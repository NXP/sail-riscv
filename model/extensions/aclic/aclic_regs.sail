// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================
//
// Shared ACLIC (Advanced Core-Local Interrupt Controller) register state.
//
// This file hosts the interrupt-status CSRs (mistatus/sistatus) that are
// shared by several ACLIC extensions. The Smcsps/Sscsps (Conditional Stack
// Pointer Swap) fields (sppush/psppush) and the Smnip/Ssnip nested-preemption
// fields (pithreshprio) are backed by real state; the mstatus/sstatus mirror
// fields are composed from the existing mstatus register so no state is
// duplicated.

// The mistatus/sistatus layout, expressed over 64 bits. Only the fields
// modeled today are named; the reserved and not-yet-implemented fields are
// deliberately omitted and returned as zero.
bitfield Mistatus : bits(64) = {
  MPP          : 29 .. 28,  // mirror of mstatus.MPP (mistatus only)
  MPIE         : 27,        // mirror of mstatus.MPIE (mistatus only)
  MPELP        : 26,        // mirror of mstatus.MPELP (mistatus only)
  SPP          : 28,        // mirror of sstatus.SPP (sistatus only)
  SPIE         : 27,        // mirror of sstatus.SPIE (sistatus only)
  SPELP        : 26,        // mirror of sstatus.SPELP (sistatus only)
  VS           : 20 .. 19,  // mirror of xstatus.VS
  FS           : 18 .. 17,  // mirror of xstatus.FS
  pithreshprio : 16 .. 8,   // Smnip: previous xithreshold.iprio
  psppush      : 7,         // Smcsps: previous stack-pointer push bit
  sppush       : 6,         // Smcsps: stack-pointer push bit
  MIE          : 0,         // mirror of mstatus.MIE (mistatus only)
  SIE          : 0,         // mirror of sstatus.SIE (sistatus only)
}

// Per-privilege backing state for the only genuinely new bits in
// mistatus/sistatus. These are separate physical bits per privilege level
// because the push/psppush bits are part of the interrupt handler context
// at each level.
register m_sppush  : bits(1) = zeros()
register m_psppush : bits(1) = zeros()
register s_sppush  : bits(1) = zeros()
register s_psppush : bits(1) = zeros()

// Smnip/Ssnip: per-privilege interrupt-enable threshold (mithreshold/
// sithreshold.iprio) and its saved copy (mistatus/sistatus.pithreshprio).
// Both are IPRIOLEN+1 = 9 bits wide so that a threshold larger than any
// live IPRIO (up to 256) can be represented, which "enables all interrupts".
register m_ithreshold   : bits(9) = zeros()
register s_ithreshold   : bits(9) = zeros()
register m_pithreshprio : bits(9) = zeros()
register s_pithreshprio : bits(9) = zeros()

// IPRIOLEN as defined by the AIA/ACLIC configuration modeled here.
let IPRIOLEN : int = 8


function get_ithreshold(priv : Privilege) -> bits(9) =
  match priv {
    Machine    => m_ithreshold,
    Supervisor => s_ithreshold,
    _          => zeros(),
  }

function set_ithreshold(priv : Privilege, v : bits(9)) -> unit =
  match priv {
    Machine    => m_ithreshold = v,
    Supervisor => s_ithreshold = v,
    _          => (),
  }

function get_pithreshprio(priv : Privilege) -> bits(9) =
  match priv {
    Machine    => m_pithreshprio,
    Supervisor => s_pithreshprio,
    _          => zeros(),
  }

function set_pithreshprio(priv : Privilege, v : bits(9)) -> unit =
  match priv {
    Machine    => m_pithreshprio = v,
    Supervisor => s_pithreshprio = v,
    _          => (),
  }


// Accessors used by the Smcsps/Sscsps instructions.
function get_sppush(priv : Privilege) -> bits(1) =
  match priv {
    Machine    => m_sppush,
    Supervisor => s_sppush,
    _          => zeros(),
  }

function set_sppush(priv : Privilege, b : bits(1)) -> unit =
  match priv {
    Machine    => m_sppush = b,
    Supervisor => s_sppush = b,
    _          => (),
  }

function get_psppush(priv : Privilege) -> bits(1) =
  match priv {
    Machine    => m_psppush,
    Supervisor => s_psppush,
    _          => zeros(),
  }

