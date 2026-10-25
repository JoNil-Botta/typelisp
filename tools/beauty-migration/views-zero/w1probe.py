#!/usr/bin/env python3
"""w1probe.py [--broken]: write src/zz_w1_copy_probe.tl, which uses a by-value parameter of each W1 value
type twice. The typecheck accepts a second by-value use only for a Copy type, so a clean check proves
every type Copy. --broken adds a String control, which must fail with a moved-value error."""
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
TYPES = [
    ("compiler_ctfe", "ctfe", "CtfeEnv"),
    ("compiler_lower", "lower", "CompilerLowerRequest"),
    ("compiler_lower", "lower", "LowerOrScrutinee"),
    ("compiler_sframe_v3", "sframe", "CompilerSframeV3Rule"),
    ("compiler_specialize", "spec", "SpecSubst"),
    ("compiler_specialize", "spec", "SpecTemplateEnv"),
    ("compiler_specialize", "spec", "SpecValueSubst"),
    ("compiler_specialize", "spec", "SpecTypeSubst"),
    ("sym_i64_env", "sym_i64_env", "SymI64Env"),
    ("compiler_typecheck_core", "tc_core", "TcTypeEnv"),
    ("compiler_typecheck_core", "tc_core", "TcContext"),
    ("compiler_typecheck_core", "tc_core", "TcBodyParamWriteFact"),
    ("compiler_typecheck_core", "tc_core", "TcMovePath"),
    ("compiler_typecheck_core", "tc_core", "TcMovedPathFact"),
    ("compiler_typecheck_core", "tc_core", "TcJobState"),
    ("compiler_ast_types", "ast", "AstExprNodePoolState"),
    ("compiler_ast_types", "ast", "AstNodePoolContext"),
    ("read", "reader", "SpannedSexpr"),
]
lines = ["; Temporary W1 probe (never committed): a second by-value use typechecks only for a Copy type.", ""]
for mod, alias in sorted({(m, a) for m, a, _ in TYPES}):
    lines.append(f"(import {mod} as {alias})")
lines.append("")
for i, (_, alias, t) in enumerate(TYPES):
    lines.append(f"(define (w1-copy-probe-{i} [x : {alias}.{t}]) : (Tuple {alias}.{t} {alias}.{t})")
    lines.append("  (tuple x x))")
    lines.append("")
if "--broken" in sys.argv:
    lines.append("(define (w1-copy-probe-broken [x : String]) : (Tuple String String)")
    lines.append("  (tuple x x))")
    lines.append("")
open(ROOT + "/src/zz_w1_copy_probe.tl", "w").write("\n".join(lines))
print(len(TYPES), "types")
