//============================================================================
/// @file       interrupt.h
/// @brief      中断处理操作(Interrupt handling operations).
//============================================================================

// 防止头文件多次被包含
#pragma once

#include <core.h>
#include <kernel/x86/cpu.h>

//----------------------------------------------------------------------------
// 常量
//----------------------------------------------------------------------------

// 硬件中断(hardware IRQ)的值，定时器中断设置为0，键盘中断设置为1。
#define IRQ_TIMER             0
#define IRQ_KEYBOARD          1

// 中断向量号：硬件中断陷入(hardware IRQ traps)
#define TRAP_IRQ_TIMER        0x20
#define TRAP_IRQ_KEYBOARD     0x21

// 可编程中断控制器端口常量(PIC port constants)
#define PIC_PORT_CMD_MASTER   0x20   ///< 主PIC芯片的命令端口
#define PIC_PORT_CMD_SLAVE    0xA0   ///< 从PIC芯片的命令端口
#define PIC_PORT_DATA_MASTER  0x21   ///< 主PIC芯片的数据端口
#define PIC_PORT_DATA_SLAVE   0xA1   ///< 从PIC芯片的数据端口

// PIC命令
#define PIC_CMD_EOI           0x20   ///< 中断结束符

//----------------------------------------------------------------------------
//  @struct interrupt_context
/// @brief      用来记录中断发生时CPU的上下文
//----------------------------------------------------------------------------
struct interrupt_context
{
    registers_t regs;            ///< 所有通用寄存器(all general-purpose registers).
    uint64_t    error;           ///< exception error identifier.
    uint64_t    interrupt;       ///< 中断向量号(interrupt vector number).
    uint64_t    retaddr;         ///< 中断返回地址(interrupt return address).
    uint64_t    cs;              ///< 代码段寄存器(code segment).
    uint64_t    rflags;          ///< 标志位寄存器(flags register).
    uint64_t    rsp;             ///< 栈指针(stack pointer).
    uint64_t    ss;              ///< 栈段寄存器(stack segment).
};

typedef struct interrupt_context interrupt_context_t;

//----------------------------------------------------------------------------
//  @function   interrupts_init
/// @brief      初始化所有中断表
/// @details    Initialize a table of interrupt service routine thunks, one
///             for each of the 256 possible interrupts. Then set up the
///             interrupt descriptor table (IDT) to point to each of the
///             thunks.
///
///             Interrupts should not be enabled until this function has
///             been called.
//----------------------------------------------------------------------------
void
interrupts_init();

//----------------------------------------------------------------------------
//  @typedef    isr_handler
/// @brief      Interrupt service routine called when an interrupt occurs.
///             当中断发生时，要调用的中断服务程序。函数指针类型。
/// @param[in]  context     中断发生时CPU的状态
//----------------------------------------------------------------------------
typedef void (*isr_handler)(const interrupt_context_t *context);

//----------------------------------------------------------------------------
//  @function   isr_set
/// @brief      Set an interrupt service routine for the given interrupt
///             number.
///             为给定的中断号设置中断服务程序
/// @details    Interrupts should be disabled while setting these handlers.
///             To disable an ISR, set its handler to null.
///             在设置中断服务程序时，需要禁用中断。想要禁用中断，将handler参数设置为NULL
///             就行了。
/// @param[in]  interrupt   Interrupt number (0-255).
/// @param[in]  handler     Interrupt service routine handler function.
//----------------------------------------------------------------------------
void
isr_set(int interrupt, isr_handler handler);

//----------------------------------------------------------------------------
//  @function   irq_enable
/// @brief      Tell the PIC to enable a hardware interrupt.
///             告诉PIC(可编程中断控制器)开启硬件中断
/// @param[in]  irq     IRQ number to enable (0-15).
//----------------------------------------------------------------------------
void
irq_enable(uint8_t irq);

//----------------------------------------------------------------------------
//  @function   irq_disable
/// @brief      告诉PIC关闭硬件中断
/// @param[in]  irq     IRQ number to enable (0-15).
//----------------------------------------------------------------------------
void
irq_disable(uint8_t irq);
