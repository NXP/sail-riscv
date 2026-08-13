// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// Register offsets.
let SIG_VERSION_OFFSET = 0
let SIG_PLATFORM_OFFSET = 4
// AIA top(e)i configuration registers (added in device version 1.1).
let SIG_MTOPEI_CFG_OFFSET = 8
let SIG_STOPEI_CFG_OFFSET = 12


private val sig_load : forall 'n, 0 < 'n <= max_mem_access . (MemoryAccessType(mem_payload), physaddr, int('n)) -> MemoryOpResult(bits(8 * 'n))
function sig_load(access, addr, width) = {
  let Physaddr(paddr) = addr;
  // Version of this MMIO device (1.1 currently).
  // This follows semver. Version 1.1 added the AIA top(e)i config
  // registers (mtopei_cfg / stopei_cfg) at offsets 8 and 12.
  let VERSION = 0x00010001;

  if width != 4 | paddr[1 .. 0] != zeros()
  then Err(addr, accessFaultFromAccessType(access))
  else {
    if paddr == plat_sig_base + SIG_VERSION_OFFSET
    then Ok(VERSION)
    else if paddr == plat_sig_base + SIG_PLATFORM_OFFSET
    then Ok(zeros())
    else if paddr == plat_sig_base + SIG_MTOPEI_CFG_OFFSET
    then Ok(sig_mtopei_cfg)
    else if paddr == plat_sig_base + SIG_STOPEI_CFG_OFFSET
    then Ok(if currentlyEnabled(Ext_S) then sig_stopei_cfg else zeros())
    else Err(addr, accessFaultFromAccessType(access))
  }
}


private val sig_store : forall 'n, 0 < 'n <= max_mem_access . (physaddr, int('n), bits(8 * 'n)) -> MemoryOpResult(bool)
function sig_store(addr, width, data) = {
  let Physaddr(paddr) = addr;
  if width != 4 | paddr[1 .. 0] != zeros()
  then Err(addr, E_SAMO_Access_Fault())
  else {
    if paddr == plat_sig_base + SIG_VERSION_OFFSET
    then Ok(true)
    else if paddr == plat_sig_base + SIG_PLATFORM_OFFSET
    then {
      let value = data[31];
      let data = Mk_Minterrupts(zero_extend(data));

      // Reserved bits must currently be written with zeros.
      if [data with MEI = 0b0, SEI = 0b0, MSI = 0b0, SSI = 0b0].bits[30 .. 0] != zeros()
      then return Err(addr, E_SAMO_Access_Fault());

      if data[MEI] == 0b1 then sig_meip = value;
      if data[SEI] == 0b1 then sig_seip = value;
      if data[MSI] == 0b1 then mip[MSI] = value;
      // SSI is read-only zero if the hart does not support supervisor mode.
      if data[SSI] == 0b1 & currentlyEnabled(Ext_S) then mip[SSI] = value;

      csr_write_callback("mip", read_mip(IncludePlatformInterrupts).bits);

      Ok(true)
    }
    else if paddr == plat_sig_base + SIG_MTOPEI_CFG_OFFSET
    then {
      // Only the identity (bits 26:16) and priority (bits 7:0) fields are
      // writable; reserved bits are read-only zero (WARL). A priority of 0
      // is not a valid external-controller priority and is legalized to 1.
      sig_mtopei_cfg = sig_legalize_topei_cfg(zero_extend(data));
      Ok(true)
    }
    else if paddr == plat_sig_base + SIG_STOPEI_CFG_OFFSET
    then {
      // The supervisor config only exists when S-mode is supported.
      if currentlyEnabled(Ext_S)
      then sig_stopei_cfg = sig_legalize_topei_cfg(zero_extend(data));
      Ok(true)
    } else Err(addr, E_SAMO_Access_Fault())


  }
}
