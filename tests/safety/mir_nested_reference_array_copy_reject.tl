;; An inner array copied out of a nested reference array carries its loans.
(define (main) : i64
  (let
    [x : i64 1]
    [outer : (Array (Array (& x i64) 1) 1) (array (array (& x)))]
    [copy : (Array (& x i64) 1) (array-ref outer 0)]
    (begin
      (set! x 5)
      (deref (array-ref copy 0)))))