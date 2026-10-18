;: A view binder of a dynamic array read through a shared reference may be read
;: and lent shared; the referent keeps owning its storage.
(defstruct Counts
  (items (__tl_dyn-array i64))
  (total i64))

(define (first-of [items : (& items (__tl_dyn-array i64))]) : i64
  (array-ref items 0))

(define (sum [counts : (& counts Counts)]) : i64
  (let
    [items counts.items]
    (+ (array-ref items 1) (first-of (& items)))))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [counts : Counts (Counts items 0)]
    (begin
      (set! (array-ref counts.items 0) 40)
      (set! (array-ref counts.items 1) 2)
      (sum (& counts)))))