// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// IMSIC (Incoming MSI Controller) - first draft.
//
// This models the machine-level and supervisor-level interrupt files only
// (no guest interrupt files, and no virtualisation). The IMSIC is one of
// the two mutually-exclusive external interrupt controllers in this model
// (the other being the Simple Interrupt Generator, SIG); at most one of
// them is configured (see validate_config.sail).
//
// Each interrupt file provides, per the AIA specification:
//   - eidelivery  : interrupt delivery enable (0 or 1 supported here).
//   - eithreshold : interrupt enable threshold.
//   - eip array   : per-identity interrupt-pending bits.
//   - eie array   : per-identity interrupt-enable bits.
//
// These are accessed indirectly through miselect/mireg (machine file) and
// siselect/sireg (supervisor file), and pending bits can additionally be
// set by an MSI write to the file's memory-mapped seteipnum register.
//
// Identities run from 1 to plat_imsic_num_ids (identity 0 is reserved and
// never pending). The arrays are sized for the architectural maximum of
// 2047 identities (64 words of 32 bits); identities above
// plat_imsic_num_ids are read-only zero.

// -------------------------------------------------------------------------
// State
// -------------------------------------------------------------------------

// The eip/eie arrays hold one bit per interrupt identity, packed as 64
// 32-bit words. Word w covers identities 32*w .. 32*w+31. Bit 0 of word 0
// (identity 0) is reserved and always reads zero.
type imsic_word_index = range(0, 63)

register imsic_m_eidelivery  : bits(32) = zeros()
register imsic_m_eithreshold : bits(32) = zeros()
register imsic_m_eip : vector(64, bits(32)) = vector_init(zeros())
register imsic_m_eie : vector(64, bits(32)) = vector_init(zeros())

register imsic_s_eidelivery  : bits(32) = zeros()
register imsic_s_eithreshold : bits(32) = zeros()
register imsic_s_eip : vector(64, bits(32)) = vector_init(zeros())
register imsic_s_eie : vector(64, bits(32)) = vector_init(zeros())

// -------------------------------------------------------------------------
// Identity / word helpers
// -------------------------------------------------------------------------

// Whether a raw identity number is a valid, implemented identity. Identity
// 0 is reserved; identities above the configured count are not implemented.
function imsic_valid_identity(id : int) -> bool =
  id >= 1 & id <= plat_imsic_num_ids

// Non-negativity-safe word index for an identity (id >> 5).
function imsic_word_of(id : int) -> imsic_word_index =
  if id >= 0 & id <= 2047 then id / 32 else 0

// Bit position within a word for an identity (id mod 32).
function imsic_bit_of(id : int) -> range(0, 31) =
  if id >= 0 then id % 32 else 0

// -------------------------------------------------------------------------
// eip / eie accessors, per privilege (Machine = M file, otherwise S file)
// -------------------------------------------------------------------------

function imsic_get_eip_word(priv : Privilege, w : imsic_word_index) -> bits(32) =
  match priv {
    Machine => imsic_m_eip[w],
    _       => imsic_s_eip[w],
  }

function imsic_get_eie_word(priv : Privilege, w : imsic_word_index) -> bits(32) =
  match priv {
    Machine => imsic_m_eie[w],
    _       => imsic_s_eie[w],
  }

function imsic_set_eip_word(priv : Privilege, w : imsic_word_index, v : bits(32)) -> unit =
  match priv {
    Machine => imsic_m_eip[w] = v,
    _       => imsic_s_eip[w] = v,
  }

function imsic_set_eie_word(priv : Privilege, w : imsic_word_index, v : bits(32)) -> unit =
  match priv {
    Machine => imsic_m_eie[w] = v,
    _       => imsic_s_eie[w] = v,
  }

// eidelivery WARL values. 1 selects IMSIC delivery; 0 disables delivery.
// 0x40000000 selects APLIC direct delivery and is only legal (and only
// meaningful) when both an IMSIC and an APLIC are configured; see
// sys/ext_intctl_combined.sail.
let EIDELIVERY_IMSIC : bits(32) = 0x0000_0001
let EIDELIVERY_APLIC : bits(32) = 0x4000_0000

function imsic_get_eidelivery(priv : Privilege) -> bits(32) =
  match priv {
    Machine => imsic_m_eidelivery,
    _       => imsic_s_eidelivery,
  }

