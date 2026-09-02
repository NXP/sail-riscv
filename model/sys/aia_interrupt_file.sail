// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================

// Shared AIA external-interrupt "interrupt file" indirect-select decode.
//
// The AIA defines a common indirect-CSR layout for the per-privilege
// external-interrupt registers (eidelivery / eithreshold / eip / eie),
// reached through miselect/mireg (machine) and siselect/sireg (supervisor):
//
//   0x70        : eidelivery
//   0x72        : eithreshold
//   0x80 .. 0xBF: eip0  .. eip63
//   0xC0 .. 0xFF: eie0  .. eie63
//
// This layout is used by more than one controller: the IMSIC interrupt
// files (sys/imsic.sail) and, when the ACLIC hart-local interrupt domain
// control (Smidctrl/Ssidctrl) is configured, the ACLIC domains alias their
// pending/enable bits onto the eip/eie selects. The select-decode logic is
// identical for both and is backing-store agnostic, so it lives here and is
// reused by each controller. Each controller supplies its own word storage
// (the IMSIC per-privilege eip/eie vectors, the ACLIC per-domain APLIC
// pending/enable arrays) and its own valid-bit masking; only the select ->
// (word index, eip-vs-eie, RV64 pairing) decode is shared.

// eip/eie words are 32 bits; the architectural maximum of 2047 identities
// packs into 64 words. Word w covers identities 32*w .. 32*w+31.
type aia_word_index = range(0, 63)

let AIA_SELECT_EIDELIVERY  : xlenbits = zero_extend(0x70)
let AIA_SELECT_EITHRESHOLD : xlenbits = zero_extend(0x72)

// Whether a select value lies in the eip range (0x80 .. 0xBF).
function aia_select_is_eip(select : xlenbits) -> bool = {
  let s = unsigned(select);
  if s >= 128 then s <= 191 else false
}

// Whether a select value lies in the eie range (0xC0 .. 0xFF).
function aia_select_is_eie(select : xlenbits) -> bool = {
  let s = unsigned(select);
  if s >= 192 then s <= 255 else false
}

// The 32-bit word index (0 .. 63) addressed by an eip or eie select value.
// Returns 0 for select values outside the eip/eie ranges.
function aia_eixx_word_index(select : xlenbits) -> aia_word_index = {
  let s = unsigned(select);
  if aia_select_is_eip(select) & s >= 128 & s <= 191 then s - 128
  else if aia_select_is_eie(select) & s >= 192 & s <= 255 then s - 192
  else 0
}

// On RV64 the eip/eie array is accessed 64 bits at a time: an even select
// addresses the word pair (idx, idx+1) and an odd select is reserved
// (read-only zero). On RV32 every select addresses a single word. This
// predicate says whether the given word index is the low half of an
// accessible access at the current xlen: always true on RV32, and true only
// for even indices on RV64.
function aia_eixx_select_accessible(idx : aia_word_index) -> bool =
  if xlen == 64 then idx % 2 == 0 else true

// Whether the current xlen accesses eip/eie as a 64-bit word pair (RV64).
function aia_eixx_is_paired() -> bool = xlen == 64
