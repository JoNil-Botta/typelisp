;: Passing a mutable reference where a shared one is expected reborrows its
;: referent: writing through the mutable reference while the result is live
;: conflicts.
(defstruct Cell
  (value i64))

(define (pick [item : (& source Cell)]) : (& source Cell)
  item)

(define (main [exclusive : (&mut exclusive Cell)]) : i64
  (let
    [view : (& exclusive Cell) (pick exclusive)]
    (begin
      (set! exclusive.value 42)
      view.value)))