#!/usr/bin/env python3
"""Export the regalloc_greedy corpus: real per-function live intervals, spill
weight inputs, copy hints, ABI argument preferences and clobber points, exactly
as src/compiler_regalloc.tl derives them for its RAGreedy pass.

The compiler cannot dump its own allocator input, so this tool RE-DERIVES it in
Python from the final optimized IR (`--dump-ir` with no stage argument), which
is the IR the liveness pass and the register allocator consume.  Every step
below is a transliteration of a named compiler function:

  liveness (edge-precise)      src/compiler_liveness.tl
      `compiler-live-analyze-function-edge-precise`: per block
      `use_nophi` (upward-exposed non-phi reads), `defs`, successors from the
      terminator, and `phi_out[pred]` from every phi input `(%v, predLabel)`.
      Fixpoint: live_out(B) = phi_out(B) | U live_in(S over succ),
                live_in(B)  = use_nophi(B) | (live_out(B) - defs(B)).
      `compiler-live-instr-seq-fill-after!`: the per-instruction live-AFTER
      sets, walked backwards from live_out with the nophi use ids.

  intervals                    src/compiler_regalloc.tl
      `compiler-reg-live-interval-selection` over that liveness.  Instruction
      points are DOUBLED indices (`point += 2` per instruction, continuing
      across blocks).  Per block, `compiler-reg-live-in-block-point` opens the
      live-in values one point BELOW the block's first instruction; per
      instruction, `compiler-reg-extend-segment-touch!` notes the def and every
      use at `point` (phi inputs included -- the SEGMENT builder is the
      conservative one), then `compiler-reg-extend-segment-after-words!`
      bridges every live-after value across `point`/`point + 1`.
      `compiler-reg-segment-note-point!` closes a segment whenever the new
      point is more than one past the open end, and
      `compiler-reg-segment-flush-var!` appends it.  The coarse hull
      (`starts`/`ends`) is the min/max of the same touches.

  spill weights                src/compiler_regalloc.tl
      `compiler-reg-function-loop-depths` (`compiler-reg-loop-nest-build-seq`:
      DFS back edges, one loop per header, body collected backwards from the
      latches through predecessors, depths saturated at
      `compiler-reg-loop-depth-max` = 8) and
      `compiler-reg-ref-counts-blocks-weighted!`, which adds
      `compiler-reg-loop-depth-weight(depth)` per USE and per DEF, uses counted
      with multiplicity.  The kernel does the rest
      (`compiler-reg-greedy-combine-spill-weights`,
      `compiler-reg-priority-keys!`).

  copy hints                   `compiler-reg-copy-hints-add-move!`: `mov` and
      phi-input pairs, symmetric, first move wins.

  arg prefs                    `compiler-reg-function-arg-prefs`: an outgoing
      integer call argument at position i prefers the SysV argument register
      for that position, recorded as its index in
      `compiler-reg-greedy-integer-pool-for-abi Linux`; then
      `compiler-reg-result-pref-blocks!` biases every scalar call RESULT toward
      %rax (pool index 0).  First wins.

  clobber points               `compiler-reg-direct-call-points-seq` (call and
      tailcall points), the div/mod points and the variable-shift points, all
      as doubled instruction points.

  candidates                   `compiler-reg-candidates` + the
      `compiler-reg-candidate-sort` heapsort: every var with a live interval
      whose type is not float, in (start, var) order.

Corpus format -- whitespace-separated decimal integers, `#` comments to end of
line, so both bench.tl and baseline.c parse it with the same scanner:

    1                       format version
    F                       function count
    SPANS                   exporter's independent total of vars whose interval
                            spans a call point (`compiler-reg-greedy-var-spans-
                            clobber?`), summed over every function; the kernels
                            recompute it and check it
    repeated F times:
      vars nblocks ncand ncall ndiv nshift nseg nrows
      nblocks+1 block start points
      ncand candidate var ids     (candidate order)
      ncall call points
      ndiv  div points
      nshift shift points
      repeated nrows times (only vars that carry a live interval; every other
      var of the function has no interval, weight 0, no hint and no preference):
        var  k  s0 e0 .. s(k-1) e(k-1)  weight  hint  argpref  flags
      (flags bit 0 = parameter root)

Regenerate from the repository root:

    python3 benchmarks/regalloc_greedy/tools/export_intervals.py \\
        benchmarks/regalloc_greedy/data/intervals.txt 3000000 \\
        target/bench6-dumps/aug25/compiler_load.final.opt2.ir \\
        target/bench6-dumps/aug25/compiler_regalloc.final.opt2.ir
"""

