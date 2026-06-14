;; compiler_ast_types_smoke.tl - Runnable AST data-shape smoke.
(import "compiler_ast_types.tl")

(define (main) : i64
  (if (= (compiler-ast-smoke) 23)
    42
    1))