// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================
//
// Smcsps / Sscsps - Conditional Stack Pointer Swap extension.
//
// Introduces the mspcs/sspcs scratch CSRs holding an alternate stack
// pointer, and four instructions (mcspspush/mcspspop at machine level and
// scspspush/scspspop at supervisor level) that conditionally swap the
// current stack pointer (x2) with the alternate one, based on the
// sppush/psppush bits in mistatus/sistatus.

// The alternate stack pointers (mspcs/sspcs) and the shared conditional
// stack-pointer-swap primitives live in this extension. They are forward
// declared in aclic_regs.sail (loaded before sys) so that the Smip/Ssip
// interrupt-handler push at trap entry can call them without depending on
// this module; when Smcsps/Sscsps is not enabled the primitives are no-ops.

// The alternate stack pointers. Full XLEN-wide WARL registers.
register mspcs : xlenbits = zeros()
register sspcs : xlenbits = zeros()

// Access the per-privilege alternate stack pointer.
function get_spcs(priv : Privilege) -> xlenbits =
  match priv {
    Supervisor => sspcs,
    _          => mspcs,
  }

function set_spcs(priv : Privilege, v : xlenbits) -> unit =
  match priv {
    Supervisor => sspcs = v,
    _          => mspcs = v,
  }

// Is the conditional-stack-pointer-swap extension enabled at `priv`?
function csps_enabled(priv : Privilege) -> bool =
  match priv {
    Supervisor => currentlyEnabled(Ext_Sscsps),
    _          => currentlyEnabled(Ext_Smcsps),
  }

// Push-mode swap: latch sppush into psppush and, if sppush is set, swap the
// current stack pointer with the alternate one and clear sppush. When the
// relevant extension is not enabled this is a no-op, matching the "viewed
// as a NOP" wording of the Smip/Ssip spec, so a Smip/Ssip push without
// Smcsps/Sscsps simply skips the stack-pointer swap.
function xcsps_push_swap(priv : Privilege) -> unit = {
  if csps_enabled(priv) then {
    set_psppush(priv, get_sppush(priv));
    if get_sppush(priv) == 0b1 then {
      let tmp = X(sp);
      X(sp) = get_spcs(priv);
      set_spcs(priv, tmp);
      set_sppush(priv, 0b0);
    }
  }
}

// Pop-mode swap: restore sppush from psppush and, if psppush is set, swap
// the current stack pointer with the alternate one and clear psppush. This
// is the exact inverse of xcsps_push_swap, so it is also used to unwind a
// swap performed at interrupt trap entry when a subsequent push store
// faults.
function xcsps_pop_swap(priv : Privilege) -> unit = {
  if csps_enabled(priv) then {
    set_sppush(priv, get_psppush(priv));
    if get_psppush(priv) == 0b1 then {
      let tmp = get_spcs(priv);
      set_spcs(priv, X(sp));
      set_psppush(priv, 0b0);
      X(sp) = tmp;
    }
  }
}

mapping clause csr_name_map = 0x349 <-> "mspcs"


mapping clause csr_name_map = 0x149 <-> "sspcs"

// Supervisor access to sspcs is additionally gated by the ACLIC bit
// (mstateen0 bit 53); that check is applied centrally in
// `stateen_allows_CSR_access`.
function clause is_CSR_accessible(0x349, priv, _) =
  currentlyEnabled(Ext_Smcsps) & priv == Machine
function clause is_CSR_accessible(0x149, priv, _) =
  currentlyEnabled(Ext_Sscsps) & (priv == Machine | priv == Supervisor)

function clause read_CSR(0x349) = mspcs
function clause read_CSR(0x149) = sspcs

function clause write_CSR(0x349, value) = { mspcs = value; Ok(mspcs) }
function clause write_CSR(0x149, value) = { sspcs = value; Ok(sspcs) }

// The stack pointer register (x2) is the `sp` regidx defined in core/types.sail.


// -------------------------------------------------------------------------
// mcspspush - conditional stack pointer swap (push mode), machine level.

// -------------------------------------------------------------------------
union clause instruction = MCSPSPUSH : unit

mapping clause encdec = MCSPSPUSH()
  <-> 0b0011000 @ 0b01001 @ 0b00010 @ 0b000 @ 0b00010 @ 0b1110011
      when currentlyEnabled(Ext_Smcsps)

function clause execute MCSPSPUSH() = {
  if   cur_privilege != Machine
  then Illegal_Instruction()
  else {
    xcsps_push_swap(Machine);
    RETIRE_SUCCESS
  }
}


mapping clause assembly = MCSPSPUSH() <-> "mcspspush" ^ spc() ^ "sp" ^ sep() ^ "sp"

// -------------------------------------------------------------------------
// mcspspop - conditional stack pointer swap (pop mode), machine level.
// -------------------------------------------------------------------------
union clause instruction = MCSPSPOP : unit

mapping clause encdec = MCSPSPOP()
  <-> 0b0011000 @ 0b01100 @ 0b00010 @ 0b000 @ 0b00010 @ 0b1110011
      when currentlyEnabled(Ext_Smcsps)

function clause execute MCSPSPOP() = {
  if   cur_privilege != Machine
  then Illegal_Instruction()
  else {
    xcsps_pop_swap(Machine);
    RETIRE_SUCCESS
  }
}


mapping clause assembly = MCSPSPOP() <-> "mcspspop" ^ spc() ^ "sp" ^ sep() ^ "sp"

// -------------------------------------------------------------------------
// scspspush - conditional stack pointer swap (push mode), supervisor level.
// -------------------------------------------------------------------------
union clause instruction = SCSPSPUSH : unit

mapping clause encdec = SCSPSPUSH()
  <-> 0b0000100 @ 0b01001 @ 0b00010 @ 0b000 @ 0b00010 @ 0b1110011
      when currentlyEnabled(Ext_Sscsps)

function clause execute SCSPSPUSH() = {
  if   not(cur_privilege == Machine | cur_privilege == Supervisor)
  then Illegal_Instruction()
  else {
    xcsps_push_swap(Supervisor);
    RETIRE_SUCCESS
  }
}


mapping clause assembly = SCSPSPUSH() <-> "scspspush" ^ spc() ^ "sp" ^ sep() ^ "sp"

// -------------------------------------------------------------------------
// scspspop - conditional stack pointer swap (pop mode), supervisor level.
// -------------------------------------------------------------------------
union clause instruction = SCSPSPOP : unit

mapping clause encdec = SCSPSPOP()
  <-> 0b0000100 @ 0b01100 @ 0b00010 @ 0b000 @ 0b00010 @ 0b1110011
      when currentlyEnabled(Ext_Sscsps)

function clause execute SCSPSPOP() = {
  if   not(cur_privilege == Machine | cur_privilege == Supervisor)
  then Illegal_Instruction()
  else {
    xcsps_pop_swap(Supervisor);
    RETIRE_SUCCESS
  }
}


mapping clause assembly = SCSPSPOP() <-> "scspspop" ^ spc() ^ "sp" ^ sep() ^ "sp"
