;; #8985: a fixed array of Strings read out of an arena Box keeps the region.
(import stdlib.arena)
(import stdlib.string)

(define (keep) : (Array String 2)
  (with-arena
    r
    (let
      [b : (Box (Array String 2))
        (box (array (string.int->string 42) (string.int->string 42)))]
      (deref b))))

(define (main) : i64
  (let
    [k (keep)]
    (+ 40 (string.string-length (& (array-ref k 0))))))