function imsic_get_eithreshold(priv : Privilege) -> bits(32) =
  match priv {
    Machine => imsic_m_eithreshold,
    _       => imsic_s_eithreshold,
  }

// Set (val=true) or clear (val=false) the pending bit for one identity.
function imsic_write_eip_bit(priv : Privilege, id : int, set_bit : bool) -> unit = {
  if imsic_valid_identity(id) then {
    let w = imsic_word_of(id);
    let b = imsic_bit_of(id);
    let word = imsic_get_eip_word(priv, w);
    let mask : bits(32) = 0x0000_0001 << b;
    let updated = if set_bit then word | mask else word & not_vec(mask);
    imsic_set_eip_word(priv, w, updated);
  }
}


// -------------------------------------------------------------------------
// Top interrupt arbitration
// -------------------------------------------------------------------------

// Legalize a mask of the meaningful identity bits of a word: only bits for
// identities 1 .. plat_imsic_num_ids are retained. Identity 0 (bit 0 of
// word 0) and identities above the configured count are forced to zero.
function imsic_word_valid_mask(w : imsic_word_index) -> bits(32) = {
  var mask : bits(32) = zeros();
  foreach (b from 0 to 31) {
    let id = 32 * w + b;
    if imsic_valid_identity(id) then mask = mask | (0x0000_0001 << b);
  };
  mask
}

// The identity of the highest-priority pending-and-enabled interrupt in the
// given file, or None. Priority order is by increasing identity number
// (lowest identity number is highest priority). An interrupt is a candidate
// only if delivery is enabled (eidelivery == 1), its eip and eie bits are
// both set, and it passes the eithreshold gate: when eithreshold is
// non-zero only identities strictly less than eithreshold are eligible.
function imsic_top_identity(priv : Privilege) -> option(range(0, 2047)) = {
  if imsic_get_eidelivery(priv)[0] != bitone then return None();
  let threshold = unsigned(imsic_get_eithreshold(priv));
  var result : option(range(0, 2047)) = None();
  foreach (w from 0 to 63) {
    let candidates = imsic_get_eip_word(priv, w) & imsic_get_eie_word(priv, w) & imsic_word_valid_mask(w);
    if candidates != zeros() then {
      foreach (b from 0 to 31) {
        let id = 32 * w + b;
        if result == None() & candidates[b] == bitone then {
          let eligible = threshold == 0 | id < threshold;
          if eligible then result = Some(id);
        }
      }
    }
  };
  result
}

// The value reported by xtopei: bits 26:16 hold the interrupt identity and
// bits 10:0 hold the interrupt priority, which for an IMSIC equals the
// identity number. Reads as zero when no interrupt is eligible.
function imsic_read_topei(priv : Privilege) -> xlenbits =
  match imsic_top_identity(priv) {
    None()   => zeros(),
    Some(id) => {
      let idbits : xlenbits = zero_extend(to_bits(11, id));
      (idbits << 16) | idbits
    },
  }

// Claim (read-and-clear) the top interrupt: clears the eip bit of the
// currently reported top interrupt, if any.
function imsic_claim_topei(priv : Privilege) -> unit =
  match imsic_top_identity(priv) {
    None()   => (),
    Some(id) => imsic_write_eip_bit(priv, id, false),
  }

// -------------------------------------------------------------------------
// External interrupt controller interface (ext_intctl_topei dispatch)
// -------------------------------------------------------------------------

// The IMSIC registers itself as an external interrupt controller by
// contributing a guarded clause of the shared ext_intctl_topei scattered
// function (declared in core/external_interrupt_ctl.sail). The guard fires
// only when the IMSIC is the configured controller; when it is not, dispatch
// falls through to the unguarded fallback clause in sys/ext_intctl_dispatch.sail,
// which forwards to the Simple Interrupt Generator (sig_ext_intctl_topei).
// The IMSIC and the SIG are mutually exclusive (see postlude/validate_config.sail).
// This file only adds a clause; it neither modifies nor removes the fallback.
// When an APLIC is also configured this standalone clause is suppressed (its
// guard excludes plat_aplic_enabled) and the combined 3-way selector clause
// in sys/ext_intctl_combined.sail takes over instead.
function clause ext_intctl_topei(priv if plat_have_imsic & not(plat_aplic_enabled)) =
  match imsic_top_identity(priv) {
    None()   => (zeros(), zeros()),
    // Report the minor identity and a live priority of 1. The priority
    // byte is only consumed by mtopi/stopi under Iprio_Iprio reporting;
    // 1 is a valid live external-interrupt priority.
    Some(id) => (to_bits(11, id), 0x01),
  }

