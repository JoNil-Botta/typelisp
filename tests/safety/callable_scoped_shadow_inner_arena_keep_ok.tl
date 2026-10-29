(define (keep [seed : (& phase str)]) : (Tuple (& phase str) i64)
  (with-arena phase (tuple seed 1)))

(define (main) : i64
  0)