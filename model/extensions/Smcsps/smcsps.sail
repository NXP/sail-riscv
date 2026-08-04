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

// The alternate stack pointers. Full XLEN-wide WARL registers.
register mspcs : xlenbits = zeros()
register sspcs : xlenbits = zeros()

mapping clause csr_name_map = 0x349 <-> "mspcs"
mapping clause csr_name_map = 0x149 <-> "sspcs"

// Smstateen bit 53 (ACLIC) gates supervisor access to sspcs. The ACLIC bit
// is not yet modeled in Mstateen0, so this check currently always passes.
// TODO: gate on mstateen0 bit 53 once the ACLIC state-enable bit is added.
function aclic_stateen_ok(priv : Privilege) -> bool =
  match priv {
    Machine    => true,
    Supervisor => true,
    _          => false,
  }


function clause is_CSR_accessible(0x349, priv, _) =
  currentlyEnabled(Ext_Smcsps) & priv == Machine
function clause is_CSR_accessible(0x149, priv, _) =
  currentlyEnabled(Ext_Sscsps) & (priv == Machine | priv == Supervisor) & aclic_stateen_ok(priv)

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
    set_psppush(Machine, get_sppush(Machine));
    if get_sppush(Machine) == 0b1 then {
      let tmp = X(sp);
      X(sp) = mspcs;
      mspcs = tmp;
      set_sppush(Machine, 0b0);
    };
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
    set_sppush(Machine, get_psppush(Machine));
    if get_psppush(Machine) == 0b1 then {
      let tmp = mspcs;
      mspcs = X(sp);
      set_psppush(Machine, 0b0);
      X(sp) = tmp;
    };
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
    set_psppush(Supervisor, get_sppush(Supervisor));
    if get_sppush(Supervisor) == 0b1 then {
      let tmp = X(sp);
      X(sp) = sspcs;
      sspcs = tmp;
      set_sppush(Supervisor, 0b0);
    };
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
    set_sppush(Supervisor, get_psppush(Supervisor));
    if get_psppush(Supervisor) == 0b1 then {
      let tmp = sspcs;
      sspcs = X(sp);
      set_psppush(Supervisor, 0b0);
      X(sp) = tmp;
    };
    RETIRE_SUCCESS
  }
}

mapping clause assembly = SCSPSPOP() <-> "scspspop" ^ spc() ^ "sp" ^ sep() ^ "sp"