function set_psppush(priv : Privilege, b : bits(1)) -> unit =
  match priv {
    Machine    => m_psppush = b,
    Supervisor => s_psppush = b,
    _          => (),
  }

// Compose the machine-level mistatus value from mstatus plus the M-level
// push bits.
function get_mistatus() -> xlenbits = {
  let v = Mk_Mistatus(zeros());
  let v = [v with
    MPP     = mstatus[MPP],
    MPIE    = mstatus[MPIE],
    MPELP   = mstatus[MPELP],
    VS      = mstatus[VS],
    FS      = mstatus[FS],
    psppush = m_psppush,
    sppush  = m_sppush,
    pithreshprio = m_pithreshprio,
    MIE     = mstatus[MIE],
  ];
  v.bits[xlen - 1 .. 0]
}

// Write mistatus: update the M-level push bits and mirror the aliased
// mstatus fields directly into the mstatus register. The core-private
// legalization helpers are not visible from this module, so the mirror
// fields are copied through the public bitfield accessors. These fields
// (MPP/MPIE/MPELP/VS/FS/MIE) are exactly the mstatus bits, so a plain
// bitfield update keeps the two views consistent.
function set_mistatus(value : xlenbits) -> unit = {
  let v = Mk_Mistatus(zero_extend(value));
  m_sppush  = v[sppush];
  m_psppush = v[psppush];
  // Smnip: pithreshprio is a genuine backing field of mistatus (9 bits).
  if hartSupports(Ext_Smnip) then m_pithreshprio = v[pithreshprio];
  mstatus = [mstatus with
    MPP   = v[MPP],
    MPIE  = v[MPIE],
    MPELP = v[MPELP],
    VS    = v[VS],
    FS    = v[FS],
    MIE   = v[MIE],
  ];
}

// Compose the supervisor-level sistatus value from the S-visible fields of
// mstatus plus the S-level push bits. The S-view fields share the same
// physical bits in mstatus, so they are read directly.
function get_sistatus() -> xlenbits = {
  let v = Mk_Mistatus(zeros());
  let v = [v with
    SPP     = mstatus[SPP],
    SPIE    = mstatus[SPIE],
    SPELP   = mstatus[SPELP],
    VS      = mstatus[VS],
    FS      = mstatus[FS],
    psppush = s_psppush,
    sppush  = s_sppush,
    pithreshprio = s_pithreshprio,
    SIE     = mstatus[SIE],
  ];
  v.bits[xlen - 1 .. 0]
}

// Write sistatus: update the S-level push bits and mirror the aliased
// sstatus fields directly into the shared mstatus register.
function set_sistatus(value : xlenbits) -> unit = {
  let v = Mk_Mistatus(zero_extend(value));
  s_sppush  = v[sppush];
  s_psppush = v[psppush];
  // Ssnip: pithreshprio is a genuine backing field of sistatus (9 bits).
  if hartSupports(Ext_Ssnip) then s_pithreshprio = v[pithreshprio];
  mstatus = [mstatus with
    SPP   = v[SPP],
    SPIE  = v[SPIE],
    SPELP = v[SPELP],
    VS    = v[VS],
    FS    = v[FS],
    SIE   = v[SIE],
  ];
}


// mistatus (0x346) is owned by Smcsps/Smnip. sistatus (0x146) is owned by
// Sscsps/Ssnip.
mapping clause csr_name_map = 0x346 <-> "mistatus"
mapping clause csr_name_map = 0x146 <-> "sistatus"

function clause is_CSR_accessible(0x346, priv, _) =
  (currentlyEnabled(Ext_Smcsps) | currentlyEnabled(Ext_Smnip)) & priv == Machine
function clause is_CSR_accessible(0x146, priv, _) =
  (currentlyEnabled(Ext_Sscsps) | currentlyEnabled(Ext_Ssnip)) & (priv == Machine | priv == Supervisor)

function clause read_CSR(0x346) = get_mistatus()
function clause read_CSR(0x146) = get_sistatus()

function clause write_CSR(0x346, value) = { set_mistatus(value); Ok(get_mistatus()) }

