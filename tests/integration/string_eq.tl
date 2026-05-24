; `string-eq` compares two strings byte-wise via the emit-on-demand,
; libc-free `tl_string_eq` runtime helper. Equal strings (including a
; literal compared with itself) print `true`; differing strings — whether by
; content at equal length or by length — print `false`. Exit status 0.
(define (main) : i64
  (begin
    (print-bool (string-eq "hello" "hello"))
    (print-bool (string=? "hello" "world"))
    (print-bool (string-eq "hi" "high"))
    (print-bool (string-eq "" ""))
    0))