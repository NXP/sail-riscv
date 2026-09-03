// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================
//
// Smnip / Ssnip - Nested interrupt preemption extension.
//
// Smnip adds a per-privilege interrupt-enable threshold (mithreshold/
// sithreshold.iprio) and a saved copy (mistatus/sistatus.pithreshprio),
// plus a signed top-interrupt CSR pair (mtopsi/stopsi). The CSRs and the
// backing state live in extensions/aclic/aclic_regs.sail; the arbitration
// helper read_xtopsi lives in core/aia_regs.sail. This file provides the
// behavioral hooks (forward declared in aclic_regs.sail) that are wired
// into the trap-dispatch path:
//
//   smnip_mask_pending  - masks the pending-and-enabled set by the nested-
//                         preemption threshold (getPendingSet);
//   smnip_trap_enter    - saves the previous threshold and raises it to the
//                         claimed interrupt's priority on trap entry;
//   smnip_xret_restore  - restores the threshold on xret.
//
// Smnip does not depend on Smidctrl: it only needs a concept of interrupt
// priority, which it borrows from the AIA arbitration (topi_iprio).

// Is nested-preemption enabled for `priv` (extension supported and the
// miconfig enable bit set)?
function smnip_enabled(priv : Privilege) -> bool =
  match priv {
    Machine    => currentlyEnabled(Ext_Smnip) & miconfig[mnipen] == 0b1,
    Supervisor => currentlyEnabled(Ext_Ssnip) & miconfig[snipen] == 0b1,
    _          => false,
  }

// The configured nipbits for `priv` (0 .. IPRIOLEN).
function smnip_nipbits(priv : Privilege) -> int =
  match priv {
    Machine    => unsigned(miconfig[mnipbits]),
    Supervisor => unsigned(miconfig[snipbits]),
    _          => 0,
  }

// The nested-preemption threshold for `priv`: xithreshold.iprio with the
// low (IPRIOLEN - nipbits) bits masked to zero (NIPPRIO_MASK).
function smnip_nip_threshold(priv : Privilege) -> int = {
  let nipbits = smnip_nipbits(priv);
  // shift = IPRIOLEN - nipbits, in the range 0 .. IPRIOLEN. Zero the low
  // `shift` bits of the threshold with a bitvector shift (avoids the
  // integer pow2/rem quantifiers Sail cannot resolve for a runtime shift).
  let shift = if nipbits >= IPRIOLEN then 0 else IPRIOLEN - nipbits;
  // NIPPRIO_MASK = all-ones shifted left by `shift`, zeroing the low bits.
  let masked : bits(9) = (get_ithreshold(priv) >> shift) << shift;
  unsigned(masked)
}

// Mask the pending set for `priv` by the nested-preemption threshold. Any
// arbitrated source whose reported IPRIO is numerically >= NIP_THRESHOLD is
// treated as disabled (its pending bit is cleared in the returned vector).
// When nested preemption is not enabled the set is returned unchanged.
function smnip_mask_pending(priv : Privilege, pending : xlenbits) -> xlenbits = {
  if not(smnip_enabled(priv)) then return pending;

  let nip_threshold = smnip_nip_threshold(priv);
  var result = pending;

  // The arbitrated standard-interrupt identities, in any order; only these
  // have a defined IPRIO from topi_iprio.
  let iids : vector(7, range(0, 13)) = [11, 3, 7, 9, 1, 5, 13];
  foreach (n from 0 to 6) {
    let iid = iids[n];
    let mask : xlenbits = to_bits_truncate(xlen, 1) << iid;
    if (result & mask) != zeros() then {
      let iprio = unsigned(topi_iprio(priv, iid));
      if iprio >= nip_threshold then {
        result = result & ~(mask);
      }
    }
  };
  result
}

// Trap entry for the nested-preemption model. Called from trap_handler
// after mcause/scause has been set.
//   del_priv     - the privilege the trap is delegated to;
//   prev_priv    - cur_privilege before the trap (for double-trap detect);
//   is_interrupt - whether the trap is an interrupt (vs synchronous exc).
//
// On trap to level x the current xithreshold.iprio is saved into
// xistatus.pithreshprio, except for a double trap into M-mode (a trap taken
// while already in M-mode), where pithreshprio is left unchanged so the
// original pre-handler threshold is preserved. For an interrupt the
// threshold is then raised to the claimed interrupt's IPRIO and the
// interrupt is claimed (best-effort pending clear). Synchronous exceptions
// do not modify xithreshold.iprio. When xnipen is set the reported cause is
// also rewritten to the ACLIC signed identity.
function smnip_trap_enter(del_priv : Privilege, prev_priv : Privilege, is_interrupt : bool) -> unit = {
  if not(smnip_enabled(del_priv)) then return ();

  // Save the current threshold so xret can restore it. Per the ACLIC spec
  // ("If a double trap occurs while in M-mode, xistatus.pithreshprio is
  // unchanged"), the save is suppressed for a trap taken into M-mode while
  // already in M-mode (a double trap into M), so the original pre-handler
  // threshold is preserved. All other trap entries save unconditionally.
  let double_trap_into_m = del_priv == Machine & prev_priv == Machine;
  if not(double_trap_into_m) then
    set_pithreshprio(del_priv, get_ithreshold(del_priv));

  if is_interrupt then {
    let reported = read_xtopsi(del_priv, get_ithreshold(del_priv));
    // Raise the threshold to the claimed interrupt's IPRIO.
    set_ithreshold(del_priv, reported[8 .. 0]);

    // Claim: best-effort pending clear for a major (negative SIID) interrupt.
    let siid = reported[xlen - 1 .. 16];
    if siid != zeros() & siid[xlen - 17] == bitone then {
      let identity = unsigned((zeros() : bits(xlen)) - (sign_extend(siid) : bits(xlen)));
      if identity < 64
      then clear_interrupt_pending(interruptType_bits(to_bits(6, identity)));
    };
    // Rewrite the reported cause to the ACLIC signed identity.
    let signed_cause : xlenbits = sign_extend(siid);
    match del_priv {
      Machine    => mcause[Cause] = signed_cause[xlen - 2 .. 0],
      Supervisor => scause[Cause] = signed_cause[xlen - 2 .. 0],
      _          => (),
    };
  };
}

// xret restore: put the saved pithreshprio back into xithreshold.iprio.
function smnip_xret_restore(priv : Privilege) -> unit = {
  if smnip_enabled(priv)
  then set_ithreshold(priv, get_pithreshprio(priv));
}
