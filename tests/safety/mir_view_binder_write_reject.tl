;: A dynamic array read through a shared reference and bound by value is a view
;: of the referent's storage: writing its elements writes through the reference.
(defstruct Counts
  (items (__tl_dyn-array i64))
  (total i64))

(define (bump [counts : (& counts Counts)]) : i64
  (let
    [items counts.items]
    (begin
      (set! (array-ref items 0) 99)
      0)))

(define (main) : i64
  (let
    [counts : Counts (Counts (__tl_make-array i64 3) 0)]
    (bump (& counts))))