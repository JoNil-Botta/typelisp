(import "stdlib/string.tl")

(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (string-test-trim-left [s : String]) : String
  (string-trim-left (& s)))

(define (string-test-trim-right [s : String]) : String
  (string-trim-right (& s)))

(define (string-test-trim [s : String]) : String
  (string-trim (& s)))

(define (string-test-contains [haystack : String] [needle : String]) : bool
  (string-contains (& haystack) (& needle)))

(define (string-test-contains-char [haystack : String] [c : char]) : bool
  (string-contains-char (& haystack) c))

(define (string-test-eq-borrowed [left : String] [right : String]) : bool
  (string-eq-borrowed (& left) (& right)))

(define (string-test-to-int-borrowed [text : String]) : i64
  (string->int-borrowed (& text)))

(define (string-test-copy-borrowed [text : String]) : String
  (string-copy-borrowed (& text)))

(define (string-test-append-borrowed [left : String] [right : String]) : String
  (string-append-borrowed (& left) (& right)))

(define (string-test-concat-borrowed [left : String] [right : String]) : String
  (string-concat-borrowed (& left) (& right)))

(define (string-test-substring-borrowed
  [text : String]
  [start : i64]
  [len : i64]) : String
  (substring-borrowed (& text) start len))

(define (string-test-slice-borrowed [text : String] [start : i64] [len : i64]) : String
  (string-slice-borrowed (& text) start len))

(define (string-test-prefix-at
  [haystack : String]
  [needle : String]
  [start : i64]) : bool
  (is-string-prefix-at (& haystack) (& needle) start))

