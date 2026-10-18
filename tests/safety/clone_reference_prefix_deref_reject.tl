(defstruct Cell
  (name String))

(define (take [_cell : Cell]) : unit
  unit)

(define (copy [source : (& source Cell)]) : Cell
  (clone
    (begin
      (take (deref source))
      (deref source))))

(define (main) : i64
  0)