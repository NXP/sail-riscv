.global main
main:
    # Self-checking test for APLIC direct interrupt delivery (machine domain).
    #
    # The APLIC replaces the Simple Interrupt Generator as the external
    # interrupt controller (see aplic.json config-override). Domain 0 is the
    # machine-level root and drives MEIP; this test drives a source pending
    # through domain 0 and checks that the machine external interrupt is
    # reported by mtopi, and that claimi clears it.
    #
    # No external interrupt wires exist in the model, so the source is made
    # pending via setipnum (valid for an edge-mode source in direct delivery).

    .set CSR_MTOPI, 0xFB0
    .set CSR_MIE,   0x304

    # APLIC domain 0 (machine) control region base (aplic.json: base 0xD000000).
    .set APLIC_M_BASE, 0xD000000

    # Register offsets within a domain control region.
    .set OFF_DOMAINCFG, 0x0000
    .set OFF_SOURCECFG1, 0x0004
    .set OFF_SETIPNUM,  0x1CDC
    .set OFF_SETIENUM,  0x1EDC
    .set OFF_TARGET1,   0x3004
    .set OFF_IDELIVERY, 0x4000
    .set OFF_ITHRESHOLD,0x4008
    .set OFF_TOPI,      0x4018
    .set OFF_CLAIMI,    0x401C

    # domaincfg.IE is bit 8.
    .set DOMAINCFG_IE, (1 << 8)

    # sourcecfg SM = Edge1 (0b100).
    .set SM_EDGE1, 4

    # Source identity used for this test.
    .set SRC, 1

    # target[i]: priority in bits 7:0 (hart index 0).
    .set TARGET_PRIO, 1

    # mtopi field layout: IID in bits 27:16, IPRIO in bits 7:0. The machine
    # external interrupt identity is 11.
    .set MEI_IID, 11

    # mie.MEIE is bit 11.
    .set MIE_MEIE, (1 << 11)

    mv t6, ra

    # All APLIC register offsets used here exceed the 12-bit load/store
    # immediate range, so absolute addresses are materialized with li and each
    # access uses a zero displacement.

    # Initially no interrupt is pending; mtopi reads zero.
    csrr t0, CSR_MTOPI
    bnez t0, fail

    # Enable MEI in mie so it counts as pending-and-enabled for mtopi.
    li t0, MIE_MEIE
    csrs CSR_MIE, t0

    # Configure domain 0: enable interrupt generation (domaincfg.IE = 1).
    li a0, (APLIC_M_BASE + OFF_DOMAINCFG)
    li t0, DOMAINCFG_IE
    sw t0, 0(a0)

    # sourcecfg[1] = Edge1 (active, not delegated).
    li a0, (APLIC_M_BASE + OFF_SOURCECFG1)
    li t0, SM_EDGE1
    sw t0, 0(a0)

    # target[1] priority = 1.
    li a0, (APLIC_M_BASE + OFF_TARGET1)
    li t0, TARGET_PRIO
    sw t0, 0(a0)

    # Enable source 1 (setienum).
    li a0, (APLIC_M_BASE + OFF_SETIENUM)
    li t0, SRC
    sw t0, 0(a0)

    # Enable direct delivery to the hart (idelivery = 1).
    li a0, (APLIC_M_BASE + OFF_IDELIVERY)
    li t0, 1
    sw t0, 0(a0)

    # No pending interrupt yet -> mtopi still zero.
    csrr t0, CSR_MTOPI
    bnez t0, fail

    # Make source 1 pending (setipnum).
    li a0, (APLIC_M_BASE + OFF_SETIPNUM)
    li t0, SRC
    sw t0, 0(a0)

    # mtopi should now report IID = 11 (MEI) and IPRIO = 1.
    csrr t0, CSR_MTOPI
    andi t1, t0, 0xFF
    li t2, 1
    bne t1, t2, fail
    srli t1, t0, 16
    li t2, MEI_IID
    bne t1, t2, fail

    # The APLIC IDC topi register should report identity = 1, priority = 1.
    # Layout: identity in bits 25:16, priority in bits 7:0.
    li a0, (APLIC_M_BASE + OFF_TOPI)
    lw t0, 0(a0)
    andi t1, t0, 0xFF
    li t2, TARGET_PRIO
    bne t1, t2, fail
    srli t1, t0, 16
    li t2, SRC
    bne t1, t2, fail

    # claimi reads the top interrupt and clears its pending bit. It should
    # return identity = 1, priority = 1.
    li a0, (APLIC_M_BASE + OFF_CLAIMI)
    lw t0, 0(a0)
    srli t1, t0, 16
    li t2, SRC
    bne t1, t2, fail

    # After the claim the pending bit is cleared, so mtopi reads zero again.
    csrr t0, CSR_MTOPI
    bnez t0, fail

    # topi should also now be zero.
    li a0, (APLIC_M_BASE + OFF_TOPI)
    lw t0, 0(a0)
    bnez t0, fail

pass:
    li a0, 0
    mv ra, t6
    ret
fail:
    li a0, 1
    mv ra, t6
    ret
