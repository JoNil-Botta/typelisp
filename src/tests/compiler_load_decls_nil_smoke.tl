;; compiler_load_decls_nil_smoke.tl - Regression: loading with an empty
;; starting decl list must succeed.
(import stdlib.vector)
(import (vector String) as svec)
(import "../compiler_load.tl")
(import compiler_builtin_ids as cbi)
(import sym_i64_env)

(define (main) : i64
  (match (compiler-load-decls-with-module-and-roots-cfg-root
    (ast-decl-list-new)
    "src/tests/compiler_load_decls_nil_smoke.tl"
    ""
    ""
    cbi.compiler-builtin-id-fix-empty
    (sym_i64_env.sym-i64-empty)
    (svec.new)
    "src/tests"
    (compiler-cfg-empty))
    [(ResultCompilerLoadWithPaths.Ok _ _ _ _) 42]
    [(ResultCompilerLoadWithPaths.Err _) 1]))