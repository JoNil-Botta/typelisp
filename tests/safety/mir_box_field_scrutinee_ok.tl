;; A by-value match on a Copy field of box contents copies it out; the box
;; stays usable.
(defenum Kind
  (Number i64)
  (Empty))

(defstruct Payload
  (kind Kind))

(define (main) : i64
  (let
    [boxed : (Box Payload) (box (Payload (Kind.Number 40)))]
    [first : i64
      (match (deref boxed).kind
        [(Number value) value]
        [(Empty) 0])]
    (+
      first
      (match (deref boxed).kind
        [(Number value) (- value 38)]
        [(Empty) 0]))))