// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// APLIC memory-mapped register ACCESS / offset decode. This is the only file
// that knows the byte layout of a domain's control region; it decodes an
// access into a (domain, offset) pair and dispatches to the register-STATE
// helpers in aplic_domain.sail / aplic_regs.sail / aplic_idc_direct.sail.
// Keeping decode separate from state means an alternate access path can be
// added later without disturbing the register model.
//
// Each interrupt domain occupies a naturally-aligned control region of
// APLIC_DOMAIN_STRIDE bytes, starting at plat_aplic_base:
//   domain d region base = plat_aplic_base + d * APLIC_DOMAIN_STRIDE
//
// Offsets within a domain's region (only the direct-delivery subset is
// implemented; everything else reads as zero / is ignored on write):
//   0x0000            domaincfg
//   0x0004 + 4*i      sourcecfg[i]        (i = 1 .. NUM_SOURCES-1)
//   0x1C00            setip[0]
//   0x1CDC            setipnum
//   0x1D00            in_clrip[0]
//   0x1DDC            clripnum
//   0x1E00            setie[0]
//   0x1EDC            setienum
//   0x1F00            clrie[0]
//   0x1FDC            clrienum
//   0x3000 + 4*i      target[i]           (i = 1 .. NUM_SOURCES-1)
//   0x4000            IDC[0].idelivery
//   0x4004            IDC[0].iforce
//   0x4008            IDC[0].ithreshold
//   0x4018            IDC[0].topi
//   0x401C            IDC[0].claimi
// (One hart index per domain in this model, so only IDC 0 exists.)

// Size of one domain's memory-mapped control region. Must be at least 16KiB
// and contain the IDC array (which starts at 0x4000); 0x8000 leaves headroom.
let APLIC_DOMAIN_STRIDE : int = 32768 // 0x8000

// Region offsets (within a single domain control region), as integers.
// Values given in decimal because Sail hex literals are bitvector-typed.
let APLIC_OFF_DOMAINCFG   : int = 0        // 0x0000
let APLIC_OFF_SOURCECFG_0 : int = 4        // 0x0004
let APLIC_OFF_TARGET_BASE : int = 12288    // 0x3000
let APLIC_OFF_SETIP_0     : int = 7168     // 0x1C00
let APLIC_OFF_SETIPNUM    : int = 7388     // 0x1CDC
let APLIC_OFF_IN_CLRIP_0  : int = 7424     // 0x1D00
let APLIC_OFF_CLRIPNUM    : int = 7644     // 0x1DDC
let APLIC_OFF_SETIE_0     : int = 7680     // 0x1E00
let APLIC_OFF_SETIENUM    : int = 7900     // 0x1EDC
let APLIC_OFF_CLRIE_0     : int = 7936     // 0x1F00
let APLIC_OFF_CLRIENUM    : int = 8156     // 0x1FDC
let APLIC_OFF_TARGET_1    : int = 12292    // 0x3004
let APLIC_OFF_IDC_BASE    : int = 16384    // 0x4000
let APLIC_IDC_IDELIVERY   : int = 0        // 0x00
let APLIC_IDC_IFORCE      : int = 4        // 0x04
let APLIC_IDC_ITHRESHOLD  : int = 8        // 0x08
let APLIC_IDC_TOPI        : int = 24       // 0x18
let APLIC_IDC_CLAIMI      : int = 28       // 0x1C

// Read-only tag in bits 31:24 of domaincfg. Bit 31 set marks correct byte
// order; the model is little-endian only (BE read-only zero).
let APLIC_DOMAINCFG_TAG : bits(32) = 0x8000_0000

// Divide a byte offset by 4 to get a word/source index. The inner guard makes
// the non-negativity precondition explicit so the type checker can discharge
// the quot_positive_round_zero quantifier; negative inputs cannot occur here.
function aplic_word_index(n : int) -> int =
  if n >= 0 then n / 4 else 0

