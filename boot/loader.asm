;=============================================================================
; @file loader.asm
;
; 一个 2-stage boot loader 遵循 El Torito ISO 9660 cdrom 镜像 标准。
;
; 这个 boot loader 在 1-stage loader 执行完之后执行。
; 它的作用是将内核加载到内存中，以及将 CPU 设置为32位保护模式，然后跳转到64位长模式
; 然后开始执行内核。
;
; 这个loader允许大小为几个MB的内核镜像来使用。做到这一点需要一些小技巧。
; 将内核镜像从cdrom读取到内存时，需要使用实模式才能使用的BIOS的功能。
; 而在实模式下，我们能使用的内存大约600KB。所以这个loader需要在实模式和保护模式之间来回切换，
; 来讲内核镜像的数据，以分片的方式从lower memory传送到upper memory。
;
;=============================================================================

; 2-stage boot loader 从16位实模式开始
bits 16

; 2-stage loader 从代码段0开始执行，从地址0x8000地址开始
org 0x8000

; 生成符号和段的映射表
[map all ../build/boot/loader.map]

; 引入常量，结构体和宏
%include "include/mem.inc"          ; 内存布局常量
%include "include/globals.inc"      ; 全局变量定义
%include "include/bios.inc"         ; BIOS结构体定义
%include "include/iso9660.inc"      ; ISO9660结构体
%include "include/gdt.inc"          ; 全局描述符表结构体


