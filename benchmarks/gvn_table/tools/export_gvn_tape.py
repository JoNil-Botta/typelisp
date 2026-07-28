#!/usr/bin/env python3
"""Export abstracted per-block instruction tapes from `--dump-ir after-ssa`.

`after-ssa` is the dump point immediately before the `gvn` pass in
`optimize-function-once-with-summaries`, so these are the exact instruction
sequences the load-CSE dispatcher walks.

Each instruction becomes a fixed 6-integer record `op dst a b c d` holding
exactly the fields `opt-load-cse-dispatch` and its callees read:

  0 OTHER     dst                                   (pure; def invalidation only)
  1 GEP       dst a=base var  b=0 const/1 var  c=offset-or-index  d=elem width
  2 LOAD      dst a=src var   b=type id        c=width            d=raw address id
  3 STORE     -1  a=ptr var   b=type id        c=width            d=value
  4 CALL      dst a=name id   b=is tl_alloc    c=0 memory-read/1 other
  5 MOV       dst a=src var   b=type id        c=width
  6 ALLOC     dst
  7 CLEARALL  dst                                   (indirect/tail call, syscall,
                                                     global store: clears the table)
  8 COPY      -1  a=dst var   b=src var        c=size
  9 CAST      dst a=src var                          (alias copy, no pointer kind)
 10 MAYALIAS  dst                                    (addr_of / entry_argv/argc)

`-1` in a var slot means "not a var" (a literal or a global). A STORE `d` of
`-1` is a value that is not copy-safe (`opt-copy-safe-source?` false: f64,
String, Bytes, global, function); `-2` is a copy-safe literal, which is what the
sub-word store-forward path normalizes.

Per function the exporter also precomputes the final `OptLoadHeaderSet`
(`opt-load-header-set-from-function`: parameters, then every defining
instruction's declared type, with the "poisoned to false stays false" rule) and
emits the header var ids. The compiler builds that set in one pre-pass over the
function; it is not part of the per-instruction dispatch this kernel measures.

Functions are deduplicated by exact rendered body (the after-ssa dump contains
one snapshot per optimizer pipeline iteration, so identical bodies repeat). The
deduplicated stream is then strided: the exporter renders every function once,
measures the total, and keeps every k-th function with the smallest k that fits
the byte budget, so the corpus samples the whole dump uniformly instead of
truncating to its stdlib-heavy prefix.

Usage:
  python3 export_gvn_tape.py OUT.txt BUDGET_BYTES DUMP.ir [DUMP.ir ...]

See ../README.md for the exact regeneration commands.
"""

import re
import sys

FUNC_RE = re.compile(r"^function [^(]*\((.*)\) -> (.*) vars (\d+) \{$")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.$]*):$")
DEF_RE = re.compile(r"^%(\d+) = (.*)$")
VAR_RE = re.compile(r"^%(\d+)$")
PARAM_RE = re.compile(r"^[^=]*=%(\d+):(.*)$")

WIDTHS = {
    "i64": 8, "u64": 8, "f64": 8,
    "i32": 4, "u32": 4, "f32": 4,
    "i16": 2, "u16": 2,
    "i8": 1, "u8": 1, "bool": 1, "char": 1,
    "unit": 0, "never": 0,
}

OP_OTHER, OP_GEP, OP_LOAD, OP_STORE, OP_CALL = 0, 1, 2, 3, 4
OP_MOV, OP_ALLOC, OP_CLEARALL, OP_COPY, OP_CAST, OP_MAYALIAS = 5, 6, 7, 8, 9, 10

# The only direct-call names `compiler-ir-runtime-memory-read-id?` accepts; a
# memory-read call leaves the load table intact, every other call empties it.
MEMORY_READ_CALLS = ("tl_region_mark", "tl_stdin_eof_label")

COPY_SAFE_LITERAL = re.compile(r"^(-?\d+|true|false|unit|'.*')$")


def strip_ref(text):
    """Peel `(& n T)` / `(&mut n T)` / `(Region n T)` down to the inner type."""
    for prefix in ("(& ", "(&mut ", "(Region "):
        if text.startswith(prefix) and text.endswith(")"):
            inner = text[len(prefix):-1]
            parts = inner.split(" ", 1)
            if len(parts) == 2:
                return strip_ref(parts[1])
    return text


