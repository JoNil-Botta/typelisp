(import stdlib.clone)

(defstruct Cell
  (name String))

(define (copy [source : (& source Cell)]) : (& source Cell)
  (clone.deep source))

(define (main) : i64
  0)