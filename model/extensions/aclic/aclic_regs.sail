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

