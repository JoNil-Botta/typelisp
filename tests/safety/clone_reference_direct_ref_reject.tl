(defstruct Cell
  (name String))

(define (copy [source : (& source Cell)]) : (& source Cell)
  (clone source))

(define (main) : i64
  0)