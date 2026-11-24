(import stdlib.clone)

(defstruct Cell
  (name String))

(clone.gen-clone Cell)

(define (take [_cell : (Box Cell)]) : unit
  unit)

(define (copy [cell : (Box Cell)]) : Cell
  (clone-cell
    (begin
      (take cell)
      (& (deref cell)))))

(define (main) : i64
  0)