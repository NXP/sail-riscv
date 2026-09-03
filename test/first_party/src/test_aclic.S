.global main
main:
    # Self-checking test for the ACLIC (Advanced Core-Local Interrupt
    # Controller) hart-local interrupt domain control (Smidctrl/Ssidctrl).
    #
    # The ACLIC operates the per-domain APLIC source state entirely through
    # hart-local indirect CSRs. This test drives source configuration and
    # priority through the acliciprio / aclicsourcecfg control registers
    # (selects 0x1000..0x10FF), then the pending/enable arrays through the
    # eip/eie interrupt-file aliases (selects 0x80/0xC0), and finally reads
    # and claims the arbitrated top interrupt through xtopei.
    #
    # Domain mapping: xtopei/machine indirect CSRs (miselect/mireg) drive the
    # machine-level domain (0); the supervisor indirect CSRs (siselect/sireg)
    # drive the supervisor-level domain (1). The S-domain is accessed here
    # directly from M-mode, so no privilege switch is required.

    # Indirect CSR addresses.
    .set CSR_MISELECT, 0x350
    .set CSR_MIREG,    0x351   # alias 1
    .set CSR_MIREG2,   0x352   # alias 2
    .set CSR_MIREG3,   0x353   # alias 3
    .set CSR_SISELECT, 0x150
    .set CSR_SIREG,    0x151
    .set CSR_SIREG2,   0x152
    .set CSR_SIREG3,   0x153
    .set CSR_MTOPEI,   0x35C
    .set CSR_STOPEI,   0x15C

    # ACLIC / interrupt-file *iselect layout.
    .set SEL_EIP0,      0x80    # eip word 0 (pending bits)
    .set SEL_EIE0,      0xC0    # eie word 0 (enable bits)
    .set SEL_CTRL0,     0x1000  # acliciprio[0] / aclicsourcecfg[0]

    # APLIC source-mode: detached (software-settable pending, active).
    .set SM_DETACHED,   0x1

    mv t6, ra

    # =====================================================================
    # Machine domain (domain 0): configure source 1, priority 5.
    # =====================================================================

    # aclicsourcecfg[0] via mireg2 (alias 2) at select 0x1000. On RV32/RV64
    # this register's lane 1 (bits 31:16) is source 1's sourcecfg[15:0];
    # write SM = detached so source 1 becomes active.
    li t0, SEL_CTRL0
    csrw CSR_MISELECT, t0
    li t0, (SM_DETACHED << 16)
    csrw CSR_MIREG2, t0
    # Readback: source 1 lane must reflect the detached SM.
    csrr t1, CSR_MIREG2
    srli t1, t1, 16
    andi t1, t1, 0x7
    li t2, SM_DETACHED
    bne t1, t2, fail

    # acliciprio[0] via mireg (alias 1) at select 0x1000. Lane 1 (bits 15:8)
    # is source 1's iprio; set priority 5.
    li t0, SEL_CTRL0
    csrw CSR_MISELECT, t0
    li t0, (5 << 8)
    csrw CSR_MIREG, t0
    csrr t1, CSR_MIREG
    srli t1, t1, 8
    andi t1, t1, 0xFF
    li t2, 5
    bne t1, t2, fail

    # Enable source 1 in the machine domain: eie0 bit 1.
    li t0, SEL_EIE0
    csrw CSR_MISELECT, t0
    li t0, (1 << 1)
    csrw CSR_MIREG, t0

    # Nothing pending yet: mtopei reads zero.
    csrr t0, CSR_MTOPEI
    bnez t0, fail

    # Assert source 1 pending: eip0 bit 1.
    li t0, SEL_EIP0
    csrw CSR_MISELECT, t0
    li t0, (1 << 1)
    csrw CSR_MIREG, t0

    # mtopei: IID in bits 25:16 == 1, IPRIO in bits 7:0 == 5.
    csrr t0, CSR_MTOPEI
    srli t1, t0, 16
    andi t1, t1, 0x3FF
    li t2, 1
    bne t1, t2, fail
    andi t1, t0, 0xFF
    li t2, 5
    bne t1, t2, fail

    # Claim (write clears the top pending bit) and confirm cleared.
    csrw CSR_MTOPEI, zero
    csrr t0, CSR_MTOPEI
    bnez t0, fail

    # =====================================================================
    # Supervisor domain (domain 1): configure source 2, priority 3.
    # =====================================================================

    # aclicsourcecfg[0] via sireg2. Source 2 is lane 0 of select 0x1002
    # (offset 2 -> base 4*... ), but to keep the test within a single
    # control register we place source 2 in lane 0 of the select whose base
    # is source 2. For simplicity, reuse select 0x1000 whose lanes cover
    # sources 0 and 1 on RV32; use source 1 in the S-domain as well.
    li t0, SEL_CTRL0
    csrw CSR_SISELECT, t0
    li t0, (SM_DETACHED << 16)
    csrw CSR_SIREG2, t0
    csrr t1, CSR_SIREG2
    srli t1, t1, 16
    andi t1, t1, 0x7
    li t2, SM_DETACHED
    bne t1, t2, fail

    # acliciprio[0] via sireg: source 1 iprio = 3.
    li t0, SEL_CTRL0
    csrw CSR_SISELECT, t0
    li t0, (3 << 8)
    csrw CSR_SIREG, t0

    # Enable source 1 in the supervisor domain: eie0 bit 1.
    li t0, SEL_EIE0
    csrw CSR_SISELECT, t0
    li t0, (1 << 1)
    csrw CSR_SIREG, t0

    csrr t0, CSR_STOPEI
    bnez t0, fail

    # Assert source 1 pending in the S-domain: eip0 bit 1.
    li t0, SEL_EIP0
    csrw CSR_SISELECT, t0
    li t0, (1 << 1)
    csrw CSR_SIREG, t0

    # stopei: IID == 1, IPRIO == 3.
    csrr t0, CSR_STOPEI
    srli t1, t0, 16
    andi t1, t1, 0x3FF
    li t2, 1
    bne t1, t2, fail
    andi t1, t0, 0xFF
    li t2, 3
    bne t1, t2, fail

    csrw CSR_STOPEI, zero
    csrr t0, CSR_STOPEI
    bnez t0, fail

pass:
    li a0, 0
    mv ra, t6
    ret
fail:
    li a0, 1
    mv ra, t6
    ret
