;; `string.eq` against string literals (#8795): with the literal's length
;; folded, an inlined comparison keeps only the arm for that width. Every
;; literal length class is compared against equal, same-length-different and
;; different-length runtime strings, and a literal reaching the call through a
;; local, so a wrong arm or a wrong length shows as a wrong answer.
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(define (is-empty [s : (& s str)]) : bool
  (string.eq s ""))

(define (is-1 [s : (& s str)]) : bool
  (string.eq s "a"))

(define (is-2 [s : (& s str)]) : bool
  (string.eq s "ab"))

(define (is-3 [s : (& s str)]) : bool
  (string.eq s "abc"))

(define (is-4 [s : (& s str)]) : bool
  (string.eq s "%rax"))

(define (is-7 [s : (& s str)]) : bool
  (string.eq s "abcdefg"))

(define (is-8 [s : (& s str)]) : bool
  (string.eq s "abcdefgh"))

(define (is-9 [s : (& s str)]) : bool
  (string.eq s "abcdefghi"))

(define (is-17 [s : (& s str)]) : bool
  (string.eq s "abcdefghijklmnopq"))

(define (is-4-local [s : (& s str)]) : bool
  (let
    [literal : String "%rbx"]
    (string.eq s literal)))

;; A runtime copy of `text`, so the compared side is never a literal.
(define (runtime [text : String]) : String
  (str_cat.str-cat "" text))

;; 1 when `f` answers `expected` for `text`, else 0.
(define (check [f : (-> (& s str) bool)] [text : String] [expected : bool]) : i64
  (let
    [value : String (runtime text)]
    (if (= (f (& value)) expected)
      1
      0)))

(define (score) : i64
  (+
    (check is-empty "" true)
    (check is-empty "a" false)
    (check is-1 "a" true)
    (check is-1 "b" false)
    (check is-1 "" false)
    (check is-1 "aa" false)
    (check is-2 "ab" true)
    (check is-2 "ac" false)
    (check is-2 "bb" false)
    (check is-2 "a" false)
    (check is-3 "abc" true)
    (check is-3 "abd" false)
    (check is-3 "xbc" false)
    (check is-3 "abcd" false)
    (check is-4 "%rax" true)
    (check is-4 "%rbx" false)
    (check is-4 "%ra" false)
    (check is-4 "%raxx" false)
    (check is-4-local "%rbx" true)
    (check is-4-local "%rax" false)
    (check is-7 "abcdefg" true)
    (check is-7 "abcdefh" false)
    (check is-7 "xbcdefg" false)
    (check is-8 "abcdefgh" true)
    (check is-8 "abcdefgx" false)
    (check is-8 "abcdefg" false)
    (check is-9 "abcdefghi" true)
    (check is-9 "abcdefghx" false)
    (check is-9 "xbcdefghi" false)
    (check is-9 "abcdefgh" false)
    (check is-17 "abcdefghijklmnopq" true)
    (check is-17 "abcdefghijklmnopx" false)
    (check is-17 "abcdefghxjklmnopq" false)
    (check is-17 "abcdefghijklmnop" false)))

(define (main) : i64
  ;; 34 checks; every one passing scores 34, offset to the corpus's 42.
  (+ (score) 8))