// -------------------------------------------------------------------------
// mithreshold / sithreshold - interrupt-enable threshold CSRs (Smnip/Ssnip).
//
// Layout: iprio [IPRIOLEN:0] = [8:0]. A source whose reported IPRIO is
// numerically greater than or equal to the (nipbits-masked) threshold is
// treated as disabled when nested preemption is enabled (see operation in
// getPendingSet). The threshold field is 9 bits wide (IPRIOLEN+1) so that a
// value larger than any live IPRIO (256) can be represented, disabling
// masking entirely (all interrupts enabled). WLRL: the low 9 bits are kept.
// CSR addresses: mithreshold = 0x347, sithreshold = 0x147.
mapping clause csr_name_map = 0x347 <-> "mithreshold"
mapping clause csr_name_map = 0x147 <-> "sithreshold"

function clause is_CSR_accessible(0x347, priv, _) =
  currentlyEnabled(Ext_Smnip) & priv == Machine
function clause is_CSR_accessible(0x147, priv, _) =
  currentlyEnabled(Ext_Ssnip) & (priv == Machine | priv == Supervisor)

function clause read_CSR(0x347) = zero_extend(get_ithreshold(Machine))
function clause read_CSR(0x147) = zero_extend(get_ithreshold(Supervisor))

function clause write_CSR(0x347, value) = {
  set_ithreshold(Machine, value[8 .. 0]);
  Ok(zero_extend(get_ithreshold(Machine)))
}
function clause write_CSR(0x147, value) = {
  set_ithreshold(Supervisor, value[8 .. 0]);
  Ok(zero_extend(get_ithreshold(Supervisor)))
}


// -------------------------------------------------------------------------
// mtopsi / stopsi - top signed interrupt CSRs (Smnip/Ssnip).
//
// Read reports the top pending-and-enabled interrupt as SIID (signed
// identity, bits XLEN-1:16) plus IPRIO (bits 8:0); see read_xtopsi in
// core/aia_regs.sail for the encoding. When no interrupt exists, IPRIO
// reads back the current threshold and SIID = 0.
//
// Write performs the three-step claim sequence (ACLIC spec):
//   1. src[16:8] -> xithreshold.iprio (raise the threshold to the written
//      priority so lower-or-equal-priority sources are masked);
//   2. claim the reported interrupt (best-effort clear of its pending bit);
//   3. write the reported IPRIO back into xithreshold.iprio.
// CSR addresses: mtopsi = 0x348, stopsi = 0x148.
mapping clause csr_name_map = 0x348 <-> "mtopsi"
mapping clause csr_name_map = 0x148 <-> "stopsi"

function clause is_CSR_accessible(0x348, priv, _) =
  currentlyEnabled(Ext_Smnip) & priv == Machine
function clause is_CSR_accessible(0x148, priv, _) =
  currentlyEnabled(Ext_Ssnip) & (priv == Machine | priv == Supervisor)

function clause read_CSR(0x348) = read_xtopsi(Machine, get_ithreshold(Machine))
function clause read_CSR(0x148) = read_xtopsi(Supervisor, get_ithreshold(Supervisor))

// The three-step claim write, shared by both privileges.
function write_xtopsi(priv : Privilege, value : xlenbits) -> xlenbits = {
  // Step 1: src[16:8] -> xithreshold.iprio.
  set_ithreshold(priv, zero_extend(value[16 .. 8]));
  // Step 2: claim the reported interrupt (best-effort pending clear). We
  // re-read the top interrupt under the updated threshold; if it is a major
  // interrupt (negative SIID) clear its pending bit.
  let reported = read_xtopsi(priv, get_ithreshold(priv));
  let siid = reported[xlen - 1 .. 16];
  if siid != zeros() & siid[xlen - 17] == bitone then {
    // Negative SIID: a major interrupt whose identity is the negation.
    let identity = unsigned((zeros() : bits(xlen)) - (sign_extend(siid) : bits(xlen)));
    if identity < 64 then
      clear_interrupt_pending(interruptType_bits(to_bits(6, identity)));
  } else if siid != zeros() then {
    // Positive SIID: an external interrupt reported by whatever external
    // interrupt controller is connected (ACLIC / IMSIC / APLIC direct).
    // Claim it through the generic controller interface (best-effort
    // pending clear); the configured controller clears the claimed source.
    let _ = ext_intctl_claim(priv);
  };

  // Step 3: write the reported IPRIO into xithreshold.iprio.
  set_ithreshold(priv, reported[8 .. 0]);

  reported
}

