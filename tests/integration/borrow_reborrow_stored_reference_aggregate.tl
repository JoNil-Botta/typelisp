;; A mutable reborrow through a stored iterator reference keeps an aggregate
;; element's nominal type; it borrows the iterator, so the item lends from it
;; (#8449).
(defstruct AggregateReborrowItem
  (value i64))

(defstruct AggregateReborrowIter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array AggregateReborrowItem)))
  (index i64))

(defenum AggregateReborrowNext
  (:lifetimes item)
  (Done)
  (Item (&mut item AggregateReborrowItem)))

(define (next [iter : (&mut item (AggregateReborrowIter source))]) : (AggregateReborrowNext
    item)
  (let
    [index : i64 iter.index]
    (if (>= index 1)
      (Done)
      (begin
        (set! iter.index (+ index 1))
        (Item (&mut (array-ref iter.slots index)))))))

(define (main) : i64
  (let
    [items : (__tl_dyn-array AggregateReborrowItem)
      (__tl_make-array AggregateReborrowItem 1)]
    [iter : (AggregateReborrowIter items)
      (AggregateReborrowIter (&mut items) 0)]
    (match (next (&mut iter))
      [(Done) 1]
      [(Item item)
        (set! item.value 42)
        item.value])))