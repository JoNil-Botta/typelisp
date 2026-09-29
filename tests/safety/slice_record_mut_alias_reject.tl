;; A fixed array of lifetime-parameterized records can be borrowed as a shared
;; Slice (#8111); this row checks that the borrow keeps its owners' lifetimes.
(defstruct Item
  (:lifetimes source)
  (text (& source str)))

;; A shared Slice borrow is rejected while the array is mutably borrowed.
(define (count [items : (& source (Slice (Item source)))]) : i64
  (array-length items))

(define (bad) : i64
  (let
    [text : String "p"]
    [items : (Array (Item text) 1) (array (Item (& text)))]
    [m : (&mut items (Array (Item text) 1)) (&mut items)]
    (+ (count (& items)) (array-length m))))

(define (main) : i64
  0)