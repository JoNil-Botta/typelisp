;: A mutable reborrow through a nested reference-bearing struct field protects
;: the original array after the holder state leaves scope.
(defstruct NestedMutReborrowIter
  (:lifetimes source)
  (slots (&mut source (Array i64)))
  (index i64))

(defstruct NestedMutReborrowHolder
  (:lifetimes source)
  (iter (NestedMutReborrowIter source)))

(defenum NestedMutReborrowNext
  (:lifetimes source)
  (Done)
  (Item (&mut source i64)))

(define (nested-next [holder : (&mut state (NestedMutReborrowHolder source))]) : (NestedMutReborrowNext
    source)
  (let
    [index : i64 (struct-get (struct-get holder iter) index)]
    (if (>= index 1)
      (NestedMutReborrowNext.Done)
      (begin
        (set! (struct-get (struct-get holder iter) index) (+ index 1))
        (NestedMutReborrowNext.Item
          (&mut (array-ref (struct-get (struct-get holder iter) slots) index)))))))

(define (consume [value : (NestedMutReborrowNext source)]) : unit
  (match value
    [(NestedMutReborrowNext.Done) unit]
    [(NestedMutReborrowNext.Item _) unit]))

(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
    (let
      [first : (NestedMutReborrowNext items)
        (let
          [iter : (NestedMutReborrowIter items)
            (NestedMutReborrowIter (&mut items) 0)]
          [holder : (NestedMutReborrowHolder items)
            (NestedMutReborrowHolder iter)]
          (nested-next (&mut holder)))]
      (begin
        (array-set! items 0 42)
        (consume first)))))