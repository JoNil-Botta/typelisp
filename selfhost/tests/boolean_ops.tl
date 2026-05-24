(let
  ((x 0))
  (begin
    (while (and (< x 6) (not (= x 6)))
      (set! x (+ x 1)))
    (if (and (or (= x 6) 0) (not (and 2 0)))
      42
      1)))