(import stdlib.clone)

(defstruct Cell
  (name String))

(clone.gen-clone Cell)

(define (take [_cell : Cell]) : unit
  unit)

(define (copy [source : (& source Cell)]) : Cell
  (clone-cell
    (begin
      (take (deref source))
      source)))

(define (main) : i64
  0)