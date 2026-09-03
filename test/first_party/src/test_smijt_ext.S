.global main

# Self-checking test for the Smijt interrupt jump-table (hardware vectoring)
# extension applied to an EXTERNAL interrupt. When mtvec.MODE == 0b11
# (jump-table mode) a machine external interrupt (MEI) delegated to M-mode is
# vectored through an in-memory table based at mijt. Unlike a non-external
# (major) interrupt, an external interrupt indexes the table by its POSITIVE
# minor interrupt identity (as reported by the external interrupt controller
# through the AIA xtopei view), so its entry lives at:
#     entry_addr = JTBASE + (minor << (SHAMT + log2(XLEN/8)))
# where JTBASE = mijt.BASE << 6 (64-byte aligned). If the entry's low bit
# (VEN) is set the handler address is (entry & ~1) and the interrupt is
# hardware-vectored. If VEN is clear control falls back to the direct mtvec
# base (a common SW dispatcher).
#
# The external interrupt is produced by the Simple Interrupt Generator MMIO
# device at 0x0C000000. Its mtopei_cfg register (offset 8) packs the reported
# minor identity (bits [26:16]) and priority (bits [7:0]) using the same
# layout as mtopi/mtopei. Setting the MEI pending bit (bit 11) via the
# platform-interrupt offset 4 raises MEI; the controller then reports the
# configured minor identity, which the IJT uses as the (positive) table index.
#
# This test drives MEI twice with minor identity MINOR_ID:
#   Phase 1 (VEN = 1): control must transfer to ext_handler (the entry at
#                      jt_base + MINOR_ID*STRIDE).
#   Phase 2 (VEN = 0): control must fall back to the direct mtvec base
#                      (sw_dispatcher).
#
# CSR numbers: mijt = 0x307, mie = 0x304 (MEIE = bit 11).

#if __riscv_xlen == 32
#define STRIDE 4
#define SHAMT  0
#define STORE  sw
#else
#define STRIDE 8
// Per spec #855 the per-entry shift is SHAMT + log2(XLEN/8) = SHAMT + 3 for
// RV64, so SHAMT = 0 yields an 8-byte (XLEN/8) stride matching STRIDE.
#define SHAMT  0
#define STORE  sd
#endif

#define MIE_MEIE  (1 << 11)
#define SIG_MEI   (1 << 11)
#define SIG_SET   (1 << 31)

#define MINOR_ID  5

    .set SIG_BASE,            0xC000000
    .set SIG_PLATFORM_OFFSET, 4
    .set SIG_MTOPEI_CFG_OFF,  8

main:
    mv s0, ra                 # save return address
    mv s1, sp                 # save the stack pointer

    # --- Program mijt: BASE = jt_base >> 6 (jt_base is 64-byte aligned),
    #     with SHAMT in the low two bits. ---
    la t0, jt_base
    ori t0, t0, SHAMT
    csrw 0x307, t0            # mijt = jt_base | SHAMT
    csrr t1, 0x307
    bne t0, t1, fail          # mijt readback must match (jt_base 64B aligned)

    csrw mideleg, 0           # do not delegate: handle MEI at M-mode

    # --- Enable the machine external interrupt. ---
    li t0, MIE_MEIE
    csrw 0x304, t0            # mie.MEIE

    # --- Configure the external controller to report minor identity
    #     MINOR_ID with a non-zero priority. ---
    la a0, SIG_BASE
    li t0, (MINOR_ID << 16) | 0x10   # minor identity in [26:16], priority 0x10
    sw t0, SIG_MTOPEI_CFG_OFF(a0)

    # =====================================================================
    # Phase 1: VEN = 1. The entry for MEI (minor identity MINOR_ID) lives at
    # jt_base + MINOR_ID*STRIDE and holds (ext_handler | 1). Vectoring must
    # transfer control to ext_handler.
    # =====================================================================
    la t2, ext_handler
    ori t2, t2, 1             # VEN = 1
    la t3, jt_base
    li t4, MINOR_ID * STRIDE
    add t3, t3, t4            # &entry = jt_base + MINOR_ID*STRIDE
    STORE t2, 0(t3)

    # mtvec: jump-table mode (MODE = 0b11). The direct base points at
    # fail_handler so phase 1 fails if vectoring does not occur.
    la t0, fail_handler
    ori t0, t0, 3             # MODE = 0b11 (jump table)
    csrw mtvec, t0

    li s2, 0                  # "handler ran" marker

    li t0, 0x8                # MSTATUS_MIE
    csrs mstatus, t0

    li t0, SIG_SET | SIG_MEI
    sw t0, SIG_PLATFORM_OFFSET(a0)

trigger_point:
    # The interrupt is dispatched here; jump-table vectoring must transfer
    # control to ext_handler (from the table entry), not to fail_handler.
    nop
    nop

    beqz s2, fail             # handler must have run

    # =====================================================================
    # Phase 2: VEN = 0. Rewrite the MEI entry so its LSB is clear. Control
    # must fall back to the direct mtvec base (sw_dispatcher).
    # =====================================================================
    la t2, ext_handler        # any address; LSB cleared below
    andi t2, t2, ~1           # VEN = 0
    la t3, jt_base
    li t4, MINOR_ID * STRIDE
    add t3, t3, t4
    STORE t2, 0(t3)

    # mtvec: jump-table mode, direct base = sw_dispatcher (the VEN=0 target).
    la t0, sw_dispatcher
    ori t0, t0, 3             # MODE = 0b11 (jump table)
    csrw mtvec, t0

    li s3, 0                  # "dispatcher ran" marker

    li t0, 0x8                # MSTATUS_MIE (re-enable; may still be set)
    csrs mstatus, t0

    # Re-raise MEI (phase 1 handler cleared the pending source below).
    li t0, SIG_SET | SIG_MEI
    sw t0, SIG_PLATFORM_OFFSET(a0)

trigger_point2:
    nop
    nop

    beqz s3, fail             # dispatcher must have run

    j pass

ext_handler:
    li s2, 1                  # mark that the vectored handler ran

    # Acknowledge the external interrupt at the controller so it does not
    # re-fire after mret (clear the MEI pending source).
    la a0, SIG_BASE
    li t0, SIG_MEI            # bit 31 = 0 -> clear
    sw t0, SIG_PLATFORM_OFFSET(a0)

    mret

sw_dispatcher:
    li s3, 1                  # mark that the SW dispatcher (direct base) ran

    # VEN = 0: not hardware-vectored. Clear the external interrupt source in
    # software so it does not re-fire after mret.
    la a0, SIG_BASE
    li t0, SIG_MEI
    sw t0, SIG_PLATFORM_OFFSET(a0)

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

# The external jump table grows upward from jt_base (entries at
# jt_base + minor*STRIDE). jt_base must be 64-byte aligned (mijt.BASE covers
# bits [XLEN-1:6]). Reserve space above jt_base for the entries.
.balign 64
jt_base:
    .zero 128
