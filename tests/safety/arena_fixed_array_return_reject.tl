;; #8985: as arena_fixed_array_tail_reject, through an early return.
(import stdlib.string)

(define (leak [n : i64]) : (Array String 1)
  (with-arena phase (return (array (string.int->string n))))
  (array ""))

(define (main) : i64
  (let
    [value (leak -5)]
    (string.string-length (array-ref value 0))))