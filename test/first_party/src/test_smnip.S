.global main
main:
    # Self-checking test for the Smnip nested interrupt-preemption extension.
    #
    # Smnip adds:
    #   mithreshold (0x347) - interrupt-enable threshold, field iprio[8:0];
    #   mtopsi      (0x348) - top signed interrupt (SIID + IPRIO);
    #   mistatus.pithreshprio (0x346, bits 16:8) - saved threshold;
    #   miconfig.mnipen (bit 2), miconfig.mnipbits (bits 11:8) - indirect at
    #   miselect 0x1000 via Smcsrind.
    #
    # This test checks:
    #   1. mithreshold is WLRL over its 9-bit iprio field;
    #   2. miconfig.mnipen / mnipbits legalize and read back;
    #   3. with mnipen set and a threshold that masks the machine software
    #      interrupt (whose default IPRIO is 0), the pending MSI is NOT taken;
    #      then, after clearing the threshold, the MSI IS taken;
    #   4. on trap entry the previous threshold is saved to
    #      mistatus.pithreshprio and restored by mret.

    mv s0, ra                 # save return address
    mv s1, sp                 # save the real stack pointer

    # --- Set up a direct (non-vectored) trap vector. ---
    la t0, trap_vector
    csrw mtvec, t0

    csrw mideleg, 0           # do not delegate to S-mode

    # =====================================================================
    # 1. mithreshold WLRL over iprio[8:0].
    # =====================================================================
    li t0, 0x1ff              # all 9 bits set
    csrw 0x347, t0
    csrr t1, 0x347
    li t2, 0x1ff
    bne t1, t2, fail

    # High bits above bit 8 must not be retained.
    li t0, 0x3fe00            # bits above [8:0]
    csrw 0x347, t0
    csrr t1, 0x347
    bnez t1, fail

    # =====================================================================
    # 2. miconfig.mnipen (bit 2) and mnipbits (bits 11:8) via indirect CSR.
    #    miselect = 0x350, mireg = 0x351, select value 0x1000.
    # =====================================================================
    li t0, 0x1000
    csrw 0x350, t0            # miselect = miconfig
    # mnipen=1 (bit 2 = 0x4), mnipbits=8 (bits 11:8 = 0x800).
    li t0, 0x804
    csrw 0x351, t0
    csrr t1, 0x351
    li t2, 0x804
    bne t1, t2, fail

    # mnipbits legalizes to at most IPRIOLEN (8): writing 0xf00 (=15) clamps
    # to 8 (0x800). Keep mnipen set.
    li t0, 0xf04
    csrw 0x351, t0
    csrr t1, 0x351
    li t2, 0x804
    bne t1, t2, fail

    # =====================================================================
    # 3. Threshold masking of the machine software interrupt.
    #    A source is masked (disabled) when its reported IPRIO is
    #    numerically >= the (nipbits-masked) threshold. With nipbits=8 the
    #    mask is exact. The MSI (major identity 3) reports a non-zero IPRIO,
    #    so a threshold of 1 (masks IPRIO >= 1) masks the MSI out.
    # =====================================================================
    li t0, 1
    csrw 0x347, t0            # mithreshold.iprio = 1 -> masks IPRIO >= 1


    li s2, 0                  # "handler ran" marker

    li t0, (1 << 3)           # mie.MSIE
    csrw mie, t0
    li t0, 0x8                # MSTATUS_MIE
    csrs mstatus, t0

    # Trigger the MSI via the Simple Interrupt Generator.
    li t0, 0x0C000000
    li t1, (1 << 31) | (1 << 3)   # SIG_SET | SIG_MSI
    sw t1, 4(t0)

    # Give the model a few cycles: the interrupt must remain masked.
    nop
    nop
    nop
    nop
    bnez s2, fail             # handler must NOT have run (masked)

    # =====================================================================
    # 4. Raise the threshold above the max IPRIO so the MSI is now enabled.
    #    A source is masked only when IPRIO >= threshold; the MSI reports a
    #    non-external major-interrupt IPRIO of 255, so a threshold of 0x100
    #    (256, larger than any live IPRIO) enables it. On trap entry
    #    pithreshprio saves the current threshold (0x100) and the threshold
    #    is raised to the claimed IPRIO; mret restores it to 0x100.
    # =====================================================================
    li t0, 0x100
    csrw 0x347, t0            # mithreshold.iprio = 256 -> nothing masked

    # The pending MSI should now fire.
    nop
    nop
    nop
    nop
    beqz s2, fail             # handler must have run

    # After mret, mithreshold must be restored to the pre-trap value (0x100).
    csrr t0, 0x347
    li t1, 0x100
    bne t0, t1, fail

    j pass

.balign 4
.option push
.option norvc
trap_vector:
    # Machine software interrupt handler (direct mode). Verify the cause is
    # the signed MSI identity, clear the source, mark ran, then mret.
    li s2, 1

    # Clear the pending MSI so it does not re-fire after return.
    li t0, 0x0C000000
    li t1, (1 << 3)           # SIG_MSI, bit 31 = 0 -> clear
    sw t1, 4(t0)

    mret
.option pop

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
