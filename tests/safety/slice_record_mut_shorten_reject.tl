;; A fixed array of lifetime-parameterized records can be borrowed as a shared
;; Slice (#8111); this row checks that the borrow keeps its owners' lifetimes.
(defstruct Item
  (:lifetimes source)
  (text (& source str)))

;; A mutable Slice cannot shorten the element lifetime: a write through it could
;; store a shorter-lived reference into the array.
(define (count-mut [items : (&mut source (Slice (Item source)))]) : i64
  (array-length items))

(define (bad) : i64
  (let
    [text : String "p"]
    [items : (Array (Item text) 1) (array (Item (& text)))]
    (count-mut (&mut items))))

(define (main) : i64
  0)