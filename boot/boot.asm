;=============================================================================
; @file boot.asm
;
; 第一阶段的bootloader，光盘镜像的格式是El Torito ISO 9660
;
; 第一阶段的bootloader主要负责访问 CDROM ，来定位和启动第二阶段的bootloader(也就是LOADER.SYS).
; 第二阶段的bootloader的大小可能会接近32KB
; 而BIOS要求第一阶段的bootloader不能大于512字节。
; 可以使用如下命令来汇编本文件。
;
;   nasm -f bin -o boot.sys boot_iso.asm
;
; 将完整的镜像拷贝到下面的路径
;
;   ./iso/boot/boot.sys
;
; 确保将第二阶段的loader添加到下面的路径：
;
;   ./iso/loader.sys
;
; 使用 genisoimage 命令来创建一个可以启动的光盘镜像 `boot.iso`
;
;   genisoimage -R -J -c boot/bootcat -b boot/boot.sys \
;       -no-emul-boot -boot-load-size 4 -o boot.iso \
;       ./iso
;
;=============================================================================

; 1-stage boot loader 在 16位 的实模式下开始
bits 16

; 所有代码地址从 0x7c00 (cs = 0x07c0) 开始偏移，所以我们使用 0 作为 origin 起始地址。
org 0

; 创建 符号 ---> 段 的映射表文件。
[map all ../build/boot/boot.map]

; 包含常量，结构，和宏
%include "include/mem.inc"          ; 内存布局相关的常量
%include "include/globals.inc"      ; 全局变量的定义
%include "include/bios.inc"         ; BIOS 结构
%include "include/iso9660.inc"      ; ISO9660 结构


