;=============================================================================
; @file     interrupt.asm
; @brief    Interrupt descriptor table and service routine functionality.
;           中断描述符表和中断服务程序功能
;=============================================================================

bits 64

section .text

    global interrupts_init
    global isr_set
    global irq_enable
    global irq_disable


;-------------------------------------------------------------------------------------
; 中断的内存布局
;
;   00001000 - 00001fff     4,096 bytes     中断描述符表(Interrupt descriptor table (IDT))
;   00002000 - 000027ff     2,048 bytes     内核定义的ISR表(Kernel-defined ISR table)
;   00002800 - 00002fff     2,048 bytes     ISR thunk table
;
; IDT 包含 256 个中断描述符，每一个都指向一个中断服务程序(interrupt service routine, ISR)
; 的内存块，这个内存块里面包含跳转到一个通用ISR分发器的代码，这个分发器用来调用内核定义的ISR表
;-------------------------------------------------------------------------------------

; IDT memory range
; 中断描述符表的内存范围
Mem.IDT             equ     0x00001000
Mem.IDT.Size        equ     IDT.Descriptor_size * 256

; Kernel ISR table
; 内核中断服务程序表的内存范围
Mem.ISR.Table       equ     0x00002000
Mem.ISR.Table.Size  equ     8 * 256         ; Pointer per interrupt

; ISR thunks
Mem.ISR.Thunks      equ     0x00002800
Mem.ISR.Thunks.Size equ     17 * 256        ; 17 bytes of code per interrupt

; 段选择子(Segment selectors)
Segment.Kernel.Data equ     0x08
Segment.Kernel.Code equ     0x10
Segment.User.Data   equ     0x18
Segment.User.Code   equ     0x20
Segment.TSS         equ     0x28

; CPU异常的常量
Exception.NMI       equ     0x02
Exception.DF        equ     0x08
Exception.TS        equ     0x0A
Exception.NP        equ     0x0B
Exception.SS        equ     0x0C
Exception.GP        equ     0x0D
Exception.PF        equ     0x0E
Exception.MC        equ     0x12


;-----------------------------------------------------------------------------
; IDT descriptor
;
; 每个中断描述符是一个16字节大小的结构，组织如下：
;
;     31                   16 15                    0
;    +-----------------------+-----------------------+
;    |        Segment        |         Offset        |
;    |       Selector        |          0:15         |
;    +-----------------------+-----------------------+
;    |        Offset         |         Flags         |
;    |        31:16          |                       |
;    +-----------------------+-----------------------+
;    |                    Offset                     |
;    |                     63:32                     |
;    +-----------------------+-----------------------+
;    |                   Reserved                    |
;    |                                               |
;    +-----------------------+-----------------------+
;
;         Bits
;       [0:15]      Interrupt handler offset bits [0:15]
;      [16:31]      Code segment selector
;      [32:34]      IST (Interrupt stack table)
;      [35:39]      Must be 0
;      [40:43]      Type (1110 = interrupt, 1111 = trap)
;          44       Must be 0
;      [45:46]      DPL (Descriptor privilege level) 0 = highest
;          47       P (Present)
;      [48:63]      Interrupt handler offset bits [16:31]
;      [64:95]      Interrupt handler offset bits [32:63]
;      [96:127]     Reserved
;
;-----------------------------------------------------------------------------
struc IDT.Descriptor

    .OffsetLo       resw    1
    .Segment        resw    1
    .Flags          resw    1
    .OffsetMid      resw    1
    .OffsetHi       resd    1
    .Reserved       resd    1

endstruc

; 中断描述符表的指针，使用lidt指令来加载
; lidt：load interrupt descriptor table
align 8
IDT.Pointer:
    dw  Mem.IDT.Size - 1    ; Limit = offset of last byte in table.
    dq  Mem.IDT             ; Address of table.


;-----------------------------------------------------------------------------
; ISR.Thunk.Template
;
; 在初始化期间，ISR thunk模板会被拷贝并修改256次。thunk代码的目的是：在调用通用
; 中断分发器之前将中断号压栈。这很有必要，否则ISR就拿不到中断号了。thunk必须是8字节大小。
;-----------------------------------------------------------------------------

align 8
ISR.Thunk.Template:
    db      0x90                ; "nop" 指令用于填充和对齐
    db      0x6A, 0             ; "push <interrupt>" 占位符
    db      0xE9, 0, 0, 0, 0    ; "jmp <dispatcher>" 占位符

ISR.Thunk.Size   equ     ($ - ISR.Thunk.Template)


