;; #8985: a with-arena result bound by a plain-typed `let` keeps the region.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [k : (Array String 2)
      (with-arena
        r
        (let
          [b : (Box (Array String 2))
            (box (array (string.int->string 42) (string.int->string 42)))]
          (deref b)))]
    (+ 40 (string.string-length (& (array-ref k 0))))))