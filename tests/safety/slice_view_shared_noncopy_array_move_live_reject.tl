;; A live shared Slice blocks moving a fixed array whose element struct contains
;; String and is therefore not structurally Copyable.
(defstruct Payload
  (text String)
  (value i64))

(define (main) : i64
  (let
    [items : (Array Payload 2) (array (Payload "left" 10) (Payload "right" 20))]
    [view : (& items (Slice Payload)) (slice-view items 0 2)]
    [moved : (Array Payload 2) items]
    (+
      (struct-get (array-ref view 0) value)
      (struct-get (array-ref moved 0) value))))