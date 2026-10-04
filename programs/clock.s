# Live demo for the board: the CPU hunts for primes by trial division
# (remu), and once a second, timed off its own cycle counter, redraws one
# status line in place with '\r':
#
#   RISC-V CPU on a Tang Nano 9K
#
#     time      primes    largest
#     00:01:23   12345    1234567
#
# Everything goes to both the UART and the screen (LCD device -> HDMI).
# A second is however many cycles the CLKHZ device says the CPU clock is,
# so this keeps real time on any build (12.6 MHz single-cycle, 21 MHz
# pipeline, ...); bitstreams from before CLKHZ existed read 0 there, and
# then it assumes 12.6 MHz. The cycle counter is 32 bits and wraps every
# few minutes, which is fine: elapsed time is (now - last), unsigned.
#
#   make load PROGRAM=clock       (or make synth PROGRAM=clock to build it in)

        .equ    DEFAULT_HZ, 12600000

        .text
start:
        li      s5, CYCLES
        li      t0, CLKHZ
        lw      s6, 0(t0)           # s6 = cycles per second
        bnez    s6, have_hz
        li      s6, DEFAULT_HZ
have_hz:
        lw      s0, 0(s5)           # s0 = cycle count at the last whole second
        li      s1, 0               # seconds since start
        li      s2, 3               # next candidate (odd numbers only)
        li      s3, 1               # primes found so far (2 counts)
        li      s4, 2               # largest prime so far

        la      a0, banner
        call    print_str
        call    show

loop:
        lw      t0, 0(s5)
        sub     t1, t0, s0
        bltu    t1, s6, work        # not a second yet: keep hunting
        add     s0, s0, s6
        addi    s1, s1, 1
        call    show
        j       loop

work:                               # is s2 prime? try odd divisors up to sqrt
        li      t2, 3
try:
        mul     t3, t2, t2
        bltu    s2, t3, prime       # divisor^2 > n: nothing divided it
        remu    t4, s2, t2
        beqz    t4, composite
        addi    t2, t2, 2
        j       try
prime:
        addi    s3, s3, 1
        mv      s4, s2
composite:
        addi    s2, s2, 2
        j       loop

# redraw the status line: "\r  hh:mm:ss  pppppp   llllllll"
show:
        mv      s7, ra
        li      a0, '\r'
        call    putc
        li      a0, ' '
        call    putc
        li      a0, ' '
        call    putc
        li      t0, 3600
        divu    a0, s1, t0          # hours
        call    print2
        li      a0, ':'
        call    putc
        li      t0, 60
        divu    a0, s1, t0
        remu    a0, a0, t0          # minutes
        call    print2
        li      a0, ':'
        call    putc
        li      t0, 60
        remu    a0, s1, t0          # seconds
        call    print2
        mv      a0, s3
        li      a1, 8
        call    print_num
        mv      a0, s4
        li      a1, 11
        call    print_num
        mv      ra, s7
        ret

# a0 as two digits (00..99)
print2:
        mv      s8, ra
        li      t0, 10
        divu    t1, a0, t0
        remu    s9, a0, t0
        addi    a0, t1, '0'
        call    putc
        addi    a0, s9, '0'
        call    putc
        mv      ra, s8
        ret

# a0 as unsigned decimal, right-aligned in a field a1 wide
print_num:
        mv      s8, ra
        la      s10, digits
        li      t0, 10
        li      s9, 0               # digit count
pn_peel:
        remu    t1, a0, t0
        divu    a0, a0, t0
        addi    t1, t1, '0'
        add     t2, s10, s9
        sb      t1, 0(t2)
        addi    s9, s9, 1
        bnez    a0, pn_peel
        sub     s11, a1, s9         # leading spaces
pn_pad:
        bge     zero, s11, pn_out
        li      a0, ' '
        call    putc
        addi    s11, s11, -1
        j       pn_pad
pn_out:
        addi    s9, s9, -1
        add     t2, s10, s9
        lbu     a0, 0(t2)
        call    putc
        bnez    s9, pn_out
        mv      ra, s8
        ret

print_str:
        mv      s8, ra
        mv      s10, a0
ps_loop:
        lbu     a0, 0(s10)
        beqz    a0, ps_done
        call    putc
        addi    s10, s10, 1
        j       ps_loop
ps_done:
        mv      ra, s8
        ret

# a0 to the UART and the screen
putc:
        li      t5, UART
        sb      a0, 0(t5)
        li      t5, LCD
        sb      a0, 0(t5)
        ret

        .data
banner: .asciz  "RISC-V CPU on a Tang Nano 9K\n\n  time      primes    largest\n"
digits: .space  12
