;: #2610: a dotted shared-field borrow blocks an overlapping nested write.
(defstruct Inner
  (x i64))

(defstruct Pair
  (left Inner)
  (right i64))

(define (read-inner [_inner : (& pair Inner)]) : unit
  unit)

(define (main) : unit
  (let
    [pair : Pair (Pair (Inner 1) 2)]
    [borrowed : (& pair Inner) (& pair.left)]
    (begin
      (set! pair.left.x 42)
      (read-inner borrowed))))