import re
import sys

VERSION = 1
DEPTH_MAX = 8

FUNCTION_RE = re.compile(r"^function (@[^(]*)\((.*)\) -> .* vars (\d+) \{$")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.$]*):$")
DEF_RE = re.compile(r"^  %(\d+) = (\S+)")
VAR_RE = re.compile(r"%(\d+)")
PARAM_RE = re.compile(r"%(\d+):")
PHI_INPUT_RE = re.compile(r"\[(%\d+|[^,\]]+), ([A-Za-z_][A-Za-z0-9_.$]*)\]")
SWITCH_CASE_RE = re.compile(r"(?:-?\d+):([A-Za-z_][A-Za-z0-9_.$]*)")
TYPE_RE = re.compile(r" : ([^:]*)$")

# compiler-reg-greedy-integer-pool-for-abi Linux (rbp pool disabled).
POOL = ["rax", "rsi", "rdi", "r9", "rcx", "rdx", "r10", "r11", "r8",
        "r12", "r13", "r14", "r15", "rbx"]
# cabi.compiler-abi-gp-arg-register-id Linux, positions 0..5.
SYSV_ARG = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]
POOL_INDEX = dict((name, i) for i, name in enumerate(POOL))

FLOAT_TYPES = ("f32", "f64")

# Instructions whose lowering clobbers caller-saved registers (kind 6).
CALL_OPS = ("call", "tailcall", "syscall")
DIV_OPS = ("div", "mod", "safe_div", "safe_mod", "udiv", "umod")
SHIFT_OPS = ("shl", "shr", "sar", "ashr")


def loop_depth_weight(depth):
    """compiler-reg-loop-depth-weight."""
    if depth <= 0:
        return 1
    if depth >= 8:
        return 256
    return 1 << depth


class Instr(object):
    __slots__ = ("op", "dst", "uses", "phi_inputs", "succ", "ty", "args")

    def __init__(self):
        self.op = ""
        self.dst = -1
        self.uses = []          # with multiplicity, in textual order
        self.phi_inputs = []    # (var, predecessor label)
        self.succ = []
        self.ty = ""
        self.args = []          # integer call-argument vars, in ABI order


class Function(object):
    __slots__ = ("name", "params", "vars", "labels", "blocks")

    def __init__(self, name, params, nvars):
        self.name = name
        self.params = params
        self.vars = nvars
        self.labels = []
        self.blocks = []        # list of [Instr]


def terminator_successors(body):
    if body.startswith("jump "):
        return [body[5:].strip()]
    if body.startswith("branch "):
        return [p.strip() for p in body[7:].split(",")[1:]]
    if body.startswith("switch "):
        targets = SWITCH_CASE_RE.findall(body)
        tail = body.rsplit(" default ", 1)
        if len(tail) == 2:
            targets.append(tail[1].strip())
        return targets
    return []


def call_arg_vars(rest):
    """Integer argument vars of a call, in ABI argument order."""
    open_paren = rest.find("(")
    close_paren = rest.rfind(")")
    if open_paren < 0 or close_paren < open_paren:
        return []
    inner = rest[open_paren + 1:close_paren]
    out = []
    for piece in inner.split(","):
        piece = piece.strip()
        match = VAR_RE.fullmatch(piece)
        out.append(int(match.group(1)) if match else -1)
    return out


