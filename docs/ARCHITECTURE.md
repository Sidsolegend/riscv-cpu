# Architecture

This doc explains how the two cores are built. Read it alongside the Verilog —
every block named here maps to a module file.

---

## 1. The single-cycle core

One instruction executes completely, start to finish, in a single clock cycle.
The data flows left to right through five logical steps (in the pipeline these
become five separate *stages* — here they're just five things that happen in
one cycle):

```
        +--------------------------- next PC logic ---------------------------+
        |                                                                     |
        v                                                                     |
   +--------+     +--------+     +----------+     +--------+     +----------+  |
   |  PC    |---->|  IMEM  |---->| DECODE + |---->|  ALU   |---->|  DMEM    |  |
   | (reg)  | pc  | (instr)|     | REGFILE  |     |        |     | (lw/sw)  |  |
   +--------+     +--------+     |  read    |     +--------+     +----------+  |
                                 |  IMM gen |          |             |        |
                                 |  CONTROL |          |            (load)    |
                                 +----------+          |             |        |
                                       |               v             v        |
                                       |          +--------------------+      |
                                       +--------->|  write-back MUX     |------+
                                                  | ALU / MEM / PC+4     | wb_data
                                                  +--------------------+
                                                            |
                                                            v
                                                     write into REGFILE (rd)
```

**What each module does** (all in `single_cycle/`):

| Module          | Role |
|-----------------|------|
| `defines.vh`    | Names for opcodes, ALU operations, result-source selects. |
| `imem.v`        | Holds the program; given the PC, returns the instruction. |
| `control.v`     | Looks at opcode/funct3/funct7 → sets every control switch. |
| `imm_gen.v`     | Extracts & sign-extends the constant baked into the instruction. |
| `regfile.v`     | The 32 registers. Reads are instant; writes land on the clock edge. |
| `alu.v`         | Does the arithmetic/logic, or computes a load/store address. |
| `dmem.v`        | Data memory for `lw`/`sw`. |
| `riscv_single.v`| Wires all of the above together + the next-PC logic. |

**Next-PC logic** decides where to go each cycle:
- normal: `PC + 4`
- taken branch / `jal`: `PC + immediate`
- `jalr`: `(rs1 + immediate)` with the low bit cleared

---

## 2. The 5-stage pipeline

Same datapath, but now cut into five stages separated by **pipeline registers**.
Five instructions are in flight at once, each one stage apart:

```
   IF          ID           EX            MEM          WB
 fetch      decode +      execute       data         write
 instr      reg read      (ALU)         memory       back to reg
   |           |            |             |            |
   |   [IF/ID] |   [ID/EX]  |  [EX/MEM]   |  [MEM/WB]  |
   +-----------+------------+-------------+------------+
       ^            ^            |   |          |
       |            |            |   |          |
       |    (load-use stall)     |   |   (forwarding paths)
       |            |            |   |          |
       +---- flush on taken -----+   +----------+---> back to EX operand muxes
             branch/jump (from EX)         (bypass values before write-back)
```

### The three hazard mechanisms

A pipeline is only correct if it handles **hazards** — situations where an
instruction needs something that isn't ready yet.

**(a) Data hazard → forwarding** (`forwarding_unit.v`)
```
add x1, x2, x3     # x1 computed in EX...
sub x4, x1, x5     # ...but sub needs x1 one cycle later, before it's written back
```
The value already exists in a pipeline register (EX/MEM or MEM/WB). The
forwarding unit detects the match and routes it straight to the ALU input,
skipping the register file. No stall needed.

**(b) Load-use hazard → stall** (`hazard_unit.v`)
```
lw  x1, 0(x2)      # x1 isn't known until the END of MEM
add x4, x1, x5     # needs x1 at the START of its EX — impossible to forward in time
```
The one case forwarding can't fix. The hazard unit freezes the pipeline for
exactly one cycle (a "bubble"), after which forwarding handles the rest.

**(c) Control hazard → flush**
```
beq x1, x2, target # we don't know if it's taken until EX
<next instr>       # already fetched, might be wrong-path
<next instr>       # already fetched, might be wrong-path
```
Branches (and jumps) resolve in **EX**. By then two younger instructions were
fetched. If the branch is taken, those two are squashed ("flushed" to bubbles)
and the PC is redirected to the target. Cost: 2 cycles per taken branch.

### Pipeline registers (the "conveyor belt")

| Register | Carries |
|----------|---------|
| `IF/ID`  | the fetched instruction + its PC |
| `ID/EX`  | control signals, register values, immediate, register indices |
| `EX/MEM` | ALU result, store data, control signals, destination register |
| `MEM/WB` | loaded data / ALU result, control signals, destination register |

Each clock edge, every register hands its contents to the next stage — that's
what moves instructions down the line.

---

## 3. Why the pipeline register file writes on the *negative* edge

This is subtle and worth understanding (it was a real bug — see
`LEARNING.md`). When one instruction is in **WB** writing register `xN`, a
younger instruction can be in **ID** reading `xN` *in the same cycle*.
Forwarding only bypasses into **EX**, not **ID**, so it doesn't help here.

Fix: the pipeline's register file (`regfile_pipe.v`) writes on the **negedge**
(middle of the cycle). So within one cycle: the write lands at the negedge, then
the ID read is sampled at the following posedge — and sees the fresh value.
"Write in the first half, read in the second half." The single-cycle core
doesn't have this problem (no overlapping instructions), so it keeps the simpler
posedge-write register file.
```
