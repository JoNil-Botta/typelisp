(defstruct Cell
  (name String))

(define (copy [source : (& source Cell)]) : Cell
  (clone
    (let
      [cell (deref source)]
      cell)))

(define (main) : i64
  0)