;=============================================================================
; @file bios.inc
;
; BIOS 常量和结构体, 只在实模式下使用
;
;=============================================================================

%ifndef __MONK_BOOT_BIOS_INC__
%define __MONK_BOOT_BIOS_INC__


;=============================================================================
; 磁盘地址包 Disk Address Packet (DAP)
; 结构体的定义，注意不占用内存，只是类型定义
; 以下是在引用某个结构体字段时，这个字段的值，其实就是偏移量
; BIOS.DAP.Bytes == 0
; BIOS.DAP.ReadSectors == 2
; BIOS.DAP.TargetBufferOffset == 4
; BIOS.DAP.TargetBufferSegment == 6
; BIOS.DAP.FirstSector == 8
;=============================================================================
struc BIOS.DAP

    .Bytes:                 resw    1   ; DAP的大小，也就是字节数量，`resw 1`表示2个字节的内存大小
    .ReadSectors:           resw    1   ; 将要读取的扇区的数量
    .TargetBufferOffset:    resw    1   ; 目标缓冲区地址的偏移量
    .TargetBufferSegment:   resw    1   ; 目标缓冲区地址段
    .FirstSector:           resq    1   ; 将要读取的第一个扇区(最多8个字节，`resq 1`表示8个字节的内存大小)

endstruc


%endif ; __MONK_BOOT_BIOS_INC__
