;; Each item of a by-value for loop is an owned value: moving it twice is rejected.
(import stdlib.string)

(define (take [s : String]) : i64
  (string.string-length (& s)))

(define (main) : i64
  (let
    [strings : (Array String 2) (array "a" "bc")]
    [total : i64 0]
    (begin
      (for [s strings]
        (set! total (+ total (+ (take s) (take s)))))
      total)))