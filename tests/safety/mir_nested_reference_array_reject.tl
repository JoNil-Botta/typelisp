;; An array of arrays of references keeps the referent borrowed while it is used.
(define (main) : i64
  (let
    [x : i64 1]
    [inner : (Array (& x i64) 1) (array (& x))]
    [outer : (Array (Array (& x i64) 1) 1) (array inner)]
    (begin
      (set! x 5)
      (deref (array-ref (array-ref outer 0) 0)))))