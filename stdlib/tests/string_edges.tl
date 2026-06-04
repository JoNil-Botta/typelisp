(import "stdlib/string.tl")

(import "stdlib/test.tl")

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
    (assert-string-eq
      (string-test-trim-left "  hello")
      "hello"
      "trim-left removes leading spaces")
    (assert-string-eq
      (string-test-trim-left "")
      ""
      "trim-left handles empty strings")
    (assert-string-eq
      (string-test-trim-right "hello  ")
      "hello"
      "trim-right removes trailing spaces")
    (assert-string-eq
      (string-test-trim-right "   ")
      ""
      "trim-right handles all-space strings")
    (assert-string-eq
      (string-test-trim "  hello  ")
      "hello"
      "trim removes both sides")
    (assert-string-eq (string-test-trim "") "" "trim handles empty strings")
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
    (assert-string-eq
      (string-replace "hello" "ell" "ipp")
      "hippo"
      "replace middle")
    (assert-string-eq
      (string-replace "hello" "he" "ye")
      "yello"
      "replace prefix")
    (assert-string-eq (string-replace "hello" "lo" "p") "help" "replace suffix")
    (assert-string-eq
      (string-replace "hello" "zz" "yy")
      "hello"
      "replace miss returns input")
    (assert-string-eq
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