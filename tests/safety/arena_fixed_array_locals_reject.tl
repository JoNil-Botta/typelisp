;; #8985: a fixed array built from arena locals keeps their region.
(import stdlib.arena)
(import stdlib.string)

(define (keep) : (Array String 2)
  (with-arena
    r
    (let
      [s (string.int->string 1)]
      [u (string.int->string 2)]
      (array s u))))

(define (main) : i64
  (let
    [k (keep)]
    (+ 40 (string.string-length (& (array-ref k 0))))))