;-----------------------------------------------------------------------------
; ISR.Dispatcher
;
; 通用的 ISR 分发器。当中断到达时，所有的 ISR thunks 都会跳转到这里。
; 当分发器从栈上接收到中断号时，将会根据中断号从表中查找内核定义的ISR。
; 如果找到了有效的ISR，那么分发器会通过指向中断上下文的指针来调用ISR。
; 中断上下文中包含了所有通用寄存器中的值，还有中断号以及错误码(如果有的话)。
;-----------------------------------------------------------------------------
ISR.Dispatcher:

    ; 压栈一个dummy错误码
    push    0

    ; 保存头两个通用寄存器
    push    r15
    push    r14

    .specialEntry:          ; ISR.Dispatcher.Special 的入口

        ; 保存其它的通用寄存器
        push    r13
        push    r12
        push    r11
        push    r10
        push    r9
        push    r8
        push    rbp
        push    rdi
        push    rsi
        push    rdx
        push    rcx
        push    rbx
        push    rax

        ; 保存 MXCSR 寄存器
        sub     rsp,    8
        stmxcsr [rsp]

    .lookup:

        ; 在表中查找内核定义的ISR
        ; Mem.ISR.Table = 0x2000
        mov     rax,    [rsp + 8 * 17]              ; rax=interrupt number
        mov     rax,    [Mem.ISR.Table + 8 * rax]   ; rax=ISR address

        ; 如果没有查找到ISR，那么结束
        cmp     rax,    0
        je      .done

    .dispatch:

        ; System V ABI 要求在函数入口处清空方向标志位(direction flag).
        ; 方向标志位是x86架构中的一个标志位，用于控制字符串操作指令的方向。
        ; 当DF标志位被置1时，字符串指令会从高地址向低地址处理字符串；
        ; 当DF标志位被清0时，字符串指令会从低地址向高地址处理字符串。
        ; 因此，在函数入口处将DF标志位清空可以确保函数对字符串操作的处理方向与调用方一致。
        cld

        ; 中断上下文在栈上，所以将ISR的指针传递给栈，作为第一个参数。
        ; lea rdi, [rsp + 8] 是一条在x86-64架构中的汇编指令，
        ; 它的功能是将栈指针 rsp 加上8的结果（即地址 rsp + 8）加载到 rdi 寄存器中。
        lea     rdi,    [rsp + 8]   ; 跳过 MXCSR 寄存器。

        ; 调用 ISR 。
        call    rax

    .done:

        ; 恢复 MXCSR 寄存器。
        ldmxcsr [rsp]
        add     rsp,    8

        ; 恢复通用寄存器
        pop     rax
        pop     rbx
        pop     rcx
        pop     rdx
        pop     rsi
        pop     rdi
        pop     rbp
        pop     r8
        pop     r9
        pop     r10
        pop     r11
        pop     r12
        pop     r13
        pop     r14
        pop     r15
        add     rsp,    16      ; 删除错误码和中断号

        ; iretq指令用于从中断处理程序返回到被中断的程序或过程。
        iretq


;-----------------------------------------------------------------------------
; ISR.Dispatcher.Special
;
; 特殊ISR分发器用来处理异常8和异常10～14。CPU在调用异常中断处理器之前将错误码压栈，
; 所以为了兼容通用ISR分发器，我们需要交换栈上的中断号和错误码。
; 8号异常：double fault
; 10号异常：invalid tss
; 11号异常：segment not present
; 12号异常：stack fault
; 13号异常：general protection
; 14号异常：page fault
;-----------------------------------------------------------------------------
ISR.Dispatcher.Special:

    ; 首先保存 r14 和 r15 寄存器
    push    r15
    push    r14

    ; 使用 r14 和 r15 来交换栈上的中断号和错误码。
    mov     r14,            [rsp + 8 * 2]    ; 中断号
    mov     r15,            [rsp + 8 * 3]    ; 错误码
    mov     [rsp + 8 * 2],  r15
    mov     [rsp + 8 * 3],  r14

    ; 跳转到通用分发器，只是跳过了插入错误码和保存r14和r15的步骤。
    jmp     ISR.Dispatcher.specialEntry


