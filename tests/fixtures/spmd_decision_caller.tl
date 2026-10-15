(import tests.fixtures.spmd_decision_macros as macros)

(define (from-template) : unit
  (macros.spmd-outer))

(define (from-operand) : unit
  (macros.spmd-pass (foreach ([i : i64 0 0]) unit)))