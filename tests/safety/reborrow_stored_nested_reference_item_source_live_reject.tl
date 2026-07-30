;: A shared reborrow through a nested reference-bearing struct field protects
;: the original array after the holder state leaves scope.
(defstruct NestedReborrowIter
  (:lifetimes source)
  (slots (& source (__tl_dyn-array i64)))
  (index i64))

(defstruct NestedReborrowHolder
  (:lifetimes source)
  (iter (NestedReborrowIter source)))

(defenum NestedReborrowNext
  (:lifetimes source)
  (Done)
  (Item (& source i64)))

(define (nested-next [holder : (&mut state (NestedReborrowHolder source))]) : (NestedReborrowNext
    source)
  (let
    [index : i64 (struct-get (struct-get holder iter) index)]
    (if (>= index 1)
      (NestedReborrowNext.Done)
      (begin
        (set! (struct-get (struct-get holder iter) index) (+ index 1))
        (NestedReborrowNext.Item
          (& (array-ref (struct-get (struct-get holder iter) slots) index)))))))

(define (consume [value : (NestedReborrowNext source)]) : unit
  (match value
    [(NestedReborrowNext.Done) unit]
    [(NestedReborrowNext.Item _) unit]))

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (let
      [first : (NestedReborrowNext items)
        (let
          [iter : (NestedReborrowIter items) (NestedReborrowIter (& items) 0)]
          [holder : (NestedReborrowHolder items) (NestedReborrowHolder iter)]
          (nested-next (&mut holder)))]
      (begin
        (array-set! items 0 42)
        (consume first)))))