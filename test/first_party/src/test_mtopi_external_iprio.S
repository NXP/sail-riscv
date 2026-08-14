.global main
main:
    # Self-checking test for the AIA machine top-interrupt CSR (mtopi) in
    # the iprio reporting mode (Smaia.iprio_reporting = Iprio_Iprio, set
    # via the aia_external_iprio.json config override).
    #
    # In this mode the machine external interrupt (MEI) reports the IPRIO
    # configured on the external interrupt controller (the Simple
    # Interrupt Generator). An external controller priority is always a
    # live value (1..255): a priority of 0 is the controller's "no
    # interrupt" sentinel and is illegal, so the Simple Interrupt
    # Generator legalizes a written priority of 0 to 1 (WARL). A
    # non-external major interrupt (with a read-only-zero iprio) reports
    # 0x00 if it outranks the machine external interrupt, else 0xFF. MEI
    # is the highest-priority interrupt in the AIA default order, so MSI
    # ranks below it and thus reports 0xFF.

    #
    # The test also exercises priority arbitration between two pending
    # major interrupts: with both MEI and MSI pending mtopi must report
    # the higher-priority one (MEI); once MEI is cleared, MSI becomes the
    # top interrupt.

    .set CSR_MTOPI, 0xFB0
    .set CSR_MIE,   0x304

    .set SIG_BASE,            0xC000000
    .set SIG_PLATFORM_OFFSET, 4
    .set SIG_MTOPEI_CFG_OFF,  8

    .set SIG_MSI, (1 << 3)
    .set SIG_MEI, (1 << 11)
    .set SIG_SET, (1 << 31)

    .set MIE_MSIE, (1 << 3)
    .set MIE_MEIE, (1 << 11)
    .set MEI_IID,  11
    .set MSI_IID,  3

    mv t6, ra

    la a0, SIG_BASE

    # Enable MEI and MSI in mie.
    li t0, MIE_MEIE | MIE_MSIE
    csrs CSR_MIE, t0

    # --- Case 1: controller priority 0x42 passes through unchanged. ---
    li t0, (5 << 16) | 0x42
    sw t0, SIG_MTOPEI_CFG_OFF(a0)
    li t0, SIG_SET | SIG_MEI
    sw t0, SIG_PLATFORM_OFFSET(a0)

    csrr t0, CSR_MTOPI
    # IPRIO (bits 7:0) should equal the configured 0x42.
    andi t1, t0, 0xFF
    li t2, 0x42
    bne t1, t2, fail
    # IID (bits 27:16) should equal MEI (11). Bits above the IID field
    # read as zero, so a shift alone isolates the identity.
    srli t1, t0, 16
    li t2, MEI_IID
    bne t1, t2, fail

    # --- Case 2: assert an additional major interrupt (MSI). MEI still
    # outranks MSI in the AIA default order, so mtopi must keep reporting
    # MEI with the same IPRIO (0x42). This proves the higher-priority
    # interrupt wins the arbitration when two are pending. ---
    li t0, SIG_SET | SIG_MSI
    sw t0, SIG_PLATFORM_OFFSET(a0)

    csrr t0, CSR_MTOPI
    andi t1, t0, 0xFF
    li t2, 0x42
    bne t1, t2, fail
    srli t1, t0, 16
    li t2, MEI_IID
    bne t1, t2, fail

    # --- Case 3: clear MEI, leaving MSI pending. mtopi now reports MSI.
    # MSI is a non-external interrupt with a read-only-zero iprio that
    # ranks below the machine external interrupt, so its IPRIO is 0xFF. ---
    li t0, SIG_MEI
    sw t0, SIG_PLATFORM_OFFSET(a0)

    csrr t0, CSR_MTOPI
    andi t1, t0, 0xFF
    li t2, 0xFF
    bne t1, t2, fail
    srli t1, t0, 16
    li t2, MSI_IID
    bne t1, t2, fail


    # Clear MSI; mtopi reads as zero.
    li t0, SIG_MSI
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
