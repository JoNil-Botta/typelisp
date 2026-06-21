(import "stdlib/string.tl")

(define (len [text : (& text str)]) : i64
  (string-length text))

(define (main) : i64
  (let
    [text : String "move"]
    (begin
      (len text)
      (let
        [moved : String text]
        (string-length moved)))))