;-----------------------------------------------------------------------------
; @function interrupts_init
;-----------------------------------------------------------------------------
interrupts_init:

    ;-------------------------------------------------------------------------
    ; 初始化8259可编程中断控制器(PIC, programmable interrupt controller)
    ;-------------------------------------------------------------------------
    .setupPIC:

        ; (ICW = initialization command word)

        ; 初始化主PIC芯片
        mov     al,     0x11        ; ICW1: 0x11 = init with 4 ICW's
        out     0x20,   al
        mov     al,     0x20        ; ICW2: 0x20 = interrupt offset 32
        out     0x21,   al
        mov     al,     0x04        ; ICW3: 0x04 = IRQ2 has a slave
        out     0x21,   al
        mov     al,     0x01        ; ICW4: 0x01 = x86 mode
        out     0x21,   al

        ; 初始化从PIC芯片
        mov     al,     0x11        ; ICW1: 0x11 = init with 4 ICW's
        out     0xa0,   al
        mov     al,     0x28        ; ICW2: 0x28 = interrupt offset 40
        out     0xa1,   al
        mov     al,     0x02        ; ICW3: 0x02 = attached to master IRQ2.
        out     0xa1,   al
        mov     al,     0x01        ; ICW4: 0x01 = x86 mode
        out     0xa1,   al

        ; 禁用所有IRQ。后面内核会重新启动它想要处理的中断。
        mov     al,     0xff
        out     0x21,   al
        out     0xa1,   al

    ;-------------------------------------------------------------------------
    ; Initialize the ISR thunk table
    ;-------------------------------------------------------------------------
    .setupThunks:

        ; 在ISR thunk表中将ISR thunk模板复制256次(因为有256种中断和异常)
        ; 当复制以后
        ;   1. 修改压栈的中断号
        ;   2. 修改跳转到分发器的跳转地址

        ; 特定的CPU异常在调用中断陷入之前会将错误码压栈。
        ; 我们需要使用一个特殊分发器来处理这一类异常，
        ; 这样这类异常才不会在调用ISR之前，额外再去压栈一个错误码。
        .PushesError    equ     (1 << Exception.DF) | \
                                (1 << Exception.TS) | \
                                (1 << Exception.NP) | \
                                (1 << Exception.SS) | \
                                (1 << Exception.GP) | \
                                (1 << Exception.PF)

        ; 初始化目标指针和中断计数器
        mov     rdi,    Mem.ISR.Thunks  ; rdi = thunk 表偏移量
        xor     rcx,    rcx             ; rcx = 中断号

        .installThunk:

            ; 将ISR thunk模板拷贝到当前的thunk项
            mov     rsi,    ISR.Thunk.Template
            movsq       ; thunk必须是8字节大小

            ; 将"push 0"占位符替换为"push X"，X是当前中断号
            mov     byte [rdi - ISR.Thunk.Size + 2],  cl

            ; 默认情况下，所有thunk都跳转到ISR通用分发器
            mov     r8,     ISR.Dispatcher

            ; 是否需要将通用分发器换成特殊分发器？

            ; 如果中断号大于14，那么肯定不会使用特殊分发器，直接跳过
            cmp     rcx,    14
            ja      .updateDispatcher

            ; 如果当前thunk处理的不是压栈了错误码的异常，那么直接跳过。
            ; (使用一位掩码，这样检测的更快)
            mov     eax,    1
            shl     eax,    cl
            test    eax,    .PushesError
            jz      .updateDispatcher

            ; 使用特殊分发器处理异常(这些异常压栈了错误码)
            mov     r8,     ISR.Dispatcher.Special

        .updateDispatcher:

            ; 将占位符"jmp 0"替换为"jmp <dispatcher offset>"。
            ; `r8d`是`r8`的32位版本
            sub     r8,                                 rdi
            mov     dword [rdi - ISR.Thunk.Size + 4],   r8d

            ; 前进到下一个中断，直到到达 256 。
            inc     ecx
            cmp     ecx,    256
            jne     .installThunk

    ;-------------------------------------------------------------------------
    ; 初始化中断描述符表(IDT)
    ;-------------------------------------------------------------------------
    .setupIDT:

        ; 先将整个IDT清零
        xor     rax,    rax
        mov     rcx,    Mem.IDT.Size / 8
        mov     edi,    Mem.IDT
        rep     stosq

        ; 初始化指针，来将ISR thunk地址传入IDT。
        mov     rsi,    Mem.ISR.Thunks      ; rsi = thunk 表偏移量
        mov     rdi,    Mem.IDT             ; rdi = IDT 偏移量
        xor     rcx,    rcx                 ; rcx = 中断号

        .installDescriptor:

            ; 将thunk表偏移量拷贝到r8寄存器，这样我们可以修改它
            lea     r8,     [rsi + 1]   ; +1 to skip the nop

            ; 存储ISR thunk地址的[0:15]位
            mov     word [rdi + IDT.Descriptor.OffsetLo],   r8w

            ; 存储ISR thunk地址的[16:31]位
            shr     r8,     16
            mov     word [rdi + IDT.Descriptor.OffsetMid],  r8w

            ; 存储ISR thunk地址的[32:63]位
            shr     r8,     16
            mov     dword [rdi + IDT.Descriptor.OffsetHi],  r8d

            ; 存储内核代码段选择子`0x10`
            mov     r8w,    Segment.Kernel.Code
            mov     word [rdi + IDT.Descriptor.Segment],    r8w

            ; CPU异常是中断向量号小于32的中断
            ; 对于这些中断，使用一个中断门(interrupt gate).
            ; 对于其它中断，使用一个陷入门(trap gate).
            cmp     cl,     31
            ja      .useTrap

        .useInterrupt:

            ; 存储标志位 (IST=0, Type=interrupt, DPL=0, P=1)
            mov     word [rdi + IDT.Descriptor.Flags], 1000111000000000b
            jmp     .nextDescriptor

        .useTrap:

            ; 存储标志位 (IST=0, Type=trap, DPL=0, P=1)
            mov     word [rdi + IDT.Descriptor.Flags], 1000111100000000b

        .nextDescriptor:

            ; 前进到下一个thunk和IDT项
            add     rsi,    ISR.Thunk.Size
            add     rdi,    IDT.Descriptor_size

            ; 碰到中断号为256的，也就是最后一个中断号，退出循环
            inc     ecx
            cmp     ecx,    256
            jne     .installDescriptor

        .replaceSpecialStacks:

            ; 三个异常(DF, MC, NMI)需要特殊的栈。所以需要替换它们的IDT项中的标志位，
            ; 需要替换成不同的中断栈表(IST)配置。

            ; NMI exception (IST=1, Type=interrupt, DPL=0, P=1)
            mov     rdi,        Mem.IDT + \
                                    IDT.Descriptor_size * Exception.NMI + \
                                    IDT.Descriptor.Flags
            mov     word [rdi], 1000111000000001b

            ; Double-fault exception (IST=2, Type=interrupt, DPL=0, P=1)
            mov     rdi,        Mem.IDT + \
                                    IDT.Descriptor_size * Exception.DF + \
                                    IDT.Descriptor.Flags
            mov     word [rdi], 1000111000000010b

            ; Machine-check exception (IST=3, Type=interrupt, DPL=0, P=1)
            mov     rdi,        Mem.IDT + \
                                    IDT.Descriptor_size * Exception.MC + \
                                    IDT.Descriptor.Flags
            mov     word [rdi], 1000111000000011b

        .loadIDT:

            ; 加载中断描述符表
            lidt    [IDT.Pointer]

        ret


