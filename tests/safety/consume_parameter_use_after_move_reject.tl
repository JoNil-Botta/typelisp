(import stdlib.string)

(define (consume-length [text : String (:consume)]) : i64
  (string-length text))

(define (main) : i64
  (let
    [text : String "moved"]
    (begin
      (consume-length text)
      (string-length text))))
