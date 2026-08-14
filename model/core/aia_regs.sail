// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// Advanced Interrupt Architecture (Smaia / Ssaia): hart-level CSRs.
//
// This is the simplest legal AIA implementation without an IMSIC. It
// provides:
//   - mtopi (0xFB0) and stopi (0xDB0): the top interrupt registers.
//   - mvien (0x308) / mvip (0x309): minimal implementation. mvien is
//     read-only zero; mvip aliases the writable bits of mip (SSI, SEI,
//     and STI). When S-mode is not implemented these registers do not
//     exist.
//   - The RV32 high-half CSRs (midelegh, mieh, mvienh, mviph, miph,
//     sieh, siph): all read-only zero, since no interrupt above bit 31
//     is implemented.
//   - The major-interrupt-priority (iprio) arrays, exposed via the
//     indirect CSR access framework (miselect/siselect 0x30 .. 0x3F),
//     as read-only zero.
//
// With all iprio bytes read-only zero (Smaia.iprio_read_only_zero, the
// only supported setting), the top interrupt registers use a simplified
// priority: the IID is the highest-priority pending-and-enabled interrupt
// in the default order.
//
// The IPRIO reporting behaviour is selectable via the Smaia.iprio_reporting
// configuration parameter (see platform_config.sail):
//   - Iprio_FixedOne: IPRIO reads as 1 whenever a top interrupt exists.
//     Requires iprio_read_only_zero to be set.
//   - Iprio_Iprio: the external top interrupt reports the priority from the
//     external interrupt controller (backed by the extended Simple Interrupt
//     Generator); all other interrupts still report 1.



// -------------------------------------------------------------------------
// mtopi / stopi
// -------------------------------------------------------------------------

// The mtopi/stopi format: bits 27:16 hold the interrupt identity (IID),
// bits 7:0 hold the interrupt priority (IPRIO). All other bits are zero.
// The register reads as zero when no interrupt is both pending and enabled.

// The AIA default priority order for the standard major interrupts is the
// base RISC-V interrupt priority order (MEI, MSI, MTI, SEI, SSI, STI,
// LCOFI). Rather than duplicate it here, both the identity selection and
// the priority rank reuse the base helpers in core/interrupt_regs.sail
// (highest_priority_pending_interrupt and interrupt_priority_rank), which
// are also used by the trap-dispatch path. This keeps a single source of
// truth without AIA owning the base arbitration order. With the iprio
// arrays read-only zero (our only supported mode) every interrupt keeps
// its default priority, so this order is exactly what the top-interrupt
// CSRs must use.

// Returns the highest-priority pending-and-enabled interrupt identity in
// the given pending/enabled sets.
function topi_iid(pending : Minterrupts, enabled : Minterrupts) -> option(range(0, 63)) =
  highest_priority_pending_interrupt(Mk_Minterrupts(pending.bits & enabled.bits))


// Build the xtopi value from an optional IID and its priority. The IID is
// the major interrupt number; IPRIO is the reported priority (mtopi/stopi
// report a major identity, not a minor one - the minor identity is a
// topei concept).
function make_xtopi(iid : option(range(0, 63)), iprio : bits(8)) -> xlenbits =
  match iid {
    None()  => zeros(),
    Some(i) => {
      let iiddbits : xlenbits = zero_extend(to_bits(12, i));
      (iiddbits << 16) | zero_extend(iprio)
    },
  }

// Determine the IPRIO to report for the winning top interrupt of the given
// privilege. Behaviour is selected by Smaia.iprio_reporting:
//
//   - Iprio_FixedOne: every pending top interrupt - external or not -
//     reports IPRIO = 1. This is the simplest legal AIA reporting without
//     an IMSIC and requires the iprio arrays to be read-only zero.
//   - Iprio_Iprio: the reported priority follows the AIA rules for an
//     iprio array that is entirely read-only zero (our only supported
//     setting). Because every iprio byte is zero, each non-external
//     interrupt's priority number is zero, so its IPRIO is derived purely
//     from its default-priority rank relative to the privilege's external
//     interrupt: 0x00 (highest) if its default priority is above the
//     external interrupt, else 0xFF (lowest). The external top interrupt
//     itself (MEI for Machine, SEI for Supervisor) reports the priority
//     number supplied by the external interrupt controller (see
//     external_interrupt_ctl.sail, backed by the extended Simple Interrupt
//     Generator). An external controller priority is always 1..255: a
//     priority of 0 is the controller's "no interrupt" sentinel and is
//     never a live priority, so it cannot be reported here (the Simple
//     Interrupt Generator legalizes a written priority of 0 to 1).

