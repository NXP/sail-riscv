// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// APLIC (Advanced Platform-Level Interrupt Controller): shared types and
// parameters. This changeset implements direct interrupt delivery only;
// MSI delivery mode is deliberately out of scope and reserved bits for it
// (domaincfg.DM = 1, target MSI layout, genmsi, msiaddrcfg) are modelled as
// read-only zero.
//
// Structure follows the specification (riscv-aia/src/AdvPLIC.adoc):
//   aplic_types.sail          : this file, identities and parameters
//   aplic_domain.sail         : domaincfg / sourcecfg / delegation / source mode
//   aplic_regs.sail           : per-domain pending/enable/target register STATE
//   aplic_idc_direct.sail     : direct-mode IDC state + priority arbitration
//   aplic_delivery_direct.sail: direct delivery signal + ext_intctl_topei
//   aplic_mmio.sail           : memory-mapped register ACCESS / offset decode
//
// The register STATE files are kept strictly separate from the register
// ACCESS file (aplic_mmio.sail) so that a future access variant (for
// example an ACLIC-style access path, or MSI-mode delivery in
// aplic_idc_msi.sail / aplic_delivery_msi.sail) can reuse the same state
// without touching the decode layer.

// Number of interrupt domains supported by the model. The tested
// configuration uses two domains (a machine-level root and a
// supervisor-level child targeting the same hart). This is a build-time
// constant; the active domain count is selected by config (see
// plat_aplic_num_domains in platform_config.sail).
type aplic_num_domains : Int = 2
let  APLIC_NUM_DOMAINS = 2

// A valid interrupt domain index.
type aplic_domain_index = range(0, 1)

// Number of interrupt sources modelled per domain. Source identity 0 is
// never a valid source (it is the AIA "no interrupt" sentinel), so valid
// sources are 1 .. APLIC_NUM_SOURCES-1. One 32-bit setip/setie word covers
// exactly this range, which keeps the memory map simple.
type aplic_num_sources : Int = 32
let  APLIC_NUM_SOURCES = 32

// A source identity within a domain. Identity 0 is reserved / no source.
type aplic_source_index = range(0, 31)

// Interrupt priority length (IPRIOLEN). Priority numbers are 1 ..
// 2^IPRIOLEN - 1; a smaller number is higher priority. This matches the
// AIA model's external-controller priority width.
let APLIC_IPRIOLEN = 8

// Source Mode (SM) encodings for a non-delegated sourcecfg (bit D = 0).
// Values 2 and 3 are reserved. Level modes are recognized but, because the
// model has no external source wires, their rectified input is always zero
// (see aplic_domain.sail); direct-delivery tests drive pending via edge or
// detached sources and setipnum.
let SM_INACTIVE = 0b000
let SM_DETACHED = 0b001
let SM_EDGE1    = 0b100
let SM_EDGE0    = 0b101
let SM_LEVEL1   = 0b110
let SM_LEVEL0   = 0b111