def header_type(text):
    """`opt-licm-array-header-type?`: DynArray / String / str / Bytes, through refs."""
    inner = strip_ref(text)
    return inner in ("String", "str", "Bytes") or inner.startswith("(DynArray ")


def type_width(text):
    """`opt-load-loc-type-size`."""
    inner = text
    while inner.startswith("(Region ") and inner.endswith(")"):
        parts = inner[len("(Region "):-1].split(" ", 1)
        if len(parts) != 2:
            break
        inner = parts[1]
    return WIDTHS.get(inner, 8)


def var_of(text):
    match = VAR_RE.match(text.strip())
    return int(match.group(1)) if match is not None else -1


def split_type(body):
    """Split `... : TY` on the last ` : ` (string literals may contain colons)."""
    cut = body.rfind(" : ")
    if cut < 0:
        return body, ""
    return body[:cut], body[cut + 3:]


INTEGER_TYPES = ("i64", "u64", "i32", "u32", "i16", "u16", "i8", "u8",
                 "bool", "char")


def integer_like(text):
    """`opt-normalize-const` returns a constant only for integer/char/bool."""
    return text in INTEGER_TYPES


class Interner(object):
    def __init__(self):
        self.ids = {}
        self.order = []

    def intern(self, text):
        found = self.ids.get(text)
        if found is None:
            found = len(self.ids)
            self.ids[text] = found
            self.order.append(text)
        return found


def parse_functions(path):
    """Yield (params, nvars, blocks) per function; blocks are lists of raw lines."""
    out = []
    state = None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            match = FUNC_RE.match(line)
            if match is not None:
                params = [p for p in match.group(1).split(", ") if p]
                state = (params, int(match.group(3)), [])
                continue
            if state is None:
                continue
            if line == "}":
                out.append(state)
                state = None
                continue
            if line.startswith("  "):
                if state[2]:
                    state[2][-1].append(line[2:])
                continue
            if LABEL_RE.match(line) is not None:
                state[2].append([])
    return out


def header_set(params, nvars, blocks):
    """`opt-load-header-set-from-function` as a dense 0/1/2 array."""
    marks = [0] * max(nvars, 1)

    def mark(var, is_header):
        if var < 0 or var >= len(marks):
            return
        if is_header:
            if marks[var] == 0:
                marks[var] = 1
        else:
            marks[var] = 2

    for param in params:
        match = PARAM_RE.match(param.replace(" ", ""))
        if match is None:
            continue
        raw = param.split("=%", 1)[1]
        cut = raw.find(":")
        mark(int(raw[:cut]), header_type(raw[cut + 1:]))
    for block in blocks:
        for line in block:
            match = DEF_RE.match(line)
            if match is None:
                continue
            dst = int(match.group(1))
            body = match.group(2)
            head = body.split(" ", 1)[0]
            if head in ("mov", "load", "call", "call*", "phi", "cast", "bitcast"):
                mark(dst, header_type(split_type(body)[1]))
            else:
                mark(dst, False)
    return [i for i, v in enumerate(marks) if v == 1]


