(import stdlib.string)

(define (ordinary-length [text : String]) : i64
  (string-length text))

(define (main) : i64
  (let
    [_consumer : (-> (:consume String) i64) ordinary-length]
    0))
