(import stdlib.string)

(define (leak [seed : (& phase str)]) : (Tuple (& phase str) i64)
  (with-arena
    phase
    (let
      [s : String (string.int->string 1)]
      (tuple (& phase s) 1))))

(define (main) : i64
  0)