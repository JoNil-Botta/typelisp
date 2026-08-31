(import stdlib.clone as clone_gen)

(defstruct Point
  (x i64))

(define (clone-point [value : (& value Point)]) : Point
  (Point value.x))

(clone_gen.gen-clone Point)