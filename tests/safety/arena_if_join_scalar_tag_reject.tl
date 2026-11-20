;; #9061: an `if` joins its arms' arena tags, here on a scalar `(in r i64)`.
(import stdlib.arena)

(define (keep [c : bool]) : i64
  (with-arena
    r
    (let
      [y : (in r i64) 3]
      (if c
        y
        y))))

(define (main) : i64
  (keep true))