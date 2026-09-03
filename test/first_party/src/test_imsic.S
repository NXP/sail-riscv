.global main
main:
    # Self-checking test for the IMSIC (Incoming MSI Controller) machine-
    # and supervisor-level interrupt files.
    #
    # Both delivery paths are exercised for each file:
    #   1. MMIO delivery: a write to the file's memory-mapped seteipnum_le
    #      register sets the pending (eip) bit for an identity.
    #   2. Direct assertion: the eip bit is set directly through the
    #      indirect CSR interface (miselect/mireg, siselect/sireg).
    #
    # After each delivery the top interrupt is read from xtopei (mtopei /
    # stopei), checked, then claimed (a write to xtopei clears the top
    # eip bit) and re-checked to be zero.
    #
    # The supervisor file is accessed from M-mode via siselect/sireg and
    # stopei, so no privilege switch is required.

    # Indirect CSR addresses.
    .set CSR_MISELECT, 0x350
    .set CSR_MIREG,    0x351
    .set CSR_SISELECT, 0x150
    .set CSR_SIREG,    0x151
    .set CSR_MTOPEI,   0x35C
    .set CSR_STOPEI,   0x15C

    # IMSIC interrupt-file *iselect layout.
    .set SEL_EIDELIVERY,  0x70
    .set SEL_EITHRESHOLD, 0x72
    .set SEL_EIP0,        0x80
    .set SEL_EIE0,        0xC0

    # IMSIC MMIO interrupt files (see platform.imsic.base in imsic.json).
    .set IMSIC_BASE,   0x2100000

    .set IMSIC_M_FILE, IMSIC_BASE
    .set IMSIC_S_FILE, (IMSIC_BASE + 0x1000)
    .set SETEIPNUM_LE, 0x0

    mv t6, ra

    # ---------------------------------------------------------------------
    # Machine interrupt file setup: enable delivery and enable identities.
    # ---------------------------------------------------------------------

    # eidelivery = 1
    li t0, SEL_EIDELIVERY
    csrw CSR_MISELECT, t0
    li t0, 1
    csrw CSR_MIREG, t0

    # eie0 |= (1 << 5) | (1 << 10) : enable identities 5 and 10.
    li t0, SEL_EIE0
    csrw CSR_MISELECT, t0
    li t0, (1 << 5) | (1 << 10)
    csrw CSR_MIREG, t0

    # With nothing pending, mtopei reads as zero.
    csrr t0, CSR_MTOPEI
    bnez t0, fail

    # --- M file, MMIO delivery of identity 5 ---
    li a0, IMSIC_M_FILE
    li t0, 5
    sw t0, SETEIPNUM_LE(a0)

    # mtopei: identity in bits 26:16, priority (== identity) in bits 10:0.
    csrr t0, CSR_MTOPEI
    srli t1, t0, 16
    andi t1, t1, 0x7FF
    li t2, 5
    bne t1, t2, fail
    andi t1, t0, 0x7FF
    li t2, 5
    bne t1, t2, fail

    # Claim it and confirm it is cleared.
    csrw CSR_MTOPEI, zero
    csrr t0, CSR_MTOPEI
    bnez t0, fail

    # --- M file, direct eip assertion of identity 10 ---
    li t0, SEL_EIP0
    csrw CSR_MISELECT, t0
    li t0, (1 << 10)
    csrw CSR_MIREG, t0

    csrr t0, CSR_MTOPEI
    srli t1, t0, 16
    andi t1, t1, 0x7FF
    li t2, 10
    bne t1, t2, fail

    csrw CSR_MTOPEI, zero
    csrr t0, CSR_MTOPEI
    bnez t0, fail

    # ---------------------------------------------------------------------
    # Supervisor interrupt file setup (accessed from M-mode).
    # ---------------------------------------------------------------------

    # eidelivery = 1
    li t0, SEL_EIDELIVERY
    csrw CSR_SISELECT, t0
    li t0, 1
    csrw CSR_SIREG, t0

    # eie0 |= (1 << 7) | (1 << 12) : enable identities 7 and 12.
    li t0, SEL_EIE0
    csrw CSR_SISELECT, t0
    li t0, (1 << 7) | (1 << 12)
    csrw CSR_SIREG, t0

    csrr t0, CSR_STOPEI
    bnez t0, fail

    # --- S file, MMIO delivery of identity 7 ---
    li a0, IMSIC_S_FILE
    li t0, 7
    sw t0, SETEIPNUM_LE(a0)

    csrr t0, CSR_STOPEI
    srli t1, t0, 16
    andi t1, t1, 0x7FF
    li t2, 7
    bne t1, t2, fail
    andi t1, t0, 0x7FF
    li t2, 7
    bne t1, t2, fail

    csrw CSR_STOPEI, zero
    csrr t0, CSR_STOPEI
    bnez t0, fail

    # --- S file, direct eip assertion of identity 12 ---
    li t0, SEL_EIP0
    csrw CSR_SISELECT, t0
    li t0, (1 << 12)
    csrw CSR_SIREG, t0

    csrr t0, CSR_STOPEI
    srli t1, t0, 16
    andi t1, t1, 0x7FF
    li t2, 12
    bne t1, t2, fail

    csrw CSR_STOPEI, zero
    csrr t0, CSR_STOPEI
    bnez t0, fail

    # ---------------------------------------------------------------------
    # eithreshold gate: identities >= threshold are masked.
    # ---------------------------------------------------------------------

    # Set M eithreshold = 10, so identity 10 (and above) is not eligible.
    li t0, SEL_EITHRESHOLD
    csrw CSR_MISELECT, t0
    li t0, 10
    csrw CSR_MIREG, t0

    # Assert eip for identity 10 (already enabled in eie0).
    li t0, SEL_EIP0
    csrw CSR_MISELECT, t0
    li t0, (1 << 10)
    csrw CSR_MIREG, t0

    # Blocked by threshold: mtopei reads as zero.
    csrr t0, CSR_MTOPEI
    bnez t0, fail

    # Also assert identity 5 (< threshold): it should be reported.
    li t0, SEL_EIP0
    csrw CSR_MISELECT, t0
    li t0, (1 << 5) | (1 << 10)
    csrw CSR_MIREG, t0

    csrr t0, CSR_MTOPEI
    srli t1, t0, 16
    andi t1, t1, 0x7FF
    li t2, 5
    bne t1, t2, fail

pass:
    li a0, 0
    mv ra, t6
    ret
fail:
    li a0, 1
    mv ra, t6
    ret
