;; Comparing a string that was moved is a use of the moved value.
(import stdlib.string)

(define (consume [text : String]) : i64
  (string.string-length text))

(define (main) : i64
  (let
    [text : String (string.copy "abc")]
    [length : i64 (consume text)]
    (if (= text "abc")
      length
      1)))