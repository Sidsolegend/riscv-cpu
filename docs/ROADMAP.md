# Roadmap — what's built, and what's next

This project grew from two working cores into a small system. This file tracks
where each capability stands, including the verified building blocks that are
ready to wire into the datapath.

## Done and tested (runs under `make all`)

- **Two cores** — single-cycle and 5-stage pipeline (forwarding, load-use stall,
  branch flush), proven equivalent by `make diff`.
- **RV32IM** — base integer + M extension on both cores.
- **Zicsr + machine-mode traps** (single-cycle) — `ecall`, `ebreak`, illegal
  instruction, `mret`, the machine CSRs, and a **timer interrupt**
  (`single_cycle/csr.v`). Demoed by `programs/traps.s`.
- **Memory-mapped I/O** — UART, cycle timer, HALT, and an LCD device.
- **FPGA SoC** — `fpga/soc_tangnano9k.v`: the core plus a real UART transmitter,
  an HDMI text terminal, a power-on reset and FIFOs, all self-checked, with a
  full end-to-end SoC test. See `docs/FPGA.md`.
- **Assembler** — RV32IM + Zicsr + pseudo-ops + `.data` and raw `.word` in
  `.text` (`tools/asm.py`).
- **C toolchain path** — `sw/`: compile C with riscv-gcc, run on the core.

## Built and verified as modules — ready to integrate

These are complete, tested RTL blocks. Each is proven correct on its own; the
remaining work is wiring it into a core's datapath (the interesting part).

- **Sequential mul/div** (`common/muldiv_seq.v`) — bit-serial shift-add /
  restoring-division with a busy/done handshake, matching the ALU on 2000+
  cases (`make muldiv`). *Integrate:* replace the combinational M-ops in EX with
  this unit and stall the pipeline while `busy` — the realistic model, since a
  32-bit divide can't complete in one fast cycle.
- **Branch predictor** (`common/branch_predictor.v`) — 2-bit saturating BHT +
  BTB (`make bpred`). *Integrate:* predict in IF, redirect fetch on a predicted-
  taken hit, compare against the EX resolution, and recover on a misprediction.
  Removes the 2-cycle flush on the common (loop) branch.
- **RVC decompressor** (`common/rvc_decompress.v`) — expands the RV32C set to
  32-bit, checked against assembler goldens (`make rvc`). *Integrate:* let the
  PC step by 2, buffer 16-bit halves, and feed aligned instructions through the
  decompressor before decode.

## Next stretch goals

- **Run it on the Tang Nano 9K** — synthesize `soc_tangnano9k` and watch a
  program print over USB-serial and on the LCD (`docs/FPGA.md`).
- **Official compliance** — the `riscv-arch-test` suite, the standard proof of
  ISA conformance.
- **Formal verification** — `riscv-formal` (SymbiYosys) to prove properties like
  "every instruction retires per spec," beyond test coverage.
- **Bring the pipeline up to feature parity** — port the CSR/trap support from
  the single-cycle core into the 5-stage pipeline (traps in a pipeline need
  precise-exception handling: flush younger instructions, take the trap on the
  oldest — a good exercise).
- **Caches** — a small direct-mapped I/D cache once memory is unified, then
  measure hit rate on a real program.
