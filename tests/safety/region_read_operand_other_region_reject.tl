;; A result tagged with one region does not escape into another (#9737).
(define (read-i64 [p : (& p i64)]) : (in p i64)
  (deref p))

; Must fail: the operator result is tagged `p`, not `q`.
(define (bad [p : (& p i64)] [q : (& q i64)] [x : i64]) : (in q i64)
  (+ (read-i64 p) x))

(define (main) : i64
  (let
    [z : i64 3]
    [w : i64 4]
    (bad (& z) (& w) 2)))