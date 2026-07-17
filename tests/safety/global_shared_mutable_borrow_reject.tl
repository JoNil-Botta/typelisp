;: #5215: a live shared global borrow excludes a mutable borrow of the same root.
(defstruct Cell
  (value i64))

(define global-cell : Cell
  (Cell 1))

(define (take-shared-and-mutable
  [_shared : (& shared Cell)]
  [_mutable : (&mut mutable Cell)]) : unit
  unit)

(define (main) : unit
  (take-shared-and-mutable (& global-cell) (&mut global-cell)))