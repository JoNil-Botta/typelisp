;; Diagnostic-parity fixture for the vector module generator's variadic
;; capability validation. The optional capability must be the bare `core` Var.
(import stdlib.vector)
(import (vector.vector i64 42) as vec)

(define (main) : i64
  (vec.len (vec.new)))