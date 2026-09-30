;: Bounds checks still apply inside a serialized body.
(define (main) : i64
  (let
    [table : (Array i64 4) (make-array i64 4)]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active
          [lane : i64]
          (set! (array-ref table (* (lane-value i) 2)) 1)))
      0)))