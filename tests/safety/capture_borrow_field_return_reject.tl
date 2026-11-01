;; A borrow of a field of a captured register-resident struct is a borrow of
;; the lambda's copy (#9297).
(defstruct Pair
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [p : Pair (Pair 42 7)]
    ; Must fail: `(& p.x)` borrows the lambda's copy of `p`.
    [g
      (lambda () : (& p i64)
        (& p.x))]
    [r : (& p i64) (g)]
    (deref r)))