;=============================================================================
; load
;
; 这是2-stage loader的入口点。
;
; 这段代码被1-stage loader启动执行，然后在实模式下运行，
; 从地址 0:0x8000 开始执行。
;
; 下面的代码执行之前的内存布局：
;
;   00000000 - 000003ff        1,024 bytes     实模式下的中断向量表(Real mode IVT)
;   00000400 - 000004ff          256 bytes     BIOS数据区(BIOS data area)
;   00000500 - 000006ff          512 bytes     全局变量(Global variables)
;   00000700 - 00007bff       29,952 bytes     空闲区域(Free)
;   00007c00 - 00007dff          512 bytes     1-stage的boot loader(First-stage boot loader (MBR))
;   00007e00 - 00097fff          512 bytes     空闲区域(Free)
;   00008000 - 0000ffff       32,768 bytes     2-stage boot loader
;   00010000 - 0009fbff      588,800 bytes     空闲区域(Free)
;   0009fc00 - 0009ffff        1,024 bytes     扩展BIOS数据区(Extended BIOS data area (EBDA))
;   000a0000 - 000bffff      131,072 bytes     BIOS视频的内存映射寄存器区域(BIOS video memory)
;   000c0000 - 000fffff      262,144 bytes     ROM
;
;   [ See http://wiki.osdev.org/Memory_Map_(x86) ]
;
; 在代码执行时使用或者修改的内存区域
;
;   00000800 - 00000fff        2,048 bytes     存储CDROM扇区的缓冲区(Cdrom sector read buffer)
;   00003000 - 000030ff          256 bytes     全局描述符表(Global Descriptor Table (GDT))
;   00003100 - 000031ff          256 bytes     任务状态段(Task State Segment (TSS))
;   00003200 - 00003fff        3,584 bytes     全局变量
;   00004000 - 00007bff       16,384 bytes     实模式的栈(Real mode stack)
;   00010000 - 00017fff       32,768 bytes     页表
;   0006f000 - 0006ffff        4,096 bytes     32位保护模式的栈
;   00070000 - 0007ffff       65,536 bytes     内核加载缓冲区(Kernel load buffer)
;   00070000 - 00075fff       24,576 bytes     内存表(Memory table (from BIOS))
;   0008a000 - 0008ffff       24,576 bytes     内核特殊中断栈(Kernel special interrupt stacks)
;   00100000 - 001fefff    1,044,480 bytes     内核中断栈(Kernel interrupt stack)
;   00200000 - 002fffff    1,048,576 bytes     内核栈(Kernel stack)
;   00300000 - (krnize)                        内核镜像(Kernel image)
;
;=============================================================================
load:

    .init:

        ; 当更新段寄存器和栈指针时，关闭中断
        cli

        ; 将所有段寄存器都初始化为0
        xor     ax,     ax
        mov     ds,     ax
        mov     es,     ax
        mov     fs,     ax
        mov     gs,     ax
        mov     ss,     ax

        ; 初始化栈指针
        ; mov sp, 0x7c00
        mov     sp,     Mem.Stack.Top

        ; 清空所有剩余的通用目的寄存器
        xor     bx,     bx
        xor     cx,     cx
        xor     dx,     dx
        xor     si,     si
        xor     di,     di
        xor     bp,     bp

    ;-------------------------------------------------------------------------
    ; 为了访问upper memory，开启A20地址总线
    ;-------------------------------------------------------------------------
    .enableA20:
        ; 快速开启A20总线
        in      al,     0x92
        or      al,     2
        out     0x92,   al
        xor     ax,     ax

        ; 显示状态信息
        mov     si,     String.Status.A20Enabled
        call    DisplayStatusString

    ;-------------------------------------------------------------------------
    ; 确保我们有一个64位的CPU
    ;-------------------------------------------------------------------------
    .detect64BitMode:

        ; 是否支持处理器信息函数(processor info function)？
        mov     eax,    0x80000000  ; Get Highest Extended Function Supported
        cpuid
        cmp     eax,    0x80000001
        jb      .error.no64BitMode

        ; 使用处理器信息函数(processor info function)查看是否支持64位长模式
        mov     eax,    0x80000001  ; Extended Processor Info and Feature Bits
        cpuid
        test    edx,    (1 << 29)   ; 64-bit mode bit
        jz      .error.no64BitMode

        ; 清空32位寄存器
        xor     eax,    eax
        xor     edx,    edx

        ; 显示状态信息
        mov     si,     String.Status.CPU64Detected
        call    DisplayStatusString

    ;-------------------------------------------------------------------------
    ; 开启 CPU 的 SSE 功能
    ;-------------------------------------------------------------------------
    .enableSSE:

        ; 将 CPU 的特性标志 加载到 ecx 和 edx 寄存器中
        mov     eax,    1
        cpuid

        ; 检测是否支持 FXSAVE/FXRSTOR 指令
        test    edx,    (1 << 24)
        jz      .error.noFXinst

        ; 检测是否支持 SSE1 。
        test    edx,    (1 << 25)
        jz      .error.noSSE

        ; 检测是否支持 SSE2 。
        test    edx,    (1 << 26)
        jz      .error.noSSE2

        ; 开启带监控的硬件 FPU 功能
        mov     eax,    cr0
        and     eax,    ~(1 << 2)   ; 关闭 CR0.EM 位 (x87 FPU is present)
        or      eax,    (1 << 1)    ; 开启 CR0.MP 位 (monitor FPU)
        mov     cr0,    eax

        ; 确保 FXSAVE/FXRSTOR 指令能够保存 FPU 寄存器中的值
        ; 开启 SSE 指令的使用。并表明内核具有处理SIMD浮点异常的能力
        mov     eax,    cr4
        or      eax,    (1 << 9) | (1 << 10)    ; CR4.OFXSR, CR4.OSXMMEXCPT
        mov     cr4,    eax

        ; 显示状态信息
        mov     si,     String.Status.SSEEnabled
        call    DisplayStatusString

    ;-------------------------------------------------------------------------
    ; 将内核镜像加载到upper memory
    ;-------------------------------------------------------------------------
    .loadKernel:

        ; 当加载内核时，开启中断
        sti

        ; 在加载内核时，使用一个临时的 GDT，因为我们在加载的时候使用的是32位保护模式。
        lgdt    [GDT32.Table.Pointer]

        ; 寻找内核镜像的第一个扇区，以及内核镜像的大小
        ; 将结果放在 bx 和 eax 寄存器中。
        call    FindKernel
        jc      .error.kernelNotFound

        ; 显示状态信息
        mov     si,     String.Status.KernelFound
        call    DisplayStatusString

        ; 开始将内核加载进内存
        call    LoadKernel
        jc      .error.kernelLoadFailed

        ; 显示状态信息
        mov     si,     String.Status.KernelLoaded
        call    DisplayStatusString

        ; 关闭中断，直到启动内核时才再一次开启中断。
        ; 再次开启中断之前，内核负责设置中断控制器和表。
        cli

    ;-------------------------------------------------------------------------
    ; 从BIOS获取内存布局
    ;-------------------------------------------------------------------------
    .readLayout:

        ; 使用 BIOS 来收集内存区域所组成的数组
        ; 这些内存区域正在被使用，或者可被使用
        call    ReadMemLayout

    ;-------------------------------------------------------------------------
    ; 将loader们使用的内存区域擦除
    ;-------------------------------------------------------------------------
    .wipeMemory:

        cld
        push    es

        ; 擦除实模式的BIOS中断向量表(BIOS IVT)
        xor     ax,     ax
        mov     es,     ax
        xor     di,     Mem.BIOS.IVT
        mov     cx,     Mem.BIOS.IVT.Size
        rep     stosb

        ; 擦除实模式的BIOS数据区(BIOS data area)
        mov     di,     Mem.BIOS.Data
        mov     cx,     Mem.BIOS.Data.Size
        rep     stosb

        ; 擦除stage-1 boot loader所在的内存
        mov     di,     Mem.Loader1
        mov     cx,     Mem.Loader1.Size
        rep     stosb

        ; 擦除临时的32位保护模式栈所在的内存
        mov     ax,     Mem.Stack32.Temp.Bottom >> 4
        mov     es,     ax
        xor     ax,     ax
        xor     di,     di
        mov     cx,     Mem.Stack32.Temp.Top - Mem.Stack32.Temp.Bottom
        rep     stosb

        ; 恢复 es 寄存器
        pop     es

    ;-------------------------------------------------------------------------
    ; 建立(但还没有安装)64位GDT
    ;-------------------------------------------------------------------------
    .setupGDT64:

        ; 将GDT拷贝到它所在的内存布局中的位置
        mov     si,     GDT64.Table
        mov     di,     Mem.GDT
        mov     cx,     GDT64.Table.Size
        shr     cx,     1
        rep     movsw

    ;-------------------------------------------------------------------------
    ; 建立 (但还没有安装) 64位任务状态段
    ;-------------------------------------------------------------------------
    .setupTSS:

        ; 将TSS项拷贝到它所在的内存布局中的位置
        mov     si,     TSS64.Entry
        mov     di,     Mem.TSS64
        mov     cx,     TSS64.Entry.Size
        shr     cx,     1
        rep     movsw

    ;-------------------------------------------------------------------------
    ; 创建页表
    ;-------------------------------------------------------------------------
    .setupPageTables:

        ; 创建一个一一映射的页表来映射内存中的前10MB的内存。
        ; 这些内存足够内核和内核栈使用了。
        call    SetupPageTables

        ; 开启 PAE 分页
        mov     eax,    cr4
        or      eax,    (1 << 5)    ; CR4.PAE
        mov     cr4,    eax

    ;-------------------------------------------------------------------------
    ; 开启64位保护模式和分页
    ;-------------------------------------------------------------------------
    .enable64BitMode:

        ; 开启 64位 和 syscall/sysret 。
        mov     ecx,    0xc0000080 ; Extended Feature Enable Register (EFER)
        rdmsr
        or      eax,    (1 << 8) | (1 << 0)
        wrmsr

        ; 开启分页和保护模式
        mov     eax,    cr0
        or      eax,    (1 << 31) | (1 << 0)    ; CR0.PG, CR0.PE
        mov     cr0,    eax

        ; 开启全局页
        mov     eax,    cr4
        or      eax,    (1 << 7)    ; CR4.PGE
        mov     cr4,    eax

        ; 加载64位的GDT
        lgdt    [GDT64.Table.Pointer]

        ; 通过长跳转来使用新的GDT，这样就强制切换到了64位模式
        jmp     GDT64.Selector.Kernel.Code : .launch64

bits 64

    ;-------------------------------------------------------------------------
    ; 启动64位内核
    ;-------------------------------------------------------------------------
    .launch64:

        ; 将CPU特性的位保存到全局内存块
        mov     eax,    1
        cpuid
        mov     [Globals.CPUFeatureBitsECX], ecx
        mov     [Globals.CPUFeatureBitsEDX], edx

        ; 擦除实模式栈
        xor     eax,    eax
        mov     rdi,    Mem.Stack.Bottom
        mov     ecx,    Mem.Stack.Top - Mem.Stack.Bottom
        rep     stosb

        ; 加载强制性的64位任务状态段。
        mov     ax,     GDT64.Selector.TSS
        ltr     ax

        ; 建立数据段寄存器。注意在64位模式下，CPU将cs，ds，es，和ss寄存器一律按0处理，
        ; 无论我们在这些寄存器中保存什么值。(gs 和 fs这两个寄存器是例外，它们还是被用作实模式段寄存器)
        mov     ax,     GDT64.Selector.Kernel.Data
        mov     ds,     ax
        mov     es,     ax
        mov     fs,     ax
        mov     gs,     ax
        mov     ss,     ax

        ; 设置内核栈指针
        ; mov rsp, 0x00300000
        mov     rsp,    Mem.Kernel.Stack.Top

        ; 初始化所有通用目的寄存器
        xor     rax,    rax
        xor     rbx,    rbx
        xor     rcx,    rcx
        xor     rdx,    rdx
        xor     rdi,    rdi
        xor     rsi,    rsi
        xor     rbp,    rbp
        xor     r8,     r8
        xor     r9,     r9
        xor     r10,    r10
        xor     r11,    r11
        xor     r12,    r12
        xor     r13,    r13
        xor     r14,    r14
        xor     r15,    r15

        ; 跳转到内核的入口点
        ; jmp 0x00301000
        ; kernel.ld链接文件也指明了内核从内存的0x00301000处开始执行
        jmp     Mem.Kernel.Code

; 错误处理由于需要在屏幕上打印字符，所以需要切换到16位模式下
bits 16

    ;-------------------------------------------------------------------------
    ; 错误处理
    ;-------------------------------------------------------------------------

    .error.no64BitMode:

        mov     si,     String.Error.No64BitMode
        jmp     .error

    .error.kernelNotFound:

        mov     si,     String.Error.KernelNotFound
        jmp     .error

    .error.kernelLoadFailed:

        mov     si,     String.Error.KernelLoadFailed
        jmp     .error

    .error.noSSE:

        mov     si,     String.Error.NoSSE
        jmp     .error

    .error.noSSE2:

        mov     si,     String.Error.NoSSE2
        jmp     .error

    .error.noFXinst:

        mov     si,     String.Error.NoFXinst
        jmp     .error

    .error:

        call    DisplayErrorString

    .hang:

        cli
        hlt
        jmp     .hang


;=============================================================================
; ReadMemLayout
;
; 使用BIOS读取内存区域组成的数组，每个内存区域打上“可用”或者“已用”的标签。
;
; 当这个过程执行完，内存布局变成如下的布局，从 Mem.Table 开始：
;
;    <----- 64-bits ----->
;   +----------------------+
;   | Zone count           |
;   +----------------------+
;   | Reserved             |
;   +----------------------+
;   | Zone #0 base address |
;   +----------------------+
;   | Zone #0 size         |
;   +----------------------+
;   | Zone #0 type         |
;   +----------------------+
;   | Zone #1 base address |
;   +----------------------+
;   | Zone #1 size         |
;   +----------------------+
;   | Zone #1 type         |
;   +----------------------+
;   |         ...          |
;   +----------------------+
;
; 这个表可能是未排序的，也可能包含间隙。而对这些数据更加高效的使用是内核的责任。
; 这里保存的zone count会在pmap.c文件中进行处理
;
; Killed registers:
;   None
;=============================================================================
ReadMemLayout:

    push    eax
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    push    es

    .init:

        ; 将段寄存器设置为内存布局的位置
        mov     ax,     Mem.Table >> 4
        mov     es,     ax
        xor     esi,    esi     ; si = zone counter
        mov     di,     0x10    ; di = target memory offset

        ; 初始化ebx和edx寄存器来调用BIOS的内存探针函数
        xor     ebx,    ebx         ; ebx = BIOS call tracking data
        mov     edx,    0x534D4150  ; edx = system map magic number 'SMAP', 0x53=='S', ...

    .readZone:

        ; 调用 BIOS 函数
        mov     eax,    0xE820      ; eax = BIOS 15h function
        mov     ecx,    24          ; ecx = Max size of target buffer
        int     0x15

        ; carry 标志位表明错误
        jc      .done

        ; 如果只读取了 20 个字节，那么填充到 24 字节大小。
        cmp     ecx,    20
        jne     .nextZone

        ; 补零
        mov     dword [es:di + 20],   0

    .nextZone:

        ; 增加 zone counter 和 目标指针
        inc     si
        add     di,     0x18

        ; 当我们结束时，ebx应该是0
        cmp     ebx,    0
        je      .done

        ; 不要溢出内存布局缓冲区
        cmp     si,     (Mem.Table.Size - 0x10) / 0x18
        jb      .readZone

    .done:

        ; 将 zone count 保存在内存布局的最开始
        mov     eax,    esi
        xor     di,     di
        stosd
        xor     eax,    eax
        stosd
        stosd
        stosd

        ; 恢复寄存器和标志位
        clc
        pop     es
        pop     edi
        pop     esi
        pop     edx
        pop     ecx
        pop     ebx
        pop     eax

        ret


;=============================================================================
; FindKernel
;
; 扫描cdrom的根目录，寻找文件名为"MONK.SYS"的文件。
; 如果找到的话，返回文件的开始扇区和文件大小。
;
; Return registers:
;   EAX     内核文件大小
;   BX      开始扇区
;
; Return flags:
;   CF      Set on error
;
; Killed registers:
;   None
;=============================================================================
FindKernel:

    ; 保存寄存器，以防这些寄存器被杀掉。
    push    cx
    push    dx
    push    si
    push    di

    ; 从全局变量中读取驱动编号和根目录扇区
    ; 这些全局变量是在1-stage的boot loader中保存的
    mov     dl,     [Globals.DriveNumber]
    mov     bx,     [Globals.RootDirectorySector]

    .processSector:

        ; 将当前目录扇区加载到缓冲区
        mov     cx,     1                   ; cx = 1 sector
        mov     di,     Mem.Sector.Buffer   ; es:di = target buffer

        call    ReadSectors
        jc      .error

    .processDirEntry:

        ; 目录的大小为0吗？如果为0，那么我们已经读取完了目录中所有的文件
        xor     ax,     ax
        mov     al,     [di + ISO.DirectoryEntry.RecordLength]
        cmp     al,     0
        je      .error

        ; 这一项是一个文件吗(flags & 2 == 0)?
        test    byte [di + ISO.DirectoryEntry.FileFlags],   0x02
        jnz     .nextDirEntry

        ; 文件名的长度和"MONK.SYS;1"一样吗？
        cmp     byte [di + ISO.DirectoryEntry.NameLength], \
                    Kernel.Filename.Length
        jne     .nextDirEntry

        ; 文件名是"MONK.SYS;1"吗？
        push    di
        mov     cx,     Kernel.Filename.Length
        mov     si,     Kernel.Filename
        add     di,     ISO.DirectoryEntry.Name
        cld
        rep     cmpsb
        pop     di
        je      .kernelFound

    .nextDirEntry:

        ; 前进到下一个目录项
        add     di,     ax
        cmp     di,     Mem.Sector.Buffer + Mem.Sector.Buffer.Size
        jb      .processDirEntry

    .nextSector:

        ; 前进到下一个目录扇区
        inc     bx
        jmp     .processSector

    .kernelFound:

        ; 在bx中返回开始扇区
        mov     bx,     [di + ISO.DirectoryEntry.LocationLBA]

        ; 在eax中返回文件的大小
        mov     eax,    [di + ISO.DirectoryEntry.Size]

    .success:

        ; 清除carry标志位来表示成功
        clc

        jmp     .done

    .error:

        ; 设置carry标志位来表示错误
        stc

    .done:

        ; 恢复寄存器
        pop     di
        pop     si
        pop     dx
        pop     cx

        ret


;=============================================================================
; ReadSectors
;
; 使用BIOS的int 13函数42来读取1个或者多个大小为2KB的扇区
;
; Input registers:
;   BX      Starting sector LBA
;   CX      Number of sectors to read
;   DL      Drive number
;   ES:DI   Target buffer
;
; Return registers:
;   AH      Return code from int 13 (42h) BIOS call
;
; Flags:
;   CF      Set on error
;
; Killed registers:
;   AX, SI
;=============================================================================
ReadSectors:

    ; 填充DAP缓冲区
    mov     word [BIOS.DAP.Buffer + BIOS.DAP.ReadSectors],          cx
    mov     word [BIOS.DAP.Buffer + BIOS.DAP.TargetBufferOffset],   di
    mov     word [BIOS.DAP.Buffer + BIOS.DAP.TargetBufferSegment],  es
    mov     word [BIOS.DAP.Buffer + BIOS.DAP.FirstSector],          bx

    ; 将DAP缓冲区的地址加载到 ds:si
    lea     si,     [BIOS.DAP.Buffer]

    ; Call int13 BIOS function 42h (extended read sectors from drive).
    mov     ax,     0x4200
    int     0x13
    ret


;=============================================================================
; LoadKernel
;
; 将内核加载进内存
;
; 有两个问题需要解决：
;
;   1. 在实模式下，我们可以访问BIOS，但我们只能访问内存的头1M字节。
;   2. 在保护模式下，我们可以访问内存中前1M后面的内存，但无法访问BIOS。
;
; 由于我们需要BIOS来从CDROM中读取内核文件，同时还需要将内核文件加载到内存中前1M后面的内存中，
; 所以我们需要在实模式和保护模式之间来回切换。
;
; 下面这段代码执行以下步骤，直到整个内核文件都拷贝到upper memory（1M后面的内存）为止。
;
;     1. 使用BIOS将64KB的内核文件读入lower memory的缓冲区中。由于一次只能读取64KB，所以需要读取多次。
;     2. 切换到32位保护模式。
;     3. 将位于lower memory缓冲区中的64KB大小的数据拷贝到upper memory中的适当的位置。
;     4. 切换回实模式。
;
; Input registers:
;   EAX     内核文件的大小
;   BX      内核文件的第一个扇区
;
; Return flags:
;   CF      错误标志位
;
; Killed registers:
;   None
;=============================================================================
LoadKernel:

    ; 将寄存器压栈。
    push    es
    pusha

    ; 保存实模式下的栈指针。
    mov     [LoadKernel.StackPointer],  sp

    ; 读取cdrom磁盘号。
    mov     dl,     [Globals.DriveNumber]

    ; 保存内核文件的大小。
    mov     [Globals.KernelSize],       eax

    ; 将内核文件的大小从按字节位单位转换成按扇区为单位(需要向上取整)
    add     eax,    Mem.Sector.Buffer.Size - 1
    shr     eax,    11 ; 除以2048(2KB)

    ; 将状态保存在code memory，因为在实模式和保护模式之间来回切换时，很难使用栈
    mov     [LoadKernel.CurrentSector], bx
    add     ax,                         bx
    mov     [LoadKernel.LastSector],    ax

    .loadChunk:

        ; 设置将要读取的目标缓冲区
        mov     cx,     Mem.Kernel.LoadBuffer >> 4
        mov     es,     cx
        xor     di,     di

        ; 设置将要读取的扇区数量(buffersize / 2048)
        mov     cx,     Mem.Kernel.LoadBuffer.Size >> 11

        ; (ax = LastSector, bx = CurrentSector)
        ; 计算剩余扇区数量
        sub     ax,     bx

        ; 要读取的扇区数量是否小于缓冲区可以容纳的数量？
        cmp     cx,     ax
        jb      .proceed

        ; 不要读取多于剩余扇区数量的扇区
        mov     cx,     ax

    .proceed:

        ; 将已经加载的扇区数量保存下来，这样当拷贝到upper memory时，我们可以在保护模式下访问它。
        mov     [LoadKernel.SectorsToCopy],     cx

        ; 将内核文件的一个分片读取到缓冲区中。
        call    ReadSectors
        jc      .errorReal

    .prepareProtected32Mode:

        ; 关闭中断，直到我们从保护模式切换回实模式才再次开启中断
        ; 因为我们没有建立一个新的中断表。
        cli

        ; 开启保护模式
        mov     eax,    cr0
        or      eax,    (1 << 0)    ; CR.PE
        mov     cr0,    eax

        ; 通过长跳转来切换成32位保护模式
        jmp     GDT32.Selector.Code32 : .switchToProtected32Mode

bits 32

    .switchToProtected32Mode:

        ; 使用32位保护模式的数据段选择子来初始化所有的数据段寄存器
        mov     ax,     GDT32.Selector.Data32
        mov     ds,     ax
        mov     es,     ax
        mov     ss,     ax

        ; 创建一个只在保护模式下使用的临时栈
        ; (可能并不必要，因为中断已经被关闭了)
        mov     esp,    Mem.Stack32.Temp.Top

    .copyChunk:

        ; 使用扇区数量建立一个从lower memory到upper memory的拷贝
        xor     ecx,    ecx
        xor     esi,    esi
        xor     edi,    edi
        mov     bx,     [LoadKernel.SectorsToCopy]
        mov     cx,     bx
        shl     ecx,    11       ; multiply by sector size (2048)
        mov     esi,    Mem.Kernel.LoadBuffer
        mov     edi,    [LoadKernel.TargetPointer]

        ; 增加计数器和指针
        add     [LoadKernel.TargetPointer],     ecx
        add     [LoadKernel.CurrentSector],     bx

        ; 拷贝分片
        cld
        shr     ecx,    2       ; 除以4，因为我们拷贝的是dword类型
        rep     movsd

    .prepareProtected16Mode:

        ; 在我们切换回实模式之前，我们必须先切换到16位保护模式。
        jmp     GDT32.Selector.Code16 : .switchToProtected16Mode

bits 16

    .switchToProtected16Mode:

        ; 使用16位保护模式的数据段选择子来初始化所有的数据段寄存器
        mov     ax,     GDT32.Selector.Data16
        mov     ds,     ax
        mov     es,     ax
        mov     ss,     ax

    .prepareRealMode:

        ; 关闭保护模式
        mov     eax,    cr0
        and     eax,    ~(1 << 0)   ; CR0.PE
        mov     cr0,    eax

        ; 通过长跳转来切换回实模式
        jmp     0x0000 : .switchToRealMode

    .switchToRealMode:

        ; 恢复实模式的数据段寄存器
        xor     ax,     ax
        mov     ds,     ax
        mov     es,     ax
        mov     ss,     ax

        ; 恢复实模式栈指针
        xor     esp,    esp
        mov     sp,     [LoadKernel.StackPointer]

        ; 再次开启中断
        sti

    .checkCompletion:

        ; 检查拷贝是否完成
        mov     ax,     [LoadKernel.LastSector]
        mov     bx,     [LoadKernel.CurrentSector]
        cmp     ax,     bx
        je      .success

        ; 前进到下一个分片(chunk)
        jmp     .loadChunk

    .errorReal:

        ; 出现错误时设置carry标志位
        stc
        jmp     .done

    .success:

        ; 成功时清除标志位
        clc

    .done:

        ; 擦除加载扇区的缓冲区
        mov     ax,     Mem.Kernel.LoadBuffer >> 4
        mov     es,     ax
        xor     ax,     ax
        xor     di,     di
        mov     cx,     Mem.Kernel.LoadBuffer.Size - 1
        rep     stosb
        inc     cx
        stosb

        ; 清除我们使用的32位寄存器
        xor     eax,    eax
        xor     ecx,    ecx
        xor     esi,    esi
        xor     edi,    edi

        ; 恢复寄存器
        popa
        pop     es

        ret

;-----------------------------------------------------------------------------
; LoadKernel 的状态变量
;-----------------------------------------------------------------------------
align 4
LoadKernel.TargetPointer        dd      Mem.Kernel.Image
LoadKernel.CurrentSector        dw      0
LoadKernel.LastSector           dw      0
LoadKernel.SectorsToCopy        dw      0
LoadKernel.StackPointer         dw      0


;=============================================================================
; SetupPageTables
;
; 为64位长模式创建页表。
;
; 下面这个过程的作用是：针对物理内存的前10MB，创建一个一一映射的页表。
; 所谓一一映射的意思就是物理内存地址和虚拟内存地址相等
;
; Killed registers:
;   None
;=============================================================================
SetupPageTables:

    ; 页表位的常量
    .Present        equ     1 << 0
    .ReadWrite      equ     1 << 1
    .UserSupervisor equ     1 << 2
    .WriteThru      equ     1 << 3
    .CacheDisable   equ     1 << 4
    .AttribTable    equ     1 << 7      ; 只对PT条目有效
    .LargePage      equ     1 << 7      ; 只对PDT条目有效
    .Guard          equ     1 << 9      ; 这一位会被CPU忽略掉
    .StdBits        equ     .Present | .ReadWrite

    ; 保存寄存器
    pusha
    push    es

    ; 将段寄存器 es 中的地址设置为页表的根节点的地址
    ; mov ax, 0x00010000 >> 4
    ; mov ax, 4096
    ; mov es, ax
    mov     ax,     Mem.PageTable >> 4
    mov     es,     ax

    .clearMemory:

        ; 清空保存页表的所有内存
        ; mov ecx, (0x20000 - 0x10000) / 2
        ; mov ecx, 0x8000
        ; mov ecx, 32KB
        ; 页表所占用内存的大小是 32KiB
        cld
        xor     eax,    eax
        xor     edi,    edi
        mov     ecx,    (Mem.PageTable.End - Mem.PageTable) >> 2
        rep     stosd

    .makeTables:

        ; PML4T 的第0条指向 PDPT.
        ; mov di, 0x10000 & 0xffff ===> mov di, 0x10000
        ; es:di == 0x1000:0x10000 == 0x1000 << 4 + 0x10000 == 0x20000
        ; 以0x20000(内存128KB处)为起始地址，保存一个dword(4字节)的PDPT(0x11000)
        mov     di,                     Mem.PageTable.PML4T & 0xffff
        mov     dword [es:di],          Mem.PageTable.PDPT | .StdBits

        ; PDPT 的第0条指向 PDT.
        ; 在0x21000处保存一个dword的PDT(0x12000)
        mov     di,                     Mem.PageTable.PDPT & 0xffff
        mov     dword [es:di],          Mem.PageTable.PDT | .StdBits

        ; PDT 的第0条 使用4KB的页大小来映射头2MB内存
        ; 在0x22000保存一个PT(0x13000)
        mov     di,                     Mem.PageTable.PDT & 0xffff
        mov     dword [es:di + 0x00],   Mem.PageTable.PT | .StdBits

        ; PDT 的第1-5条将接下来的8MB内存使用2MB的页大小来映射
        ; 这部分内存用来保存内核镜像和内核栈
        mov     dword [es:di + 0x08],   0x00200000 | .StdBits | .LargePage
        mov     dword [es:di + 0x10],   0x00400000 | .StdBits | .LargePage
        mov     dword [es:di + 0x18],   0x00600000 | .StdBits | .LargePage
        mov     dword [es:di + 0x20],   0x00800000 | .StdBits | .LargePage

        ; 为前2MB内存创建页表条目，页大小为4KB。
        mov     di,     Mem.PageTable.PT & 0xffff
        mov     eax,    .StdBits
        mov     cx,     512     ; 2MB / 4KB == 512 个页

    ; 这段循环会执行512次，然后退出，nasm的循环次数就是cx寄存器中的值，也就是512
    .makePage:

        ; 遍历每个页表项，物理内存地址每次增加一个页的大小(4096字节)
        mov     [es:di],      eax       ; 存储 `物理内存地址 + .StdBits`
        add     eax,          0x1000    ; 下一个物理内存地址
        add     di,           8         ; 下一个页表项
        loop    .makePage

    .makeStackGuardPages:

        ; 在内核栈的底部添加一个4KB大小的保护页，这样的话，当内核栈溢出时，我们将会得到一个page fault。
        ; (注意：这个保护页在内存的0～2MB内存中，这很有必要，因为我们需要使用2MB～4MB这段内存)
        mov     edi,        Mem.Kernel.Stack.Bottom - 4096
        call    .makeGuard

        ; 在每个中断栈的底部创建一个保护页
        mov     edi,        Mem.Kernel.Stack.Interrupt.Bottom
        call    .makeGuard
        mov     edi,        Mem.Kernel.Stack.NMI.Bottom
        call    .makeGuard
        mov     edi,        Mem.Kernel.Stack.DF.Bottom
        call    .makeGuard
        mov     edi,        Mem.Kernel.Stack.MC.Bottom
        call    .makeGuard

    .markUncachedPages:

        ; 将覆盖 video 和 ROM 的 32 页内存 (a0000..bffff) 标记为不可缓存的(volatile)
        ; mov edi, 0xa0000
        mov     edi,    Mem.Video
        mov     cx,     32          ; 循环32次
        call    .makeUncached

    .initPageRegister:

        ; CR3 是页目录的基址寄存器。CR3 <== 0x10000
        ; CR3 寄存器保存的是页表的起始地址
        mov     edi,    Mem.PageTable
        mov     cr3,    edi

    .done:

        ; 清空我们使用的32位寄存器
        xor     eax,    eax
        xor     ecx,    ecx
        xor     edi,    edi

        ; 恢复寄存器
        pop     es
        popa

        ret

    .makeGuard:

        ; 定位 edi 寄存器中物理地址的页表条目，清除它的当前位，设置它的保护位。
        shr     edi,        9               ; 除以 4096，然后乘以 8
        add     edi,        Mem.PageTable.PT & 0xffff
        mov     eax,        [es:di]
        and     eax,        ~(.Present)     ; 清除当前位
        or      eax,        .Guard          ; 设置保护位
        mov     [es:di],    eax

        ret

    .makeUncached:

        ; 将物理地址的页表项加载到edi寄存器。设置edi中的cache-disable, write-through, 和
        ; page-attribute-table等属性对应的bit。重复这个过程，直到将“cx”所有的连续页表项都设置一遍为止。
        shr     edi,    9               ; 除以 4096，然后乘以 8
        add     edi,    Mem.PageTable.PT & 0xffff

        .makeUncached.next:

            mov     eax,        [es:di]
            or      eax,        .CacheDisable | .WriteThru | .AttribTable
            mov     [es:di],    eax
            add     di,         8
            loop    .makeUncached.next

        ret


;=============================================================================
; DisplayStatusString
;
; 添加 OS 前缀字符串以及 CRLF 后缀字符串到一个以 null 结尾的字符串，然后使用BIOS显示
;
; Input registers:
;   SI      字符串偏移量
;
; Killed registers:
;   None
;=============================================================================
DisplayStatusString:

    push    si

    mov     si,     String.OS.Prefix
    call    DisplayString

    pop     si

    call    DisplayString

    mov     si,     String.CRLF
    call    DisplayString

    ret


;=============================================================================
; DisplayErrorString
;
; 添加 OS+error 字符串前缀和一个 CRLF 字符串后缀到一个以 null 结尾的字符串，然后使用BIOS打印出来。
;
; Input registers:
;   SI      String offset
;
; Killed registers:
;   None
;=============================================================================
DisplayErrorString:

    push    si

    mov     si,     String.OS.Prefix
    call    DisplayString

    mov     si,     String.Error.Prefix
    call    DisplayString

    pop     si

    call    DisplayString

    mov     si,     String.CRLF
    call    DisplayString

    ret


;=============================================================================
; DisplayString
;
; 使用BIOS的软件中断int 10的函数0E来打印以null结尾的字符串
;
; Input registers:
;   SI      String offset
;
; Killed registers:
;   None
;=============================================================================
DisplayString:

    push    ax
    push    bx

    mov     ah,     0x0e    ; int 10 AH=0x0e
    xor     bx,     bx      ; page + color

    cld

    .loop:

        ; 将字符串的下一个字符读取到 al 寄存器中。
        lodsb

        ; 当到达 null 结束符时，跳出循环
        cmp     al,     0
        je      .done

        ; 调用int 10函数0eh，将字符打印
        int     0x10
        jmp     .loop

    .done:

        pop     bx
        pop     ax

        ret


;=============================================================================
; 全局数据
;=============================================================================

;-----------------------------------------------------------------------------
; 状态和错误字符串
;-----------------------------------------------------------------------------

String.CRLF                   db 0x0d, 0x0a,                0

String.OS.Prefix              db "[ZYOS] ",                 0

String.Status.A20Enabled      db "A20 line enabled",        0
String.Status.CPU64Detected   db "64-bit CPU detected",     0
String.Status.SSEEnabled      db "SSE enabled",             0
String.Status.KernelFound     db "Kernel found",            0
String.Status.KernelLoaded    db "Kernel loaded",           0

String.Error.Prefix           db "ERROR: ",                 0
String.Error.No64BitMode      db "CPU is not 64-bit",       0
String.Error.NoSSE            db "No SSE support",          0
String.Error.NoSSE2           db "No SSE2 support",         0
String.Error.NoFXinst         db "No FXSAVE/FXRSTOR",       0
String.Error.KernelNotFound   db "Kernel not found",        0
String.Error.KernelLoadFailed db "Kernel load failed",      0

;-----------------------------------------------------------------------------
; 文件名字符串
;-----------------------------------------------------------------------------

Kernel.Filename         db      "MONK.SYS;1"
Kernel.Filename.Length  equ     ($ - Kernel.Filename)

;-----------------------------------------------------------------------------
; ReadSectors使用的DAP缓冲区
;-----------------------------------------------------------------------------
align 4
BIOS.DAP.Buffer:
    istruc BIOS.DAP
        at BIOS.DAP.Bytes,                  db   BIOS.DAP_size
        at BIOS.DAP.ReadSectors,            dw   0
        at BIOS.DAP.TargetBufferOffset,     dw   0
        at BIOS.DAP.TargetBufferSegment,    dw   0
        at BIOS.DAP.FirstSector,            dq   0
    iend

;-----------------------------------------------------------------------------
; 32位保护模式下临时使用的GDT
;-----------------------------------------------------------------------------
align 4
GDT32.Table:

    ; 空描述符
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,            dw      0x0000
        at GDT.Descriptor.BaseLow,             dw      0x0000
        at GDT.Descriptor.BaseMiddle,          db      0x00
        at GDT.Descriptor.Access,              db      0x00
        at GDT.Descriptor.LimitHighFlags,      db      0x00
        at GDT.Descriptor.BaseHigh,            db      0x00
    iend

    ; 32位保护模式 - 代码段描述符(选择子 = 0x08)
    ; (Base=0, Limit=4GiB-1, RW=1, DC=0, EX=1, PR=1, Priv=0, SZ=1, GR=1)
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,            dw      0xffff
        at GDT.Descriptor.BaseLow,             dw      0x0000
        at GDT.Descriptor.BaseMiddle,          db      0x00
        at GDT.Descriptor.Access,              db      0x9A
        at GDT.Descriptor.LimitHighFlags,      db      0xCF
        at GDT.Descriptor.BaseHigh,            db      0x00
    iend

    ; 32位保护模式 - 数据段描述符(选择子 = 0x10)
    ; (Base=0, Limit=4GiB-1, RW=1, DC=0, EX=0, PR=1, Priv=0, SZ=1, GR=1)
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,            dw      0xffff
        at GDT.Descriptor.BaseLow,             dw      0x0000
        at GDT.Descriptor.BaseMiddle,          db      0x00
        at GDT.Descriptor.Access,              db      0x92
        at GDT.Descriptor.LimitHighFlags,      db      0xCF
        at GDT.Descriptor.BaseHigh,            db      0x00
    iend

    ; 16位保护模式 - 代码段描述符(选择子 = 0x18)
    ; (Base=0, Limit=1MiB-1, RW=1, DC=0, EX=1, PR=1, Priv=0, SZ=0, GR=0)
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,            dw      0xffff
        at GDT.Descriptor.BaseLow,             dw      0x0000
        at GDT.Descriptor.BaseMiddle,          db      0x00
        at GDT.Descriptor.Access,              db      0x9A
        at GDT.Descriptor.LimitHighFlags,      db      0x01
        at GDT.Descriptor.BaseHigh,            db      0x00
    iend

    ; 16位保护模式 - 数据段描述符(选择子 = 0x20)
    ; (Base=0, Limit=1MiB-1, RW=1, DC=0, EX=0, PR=1, Priv=0, SZ=0, GR=0)
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,            dw      0xffff
        at GDT.Descriptor.BaseLow,             dw      0x0000
        at GDT.Descriptor.BaseMiddle,          db      0x00
        at GDT.Descriptor.Access,              db      0x92
        at GDT.Descriptor.LimitHighFlags,      db      0x01
        at GDT.Descriptor.BaseHigh,            db      0x00
    iend

GDT32.Table.Size    equ     ($ - GDT32.Table)

GDT32.Table.Pointer:
    dw  GDT32.Table.Size - 1    ; Limit = 表中最后一个字节的偏移量
    dd  GDT32.Table


;-----------------------------------------------------------------------------
; 64位长模式使用的全局描述符表
;-----------------------------------------------------------------------------
align 8
GDT64.Table:

    ; 空描述符
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,             dw      0x0000
        at GDT.Descriptor.BaseLow,              dw      0x0000
        at GDT.Descriptor.BaseMiddle,           db      0x00
        at GDT.Descriptor.Access,               db      0x00
        at GDT.Descriptor.LimitHighFlags,       db      0x00
        at GDT.Descriptor.BaseHigh,             db      0x00
    iend

    ; 内核: 数据段描述符(选择子 = 0x08)
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,             dw      0x0000
        at GDT.Descriptor.BaseLow,              dw      0x0000
        at GDT.Descriptor.BaseMiddle,           db      0x00
        at GDT.Descriptor.Access,               db      0x92
        at GDT.Descriptor.LimitHighFlags,       db      0x00
        at GDT.Descriptor.BaseHigh,             db      0x00
    iend

    ; 内核: 代码段描述符(选择子 = 0x10)
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,             dw      0x0000
        at GDT.Descriptor.BaseLow,              dw      0x0000
        at GDT.Descriptor.BaseMiddle,           db      0x00
        at GDT.Descriptor.Access,               db      0x9A
        at GDT.Descriptor.LimitHighFlags,       db      0x20
        at GDT.Descriptor.BaseHigh,             db      0x00
    iend

    ; 用户: 数据段描述符(选择子 = 0x18)
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,             dw      0x0000
        at GDT.Descriptor.BaseLow,              dw      0x0000
        at GDT.Descriptor.BaseMiddle,           db      0x00
        at GDT.Descriptor.Access,               db      0xF2
        at GDT.Descriptor.LimitHighFlags,       db      0x00
        at GDT.Descriptor.BaseHigh,             db      0x00
    iend

    ; 用户: 代码段描述符(选择子 = 0x20)
    istruc GDT.Descriptor
        at GDT.Descriptor.LimitLow,             dw      0x0000
        at GDT.Descriptor.BaseLow,              dw      0x0000
        at GDT.Descriptor.BaseMiddle,           db      0x00
        at GDT.Descriptor.Access,               db      0xFA
        at GDT.Descriptor.LimitHighFlags,       db      0x20
        at GDT.Descriptor.BaseHigh,             db      0x00
    iend

    ; 64-bit TSS 描述符(选择子 = 0x28)
    istruc TSS64.Descriptor
        at TSS64.Descriptor.LimitLow,           dw    TSS64_size - 1
        at TSS64.Descriptor.BaseLow,            dw    Mem.TSS64 & 0xffff
        at TSS64.Descriptor.BaseMiddle,         db    (Mem.TSS64 >> 16) & 0xff
        at TSS64.Descriptor.Access,             db    0x89
        at TSS64.Descriptor.LimitHighFlags,     db    0x00
        at TSS64.Descriptor.BaseHigh,           db    (Mem.TSS64 >> 24) & 0xff
        at TSS64.Descriptor.BaseHighest,        dd    (Mem.TSS64 >> 32)
        at TSS64.Descriptor.Reserved,           dd    0x00000000
    iend

GDT64.Table.Size    equ     ($ - GDT64.Table)

; GDT64表的指针
; 这个指针引用了Mem.GDT，而不是GDT64.Table，因为当我们拷贝之后，
; Mem.GDT就是64位模式GDT所在的内存地址
GDT64.Table.Pointer:
    dw  GDT64.Table.Size - 1    ; Limit = offset of last byte in table
    dq  Mem.GDT                 ; Address of table copy


;-----------------------------------------------------------------------------
; 64位模式的任务状态段(Task State Segment)
;-----------------------------------------------------------------------------
align 8
TSS64.Entry:

    ; 当出现一个这样的中断时(引发从用户模式到内核模式特权转变的中断)，
    ; 创建一个 TSS 会导致 CPU 使用一个特殊中断栈(RSP0)，
    ;
    ; 如果一个灾难性的异常出现 -- 例如 NMI, double fault, 或者
    ; machine check -- 使用一个保证有效的异常特定栈(IST1 .. IST3)
    ;
    ; 参见 section 6.14.5 in volume 3 of the Intel 64 and IA-32 Architectures
    ; Software Developer’s Manual for more information.
    istruc TSS64
        at TSS64.RSP0,          dq      Mem.Kernel.Stack.Interrupt.Top
        at TSS64.RSP1,          dq      0
        at TSS64.RSP2,          dq      0
        at TSS64.IST1,          dq      Mem.Kernel.Stack.NMI.Top
        at TSS64.IST2,          dq      Mem.Kernel.Stack.DF.Top
        at TSS64.IST3,          dq      Mem.Kernel.Stack.MC.Top
        at TSS64.IST4,          dq      0
        at TSS64.IST5,          dq      0
        at TSS64.IST6,          dq      0
        at TSS64.IST7,          dq      0
        at TSS64.IOPB,          dw      TSS64_size          ; no IOPB
    iend

TSS64.Entry.Size    equ     ($ - TSS64.Entry)


;=============================================================================
; 补零填充
;=============================================================================

programEnd:

; 将 boot record 填充到 32 KiB 大小
times   0x8000 - ($ - $$)    db  0