def parse_functions(text):
    lines = text.split("\n")
    i = 0
    n = len(lines)
    while i < n:
        head = FUNCTION_RE.match(lines[i])
        if not head:
            i += 1
            continue
        params = [int(v) for v in PARAM_RE.findall(head.group(2))]
        func = Function(head.group(1), params, int(head.group(3)))
        current = None
        i += 1
        while i < n and lines[i] != "}":
            line = lines[i]
            label = LABEL_RE.match(line)
            if label:
                func.labels.append(label.group(1))
                current = []
                func.blocks.append(current)
                i += 1
                continue
            if not line.startswith("  ") or current is None:
                i += 1
                continue
            instr = Instr()
            defm = DEF_RE.match(line)
            if defm:
                instr.dst = int(defm.group(1))
                instr.op = defm.group(2)
                rest = line[defm.end():]
            else:
                body = line.strip()
                instr.op = body.split(" ", 1)[0]
                rest = body[len(instr.op):]
            instr.uses = [int(v) for v in VAR_RE.findall(rest)]
            if instr.op == "phi":
                instr.phi_inputs = [
                    (int(value[1:]), pred)
                    for value, pred in PHI_INPUT_RE.findall(rest)
                    if value.startswith("%")
                ]
            ty = TYPE_RE.search(line)
            instr.ty = ty.group(1).strip() if ty else ""
            if instr.op in ("call", "tailcall"):
                instr.args = call_arg_vars(rest)
            instr.succ = terminator_successors(line.strip())
            current.append(instr)
            i += 1
        i += 1
        if func.blocks:
            yield func


def block_liveness(func):
    """compiler-live-analyze-function-edge-precise, block level."""
    index_of = dict((label, slot) for slot, label in enumerate(func.labels))
    count = len(func.blocks)
    use = [set() for _ in range(count)]
    defs = [set() for _ in range(count)]
    succ = [[] for _ in range(count)]
    phi_out = [set() for _ in range(count)]
    for b, instrs in enumerate(func.blocks):
        seen_defs = set()
        for instr in instrs:
            if instr.op != "phi":
                for v in instr.uses:
                    if v not in seen_defs:
                        use[b].add(v)
            else:
                for v, pred in instr.phi_inputs:
                    slot = index_of.get(pred, -1)
                    if slot >= 0:
                        phi_out[slot].add(v)
            if instr.dst >= 0:
                seen_defs.add(instr.dst)
                defs[b].add(instr.dst)
            for target in instr.succ:
                slot = index_of.get(target, -1)
                if slot >= 0 and slot not in succ[b]:
                    succ[b].append(slot)

    preds = [[] for _ in range(count)]
    for b in range(count):
        for s in succ[b]:
            preds[s].append(b)

    live_in = [set() for _ in range(count)]
    live_out = [set() for _ in range(count)]
    pending = list(range(count - 1, -1, -1))
    on_queue = [True] * count
    while pending:
        b = pending.pop()
        on_queue[b] = False
        out = set(phi_out[b])
        for s in succ[b]:
            out |= live_in[s]
        inn = use[b] | (out - defs[b])
        if out != live_out[b] or inn != live_in[b]:
            live_out[b] = out
            live_in[b] = inn
            for p in preds[b]:
                if not on_queue[p]:
                    on_queue[p] = True
                    pending.append(p)
    return live_in, live_out, succ, preds


def instr_live_after(instrs, live_out):
    """compiler-live-instr-seq-fill-after! (edge-precise use ids)."""
    after = [None] * len(instrs)
    live = set(live_out)
    for index in range(len(instrs) - 1, -1, -1):
        after[index] = frozenset(live)
        instr = instrs[index]
        if instr.dst >= 0:
            live.discard(instr.dst)
        if instr.op != "phi":
            live.update(instr.uses)
    return after


class Segments(object):
    """compiler-reg-segment-note-point! / -flush-var! over one function."""

    def __init__(self, nvars):
        self.rows = [[] for _ in range(nvars)]
        self.open_start = [-1] * nvars
        self.open_end = [-1] * nvars
        self.start = [-1] * nvars
        self.end = [-1] * nvars
        self.n = nvars

    def extend(self, var, point):
        if var < 0 or var >= self.n:
            return
        if self.start[var] < 0:
            self.start[var] = point
            self.end[var] = point
        else:
            if point < self.start[var]:
                self.start[var] = point
            if point > self.end[var]:
                self.end[var] = point

    def note(self, var, point):
        if var < 0 or var >= self.n:
            return
        if self.open_start[var] < 0:
            self.open_start[var] = point
            self.open_end[var] = point
        elif point <= self.open_end[var] + 1:
            if point > self.open_end[var]:
                self.open_end[var] = point
        else:
            self.flush(var)
            self.open_start[var] = point
            self.open_end[var] = point

    def touch(self, var, point):
        self.extend(var, point)
        self.note(var, point)

    def after(self, var, point):
        """The live-after bridge: note point/point+1, hull extended to point+1."""
        if var < 0 or var >= self.n:
            return
        nxt = point + 1
        if self.open_start[var] < 0:
            self.open_start[var] = point
            self.open_end[var] = nxt
        elif point <= self.open_end[var] + 1:
            if nxt > self.open_end[var]:
                self.open_end[var] = nxt
        else:
            self.flush(var)
            self.open_start[var] = point
            self.open_end[var] = nxt
        self.extend(var, nxt)

    def flush(self, var):
        if self.open_start[var] < 0:
            return
        self.rows[var].append((self.open_start[var], self.open_end[var]))
        self.open_start[var] = -1
        self.open_end[var] = -1

    def flush_all(self):
        for var in range(self.n):
            self.flush(var)


