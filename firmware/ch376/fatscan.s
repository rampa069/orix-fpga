; fatscan.s - count free entries in a FAT sector
; Copyright 2026 rampa
;
; This is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License,
; or any later version.
;
; cc65 compiles the C version of these loops into some 150 to 200 cycles per
; entry, which made the first DISK_QUERY on a FAT16 volume take seconds.
;
; unsigned int __fastcall__ fat_count_zero16(const unsigned char *p, unsigned int n);
;   number of 16 bit entries equal to 0 among the n (1..256) entries at p
; unsigned int __fastcall__ fat_count_zero32(const unsigned char *p, unsigned int n);
;   number of FAT32 entries (low 28 bits) equal to 0 among the n (1..128) at p

        .export     _fat_count_zero16, _fat_count_zero32
        .import     popax
        .importzp   ptr1, ptr2, tmp1, tmp2, tmp3

        .code

; common entry: n -> tmp1/tmp2, p -> ptr1, count -> ptr2 = 0, Y = 0
setup:  sta     tmp1
        stx     tmp2
        jsr     popax
        sta     ptr1
        stx     ptr1+1
        lda     #0
        sta     ptr2
        sta     ptr2+1
        tay
        rts

; n = n - 1, Z set when it reaches 0
dec_n:  lda     tmp1
        bne     @low
        dec     tmp2
@low:   dec     tmp1
        lda     tmp1
        ora     tmp2
        rts

_fat_count_zero16:
        jsr     setup
@loop:  lda     (ptr1),y
        iny
        ora     (ptr1),y
        bne     @used
        inc     ptr2
        bne     @used
        inc     ptr2+1
@used:  iny                     ; wraps after 128 entries
        bne     @next
        inc     ptr1+1
@next:  jsr     dec_n
        bne     @loop
        lda     ptr2
        ldx     ptr2+1
        rts

_fat_count_zero32:
        jsr     setup
@loop:  lda     (ptr1),y
        iny
        ora     (ptr1),y
        iny
        ora     (ptr1),y
        iny
        sta     tmp3
        lda     (ptr1),y
        and     #$0F            ; the top 4 bits are reserved
        ora     tmp3
        bne     @used
        inc     ptr2
        bne     @used
        inc     ptr2+1
@used:  iny                     ; wraps after 64 entries
        bne     @next
        inc     ptr1+1
@next:  jsr     dec_n
        bne     @loop
        lda     ptr2
        ldx     ptr2+1
        rts
