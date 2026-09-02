#!/usr/bin/env python3
"""Tokenise the compiler's own emitted assembly into a re-renderable tape.

The input is the `.s` file the stage0 compiler writes for `src/compiler_load.tl`
at `--opt-level 2`, i.e. exactly the text the backend's `compiler-backend-emit-*`
helpers produce while the compiler compiles itself. A contiguous range of
function chunks is taken (a chunk starts at a line whose first non-space bytes
are `.globl` and runs to just before the next one, the same chunking
`benchmarks/peephole_lines/tools/export_asm_slice.py` uses), sized so the two
corpus files together stay inside the byte budget.

Every line of the slice is tokenised back into the operand structure the backend
held BEFORE it rendered the line, so the kernel can render it again. The names
(mnemonic/directive heads, 64-bit register spellings, symbols, labels, verbatim
line text) go to the names file, one per line in id order; the tape refers to
them by id.

    names file: two `#` header lines, then exactly `names` lines, one name each.

    tape (whitespace-separated decimals, `#` comments to end of line):

      names chunks lines out-bytes out-fnv
      then per chunk:  line-count, then that many line rows
      line row:  kind [payload]
        kind 0  blank        -- no payload; renders "\\n"
        kind 1  verbatim     -- head-id; renders head + "\\n"
        kind 2  label        -- name-id; renders name + ":\\n"
        kind 3  directive    -- head-id nops operand*
        kind 4  instruction  -- head-id nops operand*
      operand: okind [fields]
        okind 0  register    -- reg64-id size   (compiler-backend-reg-part)
        okind 1  immediate   -- value           ("$" + string.int->string)
        okind 2  decimal     -- value           (string.int->string)
        okind 3  memory      -- base-id index-id scale disp disp-present
                                (index-id -1 when absent; renders
                                 disp(base) / disp(base,index,scale) through
                                 compiler-backend-address-add-byte-offset)
        okind 4  rip-relative-- sym-id          (name + "(%rip)")
        okind 5  symbol      -- sym-id          (the name itself)

A line renders as `head`, its operands joined with ", ", and a final "\\n";
`head` carries the indent and the trailing space (`"    movq "`, `".globl "`),
which is exactly how the backend spells the literal part of every emitter. A
line whose operands do not fit the grammar above is kept verbatim as a kind-1
row, so the re-render stays byte-exact.

`out-bytes` and `out-fnv` are the length and the 64-bit FNV-1a of the slice, the
values both kernels assert after re-rendering one unrotated round.

Usage:
  python3 export_asm_tape.py TAPE.txt NAMES.txt BUDGET_BYTES START_CHUNK IN.s

See ../README.md for the exact regeneration command.
"""

import re
import sys
from collections import Counter

LABEL_RE = re.compile(r"^[^\s:]+:$")
DEC_RE = re.compile(r"^-?[0-9]+$")
RIP_RE = re.compile(r"^([^\s(),]+)\(%rip\)$")
MEM_RE = re.compile(r"^(-?[0-9]+)?\((%[a-z0-9]+)(?:,(%[a-z0-9]+),([0-9]+))?\)$")

# compiler-backend-reg-part's table: for every register part, the 64-bit
# spelling it belongs to and its byte size. Registers outside this table (%rsp,
# %xmm*, ...) reach the text through compiler-abi-register-spelling as plain
# names, so the tape keeps those as plain symbol operands.
REG_TABLE = (
    ("%rax", "%eax", "%ax", "%al"),
    ("%rbx", "%ebx", "%bx", "%bl"),
    ("%rcx", "%ecx", "%cx", "%cl"),
    ("%rdx", "%edx", "%dx", "%dl"),
    ("%rdi", "%edi", "%di", "%dil"),
    ("%rsi", "%esi", "%si", "%sil"),
    ("%r12", "%r12d", "%r12w", "%r12b"),
    ("%r13", "%r13d", "%r13w", "%r13b"),
    ("%r14", "%r14d", "%r14w", "%r14b"),
    ("%r15", "%r15d", "%r15w", "%r15b"),
    ("%r8", "%r8d", "%r8w", "%r8b"),
    ("%r9", "%r9d", "%r9w", "%r9b"),
    ("%r10", "%r10d", "%r10w", "%r10b"),
    ("%r11", "%r11d", "%r11w", "%r11b"),
    ("%rbp", "%ebp", "%bp", "%bpl"),
)
REG_PARTS = {}
REG_SPELLING = {}
for _row in REG_TABLE:
    for _size, _spelling in zip((8, 4, 2, 1), _row):
        REG_PARTS[_spelling] = (_row[0], _size)
        REG_SPELLING[(_row[0], _size)] = _spelling

