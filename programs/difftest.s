# ============================================================================
#  difftest.s  —  a deterministic workout for the single-cycle-vs-pipeline
#                 equivalence check (tests/tb_diff.v)
# ----------------------------------------------------------------------------
#  Deliberately avoids the cycle timer and the UART (whose behaviour differs
#  between the two cores) so that BOTH cores must end in identical register and
#  memory state. Exercises arithmetic, mul/div, byte/half memory access, a
#  taken-branch loop, and a jal/jalr call — i.e. every hazard the pipeline has
#  to get right. Writes all results into the `results` array and halts.
# ============================================================================
        .text
_start:
        li    s0, 0                 # accumulator
        li    t0, 1
        li    t1, 10
sumloop:
        add   s0, s0, t0            # 1+2+...+10 = 55
        addi  t0, t0, 1
        bge   t1, t0, sumloop

        la    s1, results
        sw    s0, 0(s1)             # [0]  = 55

        li    a0, 7
        li    a1, 6
        mul   a2, a0, a1            # 42
        sw    a2, 4(s1)             # [1]  = 42

        li    a3, 100
        li    a4, 7
        div   a5, a3, a4            # 14
        rem   a6, a3, a4            # 2
        sw    a5, 8(s1)             # [2]  = 14
        sw    a6, 12(s1)            # [3]  = 2

        li    t2, 0x12345678        # byte / half access (load-use hazards)
        sw    t2, 16(s1)            # [4]  = 0x12345678
        lb    t3, 16(s1)            # 0x78 -> sign-extended
        sw    t3, 20(s1)            # [5]  = 0x00000078
        lhu   t4, 18(s1)            # upper half
        sw    t4, 24(s1)            # [6]  = 0x00001234

        call  double               # a0 (=7) doubled via a jal/jalr call
        sw    a0, 28(s1)            # [7]  = 14

        li    t0, HALT
        sw    x0, 0(t0)             # halt, exit 0
hang:   j     hang

double:
        slli  a0, a0, 1
        ret

        .data
results: .space 64
