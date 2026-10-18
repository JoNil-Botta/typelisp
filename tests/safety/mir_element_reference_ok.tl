;; A field read through an element reference before the referent is written.
(defstruct Item
  (value i64))

(define (pass [views : (Array (& r Item) 1)]) : (Array (& r Item) 1)
  views)

(define (main) : i64
  (let
    [holder : (Box Item) (box (Item 42))]
    [view : (& holder Item) (& (deref holder))]
    [views : (Array (& holder Item) 1) (array view)]
    [value : i64 (__tl-project-field (array-ref (pass views) 0) value)]
    (begin
      (set! (deref holder) (Item 5))
      value)))