(import stdlib.test)

(import stdlib.hashmap)

(defstruct HashPayload
  (score i64)
  (weight i64))

(defenum HashState
  (HashReady i64)
  (HashFailed)
  (HashPaused i64))

(comptime-decl
  (:generated stdlib/hashmap-family I64StringMap (type-key (type i64)) (type-key
    (type String)) "stdlib/hashmap/i64-key-v1")
  (defstruct I64StringMap
    (__hashmap_family_request i64)))

(comptime-decl
  (:generated stdlib/hashmap-family StringHashPayloadMap (type-key
    (type String)) (type-key (type HashPayload)) "stdlib/hashmap/string-key-v1")
  (defstruct StringHashPayloadMap
    (__hashmap_family_request i64)))

(comptime-decl
  (:generated stdlib/hashmap-family I64HashStateMap (type-key (type i64)) (type-key
    (type HashState)) "stdlib/hashmap/i64-key-v1")
  (defstruct I64HashStateMap
    (__hashmap_family_request i64)))

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

;; Predicate/extractor helpers return concrete bool/i64 (no panic in a match
;; arm) so the module typechecks on every stage0, independent of never-type.
(define (probe-found? [p : hashmap.StringI64MapProbe]) : bool
  (match p
    [(hashmap.StringI64MapProbeFound _) true]
    [(hashmap.StringI64MapProbeAbsent _) false]
    [(hashmap.StringI64MapProbeFull) false]))

(define (probe-absent? [p : hashmap.StringI64MapProbe]) : bool
  (match p
    [(hashmap.StringI64MapProbeAbsent _) true]
    [(hashmap.StringI64MapProbeFound _) false]
    [(hashmap.StringI64MapProbeFull) false]))

(define (probe-full? [p : hashmap.StringI64MapProbe]) : bool
  (match p
    [(hashmap.StringI64MapProbeFull) true]
    [(hashmap.StringI64MapProbeFound _) false]
    [(hashmap.StringI64MapProbeAbsent _) false]))

;; Slot index carried by Found/Absent; `fallback` for Full.
(define (probe-index-or [p : hashmap.StringI64MapProbe] [fallback : i64]) : i64
  (match p
    [(hashmap.StringI64MapProbeFound i) i]
    [(hashmap.StringI64MapProbeAbsent i) i]
    [(hashmap.StringI64MapProbeFull) fallback]))

;; Fill every slot of an `n`-length array with `StringI64MapEmpty`.
(define (fill-empty [slots : (Array hashmap.StringI64MapSlot)] [n : i64]) : (Array
    hashmap.StringI64MapSlot)
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! slots i (hashmap.StringI64MapEmpty))
          (set! i (+ i 1))))
      slots)))

(define (new-slots [n : i64]) : (Array hashmap.StringI64MapSlot)
  (fill-empty (make-array hashmap.StringI64MapSlot n) n))

;; Lookup/insert-result extractors (concrete returns, no panic in a match arm).
(define (lookup-value-or [l : hashmap.StringI64MapLookup] [fallback : i64]) : i64
  (match l
    [(hashmap.StringI64MapFound v) v]
    [(hashmap.StringI64MapMissing) fallback]))

(define (string-i64-borrowed-value-found?
  [l : (hashmap.StringI64MapBorrowedValueLookup map)]) : bool
  (match l
    [(hashmap.StringI64MapBorrowedValueFound _) true]
    [(hashmap.StringI64MapBorrowedValueMissing) false]))

(define (insert-ok? [r : hashmap.StringI64MapInsertResult]) : bool
  (match r
    [(hashmap.StringI64MapInsertOk _) true]
    [(hashmap.StringI64MapInsertFull _) false]))

(define (insert-result-map [r : hashmap.StringI64MapInsertResult]) : hashmap.StringI64Map
  (match r
    [(hashmap.StringI64MapInsertOk m) m]
    [(hashmap.StringI64MapInsertFull m) m]))

(define (remove-ok? [r : hashmap.StringI64MapRemoveResult]) : bool
  (match r
    [(hashmap.StringI64MapRemoveOk _) true]
    [(hashmap.StringI64MapRemoveMissing _) false]))

(define (remove-result-map [r : hashmap.StringI64MapRemoveResult]) : hashmap.StringI64Map
  (match r
    [(hashmap.StringI64MapRemoveOk m) m]
    [(hashmap.StringI64MapRemoveMissing m) m]))

(define (update-ok? [r : hashmap.StringI64MapUpdateResult]) : bool
  (match r
    [(hashmap.StringI64MapUpdateOk _) true]
    [(hashmap.StringI64MapUpdateMissing _) false]))

(define (update-result-map [r : hashmap.StringI64MapUpdateResult]) : hashmap.StringI64Map
  (match r
    [(hashmap.StringI64MapUpdateOk m) m]
    [(hashmap.StringI64MapUpdateMissing m) m]))

(define (entry-or-insert-inserted? [r : hashmap.StringI64MapEntryOrInsertResult]) : bool
  (match r
    [(hashmap.StringI64MapEntryOrInsertInserted _ _) true]
    [(hashmap.StringI64MapEntryOrInsertFound _ _) false]))

(define (entry-or-insert-result-map [r : hashmap.StringI64MapEntryOrInsertResult]) : hashmap.StringI64Map
  (match r
    [(hashmap.StringI64MapEntryOrInsertFound m _) m]
    [(hashmap.StringI64MapEntryOrInsertInserted m _) m]))

(define (entry-or-insert-value-or
  [r : hashmap.StringI64MapEntryOrInsertResult]
  [fallback : i64]) : i64
  (match r
    [(hashmap.StringI64MapEntryOrInsertFound _ v) v]
    [(hashmap.StringI64MapEntryOrInsertInserted _ v) v]))

;; Iteration entry extractors (concrete returns, no panic in a match arm).
(define (entry-none? [e : hashmap.StringI64MapEntry]) : bool
  (match e
    [(hashmap.StringI64MapEntryNone) true]
    [(hashmap.StringI64MapEntrySome _ _) false]))

(define (entry-value-or [e : hashmap.StringI64MapEntry] [fallback : i64]) : i64
  (match e
    [(hashmap.StringI64MapEntrySome _ v) v]
    [(hashmap.StringI64MapEntryNone) fallback]))

;; Generated `String -> String` map helpers.
(define (string-string-lookup-value-or
  [l : hashmap.StringStringMapLookup]
  [fallback : String]) : String
  (match l
    [(hashmap.StringStringMapFound v) v]
    [(hashmap.StringStringMapMissing) fallback]))

(define (string-string-borrowed-value-length-or
  [l : (hashmap.StringStringMapBorrowedValueLookup map)]
  [fallback : i64]) : i64
  (match l
    [(hashmap.StringStringMapBorrowedValueFound v) (string-length v)]
    [(hashmap.StringStringMapBorrowedValueMissing) fallback]))

(define (string-string-insert-result-map [r : hashmap.StringStringMapInsertResult]) : hashmap.StringStringMap
  (match r
    [(hashmap.StringStringMapInsertOk m) m]
    [(hashmap.StringStringMapInsertFull m) m]))

(define (string-string-remove-ok? [r : hashmap.StringStringMapRemoveResult]) : bool
  (match r
    [(hashmap.StringStringMapRemoveOk _) true]
    [(hashmap.StringStringMapRemoveMissing _) false]))

(define (string-string-remove-result-map [r : hashmap.StringStringMapRemoveResult]) : hashmap.StringStringMap
  (match r
    [(hashmap.StringStringMapRemoveOk m) m]
    [(hashmap.StringStringMapRemoveMissing m) m]))

(define (string-string-update-ok? [r : hashmap.StringStringMapUpdateResult]) : bool
  (match r
    [(hashmap.StringStringMapUpdateOk _) true]
    [(hashmap.StringStringMapUpdateMissing _) false]))

(define (string-string-update-result-map [r : hashmap.StringStringMapUpdateResult]) : hashmap.StringStringMap
  (match r
    [(hashmap.StringStringMapUpdateOk m) m]
    [(hashmap.StringStringMapUpdateMissing m) m]))

(define (string-string-entry-or-insert-inserted?
  [r : hashmap.StringStringMapEntryOrInsertResult]) : bool
  (match r
    [(hashmap.StringStringMapEntryOrInsertInserted _ _) true]
    [(hashmap.StringStringMapEntryOrInsertFound _ _) false]))

(define (string-string-entry-or-insert-result-map
  [r : hashmap.StringStringMapEntryOrInsertResult]) : hashmap.StringStringMap
  (match r
    [(hashmap.StringStringMapEntryOrInsertFound m _) m]
    [(hashmap.StringStringMapEntryOrInsertInserted m _) m]))

