.global main
main:
    # Self-checking test for the Smcsps machine-level Conditional Stack
    # Pointer Swap instructions (mcspspush / mcspspop) and the mspcs and
    # mistatus CSRs. The toolchain does not know these instructions yet, so
    # they are emitted as raw .word encodings:
    #   mcspspush  = 0x30910173
    #   mcspspop   = 0x30C10173
    # CSR numbers: mspcs = 0x349, mistatus = 0x346.
    # mistatus.sppush is bit 6 (0x40), mistatus.psppush is bit 7 (0x80).

    mv s0, ra                 # save return address
    mv s1, sp                 # save the real stack pointer

    # --- Push with sppush = 0: no swap should occur. ---
    li t0, 0x12345000
    csrw 0x349, t0            # mspcs = 0x12345000
    csrw 0x346, zero          # mistatus = 0 (sppush = 0)
    li sp, 0x1ABCD000         # set a known "current sp"
    .word 0x30910173          # mcspspush
    li t1, 0x1ABCD000
    bne sp, t1, fail          # sp must be unchanged
    csrr t2, 0x349
    bne t2, t0, fail          # mspcs must be unchanged

    # --- Push with sppush = 1: swap sp <-> mspcs. ---
    li t3, 0x40               # sppush bit
    csrw 0x346, t3
    .word 0x30910173          # mcspspush
    li t1, 0x12345000
    bne sp, t1, fail          # sp now holds old mspcs
    csrr t2, 0x349
    li t1, 0x1ABCD000
    bne t2, t1, fail          # mspcs now holds old sp
    csrr t2, 0x346
    li t1, 0x80               # psppush set, sppush cleared
    bne t2, t1, fail

    # --- Pop with psppush = 1: swap back. ---
    .word 0x30C10173          # mcspspop
    li t1, 0x1ABCD000
    bne sp, t1, fail          # sp restored
    csrr t2, 0x349
    li t1, 0x12345000
    bne t2, t1, fail          # mspcs restored
    csrr t2, 0x346
    li t1, 0x40               # sppush set, psppush cleared
    bne t2, t1, fail

pass:
    mv sp, s1
    li a0, 0
    mv ra, s0
    ret
fail:
    mv sp, s1
    li a0, 1
    mv ra, s0
    ret
