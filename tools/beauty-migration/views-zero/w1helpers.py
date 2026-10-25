#!/usr/bin/env python3
"""w1helpers.py: the three remaining Copy-typed uses of the per-type view helpers (their argument is a
borrowed place, so the census could not type it), then delete the helper definitions that no longer
have a use: ctfe-env-shared-view, sym-i64-shared-view, spec-template-env-shared-view,
spec-subst-shared-view, spec-type-subst-shared-view and spec-value-subst-shared-view."""
ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"


def edit(rel, old, new):
    path = f"{ROOT}/{rel}"
    s = open(path).read()
    assert s.count(old) == 1, (rel, old[:60], s.count(old))
    open(path, "w").write(s.replace(old, new))


edit("src/compiler_load.tl",
     "(compiler-load-cfg-key-copy (sym_i64_env.sym-i64-shared-view (& key.cfgs)))",
     "(compiler-load-cfg-key-copy key.cfgs)")
edit("src/compiler_load.tl",
     "  (sym_i64_env.sym-i64-shared-view (& (array-ref observer.member-sets index))))",
     "  (array-ref observer.member-sets index))")
edit("src/compiler_specialize.tl",
     "                            (spec-type-subst-shared-view (& type-subs))\n",
     "                            type-subs\n")
edit("src/sym_i64_env.tl",
     ";; Persistent environment snapshots are scalar handles into append-only arena\n"
     ";; storage. Copying the two scalar fields preserves the snapshot head without\n"
     ";; duplicating any owned aggregate.\n"
     "(define (sym-i64-shared-view [e : (& e SymI64Env)]) : SymI64Env\n"
     "  (SymI64Env e.store-address e.head 0))\n\n", "")
edit("src/compiler_specialize.tl",
     "(define (spec-template-env-shared-view\n"
     "  [templates : (& templates SpecTemplateEnv)]) : SpecTemplateEnv\n"
     "  (SpecTemplateEnv templates.address))\n\n", "")
edit("src/compiler_specialize.tl",
     "(define (spec-subst-shared-view [subs : (& subs SpecSubst)]) : SpecSubst\n"
     "  (SpecSubst\n"
     "    (spec-type-subst-shared-view (& subs.types))\n"
     "    (spec-value-subst-shared-view (& subs.values))))\n\n", "")
edit("src/compiler_specialize.tl",
     "(define (spec-value-subst-shared-view [subs : (& subs SpecValueSubst)]) : SpecValueSubst\n"
     "  (SpecValueSubst subs.slots-address subs.len))\n\n"
     "(define (spec-type-subst-shared-view [subs : (& subs SpecTypeSubst)]) : SpecTypeSubst\n"
     "  (SpecTypeSubst subs.slots-address subs.len))\n\n", "")
edit("src/compiler_ctfe.tl",
     "(define (ctfe-env-shared-view [env : (& env CtfeEnv)]) : CtfeEnv\n"
     "  (let\n"
     "    [cell : (CtfeEnvRef env) (CtfeEnvRef env)]\n"
     "    [address : u64\n"
     "      (unsafe\n"
     "        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]\n"
     "    (unsafe\n"
     "      (ptr-read (int->ptr address : (Ptr CtfeEnv))))))\n\n", "")
print("ok")
