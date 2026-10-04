# Running the CPU on real hardware (Tang Nano 9K)

The core runs on a **Sipeed Tang Nano 9K** (Gowin GW1NR-9, ~$15): `hello`,
`fib` and the trap/interrupt test all print the same output on the real chip
as in simulation, down to `fib`'s cycle count, and the `screen` program puts
its text on a TV over the board's HDMI port. This is the guide for taking it
from `make all` to there.

## What's on the FPGA

`fpga/soc_tangnano9k.v` is the top level. It wires the single-cycle core to real
peripherals:

```
        +------------------ soc_tangnano9k ------------------+
 27 MHz | PLL 126 / 25.2 / 12.6 MHz, por -> rst                |
 osc -->|                +----------+   io_uart_we/byte       |
        |   riscv_single |  CPU     |----------------+        |
 btn -->|                +----------+                v        |
        |                     |            [ FIFO ] -> uart_tx |--> USB-serial -> your PC
        |                     | io_lcd_we/byte                 |
        |                     +----------> [ FIFO ] -> hdmi_term |--> HDMI port -> TV
        |                                                    LEDs |--> heartbeat + progress
        +----------------------------------------------------+
```

- **UART** — a store to `0x10000000` streams a byte out `uart_tx_pin` (8N1) to
  the on-board USB-serial bridge, so it appears in a terminal on your computer
  over the same USB cable that programs the board. A 512-byte FIFO absorbs
  bursts so the existing (non-polling) demo programs print correctly.
- **HDMI** — a store to `0x1000000C` prints a character on a TV or monitor
  (`fpga/hdmi_term.v`): 640x480 @ 60 Hz, DVI signalling, a 40x15 grid of
  big white-on-black characters (an 8x16 font drawn at 2x; `SCALE=1` gives
  80x30). `\n` starts a new line; at the bottom the screen clears and
  printing restarts at the top. `programs/screen.s` prints to both the
  terminal and the TV.
- **LEDs** — show how far a printed character got, which is the first thing
  to look at when the terminal stays silent:

  | LED | Meaning |
  |-----|---------|
  | 5 | ~1 Hz heartbeat (free-running, blinks even if the CPU is stuck) |
  | 4 | CPU out of reset |
  | 3 | the UART transmitter has started (sticky) |
  | 2 | the UART FIFO has held a byte (sticky) |
  | 1 | the CPU has done a UART store (sticky) |
  | 0 | the program reached its HALT store |

Every one of these blocks is simulated and self-checked (`make fpga-tests`),
including a full end-to-end test that runs `hello` on the CPU and decodes the
real `uart_tx` pin.

## Toolchain (free / open source)

```bash
# the OSS CAD Suite bundles yosys + nextpnr-himbaechel + apicula + openFPGALoader
# https://github.com/YosysHQ/oss-cad-suite-build  (download, add its bin/ to PATH)
export PATH=$HOME/tools/oss-cad-suite/bin:$PATH
```

## What `make synth` actually produces

Last run (Yosys 0.69, nextpnr 0.11): **about 79% of the chip's LUT4s, 19%
of its flip-flops, 4 of 26 block RAMs, one hard multiplier and one PLL**.
Getting it to build, and then to actually work on the chip, needed several
things that simulation alone never shows:

- **12.6 MHz, not 27.** At the crystal's 27 MHz the chip printed
  `HELLO FROM MY RISC-V CPU#`: the `!` loaded from data memory came back
  with bit 1 flipped, the same way on every run. nextpnr said the design
  was good to ~32 MHz, but its reported critical path ends at the data
  memory's write enable. It has no timing for *reading* the LUT-RAM, so the
  core's real longest path (a load: instruction ROM, register file, address
  add, data LUT-RAM read, register write) is invisible to it. The CPU now
  runs at 12.6 MHz from the PLL, and every run since has been correct.
  Don't trust nextpnr's Fmax for this core; if you raise the clock, check
  loads on the real chip.
- **One PLL, three clocks.** 126 MHz (27 x 14/3) drives the HDMI
  serializers (`OSER10`, 10 bits per pixel), a `CLKDIV` /5 makes the
  25.2 MHz pixel clock, and the PLL's divided output (/10) is the 12.6 MHz
  CPU clock. The CPU side and the video side only meet in the terminal's
  dual-clock character RAM.
- **No zero-fill in synthesis.** `imem.v` / `dmem.v` zero their arrays and
  then `$readmemh` the program. Simulation does those in order, but Yosys
  let the zero-fill win, so the first bitstream held an all-zero program and
  the CPU just trapped forever. The zero-fill is now `` `ifndef SYNTHESIS ``.
- **No combinational divider.** The ALU's four 32-bit dividers were bigger
  than the whole chip (133% of LUTs on their own). The SoC runs the core with
  `SEQ_DIV=1`: div/rem stall the PC and run in the one-bit-per-cycle
  `muldiv_seq.v` (about 35 cycles each). Same results; `make seqdiv` checks
  the M-extension test, `fib`, and the pipeline-vs-single-cycle diff on it.
  The plain sim cores keep the combinational divider.
- **Smaller memories.** The SoC core has 128 instruction words and 64 data
  words (parameters `IMEM_WORDS` / `DMEM_WORDS`); the demos need less. A
  program bigger than that will silently wrap around, so raise them if you
  load something large and the chip has room.
- **Block-RAM FIFOs.** `fifo.v` reads synchronously, so it maps to block RAM
  (an asynchronous-read FIFO this size became LUT-RAM the placer couldn't
  place).
- **Yosys flags.** `read_verilog -defer` (so `$readmemh` sees the real file
  paths), and `bufnorm -conn` before writing the netlist (this Yosys leaves a
  `$buf` cell nextpnr can't place). The simulation-only console echo in
  `dmem.v` is behind `` `ifndef SYNTHESIS ``.

