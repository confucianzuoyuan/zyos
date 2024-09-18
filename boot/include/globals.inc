;=============================================================================
; @file globals.inc
;
; boot loader 使用的全局变量
;
;=============================================================================

%ifndef __MONK_BOOT_GLOBALS_INC__
%define __MONK_BOOT_GLOBALS_INC__

%include "include/mem.inc"

;=============================================================================
; 全局变量 (保存在 Mem.Boot.Globals)
;=============================================================================
struc Globals, Mem.Globals
    .DriveNumber            resd    1
    .RootDirectorySector    resw    1
    .KernelSector           resw    1
    .KernelSize             resd    1
    .CPUFeatureBitsECX      resd    1
    .CPUFeatureBitsEDX      resd    1
endstruc

%endif ; __MONK_BOOT_GLOBALS_INC__
