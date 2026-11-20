;; #8985: a call result in an arena is tagged with it, fixed arrays included.
(import stdlib.arena)
(import stdlib.string)

(define (mk2) : (Array String 2)
  (array (string.int->string 42) (string.int->string 42)))

(define (keep) : (Array String 2)
  (with-arena r (mk2)))

(define (main) : i64
  (let
    [k (keep)]
    (+ 40 (string.string-length (& (array-ref k 0))))))