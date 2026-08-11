;: A mutable item reborrowed through iterator state still protects its source
;: after the state leaves scope.
(defstruct MutReborrowIter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array i64)))
  (index i64))

(defenum MutReborrowNext
  (:lifetimes source)
  (Done)
  (Item (&mut source i64)))

(define (mut-next [iter : (&mut state (MutReborrowIter source))]) : (MutReborrowNext
    source)
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
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (let
      [first : (MutReborrowNext items)
        (let
          [iter : (MutReborrowIter items) (MutReborrowIter (&mut items) 0)]
          (mut-next (&mut iter)))]
      (begin
        (set! (array-ref items 0) 42)
        (consume first)))))