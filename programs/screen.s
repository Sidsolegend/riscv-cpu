# Same as hello.s, but every character also goes to the LCD device, so on
# the Tang Nano 9K it shows up on the 1.14" screen as well as the terminal.
# (In simulation dmem echoes LCD writes to the console too, so each
# character prints twice there.)
        .text
start:
        li      t0, UART
        li      t4, LCD
        la      t1, msg
loop:
        lbu     t2, 0(t1)
        beqz    t2, done
        sb      t2, 0(t0)           # terminal
        sb      t2, 0(t4)           # screen
        addi    t1, t1, 1
        j       loop
done:
        li      t3, HALT
        sw      zero, 0(t3)
spin:
        j       spin

        .data
msg:    .asciz  "HELLO FROM MY RISC-V CPU!\nrunning on a Tang Nano 9K\n"
