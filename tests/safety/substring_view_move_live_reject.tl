(import stdlib.string)

(define (main) : i64
  (let
    [text : String "abcdef"]
    [view : (& text str) (string.substring-view (& text) 1 3)]
    [moved : String text]
    (+ (string-length view) (string-length moved))))