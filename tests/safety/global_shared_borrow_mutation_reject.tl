;: #5215: direct mutation conflicts with a still-live shared global projection.
(defstruct Cell
  (value i64))

(define global-cell : Cell
  (Cell 1))

(define (take-shared-and-value [_shared : (& shared i64)] [_value : i64]) : i64
  1)

(define (main) : i64
  (take-shared-and-value
    (& global-cell.value)
    (begin
      (set! global-cell.value 2)
      0)))