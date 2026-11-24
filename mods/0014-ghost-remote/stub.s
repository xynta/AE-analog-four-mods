        | Mod 0014 - GHOST REMOTE (xynta). See mod.toml.
        |
        | request  F0 00 20 3C 06 00 5F <sub 01..3F> <seq 00..7F> <args, 7-bit> F7
        | reply    F0 00 20 3C 06 00 5F <sub|40> <seq> <status> <payload, 8/7-packed> F7
        | status   0 OK, 1 BUSY, 2 BAD, 4 UNKNOWN. No reply to a malformed request (shorter than 10 or longer
        |          than 48 bytes, no F7, sub 0 or above 3F) nor to one that comes while another is handled.
        |
        | Runs where the stock SysEx handlers run (the dispatcher 0x400644ea), never in the audio interrupt.
        | It writes nothing but its own state in free DDR (0x46808000..0x4680882b) and, for KEY, ENC and
        | RELEASE, the panel's own bytes into the panel parser (0x40062dfc, which the panel UART's interrupt
        | 0x400021ce calls for every byte), with every interrupt masked while it does.
        |
        | The code is split into small sections because each lives in its own run of dead code (cave10 and
        | gr2..gr12 in the registry): no section may grow past its cave.

        .include "symbols.inc"

        .equ    G_OUT,      0x46808000            | the reply as sent (<= 0x280 B)
        .equ    G_RAW,      0x46808400            | its payload before packing (<= 0x21c B)
        .equ    G_ST,       0x46808800            | the state:
        .equ    S_MAGIC,    0                     |   MAGIC once cleared after power-up
        .equ    S_BUSY,     4                     |   byte: a request is being handled
        .equ    S_HELD,     8                     |   11 bytes: the keys KEY put down, per panel group
        .equ    S_CNT,      20                    |   6 longs: requests, replies sent, dropped (busy),
        .equ    S_SIZE,     44                    |   malformed, panel messages injected, panel busy
        .equ    MAGIC,      0x47485231            | "GHR1"
        .equ    GROUPS,     11                    | the panel parser's key groups (0x408c393c)
        .equ    KEYS,       80                    | groups 0..9 hold the A4's keys (slot table 0x401ebaf8;
                                                  | group 10 is the Analog Keys' and maps to id -1 here)
        .equ    KNOBS,      11                    | encoder wire channels 0..10 (knob table 0x401ebdf8: B C D
                                                  | E G H I J A F LEVEL; 11.. map to knob -1)
        .equ    NSUB,       13                    | subs 0..12 in ghr_tab

        | ------------------------------------------------------------------
        | The entry: slot 0x5F of the product-6 SysEx table (0x401ec2b4; stock: the dump receiver 0x40063826,
        | whose type switch 0x40067390 takes 0x52..0x5D and drops 0x5F).
        | C call (msg, len, source): msg = F0 ..., len counts F0 and F7, source a mask (bit 1 USB, bit 3 DIN).
        | ------------------------------------------------------------------
        .section .gr1,"ax"
        .align  2
ghr_sysex:
        lea     -40(%sp),%sp
        movem.l %d2-%d7/%a2-%a5,(%sp)
        move.l  44(%sp),%a2                       | msg
        move.l  48(%sp),%d7                       | len
        move.l  52(%sp),-(%sp)                    | the source mask (bit 1 USB, bit 3 DIN) -> the port
        jsr     sysex_port_of                     | sysex_send takes (2 USB, 3 DIN, 4 both), as the
        addq.l  #4,%sp                            | stock dump requests do
        move.l  %d0,%d2                           | the reply goes back there
        lea     G_ST,%a3
        move.w  %sr,%d1
        move.w  #0x2700,%sr
        move.l  (%a3),%d0
        cmpi.l  #MAGIC,%d0
        beq.s   1f
        moveq   #S_SIZE/4-1,%d0                   | the first request since power-up:
0:      clr.l   (%a3,%d0.l*4)                     | the state is whatever the DDR held
        subq.l  #1,%d0
        bpl.s   0b
        move.l  #MAGIC,(%a3)