// The IMSIC's claim clause: report the current top interrupt and clear its
// eip bit. Guarded identically to the topei clause so it fires only when the
// IMSIC is the standalone controller; the combined APLIC+IMSIC selector in
// sys/ext_intctl_combined.sail supersedes it when both are configured.
function clause ext_intctl_claim(priv if plat_have_imsic & not(plat_aplic_enabled)) =
  match imsic_top_identity(priv) {
    None()   => (zeros(), zeros()),
    Some(id) => {
      imsic_write_eip_bit(priv, id, false);
      (to_bits(11, id), 0x01)
    },
  }

// -------------------------------------------------------------------------
// Indirect CSR access (eidelivery / eithreshold / eip / eie)
// -------------------------------------------------------------------------

// The AIA interrupt-file *iselect layout (eidelivery / eithreshold / eip /
// eie) and its select-decode helpers are shared with any other controller
// that presents an AIA interrupt file; they live in sys/aia_interrupt_file.sail
// (aia_select_is_eip / aia_select_is_eie / aia_eixx_word_index /
// aia_eixx_select_accessible / aia_eixx_is_paired, and the AIA_SELECT_*
// select constants). This file supplies the IMSIC's own per-privilege word
// storage and valid-identity masking on top of that shared decode.
let IMSIC_SELECT_EIDELIVERY  : xlenbits = AIA_SELECT_EIDELIVERY
let IMSIC_SELECT_EITHRESHOLD : xlenbits = AIA_SELECT_EITHRESHOLD

function imsic_select_implemented(select : xlenbits) -> bool =
  select == IMSIC_SELECT_EIDELIVERY
  | select == IMSIC_SELECT_EITHRESHOLD
  | aia_select_is_eip(select)
  | aia_select_is_eie(select)



// Legalize eithreshold (WARL): values must be representable as an identity
// number, i.e. 0 .. plat_imsic_num_ids. Larger values are held at 0.
function imsic_legalize_eithreshold(v : xlenbits) -> bits(32) = {
  let n = unsigned(v);
  if n <= plat_imsic_num_ids then v[31 .. 0] else zeros()
}

// Read the eip/eie word (or word pair on RV64) selected by a select value
// in the eip or eie range. On RV32 a select accesses a single 32-bit word;
// on RV64 an even select accesses the 64-bit pair (word, word+1) and an odd
// select is reserved (read-only zero).
function imsic_read_array(priv : Privilege, is_eip : bool, idx : range(0, 63)) -> xlenbits = {
  let lo : bits(32) = if is_eip then imsic_get_eip_word(priv, idx) else imsic_get_eie_word(priv, idx);
  if xlen == 64 then {
    // Even selects access the 64-bit pair (idx, idx+1); odd selects are
    // reserved. idx < 63 keeps idx+1 within the range(0,63) word index type
    // (an even idx is always <= 62, so the fall-through is unreachable).
    if aia_eixx_select_accessible(idx) & idx < 63 then {

      let hi : bits(32) = if is_eip then imsic_get_eip_word(priv, idx + 1) else imsic_get_eie_word(priv, idx + 1);
      zero_extend(hi @ lo)
    } else zeros()
  } else {
    zero_extend(lo)
  }
}

// Write the eip/eie word(s) selected by a select value in the eip or eie
// range, applying the valid-identity mask so unimplemented (and reserved
// identity 0) bits stay zero.
function imsic_write_array(priv : Privilege, is_eip : bool, idx : range(0, 63), value : xlenbits) -> unit = {
  let lo = value[31 .. 0] & imsic_word_valid_mask(idx);
  if is_eip then imsic_set_eip_word(priv, idx, lo) else imsic_set_eie_word(priv, idx, lo);
  if xlen == 64 & idx % 2 == 0 then {
    let hi = value[63 .. 32] & imsic_word_valid_mask(idx + 1);
    if is_eip then imsic_set_eip_word(priv, idx + 1, hi) else imsic_set_eie_word(priv, idx + 1, hi);
  }
}

// The word index for an eip/eie select value (shared AIA decode).
function imsic_array_index(select : xlenbits) -> range(0, 63) =
  aia_eixx_word_index(select)


