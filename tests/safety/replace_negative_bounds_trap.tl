;: Negative replace! indexes trap before evaluating the replacement.
(import stdlib.io)

(define (replacement) : i64
  (io.panic "replace! RHS ran before bounds check"))

(define (main) : i64
  (let
    [items : (Array i64 1) (array 7)]
    (replace! (array-ref items -1) (replacement))))