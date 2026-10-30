(define (leak [seed : (& phase str)]) : (Tuple (& phase str) i64)
  (with-arena
    phase
    (let
      [r : (& phase str) seed]
      (tuple r 1))))

(define (main) : i64
  0)