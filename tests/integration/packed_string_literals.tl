(import stdlib.io)
(import stdlib.byte_buf)

(define (write [text : String]) : unit
  (io.stdout-write (byte_buf.str-as-bytes (& text))))

;; Whole stdout exercises the physical payload and each independent length
;; through the runtime writer, including repeated, empty and UTF-8 literals.
(define (main) : i64
  (write "prefix/abc")
  (write "abc")
  (write "bc")
  (write "c")
  (write "")
  (write "cab")
  (write "dab")
  (write "ab")
  (write "b")
  (write "prefixλ")
  (write "λ")
  (write "b")
  (write "prefix/abc")
  42)