;: A mutable borrow of a view binder borrows the shared referent mutably.
(defstruct Counts
  (items (__tl_dyn-array i64))
  (total i64))

(define (fill! [items : (&mut items (__tl_dyn-array i64))]) : unit
  (set! (array-ref items 0) 7))

(define (refill [counts : (& counts Counts)]) : i64
  (let
    [items counts.items]
    (begin
      (fill! (&mut items))
      0)))

(define (main) : i64
  (let
    [counts : Counts (Counts (__tl_make-array i64 3) 0)]
    (refill (& counts))))