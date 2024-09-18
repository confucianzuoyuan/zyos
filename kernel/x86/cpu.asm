;=============================================================================
; @file     asm.asm
; @brief    x86 CPU-specific function implementations.
; @brief    x86 CPU assembly code helpers.
; @details  These implementations are for builds performed without inline
;           assembly.
;=============================================================================

bits 64

section .text

    global cpuid
    global rdmsr
    global wrmsr
    global io_inb
    global io_outb
    global io_inw
    global io_outw
    global io_ind
    global io_outd
    global set_pagetable
    global read_cr3
    global invalidate_page
    global enable_interrupts
    global disable_interrupts
    global halt
    global invalid_opcode
    global fatal

;-----------------------------------------------------------------------------
; @function     cpuid
; @brief        Return the results of the CPUID instruction.
; @reg[in]      rdi     The cpuid group code.
; @reg[in]      rsi     pointer to a registers4_t struct.
;-----------------------------------------------------------------------------
cpuid:

    push    rbx

    mov     rax,    rdi
    cpuid

    mov     [rsi + 8 * 0],  rax
    mov     [rsi + 8 * 1],  rbx
    mov     [rsi + 8 * 2],  rcx
    mov     [rsi + 8 * 3],  rdx

    pop     rbx
    ret

;-----------------------------------------------------------------------------
; @function     rdmsr
; @brief        Read the model-specific register and return the result.
; @reg[in]      rdi     The MSR register id to read.
; @reg[out]     rax     The contents of the requested MSR.
;-----------------------------------------------------------------------------
rdmsr:

    mov     rcx,    rdi

    rdmsr

    shl     rdx,    32
    or      rax,    rdx
    ret


;-----------------------------------------------------------------------------
; @function     wrmsr
; @brief        Write to the model-specific register.
; @reg[in]      rdi     The MSR register id to write.
; @reg[in]      rsi     The value to write.
;-----------------------------------------------------------------------------
wrmsr:

    mov     ecx,    edi

    mov     rax,    rsi
    mov     rdx,    rax
    shr     rdx,    32

    wrmsr

    ret

;-----------------------------------------------------------------------------
; @function     io_inb
; @brief        Retrieve a byte value from an input port.
; @reg[in]      rdi     Port number (0-65535).
; @reg[out]     rax     Byte value read from the port.
;-----------------------------------------------------------------------------
io_inb:

    mov     dx,     di
    xor     rax,    rax
    in      al,     dx
    ret

;-----------------------------------------------------------------------------
; @function     io_outb
; @brief        Write a byte value to an output port.
; @reg[in]      rdi     Port number (0-65535).
; @reg[in]      rsi     Byte value to write to the port.
;-----------------------------------------------------------------------------
io_outb:

    mov     dx,     di
    mov     ax,     si
    out     dx,     al
    ret

;-----------------------------------------------------------------------------
; @function     io_inw
; @brief        Retrieve a 16-bit word value from an input port.
; @reg[in]      rdi     Port number (0-65535).
; @reg[out]     rax     Word value read from the port.
;-----------------------------------------------------------------------------
io_inw:

    mov     dx,     di
    xor     rax,    rax
    in      ax,     dx
    ret

;-----------------------------------------------------------------------------
; @function     io_outw
; @brief        Write a 16-bit word value to an output port.
; @reg[in]      rdi     Port number (0-65535).
; @reg[in]      rsi     Word value to write to the port.
;-----------------------------------------------------------------------------
io_outw:

    mov     dx,     di
    mov     ax,     si
    out     dx,     ax
    ret

;-----------------------------------------------------------------------------
; @function     io_ind
; @brief        从一个输入端口读取32-bit dword类型的值
; @reg[in]      rdi     端口号(0-65535).
; @reg[out]     rax     从端口读取的Dword类型的值
;-----------------------------------------------------------------------------
io_ind:

    mov     dx,     di
    xor     rax,    rax
    in      eax,    dx
    ret

;-----------------------------------------------------------------------------
; @function     io_outd
; @brief        Write a 32-bit dword value to an output port.
; @reg[in]      rdi     Port number (0-65535).
; @reg[in]      rsi     Dord value to write to the port.
;-----------------------------------------------------------------------------
io_outd:

    mov     dx,     di
    mov     eax,    esi
    out     dx,     eax
    ret

;-----------------------------------------------------------------------------
; @function     set_pagetable
; @brief        更新CPU的页表寄存器CR3
; @reg[in]      rdi     包含新页表的物理内存地址
;-----------------------------------------------------------------------------
set_pagetable:

    mov     cr3,    rdi
    ret

write_cr3:

    mov     cr3,    rdi
    ret

read_cr3:

    mov     rax,    cr3
    ret

;-----------------------------------------------------------------------------
; @function     invalidate_page
; @brief        将包含虚拟地址的页置为无效
; @reg[in]      rdi     (置为无效的页的虚拟地址)
;-----------------------------------------------------------------------------
invalidate_page:

    invlpg  [rdi]
    ret

;-----------------------------------------------------------------------------
; @function     enable_interrupts
; @brief        开启中断
;-----------------------------------------------------------------------------
enable_interrupts:

    sti
    ret

;-----------------------------------------------------------------------------
; @function     disable_interrupts
; @brief        关闭中断
;-----------------------------------------------------------------------------
disable_interrupts:

    cli
    ret

;-----------------------------------------------------------------------------
; @function     halt
; @brief        挂起CPU直到出现一个中断
;-----------------------------------------------------------------------------
halt:

    hlt
    ret

;-----------------------------------------------------------------------------
; @function     invalid_opcode
; @brief        抛出无效操作符异常
;-----------------------------------------------------------------------------
invalid_opcode:

    int     6
    ret

;-----------------------------------------------------------------------------
; @function     fatal
; @brief        抛出致命错误中断来挂起系统
;-----------------------------------------------------------------------------
fatal:

    int     0xff
    ret

%macro preempt_inc 0
	lock inc dword [gs:0x18]
%endmacro

%macro preempt_dec 0
	lock dec dword [gs:0x18]
%endmacro

global spin_lock
spin_lock:
	preempt_inc
	mov rax, 1
	xchg [rdi], rax
	test rax, rax
	jz .acquired
.retry:
	pause
	bt qword [rdi], 0
	jc .retry

	xchg [rdi], rax
	test rax, rax
	jnz .retry
.acquired:
	ret

global spin_try_lock
spin_try_lock:
	preempt_inc
	mov rax, 1
	xchg [rdi], rax
	test rax, rax
	jz .acquired
	preempt_dec
	mov rax, 0
	ret
.acquired:
	mov rax, 1
	ret

global spin_unlock
spin_unlock:
	mov qword [rdi], 0
	preempt_dec
	ret