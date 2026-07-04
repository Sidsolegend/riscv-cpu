# ============================================================================
#  traps.s  —  exercises the machine-mode trap system end to end
# ----------------------------------------------------------------------------
#  Three independent traps, all handled by ONE handler that saves/restores its
#  scratch registers through mscratch (the standard RISC-V trap-entry trick):
#
#     1. ecall                -> synchronous, mcause = 11
#     2. an illegal instruction (a raw .word) -> synchronous, mcause = 2
#     3. the machine-timer interrupt (mtimecmp) -> asynchronous, mcause = 0x80000007
#
#  Each path bumps a counter in memory. The program then checks all three fired
#  exactly once and prints PASS/FAIL before halting. Runs on the single-cycle
#  core (make traps).
# ============================================================================

        .text
_start:
        la    t0, trap_handler
        csrw  mtvec, t0             # install the trap vector
        la    t0, savearea
        csrw  mscratch, t0          # handler's private scratch pointer

        # ---- Test 1: environment call ------------------------------------
        ecall                       # -> handler (cause 11), returns past this

        # ---- Test 2: illegal instruction ---------------------------------
        .word 0xffffffff            # opcode 0x7f: undecodable -> illegal trap

        # ---- Test 3: machine-timer interrupt -----------------------------
        li    t0, 128               # mie.MTIE (bit 7)
        csrw  mie, t0
        csrr  t0, mcycle            # arm the timer ~30 cycles from now
        addi  t0, t0, 30
        csrw  mtimecmp, t0
        li    t0, 8                 # mstatus.MIE (bit 3): interrupts on
        csrs  mstatus, t0
        la    s0, n_timer
wait_timer:
        lw    t0, 0(s0)             # spin until the handler records the IRQ
        beqz  t0, wait_timer

        # ---- Every counter must be exactly 1 -----------------------------
        li    t1, 1
        la    s0, n_ecall
        lw    t0, 0(s0)
        bne   t0, t1, fail
        la    s0, n_illegal
        lw    t0, 0(s0)
        bne   t0, t1, fail
        la    s0, n_timer
        lw    t0, 0(s0)
        bne   t0, t1, fail

        la    a0, msg_pass
        call  puts
        li    t0, HALT
        sw    x0, 0(t0)             # halt, exit code 0
hang_ok:
        j     hang_ok

fail:
        la    a0, msg_fail
        call  puts
        li    t0, HALT
        li    t1, 1
        sw    t1, 0(t0)             # halt, exit code 1
hang_bad:
        j     hang_bad

# ---------------------------------------------------------------------------
#  Trap handler — one entry point for every cause.
# ---------------------------------------------------------------------------
trap_handler:
        csrrw t0, mscratch, t0      # t0 <- &savearea, mscratch <- app's t0
        sw    t1, 0(t0)
        sw    t2, 4(t0)
        sw    t3, 8(t0)

        csrr  t1, mcause
        blt   t1, x0, timer_irq     # cause[31]=1 (negative) => interrupt

        # ---- synchronous exception: pick the counter, skip the instruction --
        li    t2, 11
        beq   t1, t2, do_ecall
        la    t2, n_illegal         # otherwise it was the illegal instruction
        j     bump
do_ecall:
        la    t2, n_ecall
bump:
        lw    t3, 0(t2)
        addi  t3, t3, 1
        sw    t3, 0(t2)
        csrr  t1, mepc              # advance mepc past the 4-byte faulting insn
        addi  t1, t1, 4
        csrw  mepc, t1
        j     trap_ret

        # ---- asynchronous: machine-timer interrupt --------------------------
timer_irq:
        la    t2, n_timer
        lw    t3, 0(t2)
        addi  t3, t3, 1
        sw    t3, 0(t2)
        csrw  mtimecmp, x0          # disarm + acknowledge the timer

trap_ret:
        lw    t1, 0(t0)
        lw    t2, 4(t0)
        lw    t3, 8(t0)
        csrrw t0, mscratch, t0      # restore app's t0, put &savearea back
        mret

# ---------------------------------------------------------------------------
#  puts: print the NUL-terminated string at a0 via the UART.
# ---------------------------------------------------------------------------
puts:
        li    t0, UART
puts_loop:
        lbu   t1, 0(a0)
        beqz  t1, puts_done
        sb    t1, 0(t0)
        addi  a0, a0, 1
        j     puts_loop
puts_done:
        ret

        .data
savearea:  .space 16                # t1,t2,t3 saved here (t0 lives in mscratch)
n_ecall:   .word 0
n_illegal: .word 0
n_timer:   .word 0
msg_pass:  .asciz "ALL TRAP TESTS PASSED\n"
msg_fail:  .asciz "TRAP TEST FAILED\n"
