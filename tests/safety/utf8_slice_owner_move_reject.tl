(import stdlib.string_utf8 as utf8)
(import stdlib.string)

(define (main) : i64
  (let
    [text : String "é😀"]
    [result : (utf8.SliceResult text) (utf8.slice (& text) 0 1)]
    [moved : String text]
    (match result
      [(Slice view)
        (+ (string.string-length view) (string.string-length moved))]
      [_ 1])))