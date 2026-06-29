; `string-eq` and `string=?` compare strings through stdlib/string.tl.
; This covers empty, short, long, first-byte mismatch, late mismatch, and
; length mismatch cases. Exit status 0.
(import "stdlib/io.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (begin
    (print-bool (eq "" ""))
    (print-bool (eq "a" "a"))
    (print-bool (eq "hello" "hello"))
    (print-bool (string=? "hello" "world"))
    (print-bool (eq "hi" "high"))
    (print-bool
      (eq
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "0123456789abcdefghijklmnopqrstuvwxyz"))
    (print-bool
      (eq
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "0123456789abcdefghijklmnopqrstuvwxyZ"))
    0))