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
// A further method, ext_intctl_claim (below), performs a claim
// (read-and-clear of the top external interrupt). It becomes meaningful
// once a controller with real per-source state (APLIC / IMSIC / ACLIC) is
// configured and a claim consumer exists (the xtopei CSRs and the
// mtopsi/stopsi claim write). Controllers with no per-source claim state
// (the Simple Interrupt Generator) report the current top interrupt
// without clearing.

// The top external interrupt for the given privilege, as (minor identity,
// priority), using the same encoding as mtopei/stopei. A minor identity
// of zero means no external interrupt is pending for this privilege.
val ext_intctl_topei : Privilege -> (bits(11), bits(8))
scattered function ext_intctl_topei

// Claim (read-and-clear) the top external interrupt for the given
// privilege, returning the claimed (minor identity, priority) using the
// same encoding as ext_intctl_topei. The configured controller clears the
// pending state of the claimed source as a side effect; a controller with
// no per-source claim state (the Simple Interrupt Generator) returns the
// current top interrupt without clearing. A returned identity of zero
// means there was no external interrupt to claim.
val ext_intctl_claim : Privilege -> (bits(11), bits(8))
scattered function ext_intctl_claim

// Whether the external interrupt controller is asserting the external
// interrupt pending signal (xEIP) for the given privilege. Derived from
// ext_intctl_topei: a non-zero top minor identity means pending.
function ext_intctl_pending(priv : Privilege) -> bool = {
  let (identity, _) = ext_intctl_topei(priv);
  identity != zeros()
}
