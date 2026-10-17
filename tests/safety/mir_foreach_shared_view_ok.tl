;; A shared view read in every iteration of a `foreach` body; the owner is
;; read again after the loop.
(define (main) : i64
  (let
    [values : (Array i64 4) (array 2 2 3 20)]
    [out : (Array i64 4) (array 0 0 0 0)]
    [view : (& values (Array i64 4)) (& values)]
    (begin
      (foreach
        ([i : i64 0 4])
        (set! (array-ref out i) (* 2 (array-ref view i))))
      (+ (array-ref out 3) (array-ref values 0)))))