;: #5215: one global place cannot supply two simultaneously live mutable borrows.
(defstruct Cell
  (value i64))

(define global-cell : Cell
  (Cell 1))

(define (take-two [_left : (&mut left Cell)] [_right : (&mut right Cell)]) : unit
  unit)

(define (main) : unit
  (take-two (&mut global-cell) (&mut global-cell)))