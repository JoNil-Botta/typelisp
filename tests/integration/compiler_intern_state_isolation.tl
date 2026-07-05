(import compiler_intern_state)

(define (main) : i64
  (if (compiler_intern_state.intern-state-isolation-tests-ok?)
    42
    1))
