;=============================================================================
; @file     start.asm
; @brief    内核启动器
; @details  boot loader加载内核然后跳转到`_start`方法开始执行
;=============================================================================

; 以下代码运行在64位长模式
bits 64

; 将boot loader的内存布局参数导入
%include "../boot/include/mem.inc"

; `.start`段会从0x00301000地址处开始，参见`kernel.ld`文件
section .start
    global _start

    extern kmain        ; 由main.c导出
    extern memzero      ; 由strings.asm导出
    extern _BSS_START   ; 链接器生成的符号(Linker-generated symbol)
    extern _BSS_SIZE    ; 链接器生成的符号(Linker-generated symbol)

;-----------------------------------------------------------------------------
; @function     _start
; @brief        内核入口点，被boot loader调用
;-----------------------------------------------------------------------------
_start:

    ; System V ABI 要求在函数入口处，将方向标志位清空
    ; 这样字符串从低地址向高地址的方向处理
    cld

    ; stage-2 loader 已经执行完了，所以将stage-2 loader所在的内存区域清零
    mov     rdi,    Mem.Loader2
    mov     rsi,    Mem.Loader2.Size
    call    memzero

    ; 将内核的bss段置为0
    mov     rdi,    _BSS_START
    mov     rsi,    _BSS_SIZE
    call    memzero



    ; 调用内核的main函数入口点，这个函数调用永远不应该返回
    call    kmain

    ; 如果kmain因为某些原因返回了，挂起计算机
    .hang:
        cli
        hlt
        jmp     .hang
