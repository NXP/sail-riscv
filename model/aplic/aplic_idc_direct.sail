// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// APLIC direct-mode Interrupt Delivery Control (IDC): idelivery / iforce /
// ithreshold register STATE, the priority arbitration that computes topi, and
// the claim (read-and-clear) side effect for claimi. This is the direct
// delivery path; a future MSI delivery path would live in a sibling
// aplic_idc_msi.sail and reuse the source register state from aplic_regs.sail.
//
// The model has a single hart (hart index 0) per domain, so there is exactly
// one IDC structure per domain, indexed by domain.

// idelivery: WARL 0/1 - enables direct delivery of this domain's interrupts
// to its hart's xEIP.
register aplic_idelivery : vector(aplic_num_domains, bits(1)) = [ 0b0, 0b0 ]

// iforce: WARL 0/1 - testing aid; forces an interrupt to be asserted when the
// domain's IE and idelivery are both set. Auto-cleared when a claim returns
// identity zero (a spurious interrupt).
register aplic_iforce : vector(aplic_num_domains, bits(1)) = [ 0b0, 0b0 ]

// ithreshold: WLRL, IPRIOLEN bits. When nonzero P, sources with priority
// number >= P do not contribute to signaling interrupts.
register aplic_ithreshold : vector(aplic_num_domains, bits(8)) = [ zeros(), zeros() ]

// Whether a source contributes to arbitration for this domain: it must be
// active, pending, and enabled.
function aplic_source_contributes(domain : aplic_domain_index, source : aplic_source_index) -> bool =
  aplic_source_active(domain, source)
  & aplic_pending[domain][source] == bitone
  & aplic_enable[domain][source] == bitone

// Compute the top interrupt for a domain: the highest-priority (smallest
// priority number) pending-and-enabled active source, ties broken by lowest
// source identity, that also passes the ithreshold filter. Returns
// (identity, priority); identity 0 means "no interrupt". This is the topi
// value and is not affected by domaincfg.IE or idelivery.
function aplic_arbitrate(domain : aplic_domain_index) -> (bits(11), bits(8)) = {
  var best_id : bits(11) = zeros();
  var best_prio : bits(8) = zeros();
  let threshold = aplic_ithreshold[domain];
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    if aplic_source_contributes(domain, source) then {
      let prio = aplic_target_iprio(aplic_target[domain][source]);
      // ithreshold: a nonzero P masks priority numbers >= P.
      let passes_threshold = threshold == zeros() | unsigned(prio) < unsigned(threshold);
      if passes_threshold then {
        // Smaller priority number is higher priority; ties go to lowest id.
        // Sources are scanned in increasing id order, so we only replace the
        // current best on a strictly smaller priority number.
        if best_id == zeros() | unsigned(prio) < unsigned(best_prio) then {
          best_id = to_bits(11, source);
          best_prio = prio;
        }
      }
    }
  };
  (best_id, best_prio)
}

// topi value for a domain in the mtopi/stopi (identity, priority) form.
function aplic_topi(domain : aplic_domain_index) -> (bits(11), bits(8)) =
  aplic_arbitrate(domain)

// Fixed-width readers for the IDC scalar registers. Reading these into a
// fixed 32-bit value here (rather than zero_extending a single vector element
// directly at a generic-width use site) keeps the C++ backend's monomorphiser
// happy; the generic-width zero_extend at the caller then has a bitvector(32)
// argument.
function aplic_read_idelivery(domain : aplic_domain_index) -> bits(32) =
  zero_extend(aplic_idelivery[domain])

function aplic_read_iforce(domain : aplic_domain_index) -> bits(32) =
  zero_extend(aplic_iforce[domain])

function aplic_read_ithreshold(domain : aplic_domain_index) -> bits(32) =
  zero_extend(aplic_ithreshold[domain])


// Claim the top interrupt for a domain (the read side effect of claimi):
//   - if identity is nonzero, clear that source's pending bit (if possible);
//   - if identity is zero, clear iforce.
// Returns the claimed (identity, priority), which is the same as topi.
function aplic_claim(domain : aplic_domain_index) -> (bits(11), bits(8)) = {
  let (identity, priority) = aplic_topi(domain);
  if identity != zeros() then {
    let source = unsigned(identity);
    // source is in range 1 .. APLIC_NUM_SOURCES-1 by construction.
    if source > 0 & source < APLIC_NUM_SOURCES
    then aplic_clear_pending(domain, source);
  } else {
    aplic_iforce[domain] = 0b0;
  };
  (identity, priority)
}
