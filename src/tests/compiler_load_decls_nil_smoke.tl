;; compiler_load_decls_nil_smoke.tl - Regression: loading with an empty
;; starting decl list must succeed.
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_cfg_core as cfg)
(import compiler_builtin_ids as cbi)
(import sym_i64_env)

(define (main) : i64
  (match (compiler_load.compiler-load-decls-with-module-and-roots-cfg-root
    (ast.ast-decl-list-new)
    "src/tests/compiler_load_decls_nil_smoke.tl"
    cbi.compiler-builtin-id-fix-empty
    cbi.compiler-builtin-id-fix-empty
    ""
    cbi.compiler-builtin-id-fix-empty
    ""
    cbi.compiler-builtin-id-fix-empty
    (sym_i64_env.sym-i64-empty)
    (svec.new)
    "src/tests"
    (cfg.compiler-cfg-empty))
    [(compiler_load.ResultCompilerLoadWithPaths.Ok _ _ _ _) 42]
    [(compiler_load.ResultCompilerLoadWithPaths.Err _) 1]))