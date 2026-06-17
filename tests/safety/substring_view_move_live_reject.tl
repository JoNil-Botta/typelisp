(import "stdlib/string.tl")

(define (main) : i64
  (let
    [text : String "abcdef"]
    [view : (& text str) (substring-view (& text) 1 3)]
    [moved : String text]
    (+ (string-length view) (string-length moved))))