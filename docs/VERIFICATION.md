# How this CPU is verified

A processor is only as trustworthy as its tests. This project doesn't rely on
"it printed the right thing once" — it uses the same techniques real CPU teams
use: self-checking directed tests, **differential testing** against a reference,
and randomized cross-checks. Every item below runs under `make all` and prints
an explicit `RESULT: ... PASSED`; CI fails the build if any of them regress.

## 1. Self-checking directed tests

Each core and feature has a testbench that computes known-answer results and
prints `PASS`/`FAIL` per value — not just a waveform to eyeball.

| Suite            | What it pins down                                        |
|------------------|----------------------------------------------------------|
| `make single`    | single-cycle core on a real program (sum = 55)           |
| `make pipeline`  | 5-stage core, same program, same answer                  |
| `make hazard`    | forwarding (EX/MEM + MEM/WB) and the load-use stall       |
| `make mext`      | all 8 M ops incl. ÷0 and INT_MIN/−1, on **both** cores    |
| `make memops`    | `lb/lh/lw/lbu/lhu` + `sb/sh/sw`, sign/zero extension      |
| `make traps`     | ecall, illegal-instruction, and the timer interrupt       |

## 2. Differential testing (the strongest check)

Two independent implementations of the same ISA should agree on everything.

- **`make diff`** runs one deterministic program on the single-cycle *and* the
  pipelined core and asserts they end in **byte-for-byte identical** register
  and memory state. The cores share nothing but the instruction set — one
  overlaps five instructions with forwarding/stalls/flushes, the other doesn't —
  so agreement proves the pipeline's hazard machinery is transparent. This is
  exactly the "reference model vs implementation" method used to sign off real
  silicon.

- **`make muldiv`** verifies the multi-cycle (bit-serial) mul/div unit against
  the combinational ALU — which already passes the M-extension suite — across
  every spec edge case plus **2000 pseudo-random inputs**. Two different
  datapaths, same answer on every input.

## 3. Independent-oracle testing

- **`make rvc`** checks the compressed-instruction decompressor by expanding 16-bit
  `C.*` instructions and comparing to 32-bit encodings produced **independently
  by the assembler** (`tools/asm.py`). The decompressor and the assembler derive
  their encodings from the spec separately, so a match validates both. (During
  development this caught a bug — in the *test generator*, not the RTL.)

## 4. Hardware-timing tests

The FPGA peripherals have logic that's easy to get subtly wrong (bit timing,
nibble order, FIFO wrap), so each is exercised directly:

| Suite         | What it proves                                              |
|---------------|-------------------------------------------------------------|
| `make uart`   | TX→RX loopback: every byte survives the 8N1 framing         |
| `make lcd`    | HD44780 init completes; a char clocks out high-then-low nibble |
| `make fifo`   | full/empty flags and FIFO ordering, incl. overflow guards    |
| `make soc`    | **end-to-end**: CPU runs `hello`, a real `uart_rx` decodes the `uart_tx` pin and reads back the greeting |

## Running everything

```bash
make all      # every suite above; the last lines are the RESULT: summaries
```

## What would come next

The natural next rung is running the **official `riscv-arch-test` compliance
suite** and formal checks with **`riscv-formal`** (SymbiYosys) — the two
industry-standard ways to prove ISA conformance beyond a project's own tests.
Both are external harnesses; see `docs/ROADMAP.md`.
