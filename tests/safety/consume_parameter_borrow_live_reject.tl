(import stdlib.string)

(define (consume-length [text : String (:consume)]) : i64
  (string-length text))

(define (borrowed-length [text : (& text str)]) : i64
  (string-length text))

(define (main) : i64
  (let
    [text : String "borrowed"]
    [borrowed : (& text str) (& text)]
    (begin
      (consume-length text)
      (borrowed-length borrowed))))