function clause write_CSR(0x348, value) = { let r = write_xtopsi(Machine, value); Ok(r) }
function clause write_CSR(0x148, value) = { let r = write_xtopsi(Supervisor, value); Ok(r) }

// -------------------------------------------------------------------------
// mijt / sijt - interrupt jump-table base CSRs (Smijt/Ssijt).
//
// When xtvec.MODE == 0b11 (jump-table mode) an interrupt delegated to
// privilege x vectors through a table based at xijt. The CSR layout is
// (from the ACLIC specification):
//   BASE  [XLEN-1:6]  WARL  64-byte-aligned table base
//   resv  [5:3]       WARL  reserved (read-only zero)
//   EHV   [2]         WARL  synchronous exception hardware-vectoring enable
//                          (Smehv/Ssehv); reserved (read-only zero) otherwise
//   SHAMT [1:0]       WARL  extra left-shift applied to the table index
// CSR addresses: mijt = 0x307, sijt = 0x107.
bitfield Xijt : xlenbits = {
  BASE  : xlen - 1 .. 6,
  EHV   : 2,
  SHAMT : 1 .. 0,
}


register mijt : Xijt = Mk_Xijt(zeros())
register sijt : Xijt = Mk_Xijt(zeros())

// WARL legalization: keep only BASE, SHAMT and (when synchronous exception
// hardware vectoring is supported for this privilege) EHV; the reserved
// bits [5:3] are forced to zero. When Smehv/Ssehv is not supported EHV is
// also read-only zero, so `ehv_supported` gates whether the written EHV bit
// is preserved. The table base is at least 64-byte (2^6) aligned because
// BASE occupies bits [XLEN-1:6]; if the platform mandates a coarser
// alignment (align_exp > 6) the additional low BASE bits are also zeroed,
// analogous to legalize_tvec zeroing the low bits of the trap-vector base.
function legalize_xijt(v : Xijt, align_exp : ijt_alignment, ehv_supported : bool) -> Xijt = {
  let ehv = if ehv_supported then v[EHV] else 0b0;
  let v = [Mk_Xijt(zeros()) with BASE = v[BASE], EHV = ehv, SHAMT = v[SHAMT]];
  // BASE starts at bit 6, so an alignment exponent of `align_exp` zeros the
  // lowest (align_exp - 6) bits of the BASE field.
  if align_exp > 6
  then [v with BASE = [v[BASE] with (align_exp - 7) .. 0 = zeros()]]
  else v
}



// Accessor used by the jump-table vectoring logic: the xijt value for priv.
function get_xijt(priv : Privilege) -> Xijt =
  match priv {
    Machine    => mijt,
    Supervisor => sijt,
    _          => Mk_Xijt(zeros()),
  }

mapping clause csr_name_map = 0x307 <-> "mijt"
mapping clause csr_name_map = 0x107 <-> "sijt"

function clause is_CSR_accessible(0x307, priv, _) =
  currentlyEnabled(Ext_Smijt) & priv == Machine
function clause is_CSR_accessible(0x107, priv, _) =
  currentlyEnabled(Ext_Ssijt) & (priv == Machine | priv == Supervisor)

function clause read_CSR(0x307) = mijt.bits
function clause read_CSR(0x107) = sijt.bits

function clause write_CSR(0x307, value) = {
  mijt = legalize_xijt(Mk_Xijt(value), plat_mijt_base_alignment_exp, hartSupports(Ext_Smehv));
  Ok(mijt.bits)
}
function clause write_CSR(0x107, value) = {
  sijt = legalize_xijt(Mk_Xijt(value), plat_sijt_base_alignment_exp, hartSupports(Ext_Ssehv));
  Ok(sijt.bits)
}



// -------------------------------------------------------------------------
// ACLIC trap-entry hooks.
//
// try_interrupt_jumptable and xijt_ext_enabled are defined by the Smijt/Ssijt
// extension (extensions/aclic/smijt.sail). aclic_trap_entry_active and
// handle_interrupt_aclic are defined in extensions/aclic/aclic_sys_control.sail.
// They are declared here (in the shared ACLIC register module, loaded
// `before sys`) so handle_interrupt in sys/sys_control.sail can call them.
val try_interrupt_jumptable : (Privilege, InterruptType) -> result(option(xlenbits), sync_exception)
val xijt_ext_enabled : Privilege -> bool

