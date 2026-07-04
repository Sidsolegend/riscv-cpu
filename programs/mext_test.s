# ============================================================================
#  mext_test.s — self-test for the M extension (mul / div family)
# ----------------------------------------------------------------------------
#  Leaves known answers in x18..x29 for the testbench to check, deliberately
#  hitting every edge case the RISC-V spec defines for division:
#    divide by zero, and INT_MIN / -1 overflow.
#
#  Build:  python3 tools/asm.py programs/mext_test.s
#  Run:    make mext   (checks it on BOTH cores)
# ============================================================================
        .text
        li      t0, 7
        li      t1, 6
        mul     x18, t0, t1          # x18  = 42

        li      t0, -3
        li      t1, 5
        mulh    x19, t0, t1          # x19  = high(-15)         = 0xFFFFFFFF

        li      t0, -1              # 0xFFFFFFFF
        li      t1, 2
        mulhu   x20, t0, t1          # x20  = high(0x1FFFFFFFE) = 1

        li      t0, -100
        li      t1, 7
        div     x21, t0, t1          # x21  = -14   (rounds toward zero)
        rem     x22, t0, t1          # x22  = -2    (sign follows dividend)

        li      t0, 100
        li      t1, 7
        divu    x23, t0, t1         # x23 = 14
        remu    x24, t0, t1         # x24 = 2

        li      t0, 5
        div     x25, t0, zero       # x25 = -1          (divide by zero)
        rem     x26, t0, zero       # x26 = 5           (rem by zero = dividend)

        li      t0, 0x80000000      # INT_MIN
        li      t1, -1
        div     x27, t0, t1         # x27 = INT_MIN     (overflow case)
        rem     x28, t0, t1         # x28 = 0

        li      t0, -1
        li      t1, -1
        mulhsu  x29, t0, t1         # x29 = high(-1 * 0xFFFFFFFF) = 0xFFFFFFFF

        li      t0, HALT
        sw      zero, 0(t0)
spin:   j       spin