1:      tst.b   S_BUSY(%a3)
        bne.s   8f
        move.b  #1,S_BUSY(%a3)
        move.w  %d1,%sr
        addq.l  #1,S_CNT(%a3)
        moveq   #10,%d0
        cmp.l   %d0,%d7
        blt.s   7f
        moveq   #48,%d0
        cmp.l   %d0,%d7
        bgt.s   7f
        mvz.b   -1(%a2,%d7.l),%d0
        cmpi.l  #0xf7,%d0
        bne.s   7f
        moveq   #0,%d5
        move.b  7(%a2),%d5                        | sub
        beq.s   7f
        moveq   #0x3f,%d0
        cmp.l   %d0,%d5
        bhi.s   7f
        jsr     ghr_run
        bra.s   9f
7:      addq.l  #1,S_CNT+12(%a3)                  | malformed: no reply
9:      clr.b   S_BUSY(%a3)
        bra.s   99f
8:      move.w  %d1,%sr
        addq.l  #1,S_CNT+8(%a3)                   | one is being handled: dropped
99:     movem.l (%sp),%d2-%d7/%a2-%a5
        lea     40(%sp),%sp
        rts

        | ghr_copy: d0 > 0 bytes from a0 to a1, both advanced.
        .align  2
ghr_copy:
        move.b  (%a0)+,(%a1)+
        subq.l  #1,%d0
        bne.s   ghr_copy
        rts

        | ------------------------------------------------------------------
        | ghr_run: d5 = sub, a2 = msg, d7 = its length, d2 = port, a3 = state. Calls the sub's handler and
        | sends the reply. A handler gets a5 = its argument bytes, d6 = their number, a1 = G_RAW, d3 = 0,
        | d4 = 4; it leaves the payload at G_RAW, its length in d3 and the status in d4. It may change d0, d1,
        | d3, d4, d7, a0 and a1, nothing else.
        | ------------------------------------------------------------------
        .section .gr2,"ax"
        .align  2
ghr_run:
        lea     G_OUT,%a4
        move.l  #0xf000203c,(%a4)
        moveq   #0x40,%d0
        or.l    %d5,%d0
        ori.l   #0x06005f00,%d0
        move.l  %d0,4(%a4)                        | 06 00 5F sub|40
        move.b  8(%a2),8(%a4)                     | seq
        lea     9(%a2),%a5
        moveq   #-10,%d6
        add.l   %d7,%d6
        moveq   #0,%d3
        moveq   #4,%d4                            | UNKNOWN unless a handler answers
        lea     G_RAW,%a1
        moveq   #NSUB-1,%d0
        cmp.l   %d0,%d5
        bhi.s   1f
        lea     ghr_tab,%a0
        move.l  (%a0,%d5.l*4),%d0
        beq.s   1f
        move.l  %d0,%a0
        jsr     (%a0)
1:      jmp     ghr_run_tail

        .section .gr14,"ax"
        .align  2
ghr_run_tail:                                     | the handler's status, payload and the send
        move.b  %d4,9(%a4)
        lea     G_RAW,%a0
        lea     10(%a4),%a1
        move.l  %d3,%d0
        jsr     ghr_pack
        move.b  #0xf7,(%a1)+
        move.l  %a1,%d0
        sub.l   %a4,%d0
        move.l  %d2,-(%sp)                        | port
        clr.l   -(%sp)                            | no abort flag
        move.l  %d0,-(%sp)
        move.l  %a4,-(%sp)
        jsr     sysex_send
        lea     16(%sp),%sp
        tst.b   %d0
        beq.s   2f
        addq.l  #1,S_CNT+4(%a3)
2:      rts

        | ------------------------------------------------------------------
        | ghr_pack: d0 bytes from a0, Elektron 8/7 (a byte of high bits, bit 6 = the first, then up to seven
        | low parts), to a1; a1 ends past the last byte. Changes d0, d1, a0.
        | ------------------------------------------------------------------
        .section .gr3,"ax"
        .align  2
ghr_pack:
        lea     -12(%sp),%sp
        movem.l %d2-%d3/%a2,(%sp)
1:      tst.l   %d0
        ble.s   9f
        move.l  %a1,%a2
        clr.b   (%a1)+
        moveq   #0,%d2
        moveq   #0x40,%d3
2:      move.b  (%a0)+,%d1
        bpl.s   3f
        or.l    %d3,%d2
3:      bclr    #7,%d1
        move.b  %d1,(%a1)+
        lsr.l   #1,%d3
        subq.l  #1,%d0
        beq.s   4f
        tst.l   %d3
        bne.s   2b
