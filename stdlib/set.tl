;# Generated concrete hash set family (collections v1, #2730).
;#
;# `StringSet` and `I64Set` are generated from explicit key descriptor requests.
;# They expose set-specific APIs over the same deterministic open-addressed
;# storage policy as `stdlib/hashmap.tl`: linear probing, tombstones for remove,
;# power-of-two capacities, resize/rehash on growth, and bucket-order iteration.
;#
;# Use a set when only key membership matters. Use a map when each key carries a
;# meaningful value; callers should not model sets as maps with dummy values.
;#
;# Iteration is deterministic bucket order for a fixed table state. It is not
;# insertion order, and it can change after resize/rehash. Walk by starting at
;# `*-set-next-occupied set 0`, advancing with `(+ index 1)`, and reading each
;# key with `*-set-entry-at`.
;#
;# Usage: `(import stdlib.set)`
(module stdlib.set)

(import stdlib.hashmap)

;: Local hashmap families used by the current checked-in set-family generator.
;: The generator still emits unqualified hashmap family references; keeping these
;: local preserves dotted imports without depending on legacy namespace merging.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMap (type-key (type String)) (type-key
    (type String)) "stdlib/hashmap/string-key-v1")
  (defstruct StringStringMap
    (__hashmap_family_request i64)))

(comptime-decl
  (:generated stdlib/hashmap-family I64I64Map (type-key (type i64)) (type-key
    (type i64)) "stdlib/hashmap/i64-key-v1")
  (defstruct I64I64Map
    (__hashmap_family_request i64)))

;: Stable descriptor identity for generated `String`-key set families.
(define (set-string-key-descriptor-key) : String
  (hashmap.hashmap-string-key-descriptor-key))

;: Stable descriptor identity for generated `i64`-key set families.
(define (set-i64-key-descriptor-key) : String
  (hashmap.hashmap-i64-key-descriptor-key))

;: Generated `HashSet<String>` family request. The public API is produced by
;: the `stdlib/set-family` declaration generator.
(comptime-decl
  (:generated stdlib/set-family StringSet (type-key (type String)) "stdlib/hashmap/string-key-v1")
  (defstruct StringSet
    (__set_family_request i64)))

;: Generated `HashSet<i64>` family request. The public API is produced by the
;: `stdlib/set-family` declaration generator.
(comptime-decl
  (:generated stdlib/set-family I64Set (type-key (type i64)) "stdlib/hashmap/i64-key-v1")
  (defstruct I64Set
    (__set_family_request i64)))

