;: Reading a Copy field of an array element is a read of the element's field
;: place; the element stays in the array.
(import stdlib.string)

(defstruct Slot
  (name String)
  (generation i64))

(defstruct Stack
  (slots (__tl_dyn-array Slot))
  (count i64))

(define (generation-at [stack : Stack] [index : i64]) : i64
  (+
    (array-ref stack.slots index).generation
    (array-ref stack.slots index).generation))

(define (main) : i64
  (let
    [slots : (__tl_dyn-array Slot) (__tl_make-array Slot 1)]
    (begin
      (set! (array-ref slots 0) (Slot (string.copy "a") 21))
      (generation-at (Stack slots 1) 0))))