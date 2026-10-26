;; A reference held in an array element keeps its referent borrowed while the array is used.
(defstruct Item
  (value i64))

(define (pass [views : (Array (& r Item) 1)]) : (Array (& r Item) 1)
  views)

(define (main) : i64
  (let
    [holder : (Box Item) (box (Item 41))]
    [view : (& holder Item) (& (deref holder))]
    [views : (Array (& holder Item) 1) (array view)]
    (begin
      (set! (deref holder) (Item 5))
      (__tl-project-field (array-ref (pass views) 0) value))))