(import "compiler_intern_state.tl")

(define (main) : i64
  (if (intern-state-isolation-tests-ok?)
    42
    1))