function topi_iprio(priv : Privilege, iid : range(0, 63)) -> bits(8) = {
  // The identity of the external interrupt for this privilege, and its
  // rank in the default priority order.
  let external_iid : range(0, 63) = match priv {
    Machine => 11, // MEI
    _       => 9,  // SEI
  };
  let is_external : bool = iid == external_iid;

  if plat_aia_iprio_reporting == Iprio_FixedOne then 0x01
  else if is_external then {
    // Priority number supplied by the external interrupt controller. This
    // is always a live priority (1..255); the controller never reports 0
    // for a pending external interrupt (a written priority of 0 is
    // legalized to 1 by the Simple Interrupt Generator).
    let (_, prio) = ext_intctl_topei(priv);
    prio
  } else {
    // Non-external interrupt with a read-only-zero iprio (priority number
    // 0): IPRIO is 0x00 if its default priority is above the external
    // interrupt, else 0xFF.

    if interrupt_priority_rank(iid) < interrupt_priority_rank(external_iid) then 0x00
    else 0xFF
  }
}




function read_mtopi() -> xlenbits = {
  let iid = topi_iid(read_mip(IncludePlatformInterrupts), mie);
  match iid {
    None()  => zeros(),
    Some(i) => make_xtopi(iid, topi_iprio(Machine, i)),
  }
}

function read_stopi() -> xlenbits = {
  // The supervisor view is delegated by mideleg.
  let s_pending = read_sip(IncludePlatformInterrupts);
  let s_enabled = lower_mie(mie, mideleg);
  // Reuse the machine ordering by lifting the Sinterrupts back into the
  // Minterrupts bit positions (identical bit layout).
  let iid = topi_iid(Mk_Minterrupts(s_pending.bits), Mk_Minterrupts(s_enabled.bits));
  match iid {
    None()  => zeros(),
    Some(i) => make_xtopi(iid, topi_iprio(Supervisor, i)),
  }
}


// Note: access to the supervisor-level AIA CSRs from a privilege below M
// is additionally gated by the mstateen0.AIA bit (and hstateen0 for
// VS/VU) when Smstateen is implemented. Because of module interdependency
// (core cannot depend on Stateen), that gate is applied centrally in
// `stateen_allows_CSR_access`.
mapping clause csr_name_map = 0xFB0 <-> "mtopi"
mapping clause csr_name_map = 0xDB0 <-> "stopi"

function clause is_CSR_accessible(0xFB0, _, _) = currentlyEnabled(Ext_Smaia)
function clause is_CSR_accessible(0xDB0, _, _) = currentlyEnabled(Ext_Ssaia)


function clause read_CSR(0xFB0) = read_mtopi()
function clause read_CSR(0xDB0) = read_stopi()

// mtopi/stopi are read-only; writes are ignored (return current value).
function clause write_CSR(0xFB0, _) = Ok(read_mtopi())
function clause write_CSR(0xDB0, _) = Ok(read_stopi())

// -------------------------------------------------------------------------
// mvien / mvip (minimal) and their RV32 high halves
// -------------------------------------------------------------------------

// mvien selects which interrupts have an alternative S-mode enable/pending
// path. In this minimal implementation there is no alternative delivery,
// so mvien is read-only zero.
mapping clause csr_name_map = 0x308 <-> "mvien"
mapping clause csr_name_map = 0x309 <-> "mvip"

function clause is_CSR_accessible(0x308, _, _) = currentlyEnabled(Ext_Smaia) & currentlyEnabled(Ext_S)
function clause is_CSR_accessible(0x309, _, _) = currentlyEnabled(Ext_Smaia) & currentlyEnabled(Ext_S)

function clause read_CSR(0x308) = zeros() // mvien read-only zero
function clause write_CSR(0x308, _) = Ok(zeros())

// mvip aliases the writable S-mode bits of mip: SSI (1), STI (5), SEI (9).
// Reads and writes go straight through to mip's corresponding bits.
function read_mvip() -> xlenbits = {
  let m = read_mip(ExcludePlatformInterrupts);
  [Mk_Minterrupts(zeros()) with
    SSI = m[SSI],
    STI = m[STI],
    SEI = m[SEI],
  ].bits
}

