(define (main) : i64
  (let
    [next : i64 0]
    (foreach
      ([i : i64 0 8])
      (if (= i next)
        (foreach-active [lane : i64] (set! next (+ next 1)))
        unit))
    next))