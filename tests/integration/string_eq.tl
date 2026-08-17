; `string-eq` and `string=?` compare strings through stdlib/string.tl.
; This covers empty, short, long, first-byte mismatch, late mismatch, and
; length mismatch cases. Exit status 0.
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (begin
    (io.println "{}" (string.eq "" ""))
    (io.println "{}" (string.eq "a" "a"))
    (io.println "{}" (string.eq "hello" "hello"))
    (io.println "{}" (string.string=? "hello" "world"))
    (io.println "{}" (string.eq "hi" "high"))
    (io.println
      "{}"
      (string.eq
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "0123456789abcdefghijklmnopqrstuvwxyz"))
    (io.println
      "{}"
      (string.eq
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "0123456789abcdefghijklmnopqrstuvwxyZ"))
    0))