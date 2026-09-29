;; A fixed array of lifetime-parameterized records can be borrowed as a shared
;; Slice (#8111); this row checks that the borrow keeps its owners' lifetimes.
(defstruct Item
  (:lifetimes source)
  (text (& source str)))

;; Text read through an element cannot outlive its String owner.
(define (first-text [items : (& source (Slice (Item source)))]) : (& source str)
  (array-ref items 0).text)

(define (bad [s : (& s str)]) : (& s str)
  (let
    [text : String "local"]
    [items : (Array (Item text) 1) (array (Item (& text)))]
    (first-text (& items))))

(define (main) : i64
  0)