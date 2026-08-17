(import stdlib.io)
(import stdlib.string)

; refs #215: compiled programs can observe argc/argv preserved from _tl_start.
(define (main) : i64
  (begin
    (io.print-format "{}" (io.arg 1))
    (io.print-format "{}" "\n")
    (if (and
      (= (io.arg-count) 3)
      (> (string-length (io.arg 0)) 0)
      (string.eq (io.arg 2) "beta"))
      7
      1)))