;; A for loop moves its owned array source: the source cannot be read after it.
(import stdlib.string)

(define (main) : i64
  (let
    [strings : (Array String 2) (array "a" "bc")]
    [total : i64 0]
    (begin
      (for [s strings]
        (set! total (+ total (string.string-length (& s)))))
      (+ total (string.string-length (& (array-ref strings 0)))))))