// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// APLIC per-domain register STATE for the interrupt sources: the pending and
// enable bit arrays and the target registers. This file holds STATE and the
// small helper functions that operate on it; the memory-mapped decode of
// setip/setipnum/in_clrip/clripnum/setie/setienum/clrie/clrienum/target lives
// separately in aplic_mmio.sail. Keeping state and access apart lets a future
// access variant (ACLIC-style, or MSI-mode delivery) reuse this same state.

// Interrupt-pending bit per (domain, source). Source 0 is unused. For an
// inactive source these bits are read-only zero (enforced by the access
// helpers, which never set them for inactive sources).
register aplic_pending : vector(aplic_num_domains, bits(aplic_num_sources)) =
  [ zeros(), zeros() ]

// Interrupt-enable bit per (domain, source).
register aplic_enable : vector(aplic_num_domains, bits(aplic_num_sources)) =
  [ zeros(), zeros() ]

// target[domain][source] register (direct delivery layout):
//   bits 31:18 Hart Index (WLRL), bits 7:0 IPRIO (WARL, 1 .. 2^IPRIOLEN-1).
// For an inactive source this is read-only zero.
register aplic_target : vector(aplic_num_domains, vector(aplic_num_sources, bits(32))) =
  [ vector_init(0x0000_0000),
    vector_init(0x0000_0000) ]

// Extract the IPRIO (priority number) field of a target value.
function aplic_target_iprio(t : bits(32)) -> bits(8) = t[7 .. 0]

// Extract the Hart Index field of a target value.
function aplic_target_hart_index(t : bits(32)) -> bits(14) = t[31 .. 18]

// Legalize a value written to a target register in direct delivery mode.
// Only Hart Index (31:18) and IPRIO (7:0) are meaningful; other bits are
// reserved read-only zero. IPRIO of zero is legalized to 1 (WARL), since a
// priority number of zero is not allowed.
function aplic_legalize_target(data : bits(32)) -> bits(32) = {
  let hart_index = data[31 .. 18];
  let iprio = data[7 .. 0];
  let iprio_legal : bits(8) = if iprio == zeros() then 0x01 else iprio;
  hart_index @ zeros(10) @ iprio_legal
}

// Set the pending bit for a source if it is active. Used by setip/setipnum.
// In direct delivery mode a level-sensitive source's pending bit tracks its
// rectified input and cannot be set by software; the model has no wires, so
// level sources are never made pending here. Detached and edge sources can be
// set by software.
function aplic_set_pending(domain : aplic_domain_index, source : aplic_source_index) -> unit = {
  if source != 0 & aplic_source_active(domain, source) then {
    let sm = aplic_sourcecfg_sm(aplic_sourcecfg[domain][source]);
    if sm != SM_LEVEL1 & sm != SM_LEVEL0 then {
      aplic_pending[domain] = [aplic_pending[domain] with source = bitone];
    }
  }
}

// Clear the pending bit for a source if it is active. Used by in_clrip/
// clripnum and by a claim. As above, level-sensitive sources in direct mode
// cannot have their pending bit cleared this way; the model has no wires so
// this never applies.
function aplic_clear_pending(domain : aplic_domain_index, source : aplic_source_index) -> unit = {
  if source != 0 & aplic_source_active(domain, source) then {
    let sm = aplic_sourcecfg_sm(aplic_sourcecfg[domain][source]);
    if sm != SM_LEVEL1 & sm != SM_LEVEL0 then {
      aplic_pending[domain] = [aplic_pending[domain] with source = bitzero];
    }
  }
}

// Set / clear enable bit for a source if it is active. Used by setie/setienum
// and clrie/clrienum.
function aplic_set_enable(domain : aplic_domain_index, source : aplic_source_index) -> unit = {
  if source != 0 & aplic_source_active(domain, source)
  then aplic_enable[domain] = [aplic_enable[domain] with source = bitone];
}

function aplic_clear_enable(domain : aplic_domain_index, source : aplic_source_index) -> unit = {
  if source != 0
  then aplic_enable[domain] = [aplic_enable[domain] with source = bitzero];
}

// -------------------------------------------------------------------------
// Word-granular pending / enable accessors
// -------------------------------------------------------------------------
// These expose a domain's pending/enable bit arrays as single 32-bit words
// (bit i = source i), with inactive sources and reserved source 0 forced to
// zero. They are backing-store operations shared by the memory-mapped APLIC
// access path (setip[0]/setie[0] reads in aplic_mmio.sail) and by the ACLIC
// hart-local interrupt domain control (which aliases eip/eie onto these same
// per-domain arrays). Keeping them here in the STATE layer, rather than in a
// specific access/decode layer, lets both access paths reuse identical
// active-source masking and level-sensitivity rules.

// Bitmask of active sources in a domain (bit i set iff source i is active).
// Source 0 is never active. Used to mask word-granular pending/enable
// accesses so inactive and reserved sources read/write as zero.
function aplic_active_mask(domain : aplic_domain_index) -> bits(aplic_num_sources) = {
  var m : bits(aplic_num_sources) = zeros();
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    if aplic_source_active(domain, source) then m = [m with source = bitone];
  };
  m
}

// Word-granular pending read: the stored pending bit array masked to active
// sources (inactive sources and source 0 read as zero).
function aplic_read_pending_word(domain : aplic_domain_index) -> bits(aplic_num_sources) =
  aplic_pending[domain] & aplic_active_mask(domain)

// Word-granular enable read, masked to active sources.
function aplic_read_enable_word(domain : aplic_domain_index) -> bits(aplic_num_sources) =
  aplic_enable[domain] & aplic_active_mask(domain)

// Word-granular pending write (used by the ACLIC eip alias). For each active
// source the pending bit is driven to the corresponding value bit, honoring
// the same level-sensitivity restriction as aplic_set_pending /
// aplic_clear_pending (level sources in direct mode cannot be driven by
// software). Inactive sources and source 0 are left untouched.
function aplic_write_pending_word(domain : aplic_domain_index, value : bits(aplic_num_sources)) -> unit = {
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    if value[source] == bitone then aplic_set_pending(domain, source)
    else aplic_clear_pending(domain, source);
  }
}

// Word-granular enable write, honoring active-source masking.
function aplic_write_enable_word(domain : aplic_domain_index, value : bits(aplic_num_sources)) -> unit = {
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    if value[source] == bitone then aplic_set_enable(domain, source)
    else aplic_clear_enable(domain, source);
  }
}
