(import "stdlib/string.tl")

(import "stdlib/test.tl")

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
      (string-trim-left "  hello")
      "hello"
      "trim-left removes leading spaces")
    (assert-string-eq
      (string-trim-left "")
      ""
      "trim-left handles empty strings")
    (assert-string-eq
      (string-trim-right "hello  ")
      "hello"
      "trim-right removes trailing spaces")
    (assert-string-eq
      (string-trim-right "   ")
      ""
      "trim-right handles all-space strings")
    (assert-string-eq
      (string-trim "  hello  ")
      "hello"
      "trim removes both sides")
    (assert-string-eq (string-trim "") "" "trim handles empty strings")
    (assert-true (string-contains "hello" "ell") "contains finds middle needle")
    (assert-true (string-contains "hello" "") "contains accepts empty needle")
    (assert-false (string-contains "hello" "world") "contains reports miss")
    (assert-false
      (string-contains "hi" "hello")
      "contains rejects too-long needle")
    (assert-true (string-contains-char "hello" #e') "contains-char finds char")
    (assert-false
      (string-contains-char "hello" #z')
      "contains-char reports miss")
    (assert-false
      (string-contains-char "" #z')
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
    (assert-true (is-string-prefix-at "hello" "he" 0) "prefix at start")
    (assert-true (is-string-prefix-at "hello" "ll" 2) "prefix in middle")
    (assert-true (is-string-prefix-at "hello" "" 5) "empty prefix at end")
    (assert-false
      (is-string-prefix-at "hello" "he" -1)
      "negative prefix position")
    (assert-false (is-string-prefix-at "hello" "hello!" 0) "too-long prefix")
    (assert-false (is-string-prefix-at "hello" "lo" 4) "prefix past end")
    42))