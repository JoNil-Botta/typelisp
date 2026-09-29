;; A fixed array of lifetime-parameterized records can be borrowed as a shared
;; Slice (#8111); this row checks that the borrow keeps its owners' lifetimes.
(defstruct Item
  (:lifetimes source)
  (text (& source str)))

;; A Slice view of a local array cannot outlive the array.
(define (bad [s : (& s str)]) : (& s (Slice (Item s)))
  (let
    [items : (Array (Item s) 1) (array (Item s))]
    (slice-view items 0 1)))

(define (main) : i64
  0)