;-----------------------------------------------------------------------------
; @function isr_set
;-----------------------------------------------------------------------------
isr_set:

    ; 在禁用中断之前保存标志位
    pushf

    ; 当更新ISR表时，临时关闭中断
    cli

    ; 中断号乘以8得到这个中断在ISR表中的偏移量
    shl     rdi,    3
    add     rdi,    Mem.ISR.Table

    ; 存储中断服务程序
    mov     [rdi],  rsi

    ; 恢复原来的中断标志位设置
    popf

    ret


;-----------------------------------------------------------------------------
; @function irq_enable
;-----------------------------------------------------------------------------
irq_enable:

    ; 将 IRQ 保存到 cl 寄存器中。
    mov     rcx,    rdi

    ; 确定要更新的是哪个PIC芯片，(<8 = master, else slave)
    cmp     cl,     8
    jae     .slave

    .master:

        ; 计算掩码 ~(1 << IRQ).
        mov     edx,    1
        shl     edx,    cl
        not     edx

        ; 读取当前掩码
        in      al,     0x21

        ; 清空 IRQ bit 然后更新掩码
        and     al,     dl
        out     0x21,   al

        ret

    .slave:

        ; 递归的使能主芯片的IRQ2引脚，否则从芯片的IRQs将不会工作。
        mov     rdi,    2
        call    irq_enable

        ; 从 IRQ 减去 8
        sub     cl,     8

        ; 计算掩码 ~(1 << IRQ).
        mov     edx,    1
        shl     edx,    cl
        not     edx

        ; 读取当前掩码
        in      al,     0xa1

        ; 清空 IRQ bit 然后更新掩码
        and     al,     dl
        out     0xa1,   al

        ret


;-----------------------------------------------------------------------------
; @function irq_disable
;-----------------------------------------------------------------------------
irq_disable:

    ; 将 IRQ 保存到 cl 寄存器中。
    mov     rcx,    rdi

    ; 确定要更新的是哪个PIC芯片，(<8 = master, else slave)
    cmp     cl,     8
    jae     .slave

    .master:

        ; 计算掩码(1 << IRQ).
        mov     edx,    1
        shl     edx,    cl

        ; 读取当前掩码
        in      al,     0x21

        ; 设置 IRQ bit 然后更新掩码
        or      al,     dl
        out     0x21,   al

        ret

    .slave:

        ; 从 IRQ 减去 8
        sub     cl,     8

        ; 计算掩码(1 << IRQ)
        mov     edx,    1
        shl     edx,    cl

        ; 读取当前掩码
        in      al,     0xa1

        ; 设置 IRQ bit 然后更新掩码
        or      al,     dl
        out     0xa1,   al

        ret
