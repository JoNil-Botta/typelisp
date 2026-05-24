;; compiler_typecheck_smoke.tl - Runnable smoke for compiler_typecheck.tl (#426).

(import "compiler_typecheck.tl")

(define (main) : i64
  (compiler-typecheck-self-test))