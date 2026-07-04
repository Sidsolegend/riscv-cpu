# Running C on the core

The core is a real compiler target — not just an assembler target. This folder
compiles ordinary C with the standard RISC-V GCC toolchain and runs the result
on the CPU.

```bash
# one-time: install a bare-metal RV32 toolchain, e.g.
brew tap riscv-software-src/riscv
brew install riscv-tools          # provides riscv64-unknown-elf-gcc
# (or any riscv32/none-elf GCC; pass RISCV_GCC=... to make)

make cprog-run                    # compile sw/hello.c and run it on the core
# -> "Hello from C on my RISC-V CPU!"  /  "fib(15) = 610"
```

## How it fits the split-memory cores

These cores are Harvard-style: instructions come from `imem`, data from `dmem`,
each addressed from 0. The build reflects that:

1. `sw/crt0.s` is the startup stub — it sets the stack pointer, zeroes `.bss`,
   calls `main()`, and turns `main`'s return value into a store to the HALT
   device.
2. `sw/link.ld` places `.text` in the IMEM region and `.rodata/.data/.bss` +
   stack in the DMEM region (both at VMA 0 — legal because a code address and a
   data address never share a bus here).
3. `riscv…-objcopy` dumps the `.text` and data sections to separate `.bin`
   files, and `tools/bin2hex.py` turns each into the `$readmemh` image `imem`
   and `dmem` load.

## Files

| File        | Role                                                       |
|-------------|------------------------------------------------------------|
| `crt0.s`    | reset stub: stack + `.bss` clear + call `main` + halt      |
| `link.ld`   | maps `.text` -> imem, data/stack -> dmem                    |
| `hello.c`   | the demo: prints over the UART, computes `fib(15)` in C     |

Keep programs within the BRAM the cores instantiate (256 words of code and
256 of data by default — raise `MEM_WORDS` in `imem.v`/`dmem.v` for larger
programs).
