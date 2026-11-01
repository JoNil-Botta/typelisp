;; Breaking out of a by-value for loop leaves the remaining elements unmoved.
(import stdlib.string)

(define (take [s : String]) : i64
  (string.string-length (& s)))

(define (main) : i64
  (let
    [strings : (Array String 3) (array "a" "bc" "def")]
    [total : i64 0]
    (begin
      (for [s strings]
        (if (> total 2)
          (break)
          (set! total (+ total (take s)))))
      (+ total 39))))