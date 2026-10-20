;; In a body checked under a caller identity, a borrow of a local keeps its own
;; type under an annotation, so the borrow check still ties its loan to the
;; binding.
(define (f [a : i64] [p : (& a i64)]) : i64
  (let
    [x : i64 1]
    [y : i64 2]
    [r : (& y i64) (& x)]
    ; Must fail: `r` still borrows `x`.
    (set! x 10)
    (deref r)))

(define (main) : i64
  0)