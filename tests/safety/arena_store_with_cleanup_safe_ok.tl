;; Control: a non-leaking `with` cleanup inside `with-arena` compiles and runs.
(define (noop [_x : i64]) : unit
  unit)

(define (main) : i64
  (with-arena r (with ([_x 1 noop]) 42)))