def build_intervals(func, live_in, live_out):
    """compiler-reg-live-interval-selection: segments, hull, block points."""
    segs = Segments(func.vars)
    points = []
    point = 0
    for b, instrs in enumerate(func.blocks):
        points.append(point)
        live_point = point - 1 if point > 0 else 0
        for v in sorted(live_in[b]):
            segs.touch(v, live_point)
        after = instr_live_after(instrs, live_out[b])
        for index, instr in enumerate(instrs):
            segs.touch(instr.dst, point)
            for v in instr.uses:
                segs.touch(v, point)
            for v in sorted(after[index]):
                segs.after(v, point)
            point += 2
    points.append(point)
    segs.flush_all()
    return segs, points


def clobber_points(func):
    calls = []
    divs = []
    shifts = []
    point = 0
    for instrs in func.blocks:
        for instr in instrs:
            if instr.op in CALL_OPS:
                calls.append(point)
            elif instr.op in DIV_OPS:
                divs.append(point)
            elif instr.op in SHIFT_OPS:
                # Only a variable shift count clobbers %rcx.
                if len(instr.uses) >= 2:
                    shifts.append(point)
            point += 2
    return calls, divs, shifts


def loop_depths(func, succ, preds):
    """compiler-reg-function-loop-depths."""
    count = len(func.blocks)
    depths = [0] * count
    if count < 1:
        return depths
    # compiler-reg-loop-nest-back-edges!: DFS from block 0, an edge into a node
    # still on the stack is a back edge.
    state = [0] * count           # 0 white, 1 gray, 2 black
    back = []
    stack = [(0, 0)]
    state[0] = 1
    while stack:
        node, cursor = stack[-1]
        if cursor < len(succ[node]):
            stack[-1] = (node, cursor + 1)
            nxt = succ[node][cursor]
            if state[nxt] == 0:
                state[nxt] = 1
                stack.append((nxt, 0))
            elif state[nxt] == 1:
                back.append((node, nxt))
        else:
            state[node] = 2
            stack.pop()
    if not back:
        return depths
    headers = []
    seen = set()
    for _, target in back:
        if target not in seen:
            seen.add(target)
            headers.append(target)
    for header in headers:
        # compiler-reg-loop-nest-header-members!: seed with every latch of this
        # header, then walk predecessors backwards (the header is never
        # expanded).
        stamp = set([header])
        work = [source for source, target in back if target == header
                and source not in stamp]
        members = []
        for latch in work:
            if latch not in stamp:
                stamp.add(latch)
                members.append(latch)
        pending = list(members)
        while pending:
            node = pending.pop()
            for p in preds[node]:
                if p not in stamp:
                    stamp.add(p)
                    members.append(p)
                    pending.append(p)
        if depths[header] < DEPTH_MAX:
            depths[header] += 1
        for block in members:
            if depths[block] < DEPTH_MAX:
                depths[block] += 1
    return depths


def spill_weights(func, depths):
    """compiler-reg-ref-counts-blocks-weighted!."""
    counts = [0] * func.vars
    for b, instrs in enumerate(func.blocks):
        weight = loop_depth_weight(depths[b])
        for instr in instrs:
            for v in instr.uses:
                if 0 <= v < func.vars:
                    counts[v] += weight
            if 0 <= instr.dst < func.vars:
                counts[instr.dst] += weight
    return counts


