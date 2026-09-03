// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// ACLIC (Advanced Core-Local Interrupt Controller) hart-local interrupt
// domain control (Smidctrl/Ssidctrl).
//
// The ACLIC operates the per-domain APLIC source state (pending / enable /
// target / sourcecfg, defined in aplic/aplic_domain.sail and
// aplic/aplic_regs.sail) entirely through hart-local indirect CSRs rather
// than the memory-mapped APLIC window. It is mutually exclusive with the
// IMSIC: both drive xEIP, and validate_config.sail forbids configuring both.
//
// The two-domain APLIC hierarchy is reused unchanged:
//   domain 0 = machine-level domain -> drives MEIP (Machine)
//   domain 1 = supervisor-level domain -> drives SEIP (Supervisor)
// (see aplic_domain_privilege). The ACLIC therefore maps a privilege to its
// domain with the inverse of that mapping.
//
// This module implements:
//   - the eip/eie indirect aliases (miselect/siselect 0x80 .. 0xFF via
//     mireg/sireg, alias index 1), aliasing the connected domain's
//     pending / enable bit arrays;
//   - the acliciprio / aclicsourcecfg indirect registers (Smidctrl 0x1000
//     range) exposing the connected domain's per-source priority and
//     source-configuration;
//   - xtopei (mtopei 0x35C / stopei 0x15C) reporting and claim, using the
//     ACLIC layout (IID in bits 25:16, IPRIO in bits 7:0);
//   - the ext_intctl_topei delivery clause routing xEIP from the domain's
//     arbitrated top interrupt.


// -------------------------------------------------------------------------
// Privilege / domain mapping
// -------------------------------------------------------------------------

// The APLIC domain that a privilege's ACLIC view operates on. This is the
// inverse of aplic_domain_privilege: Machine -> domain 0, Supervisor ->
// domain 1.
function aclic_domain_of(priv : Privilege) -> aplic_domain_index =
  match priv {
    Machine => 0,
    _       => 1,
  }

// Whether the ACLIC is enabled for a given privilege: the platform must have
// the ACLIC configured, the domain must exist in this build, and the
// corresponding Smidctrl/Ssidctrl extension must be currently enabled.
function aclic_enabled_for(priv : Privilege) -> bool = {
  if not(plat_have_aclic) then return false;
  match priv {
    Machine    => currentlyEnabled(Ext_Smidctrl),
    Supervisor => currentlyEnabled(Ext_Ssidctrl) & plat_aplic_num_domains >= 2,
    _          => false,
  }
}

// -------------------------------------------------------------------------
// eip / eie indirect aliases (alias index 1, selects 0x80 .. 0xFF)
// -------------------------------------------------------------------------
//
// The ACLIC aliases the connected domain's pending bits onto the eip selects
// and its enable bits onto the eie selects, reusing the shared AIA
// interrupt-file select decode (aia_select_is_eip / aia_select_is_eie /
// aia_eixx_word_index) already used by the IMSIC. The APLIC models a single
// 32-bit source word per domain (APLIC_NUM_SOURCES == 32), so only word 0
// carries source state; higher word indices read as zero and ignore writes.
// Inactive sources and reserved source 0 read as zero (enforced by the
// APLIC word accessors' active-source masking).

// Whether a select value addresses an ACLIC indirect register at alias 1.
function aclic_select_implemented(select : xlenbits) -> bool =
  aia_select_is_eip(select) | aia_select_is_eie(select)

// Read the eip/eie word (RV32) or word pair (RV64) selected by an eip/eie
// select value for the given privilege's domain. Only word 0 has state.
function aclic_read_array(priv : Privilege, is_eip : bool, idx : aia_word_index) -> xlenbits = {
  let domain = aclic_domain_of(priv);
  let lo : bits(32) =
    if idx == 0 then {
      if is_eip then aplic_read_pending_word(domain) else aplic_read_enable_word(domain)
    } else zeros();
  if xlen == 64 then {
    // On RV64 an even select addresses the pair (idx, idx+1); the high word
    // is always the next index, which for the single-word APLIC is zero.
    if aia_eixx_select_accessible(idx) then zero_extend(lo) else zeros()
  } else {
    zero_extend(lo)
  }
}

