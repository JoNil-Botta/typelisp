;; compiler_typecheck_reflection_smoke.tl - Focused comptime reflection typecheck smoke.
(import compiler_typecheck_tests as tc_tests)
(import compiler_builtin_ids as cbi)

(define (main) : i64
  (cbi.compiler-builtin-initialize-for-parse!)
  (if (tc_tests.compiler-typecheck-reflection-tests-ok?)
    42
    1))