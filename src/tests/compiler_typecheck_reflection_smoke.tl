;; compiler_typecheck_reflection_smoke.tl - Focused comptime reflection typecheck smoke.
(import "../compiler_typecheck.tl")
(import compiler_builtin_ids as cbi)

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (compiler-typecheck-reflection-tests-ok?)
      42
      1)))