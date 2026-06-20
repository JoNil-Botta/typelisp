;: SPEC borrow contract: a loop-body-local immutable borrow can end at its
;: last in-iteration use before a later owner mutation in the same iteration.
(define (take [n : (& n i64)]) : i64
  1)

(define (main [n : i64] [limit : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i limit)
        (let
          [borrowed : (& n i64) (& n)]
          (begin
            (take borrowed)
            (set! n (+ n 1))
            (set! i (+ i 1)))))
      n)))