4:      move.b  %d2,(%a2)
        bra.s   1b
9:      movem.l (%sp),%d2-%d3/%a2
        lea     12(%sp),%sp
        rts

        | ghr_inject: the panel message (header d1, data d0) through the panel parser, as the panel UART's
        | interrupt feeds it. Every interrupt must be masked. Changes d0, d1, a0, a1.
        .align  2
ghr_inject:
        move.l  %d0,-(%sp)                        | ours: the callee owns only its argument slot
        move.l  %d1,-(%sp)
        jsr     panel_parse_byte
        addq.l  #4,%sp
        move.l  (%sp),%d0
        move.l  %d0,-(%sp)
        jsr     panel_parse_byte
        addq.l  #8,%sp
        addq.l  #1,S_CNT+16(%a3)
        rts

        | ------------------------------------------------------------------
        | 01 PING: protocol 1, version 1.0, the command byte, the mods this image carries (bit n = row n of
        | ghr_mods: its hook site no longer holds stock bytes), the six counters, the tag.
        | ------------------------------------------------------------------
        .section .gr4,"ax"
        .align  2
ghr_ping:
        moveq   #0,%d3
        moveq   #1,%d4
        lea     ghr_mods,%a0
1:      move.l  (%a0)+,%d0
        beq.s   2f
        move.l  %d0,%a1
        move.l  (%a1),%d1
        cmp.l   (%a0)+,%d1
        beq.s   3f
        or.l    %d4,%d3
3:      add.l   %d4,%d4
        bra.s   1b
2:      lea     G_RAW,%a1
        move.l  #0x0101005f,(%a1)+
        move.l  %d3,(%a1)+
        lea     S_CNT(%a3),%a0
        moveq   #6,%d0
4:      move.l  (%a0)+,(%a1)+
        subq.l  #1,%d0
        bne.s   4b
        lea     ghr_tag,%a0
5:      move.b  (%a0)+,(%a1)+
        bne.s   5b
        move.l  %a1,%d3
        subi.l  #G_RAW,%d3
        moveq   #0,%d4
        rts

        | ------------------------------------------------------------------
        | The tables: the handlers by sub, the mods' hook sites with their first stock long, the tag.
        | ------------------------------------------------------------------
        .section .gr5,"a"
        .align  2
ghr_tab:
        .long   0, ghr_ping, ghr_status, ghr_key, ghr_enc, ghr_screen, ghr_read
        .long   0, 0, 0, 0, 0, ghr_release
ghr_ranges:                                       | READ: [from, to)
        .long   0x00000000, 0x00800000            | the NOR flash
        .long   0x20000000, 0x20200000            | the CS1 memory
        .long   0x40000000, 0x48000000            | DDR, cached and its uncached alias
        .long   0x80000000, 0x80010000            | the SRAM

        .section .gr6,"a"
        .align  2
ghr_mods:                                         | bit n: row n
        .long   0x400b9818, 0x4e56ffa8            | 0  0001 scale lock
        .long   0x40077fa0, 0x41f2b800            | 1  0002 303 slide
        .long   0x40009028, 0x4fefffe0            | 2  0006 FX slot
        .long   0x400f48ee, 0x2012aa00            | 3  0007 digital path
        .long   0x400bee4a, 0x4fef000c            | 4  0008 pages
        .long   0x400f8400, 0x71398000            | 5  0010 wave oscillator
        .long   0x400c435a, 0x4eb94005            | 6  0011 random track
        .long   0x400fd33a, 0x4ab9415c            | 7  0012 resonance limit
        .long   0x400ff346, 0x20398000            | 8  0013 poly legato
        .long   0x401ec2b4, 0x40063826            | 9  0014 GHOST REMOTE (the SysEx slot)
        .long   0
ghr_tag:
        .asciz  "GHOST REMOTE A4 1.0"

        | ------------------------------------------------------------------
        | 02 STATUS, layout 1 (48 B): 0 layout, 1 active pattern (0..127), 2 the panel parser's header
        | flag (0 = between a header and its data), 3 reserved, 4 the sequencer's run word (0 stopped,
        | 1 playing), 8 the active kit, 12 the 11 key groups as the parser has them, 23 the groups' keys
        | KEY holds down, 34 the 14 LED groups.
        | ------------------------------------------------------------------
        .section .gr7,"ax"
        .align  2