def encode(line, types, names, raws):
    """One instruction line -> (op, dst, a, b, c, d)."""
    match = DEF_RE.match(line)
    if match is not None:
        dst = int(match.group(1))
        body = match.group(2)
    else:
        dst = -1
        body = line
    head = body.split(" ", 1)[0]
    rest = body[len(head):].strip()

    if head == "alloc":
        return (OP_ALLOC, dst, -1, -1, -1, -1)
    if head == "gep":
        args, ty = split_type(rest)
        parts = args.split(", ")
        if len(parts) != 2:
            return (OP_OTHER, dst, -1, -1, -1, -1)
        base = var_of(parts[0])
        index = var_of(parts[1])
        if index >= 0:
            return (OP_GEP, dst, base, 1, index, type_width(ty))
        try:
            offset = int(parts[1].strip())
        except ValueError:
            return (OP_OTHER, dst, -1, -1, -1, -1)
        return (OP_GEP, dst, base, 0, offset, type_width(ty))
    if head == "load":
        args, ty = split_type(rest)
        src = var_of(args)
        raw = -1 if src >= 0 else raws.intern(args.strip())
        return (OP_LOAD, dst, src, types.intern(ty), type_width(ty), raw)
    if head == "store_ptr":
        args, ty = split_type(rest)
        parts = args.split(", ")
        if len(parts) != 2:
            return (OP_CLEARALL, dst, -1, -1, -1, -1)
        value = var_of(parts[1])
        if value < 0:
            value = -2 if COPY_SAFE_LITERAL.match(parts[1].strip()) else -1
        return (OP_STORE, -1, var_of(parts[0]), types.intern(ty),
                type_width(ty), value)
    if head == "copy_bytes":
        parts = rest.split(", ")
        if len(parts) != 3:
            return (OP_CLEARALL, dst, -1, -1, -1, -1)
        try:
            size = int(parts[2].strip())
        except ValueError:
            size = 0
        return (OP_COPY, -1, var_of(parts[0]), var_of(parts[1]), size, -1)
    if head == "call":
        name = rest.split("(", 1)[0]
        effect = 0 if name in MEMORY_READ_CALLS else 1
        return (OP_CALL, dst, names.intern(name),
                1 if name == "tl_alloc" else 0, effect, -1)
    if head in ("mov",):
        args, ty = split_type(rest)
        return (OP_MOV, dst, var_of(args), types.intern(ty), type_width(ty), -1)
    if head in ("cast", "bitcast"):
        return (OP_CAST, dst, var_of(rest.split(" ", 1)[0]), -1, -1, -1)
    if head in ("addr_of", "entry_argv", "entry_argc"):
        return (OP_MAYALIAS, dst, -1, -1, -1, -1)
    if head in ("call*", "tailcall", "store") or head.startswith("syscall"):
        return (OP_CLEARALL, dst, -1, -1, -1, -1)
    return (OP_OTHER, dst, -1, -1, -1, -1)


def main(argv):
    if len(argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    out_path = argv[1]
    budget = int(argv[2])
    sources = argv[3:]

    types = Interner()
    names = Interner()
    raws = Interner()
    seen = set()
    rendered = []
    counts = []
    total = 0

    for source in sources:
        for params, nvars, blocks in parse_functions(source):
            if not blocks:
                continue
            key = "\n".join("\n".join(block) for block in blocks)
            if key in seen:
                continue
            seen.add(key)
            headers = header_set(params, nvars, blocks)
            lines = ["%d %d %d" % (max(nvars, 1), len(headers), len(blocks))]
            if headers:
                lines.append(" ".join(str(h) for h in headers))
            count = 0
            for block in blocks:
                lines.append(str(len(block)))
                for line in block:
                    lines.append(" ".join(str(f)
                                          for f in encode(line, types, names, raws)))
                count += len(block)
            text = "\n".join(lines) + "\n"
            rendered.append(text)
            counts.append(count)
            total += len(text)

    stride = 1
    while total // stride > budget:
        stride += 1
    chunks = rendered[::stride]
    instructions = sum(counts[::stride])

    with open(out_path, "w", encoding="ascii", newline="\n") as out:
        out.write("# benchmarks/gvn_table corpus v1\n")
        out.write("# sources: %s\n" % " ".join(sources))
        out.write("# stride: every %dth deduplicated function\n" % stride)
        out.write("# ntypes, then per type: byte width, 1 if integer/char/bool\n")
        out.write("# then nfuncs, then per function: nvars nheaders nblocks,"
                  " header var ids,\n")
        out.write("# then per block: ninstr, then ninstr 'op dst a b c d' rows\n")
        out.write("%d\n" % len(types.order))
        for text in types.order:
            out.write("%d %d\n" % (type_width(text), 1 if integer_like(text) else 0))
        out.write("%d\n" % len(chunks))
        for chunk in chunks:
            out.write(chunk)

    sys.stderr.write("functions=%d instructions=%d stride=%d types=%d names=%d\n"
                     % (len(chunks), instructions, stride,
                        len(types.ids), len(names.ids)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
