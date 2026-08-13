// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// Indirect CSR access framework (Smcsrind / Sscsrind).
//
// This provides the miselect/mireg indirection registers for the machine
// level and siselect/sireg for the supervisor level, together with the
// alternate access registers mireg2..mireg6 / sireg2..sireg6, and a
// scattered dispatch mechanism keyed on the current *iselect value.
// Extensions such as the AIA (Smaia/Ssaia) register clauses of
// indirect_read/indirect_write to expose their indirectly-accessed
// registers without having to touch this file.
//
// The dispatch functions take three inputs:
//   - the privilege level at which the access is being performed (Machine
//     or Supervisor), so that a single select value can map to different
//     underlying state for the M and S views;
//   - the current *iselect value;
//   - an alias-register index in 1 .. 6 identifying which of the access
//     registers (*ireg == 1, *ireg2 == 2, ..., *ireg6 == 6) is used, so a
//     handler can expose wider or multiple sub-registers behind one select.
//
// See the "RISC-V Indirect CSR Access" specification (Smcsrind/Sscsrind)
// and the AIA specification for the required behaviour.

// The select registers are WARL. Without an IMSIC, the AIA only requires
// the iprio array region (0x30 .. 0x3F for the machine level and the
// analogous supervisor region). We allow the full low range so that
// future extensions (e.g. IMSIC file selects) can register handlers.
//
// The width of the select registers is xlen, but only a small number of
// low bits are meaningful in this configuration. Bits that are not needed
// to represent any implemented select value read as zero.

// The alias-register index distinguishes the access-register aliases that
// share a single *iselect value: *ireg (1) and *ireg2 .. *ireg6 (2 .. 6).
type indirect_alias = range(1, 6)

// Reset value is unspecified by the spec; we choose zero.
register miselect : xlenbits = zeros()
register siselect : xlenbits = zeros()

// A scattered function that indicates whether a given (privilege, select,
// alias) triple has an implemented indirect register. Handlers register a
// clause returning true. The default (see postlude/csr_end.sail fallback)
// returns false, which causes an illegal instruction.
val indirect_csr_implemented : (Privilege, xlenbits, indirect_alias) -> bool
scattered function indirect_csr_implemented

// Read the indirectly-selected register. Only called when
// indirect_csr_implemented(priv, select, alias) is true.
val indirect_read : (Privilege, xlenbits, indirect_alias) -> xlenbits
scattered function indirect_read

// Write the indirectly-selected register. Only called when
// indirect_csr_implemented(priv, select, alias) is true. The last argument
// is the full xlen value to write; handlers apply their own WARL masking.
val indirect_write : (Privilege, xlenbits, indirect_alias, xlenbits) -> unit
scattered function indirect_write

// Default fallbacks: no register implemented. NOTE: because scattered
// function clauses are matched in definition order, the catch-all
// defaults must be the LAST clauses. They are therefore defined in the
// postlude (postlude/csr_end.sail) after all extensions (e.g. AIA) have
// registered their specific clauses.


// Legalize a value written to an *iselect register. We keep it simple and
// store the value as-is (masked to xlen); illegal-select detection happens
// at *ireg access time via indirect_csr_implemented.
function legalize_iselect(v : xlenbits) -> xlenbits = v

// -------------------------------------------------------------------------
// Shared access helpers, parameterised by privilege / select register.
// -------------------------------------------------------------------------

// The *iselect value in force for the given privilege level.
function indirect_select_of(priv : Privilege) -> xlenbits =
  match priv {
    Machine => miselect,
    _       => siselect,
  }

// Whether the *ireg<alias> access register for the given privilege is
// accessible: the base indirection extension must be enabled and the
// current select/alias must map to an implemented register.
function indirect_reg_accessible(priv : Privilege, alias : indirect_alias) -> bool = {
  let enabled : bool = match priv {
    Machine => currentlyEnabled(Ext_Smcsrind),
    _       => currentlyEnabled(Ext_Sscsrind),
  };
  enabled & indirect_csr_implemented(priv, indirect_select_of(priv), alias)
}

// Read an *ireg<alias> access register. Guarded by indirect_reg_accessible
// via is_CSR_accessible; reads as zero when nothing is selected.
function indirect_reg_read(priv : Privilege, alias : indirect_alias) -> xlenbits = {
  let select = indirect_select_of(priv);
  if indirect_csr_implemented(priv, select, alias)
  then indirect_read(priv, select, alias)
  else zeros()
}

// Write an *ireg<alias> access register, returning the post-write read-back
// value (the *ireg CSRs report the current register contents on write).
function indirect_reg_write(priv : Privilege, alias : indirect_alias, value : xlenbits) -> xlenbits = {
  let select = indirect_select_of(priv);
  indirect_write(priv, select, alias, value);
  indirect_read(priv, select, alias)
}

// -------------------------------------------------------------------------
// miselect (0x350) and the machine access registers mireg / mireg2 .. mireg6
// -------------------------------------------------------------------------

mapping clause csr_name_map = 0x350 <-> "miselect"
mapping clause csr_name_map = 0x351 <-> "mireg"
mapping clause csr_name_map = 0x352 <-> "mireg2"
mapping clause csr_name_map = 0x353 <-> "mireg3"
mapping clause csr_name_map = 0x355 <-> "mireg4"
mapping clause csr_name_map = 0x356 <-> "mireg5"
mapping clause csr_name_map = 0x357 <-> "mireg6"

