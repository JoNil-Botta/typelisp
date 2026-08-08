(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 2) (array "a" "bc")]
    [total : i64 0]
    (begin
      (for
        [item : String items]
        (set! total (+ total (string.string-length item))))
      (+ total (string.string-length (array-ref items 0))))))