(define (string-string-entry-or-insert-value-or
  [r : hashmap.StringStringMapEntryOrInsertResult]
  [fallback : String]) : String
  (match r
    [(hashmap.StringStringMapEntryOrInsertFound _ v) v]
    [(hashmap.StringStringMapEntryOrInsertInserted _ v) v]))

(define (string-string-entry-value-length-or
  [e : hashmap.StringStringMapEntry]
  [fallback : i64]) : i64
  (match e
    [(hashmap.StringStringMapEntrySome _ v) (string-length v)]
    [(hashmap.StringStringMapEntryNone) fallback]))

;; Generated `i64 -> i64` map helpers.
(define (i64-i64-lookup-value-or [l : hashmap.I64I64MapLookup] [fallback : i64]) : i64
  (match l
    [(hashmap.I64I64MapFound v) v]
    [(hashmap.I64I64MapMissing) fallback]))

(define (i64-i64-borrowed-value-found? [l : (hashmap.I64I64MapBorrowedValueLookup map)]) : bool
  (match l
    [(hashmap.I64I64MapBorrowedValueFound _) true]
    [(hashmap.I64I64MapBorrowedValueMissing) false]))

(define (i64-string-borrowed-value-length-or
  [l : (I64StringMapBorrowedValueLookup map)]
  [fallback : i64]) : i64
  (match l
    [(I64StringMapBorrowedValueFound v) (string-length v)]
    [(I64StringMapBorrowedValueMissing) fallback]))

(define (i64-i64-insert-result-map [r : hashmap.I64I64MapInsertResult]) : hashmap.I64I64Map
  (match r
    [(hashmap.I64I64MapInsertOk m) m]
    [(hashmap.I64I64MapInsertFull m) m]))

(define (i64-i64-remove-ok? [r : hashmap.I64I64MapRemoveResult]) : bool
  (match r
    [(hashmap.I64I64MapRemoveOk _) true]
    [(hashmap.I64I64MapRemoveMissing _) false]))

(define (i64-i64-remove-result-map [r : hashmap.I64I64MapRemoveResult]) : hashmap.I64I64Map
  (match r
    [(hashmap.I64I64MapRemoveOk m) m]
    [(hashmap.I64I64MapRemoveMissing m) m]))

(define (i64-i64-update-ok? [r : hashmap.I64I64MapUpdateResult]) : bool
  (match r
    [(hashmap.I64I64MapUpdateOk _) true]
    [(hashmap.I64I64MapUpdateMissing _) false]))

(define (i64-i64-update-result-map [r : hashmap.I64I64MapUpdateResult]) : hashmap.I64I64Map
  (match r
    [(hashmap.I64I64MapUpdateOk m) m]
    [(hashmap.I64I64MapUpdateMissing m) m]))

(define (i64-i64-entry-or-insert-inserted? [r : hashmap.I64I64MapEntryOrInsertResult]) : bool
  (match r
    [(hashmap.I64I64MapEntryOrInsertInserted _ _) true]
    [(hashmap.I64I64MapEntryOrInsertFound _ _) false]))

(define (i64-i64-entry-or-insert-result-map [r : hashmap.I64I64MapEntryOrInsertResult]) : hashmap.I64I64Map
  (match r
    [(hashmap.I64I64MapEntryOrInsertFound m _) m]
    [(hashmap.I64I64MapEntryOrInsertInserted m _) m]))

(define (i64-i64-entry-or-insert-value-or
  [r : hashmap.I64I64MapEntryOrInsertResult]
  [fallback : i64]) : i64
  (match r
    [(hashmap.I64I64MapEntryOrInsertFound _ v) v]
    [(hashmap.I64I64MapEntryOrInsertInserted _ v) v]))

(define (i64-i64-entry-value-or [e : hashmap.I64I64MapEntry] [fallback : i64]) : i64
  (match e
    [(hashmap.I64I64MapEntrySome _ v) v]
    [(hashmap.I64I64MapEntryNone) fallback]))

;; Generated `String -> HashPayload` aggregate-value map helpers.
(define (hash-payload-score [value : HashPayload]) : i64
  (+ (struct-get value score) (struct-get value weight)))

(define (string-hash-payload-lookup-score-or
  [l : StringHashPayloadMapLookup]
  [fallback : i64]) : i64
  (match l
    [(StringHashPayloadMapFound v) (hash-payload-score v)]
    [(StringHashPayloadMapMissing) fallback]))

(define (string-hash-payload-borrowed-score-or
  [l : (StringHashPayloadMapBorrowedValueLookup map)]
  [fallback : i64]) : i64
  (match l
    [(StringHashPayloadMapBorrowedValueFound v)
      (+ (struct-get v score) (struct-get v weight))]
    [(StringHashPayloadMapBorrowedValueMissing) fallback]))

(define (string-hash-payload-remove-ok? [r : StringHashPayloadMapRemoveResult]) : bool
  (match r
    [(StringHashPayloadMapRemoveOk _) true]
    [(StringHashPayloadMapRemoveMissing _) false]))

(define (string-hash-payload-remove-result-map
  [r : StringHashPayloadMapRemoveResult]) : StringHashPayloadMap
  (match r
    [(StringHashPayloadMapRemoveOk m) m]
    [(StringHashPayloadMapRemoveMissing m) m]))

(define (string-hash-payload-update-ok? [r : StringHashPayloadMapUpdateResult]) : bool
  (match r
    [(StringHashPayloadMapUpdateOk _) true]
    [(StringHashPayloadMapUpdateMissing _) false]))

(define (string-hash-payload-update-result-map
  [r : StringHashPayloadMapUpdateResult]) : StringHashPayloadMap
  (match r
    [(StringHashPayloadMapUpdateOk m) m]
    [(StringHashPayloadMapUpdateMissing m) m]))

(define (string-hash-payload-entry-score-or
  [e : StringHashPayloadMapEntry]
  [fallback : i64]) : i64
  (match e
    [(StringHashPayloadMapEntrySome _ v) (hash-payload-score v)]
    [(StringHashPayloadMapEntryNone) fallback]))

;; Generated `i64 -> HashState` aggregate-value map helpers.
(define (hash-state-score [value : HashState]) : i64
  (match value
    [(HashReady n) n]
    [(HashFailed) -100]
    [(HashPaused n) (- 0 n)]))

(define (i64-hash-state-lookup-score-or
  [l : I64HashStateMapLookup]
  [fallback : i64]) : i64
  (match l
    [(I64HashStateMapFound v) (hash-state-score v)]
    [(I64HashStateMapMissing) fallback]))

(define (i64-hash-state-remove-ok? [r : I64HashStateMapRemoveResult]) : bool
  (match r
    [(I64HashStateMapRemoveOk _) true]
    [(I64HashStateMapRemoveMissing _) false]))

(define (i64-hash-state-remove-result-map [r : I64HashStateMapRemoveResult]) : I64HashStateMap
  (match r
    [(I64HashStateMapRemoveOk m) m]
    [(I64HashStateMapRemoveMissing m) m]))

(define (i64-hash-state-update-ok? [r : I64HashStateMapUpdateResult]) : bool
  (match r
    [(I64HashStateMapUpdateOk _) true]
    [(I64HashStateMapUpdateMissing _) false]))

(define (i64-hash-state-update-result-map [r : I64HashStateMapUpdateResult]) : I64HashStateMap
  (match r
    [(I64HashStateMapUpdateOk m) m]
    [(I64HashStateMapUpdateMissing m) m]))

(define (i64-hash-state-entry-or-insert-inserted?
  [r : I64HashStateMapEntryOrInsertResult]) : bool
  (match r
    [(I64HashStateMapEntryOrInsertInserted _ _) true]
    [(I64HashStateMapEntryOrInsertFound _ _) false]))

(define (i64-hash-state-entry-or-insert-result-map
  [r : I64HashStateMapEntryOrInsertResult]) : I64HashStateMap
  (match r
    [(I64HashStateMapEntryOrInsertFound m _) m]
    [(I64HashStateMapEntryOrInsertInserted m _) m]))

(define (i64-hash-state-entry-or-insert-score-or
  [r : I64HashStateMapEntryOrInsertResult]) : i64
  (match r
    [(I64HashStateMapEntryOrInsertFound _ v) (hash-state-score v)]
    [(I64HashStateMapEntryOrInsertInserted _ v) (hash-state-score v)]))

(define (i64-hash-state-entry-score-or
  [e : I64HashStateMapEntry]
  [fallback : i64]) : i64
  (match e
    [(I64HashStateMapEntrySome _ v) (hash-state-score v)]
    [(I64HashStateMapEntryNone) fallback]))

