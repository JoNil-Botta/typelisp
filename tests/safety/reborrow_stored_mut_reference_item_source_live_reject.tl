;: A mutable item reborrowed through iterator state lends from the state,
;: which holds the source borrow: while the item is live the source stays
;: borrowed (#8449).
(defstruct MutReborrowIter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array i64)))
  (index i64))

(defenum MutReborrowNext
  (:lifetimes item)
  (Done)
  (Item (&mut item i64)))

(define (mut-next [iter : (&mut item (MutReborrowIter source))]) : (MutReborrowNext
    item)
  (let
    [index : i64 iter.index]
    (if (>= index 1)
      (MutReborrowNext.Done)
      (begin
        (set! iter.index (+ index 1))
        (MutReborrowNext.Item (&mut (array-ref iter.slots index)))))))

(define (consume [value : (MutReborrowNext source)]) : unit
  (match value
    [(MutReborrowNext.Done) unit]
    [(MutReborrowNext.Item _) unit]))

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [iter : (MutReborrowIter items) (MutReborrowIter (&mut items) 0)]
    [first : (MutReborrowNext iter) (mut-next (&mut iter))]
    (begin
      (set! (array-ref items 0) 42)
      (consume first))))