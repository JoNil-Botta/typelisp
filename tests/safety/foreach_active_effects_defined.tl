;: Inside a foreach-active body, colliding writes, writes to bindings declared
;: outside the gang and scalar helper calls with uniform arguments are defined:
;: they run once per active lane, in lane order.
(define (bump [x : i64]) : i64
  (+ x 1))

(define (main) : i64
  (let
    [idx : (Array i64 6) (array 1 1 1 0 0 2)]
    [counts : (Array i64 3) (make-array i64 3)]
    [order : i64 0]
    (begin
      (foreach
        ([i : i64 0 6])
        (foreach-active
          [lane : i64]
          (let
            [bucket : i64 (lane-value (array-ref idx i))]
            (set! (array-ref counts bucket) (bump (array-ref counts bucket)))
            (set! order (+ (* order 10) (lane-value i))))))
      (if (and
        (= (array-ref counts 0) 2)
        (= (array-ref counts 1) 3)
        (= (array-ref counts 2) 1)
        (= order 12345))
        42
        1))))