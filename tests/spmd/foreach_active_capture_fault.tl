(import stdlib.io)

(define (main) : unit
  (let
    [xs : (Array i64 5) (array 1 2 3 4 5)]
    (foreach
      ([r : i64 0 2] [c : i64 0 4])
      (let
        [v : i64 (array-ref xs (+ (* 4 r) c))]
        (foreach-active [lane : i64] (io.println "{}" (lane-value v)))))))