ghr_status:
        move.b  #1,(%a1)
        move.b  active_pattern,%d0
        move.b  %d0,1(%a1)
        move.b  panel_ready,%d0
        move.b  %d0,2(%a1)
        clr.b   3(%a1)
        move.l  seq_running,%d0
        move.l  %d0,4(%a1)
        move.l  active_kit_nr,%d0
        move.l  %d0,8(%a1)
        lea     12(%a1),%a1
        lea     key_masks,%a0
        moveq   #GROUPS,%d0
        jsr     ghr_copy
        lea     S_HELD(%a3),%a0
        moveq   #GROUPS,%d0
        jsr     ghr_copy
        lea     led_state,%a0
        moveq   #14,%d0
        jsr     ghr_copy
        moveq   #48,%d3
        moveq   #0,%d4
        rts

        | ------------------------------------------------------------------
        | 03 KEY: code (group * 8 + bit, below 80), edge (1 down, 0 up). The group's mask as the parser
        | last had it, with this key's bit set or cleared, goes in as the panel's own `2g mask`.
        | Reply: code, edge, the mask sent. BUSY (no payload) while the parser waits for a data byte.
        | ------------------------------------------------------------------
        .section .gr8,"ax"
        .align  2
ghr_key:
        moveq   #2,%d4
        moveq   #2,%d0
        cmp.l   %d0,%d6
        bne.s   9f
        mvz.b   (%a5),%d0
        moveq   #KEYS-1,%d1
        cmp.l   %d1,%d0
        bhi.s   9f
        mvz.b   1(%a5),%d1
        moveq   #1,%d3
        cmp.l   %d3,%d1
        bhi.s   9f
        move.b  %d0,(%a1)
        move.b  %d1,1(%a1)
        move.l  %d0,%d3
        lsr.l   #3,%d3                            | group
        moveq   #7,%d4
        and.l   %d4,%d0
        moveq   #1,%d4
        lsl.l   %d0,%d4                           | its bit
        jmp     ghr_key2
9:      moveq   #0,%d3
        rts

        .section .gr9,"ax"
        .align  2
ghr_key2:                                         | d1 edge, d3 group, d4 bit
        lea     key_masks,%a0
        adda.l  %d3,%a0
        lea     S_HELD(%a3),%a1
        adda.l  %d3,%a1
        move.w  %sr,%d7
        move.w  #0x2700,%sr
        tst.b   panel_ready
        beq.s   8f
        mvz.b   (%a0),%d0                         | the group as the parser last had it
        tst.l   %d1
        beq.s   1f
        or.l    %d4,%d0
        mvz.b   (%a1),%d1
        or.l    %d4,%d1
        bra.s   2f
1:      not.l   %d4
        and.l   %d4,%d0
        mvz.b   (%a1),%d1
        and.l   %d4,%d1
2:      move.b  %d1,(%a1)
        move.b  %d0,G_RAW+2
        moveq   #0x20,%d1
        or.l    %d3,%d1
        jsr     ghr_inject
        move.w  %d7,%sr
        moveq   #3,%d3
        moveq   #0,%d4
        rts
8:      move.w  %d7,%sr
        addq.l  #1,S_CNT+20(%a3)
        moveq   #0,%d3
        moveq   #1,%d4
        rts

        | ------------------------------------------------------------------
        | 04 ENC: the encoder's wire channel (0..10; the OS's knob table 0x401ebdf8: B C D E G H I J A F
        | LEVEL), delta (signed 7-bit, not 0). In as the panel's own `3c delta`. Reply: channel, delta.
        | ------------------------------------------------------------------
        .section .gr10,"ax"
        .align  2
ghr_enc:
        moveq   #2,%d4
        moveq   #2,%d0
        cmp.l   %d0,%d6
        bne.s   9f
        mvz.b   (%a5),%d1
        moveq   #KNOBS-1,%d0
        cmp.l   %d0,%d1
        bhi.s   9f
        mvz.b   1(%a5),%d0
        beq.s   9f
        move.b  %d1,(%a1)
        move.b  %d0,1(%a1)
        btst    #6,%d0
        beq.s   1f
        ori.l   #0x80,%d0                         | -64..-1
1:      ori.l   #0x30,%d1
        move.w  %sr,%d7
        move.w  #0x2700,%sr
        tst.b   panel_ready
        beq.s   8f
        jsr     ghr_inject
        move.w  %d7,%sr
        moveq   #2,%d3
        moveq   #0,%d4