function clause read_CSR(0x309) = read_mvip()
function clause write_CSR(0x309, value) = {
  // Reuse mip's legalization so read-only conditions (e.g. Sstc STI) are
  // honoured. Only the aliased bits are taken from the written value.
  let v = Mk_Minterrupts(value);
  let updated = [read_mip(ExcludePlatformInterrupts) with
    SSI = v[SSI],
    STI = v[STI],
    SEI = v[SEI],
  ];
  write_mip(updated.bits);
  Ok(read_mvip())
}

// RV32 high-half CSRs: read-only zero (no interrupts above bit 31).
mapping clause csr_name_map = 0x313 <-> "midelegh"
mapping clause csr_name_map = 0x314 <-> "mieh"
mapping clause csr_name_map = 0x318 <-> "mvienh"
mapping clause csr_name_map = 0x319 <-> "mviph"
mapping clause csr_name_map = 0x354 <-> "miph"
mapping clause csr_name_map = 0x114 <-> "sieh"
mapping clause csr_name_map = 0x154 <-> "siph"

function clause is_CSR_accessible(0x313, _, _) = currentlyEnabled(Ext_Smaia) & currentlyEnabled(Ext_S) & xlen == 32 // midelegh
function clause is_CSR_accessible(0x314, _, _) = currentlyEnabled(Ext_Smaia) & xlen == 32 // mieh

function clause is_CSR_accessible(0x318, _, _) = currentlyEnabled(Ext_Smaia) & currentlyEnabled(Ext_S) & xlen == 32 // mvienh
function clause is_CSR_accessible(0x319, _, _) = currentlyEnabled(Ext_Smaia) & currentlyEnabled(Ext_S) & xlen == 32 // mviph
function clause is_CSR_accessible(0x354, _, _) = currentlyEnabled(Ext_Smaia) & xlen == 32 // miph
function clause is_CSR_accessible(0x114, _, _) = currentlyEnabled(Ext_Ssaia) & xlen == 32 // sieh
function clause is_CSR_accessible(0x154, _, _) = currentlyEnabled(Ext_Ssaia) & xlen == 32 // siph

function clause read_CSR(0x313 if xlen == 32) = zeros()
function clause read_CSR(0x314 if xlen == 32) = zeros()

function clause read_CSR(0x318 if xlen == 32) = zeros()
function clause read_CSR(0x319 if xlen == 32) = zeros()
function clause read_CSR(0x354 if xlen == 32) = zeros()
function clause read_CSR(0x114 if xlen == 32) = zeros()
function clause read_CSR(0x154 if xlen == 32) = zeros()

function clause write_CSR((0x313, _) if xlen == 32) = Ok(zeros())
function clause write_CSR((0x314, _) if xlen == 32) = Ok(zeros())

function clause write_CSR((0x318, _) if xlen == 32) = Ok(zeros())
function clause write_CSR((0x319, _) if xlen == 32) = Ok(zeros())
function clause write_CSR((0x354, _) if xlen == 32) = Ok(zeros())
function clause write_CSR((0x114, _) if xlen == 32) = Ok(zeros())
function clause write_CSR((0x154, _) if xlen == 32) = Ok(zeros())

// -------------------------------------------------------------------------
// iprio arrays via the indirect CSR framework (read-only zero)
// -------------------------------------------------------------------------

// The major-interrupt priority arrays are accessed indirectly through
// miselect/siselect values 0x30 .. 0x3F. In this minimal implementation
// every iprio byte is read-only zero, so all reads return zero and all
// writes are ignored. Registering these clauses makes mireg/sireg
// accessible (rather than raising an illegal instruction) for the iprio
// range once AIA is enabled.

function is_iprio_select(select : xlenbits) -> bool = {
  // Note: 0x30 .. 0x3F is 48 .. 63 in decimal. Sail hex literals are
  // bitvectors, so compare against decimal integers here.
  let sel = unsigned(select);
  if sel >= 48 then sel <= 63 else false
}

function clause indirect_csr_implemented(Machine, select) =
  currentlyEnabled(Ext_Smaia) & is_iprio_select(select)

function clause indirect_csr_implemented(Supervisor, select) =
  currentlyEnabled(Ext_Ssaia) & is_iprio_select(select)

function clause indirect_read((Machine, select) if is_iprio_select(select)) = zeros()
function clause indirect_read((Supervisor, select) if is_iprio_select(select)) = zeros()

function clause indirect_write((Machine, select) if is_iprio_select(select)) = ()
function clause indirect_write((Supervisor, select) if is_iprio_select(select)) = ()
