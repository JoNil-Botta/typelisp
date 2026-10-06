;# Generated hash set modules (collections v1).
;#
;# `(set T)` emits a module-scoped hash set. Import each instantiation with an
;# alias when more than one set type is used:
;#
;# ```typelisp
;# (import stdlib.set)
;# (import (set.set i64) as iset)
;#
;# (define (main) : i64
;#   (let
;#     [s : iset.Set (iset.new)]
;#     (begin
;#       (iset.insert! s 10)
;#       (if (iset.contains? (& s) 10)
;#         (iset.len (& s))
;#         0))))
;# ```
;#
;# Public bang mutators take a caller-owned storage place and expand to an
;# explicit `&mut` call to their `*-ref!` helper. Readers take `&`. Iteration is
;# deterministic bucket order for a fixed table state. It is not insertion
;# order, and it can change after resize/rehash. Walk by starting at
;# `(next-occupied (& set) 0)`, advancing with `(+ index 1)`, and reading each
;# key with `entry-at`.
(import stdlib.comptime)

;; lint-allow: unused-import
(import stdlib.string)

;: Emit a generated hash set module for key type `T`.
;:
;: `String` and `i64` keys share one open-addressing template. String keys
;: additionally get byte hashing, borrowed `(& str)` lookup/removal entry points
;: and map-owned key copies; any other key type yields an empty module.
(defmacro (set [T : type]) : Module
  (let
    [type-key-name : String (type-key T)]
    [module-name-text : String
      (comptime.string-append "stdlib.set.generated." type-key-name)]
    [module-name : comptime.Expr (comptime.expr-var module-name-text)]
    [insert-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".insert-ref!"))]
    [remove-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".remove-ref!"))]
    [remove-borrowed-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".remove-borrowed-ref!"))]
    [key-kind : i64
      (match type-key-name
        ["String" 1]
        ["i64" 2]
        [_ 0])]
    (if (= key-kind 0)
      `(begin
        (module ,module-name))
      (let
        [string-key? : bool (= key-kind 1)]
        [key-type : comptime.Expr
          (if string-key?
            `String
            `i64)]
        [key-param-type : comptime.Expr
          (if string-key?
            `(& key str)
            `i64)]
        [key-arg : comptime.Expr
          (if string-key?
            `(& key)
            `key)]
        [owned-key : comptime.Expr
          (if string-key?
            `(clone key)
            `key)]
        [key-eq : comptime.Expr
          (if string-key?
            `(key-eq-borrowed? existing key)
            `(= existing key))]
        [probe-from-name : comptime.Expr
          (if string-key?
            `probe-borrowed-from
            `probe-from)]
        [probe-name : comptime.Expr
          (if string-key?
            `probe-borrowed
            `probe)]
        [contains-name : comptime.Expr
          (if string-key?
            `contains-borrowed?
            `contains?)]
        [remove-name : comptime.Expr
          (if string-key?
            `remove-borrowed-ref!
            `remove-ref!)]
        [hash-key-def : comptime.Expr
          (if string-key?
            `(define (hash-key [key : (& key str)]) : i64
              (let
                [n : i64 (key-length key)]
                [i : i64 0]
                [hash : i64 0]
                (while (< i n)
                  (set!
                    hash
                    (%
                      (+ (+ (* hash 131) (cast (key-ref key i) : i64)) 1)
                      2147483647))
                  (set! i (+ i 1)))
                hash))
            `(define (hash-key [key : i64]) : i64
              (hash-normalize key)))]
        [string-imports : comptime.ExprList
          (if string-key?
            (comptime.expr-list-cons
              `(import stdlib.string)
              (comptime.expr-list-empty))
            (comptime.expr-list-empty))]
        [string-key-helpers : comptime.ExprList
          (if string-key?
            (comptime.expr-list-cons
              `(define (key-length [key : (& key str)]) : i64
                (__tl_string_length key))
              (comptime.expr-list-cons
                `(define (key-ref [key : (& key str)] [index : i64]) : char
                  (__tl_string_ref key index))
                (comptime.expr-list-empty)))
            (comptime.expr-list-empty))]
        [string-key-eq : comptime.ExprList
          (if string-key?
            (comptime.expr-list-cons
              `(define (key-eq-borrowed?
                [left : String]
                [right : (& right str)]) : bool
                (let
                  [left-len : i64 (key-length (& left))]
                  [right-len : i64 (key-length right)]
                  (if (not (= left-len right-len))
                    false
                    (let
                      [i : i64 0]
                      [same : bool true]
                      (while (if same
                        (< i left-len)
                        false)
                        (if (= (key-ref (& left) i) (key-ref right i))
                          (set! i (+ i 1))
                          (set! same false)))
                      same))))
              (comptime.expr-list-empty))
            (comptime.expr-list-empty))]
        [owned-contains : comptime.ExprList
          (if string-key?
            (comptime.expr-list-cons
              `(define (contains? [set : (& set Set)] [key : String]) : bool
                (contains-borrowed? set (& key)))
              (comptime.expr-list-empty))
            (comptime.expr-list-empty))]
        [owned-remove : comptime.ExprList
          (if string-key?
            (comptime.expr-list-cons
              `(define (remove-ref! [set : (&mut set Set)] [key : String]) : unit
                (remove-borrowed-ref! set (& key)))
              (comptime.expr-list-empty))
            (comptime.expr-list-empty))]
        [borrowed-remove-macro : comptime.ExprList
          (if string-key?
            (comptime.expr-list-cons
              `(defmacro (remove-borrowed! [place : Expr] [key : Expr]) : unit
                (expr-mut-call1
                  (expr-var ,remove-borrowed-helper-name)
                  place
                  key))
              (comptime.expr-list-empty))
            (comptime.expr-list-empty))]
        `(begin
          (module ,module-name)
          ,@string-imports
          (defenum Slot
            (Empty)
            (Tombstone)
            (Occupied ,key-type i64))
          (defenum Probe
            (Found i64)
            (Absent i64)
            (Full))
          (defstruct Set
            (slots (__tl_dyn-array Slot))
            (len i64)
            (deleted i64))
          (defenum Entry
            (None)
            (Some ,key-type))
          ,@string-key-helpers
          (define (hash-normalize [value : i64]) : i64
            (let
              [m : i64 2147483647]
              [raw : i64 (% value m)]
              (if (< raw 0)
                (+ raw m)
                raw)))
          ,hash-key-def
          ,@string-key-eq
          (define (round-capacity [capacity : i64]) : i64
            (let
              [rounded : i64 1]
              (while (< rounded capacity)
                (set! rounded (* rounded 2)))
              rounded))
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
          (define (,probe-from-name
            [slots : (& slots (__tl_dyn-array Slot))]
            [capacity : i64]
            [key : ,key-param-type]
            [hash : i64]
            [index : i64]
            [seen : i64]
            [first-tombstone : i64]) : Probe
            (if (>= seen capacity)
              (Probe.Full)
              (match (array-ref slots index)
                [Slot.Empty (Probe.Absent (insert-slot first-tombstone index))]
                [Slot.Tombstone
                  (,probe-from-name
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
                    ,key-eq
                    false)
                    (Probe.Found index)
                    (,probe-from-name
                      slots
                      capacity
                      key
                      hash
                      (next-index index capacity)
                      (+ seen 1)
                      first-tombstone))])))
          (define (,probe-name
            [slots : (& slots (__tl_dyn-array Slot))]
            [capacity : i64]
            [key : ,key-param-type]
            [hash : i64]) : Probe
            (,probe-from-name
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
              (Set (__tl_make-array Slot cap) 0 0)))
          (define (new) : Set
            (with-capacity 8))
          (define (len [set : (& set Set)]) : i64
            set.len)
          (define (capacity [set : (& set Set)]) : i64
            (array-length set.slots))
          (define (capacity-mut [set : (&mut set Set)]) : i64
            (array-length set.slots))
          (define (needs-grow? [set : (&mut set Set)]) : bool
            (> (* (+ set.len 1) 4) (* (capacity-mut set) 3)))
          (define (grow [set : (&mut set Set)]) : unit
            (let
              [old-capacity : i64 (array-length set.slots)]
              [new-capacity : i64
                (if (< old-capacity 1)
                  1
                  (* old-capacity 2))]
              [fresh : (__tl_dyn-array Slot)
                (__tl_make-array Slot new-capacity)]
              [scan : i64 0]
              (while (< scan old-capacity)
                (match (array-ref set.slots scan)
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
                            (set!
                              (array-ref fresh index)
                              (Slot.Occupied ,owned-key hash))
                            (set! placed true)]
                          [_
                            (set! index (next-index index new-capacity))
                            (set! seen (+ seen 1))])))]
                  [_ unit])
                (set! scan (+ scan 1)))
              (set! set.slots fresh)
              (set! set.deleted 0)))
          (define (,contains-name [set : (& set Set)] [key : ,key-param-type]) : bool
            (match (,probe-name (& set.slots) (capacity set) key (hash-key key))
              [(Probe.Found _) true]
              [_ false]))
          ,@owned-contains
          (define (insert-ref! [set : (&mut set Set)] [key : ,key-type]) : unit
            (if (needs-grow? set)
              (grow set)
              unit)
            (let
              [hash : i64 (hash-key ,key-arg)]
              (match (,probe-name
                (& set.slots)
                (capacity-mut set)
                ,key-arg
                hash)
                [(Probe.Found _) unit]
                [(Probe.Absent index)
                  (let
                    [was-tombstone : bool
                      (match (array-ref set.slots index)
                        [Slot.Tombstone true]
                        [_ false])]
                    (set! (array-ref set.slots index) (Slot.Occupied key hash))
                    (set! set.len (+ set.len 1))
                    (if was-tombstone
                      (set! set.deleted (- set.deleted 1))
                      unit))]
                [Probe.Full
                  (grow set)
                  (insert-ref! set key)])))
          (define (,remove-name [set : (&mut set Set)] [key : ,key-param-type]) : unit
            (match (,probe-name
              (& set.slots)
              (capacity-mut set)
              key
              (hash-key key))
              [(Probe.Found index)
                (set! (array-ref set.slots index) (Slot.Tombstone))
                (set! set.len (- set.len 1))
                (set! set.deleted (+ set.deleted 1))]
              [_ unit]))
          ,@owned-remove
          (define (next-occupied [set : (& set Set)] [from : i64]) : i64
            (let
              [index : i64
                (if (< from 0)
                  0
                  from)]
              [cap : i64 (capacity set)]
              [found : bool false]
              (while (if found
                false
                (< index cap))
                (match (array-ref set.slots index)
                  [(Slot.Occupied _ _) (set! found true)]
                  [_ (set! index (+ index 1))]))
              index))
          (define (entry-at [set : (& set Set)] [index : i64]) : Entry
            (if (if (>= index 0)
              (< index (capacity set))
              false)
              (match (array-ref set.slots index)
                [(Slot.Occupied key _) (Entry.Some ,owned-key)]
                [_ (Entry.None)])
              (Entry.None)))
          (define (entry-key-or [entry : Entry] [fallback : ,key-type]) : ,key-type
            (match entry
              [(Entry.Some key) key]
              [Entry.None fallback]))
          ;; Public set updates take a caller place. The `*-ref!` helpers are
          ;; retained only for code that already owns an explicit mutable ref.
          ;; Direct CTFE helper aliases avoid another generated-module comptime
          ;; import; the generated module body is materialized by its own imports.
          (defmacro (insert! [place : Expr] [key : Expr]) : unit
            (expr-mut-call1 (expr-var ,insert-helper-name) place key))
          (defmacro (remove! [place : Expr] [key : Expr]) : unit
            (expr-mut-call1 (expr-var ,remove-helper-name) place key))
          ,@borrowed-remove-macro)))))

;; Inline test coverage.
(cfg test (import stdlib.test))
(cfg test (import (set String) as strset))
(cfg test (import (set i64) as i64set))
(cfg test (import (set i64) as i64set_again))

(cfg
  test
  (define (set-test-string-entry-len-or [entry : strset.Entry] [fallback : i64]) : i64
    (let
      [value : String (strset.entry-key-or entry "")]
      (if (__tl_string_eq value "")
        fallback
        (__tl_string_length (& value))))))

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
        (strset.insert! s "alpha")
        (strset.insert! s "alpha")
        (test.assert-i64-eq
          (strset.len (& s))
          1
          "duplicate String insert is idempotent")
        (test.assert-true
          (strset.contains-borrowed? (& s) (& borrowed-key))
          "borrowed String contains finds owned key")
        (strset.insert! s "a")
        (strset.insert! s "e")
        (test.assert-true
          (strset.contains? (& s) "e")
          "String collision chain lookup")
        (strset.remove! s "a")
        (test.assert-false
          (strset.contains? (& s) "a")
          "String remove tombstones key")
        (test.assert-true
          (strset.contains? (& s) "e")
          "String tombstone preserves later collision")
        (strset.insert! s "i")
        (test.assert-true
          (strset.contains? (& s) "i")
          "String insert reuses tombstone slot")
        (strset.remove-borrowed! s (& borrowed-key))
        (test.assert-false
          (strset.contains-borrowed? (& s) (& borrowed-key))
          "borrowed String remove removes key")
        (let
          [len-before-missing : i64 (strset.len (& s))]
          (strset.remove! s "missing")
          (test.assert-i64-eq
            (strset.len (& s))
            len-before-missing
            "missing String remove is no-op"))
        (strset.insert! s "one")
        (strset.insert! s "two")
        (strset.insert! s "three")
        (test.assert-true
          (> (strset.capacity (& s)) 4)
          "String set grows and rehashes")
        (test.assert-true
          (strset.contains? (& s) "e")
          "String set keeps old key after resize")
        (let
          [iter-index : i64 (strset.next-occupied (& s) 0)]
          [iter-count : i64 0]
          [iter-monotonic : bool true]
          (while (< iter-index (strset.capacity (& s)))
            (let
              [next : i64 (strset.next-occupied (& s) (+ iter-index 1))]
              (set! iter-count (+ iter-count 1))
              (if (> next iter-index)
                unit
                (set! iter-monotonic false))
              (set! iter-index next)))
          (test.assert-i64-eq
            iter-count
            (strset.len (& s))
            "String set iteration visits every key")
          (test.assert-true
            iter-monotonic
            "String set iteration is ascending bucket order"))
        (test.assert-true
          (>
            (set-test-string-entry-len-or
              (strset.entry-at (& s) (strset.next-occupied (& s) 0))
              -1)
            0)
          "String set entry-at returns a live key")
        unit))))

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
        (i64set.insert! s 1)
        (i64set.insert! s 5)
        (i64set.insert! s 1)
        (test.assert-i64-eq
          (i64set.len (& s))
          2
          "duplicate i64 insert is idempotent")
        (test.assert-true (i64set.contains? (& s) 5) "i64 collision lookup")
        (i64set.remove! s 1)
        (test.assert-false
          (i64set.contains? (& s) 1)
          "i64 remove tombstones key")
        (test.assert-true
          (i64set.contains? (& s) 5)
          "i64 tombstone preserves later collision")
        (i64set.insert! s 9)
        (test.assert-true
          (i64set.contains? (& s) 9)
          "i64 tombstone slot reused")
        (let
          [len-before-missing : i64 (i64set.len (& s))]
          [sum-before-growth : i64 0]
          [sum-index : i64 (i64set.next-occupied (& s) 0)]
          (while (< sum-index (i64set.capacity (& s)))
            (set!
              sum-before-growth
              (+
                sum-before-growth
                (i64set.entry-key-or (i64set.entry-at (& s) sum-index) 0)))
            (set! sum-index (i64set.next-occupied (& s) (+ sum-index 1))))
          (i64set.remove! s 999)
          (test.assert-i64-eq
            (i64set.len (& s))
            len-before-missing
            "missing i64 remove is no-op")
          (test.assert-i64-eq
            sum-before-growth
            14
            "i64 set iteration exposes live keys"))
        (i64set.insert! s 10)
        (i64set.insert! s 11)
        (i64set.insert! s 12)
        (test.assert-true
          (> (i64set.capacity (& s)) 4)
          "i64 set grows and rehashes")
        (let
          [iter-index : i64 (i64set.next-occupied (& s) 0)]
          [iter-count : i64 0]
          (while (< iter-index (i64set.capacity (& s)))
            (set! iter-count (+ iter-count 1))
            (set! iter-index (i64set.next-occupied (& s) (+ iter-index 1))))
          (test.assert-i64-eq
            iter-count
            (i64set.len (& s))
            "i64 set iteration visits every key"))
        (test.assert-i64-eq
          (i64set_again.len (& s))
          (i64set.len (& s))
          "duplicate set macro requests share the generated type")
        unit))))