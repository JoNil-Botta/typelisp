;; tests/integration/stdlib_string.tl - Integration test for stdlib/string.tl
;; Test harnesses stage stdlib/string.tl under this import name.
;;
;; Expected stdout:
;;   hello|
;;   hello|
;;   hello|
;;   found
;;   |empty-left
;;   |empty-right
;;   |all-space
;;   contains
;;   missing
;;   hippo
;;   abx
;; Exit code: 42
(import "stdlib/string.tl")

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
    (print-string (string-trim-left ""))
    (print-string "|empty-left")
    (print-newline)
    (print-string (string-trim-right ""))
    (print-string "|empty-right")
    (print-newline)
    (print-string (string-trim "   "))
    (print-string "|all-space")
    (print-newline)
    (if (string-contains "hello" "ell")
      (print-string "contains")
      (print-string "not contains"))
    (print-newline)
    (if (string-contains "hello" "zzz")
      (print-string "not missing")
      (print-string "missing"))
    (print-newline)
    (print-string (string-replace "hello" "ell" "ipp"))
    (print-newline)
    (print-string (string-replace "abc" "c" "x"))
    (print-newline)
    42))