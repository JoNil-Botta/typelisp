;; #9061: an `if` joins its arms' arena tags, here on a Copy struct.
(import stdlib.arena)

(defstruct S
  (x i64))

(define (mk) : S
  (S 3))

(define (keep [c : bool]) : S
  (with-arena
    r
    (let
      [y : (in r S) (mk)]
      (if c
        y
        y))))

(define (main) : i64
  (keep true).x)