// Write the eip/eie word(s) selected by an eip/eie select value. Only word 0
// drives the domain's pending / enable arrays; higher words are ignored. The
// APLIC word accessors apply active-source masking and level-sensitivity
// rules, so inactive sources and source 0 are left untouched.
function aclic_write_array(priv : Privilege, is_eip : bool, idx : aia_word_index, value : xlenbits) -> unit = {
  let domain = aclic_domain_of(priv);
  if idx == 0 then {
    let lo = value[31 .. 0];
    if is_eip then aplic_write_pending_word(domain, lo) else aplic_write_enable_word(domain, lo);
  }
  // On RV64 the paired high word (idx+1) addresses word 1, which has no
  // state, so no write is performed there.
}

function aclic_indirect_read(priv : Privilege, select : xlenbits) -> xlenbits = {
  if aia_select_is_eip(select) then aclic_read_array(priv, true, aia_eixx_word_index(select))
  else if aia_select_is_eie(select) then aclic_read_array(priv, false, aia_eixx_word_index(select))
  else zeros()
}

function aclic_indirect_write(priv : Privilege, select : xlenbits, value : xlenbits) -> unit = {
  if aia_select_is_eip(select) then aclic_write_array(priv, true, aia_eixx_word_index(select), value)
  else if aia_select_is_eie(select) then aclic_write_array(priv, false, aia_eixx_word_index(select), value)
  else ()
}

// Register the ACLIC eip/eie aliases with the indirect CSR framework at
// alias index 1 (mireg/sireg). Availability is gated by Smidctrl/Ssidctrl
// and by the ACLIC being configured.
function clause indirect_csr_implemented((Machine, select, 1) if aclic_select_implemented(select)) =
  aclic_enabled_for(Machine)
function clause indirect_csr_implemented((Supervisor, select, 1) if aclic_select_implemented(select)) =
  aclic_enabled_for(Supervisor)

function clause indirect_read((Machine, select, 1) if aclic_select_implemented(select) & plat_have_aclic) =
  aclic_indirect_read(Machine, select)
function clause indirect_read((Supervisor, select, 1) if aclic_select_implemented(select) & plat_have_aclic) =
  aclic_indirect_read(Supervisor, select)

function clause indirect_write((Machine, select, 1, value) if aclic_select_implemented(select) & plat_have_aclic) =
  aclic_indirect_write(Machine, select, value)
function clause indirect_write((Supervisor, select, 1, value) if aclic_select_implemented(select) & plat_have_aclic) =
  aclic_indirect_write(Supervisor, select, value)

// -------------------------------------------------------------------------
// acliciprio / aclicsourcecfg indirect registers (selects 0x1000 .. 0x10FF)
// -------------------------------------------------------------------------
//
// The Smidctrl/Ssidctrl control range 0x1000 .. 0x10FF exposes the connected
// APLIC domain's per-source target-priority (acliciprio, via xireg / alias 1)
// and source-configuration (aclicsourcecfg, via xireg2 / alias 2 and xireg3 /
// alias 3) registers. The reserved xireg4 .. xireg6 aliases in this range
// raise an illegal instruction (they are simply not registered here, so the
// default unimplemented clauses apply); the exception is xireg4 at exactly
// select 0x1000, which is claimed by Smip's miconfig/siconfig in
// extensions/aclic/aclic_regs.sail.
//
// Packing (following the AIA interrupt-file convention already used for the
// eip/eie aliases): a select offset s addresses APLIC source base 4*s. On
// RV32 the xireg register spans 4 iprio bytes / a pair of 16-bit sourcecfg
// lanes; on RV64 only even selects exist (odd selects raise an illegal
// instruction) and the 64-bit register spans 8 iprio bytes / 4 sourcecfg
// lanes, i.e. the RV64 register covers the two consecutive RV32 words.
// APLIC has APLIC_NUM_SOURCES sources total; source 0 and out-of-range
// sources are read-only zero and ignore writes.

// Whether a select value lies in the ACLIC control range.
function aclic_ctrl_select_in_range(select : xlenbits) -> bool =
  unsigned(select) >= 4096 & unsigned(select) <= 4351

