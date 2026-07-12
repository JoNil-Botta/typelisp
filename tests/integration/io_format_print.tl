(import stdlib.io)

(define (main) : i64
  (begin
    (io.print "{}:{}:{}:{}:{}" "Ada" (cast -7 : i64) true 'x' 1.5)
    (io.println " {{done}}")
    (io.print 42)
    0))