;; A fixed array of lifetime-parameterized records storing shared references is
;; borrowed as a native Slice at a typed call (#8111, the issue's reproducer):
;; the element lifetime `text` shortens to the array borrow's, as a shared
;; borrow of one element would.
(defstruct Item
  (:lifetimes source)
  (text (& source str)))

(define (count [items : (& source (Slice (Item source)))]) : i64
  (array-length items))

(define (main) : i64
  (let
    [text : String "payload"]
    [item : (Item text) (Item (& text))]
    [items : (Array (Item text) 1) (array item)]
    (count (& items))))