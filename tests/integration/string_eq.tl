; `string-eq` and `string=?` compare strings through stdlib/string.tl.
; This covers empty, short, long, first-byte mismatch, late mismatch, and
; length mismatch cases. Exit status 0.
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (begin
    (io.print-bool (string.eq "" ""))
    (io.print-bool (string.eq "a" "a"))
    (io.print-bool (string.eq "hello" "hello"))
    (io.print-bool (string.string=? "hello" "world"))
    (io.print-bool (string.eq "hi" "high"))
    (io.print-bool
      (string.eq
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "0123456789abcdefghijklmnopqrstuvwxyz"))
    (io.print-bool
      (string.eq
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "0123456789abcdefghijklmnopqrstuvwxyZ"))
    0))