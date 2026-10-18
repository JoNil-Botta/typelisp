(defstruct Cell
  (name String))

(define (take [_cell : (Box Cell)]) : unit
  unit)

(define (copy [cell : (Box Cell)]) : Cell
  (clone
    (begin
      (take cell)
      (deref cell))))

(define (main) : i64
  0)