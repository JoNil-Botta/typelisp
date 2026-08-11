;: A shared item reborrowed through iterator state still protects its source
;: after the state leaves scope.
(defstruct SharedReborrowIter
  (:lifetimes source)
  (slots (& source (__tl_dyn-array i64)))
  (index i64))

(defenum SharedReborrowNext
  (:lifetimes source)
  (Done)
  (Item (& source i64)))

(define (shared-next [iter : (&mut state (SharedReborrowIter source))]) : (SharedReborrowNext
    source)
  (let
    [index : i64 iter.index]
    (if (>= index 1)
      (SharedReborrowNext.Done)
      (begin
        (set! iter.index (+ index 1))
        (SharedReborrowNext.Item (& (array-ref iter.slots index)))))))

(define (consume [value : (SharedReborrowNext source)]) : unit
  (match value
    [(SharedReborrowNext.Done) unit]
    [(SharedReborrowNext.Item _) unit]))

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (let
      [first : (SharedReborrowNext items)
        (let
          [iter : (SharedReborrowIter items) (SharedReborrowIter (& items) 0)]
          (shared-next (&mut iter)))]
      (begin
        (set! (array-ref items 0) 42)
        (consume first)))))