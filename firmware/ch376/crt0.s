; crt0.s - start up code of the CH376 softcore firmware
; Copyright 2026 rampa
;
; This is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License,
; or any later version.

        .export     _init, _exit
        .export     __STARTUP__ : absolute = 1
        .import     _main, zerobss, copydata, initlib, donelib
        .import     __RAM_START__, __RAM_SIZE__

        .include    "zeropage.inc"

        .segment    "STARTUP"

_init:  sei
        cld
        ldx     #$FF
        txs
        ; C stack at the top of RAM, growing down
        lda     #<(__RAM_START__ + __RAM_SIZE__)
        sta     sp
        lda     #>(__RAM_START__ + __RAM_SIZE__)
        sta     sp+1
        jsr     zerobss
        jsr     copydata
        jsr     initlib
        jsr     _main
_exit:  jsr     donelib
@halt:  jmp     @halt

nmi:
irq:    rti

        .segment    "VECTORS"
        .word       nmi
        .word       _init
        .word       irq
