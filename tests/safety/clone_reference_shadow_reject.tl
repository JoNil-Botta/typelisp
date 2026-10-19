(defstruct Cell
  (name String))

(define (clone [cell : Cell]) : Cell
  cell)

(define (copy [source : (& source Cell)]) : Cell
  (clone (deref source)))

(define (main) : i64
  0)