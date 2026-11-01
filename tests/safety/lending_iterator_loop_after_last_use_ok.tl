;: A lending iterator can advance again after its item dies in each loop body.
(defstruct Iter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array i64)))
  (index i64))

(defenum Next
  (:lifetimes item)
  (Done)
  (Item (&mut item i64)))

(define (next [iter : (&mut item (Iter source))]) : (Next item)
  (let
    [index : i64 iter.index]
    (if (>= index 1)
      (Next.Done)
      (begin
        (set! iter.index (+ index 1))
        (Next.Item (&mut (array-ref iter.slots index)))))))

(define (consume [value : (Next source)]) : unit
  (match value
    [(Next.Done) unit]
    [(Next.Item _) unit]))

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [iter : (Iter items) (Iter (&mut items) 0)]
    [round : i64 0]
    (begin
      (while (< round 1)
        (let
          [first (next (&mut iter))]
          (begin
            (consume first)
            (next (&mut iter))
            (set! round (+ round 1)))))
      unit)))