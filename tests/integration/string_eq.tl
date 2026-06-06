; `string-eq` and `string=?` compare strings through stdlib/string.tl.
; This covers empty, short, long, first-byte mismatch, late mismatch, and
; length mismatch cases. Exit status 0.
(import "stdlib/io.tl")

(import "stdlib/string.tl")

(define (main) : i64
  (begin
    (print-bool (string-eq "" ""))
    (print-bool (string-eq "a" "a"))
    (print-bool (string-eq "hello" "hello"))
    (print-bool (string=? "hello" "world"))
    (print-bool (string-eq "hi" "high"))
    (print-bool
      (string-eq
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "0123456789abcdefghijklmnopqrstuvwxyz"))
    (print-bool
      (string-eq
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "0123456789abcdefghijklmnopqrstuvwxyZ"))
    0))