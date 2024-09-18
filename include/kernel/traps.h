// x86 陷阱 和 中断 常量

// 处理器相关
#define T_DIVIDE 0   // 除零错误
#define T_DEBUG 1    // 调试异常
#define T_NMI 2      // non-maskable interrupt
#define T_BRKPT 3    // breakpoint
#define T_OFLOW 4    // overflow
#define T_BOUND 5    // bounds check
#define T_ILLOP 6    // illegal opcode(非法操作符)
#define T_DEVICE 7   // 设备不可用
#define T_DBLFLT 8   // double fault
#define T_COPROC 9   // 486之后不再使用
#define T_TSS 10     // invalid task switch segment
#define T_SEGNP 11   // segment not present
#define T_STACK 12   // 栈异常
#define T_GPFLT 13   // general protection fault
#define T_PGFLT 14   // page fault
#define T_RES 15     // 不再使用
#define T_FPERR 16   // 浮点数错误
#define T_ALIGN 17   // alignment check
#define T_MCHK 18    // machine check
#define T_SIMDERR 19 // SIMD 浮点数错误