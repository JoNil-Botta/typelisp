;; #8179: passing a mutable parent Slice view to a `&mut` parameter is an
;; implicit mutable reborrow, so it conflicts with a live shared child view.
;; Main 8d29b08a1 accepted it and the child observed the write (exit 79).
(define (poke! [view : (&mut s (Slice i64))]) : unit
  (set! (array-ref view 1) 99))

(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [parent : (&mut items (Slice i64)) (slice-mut-view items 0 4)]
    [child : (& items (Slice i64)) (slice-view parent 1 2)]
    [before : i64 (array-ref child 0)]
    (begin
      (poke! parent)
      (- (array-ref child 0) before))))