;; string_append.tl - concatenate two Strings via stdlib/string.tl.
;; `(string-append a b)` /
;; `(string-concat a b)` : (-> String String String) allocates a fresh heap
;; String holding `a`'s bytes followed by `b`'s bytes. This covers empty,
;; left-empty, right-empty, short, and long concatenations and exits 0.
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (begin
    (io.print-string "[")
    (io.print-string (string.append "" ""))
    (io.print-string "]\n")
    (io.print-string (string.append "" "right"))
    (io.print-string "\n")
    (io.print-string (string.append "left" ""))
    (io.print-string "\n")
    (io.print-string (string.append "foo" "bar"))
    (io.print-string "\n")
    (io.print-string
      (string.concat
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    (io.print-string "\n")
    0))
