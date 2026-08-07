(import stdlib.string)

(define (main) : i64
  (let
    [pair : (Tuple String i64) (tuple "moved" 37)]
    [taken : String (tuple-ref pair 0)]
    (+ (string.string-length taken) (string.string-length (tuple-ref pair 0)))))