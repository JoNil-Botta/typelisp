; `string-eq` compares strings through the emit-on-demand, libc-free
; `tl_string_eq` runtime helper. This covers empty, short, long, first-byte
; mismatch, late mismatch, and length mismatch cases. Exit status 0.
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