(define (main) : i64
  (begin
    (assert-true (is-char-whitespace #\space') "space is whitespace")
    (assert-true (is-char-whitespace #\tab') "tab is whitespace")
    (assert-true (is-char-whitespace #\newline') "newline is whitespace")
    (assert-true (is-char-whitespace #\return') "return is whitespace")
    (assert-false (is-char-whitespace #A') "letter is not whitespace")
    (assert-true (char-eq #A' #A') "same chars compare equal")
    (assert-false (char-eq #A' #B') "different chars do not compare equal")
    (assert-true (string-eq "" "") "empty strings compare equal")
    (assert-true (string-eq "hello" "hello") "same strings compare equal")
    (assert-true
      (string=? "alias" (string-append "ali" "as"))
      "string=? aliases string-eq")
    (assert-owned-string-eq
      (string-append "" "")
      ""
      "string-append handles two empty strings")
    (assert-owned-string-eq
      (string-append "" "right")
      "right"
      "string-append handles empty left")
    (assert-owned-string-eq
      (string-append "left" "")
      "left"
      "string-append handles empty right")
    (assert-owned-string-eq
      (string-append "foo" "bar")
      "foobar"
      "string-append concatenates short strings")
    (assert-owned-string-eq
      (string-append
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
      "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      "string-append concatenates long strings")
    (assert-owned-string-eq
      (string-concat "con" "cat")
      "concat"
      "string-concat aliases string-append")
    (assert-owned-string-eq
      (string-test-copy-borrowed "borrow-copy")
      "borrow-copy"
      "string-copy-borrowed copies borrowed text")
    (assert-owned-string-eq
      (string-test-append-borrowed "bor" "row")
      "borrow"
      "string-append-borrowed concatenates borrowed inputs")
    (assert-owned-string-eq
      (string-test-concat-borrowed "" "borrowed")
      "borrowed"
      "string-concat-borrowed handles empty borrowed input")
    (assert-false (string-eq "hello" "world") "different strings differ")
    (assert-false (string-eq "hi" "high") "length mismatch differs")
    (assert-true
      (string-test-eq-borrowed "borrow" (string-append "bor" "row"))
      "borrowed string equality compares contents")
    (assert-false
      (string-test-eq-borrowed "borrow" "borrows")
      "borrowed string equality rejects length mismatch")
    (assert-i64-eq (string->int "") 0 "empty string parses as zero")
    (assert-i64-eq (string->int "-") 0 "minus-only string parses as zero")
    (assert-i64-eq (string->int "123") 123 "positive integer parses")
    (assert-i64-eq (string->int "-42") -42 "negative integer parses")
    (assert-i64-eq
      (string-test-to-int-borrowed "12a")
      169
      "borrowed parser keeps legacy non-digit arithmetic")
    (assert-owned-string-eq (int->string 0) "0" "int->string renders zero")
    (assert-owned-string-eq
      (int->string 123456789)
      "123456789"
      "int->string renders positive values")
    (assert-owned-string-eq
      (int->string -42)
      "-42"
      "int->string renders negative values")
    (assert-owned-string-eq
      (int->string 9223372036854775807)
      "9223372036854775807"
      "int->string renders i64 max")
    (assert-owned-string-eq
      (int->string (- (- 0 9223372036854775807) 1))
      "-9223372036854775808"
      "int->string renders i64 min")
    (assert-owned-string-eq
      (substring "abcdef" 2 3)
      "cde"
      "public substring copies middle slice")
    (assert-owned-string-eq
      (string-slice "abcdef" 6 0)
      ""
      "public string-slice copies empty boundary slice")
    (assert-owned-string-eq
      (string-test-substring-borrowed "abcdef" 0 6)
      "abcdef"
      "borrowed substring copies full slice")
    (assert-owned-string-eq
      (string-test-slice-borrowed "abcdef" 5 1)
      "f"
      "borrowed string-slice copies final byte")
    (assert-owned-string-eq
      (string-test-substring-borrowed
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        10
        40)
      "klmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN"
      "borrowed substring copies long slice")
    (assert-owned-string-eq
      (string-test-trim-left "  hello")
      "hello"
      "trim-left removes leading spaces")
    (assert-owned-string-eq
      (string-test-trim-left "")
      ""
      "trim-left handles empty strings")
    (assert-owned-string-eq
      (string-test-trim-right "hello  ")
      "hello"
      "trim-right removes trailing spaces")
    (assert-owned-string-eq
      (string-test-trim-right "   ")
      ""
      "trim-right handles all-space strings")
    (assert-owned-string-eq
      (string-test-trim "  hello  ")
      "hello"
      "trim removes both sides")
    (assert-owned-string-eq
      (string-test-trim "")
      ""
      "trim handles empty strings")
    (assert-true
      (string-test-contains "hello" "ell")
      "contains finds middle needle")
    (assert-true
      (string-test-contains "hello" "")
      "contains accepts empty needle")
    (assert-false
      (string-test-contains "hello" "world")
      "contains reports miss")
    (assert-false
      (string-test-contains "hi" "hello")
      "contains rejects too-long needle")
    (assert-true
      (string-test-contains-char "hello" #e')
      "contains-char finds char")
    (assert-false
      (string-test-contains-char "hello" #z')
      "contains-char reports miss")
    (assert-false
      (string-test-contains-char "" #z')
      "contains-char handles empty string")
    (assert-owned-string-eq
      (string-replace "hello" "ell" "ipp")
      "hippo"
      "replace middle")
    (assert-owned-string-eq
      (string-replace "hello" "he" "ye")
      "yello"
      "replace prefix")
    (assert-owned-string-eq
      (string-replace "hello" "lo" "p")
      "help"
      "replace suffix")
    (assert-owned-string-eq
      (string-replace "hello" "zz" "yy")
      "hello"
      "replace miss returns input")
    (assert-owned-string-eq
      (string-replace "abc" "" "x")
      "xabc"
      "replace empty needle prefixes")
    (assert-true (string-test-prefix-at "hello" "he" 0) "prefix at start")
    (assert-true (string-test-prefix-at "hello" "ll" 2) "prefix in middle")
    (assert-true (string-test-prefix-at "hello" "" 5) "empty prefix at end")
    (assert-false
      (string-test-prefix-at "hello" "he" -1)
      "negative prefix position")
    (assert-false (string-test-prefix-at "hello" "hello!" 0) "too-long prefix")
    (assert-false (string-test-prefix-at "hello" "lo" 4) "prefix past end")
    42))