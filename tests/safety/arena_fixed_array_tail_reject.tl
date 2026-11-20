;; #8985: a fixed array literal at a plain expected type keeps its elements'
;; arena region.
(import stdlib.string)

(define (leak [n : i64]) : (Array String 1)
  (with-arena phase (array (string.int->string n))))

(define (main) : i64
  (let
    [value (leak -5)]
    (string.string-length (array-ref value 0))))