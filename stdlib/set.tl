;# Generated hash set modules (collections v1, #2730/#3199).
;#
;# `(set T)` emits a module-scoped hash set. Import each instantiation with an
;# alias when more than one set type is used:
;#
;# ```typelisp
;# (import "stdlib/set.tl")
;# (import (set i64) as iset)
;#
;# (define (main) : i64
;#   (let
;#     [s : iset.Set (iset.new)]
;#     (begin
;#       (iset.insert (&mut s) 10)
;#       (if (iset.contains? (& s) 10)
;#         (iset.len (& s))
;#         0))))
;# ```
;#
;# Mutators take `&mut` and update the set in place. Readers take `&`.
;# Iteration is deterministic bucket order for a fixed table state. It is not
;# insertion order, and it can change after resize/rehash. Walk by starting at
;# `(next-occupied (& set) 0)`, advancing with `(+ index 1)`, and reading each
;# key with `entry-at`.
;: Emit a generated hash set module for key type `T`.
(defmacro (set [T : type]) : Module
  (let
    [type-key-name : String (type-key T)]
    [module-name : Expr
      (expr-var (string-append "stdlib.set.generated." type-key-name))]
    (match type-key-name
      ["String"
        `(begin
          (module ,module-name)
          (defenum Slot
            (Empty)
            (Tombstone)
            (Occupied String i64))
          (defenum Probe
            (Found i64)
            (Absent i64)
            (Full))
          (defstruct Set
            (slots (Array Slot))
            (len i64)
            (deleted i64))
          (defenum Entry
            (None)
            (Some String))
          (define (hash-normalize [value : i64]) : i64
            (let
              [m : i64 2147483647]
              [raw : i64 (% value m)]
              (if (< raw 0)
                (+ raw m)
                raw)))
          (define (hash-key [key : (& key str)]) : i64
            (let
              [n : i64 (string-length key)]
              [i : i64 0]
              [hash : i64 0]
              (begin
                (while (< i n)
                  (begin
                    (set!
                      hash
                      (%
                        (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)
                        2147483647))
                    (set! i (+ i 1))))
                hash)))
          (define (key-eq-borrowed? [left : String] [right : (& right str)]) : bool
            (let
              [left-len : i64 (string-length (& left))]
              [right-len : i64 (string-length right)]
              (if (not (= left-len right-len))
                false
                (let
                  [i : i64 0]
                  [same : bool true]
                  (begin
                    (while (if same
                      (< i left-len)
                      false)
                      (if (= (string-ref (& left) i) (string-ref right i))
                        (set! i (+ i 1))
                        (set! same false)))
                    same)))))
          (define (round-capacity [capacity : i64]) : i64
            (let
              [rounded : i64 1]
              (begin
                (while (< rounded capacity)
                  (set! rounded (* rounded 2)))
                rounded)))
          (define (bucket-index [hash : i64] [capacity : i64]) : i64
            (bit-and (hash-normalize hash) (- capacity 1)))
          (define (next-index [index : i64] [capacity : i64]) : i64
            (let
              [next : i64 (+ index 1)]
              (if (>= next capacity)
                0
                next)))
          (define (insert-slot [first-tombstone : i64] [empty-index : i64]) : i64
            (if (>= first-tombstone 0)
              first-tombstone
              empty-index))
          (define (probe-borrowed-from
            [slots : (& slots (Array Slot))]
            [capacity : i64]
            [key : (& key str)]
            [hash : i64]
            [index : i64]
            [seen : i64]
            [first-tombstone : i64]) : Probe
            (if (>= seen capacity)
              (Probe.Full)
              (match (array-ref slots index)
                [Slot.Empty (Probe.Absent (insert-slot first-tombstone index))]
                [Slot.Tombstone
                  (probe-borrowed-from
                    slots
                    capacity
                    key
                    hash
                    (next-index index capacity)
                    (+ seen 1)
                    (if (>= first-tombstone 0)
                      first-tombstone
                      index))]
                [(Slot.Occupied existing existing-hash)
                  (if (if (= existing-hash hash)
                    (key-eq-borrowed? existing key)
                    false)
                    (Probe.Found index)
                    (probe-borrowed-from
                      slots
                      capacity
                      key
                      hash
                      (next-index index capacity)
                      (+ seen 1)
                      first-tombstone))])))
          (define (probe-borrowed
            [slots : (& slots (Array Slot))]
            [capacity : i64]
            [key : (& key str)]
            [hash : i64]) : Probe
            (probe-borrowed-from
              slots
              capacity
              key
              hash
              (bucket-index hash capacity)
              0
              -1))
          (define (with-capacity [capacity : i64]) : Set
            (let
              [cap : i64
                (round-capacity
                  (if (< capacity 1)
                    1
                    capacity))]
              (Set (make-array Slot cap) 0 0)))
          (define (new) : Set
            (with-capacity 8))
          (define (len [set : (& set Set)]) : i64
            (struct-get set len))
          (define (capacity [set : (& set Set)]) : i64
            (array-length (struct-get set slots)))
          (define (capacity-mut [set : (&mut set Set)]) : i64
            (array-length (struct-get set slots)))
          (define (needs-grow? [set : (&mut set Set)]) : bool
            (> (* (+ (struct-get set len) 1) 4) (* (capacity-mut set) 3)))
          (define (grow [set : (&mut set Set)]) : unit
            (let
              [old-capacity : i64 (array-length (struct-get set slots))]
              [new-capacity : i64
                (if (< old-capacity 1)
                  1
                  (* old-capacity 2))]
              [fresh : (Array Slot) (make-array Slot new-capacity)]
              [scan : i64 0]
              (begin
                (while (< scan old-capacity)
                  (begin
                    (match (array-ref (struct-get set slots) scan)
                      [(Slot.Occupied key hash)
                        (let
                          [index : i64 (bucket-index hash new-capacity)]
                          [seen : i64 0]
                          [placed : bool false]
                          (while (if placed
                            false
                            (< seen new-capacity))
                            (match (array-ref fresh index)
                              [Slot.Empty
                                (begin
                                  (array-set!
                                    fresh
                                    index
                                    (Slot.Occupied (clone key) hash))
                                  (set! placed true))]
                              [_
                                (begin
                                  (set! index (next-index index new-capacity))
                                  (set! seen (+ seen 1)))])))]
                      [_ unit])
                    (set! scan (+ scan 1))))
                (set! (struct-get set slots) fresh)
                (set! (struct-get set deleted) 0))))
          (define (contains-borrowed? [set : (& set Set)] [key : (& key str)]) : bool
            (match (probe-borrowed
              (& (struct-get set slots))
              (capacity set)
              key
              (hash-key key))
              [(Probe.Found _) true]
              [_ false]))
          (define (contains? [set : (& set Set)] [key : String]) : bool
            (contains-borrowed? set (& key)))
          (define (insert [set : (&mut set Set)] [key : String]) : unit
            (begin
              (if (needs-grow? set)
                (grow set)
                unit)
              (let
                [hash : i64 (hash-key (& key))]
                (match (probe-borrowed
                  (& (struct-get set slots))
                  (capacity-mut set)
                  (& key)
                  hash)
                  [(Probe.Found _) unit]
                  [(Probe.Absent index)
                    (let
                      [was-tombstone : bool
                        (match (array-ref (struct-get set slots) index)
                          [Slot.Tombstone true]
                          [_ false])]
                      (begin
                        (array-set!
                          (struct-get set slots)
                          index
                          (Slot.Occupied key hash))
                        (set! (struct-get set len) (+ (struct-get set len) 1))
                        (if was-tombstone
                          (set!
                            (struct-get set deleted)
                            (- (struct-get set deleted) 1))
                          unit)))]
                  [Probe.Full
                    (begin
                      (grow set)
                      (insert set key))]))))
          (define (remove-borrowed [set : (&mut set Set)] [key : (& key str)]) : unit
            (match (probe-borrowed
              (& (struct-get set slots))
              (capacity-mut set)
              key
              (hash-key key))
              [(Probe.Found index)
                (begin
                  (array-set! (struct-get set slots) index (Slot.Tombstone))
                  (set! (struct-get set len) (- (struct-get set len) 1))
                  (set! (struct-get set deleted) (+ (struct-get set deleted) 1)))]
              [_ unit]))
          (define (remove [set : (&mut set Set)] [key : String]) : unit
            (remove-borrowed set (& key)))
          (define (next-occupied [set : (& set Set)] [from : i64]) : i64
            (let
              [index : i64
                (if (< from 0)
                  0
                  from)]
              [cap : i64 (capacity set)]
              [found : bool false]
              (begin
                (while (if found
                  false
                  (< index cap))
                  (match (array-ref (struct-get set slots) index)
                    [(Slot.Occupied _ _) (set! found true)]
                    [_ (set! index (+ index 1))]))
                index)))
          (define (entry-at [set : (& set Set)] [index : i64]) : Entry
            (if (if (>= index 0)
              (< index (capacity set))
              false)
              (match (array-ref (struct-get set slots) index)
                [(Slot.Occupied key _) (Entry.Some (clone key))]
                [_ (Entry.None)])
              (Entry.None)))
          (define (entry-key-or [entry : Entry] [fallback : String]) : String
            (match entry
              [(Entry.Some key) key]
              [Entry.None fallback]))
          (export
            (type Set)
            (constructor Set)
            (type Entry)
            (variant None)
            (variant Some)
            (value with-capacity)
            (value new)
            (value len)
            (value capacity)
            (value contains-borrowed?)
            (value contains?)
            (value insert)
            (value remove-borrowed)
            (value remove)
            (value next-occupied)
            (value entry-at)
            (value entry-key-or)))]
      ["i64"
        `(begin
          (module ,module-name)
          (defenum Slot
            (Empty)
            (Tombstone)
            (Occupied i64 i64))
          (defenum Probe
            (Found i64)
            (Absent i64)
            (Full))
          (defstruct Set
            (slots (Array Slot))
            (len i64)
            (deleted i64))
          (defenum Entry
            (None)
            (Some i64))
          (define (hash-normalize [value : i64]) : i64
            (let
              [m : i64 2147483647]
              [raw : i64 (% value m)]
              (if (< raw 0)
                (+ raw m)
                raw)))
          (define (hash-key [key : i64]) : i64
            (hash-normalize key))
          (define (round-capacity [capacity : i64]) : i64
            (let
              [rounded : i64 1]
              (begin
                (while (< rounded capacity)
                  (set! rounded (* rounded 2)))
                rounded)))
          (define (bucket-index [hash : i64] [capacity : i64]) : i64
            (bit-and (hash-normalize hash) (- capacity 1)))
          (define (next-index [index : i64] [capacity : i64]) : i64
            (let
              [next : i64 (+ index 1)]
              (if (>= next capacity)
                0
                next)))
          (define (insert-slot [first-tombstone : i64] [empty-index : i64]) : i64
            (if (>= first-tombstone 0)
              first-tombstone
              empty-index))
          (define (probe-from
            [slots : (& slots (Array Slot))]
            [capacity : i64]
            [key : i64]
            [hash : i64]
            [index : i64]
            [seen : i64]
            [first-tombstone : i64]) : Probe
            (if (>= seen capacity)
              (Probe.Full)
              (match (array-ref slots index)
                [Slot.Empty (Probe.Absent (insert-slot first-tombstone index))]
                [Slot.Tombstone
                  (probe-from
                    slots
                    capacity
                    key
                    hash
                    (next-index index capacity)
                    (+ seen 1)
                    (if (>= first-tombstone 0)
                      first-tombstone
                      index))]
                [(Slot.Occupied existing existing-hash)
                  (if (if (= existing-hash hash)
                    (= existing key)
                    false)
                    (Probe.Found index)
                    (probe-from
                      slots
                      capacity
                      key
                      hash
                      (next-index index capacity)
                      (+ seen 1)
                      first-tombstone))])))
          (define (probe
            [slots : (& slots (Array Slot))]
            [capacity : i64]
            [key : i64]
            [hash : i64]) : Probe
            (probe-from
              slots
              capacity
              key
              hash
              (bucket-index hash capacity)
              0
              -1))
          (define (with-capacity [capacity : i64]) : Set
            (let
              [cap : i64
                (round-capacity
                  (if (< capacity 1)
                    1
                    capacity))]
              (Set (make-array Slot cap) 0 0)))
          (define (new) : Set
            (with-capacity 8))
          (define (len [set : (& set Set)]) : i64
            (struct-get set len))
          (define (capacity [set : (& set Set)]) : i64
            (array-length (struct-get set slots)))
          (define (capacity-mut [set : (&mut set Set)]) : i64
            (array-length (struct-get set slots)))
          (define (needs-grow? [set : (&mut set Set)]) : bool
            (> (* (+ (struct-get set len) 1) 4) (* (capacity-mut set) 3)))
          (define (grow [set : (&mut set Set)]) : unit
            (let
              [old-capacity : i64 (array-length (struct-get set slots))]
              [new-capacity : i64
                (if (< old-capacity 1)
                  1
                  (* old-capacity 2))]
              [fresh : (Array Slot) (make-array Slot new-capacity)]
              [scan : i64 0]
              (begin
                (while (< scan old-capacity)
                  (begin
                    (match (array-ref (struct-get set slots) scan)
                      [(Slot.Occupied key hash)
                        (let
                          [index : i64 (bucket-index hash new-capacity)]
                          [seen : i64 0]
                          [placed : bool false]
                          (while (if placed
                            false
                            (< seen new-capacity))
                            (match (array-ref fresh index)
                              [Slot.Empty
                                (begin
                                  (array-set!
                                    fresh
                                    index
                                    (Slot.Occupied key hash))
                                  (set! placed true))]
                              [_
                                (begin
                                  (set! index (next-index index new-capacity))
                                  (set! seen (+ seen 1)))])))]
                      [_ unit])
                    (set! scan (+ scan 1))))
                (set! (struct-get set slots) fresh)
                (set! (struct-get set deleted) 0))))
          (define (contains? [set : (& set Set)] [key : i64]) : bool
            (match (probe
              (& (struct-get set slots))
              (capacity set)
              key
              (hash-key key))
              [(Probe.Found _) true]
              [_ false]))
          (define (insert [set : (&mut set Set)] [key : i64]) : unit
            (begin
              (if (needs-grow? set)
                (grow set)
                unit)
              (let
                [hash : i64 (hash-key key)]
                (match (probe
                  (& (struct-get set slots))
                  (capacity-mut set)
                  key
                  hash)
                  [(Probe.Found _) unit]
                  [(Probe.Absent index)
                    (let
                      [was-tombstone : bool
                        (match (array-ref (struct-get set slots) index)
                          [Slot.Tombstone true]
                          [_ false])]
                      (begin
                        (array-set!
                          (struct-get set slots)
                          index
                          (Slot.Occupied key hash))
                        (set! (struct-get set len) (+ (struct-get set len) 1))
                        (if was-tombstone
                          (set!
                            (struct-get set deleted)
                            (- (struct-get set deleted) 1))
                          unit)))]
                  [Probe.Full
                    (begin
                      (grow set)
                      (insert set key))]))))
          (define (remove [set : (&mut set Set)] [key : i64]) : unit
            (match (probe
              (& (struct-get set slots))
              (capacity-mut set)
              key
              (hash-key key))
              [(Probe.Found index)
                (begin
                  (array-set! (struct-get set slots) index (Slot.Tombstone))
                  (set! (struct-get set len) (- (struct-get set len) 1))
                  (set! (struct-get set deleted) (+ (struct-get set deleted) 1)))]
              [_ unit]))
          (define (next-occupied [set : (& set Set)] [from : i64]) : i64
            (let
              [index : i64
                (if (< from 0)
                  0
                  from)]
              [cap : i64 (capacity set)]
              [found : bool false]
              (begin
                (while (if found
                  false
                  (< index cap))
                  (match (array-ref (struct-get set slots) index)
                    [(Slot.Occupied _ _) (set! found true)]
                    [_ (set! index (+ index 1))]))
                index)))
          (define (entry-at [set : (& set Set)] [index : i64]) : Entry
            (if (if (>= index 0)
              (< index (capacity set))
              false)
              (match (array-ref (struct-get set slots) index)
                [(Slot.Occupied key _) (Entry.Some key)]
                [_ (Entry.None)])
              (Entry.None)))
          (define (entry-key-or [entry : Entry] [fallback : i64]) : i64
            (match entry
              [(Entry.Some key) key]
              [Entry.None fallback]))
          (export
            (type Set)
            (constructor Set)
            (type Entry)
            (variant None)
            (variant Some)
            (value with-capacity)
            (value new)
            (value len)
            (value capacity)
            (value contains?)
            (value insert)
            (value remove)
            (value next-occupied)
            (value entry-at)
            (value entry-key-or)))]
      [_
        `(begin
          (module ,module-name))])))

(export (macro set))

;; Inline coverage migrated from stdlib/tests/set_api.tl (#3083) and from the
;; removed compiler-side set generator path (#3199).
(cfg test (import "test.tl"))
(cfg test (import "string.tl"))
(cfg test (import (set String) as strset))
(cfg test (import (set i64) as i64set))
(cfg test (import (set i64) as i64set_again))

(cfg
  test
  (define (set-test-string-entry-len-or [entry : strset.Entry] [fallback : i64]) : i64
    (let
      [value : String (strset.entry-key-or entry "")]
      (if (string-eq value "")
        fallback
        (string-length (& value))))))

(cfg
  test
  (test
    set-string-module-family
    (begin
      ;; String key family: duplicate insert, borrowed contains/remove, forced
      ;; bucket collision at capacity 4, tombstone reuse, and resize.
      (let
        [borrowed-key : String "alpha"]
        [s : strset.Set (strset.with-capacity 4)]
        (begin
          (strset.insert (&mut s) "alpha")
          (strset.insert (&mut s) "alpha")
          (assert-i64-eq
            (strset.len (& s))
            1
            "duplicate String insert is idempotent")
          (assert-true
            (strset.contains-borrowed? (& s) (& borrowed-key))
            "borrowed String contains finds owned key")
          (strset.insert (&mut s) "a")
          (strset.insert (&mut s) "e")
          (assert-true
            (strset.contains? (& s) "e")
            "String collision chain lookup")
          (strset.remove (&mut s) "a")
          (assert-false
            (strset.contains? (& s) "a")
            "String remove tombstones key")
          (assert-true
            (strset.contains? (& s) "e")
            "String tombstone preserves later collision")
          (strset.insert (&mut s) "i")
          (assert-true
            (strset.contains? (& s) "i")
            "String insert reuses tombstone slot")
          (strset.remove-borrowed (&mut s) (& borrowed-key))
          (assert-false
            (strset.contains-borrowed? (& s) (& borrowed-key))
            "borrowed String remove removes key")
          (let
            [len-before-missing : i64 (strset.len (& s))]
            (begin
              (strset.remove (&mut s) "missing")
              (assert-i64-eq
                (strset.len (& s))
                len-before-missing
                "missing String remove is no-op")))
          (strset.insert (&mut s) "one")
          (strset.insert (&mut s) "two")
          (strset.insert (&mut s) "three")
          (assert-true
            (> (strset.capacity (& s)) 4)
            "String set grows and rehashes")
          (assert-true
            (strset.contains? (& s) "e")
            "String set keeps old key after resize")
          (let
            [iter-index : i64 (strset.next-occupied (& s) 0)]
            [iter-count : i64 0]
            [iter-monotonic : bool true]
            (begin
              (while (< iter-index (strset.capacity (& s)))
                (let
                  [next : i64 (strset.next-occupied (& s) (+ iter-index 1))]
                  (begin
                    (set! iter-count (+ iter-count 1))
                    (if (> next iter-index)
                      unit
                      (set! iter-monotonic false))
                    (set! iter-index next))))
              (assert-i64-eq
                iter-count
                (strset.len (& s))
                "String set iteration visits every key")
              (assert-true
                iter-monotonic
                "String set iteration is ascending bucket order")))
          (assert-true
            (>
              (set-test-string-entry-len-or
                (strset.entry-at (& s) (strset.next-occupied (& s) 0))
                -1)
              0)
            "String set entry-at returns a live key")
          unit)))))

(cfg
  test
  (test
    set-i64-module-family
    (begin
      ;; i64 key family: same-bucket collisions, tombstone correctness, duplicate
      ;; insert, missing remove, resize, bucket-order iteration, and duplicate
      ;; `(set i64)` requests sharing one generated nominal Set.
      (let
        [s : i64set.Set (i64set.with-capacity 4)]
        (begin
          (i64set.insert (&mut s) 1)
          (i64set.insert (&mut s) 5)
          (i64set.insert (&mut s) 1)
          (assert-i64-eq
            (i64set.len (& s))
            2
            "duplicate i64 insert is idempotent")
          (assert-true (i64set.contains? (& s) 5) "i64 collision lookup")
          (i64set.remove (&mut s) 1)
          (assert-false (i64set.contains? (& s) 1) "i64 remove tombstones key")
          (assert-true
            (i64set.contains? (& s) 5)
            "i64 tombstone preserves later collision")
          (i64set.insert (&mut s) 9)
          (assert-true (i64set.contains? (& s) 9) "i64 tombstone slot reused")
          (let
            [len-before-missing : i64 (i64set.len (& s))]
            [sum-before-growth : i64 0]
            [sum-index : i64 (i64set.next-occupied (& s) 0)]
            (begin
              (while (< sum-index (i64set.capacity (& s)))
                (begin
                  (set!
                    sum-before-growth
                    (+
                      sum-before-growth
                      (i64set.entry-key-or (i64set.entry-at (& s) sum-index) 0)))
                  (set! sum-index (i64set.next-occupied (& s) (+ sum-index 1)))))
              (i64set.remove (&mut s) 999)
              (assert-i64-eq
                (i64set.len (& s))
                len-before-missing
                "missing i64 remove is no-op")
              (assert-i64-eq
                sum-before-growth
                14
                "i64 set iteration exposes live keys")))
          (i64set.insert (&mut s) 10)
          (i64set.insert (&mut s) 11)
          (i64set.insert (&mut s) 12)
          (assert-true
            (> (i64set.capacity (& s)) 4)
            "i64 set grows and rehashes")
          (let
            [iter-index : i64 (i64set.next-occupied (& s) 0)]
            [iter-count : i64 0]
            (begin
              (while (< iter-index (i64set.capacity (& s)))
                (begin
                  (set! iter-count (+ iter-count 1))
                  (set!
                    iter-index
                    (i64set.next-occupied (& s) (+ iter-index 1)))))
              (assert-i64-eq
                iter-count
                (i64set.len (& s))
                "i64 set iteration visits every key")))
          (assert-i64-eq
            (i64set_again.len (& s))
            (i64set.len (& s))
            "duplicate set macro requests share the generated type")
          unit)))))