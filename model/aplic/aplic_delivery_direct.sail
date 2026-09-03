// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// APLIC direct-mode interrupt delivery: turns each domain's arbitrated top
// interrupt into the machine / supervisor external interrupt signals via the
// shared ext_intctl_topei interface (declared in
// core/external_interrupt_ctl.sail).
//
// Domain-to-privilege mapping for the tested configuration:
//   domain 0 = root, machine level    -> drives MEIP (Machine)
//   domain 1 = child, supervisor level -> drives SEIP (Supervisor)
//
// Direct delivery: the domain asserts its external interrupt signal when
//   domaincfg.IE = 1 AND idelivery = 1 AND (iforce != 0 OR topi != 0).
// topi itself is not affected by IE or idelivery (see aplic_idc_direct.sail).
//
// Interface note on iforce: the shared ext_intctl_topei reports a single
// (identity, priority), and pending (xEIP) is derived as "identity != 0". A
// pure iforce assertion produces a spurious external interrupt whose claimi
// identity is zero, which the single-identity interface cannot represent as
// pending. Modelling that MEIP-with-identity-zero case requires a separate
// pending method on the controller interface and is deferred to a later
// changeset. The iforce register and its auto-clear on a zero claim are
// implemented and testable via claimi; iforce is also honored here whenever
// there is a real top interrupt to report.

// The privilege that a domain delivers its external interrupt to.
function aplic_domain_privilege(domain : aplic_domain_index) -> Privilege =
  if domain == 0 then Machine else Supervisor

// Whether direct delivery is currently enabled for a domain (IE & idelivery).
function aplic_delivery_enabled(domain : aplic_domain_index) -> bool =
  aplic_domaincfg_ie[domain] == 0b1 & aplic_idelivery[domain] == 0b1

// The (identity, priority) that this domain presents to its hart's external
// interrupt reporting, gated by delivery-enable. When delivery is disabled
// the domain reports "no interrupt" (identity 0) so that xEIP is deasserted.
function aplic_delivered_topei(domain : aplic_domain_index) -> (bits(11), bits(8)) =
  if aplic_delivery_enabled(domain)
  then aplic_topi(domain)
  else (zeros(), zeros())

// Find the domain (if any) that delivers to the given privilege and is
// enabled in this build. Returns the reported (identity, priority).
function aplic_topei_for_privilege(priv : Privilege) -> (bits(11), bits(8)) = {
  var result : (bits(11), bits(8)) = (zeros(), zeros());
  foreach (domain from 0 to (APLIC_NUM_DOMAINS - 1)) {
    if domain < plat_aplic_num_domains & aplic_domain_privilege(domain) == priv
    then result = aplic_delivered_topei(domain);
  };
  result
}

// The APLIC registers itself with the shared external interrupt controller
// interface (ext_intctl_topei, declared in core/external_interrupt_ctl.sail)
// by contributing guarded clauses. These clauses fire only when the APLIC is
// selected at run time (plat_aplic_enabled); otherwise dispatch falls through
// to the unguarded fallback clause (sys/ext_intctl_dispatch.sail), which
// forwards to the Simple Interrupt Generator. The APLIC and the Simple
// Interrupt Generator are mutually exclusive per build (see
// validate_config.sail). This module only adds clauses; it neither modifies
// nor removes the fallback.
// When an IMSIC is also configured these standalone clauses are suppressed
// (their guards exclude plat_have_imsic) and the combined 3-way selector
// clause in sys/ext_intctl_combined.sail takes over, routing to the APLIC
// only when the IMSIC's eidelivery selects APLIC direct delivery.
function clause ext_intctl_topei(Machine if plat_aplic_enabled & not(plat_have_imsic)) =
  aplic_topei_for_privilege(Machine)

function clause ext_intctl_topei(priv if plat_aplic_enabled & not(plat_have_imsic)) =
  if currentlyEnabled(Ext_S)
  then aplic_topei_for_privilege(Supervisor)
  else (zeros(), zeros())

// Claim (read-and-clear) the top interrupt of the domain that delivers to
// the given privilege, gated by delivery-enable (so a domain whose delivery
// is disabled reports and clears nothing). Mirrors aplic_topei_for_privilege
// but uses aplic_claim, which clears the claimed source's pending bit.
function aplic_claim_for_privilege(priv : Privilege) -> (bits(11), bits(8)) = {
  var result : (bits(11), bits(8)) = (zeros(), zeros());
  foreach (domain from 0 to (APLIC_NUM_DOMAINS - 1)) {
    if domain < plat_aplic_num_domains & aplic_domain_privilege(domain) == priv then {
      if aplic_delivery_enabled(domain)
      then result = aplic_claim(domain);
    }
  };
  result
}

// The APLIC's claim clauses, guarded identically to its topei clauses so
// they fire only when the APLIC is the standalone controller; the combined
// APLIC+IMSIC selector in sys/ext_intctl_combined.sail supersedes them when
// both are configured.
function clause ext_intctl_claim(Machine if plat_aplic_enabled & not(plat_have_imsic)) =
  aplic_claim_for_privilege(Machine)

function clause ext_intctl_claim(priv if plat_aplic_enabled & not(plat_have_imsic)) =
  if currentlyEnabled(Ext_S)
  then aplic_claim_for_privilege(Supervisor)
  else (zeros(), zeros())
