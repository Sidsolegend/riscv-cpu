# ============================================================================
#  Makefile — build & simulate the RISC-V cores with Icarus Verilog
# ----------------------------------------------------------------------------
#  Usage (run these from THIS folder):
#     make single     # build + run the single-cycle core
#     make pipeline   # build + run the 5-stage pipelined core
#     make hazard     # build + run the pipeline hazard stress test
#     make watch      # WATCH the single-cycle CPU execute, cycle by cycle
#     make all        # run all three tests (not watch)
#     make waves-pipeline   # open the pipeline waveform in GTKWave (if installed)
#     make clean      # delete generated files (sim/*.vvp, sim/*.vcd)
#
#  NOTE: install the toolchain first (once):  brew install icarus-verilog
#        (waveform viewing also needs:         brew install --cask gtkwave )
# ============================================================================

IVERILOG = iverilog
VVP      = vvp
IVFLAGS  = -g2012 -I single_cycle -I pipelined

# Generic leaf modules shared by both cores.
LEAF     = single_cycle/alu.v single_cycle/imm_gen.v single_cycle/control.v \
           single_cycle/imem.v single_cycle/dmem.v

# The single-cycle core uses the plain (posedge-write) register file, plus the
# CSR / trap-handling unit (Zicsr + machine-mode traps and the timer interrupt).
SC_SRC   = $(LEAF) single_cycle/regfile.v single_cycle/csr.v \
           single_cycle/riscv_single.v

# The pipeline uses the negedge-write register file + hazard/forwarding units.
PIPE_SRC = $(LEAF) pipelined/regfile_pipe.v pipelined/forwarding_unit.v \
           pipelined/hazard_unit.v pipelined/riscv_pipeline.v

.PHONY: all single pipeline hazard watch clean waves-pipeline waves-single \
        asm mext memops hello hello-pipe fib fib-pipe apps traps \
        muldiv bpred rvc diff fpga-tests uart lcd fifo soc fpga-lint synth prog

all: single pipeline hazard mext memops apps traps diff \
     muldiv bpred rvc fpga-tests

# Shared new library modules and FPGA peripheral RTL.
COMMON   = common/muldiv_seq.v common/branch_predictor.v common/rvc_decompress.v
FPGA_RTL = fpga/uart_tx.v fpga/uart_rx.v fpga/lcd_hd44780.v fpga/fifo.v fpga/por.v

# ---- Zicsr + machine-mode traps / timer interrupt (single-cycle core) -------
traps: asm | sim
	$(IVERILOG) $(IVFLAGS) -DPROG_HEX='"programs/traps.hex"' \
	    -DDATA_HEX='"programs/traps.data.hex"' -o sim/traps.vvp $(SC_SRC) tests/tb_run.v
	$(VVP) sim/traps.vvp

# ---- single-cycle vs pipeline equivalence (a deterministic program) ---------
#  SC_SRC already carries the shared leaf modules; add only the pipeline-only
#  files so nothing is declared twice.
PIPE_ONLY = pipelined/regfile_pipe.v pipelined/forwarding_unit.v \
            pipelined/hazard_unit.v pipelined/riscv_pipeline.v
diff: asm | sim
	$(IVERILOG) $(IVFLAGS) -DPROG_HEX='"programs/difftest.hex"' \
	    -DDATA_HEX='"programs/difftest.data.hex"' -o sim/diff.vvp \
	    $(SC_SRC) $(PIPE_ONLY) tests/tb_diff.v
	$(VVP) sim/diff.vvp

# ---- verified library modules (sequential mul/div, predictor, RVC) ----------
muldiv: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/muldiv.vvp common/muldiv_seq.v single_cycle/alu.v tests/tb_muldiv.v
	$(VVP) sim/muldiv.vvp

bpred: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/bpred.vvp common/branch_predictor.v tests/tb_bpred.v
	$(VVP) sim/bpred.vvp

