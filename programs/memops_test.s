# ============================================================================
#  memops_test.s — self-test for byte / half-word loads and stores
# ----------------------------------------------------------------------------
#  Builds the word 0x8091A2B3 in RAM one BYTE at a time, then reads it back
#  at every size, checking sign- vs zero-extension. Answers land in x18..x24
#  for the testbench.
#
#  Little-endian layout after the four sb's:
#      addr   0    1    2    3
#      byte  B3   A2   91   80      ->  word = 0x8091A2B3
#
#  Build:  python3 tools/asm.py programs/memops_test.s
#  Run:    make memops   (checks it on BOTH cores)
# ============================================================================
        .text
        li      t0, 0               # RAM base

        li      t1, 0xB3
        sb      t1, 0(t0)
        li      t1, 0xA2
        sb      t1, 1(t0)
        li      t1, 0x91
        sb      t1, 2(t0)
        li      t1, 0x80
        sb      t1, 3(t0)

        lw      x18, 0(t0)           # x18  = 0x8091A2B3   (word assembled from bytes)
        lb      x19, 3(t0)           # x19  = 0xFFFFFF80   (sign-extended byte)
        lbu     x20, 3(t0)           # x20  = 0x00000080   (zero-extended byte)
        lh      x21, 2(t0)           # x21  = 0xFFFF8091   (sign-extended half)
        lhu     x22, 2(t0)           # x22  = 0x00008091   (zero-extended half)

        li      t1, 0xBEEF
        sh      t1, 6(t0)           # upper half of word 1
        lw      x23, 4(t0)          # x23 = 0xBEEF0000

        lb      x24, 0(t0)          # x24 = 0xFFFFFFB3   (0xB3 sign-extends too)

        li      t0, HALT
        sw      zero, 0(t0)
spin:   j       spin
