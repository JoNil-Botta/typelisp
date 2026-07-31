;: A returned stored-reference reborrow protects only its original projection;
;: an unrelated sibling remains mutable.
(defstruct ReborrowSiblingArrays
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))

(defstruct ReborrowSiblingIter
  (:lifetimes source)
  (slots (& source (__tl_dyn-array i64)))
  (index i64))

(defenum ReborrowSiblingNext
  (:lifetimes source)
  (Done)
  (Item (& source i64)))

(define (next [iter : (&mut state (ReborrowSiblingIter source))]) : (ReborrowSiblingNext
    source)
  (let
    [index : i64 (struct-get iter index)]
    (if (>= index 1)
      (ReborrowSiblingNext.Done)
      (begin
        (set! (struct-get iter index) (+ index 1))
        (ReborrowSiblingNext.Item (& (array-ref (struct-get iter slots) index)))))))

(define (consume [value : (ReborrowSiblingNext source)]) : unit
  (match value
    [(ReborrowSiblingNext.Done) unit]
    [(ReborrowSiblingNext.Item _) unit]))

(define (main) : unit
  (let
    [pairs : ReborrowSiblingArrays
      (ReborrowSiblingArrays (make-array i64 1) (make-array i64 1))]
    (let
      [first : (ReborrowSiblingNext pairs)
        (let
          [iter : (ReborrowSiblingIter pairs)
            (ReborrowSiblingIter (& (struct-get pairs left)) 0)]
          (next (&mut iter)))]
      (begin
        (array-set! (struct-get pairs right) 0 42)
        (consume first)))))