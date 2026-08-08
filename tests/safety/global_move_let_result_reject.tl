;: A let body cannot hide a move from a non-Copy global.
(define global-text : String
  "owned")

(define (take-global) : String
  (let
    [_marker : i64 0]
    global-text))

(define (main) : i64
  42)