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
(import stdlib.io)
(import stdlib.string)

(define (integration-trim-left [s : String]) : String
  (string.trim-left (& s)))

(define (integration-trim-right [s : String]) : String
  (string.trim-right (& s)))

(define (integration-trim [s : String]) : String
  (string.trim (& s)))

(define (integration-contains [haystack : String] [needle : String]) : bool
  (string.contains (& haystack) (& needle)))

(define (integration-contains-char [haystack : String] [c : char]) : bool
  (string.contains-char (& haystack) c))

(define (main) : i64
  (begin
    (io.print-string (integration-trim-left "  hello"))
    (io.print-string "|")
    (io.print-newline)
    (io.print-string (integration-trim-right "hello  "))
    (io.print-string "|")
    (io.print-newline)
    (io.print-string (integration-trim "  hello  "))
    (io.print-string "|")
    (io.print-newline)
    (if (integration-contains-char "hello" 'l')
      (io.print-string "found")
      (io.print-string "not found"))
    (io.print-newline)
    (io.print-string (integration-trim-left ""))
    (io.print-string "|empty-left")
    (io.print-newline)
    (io.print-string (integration-trim-right ""))
    (io.print-string "|empty-right")
    (io.print-newline)
    (io.print-string (integration-trim "   "))
    (io.print-string "|all-space")
    (io.print-newline)
    (if (integration-contains "hello" "ell")
      (io.print-string "contains")
      (io.print-string "not contains"))
    (io.print-newline)
    (if (integration-contains "hello" "zzz")
      (io.print-string "not missing")
      (io.print-string "missing"))
    (io.print-newline)
    (io.print-string (string.replace "hello" "ell" "ipp"))
    (io.print-newline)
    (io.print-string (string.replace "abc" "c" "x"))
    (io.print-newline)
    (io.print-string (string.int->string 0))
    (io.print-newline)
    (io.print-string (string.int->string 123456789))
    (io.print-newline)
    (io.print-string (string.int->string -42))
    (io.print-newline)
    (io.print-string (string.int->string 9223372036854775807))
    (io.print-newline)
    (io.print-string (string.int->string (- (- 0 9223372036854775807) 1)))
    (io.print-newline)
    (if (and
      (string.eq "same" (string.append "sa" "me"))
      (not (string.string=? "same" "different"))
      (= (string.>int "-42") -42)
      (= (string.>int "12a") 169))
      42
      1)))