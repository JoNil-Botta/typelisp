(import compiler_surface_ast)
(import compiler_surface_facts)
(import compiler_surface_hydrate)

(define (main) : i64
  (cond
    [(not (= (compiler_surface_ast.surface-ast-selftest-main) 42)) 1]
    [(not (= (compiler_surface_facts.surface-typecheck-facts-selftest-main) 42))
      2]
    [(not
        (= (compiler_surface_hydrate.compiler-surface-hydrate-selftest-main) 42))
      3]
    [else 42]))