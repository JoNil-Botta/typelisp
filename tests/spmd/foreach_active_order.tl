;; Effects at different sites still complete in logical-index order, even
;; when masked arms and a second serialization share one gang.
(define (loop-order) : bool
  (let
    [work : (Array i64 5) (array 0 2 0 3 1)]
    [trace : i64 0]
    (foreach
      ([i : i64 0 5])
      (while (> (array-ref work i) 0)
        (foreach-active
          [lane : i64]
          (set! trace (+ (* trace 10) (lane-value i))))
        (set! (array-ref work i) (- (array-ref work i) 1))))
    (= trace 113334)))

(define (rows) : bool
  (let
    [trace : i64 0]
    [xs : (Array i64 6) (array 1 2 3 4 5 6)]
    (foreach
      ([r : i64 0 2] [c : i64 0 3])
      (foreach-active
        [lane : i64]
        (set! trace (+ (* trace 10) (lane-value (array-ref xs (+ (* r 3) c)))))))
    (= trace 123456)))

(define (negative-range) : bool
  (let
    [seen : i64 0]
    (foreach
      ([i : i64 -5 4])
      (if (= (% i 2) -1)
        (foreach-active [lane : i64] (set! seen (+ seen (lane-value i))))
        unit))
    (= seen -9)))

(define (endpoints [start : i64] [end : i64] [expected : i64]) : bool
  (let
    [seen : i64 0]
    [ok : bool true]
    (foreach
      ([i : i64 start end])
      (foreach-active
        [lane : i64]
        (set! ok (and ok (= (lane-value i) (+ start seen))))
        (set! seen (+ seen 1))))
    (and ok (= seen expected))))

(define (main) : i64
  (let
    [next : i64 0]
    [ok : bool true]
    (foreach
      ([i : i64 0 9])
      (begin
        (if (= (% i 2) 0)
          (foreach-active
            [lane : i64]
            (set! ok (and ok (= next (* 2 (lane-value i)))))
            (set! next (+ next 1)))
          (foreach-active
            [lane : i64]
            (set! ok (and ok (= next (* 2 (lane-value i)))))
            (set! next (+ next 1))))
        (foreach-active
          [lane : i64]
          (set! ok (and ok (= next (+ 1 (* 2 (lane-value i))))))
          (set! next (+ next 1)))))
    (if (and
      ok
      (= next 18)
      (loop-order)
      (rows)
      (negative-range)
      (endpoints 9223372036854775796 9223372036854775807 11)
      (endpoints -9223372036854775808 -9223372036854775797 11)
      (endpoints 9223372036854775807 -9223372036854775808 0))
      42
      1)))