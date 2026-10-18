;; refs #8853: two elided inputs keep distinct hidden lifetimes, so a local
;; bound to one cannot be assigned a reference carrying the other.
(defstruct ElidedLetSwapRec
  (value i64))

(define (elided-let-swap
  [first : (& ElidedLetSwapRec)]
  [second : (& ElidedLetSwapRec)]) : i64
  (let
    [outer first]
    [inner second]
    (set! outer inner)
    outer.value))

(define (main) : i64
  (let
    [a (ElidedLetSwapRec 40)]
    [b (ElidedLetSwapRec 2)]
    (elided-let-swap (& a) (& b))))