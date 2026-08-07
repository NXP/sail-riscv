.global main

# Self-checking test for the Smijt machine-level interrupt jump-table
# (hardware vectoring) extension. When mtvec.MODE == 0b11 (jump-table mode)
# a machine interrupt delegated to M-mode is vectored through an in-memory
# table based at mijt. For major-interrupt identity `id` the hardware reads
# an XLEN-wide entry at:
#     entry_addr = JTBASE - (id << (SHAMT + 2))
# where JTBASE = mijt.BASE << 6 (64-byte aligned). If the entry's low bit
# (VEN) is set the handler address is (entry & ~1) (IALIGN=16 with C) and the
# interrupt is hardware-vectored; the hart also clears the corresponding
# interrupt-pending bit (best effort) before entering the handler. If VEN is
# clear the interrupt is not hardware-vectored: control is redirected to the
# direct mtvec base (a common SW dispatcher) and the pending bit is left set
# for software to clear.
#
# This test drives a machine software interrupt (MSI, identity 3) twice:
#   Phase 1 (VEN = 1): control must transfer to msi_handler, and mip.MSI must
#                      already be clear on handler entry (cleared by hardware).
#   Phase 2 (VEN = 0): control must fall back to the direct mtvec base
#                      (sw_dispatcher), and mip.MSI must still be set there
#                      (hardware must NOT clear it when not vectoring).
#
# CSR numbers: mijt = 0x307, mip = 0x344 (MSI = bit 3). The Simple Interrupt
# Generator MMIO device is at 0x0C000000; writing (1<<31)|(1<<3) sets the MSI
# (latched into mip.MSI), and (1<<3) clears it.

#if __riscv_xlen == 32
#define STRIDE 4
#define SHAMT  0
#define STORE  sw
#else
#define STRIDE 8
#define SHAMT  1
#define STORE  sd
#endif

#define MIP_MSI (1 << 3)

main:
    mv s0, ra                 # save return address
    mv s1, sp                 # save the stack pointer

    # --- Program mijt: BASE = jt_base >> 6 (i.e. jt_base, 64-byte aligned),
    #     with SHAMT in the low two bits. ---
    la t0, jt_base
    ori t0, t0, SHAMT
    csrw 0x307, t0            # mijt = jt_base | SHAMT
    csrr t1, 0x307
    bne t0, t1, fail          # mijt readback must match (jt_base 64B aligned)

    csrw mideleg, 0           # do not delegate: handle at M-mode

    # --- Enable the machine software interrupt (used by both phases). ---
    li t0, MIP_MSI            # mie.MSIE
    csrw mie, t0

    # =====================================================================
    # Phase 1: VEN = 1. The entry for MSI (identity 3) lives at
    # jt_base - 3*STRIDE and holds (msi_handler | 1). Vectoring must occur
    # and mip.MSI must be clear on handler entry (hardware-acknowledged).
    # =====================================================================
    la t2, msi_handler
    ori t2, t2, 1             # VEN = 1
    la t3, jt_base
    li t4, 3 * STRIDE
    sub t3, t3, t4            # &entry = jt_base - 3*STRIDE
    STORE t2, 0(t3)

    # mtvec: jump-table mode (MODE = 0b11). The direct base points at
    # fail_handler so phase 1 fails if vectoring does not occur.
    la t0, fail_handler
    ori t0, t0, 3             # MODE = 0b11 (jump table)
    csrw mtvec, t0

    li s2, 0                  # "handler ran" marker

    li t0, 0x8                # MSTATUS_MIE
    csrs mstatus, t0

    li t0, 0x0C000000
    li t1, (1 << 31) | MIP_MSI    # SIG_SET | SIG_MSI
    sw t1, 4(t0)

trigger_point:
    # The interrupt is dispatched here; jump-table vectoring must transfer
    # control to msi_handler (from the table entry), not to fail_handler.
    nop
    nop

    beqz s2, fail             # handler must have run

    # =====================================================================
    # Phase 2: VEN = 0. Rewrite the MSI entry so its LSB is clear. The
    # interrupt must not be hardware-vectored; instead control falls back to
    # the direct mtvec base (sw_dispatcher), and mip.MSI must still be set.
    # =====================================================================
    la t2, msi_handler        # any address; LSB cleared below
    andi t2, t2, ~1           # VEN = 0
    la t3, jt_base
    li t4, 3 * STRIDE
    sub t3, t3, t4
    STORE t2, 0(t3)

    # mtvec: jump-table mode, direct base = sw_dispatcher (the VEN=0 target).
    la t0, sw_dispatcher
    ori t0, t0, 3             # MODE = 0b11 (jump table)
    csrw mtvec, t0

    li s3, 0                  # "dispatcher ran" marker

    li t0, 0x8                # MSTATUS_MIE (re-enable; may still be set)
    csrs mstatus, t0

    li t0, 0x0C000000
    li t1, (1 << 31) | MIP_MSI
    sw t1, 4(t0)

trigger_point2:
    nop
    nop

    beqz s3, fail             # dispatcher must have run

    j pass

msi_handler:
    li s2, 1                  # mark that the vectored handler ran

    # The hardware must have cleared mip.MSI as part of hardware vectoring
    # (VEN = 1), before control reached here. Verify it is clear; do NOT
    # clear it ourselves.
    csrr t0, 0x344            # mip
    andi t0, t0, MIP_MSI
    bnez t0, fail             # mip.MSI must already be clear

    mret

sw_dispatcher:
    li s3, 1                  # mark that the SW dispatcher (direct base) ran

    # VEN = 0, so the interrupt was not hardware-vectored and mip.MSI must
    # still be set here. Verify it, then clear it in software so it does not
    # re-fire after mret.
    csrr t0, 0x344            # mip
    andi t0, t0, MIP_MSI
    beqz t0, fail             # mip.MSI must still be set

    li t0, 0x0C000000
    li t1, MIP_MSI            # SIG_MSI, bit 31 = 0 -> clear
    sw t1, 4(t0)

    mret

.balign 4
fail_handler:
    # Reached only if the direct mtvec base was used instead of the table
    # entry during phase 1, i.e. jump-table vectoring did not occur.
    j fail

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

# The jump table grows downward from jt_base (entries at jt_base - id*STRIDE).
# jt_base must be 64-byte aligned (mijt.BASE covers bits [XLEN-1:6]). Reserve
# space below jt_base for the entries the hardware may read.
.balign 64
jt_area:
    .zero 64
jt_base:
    .zero 8
