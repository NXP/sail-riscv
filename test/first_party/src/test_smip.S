.global main
main:
    # Self-checking test for the Smip machine-level interrupt-handler push
    # and pop (mipopret). On a vectored machine interrupt with miconfig.mipu
    # set, the hart automatically pushes a0-a5 (x10-x15) onto the stack frame
    # at trap entry; mipopret pops them back and returns. The toolchain does
    # not know mipopret, so it is emitted as a raw .word encoding:
    #   mipopret = 0x30800073
    # CSR numbers: mistatus = 0x346; miconfig is indirect (miselect 0x1000).

    # miconfig.mipu is bit 4 (0x10). miconfig is accessed indirectly via
    # miselect (0x350) / mireg (0x351) at miselect == 0x1000 (Smcsrind).
    # The Simple Interrupt Generator MMIO
    # device lives at 0x0C000000; writing (1<<31)|(1<<3) sets the machine
    # software interrupt (MSI), and (1<<3) alone clears it.


    mv s0, ra                 # save return address
    mv s1, sp                 # save the real stack pointer

    # --- Set up a vectored trap vector. ---
    la t0, mtvec_table
    ori t0, t0, 1             # mode = vectored
    csrw mtvec, t0

    # --- Enable the machine-level push: miconfig.mipu (bit 4). ---
    # miconfig is indirect: select 0x1000 via miselect (0x350), then
    # read/write the value through mireg (0x351).
    li t0, 0x1000
    csrw 0x350, t0            # miselect = 0x1000 (miconfig)
    li t0, 0x10
    csrw 0x351, t0            # mireg = miconfig.mipu
    csrr t1, 0x351
    li t2, 0x10
    bne t1, t2, fail          # miconfig readback must match


    # --- sppush = 0: no stack-pointer swap should occur on push. ---
    csrw 0x346, zero

    csrw mideleg, 0           # do not delegate

    # --- Sentinel values in a0-a5 that the pop must restore. ---
    li a0, 0x1000
    li a1, 0x1001
    li a2, 0x1002
    li a3, 0x1003
    li a4, 0x1004
    li a5, 0x1005

    li s2, 0                  # "handler ran" marker

    # --- Enable the machine software interrupt. ---
    li t0, (1 << 3)           # mie.MSIE
    csrw mie, t0
    li t0, 0x8                # MSTATUS_MIE
    csrs mstatus, t0

    # --- Trigger the MSI via the Simple Interrupt Generator. ---
    li t0, 0x0C000000
    li t1, (1 << 31) | (1 << 3)   # SIG_SET | SIG_MSI
    sw t1, 4(t0)

trigger_point:
    # The interrupt is dispatched here; the automatic push saves a0-a5 and
    # decrements sp by FRAMESIZE, then control transfers to msi_handler.
    nop
    nop

    # Control resumes here after mipopret. The marker must be set, and the
    # pop must have restored a0-a5 and sp.
    beqz s2, fail

    li t0, 0x1000
    bne a0, t0, fail
    li t0, 0x1001
    bne a1, t0, fail
    li t0, 0x1002
    bne a2, t0, fail
    li t0, 0x1003
    bne a3, t0, fail
    li t0, 0x1004
    bne a4, t0, fail
    li t0, 0x1005
    bne a5, t0, fail

    bne sp, s1, fail          # sp restored by the pop

    # =====================================================================
    # Scenario 2: push with mistatus.sppush = 1, so the push must swap the
    # stack pointer with mspcs before saving a0-a5, and the pop must swap it
    # back.
    # =====================================================================
    # mspcs is the alternate ("interrupt") stack pointer. Point it at a
    # scratch region distinct from the current sp.
    la t0, alt_stack_top
    csrw 0x349, t0            # mspcs = alt_stack_top

    li t0, 0x40               # mistatus.sppush (bit 6)
    csrw 0x346, t0
    # mistatus mirrors mstatus fields (including MIE); the write above
    # cleared MIE, so re-enable machine interrupts.
    li t0, 0x8                # MSTATUS_MIE
    csrs mstatus, t0

    li a0, 0x2000
    li a1, 0x2001
    li a2, 0x2002
    li a3, 0x2003
    li a4, 0x2004
    li a5, 0x2005

    li s2, 0                  # clear handler-ran marker

    li t0, 0x0C000000
    li t1, (1 << 31) | (1 << 3)
    sw t1, 4(t0)

trigger_point2:
    nop
    nop

    beqz s2, fail
    li t0, 0x2000
    bne a0, t0, fail
    li t0, 0x2001
    bne a1, t0, fail
    li t0, 0x2002
    bne a2, t0, fail
    li t0, 0x2003
    bne a3, t0, fail
    li t0, 0x2004
    bne a4, t0, fail
    li t0, 0x2005
    bne a5, t0, fail

    bne sp, s1, fail          # real sp restored after swap-back
    # mispcs (mspcs) must again hold alt_stack_top after the pop swap-back.
    csrr t0, 0x349
    la t1, alt_stack_top
    bne t0, t1, fail

    j pass

.balign 4
# Vectored mtvec requires 4-byte-aligned entries at base + 4*cause. Force
# non-compressed jumps so each slot is exactly 4 bytes.
.option push
.option norvc
mtvec_table:
    j default_handler         # 0
    j default_handler         # 1
    j default_handler         # 2
    j msi_handler             # 3: machine software interrupt
    j default_handler         # 4
    j default_handler         # 5
    j default_handler         # 6
    j default_handler         # 7
.option pop

msi_handler:
    # Clobber a0-a5 to prove the pop restores them from the pushed frame.
    li a0, 0xdead0
    li a1, 0xdead1
    li a2, 0xdead2
    li a3, 0xdead3
    li a4, 0xdead4
    li a5, 0xdead5

    # Clear the pending MSI so it does not re-fire after we return.
    li t0, 0x0C000000
    li t1, (1 << 3)           # SIG_MSI, bit 31 = 0 -> clear
    sw t1, 4(t0)

    li s2, 1                  # mark that the handler ran

    .word 0x30800073          # mipopret: pop a0-a5, restore sp, and return

default_handler:
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

.balign 16
alt_stack:
    .zero 256
alt_stack_top:
