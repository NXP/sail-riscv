// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================
//
// Smehv / Ssehv - Synchronous exception hardware vectoring.
//
// When xtvec.MODE == 0b11 (TV_JumpTable) and the per-privilege xijt.EHV bit
// is set, a synchronous exception delegated to privilege x is vectored the
// same way the vectored (TV_Vector) mode vectors interrupts: to
//   OBASE + (exccode << 2)
// where OBASE = xtvec[Base] << 2 is the direct trap-vector base (the same
// base tvec_addr returns for jump-table mode). Interrupts continue to use
// the Smijt/Ssijt in-memory jump table; only synchronous exceptions are
// affected here. This purely computes the entry address; no memory access
// is performed, so it cannot fault.
//
// The mijt/sijt CSRs and the Xijt bitfield (including the EHV field) live in
// extensions/aclic/aclic_regs.sail. The hook is consulted from trap_handler
// in sys/sys_control.sail.

// Is synchronous exception hardware vectoring enabled for the delegated
// privilege?
function xehv_ext_enabled(priv : Privilege) -> bool =
  match priv {
    Machine    => currentlyEnabled(Ext_Smehv),
    Supervisor => currentlyEnabled(Ext_Ssehv),
    _          => false,
  }

// Compute the synchronous exception hardware-vectoring target for a trap
// delegated to `del_priv`, or None() to use the normal trap vector.
//
// Returns Some(handler) only when all of the following hold:
//   - Smehv/Ssehv is enabled for del_priv,
//   - the trap is a synchronous exception (cause.IsInterrupt == 0),
//   - xtvec for del_priv is in jump-table mode (MODE == 0b11), and
//   - xijt.EHV is set for del_priv.
// Otherwise None() is returned and trap_handler falls back to
// prepare_trap_vector (the direct/jump-table base).
function smehv_exc_vector(del_priv : Privilege, cause : Mcause) -> option(xlenbits) = {
  if not(xehv_ext_enabled(del_priv)) then None()
  else if cause[IsInterrupt] == 0b1 then None()
  else {
    let tvec = xtvec_for(del_priv);
    if trapVectorMode(tvec[Mode]) != TV_JumpTable then None()
    else {
      let xijt = get_xijt(del_priv);
      if xijt[EHV] == 0b0 then None()
      else {
        // OBASE = xtvec[Base] << 2, matching the base tvec_addr uses.
        let obase : xlenbits = tvec[Base] @ 0b00;
        Some(obase + (zero_extend(cause[Cause]) << 2))
      }
    }
  }
}
