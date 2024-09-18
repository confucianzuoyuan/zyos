;=============================================================================
; @file     memset.asm
; @brief    使用大小为一个字节的值填充一片内存
;=============================================================================

bits 64

section .text

    global memset


;-----------------------------------------------------------------------------
; @function     memset
; @brief        使用大小为一个字节的值填充一片内存
; @reg[in]      rdi     目标内存区域的起始地址
; @reg[in]      rsi     要填充内存的单字节的值
; @reg[in]      rdx     待填充的字节数量
; @reg[out]     rax     目标地址
; @killedregs   r8, rcx
;-----------------------------------------------------------------------------
memset:

    ; 保存原来的目标地址
    mov     r8,     rdi

    ; The value to store is the second parameter (rsi).
    mov     rax,    rsi

    ; 逐字节存储
    mov     rcx,    rdx
    rep     stosb

    ; 返回原来的目标地址
    mov     rax,    r8
    ret
