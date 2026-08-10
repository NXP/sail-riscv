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
// shared by several ACLIC extensions. At present only the Smcsps/Sscsps
// (Conditional Stack Pointer Swap) fields are backed by real state; all
// other fields defined by the ACLIC specification for these CSRs (for
// example pithreshprio, introduced by Smnip) are read-only zero until the
// corresponding extension is implemented. The mstatus/sstatus mirror
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
  pithreshprio : 16 .. 8,   // Smnip: previous xithreshold.iprio (RO 0 for now)
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
  mstatus = [mstatus with
    SPP   = v[SPP],
    SPIE  = v[SPIE],
    SPELP = v[SPELP],
    VS    = v[VS],
    FS    = v[FS],
    SIE   = v[SIE],
  ];
}


// mistatus (0x346) is owned by Smcsps today (the only extension backing any
// of its fields). sistatus (0x146) is owned by Sscsps.
mapping clause csr_name_map = 0x346 <-> "mistatus"
mapping clause csr_name_map = 0x146 <-> "sistatus"

function clause is_CSR_accessible(0x346, priv, _) =
  currentlyEnabled(Ext_Smcsps) & priv == Machine
function clause is_CSR_accessible(0x146, priv, _) =
  currentlyEnabled(Ext_Sscsps) & (priv == Machine | priv == Supervisor)

function clause read_CSR(0x346) = get_mistatus()
function clause read_CSR(0x146) = get_sistatus()

function clause write_CSR(0x346, value) = { set_mistatus(value); Ok(get_mistatus()) }
function clause write_CSR(0x146, value) = { set_sistatus(value); Ok(get_sistatus()) }

// -------------------------------------------------------------------------
// miconfig / siconfig - interrupt configuration CSRs.
//
// The ACLIC specification accesses miconfig/siconfig indirectly through
// miselect=0x1000 / mireg. This model does not implement the indirect
// CSR access mechanism, so, consistent with the treatment of
// mistatus/sistatus above, miconfig and siconfig are exposed at the
// otherwise-unused direct CSR addresses 0x347 and 0x147.
//
// Only the fields relevant to the currently modeled extensions are backed
// by state:
//   4  mipu  (Smip): enable interrupt-handler push at machine level
//   5  sipu  (Ssip): enable interrupt-handler push at supervisor level
// The nested-preemption fields (mnipbits/snipbits/mnipen/snipen) belong to
// the Smnip/Ssnip extensions and are read-only zero here. siconfig is a
// subset view of miconfig sharing the same physical bits.
bitfield Miconfig : bits(64) = {
  snipbits : 19 .. 16,  // Ssnip: RO 0 for now
  mnipbits : 11 .. 8,   // Smnip: RO 0 for now
  sipu     : 5,         // Ssip:  supervisor push-enable
  mipu     : 4,         // Smip:  machine push-enable
  snipen   : 3,         // Ssnip: RO 0 for now
  mnipen   : 2,         // Smnip: RO 0 for now
}

register miconfig : Miconfig = Mk_Miconfig(zeros())

// WARL legalization: only mipu/sipu are writable, and only when the
// corresponding extension is supported. All other fields are read-only 0.
function legalize_miconfig(v : Miconfig) -> Miconfig = {
  let m = if hartSupports(Ext_Smip) then v[mipu] else 0b0;
  let s = if hartSupports(Ext_Ssip) then v[sipu] else 0b0;
  [Mk_Miconfig(zeros()) with mipu = m, sipu = s]
}

// Accessor used by the interrupt trap-entry logic: is push enabled at priv?
function xiconfig_ipu(priv : Privilege) -> bits(1) =
  match priv {
    Machine    => miconfig[mipu],
    Supervisor => miconfig[sipu],
    _          => 0b0,
  }

mapping clause csr_name_map = 0x347 <-> "miconfig"
mapping clause csr_name_map = 0x147 <-> "siconfig"

function clause is_CSR_accessible(0x347, priv, _) =
  currentlyEnabled(Ext_Smip) & priv == Machine
function clause is_CSR_accessible(0x147, priv, _) =
  currentlyEnabled(Ext_Ssip) & (priv == Machine | priv == Supervisor)

function clause read_CSR(0x347) = miconfig.bits[xlen - 1 .. 0]
// siconfig is a subset view of miconfig: it exposes only the S-visible
// fields (sipu and snipbits). Mask out the M-only fields on read.
function clause read_CSR(0x147) =
  [Mk_Miconfig(zeros()) with sipu = miconfig[sipu], snipbits = miconfig[snipbits]].bits[xlen - 1 .. 0]

function clause write_CSR(0x347, value) = {
  miconfig = legalize_miconfig(Mk_Miconfig(zero_extend(value)));
  Ok(miconfig.bits[xlen - 1 .. 0])
}
// Writing siconfig updates only the S-visible fields of miconfig; the
// M-only fields are preserved.
function clause write_CSR(0x147, value) = {
  let w = Mk_Miconfig(zero_extend(value));
  let merged = [miconfig with sipu = w[sipu]];
  miconfig = legalize_miconfig(merged);
  Ok(read_CSR(0x147))
}

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
// ACLIC trap-entry hooks (forward declarations).
//
// Defined in the Smijt/Ssijt and Smip/Ssip extensions but declared here (in
// the shared ACLIC register module, loaded `before sys`) so handle_interrupt
// in sys/sys_control.sail can call them. try_interrupt_jumptable is a pure
// lookup returning the jump-table handler address (Ok(Some) if vectored,
// Ok(None) to use the direct vector, Err on a table-read fault). The
// x*_ext_enabled predicates gate the ACLIC trap-entry path.
val try_interrupt_jumptable : (Privilege, InterruptType) -> result(option(xlenbits), sync_exception)
val xijt_ext_enabled : Privilege -> bool
val xip_ext_enabled : Privilege -> bool

// Smip/Ssip interrupt-handler push. Some(exc) if a push store faulted.
val try_interrupt_push : Privilege -> option(sync_exception)

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






