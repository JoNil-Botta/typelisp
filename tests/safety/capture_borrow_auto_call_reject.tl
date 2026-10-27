;; A capture auto-borrowed into a call whose result carries the argument's
;; lifetime, and that result returned (#9297).
(define (same [r : (& r i64)]) : (& r i64)
  r)

(define (main) : i64
  (let
    [x : i64 42]
    ; Must fail: `x` is lent as a borrow of the lambda's copy.
    [f
      (lambda () : (& x i64)
        (same x))]
    [r : (& x i64) (f)]
    (deref r)))