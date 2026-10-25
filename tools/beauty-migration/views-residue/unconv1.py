"""unconv1.py: undo the B7 conversions inside functions that #9063 and #9071 change."""
R = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/"
p = R + "src/compiler_typecheck_core.tl"
lines = open(p).read().split("\n")


def sub(ln, a, b):
    s = lines[ln - 1]
    assert s.count(a) == 1, (ln, s)
    lines[ln - 1] = s.replace(a, b)


sub(8077, "(& (ast.ast-expr-segment-bases-get expr-bases inner-box)))]",
    "(ast.ast-expr-segment-bases-get expr-bases inner-box))]")
sub(8107, "receiver)]", "(tc-global-shared-view receiver))]")
sub(8117, "[expr : (& ast.AstExpr)]) : i64", "[expr : ast.AstExpr]) : i64")
sub(48955, "[fields : (& TcInlineFieldLayoutList)]", "[fields : TcInlineFieldLayoutList]")
sub(48961, "[fields : (& TcInlineFieldLayoutList)]", "[fields : TcInlineFieldLayoutList]")
sub(49003, "(tc-inline-fields-word-register-class fields 0 -1)",
    "(tc-inline-fields-word-register-class (tc-global-shared-view fields) 0 -1)")
open(p, "w").write("\n".join(lines))
print("ok")
