.global main
main:
    # Self-checking test for the AIA machine top-interrupt CSR (mtopi).
    #
    # This exercises the default (simplified) IPRIO reporting, where the
    # Smaia.external_iprio config parameter is false: any pending top
    # interrupt reports IPRIO = 1, regardless of the external interrupt
    # controller's configured priority.
    #
    # The Simple Interrupt Generator (SIG) MMIO device is used to raise
    # the machine external interrupt (MEI) via its platform register.

    .set CSR_MTOPI, 0xFB0
    .set CSR_MIE,   0x304

    # SIG device base (see platform.simple_interrupt_generator.base).
    .set SIG_BASE,            0xC000000
    .set SIG_PLATFORM_OFFSET, 4

    .set SIG_MEI, (1 << 11)
    .set SIG_SET, (1 << 31)

    # mie.MEIE is bit 11.
    .set MIE_MEIE, (1 << 11)

    # mtopi field layout: IID in bits 27:16, IPRIO in bits 7:0.
    .set MEI_IID, 11

    mv t6, ra

    # Initially, with no interrupt pending, mtopi reads as zero.
    csrr t0, CSR_MTOPI
    bnez t0, fail

    la a0, SIG_BASE

    # Enable MEI in mie so it counts as pending-and-enabled for mtopi.
    li t0, MIE_MEIE
    csrs CSR_MIE, t0

    # Raise MEI via the SIG platform register.
    li t0, SIG_SET | SIG_MEI
    sw t0, SIG_PLATFORM_OFFSET(a0)

    # mtopi should now report IID = 11 (MEI) and IPRIO = 1.
    csrr t0, CSR_MTOPI

    # Check IPRIO (bits 7:0) == 1.
    andi t1, t0, 0xFF
    li t2, 1
    bne t1, t2, fail

    # Check IID (bits 27:16) == 11. Bits above the IID field read as zero,
    # so a shift alone isolates the identity.
    srli t1, t0, 16
    li t2, MEI_IID
    bne t1, t2, fail

    # Clear MEI; mtopi should read as zero again.
    li t0, SIG_MEI
    sw t0, SIG_PLATFORM_OFFSET(a0)
    csrr t0, CSR_MTOPI
    bnez t0, fail

pass:
    li a0, 0
    mv ra, t6
    ret
fail:
    li a0, 1
    mv ra, t6
    ret