;; Inline coverage migrated from stdlib/tests/set_api.tl (#3083).
(cfg test (import stdlib.test))

(cfg
  test
  (define (set-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (test.assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (string-set-entry-len-or [entry : StringSetEntry] [fallback : i64]) : i64
    (match entry
      [(StringSetEntrySome key) (string-length (& key))]
      [(StringSetEntryNone) fallback])))

(cfg
  test
  (define (i64-set-entry-key-or [entry : I64SetEntry] [fallback : i64]) : i64
    (match entry
      [(I64SetEntrySome key) key]
      [(I64SetEntryNone) fallback])))

(cfg
  test
  (define (string-set-iter-count [set : StringSet] [index : i64] [acc : i64]) : i64
    (if (>= index (string-set-capacity set))
      acc
      (string-set-iter-count
        set
        (string-set-next-occupied set (+ index 1))
        (+ acc 1)))))

(cfg
  test
  (define (string-set-iter-monotonic? [set : StringSet] [index : i64]) : bool
    (if (>= index (string-set-capacity set))
      true
      (let
        [next : i64 (string-set-next-occupied set (+ index 1))]
        (if (> next index)
          (string-set-iter-monotonic? set next)
          false)))))

(cfg
  test
  (define (i64-set-iter-count [set : I64Set] [index : i64] [acc : i64]) : i64
    (if (>= index (i64-set-capacity set))
      acc
      (i64-set-iter-count set (i64-set-next-occupied set (+ index 1)) (+ acc 1)))))

(cfg
  test
  (define (i64-set-iter-sum [set : I64Set] [index : i64] [acc : i64]) : i64
    (if (>= index (i64-set-capacity set))
      acc
      (i64-set-iter-sum
        set
        (i64-set-next-occupied set (+ index 1))
        (+ acc (i64-set-entry-key-or (i64-set-entry-at set index) 0))))))

(cfg
  test
  (test
    set-descriptor-contract
    (begin
      (set-test-assert-owned-string-eq
        (set-string-key-descriptor-key)
        "stdlib/hashmap/string-key-v1"
        "String set descriptor identity")
      (set-test-assert-owned-string-eq
        (set-i64-key-descriptor-key)
        "stdlib/hashmap/i64-key-v1"
        "i64 set descriptor identity")
      unit)))

(cfg
  test
  (test
    set-string-family
    (begin
      ;; String key family: duplicate insert, borrowed contains/remove, forced
      ;; bucket collision at capacity 4, tombstone reuse, and resize.
      (let
        [borrowed-key : String "alpha"]
        [s0 : StringSet (string-set-with-capacity 4)]
        [s1 : StringSet (string-set-insert s0 "alpha")]
        [s2 : StringSet (string-set-insert s1 "alpha")]
        (begin
          (test.assert-i64-eq
            (string-set-len s2)
            1
            "duplicate String insert is idempotent")
          (test.assert-true
            (string-set-contains-borrowed? s2 (& borrowed-key))
            "borrowed String contains finds owned key")
          (let
            [s3 : StringSet (string-set-insert s2 "a")]
            [s4 : StringSet (string-set-insert s3 "e")]
            (begin
              (test.assert-true
                (string-set-contains? s4 "e")
                "String collision chain lookup")
              (let
                [s5 : StringSet (string-set-remove s4 "a")]
                (begin
                  (test.assert-false
                    (string-set-contains? s5 "a")
                    "String remove tombstones key")
                  (test.assert-true
                    (string-set-contains? s5 "e")
                    "String tombstone preserves later collision")
                  (let
                    [s6 : StringSet (string-set-insert s5 "i")]
                    (begin
                      (test.assert-true
                        (string-set-contains? s6 "i")
                        "String insert reuses tombstone slot")
                      (let
                        [s7 : StringSet
                          (string-set-remove-borrowed s6 (& borrowed-key))]
                        (begin
                          (test.assert-false
                            (string-set-contains-borrowed? s7 (& borrowed-key))
                            "borrowed String remove removes key")
                          (let
                            [s8 : StringSet (string-set-remove s7 "missing")]
                            (begin
                              (test.assert-i64-eq
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
                                  (test.assert-true
                                    (> (string-set-capacity s9) 4)
                                    "String set grows and rehashes")
                                  (test.assert-true
                                    (string-set-contains? s9 "e")
                                    "String set keeps old key after resize")
                                  (test.assert-i64-eq
                                    (string-set-iter-count
                                      s9
                                      (string-set-next-occupied s9 0)
                                      0)
                                    (string-set-len s9)
                                    "String set iteration visits every key")
                                  (test.assert-true
                                    (string-set-iter-monotonic?
                                      s9
                                      (string-set-next-occupied s9 0))
                                    "String set iteration is ascending bucket order")
                                  (test.assert-true
                                    (>
                                      (string-set-entry-len-or
                                        (string-set-entry-at
                                          s9
                                          (string-set-next-occupied s9 0))
                                        -1)
                                      0)
                                    "String set entry-at returns a live key")))))))))))))))
      unit)))

(cfg
  test
  (test
    set-i64-family
    (begin
      ;; i64 key family: same-bucket collisions, tombstone correctness, duplicate
      ;; insert, missing remove, resize, and bucket-order iteration.
      (let
        [i0 : I64Set (i64-set-with-capacity 4)]
        [i1 : I64Set (i64-set-insert i0 1)]
        [i2 : I64Set (i64-set-insert i1 5)]
        [i3 : I64Set (i64-set-insert i2 1)]
        (begin
          (test.assert-i64-eq
            (i64-set-len i3)
            2
            "duplicate i64 insert is idempotent")
          (test.assert-true (i64-set-contains? i3 5) "i64 collision lookup")
          (let
            [i4 : I64Set (i64-set-remove i3 1)]
            (begin
              (test.assert-false
                (i64-set-contains? i4 1)
                "i64 remove tombstones key")
              (test.assert-true
                (i64-set-contains? i4 5)
                "i64 tombstone preserves later collision")
              (let
                [i5 : I64Set (i64-set-insert i4 9)]
                (begin
                  (test.assert-true
                    (i64-set-contains? i5 9)
                    "i64 tombstone slot reused")
                  (let
                    [i6 : I64Set (i64-set-remove i5 999)]
                    [i6-sum : i64
                      (i64-set-iter-sum i6 (i64-set-next-occupied i6 0) 0)]
                    (begin
                      (test.assert-i64-eq
                        (i64-set-len i6)
                        (i64-set-len i5)
                        "missing i64 remove is no-op")
                      (let
                        [i7 : I64Set
                          (i64-set-insert
                            (i64-set-insert (i64-set-insert i6 10) 11)
                            12)]
                        (begin
                          (test.assert-true
                            (> (i64-set-capacity i7) 4)
                            "i64 set grows and rehashes")
                          (test.assert-i64-eq
                            (i64-set-iter-count
                              i7
                              (i64-set-next-occupied i7 0)
                              0)
                            (i64-set-len i7)
                            "i64 set iteration visits every key")
                          (test.assert-i64-eq
                            i6-sum
                            14
                            "i64 set iteration exposes live keys")))))))))))
      unit)))

(export
  (value set-string-key-descriptor-key)
  (value set-i64-key-descriptor-key)
  (type StringSet)
  (type I64Set)
  (constructor StringSet)
  (constructor I64Set))