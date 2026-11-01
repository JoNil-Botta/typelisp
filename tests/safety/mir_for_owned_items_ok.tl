;; Each element of the owned array moves into its item exactly once.
(import stdlib.string)

(define (take [s : String]) : i64
  (string.string-length (& s)))

(define (main) : i64
  (let
    [strings : (Array String 3) (array "a" "bc" "def")]
    [total : i64 0]
    (begin
      (for [s strings]
        (set! total (+ total (take s))))
      (+ total 36))))