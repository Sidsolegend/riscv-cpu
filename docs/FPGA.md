# Running the CPU on real hardware (Tang Nano 9K)

Everything in this repo is verified in simulation, but the Verilog is
synthesizable and the design has been built to run on a **Sipeed Tang Nano 9K**
(Gowin GW1NR-9, ~$15). This is the guide for taking it from `make all` to a chip
that prints to your terminal and a character LCD.

## What's on the FPGA

`fpga/soc_tangnano9k.v` is the top level. It wires the single-cycle core to real
peripherals:

```
        +------------------ soc_tangnano9k ------------------+
 27 MHz | por -> rst                                          |
 osc -->|                +----------+   io_uart_we/byte       |
        |   riscv_single |  CPU     |----------------+        |
 btn -->|                +----------+                v        |
        |                     |            [ FIFO ] -> uart_tx |--> USB-serial -> your PC
        |                     | io_lcd_we/byte                 |
        |                     +----------> [ FIFO ] -> lcd_hd44780 |--> 16x2 LCD
        |                                                    LEDs |--> heartbeat + halt
        +----------------------------------------------------+
```

- **UART** — a store to `0x10000000` streams a byte out `uart_tx_pin` (8N1) to
  the on-board USB-serial bridge, so it appears in a terminal on your computer
  over the same USB cable that programs the board. A 512-byte FIFO absorbs
  bursts so the existing (non-polling) demo programs print correctly.
- **LCD** — a store to `0x1000000C` sends a byte to an HD44780 16x2 character
  LCD on the GPIO header (`fpga/lcd_hd44780.v`, 4-bit mode, self-initializing).
- **LEDs** — a ~1 Hz heartbeat proves the clock is live; LED0 lights on HALT.

Every one of these blocks is simulated and self-checked (`make fpga-tests`),
including a full end-to-end test that runs `hello` on the CPU and decodes the
real `uart_tx` pin — so the board is very likely to work first try, modulo pins.

## Toolchain (free / open source)

```bash
# the OSS CAD Suite bundles yosys + nextpnr-himbaechel + apicula + openFPGALoader
# https://github.com/YosysHQ/oss-cad-suite-build  (download, add its bin/ to PATH)
```

## Bring-up order (do this, in order)

1. **Prove the toolchain and pin map first.** Before running the CPU, synthesize
   a trivial blink (a counter driving one LED). If it blinks, your flow and
   `.cst` are right. This isolates "toolchain/pins wrong" from "my RTL wrong."
2. **Elaborate the SoC** (no synth tools needed): `make fpga-lint`.
3. **Synthesize + flash** the CPU:
   ```bash
   make synth     # yosys -> nextpnr -> gowin_pack  => sim/soc.fs
   make prog      # openFPGALoader flashes sim/soc.fs
   ```
4. **Watch it run.** Open the board's serial port at 115200 baud:
   ```bash
   # macOS: the bridge shows up as /dev/tty.usbserial-*
   screen /dev/tty.usbserial-XXXX 115200
   ```
   You should see `HELLO FROM MY RISC-V CPU!` (change `PROG`/`DATA` in the top
   level or the `synth` rule to run a different program).

## Wiring the character LCD

The 16x2 LCD (the one from an Arduino kit works) connects in 4-bit mode:

| LCD pin        | Connect to                                    |
|----------------|-----------------------------------------------|
| VSS, RW, K     | GND                                            |
| VDD, A         | 5V (A = backlight anode, via ~220Ω)            |
| V0 (contrast)  | wiper of a 10kΩ pot between 5V and GND         |
| RS             | `lcd_rs`  (see `fpga/tangnano9k.cst`)          |
| E              | `lcd_e`                                        |
| D4..D7         | `lcd_db[0..3]`                                 |

The FPGA drives the control/data lines at 3.3V, which HD44780 panels read as
logic-high fine; power the panel itself from 5V. Verify the exact header pin
numbers in `tangnano9k.cst` against your board's silkscreen before wiring.

> The pin numbers for clock, button, LEDs and UART in `tangnano9k.cst` are the
> standard Tang Nano 9K assignments; the LCD pins are example GPIO — adjust to
> whichever free header pins you wire to.
