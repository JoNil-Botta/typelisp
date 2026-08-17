(import stdlib.io)

(define (main) : i64
  (begin
    (io.print-format "{}:{}:{}:{}:{}" "Ada" (cast -7 : i64) true 'x' 1.5)
    (io.println " {{done}}")
    (io.println "{}" (cast 42 : i64))
    0))