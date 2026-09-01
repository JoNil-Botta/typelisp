#!/usr/bin/env python3
"""Export SCCP instruction tapes from `--dump-ir after-bounds_dom`.

`after-bounds_dom` is the dump point immediately before the `sccp` pass in
`optimize-function-once-with-summaries`, so these are the exact functions
`opt-sccp-blocks-with-context-result-raw` analyses.

The tape carries, per function, everything `opt-sccp-analyze-with-frame` reads:
the frame size (`vars N`, the lattice array's sizing rule), the parameter var
ids, the block list in order with each block's successor labels taken from its
terminator, the phi inputs with their predecessor labels, and one fixed-width
row per instruction.

Instruction row: `op dst ty ty2 a a-kind b b-kind`

  op   one of the codes below
  dst  destination var id, or -1
  ty   the instruction's declared type id (the compiler's `ty` field)
  ty2  the cast source type / the shift RHS count type, else the same as `ty`
  a,b  operand payload, meaning given by a-kind / b-kind

Operand kinds mirror `ir.CompilerIrValue`'s constructors as far as
`opt-normalize-const` distinguishes them:

  0 NONE    no operand
  1 VAR     `a` is a var id -> `opt-sccp-env-lookup`
  2 INT     `a` is a decimal literal (the dump prints `Char` literals as
            decimals too, and `opt-value-to-i64` accepts both identically)
  3 BOOL    `a` is 0/1
  4 OTHER   a global, a function, a string, `unit`, or `float-bits:N` --
            `opt-normalize-const` returns `NoConst`, i.e. Overdefined

Opcodes:

   0 OTHER    binds nothing (store, store_ptr, copy_bytes, return, tailcall...)
   1 OVERDEF  binds dst Overdefined (alloc, gep, load, call, pack, word,
              bitcast, addr_of, entry_argv, ... -- every dst-binding arm of
              `opt-sccp-process-instr` that is not Mov/Cast/BinOp/UnOp/Phi)
   2 MOV      dst := value(a) : ty
   3 CAST     dst := `opt-sccp-fold-cast-value` of a, from ty2 to ty
   4 PHI      dst := `opt-sccp-phi-value`; a = phi-pool base, b = input count
   5 JUMP     marks successor 0
   6 BRANCH   `opt-sccp-mark-branch-targets` on operand a over successors 0/1
   7 SWITCH   `opt-sccp-mark-switch-targets`; successor 0 is the default label
   8 BOUNDS   `bounds_check a, b`; binds nothing, counted by the rewrite phase
   9 NEG      `opt-fold-unop` Neg
  10 NOT      `opt-fold-unop` Not
  11 BITNOT   `opt-fold-unop` BitNot
  12 SQRT     `opt-fold-unop` Sqrt (never folds)
  16.. ADD SUB MUL DIV MOD SAFEDIV SAFEMOD EQ NE LT LE GT GE BITTESTEQ
       BITTESTNE AND OR BITAND BITOR BITXOR SHL SHR   (`opt-fold-binop`)

Type table entry: `class width`.

  class 0 other (never a constant)   1 signed int   2 unsigned int
        3 char (8-bit, unsigned)     4 bool         5 f64          6 f32

Type ids 0..5 are pre-interned as i64, bool, char, f64, f32, unit so
`opt-default-immediate-type` and `opt-binop-operand-type` (which compare
against `AstType.I64` / `.F64` / `.F32`) are id comparisons.

Functions are deduplicated across the whole input list by their rendered body
plus parameter list and frame size -- every dump is a whole program, so the
stdlib and `compiler_intern` functions appear in all ten. The first occurrence
wins. The deduplicated stream is then strided: the exporter renders every
function once, measures the total, and keeps every k-th function with the
smallest k that fits the byte budget, so the corpus samples the whole input
uniformly instead of truncating to its stdlib-heavy prefix.

The exporter then runs its own SCCP over the encoded tape (`analyse` below, a
direct transcription of `opt-sccp-analyze-fixed`) and writes the five totals it
finds -- vars that end `Const`, blocks that end non-executable, operand
substitutions, branches that fold to jumps, and bounds checks proven in range
-- into the corpus header as data. `bench.tl` and `baseline.c` recompute all
five and exit 1 if any disagrees: that is the benchmark's self-check.

Usage:
  python3 export_sccp_tape.py OUT.txt BUDGET_BYTES DUMP.ir [DUMP.ir ...]

See ../README.md for the exact regeneration command.
"""

import re
import sys

FUNC_RE = re.compile(r"^function [^(]*\((.*)\) -> (.*) vars (\d+) \{$")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.$]*):$")
DEF_RE = re.compile(r"^%(\d+) = (.*)$")
VAR_RE = re.compile(r"^%(\d+)$")
INT_RE = re.compile(r"^-?\d+$")
PHI_RE = re.compile(r"\[([^,\[\]]+), ([^,\[\]]+)\]")
LABEL_NUM_RE = re.compile(r"^(\d+)")

