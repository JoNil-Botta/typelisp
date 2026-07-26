;; ptr_aggregate_copy.tl - raw aggregate writes copy the complete pointee.
;;
;; A memory aggregate is represented by an address during lowering, while a
;; two-word register group carries both words explicitly. ptr-write! must copy
;; the complete representation in either case.
(import stdlib.array)

(defenum Slot
  (Empty)
  (Tombstone)
  (Occupied i64 i64 i64))

(defstruct Pair
  (left i64)
  (right i64))

(define (main) : i64
  (let
    [slots : (Array Slot) (array.make-array Slot 2)]
    [data : (MutPtr Slot)
      (unsafe
        (ptr-cast (array-data slots) : (MutPtr Slot)))]
    [pairs : (Array Pair) (array.make-array Pair 2)]
    [pair-data : (MutPtr Pair)
      (unsafe
        (ptr-cast (array-data pairs) : (MutPtr Pair)))]
    (begin
      (array-set! slots 0 (Occupied 11 22 33))
      (array-set! pairs 0 (Pair 44 55))
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
              (if (and
                (= (struct-get pair left) 44)
                (= (struct-get pair right) 55))
                0
                3))
            1)]
        [_ 2]))))