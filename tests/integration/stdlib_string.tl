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
    (io.print-format "{}" (integration-trim-left "  hello"))
    (io.print-format "{}" "|")
    (io.println "")
    (io.print-format "{}" (integration-trim-right "hello  "))
    (io.print-format "{}" "|")
    (io.println "")
    (io.print-format "{}" (integration-trim "  hello  "))
    (io.print-format "{}" "|")
    (io.println "")
    (if (integration-contains-char "hello" 'l')
      (io.print-format "{}" "found")
      (io.print-format "{}" "not found"))
    (io.println "")
    (io.print-format "{}" (integration-trim-left ""))
    (io.print-format "{}" "|empty-left")
    (io.println "")
    (io.print-format "{}" (integration-trim-right ""))
    (io.print-format "{}" "|empty-right")
    (io.println "")
    (io.print-format "{}" (integration-trim "   "))
    (io.print-format "{}" "|all-space")
    (io.println "")
    (if (integration-contains "hello" "ell")
      (io.print-format "{}" "contains")
      (io.print-format "{}" "not contains"))
    (io.println "")
    (if (integration-contains "hello" "zzz")
      (io.print-format "{}" "not missing")
      (io.print-format "{}" "missing"))
    (io.println "")
    (io.print-format "{}" (string.replace "hello" "ell" "ipp"))
    (io.println "")
    (io.print-format "{}" (string.replace "abc" "c" "x"))
    (io.println "")
    (io.print-format "{}" (string.int->string 0))
    (io.println "")
    (io.print-format "{}" (string.int->string 123456789))
    (io.println "")
    (io.print-format "{}" (string.int->string -42))
    (io.println "")
    (io.print-format "{}" (string.int->string 9223372036854775807))
    (io.println "")
    (io.print-format "{}" (string.int->string (- (- 0 9223372036854775807) 1)))
    (io.println "")
    (if (and
      (string.eq "same" (string.append "sa" "me"))
      (not (string.string=? "same" "different"))
      (= (string.>int "-42") -42)
      (= (string.>int "12a") 169))
      42
      1)))