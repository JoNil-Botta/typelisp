;; string_append.tl - concatenate two Strings via stdlib/string.tl.
;; `(string-append a b)` /
;; `(string-concat a b)` : (-> String String String) allocates a fresh heap
;; String holding `a`'s bytes followed by `b`'s bytes. This covers empty,
;; left-empty, right-empty, short, and long concatenations and exits 0.
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (begin
    (io.print-format "{}" "[")
    (io.print-format "{}" (string.append "" ""))
    (io.print-format "{}" "]\n")
    (io.print-format "{}" (string.append "" "right"))
    (io.print-format "{}" "\n")
    (io.print-format "{}" (string.append "left" ""))
    (io.print-format "{}" "\n")
    (io.print-format "{}" (string.append "foo" "bar"))
    (io.print-format "{}" "\n")
    (io.print-format
      "{}"
      (string.concat
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    (io.print-format "{}" "\n")
    0))