;; The complete store matrix lives in store_operand_exits.tl. Retain the
;; tail-call borrowed-argument shape, which needs call-local writeback support.
(import stdlib.test)

(define (reference-store [p : (&mut p i64)]) : i64
  (set! (deref p) (return 42))
  1)

(define (returning-store) : i64
  (let
    [n : i64 1]
    (reference-store (&mut n))))

(define (main) : i64
  (test.assert-i64-eq (returning-store) 42 "tail reference store exits")
  42)