rvc: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/rvc.vvp common/rvc_decompress.v tests/tb_rvc.v
	$(VVP) sim/rvc.vvp

# ---- FPGA peripherals + full SoC (all simulated end-to-end) ------------------
fpga-tests: uart lcd fifo soc

uart: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/uart.vvp fpga/uart_tx.v fpga/uart_rx.v tests/tb_uart.v
	$(VVP) sim/uart.vvp

lcd: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/lcd.vvp fpga/lcd_hd44780.v tests/tb_lcd.v
	$(VVP) sim/lcd.vvp

fifo: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/fifo.vvp fpga/fifo.v tests/tb_fifo.v
	$(VVP) sim/fifo.vvp

# End-to-end: run hello on the CPU and decode the REAL uart_tx pin.
# (FPGA_RTL already includes uart_rx, used here as the decoding monitor.)
soc: asm | sim
	$(IVERILOG) $(IVFLAGS) -o sim/soc.vvp $(FPGA_RTL) \
	    fpga/soc_tangnano9k.v $(SC_SRC) tests/tb_soc.v
	$(VVP) sim/soc.vvp

# ---- FPGA synthesis flow (Yosys + nextpnr-apicula for the Tang Nano 9K) ------
#  Requires: yosys, nextpnr-himbaechel (apicula), gowin_pack, openFPGALoader.
#  Install on macOS with the OSS CAD Suite. `make synth` builds a bitstream;
#  `make prog` flashes it. `make fpga-lint` just elaborates the SoC with iverilog
#  (no synthesis tools needed) to catch wiring errors early.
GW_DEVICE = GW1NR-LV9QN88PC6/I5
GW_FAMILY = GW1N-9C

fpga-lint: asm
	$(IVERILOG) $(IVFLAGS) -o sim/soc_lint.vvp $(FPGA_RTL) \
	    fpga/soc_tangnano9k.v $(SC_SRC)
	@echo "FPGA SoC elaborates cleanly."

synth: asm
	yosys -p "read_verilog -I single_cycle $(FPGA_RTL) fpga/soc_tangnano9k.v $(SC_SRC); \
	          synth_gowin -top soc_tangnano9k -json sim/soc.json"
	nextpnr-himbaechel --json sim/soc.json --write sim/soc_pnr.json \
	    --device $(GW_DEVICE) --vopt family=$(GW_FAMILY) --vopt cst=fpga/tangnano9k.cst
	gowin_pack -d $(GW_FAMILY) -o sim/soc.fs sim/soc_pnr.json
	@echo "Bitstream: sim/soc.fs  (flash with: make prog)"

prog:
	openFPGALoader -b tangnano9k sim/soc.fs

# ---- compile C to the core (needs a riscv32 bare-metal GCC) ------------------
#  Override the compiler if yours is named differently, e.g.
#     make cprog RISCV_GCC=riscv-none-elf-gcc
RISCV_GCC     ?= riscv64-unknown-elf-gcc
RISCV_OBJCOPY ?= $(subst gcc,objcopy,$(RISCV_GCC))
CFLAGS_BARE    = -march=rv32im -mabi=ilp32 -Os -ffreestanding -nostdlib -nostartfiles -Wall

cprog: | sim
	$(RISCV_GCC) $(CFLAGS_BARE) -T sw/link.ld sw/crt0.s sw/hello.c -o sim/hello_c.elf
	$(RISCV_OBJCOPY) -O binary -j .text                       sim/hello_c.elf sim/hello_c.text.bin
	$(RISCV_OBJCOPY) -O binary -j .rodata -j .data            sim/hello_c.elf sim/hello_c.data.bin
	python3 tools/bin2hex.py sim/hello_c.text.bin > sim/hello_c.hex
	python3 tools/bin2hex.py sim/hello_c.data.bin > sim/hello_c.data.hex
	@echo "Built sim/hello_c.hex (+ .data.hex) from C."