FNV_BASIS = 1469598103934665603
FNV_PRIME = 1099511628211
MASK = (1 << 64) - 1
OPERAND_WIDTH = {0: 3, 1: 2, 2: 2, 3: 6, 4: 2, 5: 2}


def fnv(data):
    value = FNV_BASIS
    for byte in data:
        value = ((value ^ byte) * FNV_PRIME) & MASK
    return value


def signed(value):
    return value - (1 << 64) if value >> 63 else value


class Names(object):
    """Interning table for every string the tape refers to by id."""

    def __init__(self):
        self.items = []
        self.index = {}
        self.bytes = 0

    def id(self, text):
        found = self.index.get(text)
        if found is None:
            found = len(self.items)
            self.index[text] = found
            self.items.append(text)
            self.bytes += len(text) + 1
        return found


def tokenise_operand(text, names):
    """Return the tape fields for one operand token."""
    if text.startswith("$") and DEC_RE.match(text[1:]):
        return [1, int(text[1:])]
    if DEC_RE.match(text):
        return [2, int(text)]
    part = REG_PARTS.get(text)
    if part is not None:
        return [0, names.id(part[0]), part[1]]
    rip = RIP_RE.match(text)
    if rip:
        return [4, names.id(rip.group(1))]
    mem = MEM_RE.match(text)
    if mem:
        disp, base, index, scale = mem.groups()
        return [
            3,
            names.id(base),
            names.id(index) if index else -1,
            int(scale) if scale else 0,
            int(disp) if disp is not None else 0,
            1 if disp is not None else 0,
        ]
    return [5, names.id(text)]


def render_operand(fields, names):
    kind = fields[0]
    if kind == 0:
        return REG_SPELLING[(names.items[fields[1]], fields[2])]
    if kind == 1:
        return "$" + str(fields[1])
    if kind == 2:
        return str(fields[1])
    if kind == 3:
        base = names.items[fields[1]]
        index = names.items[fields[2]] if fields[2] >= 0 else None
        scale, disp, present = fields[3], fields[4], fields[5]
        if index is None:
            addr = "(" + base + ")"
        else:
            addr = "(" + base + "," + index + "," + str(scale) + ")"
        return (str(disp) + addr) if present else addr
    if kind == 4:
        return names.items[fields[1]] + "(%rip)"
    return names.items[fields[1]]


def tokenise_line(line, names, stats):
    """Return the tape row for one line (given without its trailing newline)."""
    if line == "":
        stats["blank"] += 1
        return [0]
    if line.lstrip(" ").startswith("#"):
        stats["verbatim"] += 1
        return [1, names.id(line)]
    if LABEL_RE.match(line):
        stats["label"] += 1
        return [2, names.id(line[:-1])]
    stripped = line.lstrip(" ")
    indent = line[: len(line) - len(stripped)]
    split = stripped.split(" ", 1)
    mnemonic = split[0]
    rest = split[1] if len(split) > 1 else ""
    kind = 3 if mnemonic.startswith(".") else 4
    head = indent + mnemonic + (" " if rest else "")
    operands = rest.split(", ") if rest else []
    fields = []
    for operand in operands:
        parsed = tokenise_operand(operand, names)
        if render_operand(parsed, names) != operand:
            stats["verbatim"] += 1
            return [1, names.id(line)]
        fields.append(parsed)
    row = [kind, names.id(head), len(operands)]
    for parsed in fields:
        row.extend(parsed)
        stats["operand"][parsed[0]] += 1
    stats["directive" if kind == 3 else "instruction"] += 1
    stats["mnemonic"][mnemonic] += 1
    stats["arity"][len(operands)] += 1
    return row


