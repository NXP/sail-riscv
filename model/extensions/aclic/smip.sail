// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================
//
// Smip / Ssip - Interrupt handler push and pop extension.
//
// This file provides the interrupt-return instructions mipopret (machine
// level) and sipopret (supervisor level), the automatic context push at
// interrupt trap entry (do_interrupt_push, invoked from handle_interrupt in
// sys/sys_control.sail), and the frame-layout parameters shared by both.
// The stack-pointer-swap primitives and the miconfig/siconfig CSRs live in
// extensions/Smcsps/smcsps.sail and extensions/aclic/aclic_regs.sail
// respectively.

// Number of argument registers (a0-a5 = x10-x15) saved/restored by the
// interrupt-handler push/pop. Fixed by the Smip/Ssip specification.
let NUM_PUSH_REGS = 6

// Byte offset of a0 (x10) in the register file. a(i) = x(10 + i).
let PUSH_A0_IDX : regidx = Regidx(to_bits(regidx_bit_width, 10))

// Size in bytes of the interrupt-handler frame: NUM_PUSH_REGS registers of
// XLEN/8 bytes each, rounded up to a 16-byte stack-alignment boundary.
// This is 32 on RV32 (6 * 4 = 24, rounded to 32) and 64 on RV64 (6 * 8 =
// 48, rounded to 64). `raw` is widened to nat so the round-up division is
// well typed.
function push_framesize() -> int = {
  let raw : nat = NUM_PUSH_REGS * xlen_bytes;
  let aligned : nat = (raw + 15) / 16;
  aligned * 16
}



// Shared pop-and-return sequence for mipopret/sipopret. Following the spec
// pseudocode, this:
//   * restores a0-a5 (x10-x15) from the frame at the current sp,
//   * adjusts sp to destroy the frame,
//   * conditionally swaps the stack pointer back (xcspspop semantics),
//   * executes an xret according to `priv`.
// The frame is push_framesize() bytes, with a(i) = x(10+i) at offset
// i * XLEN/8 from sp. The loads are committed incrementally; on the first
// faulting load the fault is taken immediately as a synchronous exception
// (the ExecutionResult is returned) before the sp adjustment, the swap, or
// the return, so the interrupted handler context is left intact. The caller
// guarantees the privilege guard.
function do_xipopret(priv : Privilege) -> ExecutionResult = {
  let framesize = push_framesize();
  let width = xlen_bytes;

  foreach (i from 0 to (NUM_PUSH_REGS - 1)) {
    let off : xlenbits = to_bits_truncate(xlen, i * width);
    match vmem_read(sp, off, width, Load(Data), false, false, false) {
      Ok(data) => X(PUSH_A0_IDX + i) = sign_extend(data),
      Err(e)   => return e,
    }
  };

  X(sp) = X(sp) + to_bits_truncate(xlen, framesize);
  xcsps_pop_swap(priv);
  do_xret(priv)
}

