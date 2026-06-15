(import stdlib.string)

(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (string-test-trim-left [s : String]) : String
  (string.string-trim-left (& s)))

(define (string-test-trim-right [s : String]) : String
  (string.string-trim-right (& s)))

(define (string-test-trim [s : String]) : String
  (string.string-trim (& s)))

(define (string-test-contains [haystack : String] [needle : String]) : bool
  (string.string-contains (& haystack) (& needle)))

(define (string-test-contains-char [haystack : String] [c : char]) : bool
  (string.string-contains-char (& haystack) c))

(define (string-test-eq-borrowed [left : String] [right : String]) : bool
  (string.string-eq-borrowed (& left) (& right)))

(define (string-test-to-int-borrowed [text : String]) : i64
  (string.string->int-borrowed (& text)))

(define (string-test-copy-borrowed [text : String]) : String
  (string.string-copy-borrowed (& text)))

(define (string-test-append-borrowed [left : String] [right : String]) : String
  (string.string-append-borrowed (& left) (& right)))

(define (string-test-concat-borrowed [left : String] [right : String]) : String
  (string.string-concat-borrowed (& left) (& right)))

(define (string-test-concat-all-empty) : String
  (string.string-concat-all (make-array String 0)))

(define (string-test-concat-all-many) : String
  (let
    [parts : (Array String) (make-array String 6)]
    (begin
      (array-set! parts 0 "ab")
      (array-set! parts 1 "")
      (array-set! parts 2 "cd")
      (array-set! parts 3 "ef")
      (array-set! parts 4 "")
      (array-set! parts 5 "gh")
      (string.string-concat-all parts))))

(define (string-test-substring-borrowed
  [text : String]
  [start : i64]
  [len : i64]) : String
  (string.substring-borrowed (& text) start len))

(define (string-test-slice-borrowed [text : String] [start : i64] [len : i64]) : String
  (string.string-slice-borrowed (& text) start len))

(define (string-test-prefix-at
  [haystack : String]
  [needle : String]
  [start : i64]) : bool
  (string.is-string-prefix-at (& haystack) (& needle) start))

