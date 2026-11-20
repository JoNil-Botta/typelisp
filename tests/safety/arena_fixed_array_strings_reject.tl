;; #8985: a fixed array of arena Strings keeps their region.
(import stdlib.arena)
(import stdlib.string)

(define (keep) : (Array String 2)
  (with-arena r (array (string.int->string 42) (string.int->string 42))))

(define (main) : i64
  (let
    [k (keep)]
    (+ 40 (string.string-length (& (array-ref k 0))))))