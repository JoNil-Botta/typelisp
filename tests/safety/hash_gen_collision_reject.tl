;; `hash.gen` rejects a hand-written hook of the same name.
(import stdlib.eq)
(import stdlib.hash)

(defstruct Point
  (x i64))

(eq.gen Point)

(define (hash-point [value : (& value Point)]) : i64
  0)

(hash.gen Point)

(define (main) : i64
  0)