9:      rts
8:      move.w  %d7,%sr
        addq.l  #1,S_CNT+20(%a3)
        moveq   #1,%d4
        rts

        | ------------------------------------------------------------------
        | 05 SCREEN: the frame on glass (fb_glass: 4 pages x 128 columns, byte = page + 4 * column, page 0
        | the bottom band, 122 columns on glass), then the 14 LED groups and their 14 blink masks (540 B).
        | ------------------------------------------------------------------
        .section .gr11,"ax"
        .align  2
ghr_screen:
        move.l  fb_glass,%a0
        move.l  #512,%d0
        jsr     ghr_copy
        lea     led_state,%a0
        moveq   #14,%d0
        jsr     ghr_copy
        lea     led_blink,%a0
        moveq   #14,%d0
        jsr     ghr_copy
        move.l  #540,%d3
        moveq   #0,%d4
        rts

        | ------------------------------------------------------------------
        | 0C RELEASE: every key KEY put down and no KEY let up goes up (its group's mask as the parser has
        | it, without them). Reply: the 11 groups' held masks as they were. BUSY as KEY.
        | ------------------------------------------------------------------
        .section .gr15,"ax"
        .align  2
ghr_release:
        lea     S_HELD(%a3),%a0
        moveq   #GROUPS,%d0
        jsr     ghr_copy
        move.w  %sr,%d7
        move.w  #0x2700,%sr
        tst.b   panel_ready
        beq.s   8f
        moveq   #0,%d3
1:      lea     S_HELD(%a3),%a0
        mvz.b   (%a0,%d3.l),%d4
        beq.s   2f
        clr.b   (%a0,%d3.l)
        lea     key_masks,%a0
        mvz.b   (%a0,%d3.l),%d0
        not.l   %d4
        and.l   %d4,%d0
        moveq   #0x20,%d1
        or.l    %d3,%d1
        jsr     ghr_inject
2:      addq.l  #1,%d3
        moveq   #GROUPS,%d0
        cmp.l   %d0,%d3
        bne.s   1b
        move.w  %d7,%sr
        moveq   #GROUPS,%d3
        moveq   #0,%d4
        rts
8:      move.w  %d7,%sr
        addq.l  #1,S_CNT+20(%a3)
        moveq   #0,%d3
        moveq   #1,%d4
        rts

        | ------------------------------------------------------------------
        | 06 READ: address (5 x 7 bits, MSB first, the first below 0x10), length (2 x 7 bits, 1..256), all
        | inside one of ghr_ranges (no peripheral, no DSP port). Reply: the address, then the bytes.
        | ------------------------------------------------------------------
        .section .gr12,"ax"
        .align  2
ghr_read:
        moveq   #2,%d4
        moveq   #7,%d0
        cmp.l   %d0,%d6
        bne.s   9f
        moveq   #15,%d0
        cmp.b   (%a5),%d0
        bcs.s   9f
        moveq   #0,%d0
        moveq   #5,%d1
        move.l  %a5,%a0
1:      lsl.l   #7,%d0
        mvz.b   (%a0)+,%d7
        or.l    %d7,%d0
        subq.l  #1,%d1
        bne.s   1b
        mvz.b   (%a0)+,%d1
        lsl.l   #7,%d1
        mvz.b   (%a0),%d7
        or.l    %d7,%d1                           | length
        beq.s   9f
        cmpi.l  #256,%d1
        bhi.s   9f
        jmp     ghr_read2
9:      rts

        .section .gr13,"ax"
        .align  2
ghr_read2:                                        | d0 address, d1 length
        lea     ghr_ranges,%a0
        moveq   #4,%d3
1:      cmp.l   (%a0)+,%d0
        bcs.s   2f
        move.l  (%a0),%d7
        sub.l   %d1,%d7
        cmp.l   %d7,%d0
        bls.s   3f
2:      addq.l  #4,%a0
        subq.l  #1,%d3
        bne.s   1b
        rts                                       | BAD (d3 = 0)
3:      lea     G_RAW,%a1
        move.l  %d0,(%a1)+
        move.l  %d0,%a0
        move.l  %d1,%d0
        jsr     ghr_copy
        addq.l  #4,%d1
        move.l  %d1,%d3
        moveq   #0,%d4
        rts