;; Iteration walkers (deterministic bucket order, #829). No first-class
;; functions yet, so each walk is its own tail-recursive helper started at
;; `(string-i64-map-next-occupied m 0)` and advanced with the cursor.
;; Number of live entries the cursor visits (should equal the map's len).
(define (iter-count [m : hashmap.StringI64Map] [i : i64] [acc : i64]) : i64
  (if (>= i (hashmap.string-i64-map-capacity m))
    acc
    (iter-count m (hashmap.string-i64-map-next-occupied m (+ i 1)) (+ acc 1))))

;; Sum of every live value, visiting entries once in bucket order.
(define (iter-sum-values [m : hashmap.StringI64Map] [i : i64] [acc : i64]) : i64
  (if (>= i (hashmap.string-i64-map-capacity m))
    acc
    (iter-sum-values
      m
      (hashmap.string-i64-map-next-occupied m (+ i 1))
      (match (hashmap.string-i64-map-entry-at m i)
        [(hashmap.StringI64MapEntrySome _ v) (+ acc v)]
        [(hashmap.StringI64MapEntryNone) acc]))))

;; True when the cursor visits strictly increasing indices: bucket order is
;; deterministic and monotonic, so each next index exceeds the current one.
(define (iter-monotonic? [m : hashmap.StringI64Map] [i : i64]) : bool
  (if (>= i (hashmap.string-i64-map-capacity m))
    true
    (let
      [nxt : i64 (hashmap.string-i64-map-next-occupied m (+ i 1))]
      (if (> nxt i)
        (iter-monotonic? m nxt)
        false))))

(define (string-string-iter-count [m : hashmap.StringStringMap] [i : i64] [acc : i64]) : i64
  (if (>= i (hashmap.string-string-map-capacity m))
    acc
    (string-string-iter-count
      m
      (hashmap.string-string-map-next-occupied m (+ i 1))
      (+ acc 1))))

(define (string-string-iter-value-length-sum
  [m : hashmap.StringStringMap]
  [i : i64]
  [acc : i64]) : i64
  (if (>= i (hashmap.string-string-map-capacity m))
    acc
    (string-string-iter-value-length-sum
      m
      (hashmap.string-string-map-next-occupied m (+ i 1))
      (+
        acc
        (string-string-entry-value-length-or (hashmap.string-string-map-entry-at m i) 0)))))

(define (i64-i64-iter-count [m : hashmap.I64I64Map] [i : i64] [acc : i64]) : i64
  (if (>= i (hashmap.i64-i64-map-capacity m))
    acc
    (i64-i64-iter-count m (hashmap.i64-i64-map-next-occupied m (+ i 1)) (+ acc 1))))

(define (i64-i64-iter-value-sum [m : hashmap.I64I64Map] [i : i64] [acc : i64]) : i64
  (if (>= i (hashmap.i64-i64-map-capacity m))
    acc
    (i64-i64-iter-value-sum
      m
      (hashmap.i64-i64-map-next-occupied m (+ i 1))
      (+ acc (i64-i64-entry-value-or (hashmap.i64-i64-map-entry-at m i) 0)))))

(define (string-hash-payload-iter-count
  [m : StringHashPayloadMap]
  [i : i64]
  [acc : i64]) : i64
  (if (>= i (string-hash-payload-map-capacity m))
    acc
    (string-hash-payload-iter-count
      m
      (string-hash-payload-map-next-occupied m (+ i 1))
      (+ acc 1))))

(define (string-hash-payload-iter-score-sum
  [m : StringHashPayloadMap]
  [i : i64]
  [acc : i64]) : i64
  (if (>= i (string-hash-payload-map-capacity m))
    acc
    (string-hash-payload-iter-score-sum
      m
      (string-hash-payload-map-next-occupied m (+ i 1))
      (+
        acc
        (string-hash-payload-entry-score-or
          (string-hash-payload-map-entry-at m i)
          0)))))

(define (i64-hash-state-iter-count [m : I64HashStateMap] [i : i64] [acc : i64]) : i64
  (if (>= i (i64-hash-state-map-capacity m))
    acc
    (i64-hash-state-iter-count
      m
      (i64-hash-state-map-next-occupied m (+ i 1))
      (+ acc 1))))

(define (i64-hash-state-iter-score-sum
  [m : I64HashStateMap]
  [i : i64]
  [acc : i64]) : i64
  (if (>= i (i64-hash-state-map-capacity m))
    acc
    (i64-hash-state-iter-score-sum
      m
      (i64-hash-state-map-next-occupied m (+ i 1))
      (+
        acc
        (i64-hash-state-entry-score-or (i64-hash-state-map-entry-at m i) 0)))))

(define (main) : i64
  (begin
    ;; --- hashmap-family key descriptor contract (#2056) ---
    (assert-owned-string-eq
      (hashmap.hashmap-string-key-descriptor-key)
      "stdlib/hashmap/string-key-v1"
      "String key descriptor identity")
    (assert-owned-string-eq
      (hashmap.hashmap-i64-key-descriptor-key)
      "stdlib/hashmap/i64-key-v1"
      "i64 key descriptor identity")
    ;; --- hashmap-family marker request fixture beyond shipped families ---
    (let
      [fixture0 : I64StringMap (i64-string-map-with-capacity 2)]
      [fixture1 : I64StringMap (i64-string-map-put fixture0 7 "seven")]
      (begin
        (test.assert-i64-eq
          (i64-string-map-len fixture1)
          1
          "i64->String fixture generated len helper")
        (assert-owned-string-eq
          (match (i64-string-map-get fixture1 7)
            [(I64StringMapFound value) value]
            [(I64StringMapMissing) "missing"])
          "seven"
          "i64->String fixture generated get helper")
        (test.assert-i64-eq
          (i64-string-borrowed-value-length-or
            (i64-string-map-get-value-borrowed (& fixture1) 7)
            -1)
          5
          "i64->String fixture borrowed value helper")
        (test.assert-false
          (i64-string-map-contains? fixture1 9)
          "i64->String fixture generated contains helper")))
    ;; --- hashmap-family aggregate value fixtures (#2728) ---
    (let
      [alpha : String "alpha"]
      [payload0 : StringHashPayloadMap
        (string-hash-payload-map-with-capacity 2)]
      [payload1 : StringHashPayloadMap
        (string-hash-payload-map-put payload0 "alpha" (HashPayload 3 4))]
      [payload2 : StringHashPayloadMap
        (string-hash-payload-map-put payload1 "beta" (HashPayload 5 6))]
      [payload3 : StringHashPayloadMap
        (string-hash-payload-map-put payload2 "gamma" (HashPayload 7 8))]
      [payload-hit : StringHashPayloadMapUpdateResult
        (string-hash-payload-map-update-borrowed-if-present
          payload3
          (& alpha)
          (HashPayload 20 1))]
      [payload4 : StringHashPayloadMap
        (string-hash-payload-update-result-map payload-hit)]
      (begin
        (test.assert-true
          (> (string-hash-payload-map-capacity payload4) 2)
          "StringHashPayload grows aggregate values")
        (test.assert-true
          (string-hash-payload-update-ok? payload-hit)
          "StringHashPayload borrowed update hit")
        (test.assert-i64-eq
          (string-hash-payload-lookup-score-or
            (string-hash-payload-map-get payload4 "alpha")
            -1)
          21
          "StringHashPayload owned get updated aggregate")
        (test.assert-i64-eq
          (string-hash-payload-borrowed-score-or
            (string-hash-payload-map-get-value-borrowed (& payload4) (& alpha))
            -1)
          21
          "StringHashPayload borrowed value exposes fields")
        (let
          [payload-remove : StringHashPayloadMapRemoveResult
            (string-hash-payload-map-remove payload4 "beta")]
          [payload5 : StringHashPayloadMap
            (string-hash-payload-remove-result-map payload-remove)]
          (begin
            (test.assert-true
              (string-hash-payload-remove-ok? payload-remove)
              "StringHashPayload remove aggregate")
            (test.assert-false
              (string-hash-payload-map-contains? payload5 "beta")
              "StringHashPayload removed key absent")
            (test.assert-i64-eq
              (string-hash-payload-iter-count
                payload5
                (string-hash-payload-map-next-occupied payload5 0)
                0)
              2
              "StringHashPayload iteration count")
            (test.assert-i64-eq
              (string-hash-payload-iter-score-sum
                payload5
                (string-hash-payload-map-next-occupied payload5 0)
                0)
              36
              "StringHashPayload iteration score sum")))))
    (let
      [states0 : I64HashStateMap (i64-hash-state-map-with-capacity 2)]
      [states1 : I64HashStateMap
        (i64-hash-state-map-put states0 1 (HashReady 10))]
      [states2 : I64HashStateMap
        (i64-hash-state-map-put states1 2 (HashFailed))]
      [states3 : I64HashStateMap
        (i64-hash-state-map-put states2 3 (HashPaused 7))]
      [state-hit : I64HashStateMapUpdateResult
        (i64-hash-state-map-update-if-present states3 2 (HashReady 22))]
      [states4 : I64HashStateMap (i64-hash-state-update-result-map state-hit)]
      (begin
        (test.assert-true
          (> (i64-hash-state-map-capacity states4) 2)
          "I64HashState grows enum values")
        (test.assert-true
          (i64-hash-state-update-ok? state-hit)
          "I64HashState update hit")
        (test.assert-i64-eq
          (i64-hash-state-lookup-score-or (i64-hash-state-map-get states4 2) -1)
          22
          "I64HashState get updated enum")
        (test.assert-i64-eq
          (i64-hash-state-lookup-score-or
            (i64-hash-state-map-get states4 99)
            -1)
          -1
          "I64HashState missing enum")
        (let
          [state-remove : I64HashStateMapRemoveResult
            (i64-hash-state-map-remove states4 1)]
          [states5 : I64HashStateMap
            (i64-hash-state-remove-result-map state-remove)]
          [state-inserted : I64HashStateMapEntryOrInsertResult
            (i64-hash-state-map-entry-or-insert states5 4 (HashReady 40))]
          [states6 : I64HashStateMap
            (i64-hash-state-entry-or-insert-result-map state-inserted)]
          [state-found : I64HashStateMapEntryOrInsertResult
            (i64-hash-state-map-entry-or-insert states6 2 (HashFailed))]
          [states7 : I64HashStateMap
            (i64-hash-state-entry-or-insert-result-map state-found)]
          (begin
            (test.assert-true
              (i64-hash-state-remove-ok? state-remove)
              "I64HashState remove enum")
            (test.assert-true
              (i64-hash-state-entry-or-insert-inserted? state-inserted)
              "I64HashState entry-or-insert inserted")
            (test.assert-i64-eq
              (i64-hash-state-entry-or-insert-score-or state-inserted)
              40
              "I64HashState entry-or-insert default enum")
            (test.assert-false
              (i64-hash-state-entry-or-insert-inserted? state-found)
              "I64HashState entry-or-insert found")
            (test.assert-i64-eq
              (i64-hash-state-entry-or-insert-score-or state-found)
              22
              "I64HashState entry-or-insert existing enum")
            (test.assert-i64-eq
              (i64-hash-state-iter-count
                states7
                (i64-hash-state-map-next-occupied states7 0)
                0)
              3
              "I64HashState iteration count")
            (test.assert-i64-eq
              (i64-hash-state-iter-score-sum
                states7
                (i64-hash-state-map-next-occupied states7 0)
                0)
              55
              "I64HashState iteration score sum")))))
    ;; --- bucket-index math + wraparound ---
    (test.assert-i64-eq (hashmap.string-i64-map-bucket-index 5 4) 1 "bucket 5 mask 4")
    (test.assert-i64-eq (hashmap.string-i64-map-bucket-index 8 4) 0 "bucket 8 mask 4")
    ;; negative hash is normalized into [0, modulus) first: -1 -> 2147483646,
    ;; and 2147483646 & 3 = 2.
    (test.assert-i64-eq (hashmap.string-i64-map-bucket-index -1 4) 2 "bucket negative")
    (test.assert-true
      (hashmap.string-i64-map-power-two-capacity? 8)
      "power-of-two capacity recognized")
    (test.assert-false
      (hashmap.string-i64-map-power-two-capacity? 10)
      "non-power-of-two capacity rejected")
    (test.assert-i64-eq
      (hashmap.string-i64-map-round-capacity 0)
      1
      "zero requested capacity rounds to one")
    (test.assert-i64-eq (hashmap.string-i64-map-round-capacity 3) 4 "capacity 3 rounds to 4")
    (test.assert-i64-eq
      (hashmap.string-i64-map-round-capacity 10)
      16
      "capacity 10 rounds to 16")
    (test.assert-i64-eq
      (hashmap.string-i64-map-normalized-bucket-index 13 8)
      5
      "normalized bucket masks capacity")
    (test.assert-i64-eq (hashmap.string-i64-map-next-index 3 4) 0 "next wraps 3 -> 0")
    (test.assert-i64-eq (hashmap.string-i64-map-next-index 1 4) 2 "next 1 -> 2")
    ;; --- zero / one capacity ---
    (test.assert-true
      (probe-full? (hashmap.string-i64-map-probe (new-slots 1) 0 "k" 5))
      "zero capacity is full")
    (let
      [one : (Array hashmap.StringI64MapSlot) (new-slots 1)]
      (begin
        (test.assert-true
          (probe-absent? (hashmap.string-i64-map-probe one 1 "k" 5))
          "capacity one empty is absent")
        (test.assert-i64-eq
          (probe-index-or (hashmap.string-i64-map-probe one 1 "k" 5) -1)
          0
          "capacity one absent slot 0")))
    ;; --- empty table: absent at the start bucket ---
    (let
      [empty : (Array hashmap.StringI64MapSlot) (new-slots 4)]
      (begin
        (test.assert-true
          (probe-absent? (hashmap.string-i64-map-probe empty 4 "k" 5))
          "empty table absent")
        (test.assert-i64-eq
          (probe-index-or (hashmap.string-i64-map-probe empty 4 "k" 5) -1)
          1
          "empty absent at bucket 1")))
    ;; --- found: occupied slot with matching hash + key ---
    (let
      [found : (Array hashmap.StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! found 1 (hashmap.StringI64MapOccupied "k" 7 5))
        (test.assert-true
          (probe-found? (hashmap.string-i64-map-probe found 4 "k" 5))
          "occupied key found")
        (test.assert-i64-eq
          (probe-index-or (hashmap.string-i64-map-probe found 4 "k" 5) -1)
          1
          "found at slot 1")))
    ;; --- collision walk: same hash, different key, walk to next empty ---
    (let
      [collide : (Array hashmap.StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! collide 1 (hashmap.StringI64MapOccupied "other" 9 5))
        (test.assert-true
          (probe-absent? (hashmap.string-i64-map-probe collide 4 "k" 5))
          "collision then absent")
        (test.assert-i64-eq
          (probe-index-or (hashmap.string-i64-map-probe collide 4 "k" 5) -1)
          2
          "collision walks to slot 2")))
    ;; --- wraparound: bucket 3 occupied, walk wraps to slot 0 ---
    (let
      [wrap : (Array hashmap.StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! wrap 3 (hashmap.StringI64MapOccupied "o" 9 3))
        (test.assert-i64-eq
          (probe-index-or (hashmap.string-i64-map-probe wrap 4 "k" 3) -1)
          0
          "wraparound walks 3 -> 0")))
    ;; --- tombstone reuse: insert position is the tombstone, not the empty ---
    (let
      [tomb : (Array hashmap.StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! tomb 1 (hashmap.StringI64MapTombstone))
        (test.assert-true
          (probe-absent? (hashmap.string-i64-map-probe tomb 4 "k" 5))
          "tombstone path absent")
        (test.assert-i64-eq
          (probe-index-or (hashmap.string-i64-map-probe tomb 4 "k" 5) -1)
          1
          "tombstone reused at slot 1")))
    ;; --- found after a tombstone: probing does not stop at a tombstone ---
    (let
      [tf : (Array hashmap.StringI64MapSlot) (new-slots 4)]
      (begin
        (array-set! tf 1 (hashmap.StringI64MapTombstone))
        (array-set! tf 2 (hashmap.StringI64MapOccupied "k" 7 5))
        (test.assert-true
          (probe-found? (hashmap.string-i64-map-probe tf 4 "k" 5))
          "found past tombstone")
        (test.assert-i64-eq
          (probe-index-or (hashmap.string-i64-map-probe tf 4 "k" 5) -1)
          2
          "found at slot 2 past tombstone")))
    ;; --- full table, no tombstone: probe terminates as full ---
    (let
      [full : (Array hashmap.StringI64MapSlot) (new-slots 2)]
      (begin
        (array-set! full 0 (hashmap.StringI64MapOccupied "a" 1 10))
        (array-set! full 1 (hashmap.StringI64MapOccupied "b" 2 11))
        (test.assert-true
          (probe-full? (hashmap.string-i64-map-probe full 2 "k" 4))
          "full table is full")))
    ;; --- full table with a tombstone: absent at the tombstone, not full ---
    (let
      [fulltomb : (Array hashmap.StringI64MapSlot) (new-slots 2)]
      (begin
        (array-set! fulltomb 0 (hashmap.StringI64MapOccupied "a" 1 10))
        (array-set! fulltomb 1 (hashmap.StringI64MapTombstone))
        (test.assert-true
          (probe-absent? (hashmap.string-i64-map-probe fulltomb 2 "k" 4))
          "full-with-tombstone is absent")
        (test.assert-i64-eq
          (probe-index-or (hashmap.string-i64-map-probe fulltomb 2 "k" 4) -1)
          1
          "absent at the tombstone slot")))
    ;; --- map API (#826): with-capacity / insert / get / contains? / len ---
    (let
      [alpha-key : String "alpha"]
      [missing-key : String "missing"]
      [m0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 8)]
      (begin
        (test.assert-i64-eq (hashmap.string-i64-map-len m0) 0 "fresh map len 0")
        (test.assert-i64-eq
          (hashmap.string-i64-map-capacity (hashmap.string-i64-map-with-capacity 10))
          16
          "manual map rounds requested capacity")
        (test.assert-false (hashmap.string-i64-map-contains? m0 "x") "fresh map has no key")
        (let
          [m1 : hashmap.StringI64Map
            (insert-result-map (hashmap.string-i64-map-insert m0 "alpha" 11))]
          [m2 : hashmap.StringI64Map
            (insert-result-map (hashmap.string-i64-map-insert m1 "beta" 22))]
          [m3 : hashmap.StringI64Map
            (insert-result-map (hashmap.string-i64-map-insert m2 "gamma" 33))]
          (begin
            (test.assert-i64-eq (hashmap.string-i64-map-len m3) 3 "len after three inserts")
            (test.assert-i64-eq
              (lookup-value-or (hashmap.string-i64-map-get m3 "alpha") -1)
              11
              "get alpha")
            (test.assert-true
              (string-i64-borrowed-value-found?
                (hashmap.string-i64-map-get-value-borrowed (& m3) (& alpha-key)))
              "StringI64 borrowed value get finds alpha")
            (test.assert-i64-eq
              (lookup-value-or (hashmap.string-i64-map-get m3 "beta") -1)
              22
              "get beta")
            (test.assert-i64-eq
              (lookup-value-or (hashmap.string-i64-map-get m3 "gamma") -1)
              33
              "get gamma")
            (test.assert-true (hashmap.string-i64-map-contains? m3 "beta") "contains beta")
            (test.assert-false
              (hashmap.string-i64-map-contains? m3 "missing")
              "missing key absent")
            (test.assert-i64-eq
              (lookup-value-or (hashmap.string-i64-map-get m3 "missing") -1)
              -1
              "get missing -> fallback")
            (test.assert-false
              (string-i64-borrowed-value-found?
                (hashmap.string-i64-map-get-value-borrowed (& m3) (& missing-key)))
              "StringI64 missing borrowed value get")
            ;; updating an existing key keeps len and changes the value
            (let
              [m4 : hashmap.StringI64Map
                (insert-result-map (hashmap.string-i64-map-insert m3 "alpha" 99))]
              (begin
                (test.assert-i64-eq
                  (hashmap.string-i64-map-len m4)
                  3
                  "len unchanged on update")
                (test.assert-i64-eq
                  (lookup-value-or (hashmap.string-i64-map-get m4 "alpha") -1)
                  99
                  "alpha updated to 99")))
            ;; a fixed capacity-1 table is full for a second distinct key
            (let
              [s0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 1)]
              [s1 : hashmap.StringI64Map
                (insert-result-map (hashmap.string-i64-map-insert s0 "only" 7))]
              (begin
                (test.assert-i64-eq
                  (lookup-value-or (hashmap.string-i64-map-get s1 "only") -1)
                  7
                  "capacity-1 get only")
                (test.assert-false
                  (insert-ok? (hashmap.string-i64-map-insert s1 "second" 8))
                  "capacity-1 second insert is full")))))))
    ;; --- removal + tombstone accounting (#829) ---
    (let
      [r0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 8)]
      [r1 : hashmap.StringI64Map (insert-result-map (hashmap.string-i64-map-insert r0 "k1" 10))]
      [r2 : hashmap.StringI64Map (insert-result-map (hashmap.string-i64-map-insert r1 "k2" 20))]
      (begin
        (test.assert-i64-eq (hashmap.string-i64-map-len r2) 2 "removal: two inserts len 2")
        (test.assert-i64-eq
          (hashmap.string-i64-map-deleted r2)
          0
          "removal: no tombstones yet")
        ;; remove-miss: absent key leaves the map unchanged and untouched.
        (let
          [miss : hashmap.StringI64MapRemoveResult (hashmap.string-i64-map-remove r2 "absent")]
          (begin
            (test.assert-false (remove-ok? miss) "remove-miss is not ok")
            (test.assert-i64-eq
              (hashmap.string-i64-map-len (remove-result-map miss))
              2
              "remove-miss keeps len")
            (test.assert-i64-eq
              (hashmap.string-i64-map-deleted (remove-result-map miss))
              0
              "remove-miss adds no tombstone")))
        ;; remove-hit: k1 becomes a tombstone; len-1, deleted+1, k2 survives.
        (let
          [hit : hashmap.StringI64MapRemoveResult (hashmap.string-i64-map-remove r2 "k1")]
          (begin
            (test.assert-true (remove-ok? hit) "remove-hit is ok")
            (let
              [r3 : hashmap.StringI64Map (remove-result-map hit)]
              (begin
                (test.assert-i64-eq (hashmap.string-i64-map-len r3) 1 "remove-hit len 1")
                (test.assert-i64-eq
                  (hashmap.string-i64-map-deleted r3)
                  1
                  "remove-hit deleted 1")
                (test.assert-i64-eq
                  (lookup-value-or (hashmap.string-i64-map-get r3 "k1") -1)
                  -1
                  "k1 missing after remove")
                (test.assert-true
                  (hashmap.string-i64-map-contains? r3 "k2")
                  "k2 survives k1 removal")
                ;; reinsert after delete reuses the tombstone: len back to 2,
                ;; deleted back to 0, new value visible.
                (let
                  [r4 : hashmap.StringI64Map
                    (insert-result-map (hashmap.string-i64-map-insert r3 "k1" 111))]
                  (begin
                    (test.assert-i64-eq (hashmap.string-i64-map-len r4) 2 "reinsert len 2")
                    (test.assert-i64-eq
                      (hashmap.string-i64-map-deleted r4)
                      0
                      "reinsert reuses tombstone (deleted 0)")
                    (test.assert-i64-eq
                      (lookup-value-or (hashmap.string-i64-map-get r4 "k1") -1)
                      111
                      "k1 reinserted value")))))))))
    ;; --- update / entry-or-insert API (#888) ---
    (let
      [u0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [u1 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
      [u2 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u1 "beta" 20)]
      [hit : hashmap.StringI64MapUpdateResult
        (hashmap.string-i64-map-update-if-present u2 "alpha" 70)]
      [u3 : hashmap.StringI64Map (update-result-map hit)]
      (begin
        (test.assert-true (update-ok? hit) "update-if-present hit is ok")
        (test.assert-i64-eq (hashmap.string-i64-map-len u3) 2 "update hit keeps len")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get u3 "alpha") -1)
          70
          "update hit overwrites alpha")))
    (let
      [u0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [u1 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
      [miss : hashmap.StringI64MapUpdateResult
        (hashmap.string-i64-map-update-if-present u1 "missing" 999)]
      [u2 : hashmap.StringI64Map (update-result-map miss)]
      (begin
        (test.assert-false (update-ok? miss) "update missing is not ok")
        (test.assert-i64-eq (hashmap.string-i64-map-len u2) 1 "update missing keeps len")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get u2 "missing") -1)
          -1
          "update missing does not insert")))
    (let
      [u0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [u1 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u0 "beta" 20)]
      [borrow-key : String "beta"]
      [borrow-hit : hashmap.StringI64MapUpdateResult
        (hashmap.string-i64-map-update-borrowed-if-present u1 (& borrow-key) 80)]
      [u2 : hashmap.StringI64Map (update-result-map borrow-hit)]
      (begin
        (test.assert-true
          (update-ok? borrow-hit)
          "borrowed update-if-present hit is ok")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get u2 "beta") -1)
          80
          "borrowed update overwrites beta")))
    (let
      [u0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [u1 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
      [u2 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u1 "beta" 20)]
      [removed : hashmap.StringI64MapRemoveResult (hashmap.string-i64-map-remove u2 "alpha")]
      [u6 : hashmap.StringI64Map (remove-result-map removed)]
      [inserted : hashmap.StringI64MapEntryOrInsertResult
        (hashmap.string-i64-map-entry-or-insert u6 "alpha" 111)]
      [u7 : hashmap.StringI64Map (entry-or-insert-result-map inserted)]
      [found : hashmap.StringI64MapEntryOrInsertResult
        (hashmap.string-i64-map-entry-or-insert u7 "alpha" 222)]
      [u8 : hashmap.StringI64Map (entry-or-insert-result-map found)]
      (begin
        (test.assert-i64-eq
          (hashmap.string-i64-map-deleted u6)
          1
          "entry test starts with one tombstone")
        (test.assert-true
          (entry-or-insert-inserted? inserted)
          "entry-or-insert inserts missing key")
        (test.assert-i64-eq
          (entry-or-insert-value-or inserted -1)
          111
          "entry-or-insert returns inserted default")
        (test.assert-i64-eq
          (hashmap.string-i64-map-deleted u7)
          0
          "entry-or-insert reuses tombstone")
        (test.assert-false
          (entry-or-insert-inserted? found)
          "entry-or-insert finds existing key")
        (test.assert-i64-eq
          (entry-or-insert-value-or found -1)
          111
          "entry-or-insert returns existing value")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get u8 "alpha") -1)
          111
          "entry-or-insert found does not overwrite")))
    (let
      [u0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [u1 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u0 "alpha" 111)]
      [u9 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u1 "alpha" 333)]
      [grow0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 1)]
      [grow1 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update grow0 "a" 1)]
      [grow2 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update grow1 "b" 2)]
      [grow3 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update grow2 "c" 3)]
      (begin
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get u9 "alpha") -1)
          333
          "insert-or-update overwrites existing key")
        (test.assert-i64-eq
          (hashmap.string-i64-map-len grow3)
          3
          "insert-or-update inserts multiple keys")
        (test.assert-true
          (> (hashmap.string-i64-map-capacity grow3) 1)
          "insert-or-update grows tiny table")))
    (let
      [key : String "alpha"]
      [u0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [u1 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
      (begin
        (let
          [entry : (hashmap.StringI64MapMutEntry u1)
            (hashmap.string-i64-map-get-mut-entry-borrowed u1 (& key))]
          (begin
            (test.assert-true
              (hashmap.string-i64-map-mut-entry-present? entry)
              "mut entry finds existing key")
            (test.assert-i64-eq
              (hashmap.string-i64-map-mut-entry-value-or entry -1)
              10
              "mut entry reads existing value")
            (hashmap.string-i64-map-mut-entry-set! entry 77)))
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get u1 "alpha") -1)
          77
          "mut entry set updates map storage")))
    (let
      [key : String "missing"]
      [u0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [u1 : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
      (begin
        (let
          [entry : (hashmap.StringI64MapMutEntry u1)
            (hashmap.string-i64-map-get-mut-entry-borrowed u1 (& key))]
          (begin
            (test.assert-false
              (hashmap.string-i64-map-mut-entry-present? entry)
              "mut entry reports missing key")
            (test.assert-i64-eq
              (hashmap.string-i64-map-mut-entry-value-or entry -1)
              -1
              "missing mut entry returns fallback")
            (hashmap.string-i64-map-mut-entry-set! entry 99)))
        (test.assert-i64-eq (hashmap.string-i64-map-len u1) 1 "missing mut entry no-op")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get u1 "alpha") -1)
          10
          "missing mut entry leaves map unchanged")))
    ;; --- resize / rehash (#827) ---
    ;; needs-grow? threshold: a fresh capacity-4 table is below the 3/4 load.
    (test.assert-false
      (hashmap.string-i64-map-needs-grow? (hashmap.string-i64-map-with-capacity 4))
      "fresh cap-4 below load threshold")
    (test.assert-false
      (hashmap.string-i64-map-needs-grow? (hashmap.string-i64-map-with-capacity 0))
      "zero requested capacity rounds to a fresh cap-1 table")
    ;; string-i64-map-put auto-grows past the fixed capacity and preserves every
    ;; entry across the rehash (collision preservation + lookup after rehash).
    (let
      [g0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [g1 : hashmap.StringI64Map (hashmap.string-i64-map-put g0 "a" 1)]
      [g2 : hashmap.StringI64Map (hashmap.string-i64-map-put g1 "b" 2)]
      [g3 : hashmap.StringI64Map (hashmap.string-i64-map-put g2 "c" 3)]
      [g4 : hashmap.StringI64Map (hashmap.string-i64-map-put g3 "d" 4)]
      [g5 : hashmap.StringI64Map (hashmap.string-i64-map-put g4 "e" 5)]
      [g6 : hashmap.StringI64Map (hashmap.string-i64-map-put g5 "f" 6)]
      (begin
        (test.assert-i64-eq (hashmap.string-i64-map-len g6) 6 "put six -> len 6")
        (test.assert-true
          (> (hashmap.string-i64-map-capacity g6) 4)
          "table grew past the seed capacity")
        (test.assert-i64-eq
          (hashmap.string-i64-map-deleted g6)
          0
          "grown table has no tombstones")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get g6 "a") -1)
          1
          "get a after grow")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get g6 "c") -1)
          3
          "get c after grow")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get g6 "f") -1)
          6
          "get f after grow")
        (test.assert-i64-eq
          (lookup-value-or (hashmap.string-i64-map-get g6 "missing") -1)
          -1
          "absent key after grow")
        ;; overwrite across resize: updating an existing key keeps len.
        (let
          [g7 : hashmap.StringI64Map (hashmap.string-i64-map-put g6 "a" 99)]
          (begin
            (test.assert-i64-eq
              (hashmap.string-i64-map-len g7)
              6
              "update keeps len after grow")
            (test.assert-i64-eq
              (lookup-value-or (hashmap.string-i64-map-get g7 "a") -1)
              99
              "a updated to 99 after grow")))))
    ;; resized drops tombstones: insert 3, remove 1 (deleted=1), resize to 16.
    (let
      [t0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 8)]
      [t1 : hashmap.StringI64Map (insert-result-map (hashmap.string-i64-map-insert t0 "x" 10))]
      [t2 : hashmap.StringI64Map (insert-result-map (hashmap.string-i64-map-insert t1 "y" 20))]
      [t3 : hashmap.StringI64Map (insert-result-map (hashmap.string-i64-map-insert t2 "z" 30))]
      [t4 : hashmap.StringI64Map (remove-result-map (hashmap.string-i64-map-remove t3 "y"))]
      (begin
        (test.assert-i64-eq
          (hashmap.string-i64-map-deleted t4)
          1
          "one tombstone before resize")
        (let
          [t5 : hashmap.StringI64Map (hashmap.string-i64-map-resized t4 16)]
          [t6 : hashmap.StringI64Map (hashmap.string-i64-map-resized t4 10)]
          (begin
            (test.assert-i64-eq
              (hashmap.string-i64-map-capacity t5)
              16
              "resized capacity 16")
            (test.assert-i64-eq
              (hashmap.string-i64-map-capacity t6)
              16
              "resized capacity rounds to power of two")
            (test.assert-i64-eq (hashmap.string-i64-map-len t5) 2 "resized len 2")
            (test.assert-i64-eq
              (hashmap.string-i64-map-deleted t5)
              0
              "resize drops tombstones")
            (test.assert-i64-eq
              (lookup-value-or (hashmap.string-i64-map-get t5 "x") -1)
              10
              "x survives resize")
            (test.assert-i64-eq
              (lookup-value-or (hashmap.string-i64-map-get t5 "z") -1)
              30
              "z survives resize")
            (test.assert-i64-eq
              (lookup-value-or (hashmap.string-i64-map-get t5 "y") -1)
              -1
              "removed y absent after resize")))))
    ;; --- deterministic bucket-order iteration (#829) ---
    ;; empty map: the cursor starts at the capacity; count and sum are zero.
    (let
      [e0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 8)]
      (begin
        (test.assert-i64-eq
          (hashmap.string-i64-map-next-occupied e0 0)
          8
          "empty map cursor starts at capacity")
        (test.assert-i64-eq
          (iter-count e0 (hashmap.string-i64-map-next-occupied e0 0) 0)
          0
          "empty map iterates zero entries")
        (test.assert-i64-eq
          (iter-sum-values e0 (hashmap.string-i64-map-next-occupied e0 0) 0)
          0
          "empty map sum is zero")))
    ;; non-empty map: the cursor visits exactly `len` entries, sums every value
    ;; once, and walks strictly increasing (deterministic bucket) indices.
    (let
      [i0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 8)]
      [i1 : hashmap.StringI64Map (hashmap.string-i64-map-put i0 "a" 1)]
      [i2 : hashmap.StringI64Map (hashmap.string-i64-map-put i1 "b" 2)]
      [i3 : hashmap.StringI64Map (hashmap.string-i64-map-put i2 "c" 4)]
      [i4 : hashmap.StringI64Map (hashmap.string-i64-map-put i3 "d" 8)]
      (begin
        (test.assert-i64-eq
          (hashmap.string-i64-map-len i4)
          4
          "iteration map has four entries")
        (test.assert-i64-eq
          (iter-count i4 (hashmap.string-i64-map-next-occupied i4 0) 0)
          4
          "cursor visits exactly len entries")
        (test.assert-i64-eq
          (iter-sum-values i4 (hashmap.string-i64-map-next-occupied i4 0) 0)
          15
          "cursor sums every value once (1+2+4+8)")
        (test.assert-true
          (iter-monotonic? i4 (hashmap.string-i64-map-next-occupied i4 0))
          "cursor visits strictly increasing indices")
        ;; a removed key is skipped: its tombstone is not iterated.
        (let
          [i5 : hashmap.StringI64Map (remove-result-map (hashmap.string-i64-map-remove i4 "b"))]
          (begin
            (test.assert-i64-eq (hashmap.string-i64-map-len i5) 3 "len 3 after removing b")
            (test.assert-i64-eq
              (iter-count i5 (hashmap.string-i64-map-next-occupied i5 0) 0)
              3
              "cursor skips the tombstone (count 3)")
            (test.assert-i64-eq
              (iter-sum-values i5 (hashmap.string-i64-map-next-occupied i5 0) 0)
              13
              "cursor sum excludes the removed value (1+4+8)")))))
    ;; entry-at: out-of-range -> None, the only occupied slot -> Some value.
    (let
      [b0 : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
      [b1 : hashmap.StringI64Map (hashmap.string-i64-map-put b0 "only" 7)]
      (begin
        (test.assert-true
          (entry-none? (hashmap.string-i64-map-entry-at b1 -1))
          "entry-at negative index is None")
        (test.assert-true
          (entry-none? (hashmap.string-i64-map-entry-at b1 4))
          "entry-at out-of-range index is None")
        (test.assert-i64-eq
          (entry-value-or
            (hashmap.string-i64-map-entry-at b1 (hashmap.string-i64-map-next-occupied b1 0))
            -1)
          7
          "entry-at the only occupied slot is Some 7")))
    ;; --- generated String -> String map family (#817) ---
    (let
      [alpha : String "alpha"]
      [beta : String "beta"]
      [missing : String "missing"]
      [ss0 : hashmap.StringStringMap (hashmap.string-string-map-with-capacity 4)]
      [ss1 : hashmap.StringStringMap (hashmap.string-string-map-put ss0 "alpha" "red")]
      [ss2 : hashmap.StringStringMap (hashmap.string-string-map-put ss1 "beta" "amber")]
      [ss3 : hashmap.StringStringMap (hashmap.string-string-map-put ss2 "gamma" "blue")]
      [ss4 : hashmap.StringStringMap (hashmap.string-string-map-put ss3 "delta" "gold")]
      [ss5 : hashmap.StringStringMap (hashmap.string-string-map-put ss4 "alpha" "green")]
      (begin
        (test.assert-i64-eq (hashmap.string-string-map-len ss5) 4 "StringString len")
        (test.assert-true
          (> (hashmap.string-string-map-capacity ss5) 4)
          "StringString grew past seed capacity")
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (hashmap.string-string-map-get-borrowed ss5 (& alpha))
            "fallback")
          "green"
          "StringString borrowed get updated alpha")
        (test.assert-i64-eq
          (string-string-borrowed-value-length-or
            (hashmap.string-string-map-get-value-borrowed (& ss5) (& alpha))
            -1)
          5
          "StringString borrowed value get returns alpha by reference")
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (hashmap.string-string-map-get ss5 "gamma")
            "fallback")
          "blue"
          "StringString owned get gamma")
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (hashmap.string-string-map-get-borrowed ss5 (& missing))
            "fallback")
          "fallback"
          "StringString missing borrowed get")
        (test.assert-i64-eq
          (string-string-borrowed-value-length-or
            (hashmap.string-string-map-get-value-borrowed (& ss5) (& missing))
            -1)
          -1
          "StringString missing borrowed value get")
        (test.assert-true
          (hashmap.string-string-map-contains-borrowed? ss5 (& beta))
          "StringString borrowed contains beta")
        (let
          [removed : hashmap.StringStringMapRemoveResult
            (hashmap.string-string-map-remove-borrowed ss5 (& beta))]
          (begin
            (test.assert-true
              (string-string-remove-ok? removed)
              "StringString remove borrowed beta")
            (let
              [ss6 : hashmap.StringStringMap (string-string-remove-result-map removed)]
              (begin
                (test.assert-i64-eq
                  (hashmap.string-string-map-len ss6)
                  3
                  "StringString len after remove")
                (test.assert-i64-eq
                  (hashmap.string-string-map-deleted ss6)
                  1
                  "StringString tombstone after remove")
                (test.assert-false
                  (hashmap.string-string-map-contains-borrowed? ss6 (& beta))
                  "StringString beta absent after remove")
                (test.assert-i64-eq
                  (string-string-iter-count
                    ss6
                    (hashmap.string-string-map-next-occupied ss6 0)
                    0)
                  3
                  "StringString iteration count")
                (test.assert-i64-eq
                  (string-string-iter-value-length-sum
                    ss6
                    (hashmap.string-string-map-next-occupied ss6 0)
                    0)
                  13
                  "StringString iteration value length sum")))))))
    ;; --- generated String -> String update / entry-or-insert API (#888) ---
    (let
      [alpha-update : String "alpha"]
      [ssu0 : hashmap.StringStringMap (hashmap.string-string-map-with-capacity 4)]
      [ssu1 : hashmap.StringStringMap
        (hashmap.string-string-map-insert-or-update ssu0 "alpha" "red")]
      [ssu2 : hashmap.StringStringMap
        (hashmap.string-string-map-insert-or-update ssu1 "beta" "amber")]
      [ssu-hit : hashmap.StringStringMapUpdateResult
        (hashmap.string-string-map-update-borrowed-if-present
          ssu2
          (& alpha-update)
          "green")]
      [ssu3 : hashmap.StringStringMap (string-string-update-result-map ssu-hit)]
      (begin
        (test.assert-true
          (string-string-update-ok? ssu-hit)
          "StringString borrowed update hit")
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (hashmap.string-string-map-get ssu3 "alpha")
            "fallback")
          "green"
          "StringString update overwrites alpha")))
    (let
      [ssu0 : hashmap.StringStringMap (hashmap.string-string-map-with-capacity 4)]
      [ssu1 : hashmap.StringStringMap
        (hashmap.string-string-map-insert-or-update ssu0 "alpha" "red")]
      [ssu-miss : hashmap.StringStringMapUpdateResult
        (hashmap.string-string-map-update-if-present ssu1 "missing" "black")]
      [ssu2 : hashmap.StringStringMap (string-string-update-result-map ssu-miss)]
      (begin
        (test.assert-false
          (string-string-update-ok? ssu-miss)
          "StringString update miss")
        (test.assert-i64-eq
          (hashmap.string-string-map-len ssu2)
          1
          "StringString update miss keeps len")))
    (let
      [ssu0 : hashmap.StringStringMap (hashmap.string-string-map-with-capacity 4)]
      [ssu1 : hashmap.StringStringMap
        (hashmap.string-string-map-insert-or-update ssu0 "alpha" "green")]
      [ssu2 : hashmap.StringStringMap
        (hashmap.string-string-map-insert-or-update ssu1 "beta" "amber")]
      [ssu-removed : hashmap.StringStringMapRemoveResult
        (hashmap.string-string-map-remove ssu2 "beta")]
      [ssu3 : hashmap.StringStringMap (string-string-remove-result-map ssu-removed)]
      [ssu-inserted : hashmap.StringStringMapEntryOrInsertResult
        (hashmap.string-string-map-entry-or-insert ssu3 "beta" "gold")]
      [ssu4 : hashmap.StringStringMap
        (string-string-entry-or-insert-result-map ssu-inserted)]
      [ssu-found : hashmap.StringStringMapEntryOrInsertResult
        (hashmap.string-string-map-entry-or-insert ssu4 "alpha" "purple")]
      [ssu5 : hashmap.StringStringMap
        (string-string-entry-or-insert-result-map ssu-found)]
      (begin
        (test.assert-true
          (string-string-entry-or-insert-inserted? ssu-inserted)
          "StringString entry-or-insert inserted")
        (assert-owned-string-eq
          (string-string-entry-or-insert-value-or ssu-inserted "fallback")
          "gold"
          "StringString entry-or-insert returns default")
        (test.assert-i64-eq
          (hashmap.string-string-map-deleted ssu4)
          0
          "StringString entry-or-insert reuses tombstone")
        (test.assert-false
          (string-string-entry-or-insert-inserted? ssu-found)
          "StringString entry-or-insert found")
        (assert-owned-string-eq
          (string-string-entry-or-insert-value-or ssu-found "fallback")
          "green"
          "StringString entry-or-insert returns existing")
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (hashmap.string-string-map-get ssu5 "alpha")
            "fallback")
          "green"
          "StringString entry-or-insert found does not overwrite")))
    (let
      [ssu0 : hashmap.StringStringMap (hashmap.string-string-map-with-capacity 2)]
      [ssu1 : hashmap.StringStringMap
        (hashmap.string-string-map-insert-or-update ssu0 "alpha" "green")]
      [ssu2 : hashmap.StringStringMap
        (hashmap.string-string-map-insert-or-update ssu1 "beta" "gold")]
      [ssu3 : hashmap.StringStringMap
        (hashmap.string-string-map-insert-or-update ssu2 "gamma" "blue")]
      (begin
        (assert-owned-string-eq
          (string-string-lookup-value-or
            (hashmap.string-string-map-get ssu3 "gamma")
            "fallback")
          "blue"
          "StringString insert-or-update inserts new key")
        (test.assert-true
          (> (hashmap.string-string-map-capacity ssu3) 2)
          "StringString insert-or-update grows")))
    ;; --- generated i64 -> i64 map family (#817) ---
    (let
      [ii0 : hashmap.I64I64Map (hashmap.i64-i64-map-with-capacity 4)]
      [ii1 : hashmap.I64I64Map (hashmap.i64-i64-map-put ii0 1 10)]
      [ii2 : hashmap.I64I64Map (hashmap.i64-i64-map-put ii1 2 20)]
      [ii3 : hashmap.I64I64Map (hashmap.i64-i64-map-put ii2 3 30)]
      [ii4 : hashmap.I64I64Map (hashmap.i64-i64-map-put ii3 4 40)]
      [ii5 : hashmap.I64I64Map (hashmap.i64-i64-map-put ii4 1 99)]
      (begin
        (test.assert-i64-eq (hashmap.i64-i64-map-len ii5) 4 "I64I64 len")
        (test.assert-true
          (> (hashmap.i64-i64-map-capacity ii5) 4)
          "I64I64 grew past seed capacity")
        (test.assert-i64-eq
          (i64-i64-lookup-value-or (hashmap.i64-i64-map-get ii5 1) -1)
          99
          "I64I64 updated key 1")
        (test.assert-true
          (i64-i64-borrowed-value-found?
            (hashmap.i64-i64-map-get-value-borrowed (& ii5) 1))
          "I64I64 borrowed value get finds key 1")
        (test.assert-i64-eq
          (i64-i64-lookup-value-or (hashmap.i64-i64-map-get ii5 3) -1)
          30
          "I64I64 get key 3")
        (test.assert-i64-eq
          (i64-i64-lookup-value-or (hashmap.i64-i64-map-get ii5 99) -1)
          -1
          "I64I64 missing key")
        (test.assert-false
          (i64-i64-borrowed-value-found?
            (hashmap.i64-i64-map-get-value-borrowed (& ii5) 99))
          "I64I64 missing borrowed value get")
        (test.assert-true (hashmap.i64-i64-map-contains? ii5 2) "I64I64 contains key 2")
        (let
          [removed : hashmap.I64I64MapRemoveResult (hashmap.i64-i64-map-remove ii5 2)]
          (begin
            (test.assert-true (i64-i64-remove-ok? removed) "I64I64 remove key 2")
            (let
              [ii6 : hashmap.I64I64Map (i64-i64-remove-result-map removed)]
              (begin
                (test.assert-i64-eq
                  (hashmap.i64-i64-map-len ii6)
                  3
                  "I64I64 len after remove")
                (test.assert-i64-eq
                  (hashmap.i64-i64-map-deleted ii6)
                  1
                  "I64I64 tombstone after remove")
                (test.assert-false
                  (hashmap.i64-i64-map-contains? ii6 2)
                  "I64I64 removed key absent")
                (test.assert-i64-eq
                  (i64-i64-iter-count ii6 (hashmap.i64-i64-map-next-occupied ii6 0) 0)
                  3
                  "I64I64 iteration count")
                (test.assert-i64-eq
                  (i64-i64-iter-value-sum
                    ii6
                    (hashmap.i64-i64-map-next-occupied ii6 0)
                    0)
                  169
                  "I64I64 iteration value sum")))))))
    ;; --- generated i64 -> i64 update / entry-or-insert API (#888) ---
    (let
      [iiu0 : hashmap.I64I64Map (hashmap.i64-i64-map-with-capacity 4)]
      [iiu1 : hashmap.I64I64Map (hashmap.i64-i64-map-insert-or-update iiu0 1 10)]
      [iiu2 : hashmap.I64I64Map (hashmap.i64-i64-map-insert-or-update iiu1 2 20)]
      [iiu-hit : hashmap.I64I64MapUpdateResult
        (hashmap.i64-i64-map-update-if-present iiu2 1 70)]
      [iiu3 : hashmap.I64I64Map (i64-i64-update-result-map iiu-hit)]
      (begin
        (test.assert-true (i64-i64-update-ok? iiu-hit) "I64I64 update hit")
        (test.assert-i64-eq
          (i64-i64-lookup-value-or (hashmap.i64-i64-map-get iiu3 1) -1)
          70
          "I64I64 update overwrites key 1")))
    (let
      [iiu0 : hashmap.I64I64Map (hashmap.i64-i64-map-with-capacity 4)]
      [iiu1 : hashmap.I64I64Map (hashmap.i64-i64-map-insert-or-update iiu0 1 10)]
      [iiu-miss : hashmap.I64I64MapUpdateResult
        (hashmap.i64-i64-map-update-if-present iiu1 99 990)]
      [iiu2 : hashmap.I64I64Map (i64-i64-update-result-map iiu-miss)]
      (begin
        (test.assert-false (i64-i64-update-ok? iiu-miss) "I64I64 update miss")
        (test.assert-i64-eq (hashmap.i64-i64-map-len iiu2) 1 "I64I64 update miss keeps len")))
    (let
      [iiu0 : hashmap.I64I64Map (hashmap.i64-i64-map-with-capacity 4)]
      [iiu1 : hashmap.I64I64Map (hashmap.i64-i64-map-insert-or-update iiu0 1 70)]
      [iiu2 : hashmap.I64I64Map (hashmap.i64-i64-map-insert-or-update iiu1 2 20)]
      [iiu-removed : hashmap.I64I64MapRemoveResult (hashmap.i64-i64-map-remove iiu2 2)]
      [iiu5 : hashmap.I64I64Map (i64-i64-remove-result-map iiu-removed)]
      [iiu-inserted : hashmap.I64I64MapEntryOrInsertResult
        (hashmap.i64-i64-map-entry-or-insert iiu5 2 222)]
      [iiu6 : hashmap.I64I64Map (i64-i64-entry-or-insert-result-map iiu-inserted)]
      [iiu-found : hashmap.I64I64MapEntryOrInsertResult
        (hashmap.i64-i64-map-entry-or-insert iiu6 1 111)]
      [iiu7 : hashmap.I64I64Map (i64-i64-entry-or-insert-result-map iiu-found)]
      (begin
        (test.assert-true
          (i64-i64-entry-or-insert-inserted? iiu-inserted)
          "I64I64 entry-or-insert inserted")
        (test.assert-i64-eq
          (i64-i64-entry-or-insert-value-or iiu-inserted -1)
          222
          "I64I64 entry-or-insert returns default")
        (test.assert-i64-eq
          (hashmap.i64-i64-map-deleted iiu6)
          0
          "I64I64 entry-or-insert reuses tombstone")
        (test.assert-false
          (i64-i64-entry-or-insert-inserted? iiu-found)
          "I64I64 entry-or-insert found")
        (test.assert-i64-eq
          (i64-i64-entry-or-insert-value-or iiu-found -1)
          70
          "I64I64 entry-or-insert returns existing")
        (test.assert-i64-eq
          (i64-i64-lookup-value-or (hashmap.i64-i64-map-get iiu7 1) -1)
          70
          "I64I64 entry-or-insert found does not overwrite")))
    (let
      [iiu0 : hashmap.I64I64Map (hashmap.i64-i64-map-with-capacity 2)]
      [iiu1 : hashmap.I64I64Map (hashmap.i64-i64-map-insert-or-update iiu0 1 70)]
      [iiu2 : hashmap.I64I64Map (hashmap.i64-i64-map-insert-or-update iiu1 2 222)]
      [iiu8 : hashmap.I64I64Map (hashmap.i64-i64-map-insert-or-update iiu2 3 30)]
      (begin
        (test.assert-i64-eq
          (i64-i64-lookup-value-or (hashmap.i64-i64-map-get iiu8 3) -1)
          30
          "I64I64 insert-or-update inserts key 3")
        (test.assert-true
          (> (hashmap.i64-i64-map-capacity iiu8) 2)
          "I64I64 insert-or-update grows")))
    42))