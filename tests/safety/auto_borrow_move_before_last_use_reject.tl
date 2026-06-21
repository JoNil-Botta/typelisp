(import "stdlib/string.tl")

(define (len [text : (& text str)]) : i64
  (string-length text))

(define (main) : i64
  (let
    [text : String "move"]
    [borrowed : (& text str) (& text)]
    (begin
      (let
        [moved : String text]
        (string-length moved))
      (len borrowed))))
