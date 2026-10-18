;; Each branch of a returned `if` flows into the function's result type: the
;; owning closure in one arm is rejected even though the other arm is plain.
(import stdlib.string)

(define (make [pick : bool] [owned : String]) : (-> i64)
  (if pick
    (lambda () : i64
      (string.string-length owned))
    (lambda () : i64
      0)))

(define (main) : i64
  ((make false "unused")))