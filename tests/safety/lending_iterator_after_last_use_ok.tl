;: A mutable iterator can advance after its prior yielded result is dead.
(import stdlib.array)

(defstruct Iter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array i64)))
  (index i64))

(defenum Next
  (:lifetimes source)
  (Done)
  (Item (&mut source i64)))

(define (next [iter : (&mut state (Iter source))]) : (Next source)
  (let
    [index : i64 (struct-get iter index)]
    (if (>= index 1)
      (Next.Done)
      (begin
        (set! (struct-get iter index) (+ index 1))
        (Next.Item (&mut (array-ref (struct-get iter slots) index)))))))

(define (consume [value : (Next source)]) : unit
  (match value
    [(Next.Done) unit]
    [(Next.Item _) unit]))

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [iter : (Iter items) (Iter (&mut items) 0)]
    [first (next (&mut iter))]
    (begin
      (consume first)
      (next (&mut iter))
      unit)))