// Register the IMSIC interrupt-file selects with the indirect CSR framework.
// The machine file is reached via miselect (Machine), the supervisor file
// via siselect (Supervisor). Availability is gated by Smaia/Ssaia and by the
// IMSIC being configured.
// The IMSIC interrupt-file registers are reached through the primary
// access register mireg/sireg (alias index 1); the alternate registers
// mireg2 .. mireg6 / sireg2 .. sireg6 are not used.
function clause indirect_csr_implemented((Machine, select, 1) if imsic_select_implemented(select) & plat_have_imsic) =
  currentlyEnabled(Ext_Smaia)

function clause indirect_csr_implemented((Supervisor, select, 1) if imsic_select_implemented(select) & plat_have_imsic) =
  currentlyEnabled(Ext_Ssaia)

function imsic_indirect_read(priv : Privilege, select : xlenbits) -> xlenbits = {
  if select == IMSIC_SELECT_EIDELIVERY then zero_extend(imsic_get_eidelivery(priv))
  else if select == IMSIC_SELECT_EITHRESHOLD then zero_extend(imsic_get_eithreshold(priv))
  else if aia_select_is_eip(select) then imsic_read_array(priv, true, imsic_array_index(select))
  else if aia_select_is_eie(select) then imsic_read_array(priv, false, imsic_array_index(select))

  else zeros()
}

function imsic_indirect_write(priv : Privilege, select : xlenbits, value : xlenbits) -> unit = {
  if select == IMSIC_SELECT_EIDELIVERY then {
    // eidelivery is WARL. Bit 0 (value 1) enables IMSIC delivery. When an
    // APLIC is also configured, the AIA-defined value 0x40000000 (select
    // APLIC direct delivery) is additionally legal. All other values are
    // held at 0 (delivery disabled).
    let legal : bits(32) =
      if value[31 .. 0] == EIDELIVERY_APLIC & plat_aplic_enabled then EIDELIVERY_APLIC
      else zero_extend(value[0 .. 0]);
    match priv {
      Machine => imsic_m_eidelivery = legal,
      _       => imsic_s_eidelivery = legal,
    }
  } else if select == IMSIC_SELECT_EITHRESHOLD then {
    let t = imsic_legalize_eithreshold(value);
    match priv {
      Machine => imsic_m_eithreshold = t,
      _       => imsic_s_eithreshold = t,
    }
  } else if aia_select_is_eip(select) then {
    imsic_write_array(priv, true, imsic_array_index(select), value)
  } else if aia_select_is_eie(select) then {

    imsic_write_array(priv, false, imsic_array_index(select), value)
  } else ()
}

function clause indirect_read((Machine, select, 1) if imsic_select_implemented(select) & plat_have_imsic) =
  imsic_indirect_read(Machine, select)
function clause indirect_read((Supervisor, select, 1) if imsic_select_implemented(select) & plat_have_imsic) =
  imsic_indirect_read(Supervisor, select)

function clause indirect_write((Machine, select, 1, value) if imsic_select_implemented(select) & plat_have_imsic) =
  imsic_indirect_write(Machine, select, value)
function clause indirect_write((Supervisor, select, 1, value) if imsic_select_implemented(select) & plat_have_imsic) =
  imsic_indirect_write(Supervisor, select, value)

// -------------------------------------------------------------------------
// mtopei (0x35C) / stopei (0x15C)
// -------------------------------------------------------------------------

mapping clause csr_name_map = 0x35C <-> "mtopei"
mapping clause csr_name_map = 0x15C <-> "stopei"

// mtopei/stopei (0x35C/0x15C) are shared between the IMSIC and the ACLIC
// (they are mutually exclusive controllers, see validate_config.sail). These
// clauses are guarded on plat_have_imsic so that the ACLIC can contribute its
// own guarded clauses (guarded on plat_have_aclic) in aplic/aclic.sail.
function clause is_CSR_accessible((0x35C, _, _) if plat_have_imsic) = plat_have_imsic & currentlyEnabled(Ext_Smaia)
function clause is_CSR_accessible((0x15C, _, _) if plat_have_imsic) = plat_have_imsic & currentlyEnabled(Ext_Ssaia)

function clause read_CSR((0x35C) if plat_have_imsic) = imsic_read_topei(Machine)
function clause read_CSR((0x15C) if plat_have_imsic) = imsic_read_topei(Supervisor)

