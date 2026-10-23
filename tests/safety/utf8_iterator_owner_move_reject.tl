(import stdlib.string_utf8 as utf8)
(import stdlib.string)

(define (main) : i64
  (let [text : String "é😀"]
    [iter : (utf8.Iter text) (utf8.iterator (& text))]
    [moved : String text]
    (match (utf8.next (&mut iter))
      [(Item scalar) (+ (cast scalar.value : i64) (string.string-length moved))]
      [_ 1])))
