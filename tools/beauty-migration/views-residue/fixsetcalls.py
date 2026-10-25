"""fixsetcalls.py: put back main's view arguments at the test calls of tc-inline-field-layout-list-set!."""
R = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/"
p = R + "src/tests/compiler_typecheck_tests.tl"
s = open(p).read()
pairs = [
    ("      (tc_core.tc-inline-field-layout-list-set! fields-a 0 (Field 1101 (I64) 0))]",
     "      (tc_core.tc-inline-field-layout-list-set!\n        (tc_core.tc-global-shared-view fields-a)\n        0\n        (Field 1101 (I64) 0))]"),
    ("      (tc_core.tc-inline-field-layout-list-set! fields-b 0 (Field 2202 (U32) 0))]",
     "      (tc_core.tc-inline-field-layout-list-set!\n        (tc_core.tc-global-shared-view fields-b)\n        0\n        (Field 2202 (U32) 0))]"),
    ("        (tc_core.tc-inline-field-layout-list-set!\n          reused-a\n",
     "        (tc_core.tc-inline-field-layout-list-set!\n          (tc_core.tc-global-shared-view reused-a)\n"),
]
for a, b in pairs:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(p, "w").write(s)
print("ok")
