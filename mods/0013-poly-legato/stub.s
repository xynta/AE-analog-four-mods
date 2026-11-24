        | Mod 0013 - poly legato. See mod.toml.
        |
        | Two detours in the audio interrupt, both once per note or voice (never per sample),
        | both reading cached memory only (below 0x44000000).

        .include "symbols.inc"

        .equ    ENV_BITS,   0x1c0                 | the three envelope retrigger bits
        .equ    EV_SIZE,    76                    | track_events record
        .equ    EV_COUNT,   4
        .equ    EV_FLAGS,   20
        .equ    VT_SIZE,    16                    | poly_voice_table record
        .equ    VT_AGE,     0
        .equ    VT_TRACK,   12
        .equ    VOICES,     4

        .text

        | ------------------------------------------------------------------
        | The voice pick 0x400ff284, poly path, after the ages were advanced, at
        | `movel 0x80003d2c,%d0` (0x400ff346). d2 = track, d3 = voices granted to
        | it, a2 = note, d5 = slot. d0, d1, d4, d7, a0, a1 are free here (every
        | mode path sets d4 and d7 before using them).
        | A legato note (one note, no envelope bit) goes to the granted voice that
        | last booked this track (the smallest age): stock's booking tail
        | 0x400ff450 with d4 = that voice, as the REASSIGN rule does. Anything
        | else, or no such voice: stock.
        | ------------------------------------------------------------------
        .align  2
legato_pick:
        move.l  poly_mode,%d0
        moveq   #3,%d1
        cmp.l   %d1,%d0
        beq.s   9f                                | unison: stock
        move.l  %d2,%d1
        mulu.w  #EV_SIZE,%d1
        lea     track_events,%a0
        move.l  #ENV_BITS,%d0
        and.l   EV_FLAGS(%a0,%d1.l),%d0
        bne.s   9f                                | the note retriggers: stock
        moveq   #1,%d0
        cmp.l   EV_COUNT(%a0,%d1.l),%d0
        bne.s   9f                                | a chord: stock
        moveq   #-1,%d4                           | the voice found, none yet
        moveq   #0,%d1                            | v
        lea     poly_voice_table,%a0
1:      btst    %d1,%d3                           | granted to this track?
        beq.s   2f
        cmp.l   VT_TRACK(%a0),%d2                 | booked by this track?
        bne.s   2f
        move.l  VT_AGE(%a0),%d0
        tst.l   %d4
        bmi.s   3f
        cmp.l   %d7,%d0
        bge.s   2f                                | not newer than the one found
3:      move.l  %d1,%d4
        move.l  %d0,%d7
2:      addq.l  #1,%d1
        lea     VT_SIZE(%a0),%a0
        moveq   #VOICES,%d0
        cmp.l   %d1,%d0
        bne.s   1b
        tst.l   %d4
        bmi.s   9f                                | none: stock
        jmp     alloc_reassign
9:      moveq   #1,%d1                            | as stock had it (0x400ff344)
        move.l  poly_mode,%d0                     | displaced
        jmp     alloc_mode_resume

        | ------------------------------------------------------------------
        | The per-voice flags, at `andil #-524305,%d4` (0x400fc578): stock clears
        | the slide bit 4 and bit 19 on every poly voice. A legato note (no
        | envelope bit) keeps its slide bit, so the voice 0013 kept glides; bit
        | 19 goes as in stock. d0 is free.
        | ------------------------------------------------------------------
        .align  2
legato_glide:
        move.l  %d4,%d0
        andi.l  #ENV_BITS,%d0
        bne.s   1f
        bclr    #19,%d4
        jmp     voice_flags_resume
1:      andi.l  #0xfff7ffef,%d4                   | displaced
        jmp     voice_flags_resume