(define (main) : i64
  (begin
    (test.assert-true (string.is-char-whitespace #\space') "space is whitespace")
    (test.assert-true (string.is-char-whitespace #\tab') "tab is whitespace")
    (test.assert-true (string.is-char-whitespace #\newline') "newline is whitespace")
    (test.assert-true (string.is-char-whitespace #\return') "return is whitespace")
    (test.assert-false (string.is-char-whitespace #A') "letter is not whitespace")
    (test.assert-true (string.char-eq #A' #A') "same chars compare equal")
    (test.assert-false (string.char-eq #A' #B') "different chars do not compare equal")
    (test.assert-true (string.string-eq "" "") "empty strings compare equal")
    (test.assert-true (string.string-eq "hello" "hello") "same strings compare equal")
    (test.assert-true
      (string.string=? "alias" (string.string-append "ali" "as"))
      "string=? aliases string-eq")
    (assert-owned-string-eq
      (string.string-append "" "")
      ""
      "string-append handles two empty strings")
    (assert-owned-string-eq
      (string.string-append "" "right")
      "right"
      "string-append handles empty left")
    (assert-owned-string-eq
      (string.string-append "left" "")
      "left"
      "string-append handles empty right")
    (assert-owned-string-eq
      (string.string-append "foo" "bar")
      "foobar"
      "string-append concatenates short strings")
    (assert-owned-string-eq
      (string.string-append
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
      "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      "string-append concatenates long strings")
    (assert-owned-string-eq
      (string.string-concat "con" "cat")
      "concat"
      "string-concat aliases string-append")
    (assert-owned-string-eq
      (string-test-concat-all-empty)
      ""
      "string-concat-all handles an empty parts array")
    (assert-owned-string-eq
      (string-test-concat-all-many)
      "abcdefgh"
      "string-concat-all concatenates many parts")
    (assert-owned-string-eq
      (string.string-concat3 "a" "b" "c")
      "abc"
      "string-concat3 concatenates three strings")
    (assert-owned-string-eq
      (string.string-concat4 "a" "b" "c" "d")
      "abcd"
      "string-concat4 concatenates four strings")
    (assert-owned-string-eq
      (string.string-concat5 "a" "b" "c" "d" "e")
      "abcde"
      "string-concat5 concatenates five strings")
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
    (test.assert-false (string.string-eq "hello" "world") "different strings differ")
    (test.assert-false (string.string-eq "hi" "high") "length mismatch differs")
    (test.assert-true
      (string-test-eq-borrowed "borrow" (string.string-append "bor" "row"))
      "borrowed string equality compares contents")
    (test.assert-false
      (string-test-eq-borrowed "borrow" "borrows")
      "borrowed string equality rejects length mismatch")
    (test.assert-i64-eq (string.string->int "") 0 "empty string parses as zero")
    (test.assert-i64-eq (string.string->int "-") 0 "minus-only string parses as zero")
    (test.assert-i64-eq (string.string->int "123") 123 "positive integer parses")
    (test.assert-i64-eq (string.string->int "-42") -42 "negative integer parses")
    (test.assert-i64-eq
      (string-test-to-int-borrowed "12a")
      169
      "borrowed parser keeps legacy non-digit arithmetic")
    (assert-owned-string-eq (string.int->string 0) "0" "int->string renders zero")
    (assert-owned-string-eq
      (string.int->string 123456789)
      "123456789"
      "int->string renders positive values")
    (assert-owned-string-eq
      (string.int->string -42)
      "-42"
      "int->string renders negative values")
    (assert-owned-string-eq
      (string.int->string 9223372036854775807)
      "9223372036854775807"
      "int->string renders i64 max")
    (assert-owned-string-eq
      (string.int->string (- (- 0 9223372036854775807) 1))
      "-9223372036854775808"
      "int->string renders i64 min")
    (assert-owned-string-eq
      (string.substring "abcdef" 2 3)
      "cde"
      "public substring copies middle slice")
    (assert-owned-string-eq
      (string.string-slice "abcdef" 6 0)
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
    (test.assert-true
      (string-test-contains "hello" "ell")
      "contains finds middle needle")
    (test.assert-true
      (string-test-contains "hello" "")
      "contains accepts empty needle")
    (test.assert-false
      (string-test-contains "hello" "world")
      "contains reports miss")
    (test.assert-false
      (string-test-contains "hi" "hello")
      "contains rejects too-long needle")
    (test.assert-true
      (string-test-contains-char "hello" #e')
      "contains-char finds char")
    (test.assert-false
      (string-test-contains-char "hello" #z')
      "contains-char reports miss")
    (test.assert-false
      (string-test-contains-char "" #z')
      "contains-char handles empty string")
    (assert-owned-string-eq
      (string.string-replace "hello" "ell" "ipp")
      "hippo"
      "replace middle")
    (assert-owned-string-eq
      (string.string-replace "hello" "he" "ye")
      "yello"
      "replace prefix")
    (assert-owned-string-eq
      (string.string-replace "hello" "lo" "p")
      "help"
      "replace suffix")
    (assert-owned-string-eq
      (string.string-replace "hello" "zz" "yy")
      "hello"
      "replace miss returns input")
    (assert-owned-string-eq
      (string.string-replace "abc" "" "x")
      "xabc"
      "replace empty needle prefixes")
    (test.assert-true (string-test-prefix-at "hello" "he" 0) "prefix at start")
    (test.assert-true (string-test-prefix-at "hello" "ll" 2) "prefix in middle")
    (test.assert-true (string-test-prefix-at "hello" "" 5) "empty prefix at end")
    (test.assert-false
      (string-test-prefix-at "hello" "he" -1)
      "negative prefix position")
    (test.assert-false (string-test-prefix-at "hello" "hello!" 0) "too-long prefix")
    (test.assert-false (string-test-prefix-at "hello" "lo" 4) "prefix past end")
    42))