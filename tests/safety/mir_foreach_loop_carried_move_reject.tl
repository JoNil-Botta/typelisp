;; A `foreach` body runs once per logical iteration: moving an outer owner in
;; it is a loop-carried move.
(import stdlib.string)

(define (take [text : String]) : i64
  (string.string-length text))

(define (main) : i64
  (let
    [text : String "lane"]
    [out : (Array i64 4) (array 0 0 0 0)]
    (begin
      (foreach ([i : i64 0 4]) (set! (array-ref out i) (take text)))
      (array-ref out 0))))