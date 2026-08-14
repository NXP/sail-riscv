// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// External interrupt controller interface.
//
// This is the abstract interface that an external interrupt controller
// (today the Simple Interrupt Generator, later an APLIC and/or IMSIC)
// implements to drive the machine and supervisor external interrupts
// (MEI / SEI). It is keyed on Privilege: Machine describes the machine
// external interrupt, Supervisor the supervisor external interrupt.
//
// The interface is deliberately equivalent to the AIA top(e)i view so a
// single controller can serve both the wired (mtopi/stopi) and, in
// future, the message-signalled (mtopei/stopei) reporting paths:
//
//   ext_intctl_topei : the (minor identity, priority) of the top
//                      external interrupt for this priv, as would be
//                      reported by xtopei.
//
// There is deliberately no separate "pending" method: per the AIA, a
// top external interrupt minor identity of zero means "no interrupt",
// so xEIP for a privilege is simply "the reported minor identity is
// non-zero". Deriving pending from the identity keeps a single source
// of truth and avoids a controller reporting pending with identity 0
// (or vice versa).
//
// A further method, a claim (read-and-clear of the top external
// interrupt), is planned but not modelled yet: it only becomes
// meaningful once we implement the xtopei CSRs and a controller with
// real per-source state (APLIC/IMSIC). Adding it now would be an unused
// hook, so it is deferred to the external-interrupt-controller changeset
// proper.

// The top external interrupt for the given privilege, as (minor identity,
// priority), using the same encoding as mtopei/stopei. A minor identity
// of zero means no external interrupt is pending for this privilege.
val ext_intctl_topei : Privilege -> (bits(11), bits(8))
scattered function ext_intctl_topei

// Whether the external interrupt controller is asserting the external
// interrupt pending signal (xEIP) for the given privilege. Derived from
// ext_intctl_topei: a non-zero top minor identity means pending.
function ext_intctl_pending(priv : Privilege) -> bool = {
  let (identity, _) = ext_intctl_topei(priv);
  identity != zeros()
}
