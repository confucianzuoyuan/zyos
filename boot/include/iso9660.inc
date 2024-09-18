;=============================================================================
; @file iso9660.inc
;
; ISO9660 常量和结构。
;
;=============================================================================

%ifndef __MONK_BOOT_ISO9660_INC__
%define __MONK_BOOT_ISO9660_INC__


;=============================================================================
; 主卷描述符(PrimaryVolumeDescriptor)
;=============================================================================
struc ISO.PrimaryVolumeDescriptor

    .Type                   resb    1   ; == 0
    .Identifier             resb    5   ; == 1
    .Version                resb    1   ; == 6
                            resb    1   ; == 7; unused
    .SystemId               resb    32  ; == 8
    .VolumeId               resb    32  ; == 40
                            resb    8   ; == 72; unused
    .VolumeSpaceSize        resq    1   ; == 80; int32 LSB-MSB
                            resb    32  ; == 88; unused
    .VolumeSetSize          resd    1   ; == 120; int16 LSB-MSB
    .VolumeSeqNum           resd    1   ; == 124; int16 LSB-MSB
    .BlockSize              resd    1   ; == 128; int16 LSB-MSB
    .PathTableSize          resq    1   ; == 132; int32 LSB-MSB
    .PathTableLBA           resd    1   ; == 140; int32 LSB
    .PathTableLBAOpt        resd    1   ; == 144; int32 LSB
    .MpathTableLBA          resd    1   ; == 148; int32 MSB
    .MpathTableLBAOpt       resd    1   ; == 152; int32 MSB
    .RootDirEntry           resb    34  ; == 156; 包含一条条目：ISO.DirectoryEntry
    .VolumeSetId            resb    128
    .Publisher              resb    128
    .DataPreparer           resb    128
    .AppId                  resb    128
    .Copyright              resb    38
    .AbstractFileId         resb    36
    .BiblioFileId           resb    37
    .CreationDateTime       resb    17
    .ModifyDateTime         resb    17
    .ExpireDateTime         resb    17
    .EffectiveDateTime      resb    17
    .FileStructVersion      resb    1
                            resb    1   ; unused
    .AppData                resb    512
    .Reserved               resb    653

endstruc


;=============================================================================
; DirectoryEntry，光盘中的目录条目
;=============================================================================
struc ISO.DirectoryEntry

    .RecordLength           resb    1
    .ExtAttribLength        resb    1
    .LocationLBA            resq    1   ; int32 LSB-MSB
    .Size                   resq    1   ; int32 LSB-MSB
    .RecordingDateTime      resb    7
    .FileFlags              resb    1
    .FileUnitSize           resb    1
    .GapSize                resb    1
    .Volume                 resd    1   ; int16 LSB-MSB
    .NameLength             resb    1
    .Name:                              ; variable length

endstruc

%endif ; __MONK_BOOT_ISO9660_INC__
