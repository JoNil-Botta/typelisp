;: Unsafe does not disable ownership checking for a result-producing global.
(define global-text : String
  "owned")

(define (take-global) : String
  (unsafe
    global-text))

(define (main) : i64
  42)