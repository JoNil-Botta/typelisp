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
;;   0
;;   123456789
;;   -42
;;   9223372036854775807
;;   -9223372036854775808
;; Exit code: 42
(import "stdlib/io.tl")

(import "stdlib/string.tl")

(define (integration-trim-left [s : String]) : String
  (string-trim-left (& s)))

(define (integration-trim-right [s : String]) : String
  (string-trim-right (& s)))

(define (integration-trim [s : String]) : String
  (string-trim (& s)))

(define (integration-contains [haystack : String] [needle : String]) : bool
  (string-contains (& haystack) (& needle)))

(define (integration-contains-char [haystack : String] [c : char]) : bool
  (string-contains-char (& haystack) c))

(define (main) : i64
  (begin
    (print-string (integration-trim-left "  hello"))
    (print-string "|")
    (print-newline)
    (print-string (integration-trim-right "hello  "))
    (print-string "|")
    (print-newline)
    (print-string (integration-trim "  hello  "))
    (print-string "|")
    (print-newline)
    (if (integration-contains-char "hello" #\l')
      (print-string "found")
      (print-string "not found"))
    (print-newline)
    (print-string (integration-trim-left ""))
    (print-string "|empty-left")
    (print-newline)
    (print-string (integration-trim-right ""))
    (print-string "|empty-right")
    (print-newline)
    (print-string (integration-trim "   "))
    (print-string "|all-space")
    (print-newline)
    (if (integration-contains "hello" "ell")
      (print-string "contains")
      (print-string "not contains"))
    (print-newline)
    (if (integration-contains "hello" "zzz")
      (print-string "not missing")
      (print-string "missing"))
    (print-newline)
    (print-string (string-replace "hello" "ell" "ipp"))
    (print-newline)
    (print-string (string-replace "abc" "c" "x"))
    (print-newline)
    (print-string (int->string 0))
    (print-newline)
    (print-string (int->string 123456789))
    (print-newline)
    (print-string (int->string -42))
    (print-newline)
    (print-string (int->string 9223372036854775807))
    (print-newline)
    (print-string (int->string (- (- 0 9223372036854775807) 1)))
    (print-newline)
    (if (and
      (string-eq "same" (string-append "sa" "me"))
      (not (string=? "same" "different"))
      (= (string->int "-42") -42)
      (= (string->int "12a") 169))
      42
      1)))