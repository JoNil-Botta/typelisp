(import "stdlib/io.tl")

; refs #215: compiled programs can observe argc/argv preserved from _start.
(define (main) : i64
  (begin
    (print-string (arg 1))
    (print-string "\n")
    (if (and
      (and (= (arg-count) 3) (> (string-length (arg 0)) 0))
      (string-eq (arg 2) "beta"))
      7
      1)))