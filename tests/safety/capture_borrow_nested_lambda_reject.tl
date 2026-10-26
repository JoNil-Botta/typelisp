;; A nested lambda returns a borrow of its capture of an enclosing lambda's
;; capture (#9297).
(define (main) : i64
  (let
    [x : i64 42]
    [f
      (lambda () : i64
        ; Must fail: `(& x)` borrows the inner lambda's copy of `x`.
        (let
          [g
            (lambda () : (& x i64)
              (& x))]
          (deref (g))))]
    (f)))