MASK64 = (1 << 64) - 1

TY_OTHER, TY_SINT, TY_UINT, TY_CHAR, TY_BOOL, TY_F64, TY_F32 = 0, 1, 2, 3, 4, 5, 6

VK_NONE, VK_VAR, VK_INT, VK_BOOL, VK_OTHER = 0, 1, 2, 3, 4

(OP_OTHER, OP_OVERDEF, OP_MOV, OP_CAST, OP_PHI, OP_JUMP, OP_BRANCH, OP_SWITCH,
 OP_BOUNDS, OP_NEG, OP_NOT, OP_BITNOT, OP_SQRT) = range(13)

OP_ADD = 16
BINOPS = ["add", "sub", "mul", "div", "mod", "safe_div", "safe_mod",
          "eq", "ne", "lt", "le", "gt", "ge", "bit_test_eq", "bit_test_ne",
          "and", "or", "bit_and", "bit_or", "bit_xor", "shl", "shr"]
BINOP_CODE = dict((name, OP_ADD + i) for i, name in enumerate(BINOPS))
(B_ADD, B_SUB, B_MUL, B_DIV, B_MOD, B_SAFEDIV, B_SAFEMOD, B_EQ, B_NE, B_LT,
 B_LE, B_GT, B_GE, B_BITTESTEQ, B_BITTESTNE, B_AND, B_OR, B_BITAND, B_BITOR,
 B_BITXOR, B_SHL, B_SHR) = [BINOP_CODE[n] for n in BINOPS]

UNOPS = {"neg": OP_NEG, "not": OP_NOT, "bit_not": OP_BITNOT, "sqrt": OP_SQRT}

# Heads whose whole operand list fits the row's two operand columns.
OPERAND_HEADS = ("load", "gep", "store_ptr", "copy_bytes", "return",
                 "addr_of", "pack", "word", "splat")

# Lattice tags.
L_UNKNOWN, L_CONST, L_OVER = 0, 1, 2

SCALARS = {
    "i64": (TY_SINT, 64), "i32": (TY_SINT, 32),
    "i16": (TY_SINT, 16), "i8": (TY_SINT, 8),
    "u64": (TY_UINT, 64), "u32": (TY_UINT, 32),
    "u16": (TY_UINT, 16), "u8": (TY_UINT, 8),
    "char": (TY_CHAR, 8), "bool": (TY_BOOL, 1),
    "f64": (TY_F64, 64), "f32": (TY_F32, 32),
}

PRE_INTERNED = ["i64", "bool", "char", "f64", "f32", "unit"]
T_I64, T_BOOL, T_CHAR, T_F64, T_F32, T_UNIT = range(6)


class Types(object):
    """Interns AstType spellings; ids 0..5 are the pre-interned ones."""

    def __init__(self):
        self.ids = {}
        self.rows = []
        for text in PRE_INTERNED:
            self.intern(text)

    def intern(self, text):
        text = text.strip()
        found = self.ids.get(text)
        if found is None:
            found = len(self.rows)
            self.ids[text] = found
            self.rows.append(SCALARS.get(text, (TY_OTHER, 0)))
        return found


def split_type(body):
    """Split `... : TY` on the last ` : ` (string literals may contain colons)."""
    cut = body.rfind(" : ")
    if cut < 0:
        return body, ""
    return body[:cut], body[cut + 3:]


def parse_value(text):
    """One IR value -> (kind, payload)."""
    text = text.strip()
    match = VAR_RE.match(text)
    if match is not None:
        return (VK_VAR, int(match.group(1)))
    if INT_RE.match(text) is not None:
        return (VK_INT, int(text) & MASK64)
    if text == "true":
        return (VK_BOOL, 1)
    if text == "false":
        return (VK_BOOL, 0)
    return (VK_OTHER, 0)


def signed(value):
    value &= MASK64
    return value - (1 << 64) if value >= (1 << 63) else value


class Function(object):
    def __init__(self, frame):
        self.frame = max(frame, 1)
        self.params = []          # var ids
        self.param_types = []
        self.labels = []          # per block
        self.succ = []            # flat successor label pool
        self.succ_base = []
        self.succ_count = []
        self.phi = []             # flat (pred-label, kind, value) pool
        self.instr = []           # flat rows of 8
        self.instr_base = []
        self.instr_count = []


def label_id(name, taken):
    """A plausible i64 label value for a dumped label name.

    Lowered labels are near-contiguous integers; the dump spells them
    `<role>.<id>` (`if_then.0`, `while_exit.10`, `while_body.9__unroll_body`),
    so the trailing number is the compiler's own label id. `entry` keeps 0 and
    every other label takes `id + 1`; a collision (inlined bodies repeat the
    suffix) falls through to the next free integer, which keeps the set dense
    and distinct exactly like the real one.
    """
    if name == "entry":
        want = 0
    else:
        tail = name.rsplit(".", 1)[-1]
        match = LABEL_NUM_RE.match(tail)
        want = int(match.group(1)) + 1 if match is not None else -1
    if want < 0 or want in taken:
        want = max(taken) + 1 if taken else 0
        while want in taken:
            want += 1
    taken.add(want)
    return want


