;; A shared Slice view does not own its non-Copy elements, even when the result
;; names the view's lifetime (#8695).
(define (first [items : (& items (Array String 2))]) : (in items String)
  (array-ref (slice-view items 0 2) 0))

(define (main) : i64
  42)