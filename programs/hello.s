# ============================================================================
#  hello.s — the classic first program, running on OUR cpu.
# ----------------------------------------------------------------------------
#  Walks a NUL-terminated string in data memory and writes each byte to the
#  memory-mapped UART. Exercises: la/li, lbu (byte load), sb (byte store to a
#  DEVICE), beqz, j, and the HALT device.
#
#  Build:  python3 tools/asm.py programs/hello.s
#  Run:    make hello        (single-cycle)   /   make hello-pipe (pipeline)
# ============================================================================
        .text
start:
        li      t0, UART            # t0 -> the "serial port"
        la      t1, msg             # t1 -> first character of the string
loop:
        lbu     t2, 0(t1)           # fetch one character (unsigned byte)
        beqz    t2, done            # NUL terminator? then stop
        sb      t2, 0(t0)           # print it (store to the UART device)
        addi    t1, t1, 1           # next character
        j       loop
done:
        li      t3, HALT
        sw      zero, 0(t3)         # exit code 0 = success
spin:
        j       spin                # (never reached; belt-and-braces)

        .data
msg:    .asciz  "HELLO FROM MY RISC-V CPU!\n"
