;; compiler_load_decls_nil_smoke.tl - Regression for #3172.
(import stdlib.vector)
(import "../compiler_load.tl")

(define (main) : i64
  (match (compiler-load-decls-with-module-and-roots-cfg-root
    AstDeclNil
    "src/tests/compiler_load_decls_nil_smoke.tl"
    ""
    ""
    (sym-i64-empty)
    (vector.string-vec-new)
    "src/tests"
    (compiler-cfg-empty))
    [(ResultCompilerLoadWithPaths.Ok _ _ _ _) 42]
    [(ResultCompilerLoadWithPaths.Err _) 1]))