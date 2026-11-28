(import stdlib.string)

(define saved : String
  "")

(define (save [left : String] [right : String]) : bool
  (set! saved (string.append left right))
  true)

(define (invoke [cmp : (-> String String bool)]) : bool
  (cmp "a" "b"))

(define (main) : i64
  (with-arena
    job
    (if (invoke save)
      42
      0)))