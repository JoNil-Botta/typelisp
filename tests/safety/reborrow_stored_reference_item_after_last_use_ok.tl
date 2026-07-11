;: A returned shared reborrow releases its source after its final use.
(defstruct SharedReborrowAfterIter
  (:lifetimes source)
  (slots (& source (Array i64)))
  (index i64))

(defenum SharedReborrowAfterNext
  (:lifetimes source)
  (Done)
  (Item (& source i64)))

(define (shared-next [iter : (&mut state (SharedReborrowAfterIter source))]) : (SharedReborrowAfterNext
    source)
  (let
    [index : i64 (struct-get iter index)]
    (if (>= index 1)
      (SharedReborrowAfterNext.Done)
      (begin
        (set! (struct-get iter index) (+ index 1))
        (SharedReborrowAfterNext.Item
          (& (array-ref (struct-get iter slots) index)))))))

(define (consume [value : (SharedReborrowAfterNext source)]) : unit
  (match value
    [(SharedReborrowAfterNext.Done) unit]
    [(SharedReborrowAfterNext.Item _) unit]))

(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
    (let
      [first : (SharedReborrowAfterNext items)
        (let
          [iter : (SharedReborrowAfterIter items)
            (SharedReborrowAfterIter (& items) 0)]
          (shared-next (&mut iter)))]
      (begin
        (consume first)
        (array-set! items 0 42)))))