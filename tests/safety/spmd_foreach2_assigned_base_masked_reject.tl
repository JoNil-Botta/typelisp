;: A mutable uniform offset cannot prove a masked row-major destination.
(define (main) : i64
  (let
    [offset : i64 3]
    [out : (Array i64 8) (make-array i64 8)]
    (foreach
      ([y : i64 0 2] [x : i64 0 2])
      (begin
        (if (= (% x 2) 0)
          (set! (array-ref out (+ offset (+ (* y 2) x))) (+ 1 (+ (* y 2) x)))
          unit)
        (foreach-active [lane : i64] (set! offset (- offset 1)))))
    0))