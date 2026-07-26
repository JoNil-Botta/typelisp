;; ptr_aggregate_copy.tl - raw aggregate writes copy the complete pointee.
;;
;; A memory aggregate is represented by an address during lowering. The
;; ptr-write! path must emit CopyBytes instead of storing that address into the
;; first destination word.
(import stdlib.array)

(defenum Slot
  (Empty)
  (Tombstone)
  (Occupied i64 i64 i64))

(define (main) : i64
  (let
    [slots : (Array Slot) (array.make-array Slot 2)]
    [data : (MutPtr Slot)
      (unsafe
        (ptr-cast (array-data slots) : (MutPtr Slot)))]
    (begin
      (array-set! slots 0 (Occupied 11 22 33))
      (unsafe
        (ptr-write! (ptr-offset data 1) (ptr-read (ptr-cast data : (Ptr Slot)))))
      (match (array-ref slots 1)
        [(Occupied key value hash)
          (if (and (= key 11) (and (= value 22) (= hash 33)))
            0
            1)]
        [_ 2]))))