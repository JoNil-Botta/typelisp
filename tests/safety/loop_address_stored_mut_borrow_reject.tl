(define (main) : i64
  (let
    [x : i64 1]
    [y : i64 0]
    [q (&mut y)]
    [i : i64 0]
    (while (< i 2)
      (when (= i 1) (set! (deref q) 99))
      (set! q (&mut x))
      (+= i 1))
    x))