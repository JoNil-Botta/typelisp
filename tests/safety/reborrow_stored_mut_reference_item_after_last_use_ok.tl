;: A returned mutable reborrow releases its source after its final use, while
;: the iterator it lends from is still in scope (#8449).
(defstruct MutReborrowAfterIter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array i64)))
  (index i64))

(defenum MutReborrowAfterNext
  (:lifetimes item)
  (Done)
  (Item (&mut item i64)))

(define (mut-next [iter : (&mut item (MutReborrowAfterIter source))]) : (MutReborrowAfterNext
    item)
  (let
    [index : i64 iter.index]
    (if (>= index 1)
      (MutReborrowAfterNext.Done)
      (begin
        (set! iter.index (+ index 1))
        (MutReborrowAfterNext.Item (&mut (array-ref iter.slots index)))))))

(define (consume [value : (MutReborrowAfterNext source)]) : unit
  (match value
    [(MutReborrowAfterNext.Done) unit]
    [(MutReborrowAfterNext.Item _) unit]))

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [iter : (MutReborrowAfterIter items) (MutReborrowAfterIter (&mut items) 0)]
    [first : (MutReborrowAfterNext iter) (mut-next (&mut iter))]
    (begin
      (consume first)
      (set! (array-ref items 0) 42))))