# ============================================================================
#  crt0.s — C runtime startup ("what runs before main")
# ----------------------------------------------------------------------------
#  The C compiler assumes someone has already set up a stack, zeroed .bss, and
#  will call main(). On a bare-metal core that "someone" is this file, placed at
#  address 0 by the linker script so it's the first thing the CPU fetches.
#
#    1. point sp at the top of data memory
#    2. clear the .bss section (uninitialised globals must read as 0)
#    3. call main()
#    4. when main returns, store its result to the HALT device to stop the sim
# ============================================================================
        .section .text._start
        .globl _start
_start:
        la      sp, _stack_top          # 1. initialise the stack pointer

        la      t0, _bss_start          # 2. zero .bss
        la      t1, _bss_end
1:      bge     t0, t1, 2f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       1b
2:
        call    main                    # 3. run the C program

        li      t0, 0x10000008          # 4. HALT device (MMIO_HALT)
        sw      a0, 0(t0)               #    exit code = main()'s return value
3:      j       3b                      #    spin until the simulator stops
