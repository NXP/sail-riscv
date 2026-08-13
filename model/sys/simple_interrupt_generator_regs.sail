// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// The last value written to the Simple Interrupt Generator.
private register sig_meip : bits(1) = 0b0
private register sig_seip : bits(1) = 0b0

// AIA top(e)i configuration for the external interrupts, one for the
// machine external interrupt (MEI) and one for the supervisor external
// interrupt (SEI). Each packs a minor interrupt identity and a priority
// using the same layout as mtopi/stopi (and, in future, mtopei/stopei):
//   bits 26:16 : interrupt identity (IID)
//   bits  7:0  : interrupt priority (IPRIO)
// All other bits are reserved and read-only zero. These let test code
// drive a meaningful (identity, priority) for the external interrupts
// that AIA's mtopi/stopi (and later topei) report.
private register sig_mtopei_cfg : bits(32) = zeros()
private register sig_stopei_cfg : bits(32) = zeros()

// Mask of the meaningful (non-reserved) bits of a top(e)i config value.
let sig_topei_cfg_mask : bits(32) = 0x07FF_00FF

// Extract the interrupt identity from a top(e)i config value. When the
// config register leaves the identity as zero (the common case for a
// plain wired external interrupt raised via the platform register), a
// default non-zero minor identity is reported so that the shared
// "identity != 0 means pending" derivation still sees the interrupt as
// pending. A test that wants a specific minor identity/priority writes
// the corresponding top(e)i config register.
let sig_topei_cfg_default_identity : bits(11) = 0b000_0000_0001

function sig_topei_cfg_identity(cfg : bits(32)) -> bits(11) = {
  let identity = cfg[26 .. 16];
  if identity != zeros() then identity else sig_topei_cfg_default_identity
}

// Extract the interrupt priority from a top(e)i config value.
function sig_topei_cfg_priority(cfg : bits(32)) -> bits(8) = cfg[7 .. 0]

// Legalize a written top(e)i config value (WARL). For an external
// interrupt controller a priority of 0 is not a valid live priority: it
// is the AIA "no interrupt" sentinel and must never be presented as the
// priority of a pending external interrupt. A written priority of 0 is
// therefore legalized to 1, so the register reads back as 1. Reserved
// bits are masked to zero at the same time.
function sig_legalize_topei_cfg(data : bits(32)) -> bits(32) = {
  let masked = data & sig_topei_cfg_mask;
  if masked[7 .. 0] == zeros()
  then [masked with 7 .. 0 = 0x01]
  else masked
}


// The Simple Interrupt Generator is the default external interrupt
// controller: it provides the shared ext_intctl_topei interface (declared
// in core/external_interrupt_ctl.sail) that mtopi/stopi (and, later, an
// APLIC/IMSIC) consume. The reported (identity, priority) comes from the
// mtopei_cfg / stopei_cfg configuration registers, gated by the raw
// sig_meip / sig_seip pending inputs: when the pending input is low the
// controller reports minor identity 0 (no interrupt), which the shared
// ext_intctl_pending derives as "not pending".
// Machine is MEI; any other privilege is treated as the supervisor
// external interrupt (SEI). These functions are only ever queried for
// Machine and Supervisor.
function clause ext_intctl_topei(Machine) =
  if sig_meip == 0b1
  then (sig_topei_cfg_identity(sig_mtopei_cfg), sig_topei_cfg_priority(sig_mtopei_cfg))
  else (zeros(), zeros())
function clause ext_intctl_topei(_) =
  if currentlyEnabled(Ext_S) & sig_seip == 0b1
  then (sig_topei_cfg_identity(sig_stopei_cfg), sig_topei_cfg_priority(sig_stopei_cfg))
  else (zeros(), zeros())

// The Simple Interrupt Generator's contribution to the shared claim
// interface (ext_intctl_claim, declared in core/external_interrupt_ctl.sail).
// The SIG has no per-source claim state, so a claim reports the current top
// interrupt (identical to ext_intctl_topei) and, as its only side effect,
// deasserts the wired pending input (sig_meip / sig_seip) for the claimed
// privilege when an interrupt was actually pending. A claim with nothing
// pending reports minor identity 0 and leaves the pending input untouched.
function clause ext_intctl_claim(Machine) =
  if sig_meip == 0b1 then {
    let claimed = (sig_topei_cfg_identity(sig_mtopei_cfg), sig_topei_cfg_priority(sig_mtopei_cfg));
    sig_meip = 0b0;
    claimed
  } else (zeros(), zeros())
function clause ext_intctl_claim(_) =
  if currentlyEnabled(Ext_S) & sig_seip == 0b1 then {
    let claimed = (sig_topei_cfg_identity(sig_stopei_cfg), sig_topei_cfg_priority(sig_stopei_cfg));
    sig_seip = 0b0;
    claimed
  } else (zeros(), zeros())


// The external interrupt pending set (xEIP) is derived from the controller
// interface so there is a single source of truth for MEI/SEI pending.
function external_interrupts_pending() -> Minterrupts =
  [Mk_Minterrupts(zeros()) with
    MEI = if ext_intctl_pending(Machine) then 0b1 else 0b0,
    // SEIP is read-only zero if the hart does not support supervisor mode;
    // ext_intctl_pending(Supervisor) already accounts for that.
    SEI = if ext_intctl_pending(Supervisor) then 0b1 else 0b0,
  ]
