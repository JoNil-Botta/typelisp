;; Comparing a string reads it through a shared borrow: it stays usable.
(import stdlib.string)

(define (consume [text : String]) : i64
  (string.string-length text))

(define (main) : i64
  (let
    [text : String (string.copy "abc")]
    (if (= text "abc")
      (+ 39 (consume text))
      (consume text))))