// The 0-based offset of a select within the ACLIC control range.
function aclic_ctrl_select_off(select : xlenbits) -> range(0, 255) = {
  let off = unsigned(select) - 4096;
  if off >= 0 & off <= 255 then off else 0
}

// On RV64 only even selects in the control range are accessible; an odd
// select raises an illegal instruction (implemented returns false).
function aclic_ctrl_select_accessible(select : xlenbits) -> bool =
  if xlen == 64 then (unsigned(select) % 2) == 0 else true


// acliciprio: read the packed iprio word for select offset s. Each 8-bit
// lane i holds target[4*s + i].iprio; inactive / reserved / out-of-range
// sources read as zero.
function aclic_read_iprio(priv : Privilege, s : range(0, 255)) -> xlenbits = {
  let domain = aclic_domain_of(priv);
  let count = if xlen == 64 then 8 else 4;
  let base = 4 * s;
  var result : xlenbits = zeros();
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    let i = source - base;
    if i >= 0 & i < count & aplic_source_active(domain, source) then {
      let iprio = aplic_target_iprio(aplic_target[domain][source]);
      result = result | (zero_extend(iprio) << (8 * i));
    }
  };
  result
}

// acliciprio: write the packed iprio word. For each active in-range source
// the iprio field is updated (preserving the hart-index field and applying
// the target WARL legalization); other sources are left untouched.
function aclic_write_iprio(priv : Privilege, s : range(0, 255), value : xlenbits) -> unit = {
  let domain = aclic_domain_of(priv);
  let count = if xlen == 64 then 8 else 4;
  let base = 4 * s;
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    let i = source - base;
    if i >= 0 & i < count & aplic_source_active(domain, source) then {
      let iprio : bits(8) = slice(value, 8 * i, 8);
      let newt = [aplic_target[domain][source] with 7 .. 0 = iprio];
      aplic_target[domain] = [aplic_target[domain] with source = aplic_legalize_target(newt)];
    }
  }
}

// aclicsourcecfg: the APLIC source that lane 0 of the given alias's register
// maps to for select offset s. alias 2 (xireg2) starts at 4*s; alias 3
// (xireg3) starts one register-worth of lanes higher.
function aclic_sourcecfg_base(s : range(0, 255), alias : indirect_alias) -> int = {
  let lanes = xlen / 16;
  let base = 4 * s;
  if alias == 2 then base else base + lanes
}

// aclicsourcecfg: read the packed lower-16-bits sourcecfg word. Each 16-bit
// lane holds sourcecfg[source][15:0]; source 0 / out-of-range read as zero.
function aclic_read_sourcecfg(priv : Privilege, s : range(0, 255), alias : indirect_alias) -> xlenbits = {
  let domain = aclic_domain_of(priv);
  let lanes = xlen / 16;
  let base = aclic_sourcecfg_base(s, alias);
  var result : xlenbits = zeros();
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    let lane = source - base;
    if lane >= 0 & lane < lanes then {
      let cfg16 = aplic_sourcecfg[domain][source][15 .. 0];
      result = result | (zero_extend(cfg16) << (16 * lane));
    }
  };
  result
}

// aclicsourcecfg: write the packed lower-16-bits sourcecfg word, applying the
// APLIC sourcecfg WARL legalization per source. Source 0 and out-of-range
// sources are left untouched (source 0 is read-only zero).
function aclic_write_sourcecfg(priv : Privilege, s : range(0, 255), alias : indirect_alias, value : xlenbits) -> unit = {
  let domain = aclic_domain_of(priv);
  let lanes = xlen / 16;
  let base = aclic_sourcecfg_base(s, alias);
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    let lane = source - base;
    if lane >= 0 & lane < lanes then {
      let cfg16 : bits(16) = slice(value, 16 * lane, 16);
      let full : bits(32) = zero_extend(cfg16);
      let was_active = aplic_source_active(domain, source);
      let was_delegated = aplic_sourcecfg_is_delegated(aplic_sourcecfg[domain][source]);
      aplic_sourcecfg[domain] = [aplic_sourcecfg[domain] with source = aplic_legalize_sourcecfg(domain, source, full)];
      let now_delegated = aplic_sourcecfg_is_delegated(aplic_sourcecfg[domain][source]);
      // If a source is made inactive, its pending/enable/target become
      // read-only zero; clear the stored state so reads are consistent
      // (mirrors the memory-mapped APLIC sourcecfg write path).
      if was_active & not(aplic_source_active(domain, source)) then {
        aplic_pending[domain] = [aplic_pending[domain] with source = bitzero];
        aplic_enable[domain] = [aplic_enable[domain] with source = bitzero];
        aplic_target[domain][source] = zeros();
      };
      // Delegation transition on a parent domain: when a source stops being
      // delegated (D 1 -> 0) the child domain no longer sees it, so any state
      // programmed there while delegated must be cleared. The tested hierarchy
      // has domain 0's child at domain 1.
      if was_delegated & not(now_delegated) & aplic_domain_has_children(domain) then {
        let child : aplic_domain_index = 1;
        aplic_pending[child] = [aplic_pending[child] with source = bitzero];
        aplic_enable[child] = [aplic_enable[child] with source = bitzero];
        aplic_target[child][source] = zeros();
        aplic_sourcecfg[child] = [aplic_sourcecfg[child] with source = zeros()];
      }
    }
  }
}


