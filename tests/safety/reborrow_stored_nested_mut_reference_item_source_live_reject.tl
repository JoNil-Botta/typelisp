;: A mutable reborrow through a nested reference-bearing struct field lends
;: from the holder, which holds the array borrow: while the item is live the
;: array stays borrowed (#8449).
(defstruct NestedMutReborrowIter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array i64)))
  (index i64))

(defstruct NestedMutReborrowHolder
  (:lifetimes source)
  (iter (NestedMutReborrowIter source)))

(defenum NestedMutReborrowNext
  (:lifetimes item)
  (Done)
  (Item (&mut item i64)))

(define (nested-next [holder : (&mut item (NestedMutReborrowHolder source))]) : (NestedMutReborrowNext
    item)
  (let
    [index : i64 holder.iter.index]
    (if (>= index 1)
      (NestedMutReborrowNext.Done)
      (begin
        (set! holder.iter.index (+ index 1))
        (NestedMutReborrowNext.Item (&mut (array-ref holder.iter.slots index)))))))

(define (consume [value : (NestedMutReborrowNext source)]) : unit
  (match value
    [(NestedMutReborrowNext.Done) unit]
    [(NestedMutReborrowNext.Item _) unit]))

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [iter : (NestedMutReborrowIter items)
      (NestedMutReborrowIter (&mut items) 0)]
    [holder : (NestedMutReborrowHolder items) (NestedMutReborrowHolder iter)]
    [first : (NestedMutReborrowNext holder) (nested-next (&mut holder))]
    (begin
      (set! (array-ref items 0) 42)
      (consume first))))