(import "stdlib/test.tl")

(import "stdlib/hashmap.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

;; Predicate/extractor helpers return concrete bool/i64 (no panic in a match
;; arm) so the module typechecks on every stage0, independent of never-type.
(define (probe-found? [p : StringI64MapProbe]) : bool
  (match p
    [(StringI64MapProbeFound _) true]
    [(StringI64MapProbeAbsent _) false]
    [(StringI64MapProbeFull) false]))

(define (probe-absent? [p : StringI64MapProbe]) : bool
  (match p
    [(StringI64MapProbeAbsent _) true]
    [(StringI64MapProbeFound _) false]
    [(StringI64MapProbeFull) false]))

(define (probe-full? [p : StringI64MapProbe]) : bool
  (match p
    [(StringI64MapProbeFull) true]
    [(StringI64MapProbeFound _) false]
    [(StringI64MapProbeAbsent _) false]))

;; Slot index carried by Found/Absent; `fallback` for Full.
(define (probe-index-or [p : StringI64MapProbe] [fallback : i64]) : i64
  (match p
    [(StringI64MapProbeFound i) i]
    [(StringI64MapProbeAbsent i) i]
    [(StringI64MapProbeFull) fallback]))

;; Fill every slot of an `n`-length array with `StringI64MapEmpty`.
(define (fill-empty [slots : (Array StringI64MapSlot)] [n : i64]) : (Array
  StringI64MapSlot)
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! slots i (StringI64MapEmpty))
          (set! i (+ i 1))))
      slots)))

(define (new-slots [n : i64]) : (Array StringI64MapSlot)
  (fill-empty (make-array StringI64MapSlot n) n))

;; Lookup/insert-result extractors (concrete returns, no panic in a match arm).
(define (lookup-value-or [l : StringI64MapLookup] [fallback : i64]) : i64
  (match l
    [(StringI64MapFound v) v]
    [(StringI64MapMissing) fallback]))

(define (insert-ok? [r : StringI64MapInsertResult]) : bool
  (match r
    [(StringI64MapInsertOk _) true]
    [(StringI64MapInsertFull _) false]))

(define (insert-result-map [r : StringI64MapInsertResult]) : StringI64Map
  (match r
    [(StringI64MapInsertOk m) m]
    [(StringI64MapInsertFull m) m]))

(define (remove-ok? [r : StringI64MapRemoveResult]) : bool
  (match r
    [(StringI64MapRemoveOk _) true]
    [(StringI64MapRemoveMissing _) false]))

(define (remove-result-map [r : StringI64MapRemoveResult]) : StringI64Map
  (match r
    [(StringI64MapRemoveOk m) m]
    [(StringI64MapRemoveMissing m) m]))

;; Iteration entry extractors (concrete returns, no panic in a match arm).
(define (entry-none? [e : StringI64MapEntry]) : bool
  (match e
    [(StringI64MapEntryNone) true]
    [(StringI64MapEntrySome _ _) false]))

(define (entry-value-or [e : StringI64MapEntry] [fallback : i64]) : i64
  (match e
    [(StringI64MapEntrySome _ v) v]
    [(StringI64MapEntryNone) fallback]))

;; Generated `String -> String` map helpers.
(define (string-string-lookup-value-or
  [l : StringStringMapLookup]
  [fallback : String]) : String
  (match l
    [(StringStringMapFound v) v]
    [(StringStringMapMissing) fallback]))

(define (string-string-insert-result-map [r : StringStringMapInsertResult]) : StringStringMap
  (match r
    [(StringStringMapInsertOk m) m]
    [(StringStringMapInsertFull m) m]))

(define (string-string-remove-ok? [r : StringStringMapRemoveResult]) : bool
  (match r
    [(StringStringMapRemoveOk _) true]
    [(StringStringMapRemoveMissing _) false]))

(define (string-string-remove-result-map [r : StringStringMapRemoveResult]) : StringStringMap
  (match r
    [(StringStringMapRemoveOk m) m]
    [(StringStringMapRemoveMissing m) m]))

(define (string-string-entry-value-length-or
  [e : StringStringMapEntry]
  [fallback : i64]) : i64
  (match e
    [(StringStringMapEntrySome _ v) (string-length v)]
    [(StringStringMapEntryNone) fallback]))

