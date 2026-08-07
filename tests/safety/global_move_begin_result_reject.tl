;: A final begin expression cannot hide a move from a non-Copy global.
(define global-text : String
  "owned")

(define (take-global) : String
  (begin
    0
    global-text))

(define (main) : i64
  42)