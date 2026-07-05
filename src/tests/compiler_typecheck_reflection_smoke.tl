;; compiler_typecheck_reflection_smoke.tl - Focused comptime reflection typecheck smoke.
(import "../compiler_typecheck.tl")

(define (main) : i64
  (if (compiler-typecheck-reflection-tests-ok?)
    42
    1))