;; Generated `i64 -> i64` map helpers.
(define (i64-i64-lookup-value-or [l : I64I64MapLookup] [fallback : i64]) : i64
  (match l
    [(I64I64MapFound v) v]
    [(I64I64MapMissing) fallback]))

(define (i64-i64-insert-result-map [r : I64I64MapInsertResult]) : I64I64Map
  (match r
    [(I64I64MapInsertOk m) m]
    [(I64I64MapInsertFull m) m]))

(define (i64-i64-remove-ok? [r : I64I64MapRemoveResult]) : bool
  (match r
    [(I64I64MapRemoveOk _) true]
    [(I64I64MapRemoveMissing _) false]))

(define (i64-i64-remove-result-map [r : I64I64MapRemoveResult]) : I64I64Map
  (match r
    [(I64I64MapRemoveOk m) m]
    [(I64I64MapRemoveMissing m) m]))

(define (i64-i64-entry-value-or [e : I64I64MapEntry] [fallback : i64]) : i64
  (match e
    [(I64I64MapEntrySome _ v) v]
    [(I64I64MapEntryNone) fallback]))

;; Iteration walkers (deterministic bucket order, #829). No first-class
;; functions yet, so each walk is its own tail-recursive helper started at
;; `(string-i64-map-next-occupied m 0)` and advanced with the cursor.
;; Number of live entries the cursor visits (should equal the map's len).
(define (iter-count [m : StringI64Map] [i : i64] [acc : i64]) : i64
  (if (>= i (string-i64-map-capacity m))
    acc
    (iter-count m (string-i64-map-next-occupied m (+ i 1)) (+ acc 1))))

;; Sum of every live value, visiting entries once in bucket order.
(define (iter-sum-values [m : StringI64Map] [i : i64] [acc : i64]) : i64
  (if (>= i (string-i64-map-capacity m))
    acc
    (iter-sum-values
      m
      (string-i64-map-next-occupied m (+ i 1))
      (match (string-i64-map-entry-at m i)
        [(StringI64MapEntrySome _ v) (+ acc v)]
        [(StringI64MapEntryNone) acc]))))

;; True when the cursor visits strictly increasing indices: bucket order is
;; deterministic and monotonic, so each next index exceeds the current one.
(define (iter-monotonic? [m : StringI64Map] [i : i64]) : bool
  (if (>= i (string-i64-map-capacity m))
    true
    (let
      [nxt : i64 (string-i64-map-next-occupied m (+ i 1))]
      (if (> nxt i)
        (iter-monotonic? m nxt)
        false))))

(define (string-string-iter-count [m : StringStringMap] [i : i64] [acc : i64]) : i64
  (if (>= i (string-string-map-capacity m))
    acc
    (string-string-iter-count
      m
      (string-string-map-next-occupied m (+ i 1))
      (+ acc 1))))

(define (string-string-iter-value-length-sum
  [m : StringStringMap]
  [i : i64]
  [acc : i64]) : i64
  (if (>= i (string-string-map-capacity m))
    acc
    (string-string-iter-value-length-sum
      m
      (string-string-map-next-occupied m (+ i 1))
      (+
        acc
        (string-string-entry-value-length-or (string-string-map-entry-at m i) 0)))))

(define (i64-i64-iter-count [m : I64I64Map] [i : i64] [acc : i64]) : i64
  (if (>= i (i64-i64-map-capacity m))
    acc
    (i64-i64-iter-count m (i64-i64-map-next-occupied m (+ i 1)) (+ acc 1))))

(define (i64-i64-iter-value-sum [m : I64I64Map] [i : i64] [acc : i64]) : i64
  (if (>= i (i64-i64-map-capacity m))
    acc
    (i64-i64-iter-value-sum
      m
      (i64-i64-map-next-occupied m (+ i 1))
      (+ acc (i64-i64-entry-value-or (i64-i64-map-entry-at m i) 0)))))

(define (main) : i64
  (begin
    ;; --- hashmap-family key descriptor contract (#2056) ---
    (assert-owned-string-eq
      (hashmap-string-key-descriptor-key)
      "stdlib/hashmap/string-key-v1"
      "String key descriptor identity")
    (assert-owned-string-eq
      (hashmap-i64-key-descriptor-key)
      "stdlib/hashmap/i64-key-v1"
      "i64 key descriptor identity")
    ;; --- bucket-index math + wraparound ---
    (assert-i64-eq (string-i64-map-bucket-index 5 4) 1 "bucket 5 % 4")
    (assert-i64-eq (string-i64-map-bucket-index 8 4) 0 "bucket 8 % 4")
    ;; negative hash is normalized into [0, modulus) first: -1 -> 2147483646,
    ;; and 2147483646 % 4 = 2.
    (assert-i64-eq (string-i64-map-bucket-index -1 4) 2 "bucket negative")
    (assert-i64-eq (string-i64-map-next-index 3 4) 0 "next wraps 3 -> 0")
    (assert-i64-eq (string-i64-map-next-index 1 4) 2 "next 1 -> 2")
    ;; --- zero / one capacity ---
    (assert-true
      (probe-full? (string-i64-map-probe (new-slots 1) 0 "k" 5))
      "zero capacity is full")
    (let
      [one : (Array StringI64MapSlot) (new-slots 1)]
      (begin
        (assert-true
          (probe-absent? (string-i64-map-probe one 1 "k" 5))
          "capacity one empty is absent")
        (assert-i64-eq
          (probe-index-or (string-i64-map-probe one 1 "k" 5) -1)
          0
          "capacity one absent slot 0")))
    ;; --- empty table: absent at the start bucket ---
    (let
      [empty : (Array StringI64MapSlot) (new-slots 4)]
      (begin
        (assert-true
          (probe-absent? (string-i64-map-probe empty 4 "k" 5))
          "empty table absent")
        (assert-i64-eq
          (probe-index-or (string-i64-map-probe empty 4 "k" 5) -1)
          1
          "empty absent at bucket 1")))
    ;; --- found: occupied slot with matching hash + key ---
    (let
      [found : (Array StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! found 1 (StringI64MapOccupied "k" 7 5))
        (assert-true
          (probe-found? (string-i64-map-probe found 4 "k" 5))
          "occupied key found")
        (assert-i64-eq
          (probe-index-or (string-i64-map-probe found 4 "k" 5) -1)
          1
          "found at slot 1")))
    ;; --- collision walk: same hash, different key, walk to next empty ---
    (let
      [collide : (Array StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! collide 1 (StringI64MapOccupied "other" 9 5))
        (assert-true
          (probe-absent? (string-i64-map-probe collide 4 "k" 5))
          "collision then absent")
        (assert-i64-eq
          (probe-index-or (string-i64-map-probe collide 4 "k" 5) -1)
          2
          "collision walks to slot 2")))
    ;; --- wraparound: bucket 3 occupied, walk wraps to slot 0 ---
    (let
      [wrap : (Array StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! wrap 3 (StringI64MapOccupied "o" 9 3))
        (assert-i64-eq
          (probe-index-or (string-i64-map-probe wrap 4 "k" 3) -1)
          0
          "wraparound walks 3 -> 0")))
    ;; --- tombstone reuse: insert position is the tombstone, not the empty ---
    (let
      [tomb : (Array StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! tomb 1 (StringI64MapTombstone))
        (assert-true
          (probe-absent? (string-i64-map-probe tomb 4 "k" 5))
          "tombstone path absent")
        (assert-i64-eq
          (probe-index-or (string-i64-map-probe tomb 4 "k" 5) -1)
          1
          "tombstone reused at slot 1")))
    ;; --- found after a tombstone: probing does not stop at a tombstone ---
    (let
      [tf : (Array StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! tf 1 (StringI64MapTombstone))
        (array-set! tf 2 (StringI64MapOccupied "k" 7 5))
        (assert-true
          (probe-found? (string-i64-map-probe tf 4 "k" 5))
          "found past tombstone")
        (assert-i64-eq
          (probe-index-or (string-i64-map-probe tf 4 "k" 5) -1)
          2
          "found at slot 2 past tombstone")))
    ;; --- full table, no tombstone: probe terminates as full ---
    (let
      [full : (Array StringI64MapSlot) (new-slots 2)]
      (begin
        (array-set! full 0 (StringI64MapOccupied "a" 1 10))
        (array-set! full 1 (StringI64MapOccupied "b" 2 11))
        (assert-true
          (probe-full? (string-i64-map-probe full 2 "k" 4))
          "full table is full")))
    ;; --- full table with a tombstone: absent at the tombstone, not full ---
    (let
      [fulltomb : (Array StringI64MapSlot) (new-slots 2)]
      (begin
        (array-set! fulltomb 0 (StringI64MapOccupied "a" 1 10))
        (array-set! fulltomb 1 (StringI64MapTombstone))
        (assert-true
          (probe-absent? (string-i64-map-probe fulltomb 2 "k" 4))
          "full-with-tombstone is absent")
        (assert-i64-eq
          (probe-index-or (string-i64-map-probe fulltomb 2 "k" 4) -1)
          1
          "absent at the tombstone slot")))
    ;; --- map API (#826): with-capacity / insert / get / contains? / len ---
    (let
      [m0 : StringI64Map (string-i64-map-with-capacity 8)]
      (begin
        (assert-i64-eq (string-i64-map-len m0) 0 "fresh map len 0")
        (assert-false (string-i64-map-contains? m0 "x") "fresh map has no key")
        (let
          [m1 : StringI64Map
            (insert-result-map (string-i64-map-insert m0 "alpha" 11))]
          [m2 : StringI64Map
            (insert-result-map (string-i64-map-insert m1 "beta" 22))]
          [m3 : StringI64Map
            (insert-result-map (string-i64-map-insert m2 "gamma" 33))]
          (begin
            (assert-i64-eq (string-i64-map-len m3) 3 "len after three inserts")
            (assert-i64-eq
              (lookup-value-or (string-i64-map-get m3 "alpha") -1)
              11
              "get alpha")
            (assert-i64-eq
              (lookup-value-or (string-i64-map-get m3 "beta") -1)
              22
              "get beta")
            (assert-i64-eq
              (lookup-value-or (string-i64-map-get m3 "gamma") -1)
              33
              "get gamma")
            (assert-true (string-i64-map-contains? m3 "beta") "contains beta")
            (assert-false
              (string-i64-map-contains? m3 "missing")
              "missing key absent")
            (assert-i64-eq
              (lookup-value-or (string-i64-map-get m3 "missing") -1)
              -1
              "get missing -> fallback")
            ;; updating an existing key keeps len and changes the value
            (let
              [m4 : StringI64Map
                (insert-result-map (string-i64-map-insert m3 "alpha" 99))]
              (begin
                (assert-i64-eq
                  (string-i64-map-len m4)
                  3
                  "len unchanged on update")
                (assert-i64-eq
                  (lookup-value-or (string-i64-map-get m4 "alpha") -1)
                  99
                  "alpha updated to 99")))
            ;; a fixed capacity-1 table is full for a second distinct key
            (let
              [s0 : StringI64Map (string-i64-map-with-capacity 1)]
              [s1 : StringI64Map
                (insert-result-map (string-i64-map-insert s0 "only" 7))]
              (begin
                (assert-i64-eq
                  (lookup-value-or (string-i64-map-get s1 "only") -1)
                  7
                  "capacity-1 get only")
                (assert-false
                  (insert-ok? (string-i64-map-insert s1 "second" 8))
                  "capacity-1 second insert is full")))))))
    ;; --- removal + tombstone accounting (#829) ---
    (let
      [r0 : StringI64Map (string-i64-map-with-capacity 8)]
      [r1 : StringI64Map (insert-result-map (string-i64-map-insert r0 "k1" 10))]
      [r2 : StringI64Map (insert-result-map (string-i64-map-insert r1 "k2" 20))]
      (begin
        (assert-i64-eq (string-i64-map-len r2) 2 "removal: two inserts len 2")
        (assert-i64-eq
          (string-i64-map-deleted r2)
          0
          "removal: no tombstones yet")
        ;; remove-miss: absent key leaves the map unchanged and untouched.
        (let
          [miss : StringI64MapRemoveResult (string-i64-map-remove r2 "absent")]
          (begin
            (assert-false (remove-ok? miss) "remove-miss is not ok")
            (assert-i64-eq
              (string-i64-map-len (remove-result-map miss))
              2
              "remove-miss keeps len")
            (assert-i64-eq
              (string-i64-map-deleted (remove-result-map miss))
              0
              "remove-miss adds no tombstone")))
        ;; remove-hit: k1 becomes a tombstone; len-1, deleted+1, k2 survives.
        (let
          [hit : StringI64MapRemoveResult (string-i64-map-remove r2 "k1")]
          (begin
            (assert-true (remove-ok? hit) "remove-hit is ok")
            (let
              [r3 : StringI64Map (remove-result-map hit)]
              (begin
                (assert-i64-eq (string-i64-map-len r3) 1 "remove-hit len 1")
                (assert-i64-eq
                  (string-i64-map-deleted r3)
                  1
                  "remove-hit deleted 1")
                (assert-i64-eq
                  (lookup-value-or (string-i64-map-get r3 "k1") -1)
                  -1
                  "k1 missing after remove")
                (assert-true
                  (string-i64-map-contains? r3 "k2")
                  "k2 survives k1 removal")
                ;; reinsert after delete reuses the tombstone: len back to 2,
                ;; deleted back to 0, new value visible.
                (let
                  [r4 : StringI64Map
                    (insert-result-map (string-i64-map-insert r3 "k1" 111))]
                  (begin
                    (assert-i64-eq (string-i64-map-len r4) 2 "reinsert len 2")
                    (assert-i64-eq
                      (string-i64-map-deleted r4)
                      0
                      "reinsert reuses tombstone (deleted 0)")
                    (assert-i64-eq
                      (lookup-value-or (string-i64-map-get r4 "k1") -1)
                      111
                      "k1 reinserted value")))))))))
    ;; --- resize / rehash (#827) ---
    ;; needs-grow? threshold: a fresh capacity-4 table is below the 3/4 load.
    (assert-false
      (string-i64-map-needs-grow? (string-i64-map-with-capacity 4))
      "fresh cap-4 below load threshold")
    (assert-true
      (string-i64-map-needs-grow? (string-i64-map-with-capacity 0))
      "zero-capacity always needs grow")
    ;; string-i64-map-put auto-grows past the fixed capacity and preserves every
    ;; entry across the rehash (collision preservation + lookup after rehash).
    (let
      [g0 : StringI64Map (string-i64-map-with-capacity 4)]
      [g1 : StringI64Map (string-i64-map-put g0 "a" 1)]
      [g2 : StringI64Map (string-i64-map-put g1 "b" 2)]
      [g3 : StringI64Map (string-i64-map-put g2 "c" 3)]
      [g4 : StringI64Map (string-i64-map-put g3 "d" 4)]
      [g5 : StringI64Map (string-i64-map-put g4 "e" 5)]
      [g6 : StringI64Map (string-i64-map-put g5 "f" 6)]
      (begin
        (assert-i64-eq (string-i64-map-len g6) 6 "put six -> len 6")
        (assert-true
          (> (string-i64-map-capacity g6) 4)
          "table grew past the seed capacity")
        (assert-i64-eq
          (string-i64-map-deleted g6)
          0
          "grown table has no tombstones")
        (assert-i64-eq
          (lookup-value-or (string-i64-map-get g6 "a") -1)
          1
          "get a after grow")
        (assert-i64-eq
          (lookup-value-or (string-i64-map-get g6 "c") -1)
          3
          "get c after grow")
        (assert-i64-eq
          (lookup-value-or (string-i64-map-get g6 "f") -1)
          6
          "get f after grow")
        (assert-i64-eq
          (lookup-value-or (string-i64-map-get g6 "missing") -1)
          -1
          "absent key after grow")
        ;; overwrite across resize: updating an existing key keeps len.
        (let
          [g7 : StringI64Map (string-i64-map-put g6 "a" 99)]
          (begin
            (assert-i64-eq
              (string-i64-map-len g7)
              6
              "update keeps len after grow")
            (assert-i64-eq
              (lookup-value-or (string-i64-map-get g7 "a") -1)
              99
              "a updated to 99 after grow")))))
    ;; resized drops tombstones: insert 3, remove 1 (deleted=1), resize to 16.
    (let
      [t0 : StringI64Map (string-i64-map-with-capacity 8)]
      [t1 : StringI64Map (insert-result-map (string-i64-map-insert t0 "x" 10))]
      [t2 : StringI64Map (insert-result-map (string-i64-map-insert t1 "y" 20))]
      [t3 : StringI64Map (insert-result-map (string-i64-map-insert t2 "z" 30))]
      [t4 : StringI64Map (remove-result-map (string-i64-map-remove t3 "y"))]
      (begin
        (assert-i64-eq
          (string-i64-map-deleted t4)
          1
          "one tombstone before resize")
        (let
          [t5 : StringI64Map (string-i64-map-resized t4 16)]
          (begin
            (assert-i64-eq
              (string-i64-map-capacity t5)
              16
              "resized capacity 16")
            (assert-i64-eq (string-i64-map-len t5) 2 "resized len 2")
            (assert-i64-eq
              (string-i64-map-deleted t5)
              0
              "resize drops tombstones")
            (assert-i64-eq
              (lookup-value-or (string-i64-map-get t5 "x") -1)
              10
              "x survives resize")
            (assert-i64-eq
              (lookup-value-or (string-i64-map-get t5 "z") -1)
              30
              "z survives resize")
            (assert-i64-eq
              (lookup-value-or (string-i64-map-get t5 "y") -1)
              -1
              "removed y absent after resize")))))
    ;; --- deterministic bucket-order iteration (#829) ---
    ;; empty map: the cursor starts at the capacity; count and sum are zero.
    (let
      [e0 : StringI64Map (string-i64-map-with-capacity 8)]
      (begin
        (assert-i64-eq
          (string-i64-map-next-occupied e0 0)
          8
          "empty map cursor starts at capacity")
        (assert-i64-eq
          (iter-count e0 (string-i64-map-next-occupied e0 0) 0)
          0
          "empty map iterates zero entries")
        (assert-i64-eq
          (iter-sum-values e0 (string-i64-map-next-occupied e0 0) 0)
          0
          "empty map sum is zero")))
    ;; non-empty map: the cursor visits exactly `len` entries, sums every value
    ;; once, and walks strictly increasing (deterministic bucket) indices.
    (let
      [i0 : StringI64Map (string-i64-map-with-capacity 8)]
      [i1 : StringI64Map (string-i64-map-put i0 "a" 1)]
      [i2 : StringI64Map (string-i64-map-put i1 "b" 2)]
      [i3 : StringI64Map (string-i64-map-put i2 "c" 4)]
      [i4 : StringI64Map (string-i64-map-put i3 "d" 8)]
      (begin
        (assert-i64-eq
          (string-i64-map-len i4)
          4
          "iteration map has four entries")
        (assert-i64-eq
          (iter-count i4 (string-i64-map-next-occupied i4 0) 0)
          4
          "cursor visits exactly len entries")
        (assert-i64-eq
          (iter-sum-values i4 (string-i64-map-next-occupied i4 0) 0)
          15
          "cursor sums every value once (1+2+4+8)")
        (assert-true
          (iter-monotonic? i4 (string-i64-map-next-occupied i4 0))
          "cursor visits strictly increasing indices")
        ;; a removed key is skipped: its tombstone is not iterated.
        (let
          [i5 : StringI64Map (remove-result-map (string-i64-map-remove i4 "b"))]
          (begin
            (assert-i64-eq (string-i64-map-len i5) 3 "len 3 after removing b")
            (assert-i64-eq
              (iter-count i5 (string-i64-map-next-occupied i5 0) 0)
              3
              "cursor skips the tombstone (count 3)")
            (assert-i64-eq
              (iter-sum-values i5 (string-i64-map-next-occupied i5 0) 0)
              13
              "cursor sum excludes the removed value (1+4+8)")))))
    ;; entry-at: out-of-range -> None, the only occupied slot -> Some value.
    (let
      [b0 : StringI64Map (string-i64-map-with-capacity 4)]
      [b1 : StringI64Map (string-i64-map-put b0 "only" 7)]
      (begin
        (assert-true
          (entry-none? (string-i64-map-entry-at b1 -1))
          "entry-at negative index is None")
        (assert-true
          (entry-none? (string-i64-map-entry-at b1 4))
          "entry-at out-of-range index is None")
        (assert-i64-eq
          (entry-value-or
            (string-i64-map-entry-at b1 (string-i64-map-next-occupied b1 0))
            -1)
          7
          "entry-at the only occupied slot is Some 7")))
    ;; --- generated String -> String map family (#817) ---
    (let
      [alpha : String "alpha"]
      [beta : String "beta"]
      [missing : String "missing"]
      [ss0 : StringStringMap (string-string-map-with-capacity 4)]
      [ss1 : StringStringMap (string-string-map-put ss0 "alpha" "red")]
      [ss2 : StringStringMap (string-string-map-put ss1 "beta" "amber")]
      [ss3 : StringStringMap (string-string-map-put ss2 "gamma" "blue")]
      [ss4 : StringStringMap (string-string-map-put ss3 "delta" "gold")]
      [ss5 : StringStringMap (string-string-map-put ss4 "alpha" "green")]
      (begin
        (assert-i64-eq (string-string-map-len ss5) 4 "StringString len")
        (assert-true
          (> (string-string-map-capacity ss5) 4)
          "StringString grew past seed capacity")
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (string-string-map-get-borrowed ss5 (& alpha))
            "fallback")
          "green"
          "StringString borrowed get updated alpha")
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (string-string-map-get ss5 "gamma")
            "fallback")
          "blue"
          "StringString owned get gamma")
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (string-string-map-get-borrowed ss5 (& missing))
            "fallback")
          "fallback"
          "StringString missing borrowed get")
        (assert-true
          (string-string-map-contains-borrowed? ss5 (& beta))
          "StringString borrowed contains beta")
        (let
          [removed : StringStringMapRemoveResult
            (string-string-map-remove-borrowed ss5 (& beta))]
          (begin
            (assert-true
              (string-string-remove-ok? removed)
              "StringString remove borrowed beta")
            (let
              [ss6 : StringStringMap (string-string-remove-result-map removed)]
              (begin
                (assert-i64-eq
                  (string-string-map-len ss6)
                  3
                  "StringString len after remove")
                (assert-i64-eq
                  (string-string-map-deleted ss6)
                  1
                  "StringString tombstone after remove")
                (assert-false
                  (string-string-map-contains-borrowed? ss6 (& beta))
                  "StringString beta absent after remove")
                (assert-i64-eq
                  (string-string-iter-count
                    ss6
                    (string-string-map-next-occupied ss6 0)
                    0)
                  3
                  "StringString iteration count")
                (assert-i64-eq
                  (string-string-iter-value-length-sum
                    ss6
                    (string-string-map-next-occupied ss6 0)
                    0)
                  13
                  "StringString iteration value length sum")))))))
    ;; --- generated i64 -> i64 map family (#817) ---
    (let
      [ii0 : I64I64Map (i64-i64-map-with-capacity 4)]
      [ii1 : I64I64Map (i64-i64-map-put ii0 1 10)]
      [ii2 : I64I64Map (i64-i64-map-put ii1 2 20)]
      [ii3 : I64I64Map (i64-i64-map-put ii2 3 30)]
      [ii4 : I64I64Map (i64-i64-map-put ii3 4 40)]
      [ii5 : I64I64Map (i64-i64-map-put ii4 1 99)]
      (begin
        (assert-i64-eq (i64-i64-map-len ii5) 4 "I64I64 len")
        (assert-true
          (> (i64-i64-map-capacity ii5) 4)
          "I64I64 grew past seed capacity")
        (assert-i64-eq
          (i64-i64-lookup-value-or (i64-i64-map-get ii5 1) -1)
          99
          "I64I64 updated key 1")
        (assert-i64-eq
          (i64-i64-lookup-value-or (i64-i64-map-get ii5 3) -1)
          30
          "I64I64 get key 3")
        (assert-i64-eq
          (i64-i64-lookup-value-or (i64-i64-map-get ii5 99) -1)
          -1
          "I64I64 missing key")
        (assert-true (i64-i64-map-contains? ii5 2) "I64I64 contains key 2")
        (let
          [removed : I64I64MapRemoveResult (i64-i64-map-remove ii5 2)]
          (begin
            (assert-true (i64-i64-remove-ok? removed) "I64I64 remove key 2")
            (let
              [ii6 : I64I64Map (i64-i64-remove-result-map removed)]
              (begin
                (assert-i64-eq
                  (i64-i64-map-len ii6)
                  3
                  "I64I64 len after remove")
                (assert-i64-eq
                  (i64-i64-map-deleted ii6)
                  1
                  "I64I64 tombstone after remove")
                (assert-false
                  (i64-i64-map-contains? ii6 2)
                  "I64I64 removed key absent")
                (assert-i64-eq
                  (i64-i64-iter-count ii6 (i64-i64-map-next-occupied ii6 0) 0)
                  3
                  "I64I64 iteration count")
                (assert-i64-eq
                  (i64-i64-iter-value-sum
                    ii6
                    (i64-i64-map-next-occupied ii6 0)
                    0)
                  169
                  "I64I64 iteration value sum")))))))
    42))