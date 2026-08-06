;: Returning a non-Copy fixed array from a global would move from it.
(define global-values : (Array String 2)
  (array "left" "right"))

(define (take-global) : (Array String 2)
  global-values)

(define (main) : i64
  42)
