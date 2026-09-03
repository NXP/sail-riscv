.global main

# Self-checking test for the Smehv machine-level synchronous exception
# hardware-vectoring extension. When mtvec.MODE == 0b11 (jump-table mode)
# and mijt.EHV is set, a synchronous exception delegated to M-mode is
# vectored to:
#     OBASE + (exccode << 2)
# where OBASE = mtvec[Base] << 2 is the direct trap-vector base (the same
# base used for jump-table mode). Interrupts continue to use the Smijt
# in-memory jump table; only synchronous exceptions are affected here.
# If mijt.EHV is clear the exception is NOT hardware-vectored: control is
# redirected to the direct base (OBASE + 0), matching the normal
# jump-table-mode fallback for exceptions.
#
# This test raises an environment-call-from-M-mode exception (exccode 11)
# twice:
#   Phase 1 (EHV = 1): control must transfer to OBASE + (11 << 2), i.e. the
#                      12th entry of the exception vector table, which jumps
#                      to exc_handler.
#   Phase 2 (EHV = 0): control must fall back to the direct base OBASE + 0,
#                      whose entry jumps to exc_fallback.
#
# CSR numbers: mijt = 0x307. In mijt, SHAMT is bits [1:0], EHV is bit [2],
# and BASE covers bits [XLEN-1:6]. The vector table below is assembled with
# compression disabled so every "j" entry is exactly 4 bytes and lands at
# OBASE + 4*exccode.

#if __riscv_xlen == 32
#define SHAMT  0
#else
#define SHAMT  1
#endif

#define MIJT_EHV (1 << 2)

# Environment call from M-mode exception code.
#define EXC_ECALL_M 11

main:
    mv s0, ra                 # save return address
    mv s1, sp                 # save the stack pointer

    # --- Program mijt: BASE = jt_base >> 6 (i.e. jt_base, 64-byte aligned),
    #     with SHAMT in the low two bits and EHV (bit 2) set. ---
    la t0, jt_base
    ori t0, t0, SHAMT | MIJT_EHV
    csrw 0x307, t0            # mijt = jt_base | EHV | SHAMT
    csrr t1, 0x307
    bne t0, t1, fail          # mijt readback must match (EHV preserved)

    csrw medeleg, 0           # do not delegate: handle at M-mode

    # --- mtvec: jump-table mode (MODE = 0b11), base = exc_base. ---
    la t0, exc_base
    ori t0, t0, 3             # MODE = 0b11 (jump table)
    csrw mtvec, t0

    # =====================================================================
    # Phase 1: EHV = 1. ECALL from M-mode (exccode 11) must be vectored to
    # OBASE + 44, whose entry jumps to exc_handler.
    # =====================================================================
    li s2, 0                  # "vectored handler ran" marker
    li s4, 1                  # phase selector: 1 => phase 1
    ecall

    beqz s2, fail             # vectored handler must have run

    # =====================================================================
    # Phase 2: EHV = 0. Rewrite mijt with EHV cleared. The exception must
    # not be hardware-vectored; control falls back to OBASE + 0, whose
    # entry jumps to exc_fallback.
    # =====================================================================
    la t0, jt_base
    ori t0, t0, SHAMT         # EHV = 0
    csrw 0x307, t0

    li s3, 0                  # "fallback handler ran" marker
    li s4, 2                  # phase selector: 2 => phase 2
    ecall

    beqz s3, fail             # fallback handler must have run

    j pass

exc_handler:
    li s2, 1                  # mark that the vectored handler ran
    # Advance past the 4-byte ECALL and return.
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

exc_fallback:
    li s3, 1                  # mark that the fallback (direct base) ran
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

# Exception vector table. OBASE = exc_base; entry for exccode `n` is at
# exc_base + 4*n. Compression is disabled so every "j" is 4 bytes wide.
.balign 4
exc_base:
    .option push
    .option norvc
    j exc_fallback            # 0  (also the EHV=0 fallback target)
    j fail                    # 1
    j fail                    # 2
    j fail                    # 3
    j fail                    # 4
    j fail                    # 5
    j fail                    # 6
    j fail                    # 7
    j fail                    # 8
    j fail                    # 9
    j fail                    # 10
    j exc_handler             # 11 (environment call from M-mode)
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

# The jump table base for interrupt vectoring. Not exercised by this test
# (only exception vectoring is), but mijt.BASE must point at a 64-byte
# aligned region.
.balign 64
jt_area:
    .zero 64
jt_base:
    .zero 8
