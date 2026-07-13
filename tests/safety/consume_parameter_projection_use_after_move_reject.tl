(import stdlib.string)

(defstruct Pair
  (text String)
  (value i64))

(define (consume-length [text : String (:consume)]) : i64
  (string-length text))

(define (main) : i64
  (let
    [pair : Pair (Pair "moved" 7)]
    (begin
      (consume-length pair.text)
      (string-length pair.text))))
