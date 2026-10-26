;: A rank-2 foreach body runs once per cell: moving an owner captured from
;: outside the loop is a loop-carried move (#8449).
(import stdlib.string)

(define (consume [text : String]) : i64
  (string.string-length text))

(define (main) : i64
  (let
    [text : String "cell"]
    [out : (Array i64 4) (make-array i64 4)]
    (foreach
      ([y : i64 0 2] [x : i64 0 2])
      (set! (array-ref out (+ (* y 2) x)) (consume text)))
    (array-ref out 0)))