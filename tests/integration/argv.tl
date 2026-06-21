(import "stdlib/io.tl")
(import "stdlib/string.tl")

; refs #215: compiled programs can observe argc/argv preserved from _tl_start.
(define (main) : i64
  (begin
    (print-string (arg 1))
    (print-string "\n")
    (if (and
      (= (arg-count) 3)
      (> (string-length (arg 0)) 0)
      (string-eq (arg 2) "beta"))
      7
      1)))
