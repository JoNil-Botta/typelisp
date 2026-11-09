;; The operand conversion keeps the underlying type: an `f64` name does not
;; become an `(in p i64)` operand (#9737).
(define (read-i64 [p : (& p i64)]) : (in p i64)
  (deref p))

; Must fail: the operands are `i64` and `f64`.
(define (bad [p : (& p i64)] [x : f64]) : i64
  (if (> (+ (read-i64 p) x) 1)
    42
    7))

(define (main) : i64
  (let
    [z : i64 3]
    (bad (& z) 2.0)))