;; tests/integration/stdlib_string.tl — Integration test for stdlib/string.tl
;;
;; Expected stdout:
;;   hello|
;;   hello|
;;   hello|
;;   found
;; Exit code: 42

(import "string.tl")

(define (main) : i64
  (begin
    (print-string (string-trim-left "  hello"))
    (print-string "|")
    (print-newline)

    (print-string (string-trim-right "hello  "))
    (print-string "|")
    (print-newline)

    (print-string (string-trim "  hello  "))
    (print-string "|")
    (print-newline)

    (if (string-contains-char "hello" #\l')
        (print-string "found")
        (print-string "not found"))
    (print-newline)

    42))