// Register acliciprio (alias 1) and aclicsourcecfg (alias 2 / alias 3) with
// the indirect CSR framework over the 0x1000 .. 0x10FF control range.
function clause indirect_csr_implemented((Machine, select, 1) if aclic_ctrl_select_in_range(select)) =
  aclic_enabled_for(Machine) & aclic_ctrl_select_accessible(select)
function clause indirect_csr_implemented((Supervisor, select, 1) if aclic_ctrl_select_in_range(select)) =
  aclic_enabled_for(Supervisor) & aclic_ctrl_select_accessible(select)
function clause indirect_csr_implemented((Machine, select, 2) if aclic_ctrl_select_in_range(select)) =
  aclic_enabled_for(Machine) & aclic_ctrl_select_accessible(select)
function clause indirect_csr_implemented((Supervisor, select, 2) if aclic_ctrl_select_in_range(select)) =
  aclic_enabled_for(Supervisor) & aclic_ctrl_select_accessible(select)
function clause indirect_csr_implemented((Machine, select, 3) if aclic_ctrl_select_in_range(select)) =
  aclic_enabled_for(Machine) & aclic_ctrl_select_accessible(select)
function clause indirect_csr_implemented((Supervisor, select, 3) if aclic_ctrl_select_in_range(select)) =
  aclic_enabled_for(Supervisor) & aclic_ctrl_select_accessible(select)

