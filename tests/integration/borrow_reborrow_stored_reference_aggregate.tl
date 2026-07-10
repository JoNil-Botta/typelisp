;; Mutable reborrows through stored iterator references preserve an aggregate
;; element's original source lifetime as well as its nominal element type.
(defstruct AggregateReborrowItem
  (value i64))

(defstruct AggregateReborrowIter
  (:lifetimes source)
  (slots (&mut source (Array AggregateReborrowItem)))
  (index i64))

(defenum AggregateReborrowNext
  (:lifetimes source)
  (Done)
  (Item (&mut source AggregateReborrowItem)))

(define (next [iter : (&mut state (AggregateReborrowIter source))]) : (AggregateReborrowNext
    source)
  (let
    [index : i64 (struct-get iter index)]
    (if (>= index 1)
      (AggregateReborrowNext.Done)
      (begin
        (set! (struct-get iter index) (+ index 1))
        (AggregateReborrowNext.Item
          (&mut (array-ref (struct-get iter slots) index)))))))

(define (main) : i64
  (let
    [items : (Array AggregateReborrowItem) (make-array AggregateReborrowItem 1)]
    [iter : (AggregateReborrowIter items)
      (AggregateReborrowIter (&mut items) 0)]
    (match (next (&mut iter))
      [(AggregateReborrowNext.Done) 1]
      [(AggregateReborrowNext.Item item)
        (begin
          (set! item.value 42)
          item.value)])))