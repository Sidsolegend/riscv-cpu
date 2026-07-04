# ============================================================================
#  fib.s — compute fib(15) and PRINT it in decimal, with a cycle count.
# ----------------------------------------------------------------------------
#  This is the "applications" demo: it needs the M extension (divu/remu by 10
#  to convert a number to decimal digits), byte stores (building the digit
#  string), function calls (call/ret through ra), the UART, the cycle-counter
#  device, and HALT. Every capability of the core in ~60 instructions.
#
#  Expected output:
#      fib(15) = 610
#      cycles: <n>
#
#  Build:  python3 tools/asm.py programs/fib.s
#  Run:    make fib          (single-cycle)   /   make fib-pipe (pipeline)
# ============================================================================
        .text
start:
        # ---- fib(15) iteratively: a0 = fib(n) ----
        li      t0, 15              # n
        li      a0, 0               # fib(0)
        li      t1, 1               # fib(1)
fib_loop:
        beqz    t0, fib_done
        add     t2, a0, t1          # next = a + b
        mv      a0, t1              # a = b
        mv      t1, t2              # b = next
        addi    t0, t0, -1
        j       fib_loop
fib_done:
        mv      s1, a0              # keep fib(15) safe in s1

        # ---- print "fib(15) = " ----
        la      a0, label_str
        call    print_str
        mv      a0, s1
        call    print_dec           # print 610 in decimal
        li      a0, '\n'
        call    print_ch

        # ---- print "cycles: <n>" (read the timer DEVICE) ----
        la      a0, cyc_str
        call    print_str
        li      t0, CYCLES
        lw      a0, 0(t0)           # a0 = cycles since reset
        call    print_dec
        li      a0, '\n'
        call    print_ch

        li      t0, HALT
        sw      zero, 0(t0)         # done, exit code 0
spin:   j       spin

# ---------------------------------------------------------------------------
#  print_ch: print the single character in a0
# ---------------------------------------------------------------------------
print_ch:
        li      t5, UART
        sb      a0, 0(t5)
        ret

# ---------------------------------------------------------------------------
#  print_str: print the NUL-terminated string at address a0
# ---------------------------------------------------------------------------
print_str:
        li      t5, UART
ps_loop:
        lbu     t6, 0(a0)
        beqz    t6, ps_done
        sb      t6, 0(t5)
        addi    a0, a0, 1
        j       ps_loop
ps_done:
        ret

# ---------------------------------------------------------------------------
#  print_dec: print a0 as an unsigned decimal number.
#  Peels digits off with remu/divu by 10 (least-significant first), stores
#  them into a small buffer, then prints the buffer backwards.
# ---------------------------------------------------------------------------
print_dec:
        la      t0, digits          # t0 -> digit buffer
        li      t1, 10
        li      t2, 0               # digit count
pd_peel:
        remu    t3, a0, t1          # t3 = a0 % 10   (M extension!)
        divu    a0, a0, t1          # a0 = a0 / 10
        addi    t3, t3, '0'         # to ASCII
        add     t4, t0, t2
        sb      t3, 0(t4)           # buffer[count] = digit
        addi    t2, t2, 1
        bnez    a0, pd_peel
        li      t5, UART
pd_out:                             # print buffer[count-1] .. buffer[0]
        addi    t2, t2, -1
        add     t4, t0, t2
        lbu     t3, 0(t4)
        sb      t3, 0(t5)
        bnez    t2, pd_out
        ret

        .data
label_str: .asciz "fib(15) = "
cyc_str:   .asciz "cycles: "
digits:    .space 12               # scratch for decimal conversion