def render_line(row, names):
    kind = row[0]
    if kind == 0:
        return "\n"
    if kind == 1:
        return names.items[row[1]] + "\n"
    if kind == 2:
        return names.items[row[1]] + ":\n"
    head = names.items[row[1]]
    cursor = 3
    parts = []
    for _ in range(row[2]):
        width = OPERAND_WIDTH[row[cursor]]
        parts.append(render_operand(row[cursor:cursor + width], names))
        cursor += width
    return head + ", ".join(parts) + "\n"


def row_text(row):
    return " ".join(str(value) for value in row)


def main(argv):
    if len(argv) != 6:
        sys.stderr.write(__doc__)
        return 2
    tape_path, names_path = argv[1], argv[2]
    budget = int(argv[3])
    start_chunk = int(argv[4])
    source = argv[5]

    with open(source, "r", encoding="utf-8", errors="replace",
              newline="\n") as handle:
        text = handle.read()
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()

    chunks = []
    current = []
    for line in lines:
        if line.lstrip(" ").startswith(".globl") and current:
            chunks.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        chunks.append(current)

    names = Names()
    stats = {
        "blank": 0, "verbatim": 0, "label": 0, "directive": 0,
        "instruction": 0,
        "mnemonic": Counter(), "operand": Counter(), "arity": Counter(),
    }
    kept = []
    slice_text = []
    tape_bytes = 128
    index = start_chunk
    while index < len(chunks):
        chunk = chunks[index]
        rows = [tokenise_line(line, names, stats) for line in chunk]
        cost = sum(len(row_text(row)) + 1 for row in rows) + 8
        if kept and tape_bytes + cost + names.bytes > budget:
            break
        tape_bytes += cost
        kept.append(rows)
        slice_text.append("\n".join(chunk) + "\n")
        index += 1

    original = "".join(slice_text)
    rebuilt = "".join(render_line(row, names) for rows in kept for row in rows)
    if rebuilt != original:
        for got, want in zip(rebuilt.split("\n"), original.split("\n")):
            if got != want:
                sys.stderr.write("MISMATCH\n got %r\nwant %r\n" % (got, want))
                break
        return 1

    encoded = original.encode("ascii")
    out_bytes = len(encoded)
    out_fnv = fnv(encoded)
    line_count = sum(len(rows) for rows in kept)

    with open(names_path, "w", encoding="ascii", newline="\n") as handle:
        handle.write("# benchmarks/asm_render names v1\n")
        handle.write("# sources: target/bench6-dumps/compiler_load.opt2.s"
                     " (stage0 -O2 assembly of src/compiler_load.tl)\n")
        for name in names.items:
            handle.write(name + "\n")

    with open(tape_path, "w", encoding="ascii", newline="\n") as handle:
        handle.write("# benchmarks/asm_render corpus v1\n")
        handle.write("# sources: target/bench6-dumps/compiler_load.opt2.s"
                     " (stage0 -O2 assembly of src/compiler_load.tl),"
                     " function chunks %d..%d\n" % (start_chunk, index - 1))
        handle.write("# names chunks lines slice-bytes slice-fnv\n")
        handle.write("%d %d %d %d %d\n"
                     % (len(names.items), len(kept), line_count, out_bytes,
                        signed(out_fnv)))
        for rows in kept:
            handle.write("%d\n" % len(rows))
            for row in rows:
                handle.write(row_text(row) + "\n")

    sys.stderr.write(
        "chunks=%d..%d lines=%d names=%d slice-bytes=%d slice-fnv=%d (%d)\n"
        % (start_chunk, index - 1, line_count, len(names.items), out_bytes,
           out_fnv, signed(out_fnv)))
    sys.stderr.write("kinds: blank=%d verbatim=%d label=%d directive=%d"
                     " instruction=%d\n"
                     % (stats["blank"], stats["verbatim"], stats["label"],
                        stats["directive"], stats["instruction"]))
    sys.stderr.write("arity: %s\n" % (
        ", ".join("%d=%d" % item for item in sorted(stats["arity"].items()))))
    sys.stderr.write("mnemonics (%d distinct): %s\n" % (
        len(stats["mnemonic"]),
        ", ".join("%s=%d" % item
                  for item in stats["mnemonic"].most_common(12))))
    sys.stderr.write("operands: reg=%d imm=%d dec=%d mem=%d rip=%d sym=%d\n"
                     % tuple(stats["operand"][kind] for kind in range(6)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
