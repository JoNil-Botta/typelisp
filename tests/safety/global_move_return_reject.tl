;: Returning a non-Copy fixed array from a global would move from it.
(define global-values : (Array String 2)
  (array "left" "right"))

(define (take-global [flag : bool]) : (Array String 2)
  (if flag
    global-values
    (array "fallback" "values")))

(define (main) : i64
  42)