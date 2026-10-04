#!/usr/bin/env python3
"""Send a program to the CPU on the Tang Nano 9K over USB serial, no rebuild.

    python3 tools/load.py programs/fib.s          # assemble, send, show output
    python3 tools/load.py programs/fib.s --watch 0

The board must be running a bitstream with fpga/uart_loader.v in it (any
`make synth` build). The loader holds the CPU in reset, writes the program
into its memories, checks the checksum, replies, and lets it run from 0.
Packet format is documented at the top of fpga/uart_loader.v.

Needs pyserial (pip install pyserial).
"""
import argparse
import glob
import os
import subprocess
import sys
import time

IMEM_WORDS, DMEM_WORDS = 128, 64     # must match soc_tangnano9k.v
REPLIES = {b"K": "loaded, running", b"E": "rejected (bad checksum or too big)",
           b"T": "timed out mid-packet"}


def read_hex(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [int(tok, 16) for line in f for tok in line.split()]


def find_port():
    # the board's FTDI-style bridge shows up as two ports; the higher-numbered
    # one is the UART, the lower one is the JTAG programmer
    ports = sorted(glob.glob("/dev/cu.usbserial-*"))
    if not ports:
        sys.exit("no /dev/cu.usbserial-* found -- is the board plugged in?")
    return ports[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("program", help="programs/<name>.s (or the .hex it assembles to)")
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--watch", type=float, default=3.0,
                    help="seconds to print the program's output afterwards (0 = don't)")
    args = ap.parse_args()

    base, ext = os.path.splitext(args.program)
    if ext == ".s":
        here = os.path.dirname(os.path.abspath(__file__))
        subprocess.run([sys.executable, os.path.join(here, "asm.py"), args.program], check=True)
    text = read_hex(base + ".hex")
    data = read_hex(base + ".data.hex")
    if not text:
        sys.exit(f"{base}.hex is missing or empty")
    if len(text) > IMEM_WORDS or len(data) > DMEM_WORDS:
        sys.exit(f"program too big for the board: {len(text)}/{IMEM_WORDS} instructions, "
                 f"{len(data)}/{DMEM_WORDS} data words")

    def le32(w):
        return (w & 0xFFFFFFFF).to_bytes(4, "little")

    packet = (b"RVLD" + len(text).to_bytes(2, "little") + len(data).to_bytes(2, "little")
              + b"".join(le32(w) for w in text + data) + le32(sum(text + data)))

    try:
        import serial
    except ImportError:
        sys.exit("needs pyserial:  pip install pyserial")

    port = args.port or find_port()
    with serial.Serial(port, args.baud, timeout=0.1) as ser:
        time.sleep(0.05)
        ser.reset_input_buffer()            # drop whatever the old program printed
        ser.write(packet)
        ser.flush()

        reply, deadline = b"", time.time() + 2.0
        while not reply and time.time() < deadline:
            reply = ser.read(1)
        if not reply:
            sys.exit(f"no reply from the board on {port} -- is the loader in the bitstream?")
        print(f"{os.path.basename(base)}: {len(text)} instructions, {len(data)} data words "
              f"-> {REPLIES.get(reply, 'unexpected reply %r' % reply)}")
        if reply != b"K":
            sys.exit(1)

        end = time.time() + args.watch
        try:
            while time.time() < end:
                chunk = ser.read(256)
                if chunk:
                    sys.stdout.write(chunk.decode("ascii", "replace"))
                    sys.stdout.flush()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
