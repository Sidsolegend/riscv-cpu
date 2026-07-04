#!/usr/bin/env python3
"""
bin2hex.py — convert a raw binary section image into the $readmemh word format
the cores load (one little-endian 32-bit word per line).

    python3 tools/bin2hex.py section.bin > section.hex

Used by the C build flow (sw/): the RISC-V GCC toolchain produces an ELF, then
`objcopy -O binary` dumps the .text and .data sections to raw .bin files, and
this turns each into the hex image imem/dmem read with $readmemh. The core uses
separate instruction and data memories, so .text and .data are converted
independently — see sw/link.ld and sw/README.md.
"""
import sys


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    # pad up to a 4-byte boundary so the last word is complete
    if len(data) % 4:
        data += bytes(4 - len(data) % 4)
    for i in range(0, len(data), 4):
        word = int.from_bytes(data[i:i + 4], "little")
        print(f"{word:08x}")


if __name__ == "__main__":
    main()
