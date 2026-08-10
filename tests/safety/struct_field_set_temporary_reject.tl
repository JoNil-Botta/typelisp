(defstruct Pair
  (x i64)
  (y i64))

(define (main) : unit
  (__tl-project-set-field (Pair 1 2) x 3))