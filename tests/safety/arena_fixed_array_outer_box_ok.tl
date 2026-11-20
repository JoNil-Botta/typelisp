;; #8985 control: a fixed array read from a Box outside the arena leaves it.
(import stdlib.arena)
(import stdlib.string)

(define (use [o : (Box (Array String 2))]) : (Array String 2)
  (with-arena r (deref o)))

(define (main) : i64
  (let
    [b : (Box (Array String 2))
      (box (array (string.int->string 42) (string.int->string 42)))]
    (let
      [k (use b)]
      (+ 40 (string.string-length (& (array-ref k 0)))))))