// Smip/Ssip interrupt-handler push. Some(exc) if a push store faulted.

val try_interrupt_push : Privilege -> option(sync_exception)

// Is the interrupt-handler push extension (Smip/Ssip) enabled for priv?
// Defined in extensions/aclic/smip.sail; declared here so
// aclic_trap_entry_active in aclic_sys_control.sail can consult it.
val xip_ext_enabled : Privilege -> bool

// Smehv/Ssehv synchronous exception hardware-vectoring hook, defined in
// extensions/aclic/smehv.sail but declared here so trap_handler in
// sys/sys_control.sail can consult it when computing the trap vector.
// Returns Some(handler) when the trap being taken is a synchronous
// exception, xtvec is in jump-table mode, and xijt.EHV is set for the
// delegated privilege; None() to fall back to the normal trap vector.
val smehv_exc_vector : (Privilege, Mcause) -> option(xlenbits)



// ACLIC interrupt trap entry (jump-table lookup + handler push + pending
// clear), defined in extensions/aclic/aclic_sys_control.sail. handle_interrupt
// takes this path only when aclic_trap_entry_active holds.
val aclic_trap_entry_active : Privilege -> bool
val handle_interrupt_aclic : (InterruptType, Privilege) -> unit

function clause write_CSR(0x146, value) = { set_sistatus(value); Ok(get_sistatus()) }

// -------------------------------------------------------------------------
// miconfig / siconfig - interrupt configuration CSRs (Smip/Ssip + Smnip/Ssnip).
//
// The ACLIC specification accesses miconfig/siconfig indirectly at
// *iselect == 0x1000 through the mireg/sireg alias (indirect alias index 1).
// The machine view (miconfig) exposes the full register; the supervisor view
// (siconfig) is a subset exposing only the S-visible fields (sipu, snipen,
// snipbits).
//
// Backed fields:
//   4  mipu  (Smip):  enable interrupt-handler push at machine level
//   5  sipu  (Ssip):  enable interrupt-handler push at supervisor level
//   2  mnipen  (Smnip): enable nested preemption at machine level
//   3  snipen  (Ssnip): enable nested preemption at supervisor level
//   11:8   mnipbits (Smnip): machine nested-preemption threshold bits
//   19:16  snipbits (Ssnip): supervisor nested-preemption threshold bits
bitfield Miconfig : bits(64) = {
  snipbits : 19 .. 16,  // Ssnip
  mnipbits : 11 .. 8,   // Smnip
  sipu     : 5,         // Ssip:  supervisor push-enable
  mipu     : 4,         // Smip:  machine push-enable
  snipen   : 3,         // Ssnip: supervisor nested-preemption enable
  mnipen   : 2,         // Smnip: machine nested-preemption enable
}

register miconfig : Miconfig = Mk_Miconfig(zeros())

// WARL legalization: only mipu/sipu and the nested-preemption fields are
// writable, and only when the corresponding extension is supported. All
// other fields are read-only 0.
// The highest legal value of mnipbits/snipbits is IPRIOLEN. The field is 4
// bits wide, so values above IPRIOLEN are legalized down to IPRIOLEN.
function legalize_nipbits(v : bits(4)) -> bits(4) =
  if unsigned(v) > IPRIOLEN then to_bits(4, 8) else v

function legalize_miconfig(v : Miconfig) -> Miconfig = {
  let m = if hartSupports(Ext_Smip) then v[mipu] else 0b0;
  let s = if hartSupports(Ext_Ssip) then v[sipu] else 0b0;
  let mnipen   = if hartSupports(Ext_Smnip) then v[mnipen] else 0b0;
  let snipen   = if hartSupports(Ext_Ssnip) then v[snipen] else 0b0;
  let mnipbits = if hartSupports(Ext_Smnip) then legalize_nipbits(v[mnipbits]) else zeros();
  let snipbits = if hartSupports(Ext_Ssnip) then legalize_nipbits(v[snipbits]) else zeros();
  [Mk_Miconfig(zeros()) with
    mipu = m, sipu = s,
    mnipen = mnipen, snipen = snipen,
    mnipbits = mnipbits, snipbits = snipbits]
}


// The *iselect value at which miconfig/siconfig are accessed.
let ACLIC_ICONFIG_SELECT : xlenbits = zero_extend(0x1000)

