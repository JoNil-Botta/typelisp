(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o (arena.make-atomic)]
    [f
      (lambda () : i64
        (let
          [c (in-arena o (string.append "lambda" "-text"))]
          (string.string-length c)))]
    (+ (f) 31)))