def split_params(text):
    """Paren-aware split of a parameter list on top-level `, `."""
    out = []
    depth = 0
    start = 0
    index = 0
    while index < len(text):
        char = text[index]
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        elif char == "," and depth == 0 and index + 1 < len(text):
            out.append(text[start:index])
            start = index + 2
            index += 1
        index += 1
    if start < len(text):
        out.append(text[start:])
    return [p for p in out if p]


def parse_dump(path):
    """Yield (params-text, frame, [(label, [lines]), ...]) per function.

    The dump escapes newlines inside string literals but not quotes, so a line
    is a self-contained record: instructions are the two-space-indented lines,
    a bare `name:` opens a block and a bare `}` closes the function.
    """
    out = []
    state = None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            match = FUNC_RE.match(line)
            if match is not None:
                state = (match.group(1), int(match.group(3)), [])
                continue
            if state is None:
                continue
            if line == "}":
                out.append(state)
                state = None
                continue
            if line.startswith("  "):
                if state[2]:
                    state[2][-1][1].append(line[2:])
                continue
            label = LABEL_RE.match(line)
            if label is not None:
                state[2].append((label.group(1), []))
    return out


def encode_function(params_text, frame, blocks, types):
    """One parsed function -> a Function, or None if it has no blocks."""
    if not blocks:
        return None
    func = Function(frame)
    taken = set()
    ids = {}
    for name, _ in blocks:
        if name not in ids:
            ids[name] = label_id(name, taken)
    for param in split_params(params_text):
        cut = param.find("=%")
        if cut < 0:
            continue
        rest = param[cut + 2:]
        colon = rest.find(":")
        if colon < 0:
            continue
        try:
            func.params.append(int(rest[:colon]))
        except ValueError:
            continue
        func.param_types.append(types.intern(rest[colon + 1:]))

    for name, lines in blocks:
        func.labels.append(ids[name])
        func.succ_base.append(len(func.succ))
        func.instr_base.append(len(func.instr) // 8)
        before = len(func.succ)
        rows = 0
        for line in lines:
            rows += encode_instr(line, func, ids, types)
        func.succ_count.append(len(func.succ) - before)
        func.instr_count.append(rows)
    return func


def target_of(name, ids, func):
    """Record a successor label; unknown labels become -1 (`opt-cfg-index-id`
    returns `None`, and `opt-sccp-state-mark-executable` then does nothing)."""
    func.succ.append(ids.get(name.strip(), -1))


def encode_instr(line, func, ids, types):
    """Append one instruction row (and its successors / phi inputs). -> 1."""
    match = DEF_RE.match(line)
    if match is not None:
        dst = int(match.group(1))
        body = match.group(2)
    else:
        dst = -1
        body = line
    head = body.split(" ", 1)[0]
    rest = body[len(head):].strip()

    def emit(op, ty, ty2, a, akind, b, bkind):
        func.instr.extend([op, dst, ty, ty2, a, akind, b, bkind])
        return 1

    if head == "jump":
        target_of(rest, ids, func)
        return emit(OP_JUMP, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
    if head == "branch":
        parts = rest.split(", ")
        if len(parts) != 3:
            return emit(OP_OTHER, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
        target_of(parts[1], ids, func)
        target_of(parts[2], ids, func)
        kind, value = parse_value(parts[0])
        return emit(OP_BRANCH, T_BOOL, T_BOOL, value, kind, 0, VK_NONE)
    if head == "switch":
        # `switch %v base N [k:L, ...] default L`; the compiler marks the
        # default first, then every case, so successor 0 is the default.
        open_bracket = rest.find("[")
        close_bracket = rest.rfind("]")
        default_at = rest.rfind(" default ")
        if open_bracket < 0 or close_bracket < 0 or default_at < 0:
            return emit(OP_OTHER, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
        target_of(rest[default_at + 9:], ids, func)
        for case in rest[open_bracket + 1:close_bracket].split(", "):
            colon = case.find(":")
            if colon >= 0:
                target_of(case[colon + 1:], ids, func)
        return emit(OP_SWITCH, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
    if head == "bounds_check":
        args = rest.split(" message ")[0]
        parts = args.split(", ")
        if len(parts) != 2:
            return emit(OP_OTHER, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
        akind, a = parse_value(parts[0])
        bkind, b = parse_value(parts[1])
        return emit(OP_BOUNDS, T_I64, T_I64, a, akind, b, bkind)
    if head == "mov":
        args, ty_text = split_type(rest)
        if not ty_text:
            return emit(OP_OVERDEF, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
        ty = types.intern(ty_text)
        kind, value = parse_value(args)
        return emit(OP_MOV, ty, ty, value, kind, 0, VK_NONE)
    if head in ("cast", "bitcast"):
        args, ty_text = split_type(rest)
        cut = ty_text.rfind(" to ")
        if not ty_text or cut < 0:
            return emit(OP_OVERDEF, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
        from_ty = types.intern(ty_text[:cut])
        to_ty = types.intern(ty_text[cut + 4:])
        if head == "bitcast":
            # `Bitcast` binds Overdefined unconditionally.
            return emit(OP_OVERDEF, to_ty, from_ty, 0, VK_NONE, 0, VK_NONE)
        kind, value = parse_value(args)
        return emit(OP_CAST, to_ty, from_ty, value, kind, 0, VK_NONE)
    if head == "phi":
        args, ty_text = split_type(rest)
        inputs = PHI_RE.findall(args)
        if not ty_text or not inputs:
            return emit(OP_OVERDEF, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
        ty = types.intern(ty_text)
        base = len(func.phi) // 3
        for value_text, label_text in inputs:
            kind, value = parse_value(value_text)
            func.phi.extend([ids.get(label_text.strip(), -1), kind, value])
        return emit(OP_PHI, ty, ty, base, VK_NONE, len(inputs), VK_NONE)
    if head in UNOPS:
        args, ty_text = split_type(rest)
        if not ty_text:
            return emit(OP_OVERDEF, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
        ty = types.intern(ty_text)
        kind, value = parse_value(args)
        return emit(UNOPS[head], ty, ty, value, kind, 0, VK_NONE)
    if head in BINOP_CODE:
        args, ty_text = split_type(rest)
        parts = args.split(", ")
        if not ty_text or len(parts) != 2:
            return emit(OP_OVERDEF, T_UNIT, T_UNIT, 0, VK_NONE, 0, VK_NONE)
        ty = types.intern(ty_text)
        akind, a = parse_value(parts[0])
        bkind, b = parse_value(parts[1])
        # The dump does not print the shift's independently typed RHS; the
        # lowerer emits i64 counts, which is what `compiler-ir-binop-rhs-type`
        # hands `opt-shift-count-valid?`.
        rhs_ty = T_I64 if head in ("shl", "shr") else ty
        return emit(BINOP_CODE[head], ty, rhs_ty, a, akind, b, bkind)
    # Everything else binds Overdefined (or nothing). Its operands still matter
    # to the counted rewrite phase, so the two operand columns carry them for
    # the instructions whose operand list fits: `opt-sccp-rewrite-instr`
    # substitutes Const lattice values into exactly these positions.
    akind, a, bkind, b = VK_NONE, 0, VK_NONE, 0
    if head in OPERAND_HEADS:
        args, _ = split_type(rest)
        parts = args.split(", ")
        if len(parts) >= 1 and parts[0]:
            akind, a = parse_value(parts[0])
        if len(parts) >= 2:
            bkind, b = parse_value(parts[1])
    return emit(OP_OTHER if dst < 0 else OP_OVERDEF,
                T_UNIT, T_UNIT, a, akind, b, bkind)


# --- the reference analysis (a transcription of opt-sccp-analyze-fixed) -----

def normalize_int(value, klass, width):
    """`opt-normalize-int-to-i64`."""
    if klass == TY_SINT:
        value &= (1 << width) - 1
        if value >= (1 << (width - 1)):
            value -= 1 << width
        return value & MASK64
    if klass == TY_UINT:
        return value & ((1 << width) - 1)
    if klass == TY_CHAR:
        return value & 0xFF
    return value & MASK64


class Lattice(object):
    __slots__ = ("tag", "kind", "value", "ty")

    def __init__(self, tag, kind=0, value=0, ty=0):
        self.tag = tag
        self.kind = kind
        self.value = value
        self.ty = ty


UNKNOWN = Lattice(L_UNKNOWN)
OVER = Lattice(L_OVER)


class Analysis(object):
    def __init__(self, rows):
        self.rows = rows

    def klass(self, ty):
        return self.rows[ty][0]

    def width(self, ty):
        return self.rows[ty][1]

    def integer(self, ty):
        return self.klass(ty) in (TY_SINT, TY_UINT)

    def int_or_char(self, ty):
        return self.klass(ty) in (TY_SINT, TY_UINT, TY_CHAR)

    def normalize_const(self, kind, value, ty):
        """`opt-normalize-const`."""
        klass = self.klass(ty)
        if klass in (TY_SINT, TY_UINT):
            if kind != VK_INT:
                return None
            return Lattice(L_CONST, VK_INT,
                           normalize_int(value, klass, self.width(ty)), ty)
        if klass == TY_CHAR:
            if kind != VK_INT:
                return None
            return Lattice(L_CONST, VK_INT, value & 0xFF, T_CHAR)
        if klass == TY_BOOL:
            if kind != VK_BOOL:
                return None
            return Lattice(L_CONST, VK_BOOL, value, T_BOOL)
        return None

    def immediate(self, kind, value, ty):
        """`opt-sccp-immediate` over `opt-default-immediate-type`."""
        if kind == VK_INT:
            fallback = ty if self.int_or_char(ty) else T_I64
        elif kind == VK_BOOL:
            fallback = T_BOOL
        else:
            fallback = ty
        folded = self.normalize_const(kind, value, fallback)
        return folded if folded is not None else OVER

    def value(self, env, kind, payload, ty):
        """`opt-sccp-value`."""
        if kind == VK_VAR:
            return env[payload] if 0 <= payload < len(env) else UNKNOWN
        if kind == VK_NONE:
            return UNKNOWN
        return self.immediate(kind, payload, ty)

    def join(self, old, new):
        """`opt-sccp-join`."""
        if old.tag == L_UNKNOWN:
            return new
        if old.tag == L_OVER:
            return OVER
        if new.tag == L_UNKNOWN:
            return old
        if new.tag == L_OVER:
            return OVER
        if old.kind == new.kind and old.value == new.value and old.ty == new.ty:
            return old
        return OVER

    def scalar_to_i64(self, item, ty):
        """`opt-normalize-scalar-to-i64`."""
        if not self.int_or_char(ty) or item.kind != VK_INT:
            return None
        return normalize_int(item.value, self.klass(ty), self.width(ty))

    def operand_type(self, op, lhs_ty, rhs_ty, result_ty):
        """`opt-binop-operand-type`."""
        if op in (B_EQ, B_NE, B_LT, B_LE, B_GT, B_GE):
            if lhs_ty == T_I64:
                return rhs_ty
            if lhs_ty == T_F64 and rhs_ty == T_F32:
                return rhs_ty
            return lhs_ty
        if op in (B_BITAND, B_BITOR, B_BITXOR, B_SHL, B_SHR):
            return lhs_ty
        return result_ty

    def fold_binop(self, op, lhs, rhs, ty, rhs_ty_field):
        """`opt-fold-binop`, minus the float arm (see README, Dropped)."""
        operand_ty = self.operand_type(op, lhs.ty, rhs.ty, ty)
        klass = self.klass(operand_ty)
        if klass == TY_BOOL:
            if lhs.kind != VK_BOOL or rhs.kind != VK_BOOL:
                return None
            a, b = lhs.value, rhs.value
            if op == B_AND:
                return Lattice(L_CONST, VK_BOOL, 1 if (a and b) else 0, ty)
            if op == B_OR:
                return Lattice(L_CONST, VK_BOOL, 1 if (a or b) else 0, ty)
            if op == B_EQ:
                return Lattice(L_CONST, VK_BOOL, 1 if a == b else 0, ty)
            if op == B_NE:
                return Lattice(L_CONST, VK_BOOL, 1 if a != b else 0, ty)
            return None
        if klass in (TY_SINT, TY_UINT, TY_CHAR):
            return self.fold_int(op, lhs, rhs, operand_ty, rhs_ty_field, ty)
        return None

    def fold_int(self, op, lhs, rhs, operand_ty, rhs_ty_field, ty):
        """`opt-fold-int-char-binop`."""
        a = self.scalar_to_i64(lhs, operand_ty)
        if a is None:
            return None
        klass = self.klass(operand_ty)
        width = self.width(operand_ty) if klass != TY_BOOL else 0
        if op in (B_SHL, B_SHR):
            count = self.scalar_to_i64(rhs, rhs_ty_field)
            if count is None:
                return None
            if not self.shift_valid(count, rhs_ty_field, width):
                return None
            if op == B_SHL:
                out = (a << count) & MASK64
            elif klass == TY_SINT:
                out = signed(a) >> count
            else:
                out = a >> count
            return Lattice(L_CONST, VK_INT,
                           normalize_int(out, klass, width), ty)
        b = self.scalar_to_i64(rhs, operand_ty)
        if b is None:
            return None
        integer = klass in (TY_SINT, TY_UINT)
        if op in (B_ADD, B_SUB, B_MUL, B_BITAND, B_BITOR, B_BITXOR):
            if not integer:
                return None
            if op == B_ADD:
                out = a + b
            elif op == B_SUB:
                out = a - b
            elif op == B_MUL:
                out = signed(a) * signed(b)
            elif op == B_BITAND:
                out = a & b
            elif op == B_BITOR:
                out = a | b
            else:
                out = a ^ b
            return Lattice(L_CONST, VK_INT,
                           normalize_int(out & MASK64, klass, width), ty)
        if op in (B_DIV, B_MOD, B_SAFEDIV, B_SAFEMOD):
            if not integer or not self.divmod_valid(a, b, klass, width):
                return None
            if klass == TY_SINT:
                x = self.to_signed(a, width)
                y = self.to_signed(b, width)
            else:
                x, y = a, b
            quotient = abs(x) // abs(y)
            if (x < 0) != (y < 0):
                quotient = -quotient
            if op in (B_DIV, B_SAFEDIV):
                out = quotient
            else:
                out = x - quotient * y
            return Lattice(L_CONST, VK_INT,
                           normalize_int(out & MASK64, klass, width), ty)
        if op in (B_EQ, B_NE):
            same = a == b
            hit = same if op == B_EQ else not same
            return Lattice(L_CONST, VK_BOOL, 1 if hit else 0, ty)
        if op in (B_LT, B_LE, B_GT, B_GE):
            if klass == TY_UINT:
                x, y = a, b
            else:
                x = self.to_signed(a, width) if klass == TY_SINT else a
                y = self.to_signed(b, width) if klass == TY_SINT else b
            if op == B_LT:
                hit = x < y
            elif op == B_LE:
                hit = x <= y
            elif op == B_GT:
                hit = x > y
            else:
                hit = x >= y
            return Lattice(L_CONST, VK_BOOL, 1 if hit else 0, ty)
        if op in (B_BITTESTEQ, B_BITTESTNE):
            hit = (a & b) == 0
            if op == B_BITTESTNE:
                hit = not hit
            return Lattice(L_CONST, VK_BOOL, 1 if hit else 0, ty)
        return None

    @staticmethod
    def to_signed(value, width):
        value &= (1 << width) - 1
        return value - (1 << width) if value >= (1 << (width - 1)) else value

    def shift_valid(self, count, count_ty, width):
        """`opt-shift-count-valid?`."""
        if not self.integer(count_ty):
            return False
        klass = self.klass(count_ty)
        if klass == TY_SINT:
            return 0 <= self.to_signed(count, self.width(count_ty)) < width
        return count < width

    def divmod_valid(self, a, b, klass, width):
        """`opt-divmod-valid?`."""
        if b == 0:
            return False
        if klass == TY_SINT:
            return not (self.to_signed(a, width) == -(1 << (width - 1))
                        and self.to_signed(b, width) == -1)
        return True

    def fold_unop(self, op, src, ty):
        """`opt-fold-unop`."""
        klass = self.klass(ty)
        if op == OP_NEG:
            if klass not in (TY_SINT, TY_UINT):
                return None
            a = self.scalar_to_i64(src, ty)
            if a is None:
                return None
            return Lattice(L_CONST, VK_INT,
                           normalize_int((-a) & MASK64, klass, self.width(ty)),
                           ty)
        if op == OP_NOT:
            if klass != TY_BOOL or src.kind != VK_BOOL:
                return None
            return Lattice(L_CONST, VK_BOOL, 0 if src.value else 1, ty)
        if op == OP_BITNOT:
            if klass not in (TY_SINT, TY_UINT):
                return None
            a = self.scalar_to_i64(src, ty)
            if a is None:
                return None
            return Lattice(L_CONST, VK_INT,
                           normalize_int((~a) & MASK64, klass, self.width(ty)),
                           ty)
        return None

    def fold_cast(self, src, from_ty, to_ty):
        """`opt-fold-cast` over `compiler-finite-cast-fold`, integers only."""
        if not self.int_or_char(from_ty) or src.kind != VK_INT:
            return None
        n = normalize_int(src.value, self.klass(from_ty), self.width(from_ty))
        if not self.int_or_char(to_ty):
            return None
        return Lattice(L_CONST, VK_INT,
                       normalize_int(n, self.klass(to_ty), self.width(to_ty)),
                       to_ty)


def analyse(func, analysis):
    """`opt-sccp-analyze-with-frame`: -> (consts, dead blocks, sweeps)."""
    env = [UNKNOWN] * func.frame
    for var in func.params:
        if 0 <= var < len(env):
            env[var] = OVER
    nblocks = len(func.labels)
    exec_flags = [False] * nblocks
    index = {}
    for block, label in enumerate(func.labels):
        if label not in index:
            index[label] = block
    if nblocks:
        exec_flags[0] = True
    ninstr = len(func.instr) // 8
    remaining = nblocks + 8 + 2 * ninstr
    sweeps = 0
    changed = True
    while remaining > 0 and changed:
        remaining -= 1
        sweeps += 1
        changed = False
        for block in range(nblocks):
            if not exec_flags[block]:
                continue
            base = func.instr_base[block]
            for row in range(base, base + func.instr_count[block]):
                changed = step(func, analysis, env, exec_flags, index,
                               block, row) or changed
    consts = sum(1 for item in env if item.tag == L_CONST)
    dead = sum(1 for flag in exec_flags if not flag)
    subs, branches, dropped = rewrite(func, analysis, env, consts > 0)
    return consts, dead, sweeps, subs, branches, dropped


def const_var(env, kind, payload):
    """`opt-sccp-rewrite-value`: the Const a Var operand resolves to, or None."""
    if kind != VK_VAR or not (0 <= payload < len(env)):
        return None
    item = env[payload]
    return item if item.tag == L_CONST else None


def as_i64(analysis, env, kind, payload):
    """The `ir.CompilerIrValue.I64` a rewritten operand ends up being."""
    if kind == VK_INT:
        return payload
    item = const_var(env, kind, payload)
    if item is None or item.kind != VK_INT:
        return None
    if analysis.klass(item.ty) not in (TY_SINT, TY_UINT):
        return None
    return item.value


def rewrite(func, analysis, env, any_const):
    """The counted rewrite phase: `opt-sccp-rewrite-value` substitutions,
    `opt-sccp-instr-changes-successors?` hits, and the bounds checks
    `opt-sccp-bounds-check-in-range?` proves away."""
    if not any_const:
        return 0, 0, 0
    subs = 0
    branches = 0
    dropped = 0
    for row in range(len(func.instr) // 8):
        at = row * 8
        op, _dst, _ty, _ty2, a, akind, b, bkind = func.instr[at:at + 8]
        if op == OP_PHI:
            for i in range(b):
                pred_kind = func.phi[(a + i) * 3 + 1]
                pred_value = func.phi[(a + i) * 3 + 2]
                if const_var(env, pred_kind, pred_value) is not None:
                    subs += 1
            continue
        if const_var(env, akind, a) is not None:
            subs += 1
        if const_var(env, bkind, b) is not None:
            subs += 1
        if op == OP_BRANCH:
            if akind == VK_BOOL:
                branches += 1
            else:
                item = const_var(env, akind, a)
                if item is not None and item.kind == VK_BOOL:
                    branches += 1
        elif op == OP_BOUNDS:
            index = as_i64(analysis, env, akind, a)
            length = as_i64(analysis, env, bkind, b)
            if index is not None and length is not None:
                if signed(index) >= 0 and signed(length) >= 0 \
                        and signed(index) < signed(length):
                    dropped += 1
    return subs, branches, dropped


def mark(func, exec_flags, index, label):
    """`opt-sccp-state-mark-executable`."""
    block = index.get(label)
    if block is None or exec_flags[block]:
        return False
    exec_flags[block] = True
    return True


def bind(env, var, value, analysis):
    """`opt-sccp-state-bind`."""
    if not (0 <= var < len(env)):
        old = UNKNOWN
        merged = analysis.join(old, value)
        return merged.tag != L_UNKNOWN
    old = env[var]
    merged = analysis.join(old, value)
    if merged.tag == old.tag and (merged.tag != L_CONST or (
            merged.kind == old.kind and merged.value == old.value
            and merged.ty == old.ty)):
        return False
    env[var] = merged
    return True


def step(func, analysis, env, exec_flags, index, block, row):
    """`opt-sccp-process-instr`."""
    at = row * 8
    op, dst, ty, ty2, a, akind, b, bkind = func.instr[at:at + 8]
    succ_base = func.succ_base[block]
    if op == OP_OTHER or op == OP_BOUNDS:
        return False
    if op == OP_OVERDEF:
        return bind(env, dst, OVER, analysis)
    if op == OP_MOV:
        return bind(env, dst, analysis.value(env, akind, a, ty), analysis)
    if op == OP_CAST:
        src = analysis.value(env, akind, a, ty2)
        if src.tag == L_CONST:
            folded = analysis.fold_cast(src, ty2, ty)
            out = folded if folded is not None else OVER
        else:
            out = src
        return bind(env, dst, out, analysis)
    if op == OP_PHI:
        out = UNKNOWN
        for i in range(b - 1, -1, -1):
            pred, kind, value = func.phi[(a + i) * 3:(a + i) * 3 + 3]
            pred_block = index.get(pred)
            if pred_block is not None and exec_flags[pred_block]:
                item = analysis.value(env, kind, value, ty)
            else:
                item = UNKNOWN
            out = analysis.join(item, out)
        return bind(env, dst, out, analysis)
    if op == OP_JUMP:
        return mark(func, exec_flags, index, func.succ[succ_base])
    if op == OP_BRANCH:
        cond = analysis.value(env, akind, a, T_BOOL)
        targets = func.succ[succ_base:succ_base + func.succ_count[block]]
        if cond.tag == L_UNKNOWN:
            return False
        if cond.tag == L_CONST and cond.kind == VK_BOOL:
            return mark(func, exec_flags, index,
                        targets[0] if cond.value else targets[1])
        hit = mark(func, exec_flags, index, targets[0])
        return mark(func, exec_flags, index, targets[1]) or hit
    if op == OP_SWITCH:
        hit = False
        for target in func.succ[succ_base:succ_base + func.succ_count[block]]:
            hit = mark(func, exec_flags, index, target) or hit
        return hit
    if op in (OP_NEG, OP_NOT, OP_BITNOT, OP_SQRT):
        src = analysis.value(env, akind, a, ty)
        if src.tag == L_CONST:
            folded = analysis.fold_unop(op, src, ty)
            out = folded if folded is not None else OVER
        else:
            out = src
        return bind(env, dst, out, analysis)
    lhs = analysis.value(env, akind, a, ty)
    rhs = analysis.value(env, bkind, b, ty2)
    if lhs.tag == L_CONST:
        if rhs.tag == L_CONST:
            folded = analysis.fold_binop(op, lhs, rhs, ty, ty2)
            out = folded if folded is not None else OVER
        else:
            out = rhs
    else:
        out = lhs
    return bind(env, dst, out, analysis)


# --- rendering ---------------------------------------------------------------

def well_formed(func):
    """Every bound var id below the frame, every successor a known label."""
    for row in range(len(func.instr) // 8):
        at = row * 8
        if func.instr[at] in (OP_OTHER, OP_JUMP, OP_BRANCH, OP_SWITCH,
                              OP_BOUNDS):
            continue
        if not (0 <= func.instr[at + 1] < func.frame):
            return False
    return all(label >= 0 for label in func.succ)


def render(func):
    lines = ["%d %d %d %d %d %d" % (
        func.frame, len(func.params), len(func.labels),
        len(func.succ), len(func.phi) // 3, len(func.instr) // 8)]
    if func.params:
        lines.append(" ".join("%d %d" % pair
                              for pair in zip(func.params, func.param_types)))
    if func.succ:
        lines.append(" ".join(str(s) for s in func.succ))
    for i in range(0, len(func.phi), 3):
        lines.append(" ".join(str(v) for v in func.phi[i:i + 3]))
    for i in range(len(func.labels)):
        lines.append("%d %d %d %d %d" % (
            func.labels[i], func.succ_base[i], func.succ_count[i],
            func.instr_base[i], func.instr_count[i]))
    for i in range(0, len(func.instr), 8):
        lines.append(" ".join(str(v) for v in func.instr[i:i + 8]))
    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    out_path = argv[1]
    budget = int(argv[2])
    sources = argv[3:]

    types = Types()
    seen = set()
    skipped = 0
    kept = []
    rendered = []
    total = 0

    for source in sources:
        for params_text, frame, blocks in parse_dump(source):
            key = "%s|%d|%s" % (params_text, frame, "\n".join(
                name + "\n" + "\n".join(lines) for name, lines in blocks))
            if key in seen:
                continue
            seen.add(key)
            func = encode_function(params_text, frame, blocks, types)
            if func is None:
                continue
            if not well_formed(func):
                # A dumped function's var ids are dense below its frame (the
                # lowerer's next-var counter). Anything else is a parse of text
                # that only looked like IR; drop it rather than analyse it.
                skipped += 1
                continue
            text = render(func)
            kept.append(func)
            rendered.append(text)
            total += len(text)

    stride = 1
    while total // stride > budget:
        stride += 1
    chunks = rendered[::stride]
    picked = kept[::stride]

    analysis = Analysis(types.rows)
    consts = 0
    dead = 0
    sweeps = 0
    subs = 0
    branches = 0
    dropped = 0
    blocks = 0
    instrs = 0
    top_sweeps = 0
    for func in picked:
        one, two, three, four, five, six = analyse(func, analysis)
        consts += one
        dead += two
        sweeps += three
        subs += four
        branches += five
        dropped += six
        top_sweeps = max(top_sweeps, three)
        blocks += len(func.labels)
        instrs += len(func.instr) // 8

    with open(out_path, "w", encoding="ascii", newline="\n") as out:
        out.write("# benchmarks/sccp_lattice corpus v1\n")
        out.write("# sources: %s\n" % " ".join(sources))
        out.write("# stride: 1 in every %d deduplicated functions\n" % stride)
        out.write("# ntypes, then per type: class width\n")
        out.write("# then the self-check row, from this exporter's own SCCP:\n")
        out.write("#   expected-consts expected-dead-blocks"
                  " expected-substitutions expected-folded-branches"
                  " expected-dropped-bounds-checks\n")
        out.write("# then nfuncs, then per function:"
                  " frame nparams nblocks nsucc nphi ninstr,\n")
        out.write("#   nparams 'var type' pairs, nsucc successor labels,"
                  " nphi 'pred kind value' rows,\n")
        out.write("#   nblocks 'label succ-base succ-count instr-base"
                  " instr-count' rows,\n")
        out.write("#   ninstr 'op dst ty ty2 a a-kind b b-kind' rows\n")
        out.write("%d\n" % len(types.rows))
        for klass, width in types.rows:
            out.write("%d %d\n" % (klass, width))
        out.write("%d %d %d %d %d\n"
                  % (consts, dead, subs, branches, dropped))
        out.write("%d\n" % len(chunks))
        for text in chunks:
            out.write(text)

    sys.stderr.write(
        "functions=%d blocks=%d instructions=%d types=%d stride=%d "
        "skipped=%d\n"
        "consts=%d dead=%d sweeps=%d max-sweeps=%d subs=%d branches=%d "
        "dropped=%d\n"
        % (len(chunks), blocks, instrs, len(types.rows), stride, skipped,
           consts, dead, sweeps, top_sweeps, subs, branches, dropped))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
