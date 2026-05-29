(import "stdlib/string.tl")

(import "stdlib/hash.tl")

(import "stdlib/test.tl")

(import "stdlib/json.tl")

(define (borrowed-str-score [text : (& text str)] [owned : String]) : i64
  (begin
    (assert-i64-eq
      (string-length text)
      (string-length (& owned))
      "borrowed str length")
    (+ (string-length text) (hash-string owned))))

(define (borrowed-str-gate-main [text : String]) : i64
  (borrowed-str-score (& text) text))