cprog-run: cprog
	$(IVERILOG) $(IVFLAGS) -DPROG_HEX='"sim/hello_c.hex"' \
	    -DDATA_HEX='"sim/hello_c.data.hex"' -o sim/hello_c.vvp $(SC_SRC) tests/tb_run.v
	$(VVP) sim/hello_c.vvp

# ---- assemble every program written in assembly (tools/asm.py) -------------
ASM_SRCS := $(wildcard programs/*.s)
asm:
	@for s in $(ASM_SRCS); do python3 tools/asm.py $$s; done

# ---- new-instruction tests: each runs on BOTH cores -------------------------
mext: asm | sim
	$(IVERILOG) $(IVFLAGS) -o sim/mext_sc.vvp   $(SC_SRC)   tests/tb_mext.v
	$(VVP) sim/mext_sc.vvp
	$(IVERILOG) $(IVFLAGS) -DUSE_PIPE -o sim/mext_pipe.vvp $(PIPE_SRC) tests/tb_mext.v
	$(VVP) sim/mext_pipe.vvp

memops: asm | sim
	$(IVERILOG) $(IVFLAGS) -o sim/memops_sc.vvp   $(SC_SRC)   tests/tb_memops.v
	$(VVP) sim/memops_sc.vvp
	$(IVERILOG) $(IVFLAGS) -DUSE_PIPE -o sim/memops_pipe.vvp $(PIPE_SRC) tests/tb_memops.v
	$(VVP) sim/memops_pipe.vvp

# ---- demo applications (they PRINT via the memory-mapped UART) --------------
hello: asm | sim
	$(IVERILOG) $(IVFLAGS) -DPROG_HEX='"programs/hello.hex"' \
	    -DDATA_HEX='"programs/hello.data.hex"' -o sim/hello.vvp $(SC_SRC) tests/tb_run.v
	$(VVP) sim/hello.vvp

hello-pipe: asm | sim
	$(IVERILOG) $(IVFLAGS) -DUSE_PIPE -DPROG_HEX='"programs/hello.hex"' \
	    -DDATA_HEX='"programs/hello.data.hex"' -o sim/hello_pipe.vvp $(PIPE_SRC) tests/tb_run.v
	$(VVP) sim/hello_pipe.vvp

fib: asm | sim
	$(IVERILOG) $(IVFLAGS) -DPROG_HEX='"programs/fib.hex"' \
	    -DDATA_HEX='"programs/fib.data.hex"' -o sim/fib.vvp $(SC_SRC) tests/tb_run.v
	$(VVP) sim/fib.vvp

fib-pipe: asm | sim
	$(IVERILOG) $(IVFLAGS) -DUSE_PIPE -DPROG_HEX='"programs/fib.hex"' \
	    -DDATA_HEX='"programs/fib.data.hex"' -o sim/fib_pipe.vvp $(PIPE_SRC) tests/tb_run.v
	$(VVP) sim/fib_pipe.vvp

apps: hello hello-pipe fib fib-pipe

single: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/single.vvp $(SC_SRC) single_cycle/tb_single.v
	$(VVP) sim/single.vvp

pipeline: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/pipeline.vvp $(PIPE_SRC) pipelined/tb_pipeline.v
	$(VVP) sim/pipeline.vvp

hazard: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/hazard.vvp $(PIPE_SRC) pipelined/tb_hazard.v
	$(VVP) sim/hazard.vvp

# Prints every cycle: PC, raw instruction, decoded assembly, live register
# values. This is the "watch the CPU actually run" view (no GUI needed).
watch: | sim
	$(IVERILOG) $(IVFLAGS) -o sim/watch.vvp $(SC_SRC) single_cycle/tb_watch.v
	$(VVP) sim/watch.vvp

# Open waveforms (needs gtkwave). Run the matching sim first.
waves-pipeline:
	gtkwave sim/pipeline.vcd

waves-single:
	gtkwave sim/single.vcd

sim:
	mkdir -p sim

clean:
	rm -f sim/*.vvp sim/*.vcd
