(import compiler_surface_tests)

(define (main) : i64
  (cond
    [(not (= (compiler_surface_tests.surface-ast-selftest-main) 42)) 1]
    [(not (= (compiler_surface_tests.surface-typecheck-facts-selftest-main) 42))
      2]
    [(not
        (= (compiler_surface_tests.compiler-surface-hydrate-selftest-main) 42))
      3]
    [else 42]))