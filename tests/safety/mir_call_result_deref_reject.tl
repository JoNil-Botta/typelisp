;: A reference returned by a call keeps its argument borrowed until its last
;: use, also when read through `(deref ...)`.
(defstruct Cell
  (value i64))

(define (pick [item : (& item Cell)]) : (& item Cell)
  item)

(define (main) : i64
  (let
    [x : Cell (Cell 1)]
    [view : (& x Cell) (pick (& x))]
    (begin
      (set! x.value 42)
      view.value)))