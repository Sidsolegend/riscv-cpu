#!/usr/bin/env python3
"""
asm.py — a small two-pass RV32IM assembler for the riscv-cpu project.

Turns human-readable assembly (programs/*.s) into the hex images the cores
load with $readmemh:

    python3 tools/asm.py programs/hello.s
        -> programs/hello.hex          (.text  -> instruction memory)
        -> programs/hello.data.hex     (.data  -> data memory, if any)

Why it exists: without a toolchain you hand-encode 32-bit instructions one
bit-field at a time. With it, the CPU becomes a real target you can write
applications for. It supports every instruction the cores implement
(RV32I + the M extension), labels, a .data section, and the usual pseudo
instructions (li / la / mv / j / call / ret / beqz / ...).

Syntax (one instruction or directive per line):
    label:            define a label (text: byte address of next instr;
                      data: byte address of next datum)
    .text / .data     switch section (text is the default)
    .word  v, v, ...  32-bit values in .data (labels allowed)
    .half  v, ...     16-bit values
    .byte  v, ...     8-bit values
    .asciz "str"      NUL-terminated string (\\n \\t \\0 \\\\ \\" escapes)
    .space n          n zero bytes
    .equ NAME, value  define a constant
    # or //           comment to end of line

Built-in constants (the memory-mapped devices in dmem.v):
    UART = 0x10000000   CYCLES = 0x10000004   HALT = 0x10000008
"""
import re
import sys
import os

# ---------------------------------------------------------------------------
#  Register names
# ---------------------------------------------------------------------------
ABI = {'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
       't0': 5, 't1': 6, 't2': 7, 's0': 8, 'fp': 8, 's1': 9,
       'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15,
       'a6': 16, 'a7': 17, 's2': 18, 's3': 19, 's4': 20, 's5': 21,
       's6': 22, 's7': 23, 's8': 24, 's9': 25, 's10': 26, 's11': 27,
       't3': 28, 't4': 29, 't5': 30, 't6': 31}


def reg(tok):
    t = tok.strip().lower()
    if t in ABI:
        return ABI[t]
    if t.startswith('x') and t[1:].isdigit() and 0 <= int(t[1:]) <= 31:
        return int(t[1:])
    raise ValueError(f"not a register: {tok!r}")


# ---------------------------------------------------------------------------
#  Instruction encoders (the five RV32 formats)
# ---------------------------------------------------------------------------
def enc_r(f7, rs2, rs1, f3, rd, opc):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def enc_i(imm, rs1, f3, rd, opc):
    if not -2048 <= imm <= 2047:
        raise ValueError(f"I-imm out of range: {imm}")
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def enc_s(imm, rs2, rs1, f3, opc):
    if not -2048 <= imm <= 2047:
        raise ValueError(f"S-imm out of range: {imm}")
    i = imm & 0xFFF
    return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((i & 0x1F) << 7) | opc


