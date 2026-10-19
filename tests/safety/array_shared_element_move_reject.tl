;; A shared fixed-array reference does not own its non-Copy elements, even when
;; the result names the reference's lifetime (#8695).
(define (first [items : (& items (Array String 2))]) : (in items String)
  (array-ref items 0))

(define (main) : i64
  42)