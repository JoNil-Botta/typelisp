;; Zero-template newline forms (#6985): `(io.println)` and `(io.eprintln)` write
;; exactly one LF byte, never CRLF, through the same direct sinks as the
;; template-bearing forms. The manifest rows assert the raw bytes of each
;; stream; the other stream must stay empty.
(import stdlib.io)

(define (main) : i64
  (if (> (io.arg-count) 1)
    (begin
      (io.eprintln)
      (io.eprint "e")
      (io.eprintln)
      (io.eprintln "{}" (cast 2 : i64))
      (io.eprintln)
      42)
    (begin
      (io.println)
      (io.print "o")
      (io.println)
      (io.println "{}" (cast 1 : i64))
      (io.println)
      42)))