// Accessor used by the interrupt trap-entry logic: is push enabled at priv?
function xiconfig_ipu(priv : Privilege) -> bits(1) =
  match priv {
    Machine    => miconfig[mipu],
    Supervisor => miconfig[sipu],
    _          => 0b0,
  }


// Register the miconfig/siconfig views with the indirect CSR framework.
// miconfig/siconfig are accessed through the mireg/sireg alias (indirect
// alias index 1) at *iselect == 0x1000. The M-view is gated by Smip or
// Smnip, the S-view (siconfig) by Ssip or Ssnip. Selects other than 0x1000
// fall through to the default (unimplemented) clauses.
function clause indirect_csr_implemented((Machine, select, 1) if select == ACLIC_ICONFIG_SELECT) =
  currentlyEnabled(Ext_Smip) | currentlyEnabled(Ext_Smnip)
function clause indirect_csr_implemented((Supervisor, select, 1) if select == ACLIC_ICONFIG_SELECT) =
  currentlyEnabled(Ext_Ssip) | currentlyEnabled(Ext_Ssnip)

function clause indirect_read((Machine, select, 1) if select == ACLIC_ICONFIG_SELECT) =
  miconfig.bits[xlen - 1 .. 0]
// siconfig is a subset view of miconfig: only the S-visible fields (sipu,
// snipen, snipbits) are exposed.
function clause indirect_read((Supervisor, select, 1) if select == ACLIC_ICONFIG_SELECT) =
  [Mk_Miconfig(zeros()) with
    sipu = miconfig[sipu],
    snipen = miconfig[snipen],
    snipbits = miconfig[snipbits]].bits[xlen - 1 .. 0]

function clause indirect_write((Machine, select, 1, value) if select == ACLIC_ICONFIG_SELECT) = {
  miconfig = legalize_miconfig(Mk_Miconfig(zero_extend(value)))
}
// Writing siconfig updates only the S-visible fields of miconfig; the
// M-only fields are preserved.
function clause indirect_write((Supervisor, select, 1, value) if select == ACLIC_ICONFIG_SELECT) = {
  let w = Mk_Miconfig(zero_extend(value));
  let merged = [miconfig with sipu = w[sipu]];
  miconfig = legalize_miconfig(merged)
}

// -------------------------------------------------------------------------
// Conditional stack-pointer-swap primitives (forward declarations).
//
// The state (mspcs/sspcs) and the bodies of these primitives belong to the
// Smcsps/Sscsps extension and are defined in extensions/Smcsps/smcsps.sail.
// They are only declared here (in the shared ACLIC register module, which
// is loaded `before sys`) so that the Smip/Ssip interrupt-handler push at
// trap entry can call them without depending on the Smcsps module. When
// Smcsps/Sscsps is not implemented the definitions reduce to a no-op, so
// the interrupt push simply skips the stack-pointer swap.
val xcsps_push_swap : Privilege -> unit
val xcsps_pop_swap : Privilege -> unit

// -------------------------------------------------------------------------
// Smnip/Ssnip nested-preemption hooks (forward declarations).
//
// Bodies live in extensions/aclic/smnip.sail (loaded after sys) so they can
// call the core arbitration helpers and sys state. They are declared here
// (before sys) so getPendingSet/trap_handler/do_xret can call them. When
// Smnip/Ssnip is not enabled each reduces to a no-op / identity.

// Mask the pending-and-enabled set for `priv` by the nested-preemption
// threshold: when xnipen==1, any source whose reported IPRIO is >= the
// nipbits-masked xithreshold.iprio is treated as disabled. Returns the
// (possibly reduced) pending bit vector. Identity when Smnip/Ssnip off.
val smnip_mask_pending : (Privilege, xlenbits) -> xlenbits

// Trap entry: save the current xithreshold.iprio into xistatus.pithreshprio
// and, for an interrupt, raise xithreshold.iprio to the taken interrupt's
// IPRIO (xtopsi.IPRIO) and claim it. Synchronous exceptions do not modify
// xithreshold. A double trap in M-mode leaves pithreshprio unchanged (the
// hook detects the recursive-into-M case via the previous privilege).
val smnip_trap_enter : (Privilege, Privilege, bool) -> unit

// xret: restore xithreshold.iprio from xistatus.pithreshprio for the
// privilege being returned from.
val smnip_xret_restore : Privilege -> unit
