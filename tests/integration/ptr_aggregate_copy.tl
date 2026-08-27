;; ptr_aggregate_copy.tl - raw aggregate writes copy the complete pointee.
;;
;; A memory aggregate is represented by an address during lowering, while a
;; two-word register group carries both words explicitly. ptr-write! must copy
;; the complete representation in either case.

(defenum Slot
  (Empty)
  (Tombstone)
  (Occupied i64 i64 i64))

(defstruct Pair
  (left i64)
  (right i64))

(define (main) : i64
  (let
    [slots : (__tl_dyn-array Slot) (__tl_make-array Slot 2)]
    [data : (MutPtr Slot)
      (unsafe
        (ptr-cast (__tl_array-data slots) : (MutPtr Slot)))]
    [pairs : (__tl_dyn-array Pair) (__tl_make-array Pair 2)]
    [pair-data : (MutPtr Pair)
      (unsafe
        (ptr-cast (__tl_array-data pairs) : (MutPtr Pair)))]
    (begin
      (set! (array-ref slots 0) (Occupied 11 22 33))
      (set! (array-ref pairs 0) (Pair 44 55))
      (unsafe
        (ptr-write! (ptr-offset data 1) (ptr-read (ptr-cast data : (Ptr Slot)))))
      (unsafe
        (ptr-write!
          (ptr-offset pair-data 1)
          (ptr-read (ptr-cast pair-data : (Ptr Pair)))))
      (match (array-ref slots 1)
        [(Occupied key value hash)
          (if (and (= key 11) (= value 22) (= hash 33))
            (let
              [pair : Pair (array-ref pairs 1)]
              (if (and (= pair.left 44) (= pair.right 55))
                0
                3))
            1)]
        [_ 2]))))