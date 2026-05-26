(import "stdlib/test.tl")

(import "stdlib/hashmap.tl")

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

(define (main) : i64
  (begin
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
    42))