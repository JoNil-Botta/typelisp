;; #8985 control: a fixed array rooted outside the arena leaves it.
(import stdlib.arena)
(import stdlib.string)

(define (use [o : (Array String 2)]) : (Array String 2)
  (with-arena r o))

(define (main) : i64
  (let
    [k (use (array (string.int->string 42) (string.int->string 42)))]
    (+ 40 (string.string-length (& (array-ref k 0))))))