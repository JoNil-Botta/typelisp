;: A result-bearing arena scope cannot hide a move from a non-Copy global.
(define global-text : String
  "owned")

(define (take-global) : String
  (with-arena scratch global-text))

(define (main) : i64
  42)