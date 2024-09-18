//============================================================================
/// @file       timer.c
/// @brief      Programmable interval timer (8253/8254) controller.
///             可编程间隔定时器控制器
//============================================================================

#include <core.h>
#include <kernel/x86/cpu.h>
#include <kernel/device/timer.h>
#include <kernel/interrupt/interrupt.h>

// 8253 timer ports
// 8253 定时器引脚
#define TIMER_PORT_DATA_CH0  0x40   ///< Channel 0 data port.
#define TIMER_PORT_DATA_CH1  0x41   ///< Channel 1 data port.
#define TIMER_PORT_DATA_CH2  0x42   ///< Channel 2 data port.
#define TIMER_PORT_CMD       0x43   ///< Timer command port.

// Frequency bounds
// 频率范围
#define MIN_FREQUENCY        19
#define MAX_FREQUENCY        1193181

static void
isr_timer(const interrupt_context_t *context)
{
    (void)context;

    // Do nothing for now.

    // Send the end-of-interrupt signal.
    // 发送中断结束信号
    io_outb(PIC_PORT_CMD_MASTER, PIC_CMD_EOI);
}

void
timer_init(uint32_t frequency)
{
    // Clamp frequency to allowable range.
    // 确保频率在设定的范围内
    if (frequency < MIN_FREQUENCY) {
        frequency = MIN_FREQUENCY;
    }
    else if (frequency > MAX_FREQUENCY) {
        frequency = MAX_FREQUENCY;
    }

    // Compute the clock count value.
    // 计算时钟计数值
    uint16_t count = (uint16_t)(MAX_FREQUENCY / frequency);

    // Channel=0, AccessMode=lo/hi, OperatingMode=rate-generator
    io_outb(TIMER_PORT_CMD, 0x34);

    // Output the lo/hi count value
    io_outb(TIMER_PORT_DATA_CH0, (uint8_t)count);
    io_outb(TIMER_PORT_DATA_CH0, (uint8_t)(count >> 8));

    // Assign the interrupt service routine.
    // 定时器中断号设置为0x20，将isr_timer这个中断处理程序赋值给定时器中断号
    isr_set(TRAP_IRQ_TIMER, isr_timer);

    // Enable the timer interrupt (IRQ0).
    // 开启定时器中断
    irq_enable(IRQ_TIMER);
}

void
timer_enable()
{
    // Enable the timer interrupt (IRQ0).
    // 开启定时器中断
    irq_enable(0);
}

void
timer_disable()
{
    // Disable the timer interrupt (IRQ0).
    // 关闭定时器中断
    irq_disable(0);
}