function clause is_CSR_accessible(0x350, _, _) = currentlyEnabled(Ext_Smcsrind)

function clause read_CSR(0x350) = miselect

function clause write_CSR(0x350, value) = {
  miselect = legalize_iselect(value);
  Ok(miselect)
}

// The *ireg access registers are only accessible when the currently
// selected value maps to an implemented register for that alias index;
// otherwise accessing them raises an illegal instruction.
function clause is_CSR_accessible(0x351, _, _) = indirect_reg_accessible(Machine, 1)
function clause is_CSR_accessible(0x352, _, _) = indirect_reg_accessible(Machine, 2)
function clause is_CSR_accessible(0x353, _, _) = indirect_reg_accessible(Machine, 3)
function clause is_CSR_accessible(0x355, _, _) = indirect_reg_accessible(Machine, 4)
function clause is_CSR_accessible(0x356, _, _) = indirect_reg_accessible(Machine, 5)
function clause is_CSR_accessible(0x357, _, _) = indirect_reg_accessible(Machine, 6)

function clause read_CSR(0x351) = indirect_reg_read(Machine, 1)
function clause read_CSR(0x352) = indirect_reg_read(Machine, 2)
function clause read_CSR(0x353) = indirect_reg_read(Machine, 3)
function clause read_CSR(0x355) = indirect_reg_read(Machine, 4)
function clause read_CSR(0x356) = indirect_reg_read(Machine, 5)
function clause read_CSR(0x357) = indirect_reg_read(Machine, 6)

function clause write_CSR(0x351, value) = Ok(indirect_reg_write(Machine, 1, value))
function clause write_CSR(0x352, value) = Ok(indirect_reg_write(Machine, 2, value))
function clause write_CSR(0x353, value) = Ok(indirect_reg_write(Machine, 3, value))
function clause write_CSR(0x355, value) = Ok(indirect_reg_write(Machine, 4, value))
function clause write_CSR(0x356, value) = Ok(indirect_reg_write(Machine, 5, value))
function clause write_CSR(0x357, value) = Ok(indirect_reg_write(Machine, 6, value))

// -------------------------------------------------------------------------
// siselect (0x150) and the supervisor access registers sireg / sireg2 .. sireg6
// -------------------------------------------------------------------------

mapping clause csr_name_map = 0x150 <-> "siselect"
mapping clause csr_name_map = 0x151 <-> "sireg"
mapping clause csr_name_map = 0x152 <-> "sireg2"
mapping clause csr_name_map = 0x153 <-> "sireg3"
mapping clause csr_name_map = 0x155 <-> "sireg4"
mapping clause csr_name_map = 0x156 <-> "sireg5"
mapping clause csr_name_map = 0x157 <-> "sireg6"

// Note: access to the supervisor-level indirect CSRs (siselect/sireg*)
// from a privilege below M is additionally gated by the mstateen0.CSRIND
// bit (and hstateen0 for VS/VU) when Smstateen is implemented. Because of
// module interdependency (core cannot depend on Stateen), that gate is
// applied centrally in `stateen_allows_CSR_access`.
function clause is_CSR_accessible(0x150, _, _) = currentlyEnabled(Ext_Sscsrind)

function clause read_CSR(0x150) = siselect

function clause write_CSR(0x150, value) = {
  siselect = legalize_iselect(value);
  Ok(siselect)
}

function clause is_CSR_accessible(0x151, _, _) = indirect_reg_accessible(Supervisor, 1)
function clause is_CSR_accessible(0x152, _, _) = indirect_reg_accessible(Supervisor, 2)
function clause is_CSR_accessible(0x153, _, _) = indirect_reg_accessible(Supervisor, 3)
function clause is_CSR_accessible(0x155, _, _) = indirect_reg_accessible(Supervisor, 4)
function clause is_CSR_accessible(0x156, _, _) = indirect_reg_accessible(Supervisor, 5)
function clause is_CSR_accessible(0x157, _, _) = indirect_reg_accessible(Supervisor, 6)

function clause read_CSR(0x151) = indirect_reg_read(Supervisor, 1)
function clause read_CSR(0x152) = indirect_reg_read(Supervisor, 2)
function clause read_CSR(0x153) = indirect_reg_read(Supervisor, 3)
function clause read_CSR(0x155) = indirect_reg_read(Supervisor, 4)
function clause read_CSR(0x156) = indirect_reg_read(Supervisor, 5)
function clause read_CSR(0x157) = indirect_reg_read(Supervisor, 6)

function clause write_CSR(0x151, value) = Ok(indirect_reg_write(Supervisor, 1, value))
function clause write_CSR(0x152, value) = Ok(indirect_reg_write(Supervisor, 2, value))
function clause write_CSR(0x153, value) = Ok(indirect_reg_write(Supervisor, 3, value))
function clause write_CSR(0x155, value) = Ok(indirect_reg_write(Supervisor, 4, value))
function clause write_CSR(0x156, value) = Ok(indirect_reg_write(Supervisor, 5, value))
function clause write_CSR(0x157, value) = Ok(indirect_reg_write(Supervisor, 6, value))
