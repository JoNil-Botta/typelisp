;; A by-value for loop cannot move an array that a live reference borrows.
(import stdlib.string)

(define (main) : i64
  (let
    [strings : (Array String 2) (array "a" "bc")]
    [r : (& strings (Array String 2)) (& strings)]
    [total : i64 0]
    (begin
      (for [s strings]
        (set! total (+ total (string.string-length (& s)))))
      (+ total (string.string-length (& (array-ref (deref r) 0)))))))