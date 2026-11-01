;; A nested reference array read before the referent changes, then dead (NLL).
(define (main) : i64
  (let
    [x : i64 1]
    [inner : (Array (& x i64) 1) (array (& x))]
    [outer : (Array (Array (& x i64) 1) 1) (array inner)]
    [v : i64 (deref (array-ref (array-ref outer 0) 0))]
    (begin
      (set! x 41)
      (+ v x))))