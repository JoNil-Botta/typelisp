;; A nested lambda returns a borrow of its capture of the enclosing lambda's
;; by-value parameter (#9297).
(define (main) : i64
  (let
    [f
      (lambda ([n : i64]) : i64
        ; Must fail: `(& n)` borrows the inner lambda's copy of `n`.
        (let
          [g
            (lambda () : (& n i64)
              (& n))]
          (deref (g))))]
    (f 42)))