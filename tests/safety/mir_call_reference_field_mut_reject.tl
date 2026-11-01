;; A field read through a call's reference result keeps the referent borrowed.
(defstruct Item
  (value i64))

(define (view-of [item : (& r Item)]) : (& r Item)
  item)

(define (main) : i64
  (let
    [holder : (Box Item) (box (Item 41))]
    [view : (& holder Item) (& (deref holder))]
    (begin
      (set! (deref holder) (Item 5))
      (__tl-project-field (view-of view) value))))