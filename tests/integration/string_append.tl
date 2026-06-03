;; string_append.tl - concatenate two Strings via the emit-on-demand,
;; libc-free `tl_string_concat` runtime. `(string-append a b)` /
;; `(string-concat a b)` : (-> String String String) allocates a fresh heap
;; String holding `a`'s bytes followed by `b`'s bytes. This covers empty,
;; left-empty, right-empty, short, and long concatenations and exits 0.
(import "stdlib/io.tl")

(define (main) : i64
  (begin
    (print-string "[")
    (print-string (string-append "" ""))
    (print-string "]\n")
    (print-string (string-append "" "right"))
    (print-string "\n")
    (print-string (string-append "left" ""))
    (print-string "\n")
    (print-string (string-append "foo" "bar"))
    (print-string "\n")
    (print-string
      (string-concat
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    (print-string "\n")
    0))
