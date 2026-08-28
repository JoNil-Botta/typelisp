(import stdlib.io)

(define (main) : i64
  (if (> (io.arg-count) 1)
    (begin
      (io.eprint "error={}" (cast 9 : i64))
      (io.eprintln " line={}" (cast 10 : i64))
      42)
    (begin
      (io.print "print={}" (cast 7 : i64))
      (io.println " line={}" (cast 8 : i64))
      42)))