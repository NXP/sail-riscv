// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================
//
// Smijt / Ssijt - Interrupt jump-table (hardware vectoring) extension.
//
// When xtvec.MODE == 0b11 (TV_JumpTable) an interrupt delegated to
// privilege x is vectored through an in-memory jump table based at xijt.
// This file provides the fault-capable table lookup try_interrupt_jumptable,
// invoked from handle_interrupt (sys/sys_control.sail) before the automatic
// interrupt-handler push, so that a fault reading the table is taken as a
// precise synchronous exception with the interrupted context intact. The
// mijt/sijt CSRs and the Xijt bitfield live in extensions/aclic/aclic_regs.sail.

// Is the jump-table extension enabled for the delegated privilege?
function xijt_ext_enabled(priv : Privilege) -> bool =
  match priv {
    Machine    => currentlyEnabled(Ext_Smijt),
    Supervisor => currentlyEnabled(Ext_Ssijt),
    _          => false,
  }

// The trap vector CSR (xtvec) for the delegated privilege.
function xtvec_for(priv : Privilege) -> Mtvec =
  match priv {
    Supervisor => stvec,
    _          => mtvec,
  }

// Resolve the handler address for an interrupt delegated to `del_priv`,
// using the jump-table vectoring mechanism.
//
// Returns:
//   Ok(None())        jump-table vectoring is not active for this trap
//                     (extension disabled, xtvec.MODE != 0b11, not an
//                     interrupt, or the table entry's vectoring-enable bit
//                     is clear). handle_interrupt falls back to the normal
//                     (direct) trap vector, which is xtvec[Base] << 2.
//   Ok(Some(handler)) resolved handler address to jump to.
//   Err(exc)          a fault occurred reading the table entry; it is taken
//                     as a precise synchronous exception.
//
// Table entry address (spec formula, external interrupts are not modeled so
// only the negated major-interrupt-identity form is used):
//   JTBASE  = xijt.BASE << 6                        (64-byte aligned)
//   entry   = M[ JTBASE - (identity << (SHAMT + 2)) ]   (XLEN-wide load)
//   VEN     = entry & 0x1
//   handler = (VEN == 1) ? (entry & JTMASK) : direct fallback
//   JTMASK  = ~0x1 (IALIGN=16, i.e. Zca/C) or ~0x3 (IALIGN=32)
//
// The interrupt identity is passed directly as an InterruptType (the value
// the caller already has in hand), rather than reconstructing it from an
// Mcause. An InterruptType is always an interrupt, so no separate
// is-interrupt guard is needed.
function try_interrupt_jumptable(del_priv : Privilege, i : InterruptType) -> result(option(xlenbits), sync_exception) = {
  if not(xijt_ext_enabled(del_priv)) then Ok(None())
  else {
    let tvec = xtvec_for(del_priv);
    if trapVectorMode(tvec[Mode]) != TV_JumpTable then Ok(None())
    else {
      let xijt    = get_xijt(del_priv);
      let jtbase : xlenbits = xijt[BASE] @ 0b000000;
      let shamt : nat       = unsigned(xijt[SHAMT]);
      let identity : nat    = unsigned(interruptType_bits(i));
      // vtoffset = -(major interrupt identity); the negation folds into a
      // subtraction of the shifted index from the table base.
      let index_bytes : xlenbits = to_bits_truncate(xlen, identity) << (shamt + 2);
      let entry_addr : xlenbits   = jtbase - index_bytes;

      // Perform the table read at the handler's privilege, restoring
      // cur_privilege afterwards, exactly as the interrupt-handler push does.
      let saved_priv = cur_privilege;
      cur_privilege = del_priv;
      // vmem_read computes the effective address as X(base) + offset. Use x0
      // (zreg) as the base so the effective address is exactly entry_addr.
      let r = vmem_read(zreg, entry_addr, xlen_bytes, Load(Data), false, false, false);

      cur_privilege = saved_priv;

      match r {
        Err(Trap(_, exc, _)) => Err(exc),
        Err(_)               => internal_error(__FILE__, __LINE__, "unexpected jump-table read fault result"),
        Ok(data) => {
          // Pure lookup: this function has no architectural side effects. The
          // pending-bit clear happens in handle_interrupt, and only when the
          // interrupt is actually hardware-vectored (VEN == 1) after the
          // interrupt-handler push has committed without faulting. Doing it
          // here would clear the bit even when the push later faults (leaving
          // the interrupt lost) and even for the VEN == 0 SW-dispatcher path.
          let entry : xlenbits = zero_extend(data);
          if entry[0 .. 0] == 0b0 then Ok(None())
          else {
            // IALIGN is 16 when compressed instructions are enabled, else 32.
            let jtmask : xlenbits =
              if currentlyEnabled(Ext_Zca)
              then ~(zero_extend(0b1))
              else ~(zero_extend(0b11));
            Ok(Some(entry & jtmask))
          }
        }
      }
    }
  }
}

