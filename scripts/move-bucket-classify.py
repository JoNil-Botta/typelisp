#!/usr/bin/env python3
"""Classify execution-weighted reg-reg movs in a callgrind profile into the
move-flood buckets a-f described in next_session.md. Joins cg.out (per-address
Ir, inclusive call-cost lines skipped) against an objdump disassembly."""
import re
import sys

cg_path, dis_path = sys.argv[1], sys.argv[2]

# ---- parse cg.out: addr -> self Ir ----
ir = {}
cur = 0
skip_next_cost = False  # the inclusive cost line following a calls= line
total = 0
with open(cg_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        if line.startswith(("fn=", "fl=", "ob=", "cfn=", "cob=", "cfi=", "fi=")):
            # function/file context change; cg keeps a running instr position,
            # but a fresh fn= block always restarts with an absolute 0x position.
            continue
        if line.startswith("calls="):
            skip_next_cost = True
            continue
        if line.startswith(("desc:", "cmd:", "events:", "positions:", "summary:",
                            "totals:", "version:", "creator:", "pid:", "part:")):
            continue
        toks = line.split()
        if len(toks) < 2:
            continue
        pos = toks[0]
        if pos.startswith("0x"):
            cur = int(pos, 16)
        elif pos.startswith("+"):
            cur += int(pos[1:])
        elif pos.startswith("-"):
            cur -= int(pos[1:])
        elif pos == "*":
            pass
        else:
            try:
                cur = int(pos, 16)
            except ValueError:
                continue
        # last token is the Ir cost (events: Ir, positions: instr line -> 2 pos + 1 cost)
        try:
            cost = int(toks[-1])
        except ValueError:
            continue
        if skip_next_cost:
            skip_next_cost = False
            continue
        ir[cur] = ir.get(cur, 0) + cost
        total += cost

# ---- parse disasm: ordered list of (addr, mnemonic, ops) ----
insns = []
line_re = re.compile(r"^\s+([0-9a-f]+):\s+(\S+)\s*(.*)$")
for line in open(dis_path):
    m = line_re.match(line)
    if not m:
        continue
    addr = int(m.group(1), 16)
    mnem = m.group(2)
    rest = m.group(3).strip()
    # strip trailing comment (# ...)
    if "#" in rest:
        rest = rest[:rest.index("#")].strip()
    insns.append((addr, mnem, rest))

idx = {a: i for i, (a, _, _) in enumerate(insns)}

def split_ops(rest):
    """Split operands on the top-level comma (not inside parens)."""
    if not rest:
        return []
    depth = 0
    for i, ch in enumerate(rest):
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        elif ch == ',' and depth == 0:
            return [rest[:i].strip(), rest[i+1:].strip()]
    return [rest.strip()]

def is_reg(op):
    return op.startswith('%') and '(' not in op and '$' not in op

MOV = {"mov", "movq", "movl", "movabs", "movabsq"}
ARG_REGS = {"%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9",
            "%edi", "%esi", "%edx", "%ecx", "%r8d", "%r9d"}
CALLEE_SAVED = {"%r12", "%r13", "%r14", "%r15", "%rbx",
                "%r12d", "%r13d", "%r14d", "%r15d", "%ebx"}
RET_REGS = {"%rax", "%rdx", "%eax", "%edx"}
SCRATCH = {"%r8", "%r10", "%r8d", "%r10d"}
ALU = {"add", "sub", "imul", "and", "or", "xor", "lea", "shl", "shr", "sar",
       "addq", "subq", "imulq", "andq", "orq", "xorq", "leaq", "sal",
       "addl", "subl", "andl", "orl", "xorl"}

def norm(r):
    # crude 32->64 normalization for comparing the same arch register
    m = {"%eax": "%rax", "%ebx": "%rbx", "%ecx": "%rcx", "%edx": "%rdx",
         "%esi": "%rsi", "%edi": "%rdi", "%r8d": "%r8", "%r9d": "%r9",
         "%r10d": "%r10", "%r12d": "%r12", "%r13d": "%r13", "%r14d": "%r14",
         "%r15d": "%r15"}
    return m.get(r, r)

buckets = {k: [0, 0] for k in "abcdef"}  # [static_count, exec_count]
buckets["b1"] = [0, 0]
buckets["unclassified"] = [0, 0]
total_movs = [0, 0]

for i, (addr, mnem, rest) in enumerate(insns):
    if mnem not in MOV:
        continue
    ops = split_ops(rest)
    if len(ops) != 2:
        continue
    src, dst = ops[0], ops[1]
    if not (is_reg(src) and is_reg(dst)):
        continue
    c = ir.get(addr, 0)
    total_movs[0] += 1
    total_movs[1] += c
    nS, nD = norm(src), norm(dst)
    prev = insns[i-1] if i > 0 else None
    nxt = insns[i+1] if i+1 < len(insns) else None

    def classify():
        # (c) call-result: mov %rax/%rdx, <callee-saved> shortly after a call
        if src in RET_REGS and dst in CALLEE_SAVED:
            for j in range(i-1, max(i-4, -1), -1):
                if insns[j][1] == "call":
                    return "c"
                # stop if rax/rdx redefined before our mov by a non-call
                pj = split_ops(insns[j][2])
                if pj and is_reg(pj[-1]) and norm(pj[-1]) == nS:
                    break
        # (d) call-arg: mov reg, <arg reg> shortly before a call
        if dst in ARG_REGS:
            for j in range(i+1, min(i+5, len(insns))):
                if insns[j][1] == "call":
                    return "d"
                pj = split_ops(insns[j][2])
                if pj and is_reg(pj[-1]) and norm(pj[-1]) == nD:
                    break
        # (f) load-into-fixed-home: mov %rax,%rN preceded by mov MEM,%rax
        if nS == "%rax" and prev is not None:
            pops = split_ops(prev[2])
            if (prev[1] in MOV and len(pops) == 2 and not is_reg(pops[0])
                    and is_reg(pops[1]) and norm(pops[1]) == "%rax"
                    and '$' not in pops[0]):
                return "f"
        # (a) two-address tie: mov LHS,DST then op ...,DST (same dst, diff src)
        if nxt is not None and nxt[1] in ALU:
            nops = split_ops(nxt[2])
            if nops and is_reg(nops[-1]) and norm(nops[-1]) == nD:
                if not (len(nops) == 2 and norm(nops[0]) == nS):
                    return "a"
        # (e) scratch staging: mov RHS,%r8/%r10 then op %r8/%r10,DST
        if dst in SCRATCH and nxt is not None:
            nops = split_ops(nxt[2])
            if any(is_reg(o) and norm(o) == nD for o in nops[:-1]):
                return "e"
        return "b"

    k = classify()
    buckets[k][0] += 1
    buckets[k][1] += c
    if k == "b":
        # b1: src read again later in-function before redef
        for j in range(i+1, min(i+40, len(insns))):
            jops = split_ops(insns[j][2])
            if any(o == src or norm(o) == nS for o in jops):
                buckets["b1"][0] += 1
                buckets["b1"][1] += c
                break
            if jops and is_reg(jops[-1]) and norm(jops[-1]) == nS:
                break

print(f"total Ir              = {total}")
print(f"reg-reg movs: static={total_movs[0]:6d}  exec={total_movs[1]:10d}  "
      f"({100.0*total_movs[1]/total:.2f}% of Ir)")
print()
print(f"{'bucket':14s} {'static':>7s} {'exec':>11s} {'%movs':>7s} {'%Ir':>7s}")
tm = total_movs[1] or 1
for k in ["b", "c", "f", "e", "a", "d", "unclassified"]:
    s, e = buckets[k]
    print(f"{k:14s} {s:7d} {e:11d} {100.0*e/tm:6.1f}% {100.0*e/total:6.2f}%")
s, e = buckets["b1"]
print(f"{'  (b1 fanout)':14s} {s:7d} {e:11d} {100.0*e/tm:6.1f}% {100.0*e/total:6.2f}%")
