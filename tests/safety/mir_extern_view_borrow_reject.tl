;; An extern view constructor's result borrows from its reference operand:
;; moving the source while the view is live is rejected.
(import stdlib.string)

(unsafe
  (extern (tl_str_view [text : (& text str)] [start : i64] [len : i64]) : (&
    text
    str)))

(define (consume [text : String]) : i64
  (string.string-length text))

(define (main) : i64
  (let
    [text : String (string.copy "abcdef")]
    [view : (& text str)
      (unsafe
        (tl_str_view (& text) 1 3))]
    [n : i64 (consume text)]
    (+ n (string.string-length view))))