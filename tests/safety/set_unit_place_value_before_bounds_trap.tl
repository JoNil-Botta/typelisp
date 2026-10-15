;; A value trap precedes the final array-store bounds check.
(define (main) : i64
  (let
    [a : (Array unit 1) (array unit)]
    (set!
      (array-ref a 1)
      (begin
        (shl (cast 1 : i64) -1)
        unit))
    0))