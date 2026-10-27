;; Control (#9297): a lambda returning a borrow of its own by-value parameter
;; keeps the parameter diagnostic.
(define (main) : i64
  (let
    ; Must fail: `(& n)` borrows the lambda's parameter.
    [f
      (lambda ([n : i64]) : (& n i64)
        (& n))]
    (deref (f 42))))