;: A match arm result cannot move from a non-Copy global.
(defenum GlobalMoveFlag
  (On)
  (Off))

(define global-text : String
  "owned")

(define (take-global [flag : GlobalMoveFlag]) : String
  (match flag
    [(On) global-text]
    [(Off) "fallback"]))

(define (main) : i64
  42)