// Whether an access lies within the APLIC's overall memory-mapped region.
function within_aplic forall 'n, 0 < 'n <= max_mem_access . (Physaddr(addr) : physaddr, width : int('n)) -> bool = {
  if not(plat_aplic_enabled) then return false;
  let addr_int = unsigned(addr);
  let base_int = unsigned(plat_aplic_base);
  let num_domains : int = plat_aplic_num_domains;
  let size_int = num_domains * APLIC_DOMAIN_STRIDE;
    base_int <= addr_int
  & (addr_int + sizeof('n)) <= (base_int + size_int)
}

// Decode a physical address into (domain, offset) within that domain's
// region, or None if it is outside any active domain's region.
function aplic_decode(paddr : physaddrbits) -> option((aplic_domain_index, int)) = {
  let addr_int = unsigned(paddr);
  let base_int = unsigned(plat_aplic_base);
  if addr_int < base_int then return None();
  let rel = addr_int - base_int;
  // Iterate over the modelled domains rather than dividing, so the type
  // checker does not need to reason about the divisor / remainder.
  var result : option((aplic_domain_index, int)) = None();
  foreach (domain from 0 to (APLIC_NUM_DOMAINS - 1)) {
    if domain < plat_aplic_num_domains then {
      let region_lo = domain * APLIC_DOMAIN_STRIDE;
      let region_hi = region_lo + APLIC_DOMAIN_STRIDE;
      if region_lo <= rel & rel < region_hi then {
        let offset = rel - region_lo;
        result = Some((domain, offset));
      }
    }
  };
  result
}

// Compose the readable value of domaincfg for a domain: read-only tag plus IE
// bit (bit 8). DM and BE are read-only zero (direct, little-endian).
function aplic_read_domaincfg(domain : aplic_domain_index) -> bits(32) =
  APLIC_DOMAINCFG_TAG | (zero_extend(aplic_domaincfg_ie[domain]) << 8)

// The source-indexed pending/enable word readers (setip[0]/setie[0]) live in
// the STATE layer (aplic_regs.sail: aplic_read_pending_word /
// aplic_read_enable_word) so they can be shared with the ACLIC access path.

// Rectified-input word for an in_clrip read.
function aplic_read_rectified_word(domain : aplic_domain_index) -> bits(32) = {
  var w : bits(32) = zeros();
  foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
    if aplic_rectified_input(domain, source) == bitone
    then w = [w with source = bitone];
  };
  w
}

// topi/claimi 32-bit encoding: identity in bits 25:16, priority in bits 7:0.
function aplic_topi_word(identity : bits(11), priority : bits(8)) -> bits(32) =
  (zero_extend(identity) << 16) | zero_extend(priority)

// Read side of the APLIC. Only naturally-aligned 32-bit accesses are
// supported; anything else faults.
val aplic_load : forall 'n, 0 < 'n <= max_mem_access . (MemoryAccessType(mem_payload), physaddr, int('n)) -> MemoryOpResult(bits(8 * 'n))
function aplic_load(access, addr, width) = {
  let Physaddr(paddr) = addr;
  if width != 4 | paddr[1 .. 0] != zeros()
  then return Err(addr, accessFaultFromAccessType(access));
  match aplic_decode(paddr) {
    None() => Err(addr, accessFaultFromAccessType(access)),
    Some((domain, offset)) => {
      // domaincfg
      if offset == APLIC_OFF_DOMAINCFG then Ok(zero_extend(aplic_read_domaincfg(domain)))
      // sourcecfg[i]
      else if offset >= APLIC_OFF_SOURCECFG_0 & offset < APLIC_OFF_SOURCECFG_0 + 4 * (APLIC_NUM_SOURCES - 1) then {
        let source = aplic_word_index(offset - APLIC_OFF_DOMAINCFG); // = i since sourcecfg[i] @ 4*i
        if source > 0 & source < APLIC_NUM_SOURCES
        then Ok(zero_extend(aplic_sourcecfg[domain][source]))
        else Ok(zeros())
      }
      else if offset == APLIC_OFF_SETIP_0 then Ok(zero_extend(aplic_read_pending_word(domain)))
      else if offset == APLIC_OFF_SETIPNUM then Ok(zeros())        // read as zero
      else if offset == APLIC_OFF_IN_CLRIP_0 then Ok(zero_extend(aplic_read_rectified_word(domain)))
      else if offset == APLIC_OFF_CLRIPNUM then Ok(zeros())
      else if offset == APLIC_OFF_SETIE_0 then Ok(zero_extend(aplic_read_enable_word(domain)))
      else if offset == APLIC_OFF_SETIENUM then Ok(zeros())
      else if offset == APLIC_OFF_CLRIE_0 then Ok(zeros())         // clrie reads as zero
      else if offset == APLIC_OFF_CLRIENUM then Ok(zeros())
      // target[i]
      else if offset >= APLIC_OFF_TARGET_1 & offset < APLIC_OFF_TARGET_1 + 4 * (APLIC_NUM_SOURCES - 1) then {
        let source = aplic_word_index(offset - APLIC_OFF_TARGET_BASE); // target[i] @ 0x3000 + 4*i
        if source > 0 & source < APLIC_NUM_SOURCES then {
          if aplic_source_active(domain, source)
          then Ok(zero_extend(aplic_target[domain][source]))
          else Ok(zeros())
        } else Ok(zeros())
      }
      // IDC 0 registers
      else if offset == APLIC_OFF_IDC_BASE + APLIC_IDC_IDELIVERY then Ok(zero_extend(aplic_read_idelivery(domain)))
      else if offset == APLIC_OFF_IDC_BASE + APLIC_IDC_IFORCE then Ok(zero_extend(aplic_read_iforce(domain)))
      else if offset == APLIC_OFF_IDC_BASE + APLIC_IDC_ITHRESHOLD then Ok(zero_extend(aplic_read_ithreshold(domain)))

      else if offset == APLIC_OFF_IDC_BASE + APLIC_IDC_TOPI then {
        let (identity, priority) = aplic_topi(domain);
        Ok(zero_extend(aplic_topi_word(identity, priority)))
      }
      else if offset == APLIC_OFF_IDC_BASE + APLIC_IDC_CLAIMI then {
        // Read has the side effect of clearing the claimed pending bit (or
        // clearing iforce on a zero claim).
        let (identity, priority) = aplic_claim(domain);
        Ok(zero_extend(aplic_topi_word(identity, priority)))
      }
      else Ok(zeros()) // reserved / unimplemented offsets read as zero
    }
  }
}

// Write side of the APLIC. Only naturally-aligned 32-bit accesses supported.
val aplic_store : forall 'n, 0 < 'n <= max_mem_access . (physaddr, int('n), bits(8 * 'n)) -> MemoryOpResult(bool)
function aplic_store(addr, width, data) = {
  let Physaddr(paddr) = addr;
  if width != 4 | paddr[1 .. 0] != zeros()
  then return Err(addr, E_SAMO_Access_Fault());
  let data32 : bits(32) = data[31 .. 0];
  match aplic_decode(paddr) {
    None() => Err(addr, E_SAMO_Access_Fault()),
    Some((domain, offset)) => {
      if offset == APLIC_OFF_DOMAINCFG then {
        // Only IE (bit 8) is writable; DM/BE read-only zero (direct, LE).
        aplic_domaincfg_ie[domain] = [data32[8]];
        Ok(true)
      }
      else if offset >= APLIC_OFF_SOURCECFG_0 & offset < APLIC_OFF_SOURCECFG_0 + 4 * (APLIC_NUM_SOURCES - 1) then {
        let source = aplic_word_index(offset - APLIC_OFF_DOMAINCFG);
        if source > 0 & source < APLIC_NUM_SOURCES then {
          let was_active = aplic_source_active(domain, source);
          aplic_sourcecfg[domain][source] = aplic_legalize_sourcecfg(domain, source, data32);
          // If a source is made inactive, its pending/enable/target become
          // read-only zero; clear the stored state so reads are consistent.
          if was_active & not(aplic_source_active(domain, source)) then {
            aplic_pending[domain] = [aplic_pending[domain] with source = bitzero];
            aplic_enable[domain] = [aplic_enable[domain] with source = bitzero];
            aplic_target[domain][source] = zeros();
          }
        };
        Ok(true)
      }
      else if offset == APLIC_OFF_SETIP_0 then {
        foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
          if data32[source] == bitone then aplic_set_pending(domain, source);
        };
        Ok(true)
      }
      else if offset == APLIC_OFF_SETIPNUM then {
        let source = unsigned(data32[9 .. 0]);
        if source > 0 & source < APLIC_NUM_SOURCES then aplic_set_pending(domain, source);
        Ok(true)
      }
      else if offset == APLIC_OFF_IN_CLRIP_0 then {
        foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
          if data32[source] == bitone then aplic_clear_pending(domain, source);
        };
        Ok(true)
      }
      else if offset == APLIC_OFF_CLRIPNUM then {
        let source = unsigned(data32[9 .. 0]);
        if source > 0 & source < APLIC_NUM_SOURCES then aplic_clear_pending(domain, source);
        Ok(true)
      }
      else if offset == APLIC_OFF_SETIE_0 then {
        foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
          if data32[source] == bitone then aplic_set_enable(domain, source);
        };
        Ok(true)
      }
      else if offset == APLIC_OFF_SETIENUM then {
        let source = unsigned(data32[9 .. 0]);
        if source > 0 & source < APLIC_NUM_SOURCES then aplic_set_enable(domain, source);
        Ok(true)
      }
      else if offset == APLIC_OFF_CLRIE_0 then {
        foreach (source from 1 to (APLIC_NUM_SOURCES - 1)) {
          if data32[source] == bitone then aplic_clear_enable(domain, source);
        };
        Ok(true)
      }
      else if offset == APLIC_OFF_CLRIENUM then {
        let source = unsigned(data32[9 .. 0]);
        if source > 0 & source < APLIC_NUM_SOURCES then aplic_clear_enable(domain, source);
        Ok(true)
      }
      else if offset >= APLIC_OFF_TARGET_1 & offset < APLIC_OFF_TARGET_1 + 4 * (APLIC_NUM_SOURCES - 1) then {
        let source = aplic_word_index(offset - APLIC_OFF_TARGET_BASE);
        if source > 0 & source < APLIC_NUM_SOURCES then {
          if aplic_source_active(domain, source)
          then aplic_target[domain][source] = aplic_legalize_target(data32);
        };
        Ok(true)
      }
      else if offset == APLIC_OFF_IDC_BASE + APLIC_IDC_IDELIVERY then {
        // WARL 0/1: keep only bit 0.
        aplic_idelivery[domain] = [data32[0]];
        Ok(true)
      }
      else if offset == APLIC_OFF_IDC_BASE + APLIC_IDC_IFORCE then {
        aplic_iforce[domain] = [data32[0]];
        Ok(true)
      }
      else if offset == APLIC_OFF_IDC_BASE + APLIC_IDC_ITHRESHOLD then {
        // WLRL, IPRIOLEN bits.
        aplic_ithreshold[domain] = data32[7 .. 0];
        Ok(true)
      }
      // topi and claimi are read-only; writes are ignored.
      else Ok(true)
    }
  }
}