def enc_b(imm, rs2, rs1, f3, opc):
    if imm % 2 or not -4096 <= imm <= 4094:
        raise ValueError(f"branch offset out of range/odd: {imm}")
    i = imm & 0x1FFF
    return (((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | (rs2 << 20) | \
           (rs1 << 15) | (f3 << 12) | (((i >> 1) & 0xF) << 8) | (((i >> 11) & 1) << 7) | opc


def enc_u(imm, rd, opc):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | opc


def enc_j(imm, rd, opc=0x6F):
    if imm % 2 or not -(1 << 20) <= imm <= (1 << 20) - 2:
        raise ValueError(f"jal offset out of range/odd: {imm}")
    i = imm & 0x1FFFFF
    return (((i >> 20) & 1) << 31) | (((i >> 1) & 0x3FF) << 21) | (((i >> 11) & 1) << 20) | \
           (((i >> 12) & 0xFF) << 12) | (rd << 7) | opc


def enc_csr(csr, rs1_or_imm, f3, rd):
    # SYSTEM / Zicsr uses the I-type layout: csr[11:0] in [31:20], the rs1 field
    # (a register, or a 5-bit zero-extended immediate) in [19:15].
    if not 0 <= csr <= 0xFFF:
        raise ValueError(f"CSR address out of range: {csr:#x}")
    return ((csr & 0xFFF) << 20) | ((rs1_or_imm & 0x1F) << 15) | (f3 << 12) | (rd << 7) | 0x73


R_OPS = {  # name: (funct7, funct3)
    'add': (0x00, 0), 'sub': (0x20, 0), 'sll': (0x00, 1), 'slt': (0x00, 2),
    'sltu': (0x00, 3), 'xor': (0x00, 4), 'srl': (0x00, 5), 'sra': (0x20, 5),
    'or': (0x00, 6), 'and': (0x00, 7),
    # M extension: funct7 = 0000001
    'mul': (0x01, 0), 'mulh': (0x01, 1), 'mulhsu': (0x01, 2), 'mulhu': (0x01, 3),
    'div': (0x01, 4), 'divu': (0x01, 5), 'rem': (0x01, 6), 'remu': (0x01, 7),
}
I_OPS = {'addi': 0, 'slti': 2, 'sltiu': 3, 'xori': 4, 'ori': 6, 'andi': 7}
SHIFT_OPS = {'slli': (0x00, 1), 'srli': (0x00, 5), 'srai': (0x20, 5)}
LOADS = {'lb': 0, 'lh': 1, 'lw': 2, 'lbu': 4, 'lhu': 5}
STORES = {'sb': 0, 'sh': 1, 'sw': 2}
BRANCHES = {'beq': 0, 'bne': 1, 'blt': 4, 'bge': 5, 'bltu': 6, 'bgeu': 7}

# Zicsr: csrrw/csrrs/csrrc + the immediate forms (funct3).
CSR_OPS = {'csrrw': 1, 'csrrs': 2, 'csrrc': 3,
           'csrrwi': 5, 'csrrsi': 6, 'csrrci': 7}
CSR_IMM = {'csrrwi', 'csrrsi', 'csrrci'}    # 3rd operand is a 5-bit immediate

# SYSTEM / privileged instructions with a fixed 32-bit encoding.
SYSTEM_FIXED = {
    'ecall':   0x00000073, 'ebreak':  0x00100073,
    'mret':    0x30200073, 'wfi':     0x10500073,
    'fence':   0x0ff0000f, 'fence.i': 0x0000100f,
}

# CSR names -> address (the machine-mode subset this core implements).
CSR_NAMES = {
    'mstatus': 0x300, 'misa': 0x301, 'mie': 0x304, 'mtvec': 0x305,
    'mscratch': 0x340, 'mepc': 0x341, 'mcause': 0x342, 'mtval': 0x343,
    'mip': 0x344, 'mcycle': 0xB00, 'minstret': 0xB02,
    'mtimecmp': 0x7C0,                       # custom: machine-timer compare
    'cycle': 0xC00, 'time': 0xC01, 'instret': 0xC02,
    'mvendorid': 0xF11, 'marchid': 0xF12, 'mimpid': 0xF13, 'mhartid': 0xF14,
}

BUILTINS = {'UART': 0x10000000, 'CYCLES': 0x10000004, 'HALT': 0x10000008,
            'LCD': 0x1000000C}


# ---------------------------------------------------------------------------
#  Parsing helpers
# ---------------------------------------------------------------------------
def strip_comment(line):
    out, in_str = [], False
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != '\\'):
            in_str = not in_str
        if not in_str:
            if c == '#' or line[i:i + 2] == '//':
                break
        out.append(c)
        i += 1
    return ''.join(out).strip()


def unescape(s):
    return (s.replace('\\n', '\n').replace('\\t', '\t')
             .replace('\\0', '\0').replace('\\"', '"').replace('\\\\', '\\'))


MEM_RE = re.compile(r'^(-?\w+)\s*\(\s*(\w+)\s*\)$')   # imm(rs1)


class Assembler:
    def __init__(self):
        self.symbols = dict(BUILTINS)
        self.text = []      # list of (mnemonic, operands, line_no, source)
        self.data = bytearray()
        self.errors = []

    # -- immediate / symbol evaluation (pass 2 only for labels) -------------
    def value(self, tok, resolve=True):
        t = tok.strip()
        m = re.fullmatch(r"'(\\.|[^\\'])'", t)     # char literal, incl. '\n' etc
        if m:
            return ord(unescape(m.group(1)))
        try:
            return int(t, 0)
        except ValueError:
            pass
        if t in self.symbols:
            return self.symbols[t]
        if not resolve:
            return 0
        raise ValueError(f"undefined symbol: {t!r}")

    # -- resolve a CSR operand: a name (mstatus, mtvec, ...) or a raw number ---
    def csr_value(self, tok):
        t = tok.strip().lower()
        if t in CSR_NAMES:
            return CSR_NAMES[t]
        return self.value(tok)

    # -- how many instruction words does a (pseudo) instruction occupy? -----
    #  MUST agree with expand(): pass 1 uses this to place labels, so if the
    #  two disagreed every later label would shift. Rule: `la` and any li of
    #  a symbol/label are always 2 words; li of a small numeric literal is 1.
    def width(self, op, args):
        if op == 'la':
            return 2
        if op == 'li':
            t = args[1].strip()
            if re.fullmatch(r"-?(0x[0-9a-fA-F]+|\d+)", t) or \
               (len(t) == 3 and t[0] == "'" and t[2] == "'"):
                v = self.value(t)
                return 1 if -2048 <= v <= 2047 else 2
            return 2                        # symbol / label -> lui+addi
        return 1

    # -- pseudo-instruction expansion (returns list of real instructions) ---
    def expand(self, op, a):
        if op == 'nop':
            return [('addi', ['x0', 'x0', '0'])]
        if op == 'mv':
            return [('addi', [a[0], a[1], '0'])]
        if op == 'not':
            return [('xori', [a[0], a[1], '-1'])]
        if op == 'neg':
            return [('sub', [a[0], 'x0', a[1]])]
        if op == 'seqz':
            return [('sltiu', [a[0], a[1], '1'])]
        if op == 'snez':
            return [('sltu', [a[0], 'x0', a[1]])]
        if op == 'j':
            return [('jal', ['x0', a[0]])]
        if op == 'jr':
            return [('jalr', ['x0', a[0], '0'])]
        if op == 'call':
            return [('jal', ['ra', a[0]])]
        if op == 'ret':
            return [('jalr', ['x0', 'ra', '0'])]
        if op == 'beqz':
            return [('beq', [a[0], 'x0', a[1]])]
        if op == 'bnez':
            return [('bne', [a[0], 'x0', a[1]])]
        # ---- CSR pseudo-instructions (all map onto csrr{w,s,c}[i]) ----
        if op == 'csrr':                    # csrr rd, csr   -> csrrs rd, csr, x0
            return [('csrrs', [a[0], a[1], 'x0'])]
        if op == 'csrw':                    # csrw csr, rs   -> csrrw x0, csr, rs
            return [('csrrw', ['x0', a[0], a[1]])]
        if op == 'csrs':                    # csrs csr, rs   -> csrrs x0, csr, rs
            return [('csrrs', ['x0', a[0], a[1]])]
        if op == 'csrc':                    # csrc csr, rs   -> csrrc x0, csr, rs
            return [('csrrc', ['x0', a[0], a[1]])]
        if op == 'csrwi':                   # csrwi csr, imm -> csrrwi x0, csr, imm
            return [('csrrwi', ['x0', a[0], a[1]])]
        if op == 'csrsi':
            return [('csrrsi', ['x0', a[0], a[1]])]
        if op == 'csrci':
            return [('csrrci', ['x0', a[0], a[1]])]
        if op in ('li', 'la'):
            v = self.value(a[1]) & 0xFFFFFFFF
            sv = v - (1 << 32) if v >= (1 << 31) else v
            if op == 'li' and -2048 <= sv <= 2047 and self.width(op, a) == 1:
                return [('addi', [a[0], 'x0', str(sv)])]
            lo = v & 0xFFF
            lo = lo - 4096 if lo >= 2048 else lo       # addi sign-extends
            hi = ((v - lo) >> 12) & 0xFFFFF
            return [('lui', [a[0], str(hi)]),
                    ('addi', [a[0], a[0], str(lo)])]
        return [(op, a)]

    # -- encode ONE real instruction at address `pc` -------------------------
    def encode(self, op, a, pc):
        if op in R_OPS:
            f7, f3 = R_OPS[op]
            return enc_r(f7, reg(a[2]), reg(a[1]), f3, reg(a[0]), 0x33)
        if op in I_OPS:
            return enc_i(self.value(a[2]), reg(a[1]), I_OPS[op], reg(a[0]), 0x13)
        if op in SHIFT_OPS:
            f7, f3 = SHIFT_OPS[op]
            sh = self.value(a[2])
            if not 0 <= sh <= 31:
                raise ValueError(f"shift amount out of range: {sh}")
            return enc_r(f7, sh, reg(a[1]), f3, reg(a[0]), 0x13)
        if op in LOADS:
            m = MEM_RE.match(a[1].strip())
            if not m:
                raise ValueError(f"expected imm(rs1): {a[1]!r}")
            return enc_i(self.value(m.group(1)), reg(m.group(2)),
                         LOADS[op], reg(a[0]), 0x03)
        if op in STORES:
            m = MEM_RE.match(a[1].strip())
            if not m:
                raise ValueError(f"expected imm(rs1): {a[1]!r}")
            return enc_s(self.value(m.group(1)), reg(a[0]), reg(m.group(2)),
                         STORES[op], 0x23)
        if op in BRANCHES:
            tgt = self.value(a[2])
            return enc_b(tgt - pc, reg(a[1]), reg(a[0]), BRANCHES[op], 0x63)
        if op == 'jal':
            rd, tgt = ('ra', a[0]) if len(a) == 1 else (a[0], a[1])
            return enc_j(self.value(tgt) - pc, reg(rd), 0x6F)
        if op == 'jalr':
            if len(a) == 1:                       # jalr rs1
                return enc_i(0, reg(a[0]), 0, 1, 0x67)
            if len(a) == 2 and MEM_RE.match(a[1].strip()):
                m = MEM_RE.match(a[1].strip())    # jalr rd, imm(rs1)
                return enc_i(self.value(m.group(1)), reg(m.group(2)), 0,
                             reg(a[0]), 0x67)
            return enc_i(self.value(a[2]), reg(a[1]), 0, reg(a[0]), 0x67)
        if op == 'lui':
            return enc_u(self.value(a[1]), reg(a[0]), 0x37)
        if op == 'auipc':
            return enc_u(self.value(a[1]), reg(a[0]), 0x17)
        if op in SYSTEM_FIXED:
            return SYSTEM_FIXED[op]
        if op in CSR_OPS:
            f3  = CSR_OPS[op]
            csr = self.csr_value(a[1])
            if op in CSR_IMM:
                uimm = self.value(a[2])
                if not 0 <= uimm <= 31:
                    raise ValueError(f"CSR immediate out of range 0..31: {uimm}")
                return enc_csr(csr, uimm, f3, reg(a[0]))
            return enc_csr(csr, reg(a[2]), f3, reg(a[0]))
        raise ValueError(f"unknown instruction: {op!r}")

    # -- the two passes ------------------------------------------------------
    def assemble(self, src_lines, src_name):
        section = 'text'
        pc, dp = 0, 0                       # text byte addr / data byte addr

        # ---------- pass 1: sizes + label addresses ----------
        items = []                          # ('ins',op,args,line#) / data ops
        for n, raw in enumerate(src_lines, 1):
            line = strip_comment(raw)
            if not line:
                continue
            while True:                     # peel leading "label:" prefixes
                m = re.match(r'^([A-Za-z_]\w*)\s*:\s*(.*)$', line)
                if not m:
                    break
                self.symbols[m.group(1)] = pc if section == 'text' else dp
                line = m.group(2)
            if not line:
                continue
            if line.startswith('.'):
                parts = line.split(None, 1)
                d = parts[0].lower()
                rest = parts[1] if len(parts) > 1 else ''
                if d == '.text':
                    section = 'text'
                elif d == '.data':
                    section = 'data'
                elif d == '.equ':
                    name, v = [x.strip() for x in rest.split(',', 1)]
                    self.symbols[name] = self.value(v)
                elif d in ('.word', '.half', '.byte'):
                    vals = [v.strip() for v in rest.split(',')]
                    if section == 'text':
                        # In .text, `.word` drops raw 32-bit words straight into
                        # the instruction stream — handy for encoding something
                        # the assembler has no mnemonic for (e.g. a deliberately
                        # illegal instruction to exercise the trap handler).
                        if d != '.word':
                            self.errors.append(
                                f"{src_name}:{n}: only .word is allowed in .text")
                            continue
                        items.append(('txt', d, vals, n, pc))
                        pc += 4 * len(vals)
                    else:
                        size = {'w': 4, 'h': 2, 'b': 1}[d[1]]
                        if size == 4 and dp % 4:
                            dp += 4 - dp % 4    # auto-align words
                        if size == 2 and dp % 2:
                            dp += 1
                        items.append(('dat', d, vals, n, dp))
                        dp += size * len(vals)
                elif d == '.asciz':
                    m = re.match(r'^"(.*)"$', rest.strip())
                    if not m:
                        self.errors.append(f"{src_name}:{n}: bad .asciz")
                        continue
                    s = unescape(m.group(1)) + '\0'
                    items.append(('str', s, None, n, dp))
                    dp += len(s)
                elif d == '.space':
                    items.append(('spc', int(rest, 0), None, n, dp))
                    dp += int(rest, 0)
                else:
                    self.errors.append(f"{src_name}:{n}: unknown directive {d}")
                continue
            # an instruction
            parts = line.split(None, 1)
            op = parts[0].lower()
            args = [a.strip() for a in parts[1].split(',')] if len(parts) > 1 else []
            if section != 'text':
                self.errors.append(f"{src_name}:{n}: instruction in .data")
                continue
            w = self.width(op, args)
            items.append(('ins', op, args, n, pc))
            pc += 4 * w

        # ---------- pass 2: encode ----------
        # pc-relative instructions (branches, jal) encode against the address
        # of the word they land at: `addr + 4*k` for the k-th word of a
        # pseudo-instruction expansion.
        words = []
        data = bytearray(dp)
        for kind, x, args, n, addr in items:
            if kind == 'ins':
                try:
                    sub = self.expand(x, args)
                    for k, (op2, a2) in enumerate(sub):
                        words.append(self.encode(op2, a2, addr + 4 * k))
                except ValueError as e:
                    self.errors.append(f"{src_name}:{n}: {e}")
            elif kind == 'dat':
                size = {'w': 4, 'h': 2, 'b': 1}[x[1]]
                p = addr
                for v in args:
                    try:
                        val = self.value(v) & ((1 << (8 * size)) - 1)
                    except ValueError as e:
                        self.errors.append(f"{src_name}:{n}: {e}")
                        val = 0
                    for b in range(size):
                        data[p + b] = (val >> (8 * b)) & 0xFF
                    p += size
            elif kind == 'txt':
                for v in args:
                    try:
                        words.append(self.value(v) & 0xFFFFFFFF)
                    except ValueError as e:
                        self.errors.append(f"{src_name}:{n}: {e}")
                        words.append(0)
            elif kind == 'str':
                for k, ch in enumerate(x):
                    data[addr + k] = ord(ch) & 0xFF
            elif kind == 'spc':
                pass                        # already zeros
        return words, data


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    base = os.path.splitext(src)[0]
    with open(src) as f:
        lines = f.readlines()
    asm = Assembler()
    words, data = asm.assemble(lines, src)
    if asm.errors:
        for e in asm.errors:
            print("error:", e, file=sys.stderr)
        sys.exit(1)
    with open(base + '.hex', 'w') as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    msg = f"{src}: {len(words)} instructions -> {base}.hex"
    if len(data):
        dwords = (len(data) + 3) // 4
        padded = data + bytes(4 * dwords - len(data))
        with open(base + '.data.hex', 'w') as f:
            for i in range(dwords):
                w = int.from_bytes(padded[4 * i:4 * i + 4], 'little')
                f.write(f"{w:08x}\n")
        msg += f", {len(data)} data bytes -> {base}.data.hex"
    print(msg)


if __name__ == '__main__':
    main()
