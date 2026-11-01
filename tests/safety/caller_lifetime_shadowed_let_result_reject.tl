;; A `let` result typed with a lifetime spelled like one of the `let`'s own
;; bindings is rejected by spelling, as main does and as lowering re-checks it,
;; even when the lifetime is the caller's.
(define (first [p : (& a i64)]) : i64
  (let
    ; Must fail: the inner `let` binds `a` and returns a `(& a i64)`.
    [t
      (tuple
        (let
          [a : i64 1]
          p)
        0)]
    (deref (tuple-ref t 0))))

(define (main) : i64
  0)