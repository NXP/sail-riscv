.global main
main:
    # Self-checking test for the combined IMSIC + APLIC configuration, where
    # the IMSIC's per-privilege eidelivery register acts as a 3-way selector
    # for which controller delivers external interrupts to the hart:
    #
    #   eidelivery = 0x00000001 -> the IMSIC interrupt file delivers.
    #   eidelivery = 0x40000000 -> the APLIC delivers directly.
    #   eidelivery = 0x00000000 -> nothing is delivered.
    #
    # Both controllers are set up with a pending, enabled interrupt at the
    # machine level. The selector is then walked through all three values and
    # the machine external interrupt pending bit (mip.MEIP) plus mtopei are
    # checked to confirm that only the selected controller drives delivery.

    # Indirect CSR / IMSIC addresses.
    .set CSR_MISELECT, 0x350
    .set CSR_MIREG,    0x351
    .set CSR_MTOPEI,   0x35C
    .set CSR_MIP,      0x344
    .set CSR_MIE,      0x304

    .set SEL_EIDELIVERY,  0x70
    .set SEL_EIP0,        0x80
    .set SEL_EIE0,        0xC0

    # eidelivery selector values.
    .set EIDELIVERY_IMSIC, 0x00000001
    .set EIDELIVERY_APLIC, 0x40000000

    # IMSIC MMIO machine interrupt file (imsic base 0x2100000).
    .set IMSIC_BASE,   0x2100000
    .set IMSIC_M_FILE, IMSIC_BASE
    .set SETEIPNUM_LE, 0x0

    # IMSIC identity delivered by the IMSIC path.
    .set IMSIC_ID, 5

    # APLIC domain 0 (machine) control region base (aplic base 0xD000000).
    .set APLIC_M_BASE, 0xD000000
    .set OFF_DOMAINCFG, 0x0000
    .set OFF_SOURCECFG1, 0x0004
    .set OFF_SETIPNUM,  0x1CDC
    .set OFF_SETIENUM,  0x1EDC
    .set OFF_TARGET1,   0x3004
    .set OFF_IDELIVERY, 0x4000
    .set DOMAINCFG_IE, (1 << 8)
    .set SM_EDGE1, 4
    .set APLIC_SRC, 1
    .set TARGET_PRIO, 1

    # mip.MEIP is bit 11; mie.MEIE is bit 11.
    .set MIP_MEIP, (1 << 11)
    .set MIE_MEIE, (1 << 11)

    mv t6, ra

    # Enable MEI in mie so MEIP counts as pending-and-enabled.
    li t0, MIE_MEIE
    csrs CSR_MIE, t0

    # ---------------------------------------------------------------------
    # IMSIC machine file setup: enable identity IMSIC_ID and make it pending.
    # Start with delivery disabled (eidelivery = 0) so nothing is delivered
    # until we select a controller below.
    # ---------------------------------------------------------------------
    li t0, SEL_EIDELIVERY
    csrw CSR_MISELECT, t0
    li t0, 0
    csrw CSR_MIREG, t0

    li t0, SEL_EIE0
    csrw CSR_MISELECT, t0
    li t0, (1 << IMSIC_ID)
    csrw CSR_MIREG, t0

    li a0, IMSIC_M_FILE
    li t0, IMSIC_ID
    sw t0, SETEIPNUM_LE(a0)

    # ---------------------------------------------------------------------
    # APLIC domain 0 setup: source APLIC_SRC pending, enabled, delivering.
    # ---------------------------------------------------------------------
    li a0, (APLIC_M_BASE + OFF_DOMAINCFG)
    li t0, DOMAINCFG_IE
    sw t0, 0(a0)

    li a0, (APLIC_M_BASE + OFF_SOURCECFG1)
    li t0, SM_EDGE1
    sw t0, 0(a0)

    li a0, (APLIC_M_BASE + OFF_TARGET1)
    li t0, TARGET_PRIO
    sw t0, 0(a0)

    li a0, (APLIC_M_BASE + OFF_SETIENUM)
    li t0, APLIC_SRC
    sw t0, 0(a0)

    li a0, (APLIC_M_BASE + OFF_IDELIVERY)
    li t0, 1
    sw t0, 0(a0)

    li a0, (APLIC_M_BASE + OFF_SETIPNUM)
    li t0, APLIC_SRC
    sw t0, 0(a0)

    # ---------------------------------------------------------------------
    # eidelivery = 0: nothing is delivered even though both controllers have
    # a pending interrupt.
    # ---------------------------------------------------------------------
    li t3, MIP_MEIP
    csrr t0, CSR_MIP
    and t0, t0, t3
    bnez t0, fail

    csrr t0, CSR_MTOPEI
    bnez t0, fail

    # ---------------------------------------------------------------------
    # eidelivery = 1 (IMSIC): mip.MEIP is asserted and mtopei reports the
    # IMSIC identity.
    # ---------------------------------------------------------------------
    li t0, SEL_EIDELIVERY
    csrw CSR_MISELECT, t0
    li t0, EIDELIVERY_IMSIC
    csrw CSR_MIREG, t0

    li t3, MIP_MEIP
    csrr t0, CSR_MIP
    and t0, t0, t3
    beqz t0, fail

    csrr t0, CSR_MTOPEI
    srli t1, t0, 16
    andi t1, t1, 0x7FF
    li t2, IMSIC_ID
    bne t1, t2, fail

    # ---------------------------------------------------------------------
    # eidelivery = 0x40000000 (APLIC): mip.MEIP is asserted (driven by the
    # APLIC now), and mtopei reads zero because the IMSIC file is no longer
    # delivering.
    # ---------------------------------------------------------------------
    li t0, SEL_EIDELIVERY
    csrw CSR_MISELECT, t0
    li t0, EIDELIVERY_APLIC
    csrw CSR_MIREG, t0

    # Confirm the selector legalized to the APLIC value (WARL).
    csrr t0, CSR_MIREG
    li t2, EIDELIVERY_APLIC
    bne t0, t2, fail

    li t3, MIP_MEIP
    csrr t0, CSR_MIP
    and t0, t0, t3
    beqz t0, fail

    csrr t0, CSR_MTOPEI
    bnez t0, fail

    # ---------------------------------------------------------------------
    # Back to eidelivery = 0: delivery is disabled again.
    # ---------------------------------------------------------------------
    li t0, SEL_EIDELIVERY
    csrw CSR_MISELECT, t0
    li t0, 0
    csrw CSR_MIREG, t0

    li t3, MIP_MEIP
    csrr t0, CSR_MIP
    and t0, t0, t3
    bnez t0, fail

    csrr t0, CSR_MTOPEI
    bnez t0, fail

pass:
    li a0, 0
    mv ra, t6
    ret
fail:
    li a0, 1
    mv ra, t6
    ret
