// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// APLIC interrupt domains: domaincfg and sourcecfg register STATE plus the
// derived "source active" predicate. Direct delivery only, so domaincfg.DM
// is read-only zero and only little-endian byte order is modelled
// (domaincfg.BE read-only zero).
//
// The domain hierarchy for the tested configuration is fixed:
//   domain 0 = root, machine level, drives MEIP
//   domain 1 = child of domain 0, supervisor level, drives SEIP
// The root is always machine level per the specification.

// domaincfg for each domain. Only IE (bit 8) is writable in this model; the
// read-only 0x80 tag in bits 31:24 is added on read (see aplic_mmio.sail),
// and DM (bit 2) / BE (bit 0) are read-only zero (direct, little-endian).
register aplic_domaincfg_ie : vector(aplic_num_domains, bits(1)) =
  [ 0b0, 0b0 ]

// sourcecfg[domain][source]. Source 0 is unused (read-only zero). The stored
// value holds the meaningful bits only: bit 10 = D, and either bits 9:0
// (child index, when D = 1) or bits 2:0 (SM, when D = 0).
register aplic_sourcecfg : vector(aplic_num_domains, vector(aplic_num_sources, bits(32))) =
  [ vector_init(0x0000_0000),
    vector_init(0x0000_0000) ]

// Whether a domain has any child domains in the hierarchy. Only the root
// (domain 0) has a child (domain 1); leaf domains cannot set sourcecfg.D.
function aplic_domain_has_children(domain : aplic_domain_index) -> bool =
  domain == 0

// Delegate bit (D) of a sourcecfg value.
function aplic_sourcecfg_is_delegated(cfg : bits(32)) -> bool = cfg[10] == 0b1

// Source Mode (SM) field of a non-delegated sourcecfg value.
function aplic_sourcecfg_sm(cfg : bits(32)) -> bits(3) = cfg[2 .. 0]

// A source is active in a domain when it is not delegated (D = 0) and its
// SM is not Inactive. An inactive source has read-only-zero pending/enable
// bits and target register.
function aplic_source_active(domain : aplic_domain_index, source : aplic_source_index) -> bool = {
  if source == 0 then return false;
  let cfg = aplic_sourcecfg[domain][source];
  not(aplic_sourcecfg_is_delegated(cfg)) & aplic_sourcecfg_sm(cfg) != SM_INACTIVE
}

// Legalize a value written to sourcecfg[domain][source]. Implements the WARL
// rules from the specification:
//   - source 0 is read-only zero;
//   - a leaf domain (no children) that is written with D = 1 has the whole
//     register forced to zero;
//   - when D = 1 (and children exist) only the child-index bits 9:0 are kept;
//   - when D = 0 only the SM bits 2:0 are kept, and reserved SM values 2/3
//     are legalized to Inactive (0).
function aplic_legalize_sourcecfg(domain : aplic_domain_index,
                                  source : aplic_source_index,
                                  data : bits(32)) -> bits(32) = {
  if source == 0 then return zeros();
  if data[10] == 0b1 then {
    // Delegation requested.
    if aplic_domain_has_children(domain)
    then zero_extend(0b1 @ data[9 .. 0])
    else zeros() // leaf domain: whole register forced to zero
  } else {
    let sm = data[2 .. 0];
    // Reserved SM encodings (2, 3) are not supported; legalize to Inactive.
    let sm_legal : bits(3) = if sm == 0b010 | sm == 0b011 then SM_INACTIVE else sm;
    zero_extend(sm_legal)
  }
}

// Rectified input value of a source. The model has no external interrupt
// wires, so the incoming wire value is always zero and hence the rectified
// input is always zero. Software drives pending state through setip/setipnum
// (valid for detached and edge sources in direct mode). This helper exists so
// in_clrip reads have a defined value and future wire support has one place
// to change.
function aplic_rectified_input(domain : aplic_domain_index, source : aplic_source_index) -> bits(1) = 0b0
