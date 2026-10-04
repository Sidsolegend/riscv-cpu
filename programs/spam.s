# Prints "spam " forever. Only used by tests/tb_loader.v, to load a new
# program while this one keeps the UART busy.
        .text
start:
        li      t0, UART
        la      t1, msg
again:
        mv      t2, t1
next:
        lbu     t3, 0(t2)
        beqz    t3, again
        sb      t3, 0(t0)
        addi    t2, t2, 1
        j       next

        .data
msg:    .asciz  "spam "