// Automatic context push at interrupt trap entry, invoked from
// handle_interrupt (sys/sys_control.sail) before the interrupt trap side
// effects are applied. Following the spec pseudocode, this:
//   * conditionally swaps the stack pointer (xcspspush semantics),
//   * stores a0-a5 (x10-x15) into the newly created frame,
//   * adjusts sp to create the frame.
// The frame is push_framesize() bytes, with a(i) = x(10+i) stored at offset
// i * XLEN/8 from the frame base (sp - framesize). The caller must have set
// cur_privilege to `priv` before calling.
//
// Fault unwinding: stores are committed incrementally, but the sp is only
// decremented after all stores succeed, and the stack-pointer swap is the
// only other side effect (performed first). On the first faulting store the
// swap is inverted with xcsps_pop_swap and Some(exc) is returned before sp
// is touched, so the interrupted context (sp, sppush/psppush, and the
// alternate stack pointer) is fully restored and the caller can take the
// store fault as a precise synchronous exception. On success None() is
// returned.
function do_interrupt_push(priv : Privilege) -> option(sync_exception) = {
  let framesize = push_framesize();
  let width = xlen_bytes;

  xcsps_push_swap(priv);

  foreach (i from 0 to (NUM_PUSH_REGS - 1)) {
    let off : xlenbits = to_bits_truncate(xlen, i * width) - to_bits_truncate(xlen, framesize);
    let data = X(PUSH_A0_IDX + i)[width * 8 - 1 .. 0];
    match vmem_write(sp, off, width, data, Store(Data), false, false, false) {
      Ok(_)  => (),
      Err(e) => {
        // Abort: unwind the swap so the interrupted context is intact (sp
        // has not yet been decremented), then report the fault. Extract the
        // synchronous exception carried by the faulting store's trap.
        xcsps_pop_swap(priv);
        match e {
          Trap(_, exc, _) => return Some(exc),
          _               => internal_error(__FILE__, __LINE__, "unexpected push store fault result"),
        }
      },
    }
  };

  // All stores committed: create the frame.
  X(sp) = X(sp) - to_bits_truncate(xlen, framesize);
  None()
}

// Is the interrupt-handler push extension enabled for `priv`?
function xip_ext_enabled(priv : Privilege) -> bool =
  match priv {
    Machine    => currentlyEnabled(Ext_Smip),
    Supervisor => currentlyEnabled(Ext_Ssip),
    _          => false,
  }

// Is the interrupt-handler push active for a trap delegated to `priv`?
function xip_push_enabled(priv : Privilege) -> bool =
  xip_ext_enabled(priv) & xiconfig_ipu(priv) == 0b1

// Attempt the interrupt-handler push for a trap delegated to `del_priv`.
// Returns None() if no push happened (push disabled) or the push completed
// successfully; Some(exc) if a push store faulted (interrupted context left
// intact). Performs the enable check and the cur_privilege save/restore
// internally so the push memory accesses use the handler's privilege.
function try_interrupt_push(del_priv : Privilege) -> option(sync_exception) = {
  if not(xip_push_enabled(del_priv)) then None()
  else {
    let saved_priv = cur_privilege;
    cur_privilege = del_priv;
    let r = do_interrupt_push(del_priv);
    cur_privilege = saved_priv;
    r
  }
}



// -------------------------------------------------------------------------
// mipopret - pop interrupt context and return, machine level.
// -------------------------------------------------------------------------
union clause instruction = MIPOPRET : unit

mapping clause encdec = MIPOPRET()
  <-> 0b0011000 @ 0b01000 @ 0b00000 @ 0b000 @ 0b00000 @ 0b1110011
      when currentlyEnabled(Ext_Smip)

function clause execute MIPOPRET() = {
  if   cur_privilege != Machine
  then Illegal_Instruction()
  else if not(ext_check_xret_priv(Machine))
  then Ext_XRET_Priv_Failure()
  else do_xipopret(Machine)
}

mapping clause assembly = MIPOPRET() <-> "mipopret"

// -------------------------------------------------------------------------
// sipopret - pop interrupt context and return, supervisor level.
// -------------------------------------------------------------------------
union clause instruction = SIPOPRET : unit

mapping clause encdec = SIPOPRET()
  <-> 0b0000100 @ 0b01000 @ 0b00000 @ 0b000 @ 0b00000 @ 0b1110011
      when currentlyEnabled(Ext_Ssip)

function clause execute SIPOPRET() = {
  // Legal at machine or supervisor level; also honors mstatus.TSR like sret.
  let illegal : bool = match cur_privilege {
    User              => true,
    Supervisor        => mstatus[TSR] == 0b1,
    Machine           => false,
    VirtualUser       => true,
    VirtualSupervisor => true,
  };
  if   illegal
  then Illegal_Instruction()
  else if not(ext_check_xret_priv(Supervisor))
  then Ext_XRET_Priv_Failure()
  else do_xipopret(Supervisor)
}

mapping clause assembly = SIPOPRET() <-> "sipopret"
