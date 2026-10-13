;; refs #8853: two elided inputs keep distinct hidden lifetimes. A local bound
;; to the second cannot be returned under the first's explicit lifetime.
(defstruct ElidedLetPickRec
  (value i64))

(define (elided-let-pick
  [first : (& keep ElidedLetPickRec)]
  [second : (& ElidedLetPickRec)]) : (& keep ElidedLetPickRec)
  (let
    [bound second]
    bound))

(define (main) : i64
  (let
    [a (ElidedLetPickRec 40)]
    [b (ElidedLetPickRec 2)]
    (elided-let-pick (& a) (& b)).value))