def copy_hints(func):
    """compiler-reg-function-copy-hints (mov and phi-input pairs, first wins)."""
    hints = [-1] * func.vars
    for instrs in func.blocks:
        for instr in instrs:
            pairs = []
            if instr.op == "mov" and instr.uses:
                pairs.append((instr.uses[0], instr.dst))
            elif instr.op == "phi":
                for v, _ in instr.phi_inputs:
                    pairs.append((v, instr.dst))
            for src, dst in pairs:
                if src == dst or src < 0 or dst < 0:
                    continue
                if src >= func.vars or dst >= func.vars:
                    continue
                if hints[src] < 0:
                    hints[src] = dst
                if hints[dst] < 0:
                    hints[dst] = src
    return hints


def arg_prefs(func):
    """compiler-reg-function-arg-prefs + compiler-reg-result-pref-blocks!."""
    prefs = [-1] * func.vars
    rax = POOL_INDEX["rax"]
    for instrs in func.blocks:
        for instr in instrs:
            if instr.op not in ("call", "tailcall"):
                continue
            for pos, var in enumerate(instr.args):
                if pos >= len(SYSV_ARG) or var < 0 or var >= func.vars:
                    continue
                if prefs[var] < 0:
                    prefs[var] = POOL_INDEX[SYSV_ARG[pos]]
    for instrs in func.blocks:
        for instr in instrs:
            if instr.op not in ("call", "syscall"):
                continue
            if instr.ty in FLOAT_TYPES:
                continue
            if 0 <= instr.dst < func.vars and prefs[instr.dst] < 0:
                prefs[instr.dst] = rax
    return prefs


def float_vars(func):
    out = set()
    for instrs in func.blocks:
        for instr in instrs:
            if instr.dst >= 0 and instr.ty in FLOAT_TYPES:
                out.add(instr.dst)
    return out


def call_set_in_range(points, lo, hi):
    """compiler-reg-call-set-in-range?: any point c with lo < c < hi."""
    for c in points:
        if lo < c < hi:
            return True
    return False


def spans_clobber(rows, hull_start, hull_end, calls):
    """compiler-reg-greedy-var-spans-clobber? for the call-point set."""
    if hull_start < 0:
        return True
    if not call_set_in_range(calls, hull_start, hull_end):
        return False
    if not rows:
        return True
    for start, end in rows:
        low = start if start == hull_start else start - 1
        if call_set_in_range(calls, low, end):
            return True
    return False


def encode_function(func, out):
    live_in, live_out, succ, preds = block_liveness(func)
    segs, points = build_intervals(func, live_in, live_out)
    calls, divs, shifts = clobber_points(func)
    depths = loop_depths(func, succ, preds)
    weights = spill_weights(func, depths)
    hints = copy_hints(func)
    prefs = arg_prefs(func)
    floats = float_vars(func)
    params = set(func.params)

    candidates = sorted(
        (segs.start[v], v)
        for v in range(func.vars)
        if segs.start[v] >= 0 and v not in floats
    )
    total_segments = sum(len(segs.rows[v]) for v in range(func.vars))
    spans = sum(
        1 for v in range(func.vars)
        if segs.start[v] >= 0
        and spans_clobber(segs.rows[v], segs.start[v], segs.end[v], calls)
    )

    live_vars = [v for v in range(func.vars) if segs.start[v] >= 0]
    out.append("%d %d %d %d %d %d %d %d" % (
        func.vars, len(func.blocks), len(candidates),
        len(calls), len(divs), len(shifts), total_segments, len(live_vars)))
    out.append(" ".join(str(p) for p in points))
    out.append(" ".join(str(v) for _, v in candidates) or "")
    out.append(" ".join(str(p) for p in calls) or "")
    out.append(" ".join(str(p) for p in divs) or "")
    out.append(" ".join(str(p) for p in shifts) or "")
    for v in live_vars:
        rows = segs.rows[v]
        flat = [str(v), str(len(rows))]
        for start, end in rows:
            flat.append(str(start))
            flat.append(str(end))
        flat.append(str(weights[v]))
        flat.append(str(hints[v]))
        flat.append(str(prefs[v]))
        flat.append("1" if v in params else "0")
        out.append(" ".join(flat))
    return spans, total_segments, len(candidates)


def render(func):
    """Body text used to deduplicate repeated snapshots of one function."""
    parts = [func.name, str(func.vars), ";".join(func.params and
                                                 [str(p) for p in func.params])]
    for label, instrs in zip(func.labels, func.blocks):
        parts.append(label)
        for instr in instrs:
            parts.append("%s|%d|%s|%s" % (
                instr.op, instr.dst,
                ",".join(str(u) for u in instr.uses),
                ",".join(instr.succ)))
    return "\n".join(parts)


