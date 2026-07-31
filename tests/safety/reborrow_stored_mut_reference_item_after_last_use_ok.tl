;: A returned mutable reborrow releases its source after its final use.
(defstruct MutReborrowAfterIter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array i64)))
  (index i64))

(defenum MutReborrowAfterNext
  (:lifetimes source)
  (Done)
  (Item (&mut source i64)))

(define (mut-next [iter : (&mut state (MutReborrowAfterIter source))]) : (MutReborrowAfterNext
    source)
  (let
    [index : i64 (struct-get iter index)]
    (if (>= index 1)
      (MutReborrowAfterNext.Done)
      (begin
        (set! (struct-get iter index) (+ index 1))
        (MutReborrowAfterNext.Item
          (&mut (array-ref (struct-get iter slots) index)))))))

(define (consume [value : (MutReborrowAfterNext source)]) : unit
  (match value
    [(MutReborrowAfterNext.Done) unit]
    [(MutReborrowAfterNext.Item _) unit]))

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (let
      [first : (MutReborrowAfterNext items)
        (let
          [iter : (MutReborrowAfterIter items)
            (MutReborrowAfterIter (&mut items) 0)]
          (mut-next (&mut iter)))]
      (begin
        (consume first)
        (array-set! items 0 42)))))