## Bring-up order (do this, in order)

`make prog*` loads the chip's SRAM: it runs immediately and is gone when you
unplug the board, so nothing here is permanent.

1. **`make prog-blink`** — LEDs count in binary. Proves the toolchain, the
   clock pin and the LED pins with no CPU involved.
2. **`make prog-uart`** — sends `HELLO` once a second from the bare UART, no
   CPU. Proves the serial pin and port. (The first byte after a quiet second
   is sometimes dropped by the USB bridge.)
3. **Synthesize + load the CPU:**
   ```bash
   make synth                 # => sim/soc.fs, running programs/hello.s
   make synth PROGRAM=fib     # or any programs/<name>.s
   make prog                  # into the chip's SRAM (gone when unplugged)
   make flash                 # or into its flash (boots on every power-up)
   ```
4. **Watch it run.** For the TV, `make synth PROGRAM=screen` and plug HDMI
   in. **Plug USB in before HDMI, and unplug HDMI before USB.** The TV puts
   a little voltage on the HDMI cable, and with USB out that can half-power
   the board and wedge its USB chip, so the Mac stops seeing it. If that
   happens, unplug both for ten seconds and plug USB in first.

   For the serial terminal: the board shows up as two serial ports. The lower
   number (`/dev/cu.usbserial-100` here) is the programmer, so leave it
   alone; the higher one is the UART:
   ```bash
   screen /dev/cu.usbserial-101 115200
   ```
   `hello` prints once at power-up, so open the terminal first and then run
   `make prog` (or press S1, the reset button) to see it.

## Running a different program without rebuilding

Every bitstream includes `fpga/uart_loader.v`, so once the board is running
you can send it any program over the same USB cable in about a second:

```bash
make load PROGRAM=fib          # or: python3 tools/load.py programs/fib.s
```

`tools/load.py` assembles the program, sends it, and prints the board's
reply and then the program's output for a few seconds. The loader holds the
CPU in reset while it writes the program into instruction and data memory,
zeroes whatever is left of both, checks a checksum, and then lets the CPU
run from address 0 (with the HDMI screen cleared). Programs must fit in 128
instructions and 64 data words. A bad checksum or a sender that stops
halfway leaves the CPU stopped instead of running half a program; just send
it again. `make loader` tests all of this on the simulated SoC, including a
real bug it caught: the loader used to drop a byte when a short program
made its zero-fill take longer than one byte's arrival time.

Unplugging the board brings back whatever program the bitstream was built
with.

## HDMI text terminal

`hdmi_term.v` is plain Verilog with no Gowin primitives inside: it outputs
three 10-bit TMDS symbols per pixel, and only the top level serializes them
(`OSER10` + `ELVDS_OBUF`). That's what makes `make hdmi` possible: the test
decodes the symbol streams with its own DVI decoder and checks a TV's view
of the signal: frame geometry (640x480 active, 800x525 total, porches and
sync widths, vsync edges on hsync edges), DC balance, and every pixel of a
whole frame against the font, after writes that exercise newline, CR, line
wrap and end-of-screen clear. It was also run against deliberately broken
copies (pixel shifted by one, sync pulse one pixel long, vsync on the wrong
edge, DC balance off) and caught each one.

Pins (69/68 clock, 71/70, 73/72, 75/74 data, as `LVDS25E`) come from
apicula's own `tangnano9k.cst`, which matches Sipeed's HDMI example.

## The SPI screen (not in the SoC)

Buy the variant with the **SPI interface** connector (not the RGB one, which
is a parallel-RGB panel and needs a different driver). `st7789_term.v` sends
the init sequence itself (reset, sleep-out, RGB565, landscape, inversion on,
display on), clears the screen, then draws each character straight into a
6x12 window, so there is no framebuffer.

**Pins.** The screen plugs into the board's own screen connector, so the
pins are fixed: SCLK 76, MOSI 77, DC 49, CS 48, RESET 47, taken from Sipeed's
TangNano-9K-example `spi_lcd` project. There's no backlight pin; it's
always on. The SoC uses HDMI instead now; to use this screen, swap
`hdmi_term` for `st7789_term` in `soc_tangnano9k.v` and put those pins back
in the `.cst`.

The driver is verified in simulation only (`make st7789`: init bytes, clear,
every pixel of a drawn character against the font, newline, wrap), not on a
real panel. If it comes up blank, check in this order: pins, that BLK is
high, then the panel offset. If a one-pixel line of noise shows along an
edge, adjust `OFF_X` / `OFF_Y` in `st7789_term.v` (40 / 53 is the common
value for this module in landscape, and what Sipeed's example uses). If
colors look inverted, remove the
`INVON` (0x21) entry from the init ROM. To try another font, regenerate it
with `python3 tools/genfont.py > fpga/font6x12.hex`.

The 16x2 HD44780 driver (`fpga/lcd_hd44780.v`, with `make lcd`) is still in
the repo as an alternative, but the SoC no longer instantiates it.
