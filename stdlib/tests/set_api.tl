(import stdlib.test)

(import stdlib.string)

(import stdlib.set)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (string-set-entry-len-or [entry : set.StringSetEntry] [fallback : i64]) : i64
  (match entry
    [(set.StringSetEntrySome key) (string-length (& key))]
    [(set.StringSetEntryNone) fallback]))

(define (i64-set-entry-key-or [entry : set.I64SetEntry] [fallback : i64]) : i64
  (match entry
    [(set.I64SetEntrySome key) key]
    [(set.I64SetEntryNone) fallback]))

(define (string-set-iter-count [set : set.StringSet] [index : i64] [acc : i64]) : i64
  (if (>= index (set.string-set-capacity set))
    acc
    (string-set-iter-count
      set
      (set.string-set-next-occupied set (+ index 1))
      (+ acc 1))))

(define (string-set-iter-monotonic? [set : set.StringSet] [index : i64]) : bool
  (if (>= index (set.string-set-capacity set))
    true
    (let
      [next : i64 (set.string-set-next-occupied set (+ index 1))]
      (if (> next index)
        (string-set-iter-monotonic? set next)
        false))))

(define (i64-set-iter-count [set : set.I64Set] [index : i64] [acc : i64]) : i64
  (if (>= index (set.i64-set-capacity set))
    acc
    (i64-set-iter-count set (set.i64-set-next-occupied set (+ index 1)) (+ acc 1))))

(define (i64-set-iter-sum [set : set.I64Set] [index : i64] [acc : i64]) : i64
  (if (>= index (set.i64-set-capacity set))
    acc
    (i64-set-iter-sum
      set
      (set.i64-set-next-occupied set (+ index 1))
      (+ acc (i64-set-entry-key-or (set.i64-set-entry-at set index) 0)))))

(define (main) : i64
  (begin
    (assert-owned-string-eq
      (set.set-string-key-descriptor-key)
      "stdlib/hashmap/string-key-v1"
      "String set descriptor identity")
    (assert-owned-string-eq
      (set.set-i64-key-descriptor-key)
      "stdlib/hashmap/i64-key-v1"
      "i64 set descriptor identity")
    ;; String key family: duplicate insert, borrowed contains/remove, forced
    ;; bucket collision at capacity 4, tombstone reuse, and resize.
    (let
      [borrowed-key : String "alpha"]
      [s0 : set.StringSet (set.string-set-with-capacity 4)]
      [s1 : set.StringSet (set.string-set-insert s0 "alpha")]
      [s2 : set.StringSet (set.string-set-insert s1 "alpha")]
      [s3 : set.StringSet (set.string-set-insert s2 "a")]
      [s4 : set.StringSet (set.string-set-insert s3 "e")]
      [s5 : set.StringSet (set.string-set-remove s4 "a")]
      [s6 : set.StringSet (set.string-set-insert s5 "i")]
      [s7 : set.StringSet (set.string-set-remove-borrowed s6 (& borrowed-key))]
      [s8 : set.StringSet (set.string-set-remove s7 "missing")]
      [s9 : set.StringSet
        (set.string-set-insert
          (set.string-set-insert (set.string-set-insert s8 "one") "two")
          "three")]
      (begin
        (test.assert-i64-eq
          (set.string-set-len s2)
          1
          "duplicate String insert is idempotent")
        (test.assert-true
          (set.string-set-contains-borrowed? s2 (& borrowed-key))
          "borrowed String contains finds owned key")
        (test.assert-true
          (set.string-set-contains? s4 "e")
          "String collision chain lookup")
        (test.assert-false
          (set.string-set-contains? s5 "a")
          "String remove tombstones key")
        (test.assert-true
          (set.string-set-contains? s5 "e")
          "String tombstone preserves later collision")
        (test.assert-true
          (set.string-set-contains? s6 "i")
          "String insert reuses tombstone slot")
        (test.assert-false
          (set.string-set-contains-borrowed? s7 (& borrowed-key))
          "borrowed String remove removes key")
        (test.assert-i64-eq
          (set.string-set-len s8)
          (set.string-set-len s7)
          "missing String remove is no-op")
        (test.assert-true
          (> (set.string-set-capacity s9) 4)
          "String set grows and rehashes")
        (test.assert-true
          (set.string-set-contains? s9 "e")
          "String set keeps old key after resize")
        (test.assert-i64-eq
          (string-set-iter-count s9 (set.string-set-next-occupied s9 0) 0)
          (set.string-set-len s9)
          "String set iteration visits every key")
        (test.assert-true
          (string-set-iter-monotonic? s9 (set.string-set-next-occupied s9 0))
          "String set iteration is ascending bucket order")
        (test.assert-true
          (>
            (string-set-entry-len-or
              (set.string-set-entry-at s9 (set.string-set-next-occupied s9 0))
              -1)
            0)
          "String set entry-at returns a live key")))
    ;; i64 key family: same-bucket collisions, tombstone correctness, duplicate
    ;; insert, missing remove, resize, and bucket-order iteration.
    (let
      [i0 : set.I64Set (set.i64-set-with-capacity 4)]
      [i1 : set.I64Set (set.i64-set-insert i0 1)]
      [i2 : set.I64Set (set.i64-set-insert i1 5)]
      [i3 : set.I64Set (set.i64-set-insert i2 1)]
      [i4 : set.I64Set (set.i64-set-remove i3 1)]
      [i5 : set.I64Set (set.i64-set-insert i4 9)]
      [i6 : set.I64Set (set.i64-set-remove i5 999)]
      [i6-sum : i64 (i64-set-iter-sum i6 (set.i64-set-next-occupied i6 0) 0)]
      [i7 : set.I64Set
        (set.i64-set-insert (set.i64-set-insert (set.i64-set-insert i6 10) 11) 12)]
      (begin
        (test.assert-i64-eq (set.i64-set-len i3) 2 "duplicate i64 insert is idempotent")
        (test.assert-true (set.i64-set-contains? i3 5) "i64 collision lookup")
        (test.assert-false (set.i64-set-contains? i4 1) "i64 remove tombstones key")
        (test.assert-true
          (set.i64-set-contains? i4 5)
          "i64 tombstone preserves later collision")
        (test.assert-true (set.i64-set-contains? i5 9) "i64 tombstone slot reused")
        (test.assert-i64-eq
          (set.i64-set-len i6)
          (set.i64-set-len i5)
          "missing i64 remove is no-op")
        (test.assert-true (> (set.i64-set-capacity i7) 4) "i64 set grows and rehashes")
        (test.assert-i64-eq
          (i64-set-iter-count i7 (set.i64-set-next-occupied i7 0) 0)
          (set.i64-set-len i7)
          "i64 set iteration visits every key")
        (test.assert-i64-eq i6-sum 14 "i64 set iteration exposes live keys")))
    42))