function clause indirect_read((Machine, select, 1) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_read_iprio(Machine, aclic_ctrl_select_off(select))
function clause indirect_read((Supervisor, select, 1) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_read_iprio(Supervisor, aclic_ctrl_select_off(select))
function clause indirect_read((Machine, select, 2) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_read_sourcecfg(Machine, aclic_ctrl_select_off(select), 2)
function clause indirect_read((Supervisor, select, 2) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_read_sourcecfg(Supervisor, aclic_ctrl_select_off(select), 2)
function clause indirect_read((Machine, select, 3) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_read_sourcecfg(Machine, aclic_ctrl_select_off(select), 3)
function clause indirect_read((Supervisor, select, 3) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_read_sourcecfg(Supervisor, aclic_ctrl_select_off(select), 3)

function clause indirect_write((Machine, select, 1, value) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_write_iprio(Machine, aclic_ctrl_select_off(select), value)
function clause indirect_write((Supervisor, select, 1, value) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_write_iprio(Supervisor, aclic_ctrl_select_off(select), value)
function clause indirect_write((Machine, select, 2, value) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_write_sourcecfg(Machine, aclic_ctrl_select_off(select), 2, value)
function clause indirect_write((Supervisor, select, 2, value) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_write_sourcecfg(Supervisor, aclic_ctrl_select_off(select), 2, value)
function clause indirect_write((Machine, select, 3, value) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_write_sourcecfg(Machine, aclic_ctrl_select_off(select), 3, value)
function clause indirect_write((Supervisor, select, 3, value) if aclic_ctrl_select_in_range(select) & plat_have_aclic) =
  aclic_write_sourcecfg(Supervisor, aclic_ctrl_select_off(select), 3, value)

// -------------------------------------------------------------------------
// xtopei (mtopei 0x35C / stopei 0x15C)

// -------------------------------------------------------------------------
//
// The ACLIC reports its top interrupt through xtopei with the ACLIC layout:
//   bits 25:16 : interrupt identity (IID)
//   bits  7:0  : interrupt priority (IPRIO)
// A write claims (reads and clears) the current top interrupt. The
// arbitration is the APLIC's own priority arbitration (aplic_topi); the
// ACLIC does not implement eidelivery/eithreshold, so any enabled source
// contributes.

function aclic_read_topei(priv : Privilege) -> xlenbits = {
  let domain = aclic_domain_of(priv);
  let (identity, priority) = aplic_topi(domain);
  if identity == zeros() then zeros()
  else {
    let idbits : xlenbits = zero_extend(identity);
    let priobits : xlenbits = zero_extend(priority);
    (idbits << 16) | priobits
  }
}

function aclic_claim_topei(priv : Privilege) -> unit = {
  let domain = aclic_domain_of(priv);
  let _ = aplic_claim(domain);
  ()
}

// The ACLIC's contribution to the shared external-interrupt-controller claim
// interface (ext_intctl_claim, declared in core/external_interrupt_ctl.sail).
// Guarded on plat_have_aclic so it fires only when the ACLIC is configured;
// it claims the connected domain's top interrupt (clearing its pending bit)
// and returns the claimed (identity, priority). Used by the mtopsi/stopsi
// claim write via the generic ext_intctl_claim hook.
function clause ext_intctl_claim(Machine if plat_have_aclic) =
  if aclic_enabled_for(Machine) then aplic_claim(aclic_domain_of(Machine))
  else (zeros(), zeros())

function clause ext_intctl_claim(priv if plat_have_aclic) =
  if currentlyEnabled(Ext_S) & aclic_enabled_for(Supervisor)
  then aplic_claim(aclic_domain_of(Supervisor))
  else (zeros(), zeros())


// Register the ACLIC's mtopei/stopei clauses. The csr_name_map entries for
// 0x35C/0x15C are defined in sys/imsic.sail (unconditionally), so only the
// access/read/write clauses are added here, guarded on plat_have_aclic. The
// IMSIC's clauses for the same CSR numbers are guarded on plat_have_imsic;
// the ACLIC and IMSIC are mutually exclusive (see validate_config.sail).
function clause is_CSR_accessible((0x35C, _, _) if plat_have_aclic) =
  aclic_enabled_for(Machine)
function clause is_CSR_accessible((0x15C, _, _) if plat_have_aclic) =
  aclic_enabled_for(Supervisor)

function clause read_CSR((0x35C) if plat_have_aclic) = aclic_read_topei(Machine)
function clause read_CSR((0x15C) if plat_have_aclic) = aclic_read_topei(Supervisor)

function clause write_CSR((0x35C, _) if plat_have_aclic) = {
  aclic_claim_topei(Machine);
  Ok(aclic_read_topei(Machine))
}
function clause write_CSR((0x15C, _) if plat_have_aclic) = {
  aclic_claim_topei(Supervisor);
  Ok(aclic_read_topei(Supervisor))
}

// -------------------------------------------------------------------------
// External interrupt delivery (ext_intctl_topei)
// -------------------------------------------------------------------------
//
// The ACLIC drives xEIP directly from the domain's arbitrated top interrupt,
// ignoring the APLIC direct-delivery idelivery/IE gate (the ACLIC has no
// idelivery register). These clauses fire only when the ACLIC is configured;
// the ACLIC is mutually exclusive with the IMSIC and with the memory-mapped
// APLIC delivery clauses (whose guards require plat_aplic_enabled).
function aclic_topei_for_privilege(priv : Privilege) -> (bits(11), bits(8)) = {
  if aclic_enabled_for(priv) then aplic_topi(aclic_domain_of(priv))
  else (zeros(), zeros())
}

function clause ext_intctl_topei(Machine if plat_have_aclic) =
  aclic_topei_for_privilege(Machine)

function clause ext_intctl_topei(priv if plat_have_aclic) =
  if currentlyEnabled(Ext_S)
  then aclic_topei_for_privilege(Supervisor)
  else (zeros(), zeros())
