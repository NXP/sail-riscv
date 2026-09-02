// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// External interrupt controller dispatch: fallback clause.
//
// ext_intctl_topei (declared in core/external_interrupt_ctl.sail) is a
// scattered function. This file provides the unguarded fallback clause of
// that function, which forwards to the Simple Interrupt Generator helper
// sig_ext_intctl_topei. The Simple Interrupt Generator is the default
// external interrupt controller and is present in every build.
//
// An advanced external interrupt controller (APLIC and/or IMSIC) registers
// itself additively: its own module contributes a guarded ext_intctl_topei
// clause, and it lists that module in riscv.sail_project ahead of this file.
// A guarded clause fires only when its controller is selected at run time
// (via the platform config); otherwise dispatch falls through to this
// unguarded fallback, so the Simple Interrupt Generator remains selectable
// in every build. Controllers are mutually exclusive (see
// postlude/validate_config.sail), so at most one guarded clause ever fires.
//
// This file is never modified or removed when a controller is added; the
// controller only adds its own file and one filelist entry.
function clause ext_intctl_topei(priv) = sig_ext_intctl_topei(priv)

// The unguarded fallback claim clause. The Simple Interrupt Generator
// claims its wired external interrupt by deasserting the MEIP/SEIP pending
// latch (sig_ext_intctl_claim); it reports the same (identity, priority) as
// the topei fallback. Advanced controllers (IMSIC / APLIC / ACLIC)
// contribute their own guarded ext_intctl_claim clauses that clear their
// own per-source state.
function clause ext_intctl_claim(priv) = sig_ext_intctl_claim(priv)

