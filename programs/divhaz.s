# Divides in every awkward spot for a pipeline that stalls on them: operands
# straight from the instruction before, the result used by the very next
# instruction, a load feeding a divide, a store and a branch right after
# one, back-to-back dependent divides, a call straight after. Checked by
# running it on both cores and comparing every register and memory word
# (make seqdiv), so it doesn't print anything itself.
        .text
        li      t0, 100
        li      t1, 7
        div     t2, t0, t1          # operand from the instruction just before
        addi    t3, t2, 1           # result used immediately
        rem     t4, t3, t1          # divide fed by the previous result
        mul     t5, t4, t2
        la      a0, buf
        sw      t2, 0(a0)
        lw      a1, 0(a0)
        divu    a2, a1, t1          # load straight into a divide
        sw      a2, 4(a0)           # store straight after one
        li      a3, 3
        div     a4, a2, a3
        beq     a4, zero, skip1     # branch on a divide result
        addi    a5, zero, 11
skip1:
        remu    a6, a4, a3
        bne     a6, zero, skip2
        addi    a7, zero, 22
skip2:
        div     s2, t0, t1
        div     s3, s2, t1          # back-to-back, dependent
        div     s4, s3, zero        # by zero, also back-to-back
        jal     ra, func            # call straight after
        sw      s5, 8(a0)
        lw      s6, 8(a0)
        rem     s7, s6, t1
        sw      s7, 12(a0)
        li      t6, HALT
        sw      zero, 0(t6)
spin:   j       spin

func:
        divu    s5, t0, t1
        ret

        .data
buf:    .space  16
