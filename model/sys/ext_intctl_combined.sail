// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// Combined IMSIC + APLIC external interrupt delivery.
//
// When BOTH an IMSIC and an APLIC are configured (plat_have_imsic and
// plat_aplic_enabled), the IMSIC's per-privilege eidelivery register acts as
// a 3-way selector for which controller delivers external interrupts to the
// hart, per the AIA specification (IMSIC eidelivery is WARL with values):
//   0x00000001 -> the IMSIC interrupt file delivers (its top pending-and-
//                 enabled identity, subject to eithreshold).
//   0x40000000 -> the APLIC delivers directly (the interrupt file behaves as
//                 if eidelivery == 0 and the APLIC supplies the pending
//                 external interrupt at this privilege level).
//   0x00000000 -> nothing is delivered (the external interrupt signal is held
//                 de-asserted).
//
// This guarded clause of the shared ext_intctl_topei scattered function
// (declared in core/external_interrupt_ctl.sail) is registered ahead of the
// standalone IMSIC and APLIC clauses in the file list, so its more-specific
// guard (both controllers present) wins when both are enabled. When only one
// controller is present, this clause does not fire and dispatch falls through
// to that controller's own clause.

// The IMSIC top interrupt for a privilege, wrapped into the shared
// (identity, priority) reporting form. Priority is a live 1 (as for the
// standalone IMSIC clause).
function imsic_topei_for_privilege(priv : Privilege) -> (bits(11), bits(8)) =
  match imsic_top_identity(priv) {
    None()   => (zeros(), zeros()),
    Some(id) => (to_bits(11, id), 0x01),
  }

function clause ext_intctl_topei(priv if plat_have_imsic & plat_aplic_enabled) = {
  let eidelivery = imsic_get_eidelivery(priv);
  if eidelivery == EIDELIVERY_IMSIC then
    // The IMSIC interrupt file delivers.
    imsic_topei_for_privilege(priv)
  else if eidelivery == EIDELIVERY_APLIC then {
    // The APLIC delivers directly. Supervisor delivery only exists when S is
    // supported; otherwise nothing is delivered at this privilege.
    match priv {
      Machine => aplic_topei_for_privilege(Machine),
      _       => if currentlyEnabled(Ext_S)
                 then aplic_topei_for_privilege(Supervisor)
                 else (zeros(), zeros()),
    }
  } else
    // eidelivery == 0 (or any other unsupported value held at 0): nothing
    // is delivered.
    (zeros(), zeros())
}

// The combined claim selector: route a claim to whichever controller the
// IMSIC eidelivery register currently selects, mirroring the topei selector
// above. Each branch uses the claiming form so the selected controller
// clears the claimed source.
function clause ext_intctl_claim(priv if plat_have_imsic & plat_aplic_enabled) = {
  let eidelivery = imsic_get_eidelivery(priv);
  if eidelivery == EIDELIVERY_IMSIC then
    match imsic_top_identity(priv) {
      None()   => (zeros(), zeros()),
      Some(id) => {
        imsic_write_eip_bit(priv, id, false);
        (to_bits(11, id), 0x01)
      },
    }
  else if eidelivery == EIDELIVERY_APLIC then {
    match priv {
      Machine => aplic_claim_for_privilege(Machine),
      _       => if currentlyEnabled(Ext_S)
                 then aplic_claim_for_privilege(Supervisor)
                 else (zeros(), zeros()),
    }
  } else
    (zeros(), zeros())
}
