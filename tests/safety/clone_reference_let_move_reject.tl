(import stdlib.clone)

(defstruct Cell
  (name String))

(clone.gen-clone Cell)

(define (copy [source : (& source Cell)]) : Cell
  (let
    [cell (deref source)]
    (clone-cell (& cell))))

(define (main) : i64
  0)