def main(argv):
    argv = list(argv)
    want_verify = "--verify" in argv
    if want_verify:
        argv.remove("--verify")
    if len(argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    out_path = argv[1]
    budget = int(argv[2])
    dumps = argv[3:]

    functions = []
    seen = set()
    for dump in dumps:
        with open(dump, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        for func in parse_functions(text):
            key = render(func)
            if key in seen:
                continue
            seen.add(key)
            functions.append(func)

    # Encode everything once, then stride the encoded stream to the byte budget
    # so the corpus samples the whole self-compile instead of truncating to its
    # stdlib-heavy prefix.
    encoded = []
    for func in functions:
        body = []
        spans, nseg, ncand = encode_function(func, body)
        blob = "\n".join(body)
        encoded.append((blob, spans, nseg, ncand, func))

    stride = 1
    while True:
        picked = encoded[::stride]
        size = sum(len(blob) + 1 for blob, _, _, _, _ in picked) + 64
        if size <= budget:
            break
        stride += 1

    spans_total = sum(entry[1] for entry in picked)
    lines = [
        "# benchmarks/regalloc_greedy corpus v1",
        "# sources: %s" % " ".join(dumps),
        "# format: see benchmarks/regalloc_greedy/tools/export_intervals.py",
        str(VERSION),
        str(len(picked)),
        str(spans_total),
    ]
    for blob, _, _, _, _ in picked:
        lines.append(blob)
    payload = ("\n".join(lines) + "\n").encode("ascii")
    with open(out_path, "wb") as handle:
        handle.write(payload)

    vars_max = max(entry[4].vars for entry in picked)
    segs_max = max(entry[2] for entry in picked)
    point_max = max(2 * sum(len(b) for b in entry[4].blocks) for entry in picked)
    cand_total = sum(entry[3] for entry in picked)
    seg_total = sum(entry[2] for entry in picked)
    call_total = sum(len(clobber_points(entry[4])[0]) for entry in picked)
    sys.stderr.write(
        "wrote %s: %d bytes\n"
        "  dumps: %s\n"
        "  functions parsed: %d  deduplicated: %d  stride: %d  shipped: %d\n"
        "  candidate vars: %d  segments: %d  call points: %d\n"
        "  spans-call total (self-check): %d\n"
        "  max vars/function: %d  max segments/function: %d  max point: %d\n"
        % (out_path, len(payload), " ".join(dumps), len(seen), len(encoded),
           stride, len(picked), cand_total, seg_total, call_total,
           spans_total, vars_max, segs_max, point_max))
    if want_verify:
        verify(out_path)
    return 0




# ---------------------------------------------------------------------------
# --verify: a Python port of the same greedy both kernels run, executed over
# the corpus file that was just written.  It re-reads the emitted bytes with
# the same trivial integer scanner the kernels use, so it checks the shipped
# artifact rather than the encoder's in-memory state, and prints the totals the
# README records (assignments, spills, RS_Split marks, evictions, conflicts).

POOL_COUNT = 14
CALLER_SAVED_COUNT = 9
BAND_SPAN = 2097152
LOCAL_SPAN = 1048576
TIE_SPAN = 1024
WEIGHT_CAP = 1073741824
EVICT_CAP = 4
EVICT_INF = 35184372088832
REG_ID = {"rax": 0, "rcx": 1, "rdx": 2, "rbx": 3, "rsi": 6, "rdi": 7,
          "r8": 8, "r9": 9, "r10": 10, "r11": 11, "r12": 12, "r13": 13,
          "r14": 14, "r15": 15}
POOL_REG = [REG_ID[name] for name in POOL]
POOL_OF = dict((reg, i) for i, reg in enumerate(POOL_REG))


def scan_ints(text):
    """The corpus scanner both kernels use: decimals, `#` to end of line."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "#":
            while i < n and text[i] != "\n":
                i += 1
        elif ch.isdigit() or ch == "-":
            negative = ch == "-"
            if negative:
                i += 1
            value = 0
            while i < n and text[i].isdigit():
                value = value * 10 + (ord(text[i]) - 48)
                i += 1
            out.append(-value if negative else value)
        else:
            i += 1
    return out


def read_corpus(path):
    with open(path, "r", encoding="ascii") as handle:
        tokens = scan_ints(handle.read())
    at = 1                                   # skip the format version
    count = tokens[at]
    at += 1
    spans_total = tokens[at]
    at += 1
    records = []
    for _ in range(count):
        nvars = tokens[at]
        nblocks = tokens[at + 1]
        ncand = tokens[at + 2]
        ncall = tokens[at + 3]
        ndiv = tokens[at + 4]
        nshift = tokens[at + 5]
        nrows = tokens[at + 7]
        at += 8
        points = tokens[at:at + nblocks + 1]
        at += nblocks + 1
        cand = tokens[at:at + ncand]
        at += ncand
        calls = tokens[at:at + ncall]
        at += ncall
        divs = tokens[at:at + ndiv]
        at += ndiv
        shifts = tokens[at:at + nshift]
        at += nshift
        rows = [[] for _ in range(nvars)]
        raw = [0] * nvars
        hints = [-1] * nvars
        prefs = [-1] * nvars
        params = [0] * nvars
        for _row in range(nrows):
            var = tokens[at]
            k = tokens[at + 1]
            rows[var] = [(tokens[at + 2 + 2 * s], tokens[at + 3 + 2 * s])
                         for s in range(k)]
            raw[var] = tokens[at + 2 + 2 * k]
            hints[var] = tokens[at + 3 + 2 * k]
            prefs[var] = tokens[at + 4 + 2 * k]
            params[var] = tokens[at + 5 + 2 * k]
            at += 6 + 2 * k
        records.append({
            "vars": nvars, "nblocks": nblocks, "points": points,
            "cand": cand, "calls": calls, "divs": divs, "shifts": shifts,
            "rows": rows, "raw": raw, "hints": hints, "prefs": prefs,
            "params": params,
        })
    return records, spans_total


def seg_overlaps(a, b):
    """compiler-reg-interval-seq-overlaps?."""
    i = 0
    j = 0
    while i < len(a) and j < len(b):
        a_start, a_end = a[i]
        b_start, b_end = b[j]
        if a_end <= b_start and b_start != 0:
            i += 1
        elif b_end <= a_start and a_start != 0:
            j += 1
        else:
            return True
    return False


def block_index_of_point(points, nblocks, point):
    """compiler-reg-block-index-of-point."""
    lo = 0
    hi = nblocks - 1
    best = 0
    while lo <= hi:
        mid = (lo + hi) // 2
        if points[mid] <= point:
            best = mid
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def priority_keys(rec):
    """compiler-reg-greedy-combine-spill-weights + compiler-reg-priority-keys!."""
    nvars = rec["vars"]
    raw = rec["raw"]
    rows = rec["rows"]
    max_raw = max(raw) if raw else 0
    keys = [0] * nvars
    for v in range(nvars):
        r = raw[v]
        d = WEIGHT_CAP if r > WEIGHT_CAP else r
        if max_raw == 0:
            tie = 0
        else:
            scaled = (r * TIE_SPAN) // (max_raw + 1)
            tie = TIE_SPAN - 1 if scaled >= TIE_SPAN else scaled
        keys[v] = d * TIE_SPAN + tie
    for v in range(nvars):
        if rec["nblocks"] < 1 or not rows[v]:
            band = BAND_SPAN - 1
        else:
            s = rows[v][0][0]
            e = rows[v][-1][1]
            if (block_index_of_point(rec["points"], rec["nblocks"], s)
                    == block_index_of_point(rec["points"], rec["nblocks"], e)):
                limit = LOCAL_SPAN - 1
                band = limit - (limit if s > limit else s)
            else:
                band = BAND_SPAN - 1
        keys[v] = keys[v] * BAND_SPAN + band
    return keys


def simulate(rec):
    """compiler-reg-greedy-alloc-all! over one function."""
    import heapq
    nvars = rec["vars"]
    rows = rec["rows"]
    hints = rec["hints"]
    prefs = rec["prefs"]
    params = rec["params"]
    keys = priority_keys(rec)
    residents = [set() for _ in range(POOL_COUNT)]
    home = [-1] * nvars
    present = [0] * nvars
    kind = [0] * nvars
    evict_count = [0] * nvars
    pending = [0] * nvars
    assigned = 0
    spilled = 0
    splits = 0
    evictions = 0

    def interfere(a, b):
        if a == b:
            return True
        if not rows[a] or not rows[b]:
            return True
        return seg_overlaps(rows[a], rows[b])

    def reg_free(var, ridx):
        for other in residents[ridx]:
            if other != var and interfere(var, other):
                return False
        return True

    def interferer_max_capped(var, ridx):
        best = -1
        for other in residents[ridx]:
            if other == var or not interfere(var, other):
                continue
            if evict_count[other] >= EVICT_CAP:
                return EVICT_INF
            weight = keys[other] // BAND_SPAN
            if weight > best:
                best = weight
        return best

    def spans(var, points):
        if not rows[var]:
            return True
        return spans_clobber(rows[var], rows[var][0][0], rows[var][-1][1],
                             points)

    heap = []
    for v in sorted(rec["cand"], key=lambda item: (-keys[item], item)):
        pending[v] = 1
        heap.append((-keys[v], v))
    heapq.heapify(heap)

    while heap:
        _, var = heapq.heappop(heap)
        if pending[var] != 1:
            continue
        pending[var] = 0
        if present[var] == 1:
            continue
        csr_only = spans(var, rec["calls"]) or params[var] == 1
        start_idx = CALLER_SAVED_COUNT if csr_only else 0
        forbidden = set()
        if not csr_only:
            if spans(var, rec["shifts"]):
                forbidden.add(REG_ID["rcx"])
            if spans(var, rec["divs"]):
                forbidden.add(REG_ID["rax"])
                forbidden.add(REG_ID["rdx"])

        chosen = -1
        idx = prefs[var]
        if not csr_only and 0 <= idx < POOL_COUNT:
            if POOL_REG[idx] not in forbidden and reg_free(var, idx):
                chosen = idx
        if chosen < 0:
            nb = hints[var]
            if 0 <= nb < nvars and present[nb] == 1 and kind[nb] == 1:
                r = POOL_REG[home[nb]]
                ridx = POOL_OF[r]
                if (r not in forbidden and ridx >= start_idx
                        and reg_free(var, ridx)):
                    chosen = ridx
        if chosen < 0:
            for ridx in range(start_idx, POOL_COUNT):
                if POOL_REG[ridx] in forbidden:
                    continue
                if reg_free(var, ridx):
                    chosen = ridx
                    break
        if chosen >= 0:
            residents[chosen].add(var)
            home[var] = chosen
            present[var] = 1
            kind[var] = 1
            assigned += 1
            continue

        weight = keys[var] // BAND_SPAN
        ev = -1
        for ridx in range(start_idx, POOL_COUNT):
            m = interferer_max_capped(var, ridx)
            if POOL_REG[ridx] in forbidden:
                continue
            if 0 <= m < weight:
                ev = ridx
                break
        if ev >= 0:
            victims = [o for o in sorted(residents[ev])
                       if o != var and interfere(var, o)]
            for victim in victims:
                residents[ev].discard(victim)
                home[victim] = -1
                present[victim] = 0
                kind[victim] = 0
                pending[victim] = 1
                heapq.heappush(heap, (-keys[victim], victim))
                evict_count[victim] += 1
                evictions += 1
            residents[ev].add(var)
            home[var] = ev
            present[var] = 1
            kind[var] = 1
            assigned += 1
            continue

        present[var] = 1
        kind[var] = 2
        spilled += 1
        if rows[var]:
            splits += 1

    conflicts = 0
    for ridx in range(POOL_COUNT):
        members = sorted(residents[ridx])
        for a in range(len(members)):
            for b in range(a + 1, len(members)):
                if interfere(members[a], members[b]):
                    conflicts += 1
    seen = sum(1 for v in range(nvars) if rows[v] and spans(v, rec["calls"]))
    return assigned, spilled, splits, evictions, conflicts, seen


def verify(path):
    records, spans_total = read_corpus(path)
    totals = [0, 0, 0, 0, 0, 0]
    for rec in records:
        for slot, value in enumerate(simulate(rec)):
            totals[slot] += value
    sys.stderr.write(
        "  python greedy over the shipped corpus (%d functions):\n"
        "    assignments %d  spills %d  RS_Split %d  evictions %d\n"
        "    conflicts %d  spans-call %d (corpus header says %d)\n"
        % (len(records), totals[0], totals[1], totals[2], totals[3],
           totals[4], totals[5], spans_total))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
