(import "stdlib/test.tl")

(import "stdlib/string.tl")

(import "stdlib/set.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (string-set-entry-len-or [entry : StringSetEntry] [fallback : i64]) : i64
  (match entry
    [(StringSetEntrySome key) (string-length (& key))]
    [(StringSetEntryNone) fallback]))

(define (i64-set-entry-key-or [entry : I64SetEntry] [fallback : i64]) : i64
  (match entry
    [(I64SetEntrySome key) key]
    [(I64SetEntryNone) fallback]))

(define (string-set-iter-count [set : StringSet] [index : i64] [acc : i64]) : i64
  (if (>= index (string-set-capacity set))
    acc
    (string-set-iter-count
      set
      (string-set-next-occupied set (+ index 1))
      (+ acc 1))))

(define (string-set-iter-monotonic? [set : StringSet] [index : i64]) : bool
  (if (>= index (string-set-capacity set))
    true
    (let
      [next : i64 (string-set-next-occupied set (+ index 1))]
      (if (> next index)
        (string-set-iter-monotonic? set next)
        false))))

(define (i64-set-iter-count [set : I64Set] [index : i64] [acc : i64]) : i64
  (if (>= index (i64-set-capacity set))
    acc
    (i64-set-iter-count set (i64-set-next-occupied set (+ index 1)) (+ acc 1))))

(define (i64-set-iter-sum [set : I64Set] [index : i64] [acc : i64]) : i64
  (if (>= index (i64-set-capacity set))
    acc
    (i64-set-iter-sum
      set
      (i64-set-next-occupied set (+ index 1))
      (+ acc (i64-set-entry-key-or (i64-set-entry-at set index) 0)))))

(define (main) : i64
  (begin
    (assert-owned-string-eq
      (set-string-key-descriptor-key)
      "stdlib/hashmap/string-key-v1"
      "String set descriptor identity")
    (assert-owned-string-eq
      (set-i64-key-descriptor-key)
      "stdlib/hashmap/i64-key-v1"
      "i64 set descriptor identity")
    ;; String key family: duplicate insert, borrowed contains/remove, forced
    ;; bucket collision at capacity 4, tombstone reuse, and resize.
    (let
      [borrowed-key : String "alpha"]
      [s0 : StringSet (string-set-with-capacity 4)]
      [s1 : StringSet (string-set-insert s0 "alpha")]
      [s2 : StringSet (string-set-insert s1 "alpha")]
      (begin
        (assert-i64-eq
          (string-set-len s2)
          1
          "duplicate String insert is idempotent")
        (assert-true
          (string-set-contains-borrowed? s2 (& borrowed-key))
          "borrowed String contains finds owned key")
        (let
          [s3 : StringSet (string-set-insert s2 "a")]
          [s4 : StringSet (string-set-insert s3 "e")]
          (begin
            (assert-true
              (string-set-contains? s4 "e")
              "String collision chain lookup")
            (let
              [s5 : StringSet (string-set-remove s4 "a")]
              (begin
                (assert-false
                  (string-set-contains? s5 "a")
                  "String remove tombstones key")
                (assert-true
                  (string-set-contains? s5 "e")
                  "String tombstone preserves later collision")
                (let
                  [s6 : StringSet (string-set-insert s5 "i")]
                  (begin
                    (assert-true
                      (string-set-contains? s6 "i")
                      "String insert reuses tombstone slot")
                    (let
                      [s7 : StringSet
                        (string-set-remove-borrowed s6 (& borrowed-key))]
                      (begin
                        (assert-false
                          (string-set-contains-borrowed? s7 (& borrowed-key))
                          "borrowed String remove removes key")
                        (let
                          [s8 : StringSet (string-set-remove s7 "missing")]
                          (begin
                            (assert-i64-eq
                              (string-set-len s8)
                              (string-set-len s7)
                              "missing String remove is no-op")
                            (let
                              [s9 : StringSet
                                (string-set-insert
                                  (string-set-insert
                                    (string-set-insert s8 "one")
                                    "two")
                                  "three")]
                              (begin
                                (assert-true
                                  (> (string-set-capacity s9) 4)
                                  "String set grows and rehashes")
                                (assert-true
                                  (string-set-contains? s9 "e")
                                  "String set keeps old key after resize")
                                (assert-i64-eq
                                  (string-set-iter-count
                                    s9
                                    (string-set-next-occupied s9 0)
                                    0)
                                  (string-set-len s9)
                                  "String set iteration visits every key")
                                (assert-true
                                  (string-set-iter-monotonic?
                                    s9
                                    (string-set-next-occupied s9 0))
                                  "String set iteration is ascending bucket order")
                                (assert-true
                                  (>
                                    (string-set-entry-len-or
                                      (string-set-entry-at
                                        s9
                                        (string-set-next-occupied s9 0))
                                      -1)
                                    0)
                                  "String set entry-at returns a live key")))))))))))))))
    ;; i64 key family: same-bucket collisions, tombstone correctness, duplicate
    ;; insert, missing remove, resize, and bucket-order iteration.
    (let
      [i0 : I64Set (i64-set-with-capacity 4)]
      [i1 : I64Set (i64-set-insert i0 1)]
      [i2 : I64Set (i64-set-insert i1 5)]
      [i3 : I64Set (i64-set-insert i2 1)]
      (begin
        (assert-i64-eq (i64-set-len i3) 2 "duplicate i64 insert is idempotent")
        (assert-true (i64-set-contains? i3 5) "i64 collision lookup")
        (let
          [i4 : I64Set (i64-set-remove i3 1)]
          (begin
            (assert-false (i64-set-contains? i4 1) "i64 remove tombstones key")
            (assert-true
              (i64-set-contains? i4 5)
              "i64 tombstone preserves later collision")
            (let
              [i5 : I64Set (i64-set-insert i4 9)]
              (begin
                (assert-true
                  (i64-set-contains? i5 9)
                  "i64 tombstone slot reused")
                (let
                  [i6 : I64Set (i64-set-remove i5 999)]
                  [i6-sum : i64
                    (i64-set-iter-sum i6 (i64-set-next-occupied i6 0) 0)]
                  (begin
                    (assert-i64-eq
                      (i64-set-len i6)
                      (i64-set-len i5)
                      "missing i64 remove is no-op")
                    (let
                      [i7 : I64Set
                        (i64-set-insert
                          (i64-set-insert (i64-set-insert i6 10) 11)
                          12)]
                      (begin
                        (assert-true
                          (> (i64-set-capacity i7) 4)
                          "i64 set grows and rehashes")
                        (assert-i64-eq
                          (i64-set-iter-count i7 (i64-set-next-occupied i7 0) 0)
                          (i64-set-len i7)
                          "i64 set iteration visits every key")
                        (assert-i64-eq
                          i6-sum
                          14
                          "i64 set iteration exposes live keys")))))))))))
    42))