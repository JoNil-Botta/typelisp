;; An active enum tag load has the same checked bounds as a numeric lane.
(defenum Choice
  (Skip)
  (Take i64))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array Choice) (__tl_make-array Choice 5)]
    [sum : i64 0]
    (foreach
      ([i : i64 0 6])
      (match (array-ref xs i)
        [Skip unit]
        [(Take x)
          (foreach-active [lane : i64] (set! sum (+ sum (lane-value x))))]))
    sum))