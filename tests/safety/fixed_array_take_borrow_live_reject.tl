;: Resetting a slot conflicts with a shared element borrow that remains live.
(define (main) : i64
  (let
    [items : (Array i64 1) (array 0)]
    [borrowed : (& items i64) (& (array-ref items 0))]
    [old : i64 (array-take! items (deref borrowed))]
    (+ old (deref borrowed))))