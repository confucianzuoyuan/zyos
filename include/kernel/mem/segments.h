//============================================================================
/// @file       segments.h
/// @brief      Memory segment definitions.
//============================================================================

#pragma once

#include <core.h>

// Segment selector values for segment registers.
// 段寄存器的段选择子的值
// 这些值在loader.S里面进行了定义，在加载64位GDT的时候
#define SEGMENT_SELECTOR_KERNEL_DATA  0x08
#define SEGMENT_SELECTOR_KERNEL_CODE  0x10
#define SEGMENT_SELECTOR_USER_DATA    0x18
#define SEGMENT_SELECTOR_USER_CODE    0x20
#define SEGMENT_SELECTOR_TSS          0x28