// Any write to xtopei claims (reads and clears) the current top interrupt.
function clause write_CSR((0x35C, _) if plat_have_imsic) = {
  imsic_claim_topei(Machine);
  Ok(imsic_read_topei(Machine))
}
function clause write_CSR((0x15C, _) if plat_have_imsic) = {
  imsic_claim_topei(Supervisor);
  Ok(imsic_read_topei(Supervisor))
}

// -------------------------------------------------------------------------
// Memory-mapped interrupt file (seteipnum)
// -------------------------------------------------------------------------

// Each interrupt file occupies one 4KiB page. The M-mode file is at
// plat_imsic_base, the S-mode file at plat_imsic_base + 0x1000. Within a
// file only the seteipnum registers are modelled:
//   0x00 : seteipnum_le - write the identity number (little-endian) to set
//   0x04 : seteipnum_be - write the identity number (byte-reversed) to set
let IMSIC_FILE_SIZE      : physaddrbits = zero_extend(0x1000)
let IMSIC_SETEIPNUM_LE   : physaddrbits = zero_extend(0x000)
let IMSIC_SETEIPNUM_BE   : physaddrbits = zero_extend(0x004)

private function within_imsic forall 'n, 0 < 'n <= max_mem_access . (Physaddr(addr) : physaddr, width : int('n)) -> bool = {
  if not(plat_have_imsic) then return false;
  let addr_int  = unsigned(addr);
  let base_int  = unsigned(plat_imsic_base);
  let size_int  = unsigned(plat_imsic_size);
    base_int <= addr_int
  & (addr_int + sizeof('n)) <= (base_int + size_int)
}

// Determine the interrupt file (privilege) that an address falls in, and
// the offset within that file. The M file is the first page, the S file
// the second. When S mode is not supported, the second page is not a valid
// file.
function imsic_file_of(paddr : physaddrbits) -> option((Privilege, physaddrbits)) = {
  let offset = paddr - plat_imsic_base;
  if offset <_u IMSIC_FILE_SIZE then Some((Machine, offset))
  else if offset <_u plat_imsic_size & currentlyEnabled(Ext_S)
  then Some((Supervisor, offset - IMSIC_FILE_SIZE))
  else None()
}

private val imsic_load : forall 'n, 0 < 'n <= max_mem_access . (MemoryAccessType(mem_payload), physaddr, int('n)) -> MemoryOpResult(bits(8 * 'n))
function imsic_load(access, addr, width) = {
  let Physaddr(paddr) = addr;
  // Only aligned 4-byte accesses are supported. The seteipnum registers
  // read as zero.
  if width != 4 | paddr[1 .. 0] != zeros()
  then Err(addr, accessFaultFromAccessType(access))
  else {
    match imsic_file_of(paddr) {
      Some((_, file_offset)) =>
        if file_offset == IMSIC_SETEIPNUM_LE | file_offset == IMSIC_SETEIPNUM_BE
        then Ok(zeros())
        else Err(addr, accessFaultFromAccessType(access)),
      None() => Err(addr, accessFaultFromAccessType(access)),
    }
  }
}

private val imsic_store : forall 'n, 0 < 'n <= max_mem_access . (physaddr, int('n), bits(8 * 'n)) -> MemoryOpResult(bool)
function imsic_store(addr, width, data) = {
  let Physaddr(paddr) = addr;
  if width != 4 | paddr[1 .. 0] != zeros()
  then Err(addr, E_SAMO_Access_Fault())
  else {
    match imsic_file_of(paddr) {
      Some((priv, file_offset)) => {
        // Extract the identity number to make pending. seteipnum_be uses a
        // byte-reversed value.
        let value : bits(32) = data[31 .. 0];
        if file_offset == IMSIC_SETEIPNUM_LE then {
          imsic_write_eip_bit(priv, unsigned(value), true);
          // MEI/SEI pending is derived from the controller when mip is read;
          // notify observers that the mip view may have changed.
          csr_write_callback("mip", read_mip(IncludePlatformInterrupts).bits);
          Ok(true)
        } else if file_offset == IMSIC_SETEIPNUM_BE then {
          let swapped : bits(32) = value[7 .. 0] @ value[15 .. 8] @ value[23 .. 16] @ value[31 .. 24];
          imsic_write_eip_bit(priv, unsigned(swapped), true);
          csr_write_callback("mip", read_mip(IncludePlatformInterrupts).bits);
          Ok(true)
        } else Err(addr, E_SAMO_Access_Fault())

      },
      None() => Err(addr, E_SAMO_Access_Fault()),
    }
  }
}