;=============================================================================
; boot(启动)
;
; 1-stage boot loader 入口点
;
; BIOS 如何初始化 boot 过程？通过在实模式下运行下面的代码。
; 段寄存器(segment registers)全部设置为 0 ，
; 程序计数器(IP) 是 0x7c00 。
;
; 输入寄存器:
;
;   AX      Boot 签名 (必须是0xaa55，也就是第一个512字节扇区的最末尾必须是0xaa55)
;   DL      Boot 驱动器编号
;
; 本文件中的代码执行之前的内存布局如下：
;
;   00000000 - 000003ff        1,024 bytes     Real mode IVT(实模式中断向量表所在的内存区域)
;   00000400 - 000004ff          256 bytes     BIOS data area(BIOS数据区)
;   00000500 - 00007bff       30,464 bytes     Free
;   00007c00 - 00007dff          512 bytes     1-stage boot loader (MBR), bios将软盘前512字节的内容加载到内存的0x7c00处，从这里开始执行
;   00007e00 - 0009fbff      622,080 bytes     Free
;   0009fc00 - 0009ffff        1,024 bytes     Extended BIOS data area (EBDA)
;   000a0000 - 000bffff      131,072 bytes     BIOS video memory，BIOS显示相关内存映射寄存器所处的内存区域
;   000c0000 - 000fffff      262,144 bytes     ROM
;
;   [ See http://wiki.osdev.org/Memory_Map_(x86) ]
;
; 本文件所使用的或者可能修改的内存区域：
;
;   00000800 - 00000fff        2,048 bytes     Cdrom sector read buffer(用于读取光盘镜像扇区的缓冲区，2KB)，在第一个Free区域
;   00003200 - 00003fff        3,584 bytes     Global variables(全局变量)，在第一个Free区域
;   00004000 - 00007bff       27,648 bytes     Stack(栈)，在第一个Free区域
;   00008000 - 0000ffff       32,768 bytes     2-stage boot loader，在第二个Free区域
;
;=============================================================================
boot:

    ; 做一个长跳转，来更新代码段寄存器(code segment)为0x07c0
    ; jmp 0x07c0 : .init ====> 0x07c0 << 4 + `.init`
    jmp     Mem.Loader1.Segment : .init

    ;-------------------------------------------------------------------------
    ; 初始化寄存器
    ;-------------------------------------------------------------------------
    .init:

        ; 当设置栈指针时，关闭中断。
        cli

        ; 除了es寄存器，所有的数据段寄存器(data segments)都初始化为代码段寄存器(code segment)
        mov     ax,     cs
        mov     ds,     ax
        mov     fs,     ax
        mov     gs,     ax

        ; 设置一个临时栈
        xor     ax,     ax
        mov     ss,     ax
        ; mov sp, 0x7c00
        mov     sp,     Mem.Stack.Top

        ; es 段寄存器设置为 0 ，这样可以在内存的前 64 KB 进行绝对寻址
        mov     es,     ax

        ; 重新开启中断
        sti

        ; 将 BIOS boot驱动器编号作为全局变量存储，这样我们需要时可以使用
        ; dl是edx的低8位，里面的值是驱动器编号，dl里面的值是BIOS在上电时存储进去的
        mov     byte [es:Globals.DriveNumber], dl

    ;-------------------------------------------------------------------------
    ; 定位包含根目录的ISO9660扇区
    ;-------------------------------------------------------------------------
    .findRootDirectory:

        ; 扫描2KB的扇区大小来寻找主卷描述符(primary volume descriptor)
        ; 根据ISO9660标准，从光盘的第16个扇区(16 == 0x10)开始扫描
        mov     bx,     0x10                ; 从扇区0x10开始
        mov     cx,     1                   ; 每次读取1个扇区
        ; mov di, 0x00000800
        mov     di,     Mem.Sector.Buffer   ; 将读取扇区的缓冲区的地址加载到di寄存器

        .readVolume:

            ; 读取包含卷描述符的扇区
            call    ReadSectors
            jc      .error

            ; 卷的第一个字节包含了卷的类型
            mov     al,     [es:Mem.Sector.Buffer]

            ; 主卷描述符的类型是 1 。
            cmp     al,     0x01
            je      .found

            ; 卷列表结束符的类型是 0xff 。
            cmp     al,     0xff
            je      .error

            ; 移动到下一个扇区
            inc     bx
            jmp     .readVolume

        .found:

            ; 主卷描述符包含了主卷目录条目
            ; 主卷描述符指定了包含根目录的扇区
            ; Mem.Sector.Buffer == 0x800
            ; ISO.PrimaryVolumeDescriptor.RootDirEntry == 156
            ; ISO.DirectoryEntry.LocationLBA == 2
            mov     bx,     [es:Mem.Sector.Buffer + \
                                ISO.PrimaryVolumeDescriptor.RootDirEntry + \
                                ISO.DirectoryEntry.LocationLBA]

            ; 将根目录扇区缓存下来，供后面使用
            mov     [es:Globals.RootDirectorySector],   bx

    ;-------------------------------------------------------------------------
    ; 扫描根目录，寻找 2-stage 的 boot loader
    ;-------------------------------------------------------------------------
    .findLoader:

        .processSector:

            ; 将当前目录扇区加载到缓冲区中
            mov     cx,     1                   ; 读取 1 个扇区
            mov     di,     Mem.Sector.Buffer   ; 读入扇区缓冲区

            call    ReadSectors
            jc      .error

        .processDirEntry:

            ; 条目的长度为 0 吗？如果为 0 ，那么我们已经遍历完了目录中所有的文件
            xor     ax,     ax
            mov     al,     [es:di + ISO.DirectoryEntry.RecordLength]
            cmp     al,     0
            je      .error

            ; 这个条目是一个文件吗 (flags & 2 == 0)?
            test    byte [es:di + ISO.DirectoryEntry.FileFlags],    0x02
            jnz     .nextDirEntry

            ; 文件名的长度和 "LOADER.SYS;1" 一样吗?
            cmp     byte [es:di + ISO.DirectoryEntry.NameLength], \
                        Loader.Filename.Length
            jne     .nextDirEntry

            ; 文件名是 "LOADER.SYS;1" 吗?
            push    di
            mov     cx,     Loader.Filename.Length
            mov     si,     Loader.Filename
            add     di,     ISO.DirectoryEntry.Name
            cld
            rep     cmpsb ; 重复执行cmpsb指令，其实就是按字节比较
            pop     di
            je      .loaderFound

        .nextDirEntry:

            ; 前进到下一个目录条目
            add     di,     ax
            cmp     di,     Mem.Sector.Buffer + Mem.Sector.Buffer.Size
            jb      .processDirEntry

        .nextSector:

            ; 前进到下一个目录扇区
            inc     bx
            jmp     .processSector

        .loaderFound:

            ; 显示状态信息
            mov     si,     String.Loader.Found
            call    DisplayString

    ;-------------------------------------------------------------------------
    ; 从磁盘读取 2-stage loader
    ;-------------------------------------------------------------------------
    .readLoader:

        ; 获取 2-stage boot loader 的开始扇区
        mov     bx,     [es:di + ISO.DirectoryEntry.LocationLBA]

        .calcSize:

            ; 如果size的dword表示的高位双字节(upper word)非零，那么loader至少是64KB大小，loader太大了，报错
            mov     cx,     [es:di + ISO.DirectoryEntry.Size + 2]
            cmp     cx,     0
            jne     .error

            ; 读取size的lower word，in bytes
            mov     cx,     [es:di + ISO.DirectoryEntry.Size]

            ; 最大尺寸是32KiB.
            cmp     cx,     0x8000
            ja      .error

            ; loader 的大小除以 2KB 得到扇区的数量
            add     cx,     Mem.Sector.Buffer.Size - 1  ; 向上取整
            ; 左移11个bit，就是除以2048
            shr     cx,     11                          ; 除以2048(2KB)

        .load:

            ; 将 es:di 初始化为 loader 的目标地址
            ; Mem.Loader2.Segment == 0x00008000 >> 4
            mov     ax,     Mem.Loader2.Segment
            mov     es,     ax
            xor     di,     di      ; 假设 Mem.Loader2 % 16 == 0

            ; 将 2-stage boot loader 读入内存
            call    ReadSectors
            jc      .error

    ;-------------------------------------------------------------------------
    ; 启动 2-stage boot loader
    ;-------------------------------------------------------------------------
    .launchLoader:

        ; 显示成功信息
        mov     si,     String.Loader.Starting
        call    DisplayString

        ; 长跳转到 2-stage boot loader.
        ; 0x0000 << 4 + 0x8000 == 0x8000
        ; 0x8000 是 2-stage loader 加载到内存的地址，然后从 0x8000 开始执行
        jmp     0x0000 : Mem.Loader2

    ;-------------------------------------------------------------------------
    ; 错误处理
    ;-------------------------------------------------------------------------
    .error:

        ; 显示错误信息
        mov     si,     String.Fail
        call    DisplayString

        .hang:

            ; 锁定系统
            cli
            hlt
            jmp     .hang


;=============================================================================
; ReadSectors
;
; 从 CDROM 读取 1 个或者多个 2KB 大小的扇区
; 使用的中断函数是：int 13 function 42
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
;   CF      发生错误时置为 1 。
;
; Killed registers:
;   AX, SI
;=============================================================================
ReadSectors:

    ; 填充BIOS.DAP.Buffer结构体
    ; di 中保存的是扇区在内存中的缓冲区的开始地址，把di中的地址放在DAP包的某个位置
    ; 就可以将扇区读取到di中的地址所在的内存了
    mov     word [BIOS.DAP.Buffer + BIOS.DAP.ReadSectors],          cx
    mov     word [BIOS.DAP.Buffer + BIOS.DAP.TargetBufferOffset],   di
    mov     word [BIOS.DAP.Buffer + BIOS.DAP.TargetBufferSegment],  es
    mov     word [BIOS.DAP.Buffer + BIOS.DAP.FirstSector],          bx

    ; 这条指令的作用是获取 `BIOS.DAP.Buffer` 这个结构体的起始地址，并将这个地址存储在 `si` 寄存器中
    lea     si,     [BIOS.DAP.Buffer]

    ; 调用BIOS的软件中断函数int13 42h，从drive读取扇区
    mov     ah,     0x42
    int     0x13
    ret


;=============================================================================
; DisplayString
;
; 在控制台显示以 null 结尾的字符串，使用 BIOS int 10 函数 0E
;
; Input registers:
;   SI      String offset，字符串偏移量
;
; Killed registers:
;   None
;=============================================================================
DisplayString:

    pusha

    mov     ah,     0x0e    ; int 10 AH=0x0e
    xor     bx,     bx

    cld

    .loop:

        ; 将字符串下一个字符读取到 al 寄存器
        lodsb

        ; 当到达 null 结束符，退出循环
        cmp     al,     0
        je      .done

        ; 调用 int 10 function 0eh (打印字符到teletype)
        int     0x10
        jmp     .loop

    .done:

        popa
        ret


;=============================================================================
; 全局数据
;=============================================================================

; 2-stage loader 的文件名
Loader.Filename         db      "LOADER.SYS;1"
; 计算字符串长度：$表示当前位置，减去标签Loader.Filename的位置，就是字符串的长度。
Loader.Filename.Length  equ     ($ - Loader.Filename)

; 显示字符串
; 0x0D, 0x0A ---> `\r\n`
String.Loader.Found     db      "[Monk] Loader found",          0x0D, 0x0A, 0
String.Loader.Starting  db      "[Monk] Loader starting",       0x0D, 0x0A, 0
String.Fail             db      "[Monk] ERROR: Failed to load", 0x0D, 0x0A, 0

; The DAP buffer used by ReadSectors
; ReadSectors函数所使用的DAP buffer，实例化一个结构体
align 4
BIOS.DAP.Buffer:
    istruc BIOS.DAP
        at BIOS.DAP.Bytes,                  db   BIOS.DAP_size
        at BIOS.DAP.ReadSectors,            dw   0
        at BIOS.DAP.TargetBufferOffset,     dw   0
        at BIOS.DAP.TargetBufferSegment,    dw   0
        at BIOS.DAP.FirstSector,            dq   0
    iend


;=============================================================================
; 补零填充 & boot 签名
;=============================================================================

programEnd:

; 补零填充到 510 个字节大小
times   510 - ($ - $$)    db  0

; 末尾添加两个字节的签名 AA55 .
signature       dw      0xAA55
