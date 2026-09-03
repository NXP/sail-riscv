// =======================================================================================
// This Sail RISC-V architecture model, comprising all files and
// directories except where otherwise noted is subject the BSD
// two-clause license in the LICENSE file.
//
// SPDX-License-Identifier: BSD-2-Clause
// =======================================================================================
//
// ACLIC interrupt trap entry.
//
// handle_interrupt (sys/sys_control.sail) delegates here when any ACLIC
// trap-entry extension (jump-table vectoring or interrupt-handler push) is
// enabled. The generic no-ACLIC trap entry stays in sys_control.sail.

// Is any ACLIC trap-entry extension enabled for a trap delegated to `priv`?
function aclic_trap_entry_active(priv : Privilege) -> bool =
  xijt_ext_enabled(priv) | xip_ext_enabled(priv)

function handle_interrupt_aclic(i : InterruptType, del_priv : Privilege) -> unit = {
  // The fault-capable jump-table lookup and handler push happen before any
  // committed side effect, so a fault is a precise exception with the
  // interrupted context intact and the interrupt re-takeable.
  let handler_opt : option(xlenbits) = match try_interrupt_jumptable(del_priv, i) {
    Err(exc) => { set_next_pc(exception_handler(cur_privilege, exc, PC)); return () },
    Ok(h)    => h,
  };
  match try_interrupt_push(del_priv) {
    Some(exc) => { set_next_pc(exception_handler(cur_privilege, exc, PC)); return () },
    None()    => (),
  };
  // Clear the pending bit only when hardware-vectored, so a faulting push
  // does not lose the interrupt and the VEN == 0 path leaves it for software.
  match handler_opt {
    Some(_) => clear_interrupt_pending(i),
    None()  => (),
  };
  let vector_pc = trap_handler(del_priv, Interrupt(i), PC, None(), None());
  set_next_pc(match handler_opt { Some(handler) => handler, None() => vector_pc })
}
