;# Generated hashmap modules (collections v1).
;#
;# `(hashmap K V)` emits a complete open-addressed, linear-probing map module.
;# Every instantiation owns its slot, probe, map, lookup, mutation, and
;# iteration declarations; there are no checked-in concrete backing families.
;#
;# String keys use borrowed lookup/contains/remove entry points and the stable
;# `hash.string-key`/`hash.key-string-eq?` rules. i64 keys use a multiplicative
;# bucket hash and scalar equality. Other cloneable structural keys use the
;# generated `(hash K)` and `(eq K)` modules.
;#
;# Slots are interleaved tagged structs whose state is
;# `Empty | Tombstone | Occupied`. The stored hash makes a probe step cheap for
;# keys whose equality is expensive. The `i64 -> i64` family omits the hash
;# field: `key-eq?` for an i64 key is a single compare, so the hash guarded
;# nothing while costing a word per slot -- a quarter of the slot, of
;# allocation, of zeroing, and of probe cache traffic.
;# Growth recomputes `hash-key` per occupied slot instead. The hash function,
;# capacity policy, probe order, first-tombstone rule, and growth condition are
;# shared, so slot indices and iteration order are identical under either.
;#
;# Read-only lookups go through one index-returning `find-index` helper rather
;# than the `GeneratedHashmapProbe` value: `Found`/`Absent`/`Full` is a payload
;# enum that the ABI returns through memory, and only the insert and mut-entry
;# paths need the absent slot or the first tombstone it carries. `find-index`
;# reports "no such key" as -1 and keeps the probe order, wrap rule and
;# terminating bound of `probe` exactly, so lookup, containment and removal see
;# the same slot for the same table state. The scalar `get`/`get-borrowed` pair
;# emits that same probe inline and yields the value from the slot it stopped
;# on: routing them through `find-index` paid a call, then re-derived the slot
;# array, repeated a bounds check and re-matched a state the probe had already
;# decided. The probe order and hash are shared with `find-index`, so the two
;# still agree on every slot, and no iteration order moves.
;#
;# The scalar scan loops bound themselves by wrap detection -- the cursor
;# returning to the slot it started at -- instead of a separate step counter.
;# The cursor is masked by a positive power-of-two capacity, so it visits every
;# slot exactly once before repeating: the loop still stops after at most the
;# slot-array length on a full table while carrying one less live value and one
;# less add/compare per collision step.
;# The map's third descriptor word caches `growth threshold - deleted`.
;# Removal decrements it and tombstone reuse restores it, making
;# `len >= growth-limit` the previous `len + deleted` condition while keeping
;# the descriptor at three words. The public deleted count is derived.
;#
;# Public capacities are positive powers of two. Probing visits at most the
;# slot-array length, remembers the first tombstone, and terminates on full
;# tables. Iteration is deterministic bucket order for a fixed table state.
;#
;# Usage:
;#
;# ```typelisp
;# (import stdlib.hashmap)
;# (import (hashmap.hashmap String i64) as map)
;# (define (main) : i64
;#   (let
;#     [m : map.Map (map.new)]
;#     (begin
;#       (map.insert! m "k" 42)
;#       (map.lookup-value-or (map.get (& m) "k") 0))))
;# ```
(import stdlib.comptime)
(import stdlib.eq)
(import stdlib.hash)

;; lint-allow: unused-import
(import stdlib.string)

;: Stable descriptor identity for generated `String`-key hashmap families.
(define (string-key-descriptor-key) : String
  "stdlib/hashmap/string-key-v1")

;: Stable descriptor identity for generated `i64`-key hashmap families.
(define (i64-key-descriptor-key) : String
  "stdlib/hashmap/i64-key-v1")

;: Stable descriptor identity for generated structural-key hashmap families.
(define (aggregate-key-descriptor-key) : String
  "stdlib/hashmap/aggregate-key-v1")

;: Emit a complete hashmap module for every supported key/value pair.
(defmacro (hashmap [K : type] [V : type]) : Module
  (let
    [key-kind : String
      (match (type-key K)
        ["String" "string"]
        ["i64" "i64"]
        [_ "generated"])]
    [value-kind : String
      (match (type-key V)
        ["i64" "i64"]
        ["String" "string"]
        ["struct_stdlib.hashmap/HashPayload" "aggregate"]
        ["enum_stdlib.hashmap/HashState" "aggregate"]
        [_ "unsupported"])]
    [module-key-k : String (type-key K)]
    [module-key-v : String
      (match (type-key V)
        ["struct_stdlib.hashmap/HashPayload"
          "struct_stdlib.hashmap.HashPayload"]
        ["enum_stdlib.hashmap/HashState" "enum_stdlib.hashmap.HashState"]
        [_ (type-key V)])]
    [module-name-text : String
      (comptime.string-append
        "stdlib.hashmap.generated."
        (comptime.string-append
          module-key-k
          (comptime.string-append "." module-key-v)))]
    [module-name : comptime.Expr (comptime.expr-var module-name-text)]
    [key-module-imports : comptime.ExprList
      (if (string.eq key-kind "generated")
        (comptime.expr-list-cons
          `(import (hash.hash ,K) as key_hash)
          (comptime.expr-list-cons
            `(import (eq.eq ,K) as key_eq)
            (comptime.expr-list-empty)))
        (comptime.expr-list-empty))]
    [insert-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".insert-ref!"))]
    [insert-or-update-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".insert-or-update-ref!"))]
    [insert-if-absent-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".insert-if-absent-ref!"))]
    [remove-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".remove-ref!"))]
    [remove-borrowed-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".remove-borrowed-ref!"))]
    [entry-or-insert-helper-name : comptime.Expr
      (comptime.expr-string
        (comptime.string-append module-name-text ".entry-or-insert-ref!"))]
    [query-key-type : comptime.Expr
      (if (string.eq key-kind "string")
        `(& key str)
        K)]
    [key-eq-left-type : comptime.Expr
      (if (string.eq key-kind "string")
        `(& left str)
        K)]
    [owned-query-key : comptime.Expr
      (match key-kind
        ["string" `(& key)]
        ["generated" `(clone key)]
        [_ `key])]
    [query-owned-key : comptime.Expr
      (match key-kind
        ["string" `(string_mod.copy key)]
        ["generated" `(clone key)]
        [_ `key])]
    [reusable-query-key : comptime.Expr
      (if (string.eq key-kind "generated")
        `(clone key)
        `key)]
    [borrowed-value-type : comptime.Expr
      (if (string.eq value-kind "string")
        (comptime.expr-var "str")
        V)]
    [key-copy : comptime.Expr
      (match key-kind
        ["string" `(string_mod.copy (& key))]
        ["i64" `key]
        [_ `(clone key)])]
    [insert-key-copy : comptime.Expr
      (if (string.eq key-kind "generated")
        `(clone key)
        `key)]
    [value-copy : comptime.Expr
      (match value-kind
        ["string" `(string_mod.copy (& value))]
        ["i64" `value]
        ["aggregate" `(clone value)]
        [_ `value])]
    [hash-key-body : comptime.Expr
      (match key-kind
        ["string" `(hash_mod.string-key key)]
        ["i64" `(* key 6364136223846793005)]
        [_ `(key_hash.hash key)])]
    [key-eq-body : comptime.Expr
      (match key-kind
        ["string" `(hash_mod.key-string-eq? left right)]
        ["i64" `(= left right)]
        [_ `(key_eq.eq left right)])]
    [probe-key-eq-body : comptime.Expr
      (if (string.eq key-kind "generated")
        `(key-eq? (clone (__tl-project-field-name slot "key")) (clone key))
        `(key-eq? (__tl-project-field-name slot "key") key))]
    ;; Keep the generated i64 -> i64 hot path as lean as the former concrete
    ;; family. Its raw reads are bounded by the positive power-of-two capacity;
    ;; growth finishes before a pointer is captured, and no scan reallocates.
    [scalar-family : bool
      (if (string.eq key-kind "i64")
        (string.eq value-kind "i64")
        false)]
    ;; Scalar slots are bitwise-movable. Rehash through raw pointers so the
    ;; capacity invariants discharge bounds once, then copy each contiguous
    ;; 32-byte slot through aggregate ptr-write!; lowering emits two 16-byte
    ;; load/store chunks. Other families reconstruct slots so String and
    ;; aggregate keys/values receive their required owned copies.
    [grow-rehash-body : comptime.Expr
      (if scalar-family
        `(let
          [old-data : (Ptr GeneratedHashmapSlot)
            (unsafe
              (ptr-cast (array-data map.slots) : (Ptr GeneratedHashmapSlot)))]
          [fresh-data : (MutPtr GeneratedHashmapSlot)
            (unsafe
              (ptr-cast (array-data fresh) : (MutPtr GeneratedHashmapSlot)))]
          (while (< scan old-capacity)
            (begin
              (let
                [old-slot : GeneratedHashmapSlot
                  (unsafe
                    (ptr-read (ptr-offset old-data scan)))]
                (match (__tl-project-field-name old-slot "state")
                  [GeneratedHashmapSlotState.Occupied
                    (let
                      ;; No stored hash on a scalar slot: recompute the same
                      ;; multiplicative bucket hash `hash-key` uses, so every
                      ;; key lands in the bucket the stored word used to name.
                      ;; One multiply per live slot at growth, against a word
                      ;; per slot of probe traffic on every lookup.
                      [key : ,K (__tl-project-field-name old-slot "key")]
                      [index : i64 (bit-and (* key 6364136223846793005) mask)]
                      (begin
                        (while (match (__tl-project-field-name
                          (unsafe
                            (ptr-read (ptr-offset fresh-data index)))
                          "state")
                          [GeneratedHashmapSlotState.Empty false]
                          [_ true])
                          (set! index (bit-and (+ index 1) mask)))
                        (unsafe
                          (ptr-write! (ptr-offset fresh-data index) old-slot))))]
                  [_ unit]))
              (set! scan (+ scan 1)))))
        `(let
          [old-slots : (& map (__tl_dyn-array GeneratedHashmapSlot))
            (& map.slots)]
          [old-count : i64 (array_ops.length old-slots)]
          (while (< scan old-count)
            (begin
              (let
                [old-slot : GeneratedHashmapSlot
                  (clone (array-ref old-slots scan))]
                (match (clone (__tl-project-field-name old-slot "state"))
                  [GeneratedHashmapSlotState.Occupied
                    (let
                      [key : ,K
                        (clone (__tl-project-field-name old-slot "key"))]
                      [value : ,V
                        (clone (__tl-project-field-name old-slot "value"))]
                      [hash : i64 (__tl-project-field-name old-slot "hash")]
                      [index : i64 (bit-and hash mask)]
                      (begin
                        (while (match (clone
                          (__tl-project-field-name
                            (array-ref fresh index)
                            "state"))
                          [GeneratedHashmapSlotState.Empty false]
                          [_ true])
                          (set! index (bit-and (+ index 1) mask)))
                        (let
                          [slot : (&mut fresh GeneratedHashmapSlot)
                            (&mut (array-ref fresh index))]
                          (begin
                            (__tl-project-set-field-name slot "key" ,key-copy)
                            (__tl-project-set-field-name
                              slot
                              "value"
                              ,value-copy)
                            (__tl-project-set-field-name slot "hash" hash)
                            (__tl-project-set-field-name
                              slot
                              "state"
                              (GeneratedHashmapSlotState.Occupied))))))]
                  [_ unit]))
              (set! scan (+ scan 1))))))]
    [get-value-or-body : comptime.Expr
      (if scalar-family
        `(let
          [slots : (& map (__tl_dyn-array GeneratedHashmapSlot)) (& map.slots)]
          [data : (Ptr GeneratedHashmapSlot)
            (unsafe
              (ptr-cast (array-data map.slots) : (Ptr GeneratedHashmapSlot)))]
          [cap : i64 (array_ops.length slots)]
          ;; A zero-length table is reachable through a ZII-initialized map, and
          ;; its mask would be -1 -- the guard is what keeps the masked cursor
          ;; in bounds, not decoration.
          (if (<= cap 0)
            fallback
            (let
              [mask : i64 (- cap 1)]
              [cursor : i64 (bit-and (* key 6364136223846793005) mask)]
              [start : i64 cursor]
              (begin
                (while true
                  (begin
                    ;; Occupied leads the arm order: it is the tag every
                    ;; collision step reads, so the common step classifies a
                    ;; slot in one compare instead of falling through two.
                    (let
                      [slot : GeneratedHashmapSlot
                        (unsafe
                          (ptr-read (ptr-offset data cursor)))]
                      (match (__tl-project-field-name slot "state")
                        [GeneratedHashmapSlotState.Occupied
                          (if (= (__tl-project-field-name slot "key") key)
                            (return (__tl-project-field-name slot "value"))
                            (set! cursor (bit-and (+ cursor 1) mask)))]
                        [GeneratedHashmapSlotState.Empty (return fallback)]
                        [GeneratedHashmapSlotState.Tombstone
                          (set! cursor (bit-and (+ cursor 1) mask))]))
                    ;; Wrap detection is the walked bound: a masked cursor over
                    ;; a positive power-of-two capacity returns to `start` only
                    ;; after visiting all `cap` slots.
                    (if (= cursor start)
                      (return fallback)
                      unit)))
                fallback))))
        `(lookup-value-or (get map key) fallback))]
    [update-slot-body : comptime.Expr
      `(set-occupied-value! (&mut map.slots) index value)]
    [growth-limit-body : comptime.Expr
      (if scalar-family
        `(- capacity (shr capacity 2))
        `(if (< capacity 4)
          (- capacity 1)
          (- capacity (shr capacity 2))))]
    [insert-ref-body : comptime.Expr
      (if scalar-family
        `(let
          [growth-limit-before : i64 map.growth-limit]
          (begin
            ;; Preserve the pre-probe len + deleted condition through the
            ;; cached limit: below the threshold at least one Empty slot
            ;; remains in the table.
            ;; Perform this exactly once before deriving data or probing, so a
            ;; grow cannot invalidate the raw pointer used by the loop.
            (if (>= map.len growth-limit-before)
              (grow! map)
              unit)
            (let
              [data : (MutPtr GeneratedHashmapSlot)
                (unsafe
                  (ptr-cast
                    (array-data map.slots)
                    : (MutPtr GeneratedHashmapSlot)))]
              ;; with-capacity and grow! preserve a positive power-of-two
              ;; capacity, making the masked initial cursor in bounds.
              [cap : i64 (array_ops.length map.slots)]
              [hash : i64 (* key 6364136223846793005)]
              [mask : i64 (- cap 1)]
              [cursor : i64 (bit-and hash mask)]
              [start : i64 cursor]
              [first : i64 -1]
              (begin
                ;; The preserved growth predicate guarantees an Empty slot,
                ;; so this loop terminates without a redundant walked bound.
                (while true
                  (begin
                    (let
                      [observed-slot : GeneratedHashmapSlot
                        (unsafe
                          (ptr-read (ptr-offset data cursor)))]
                      (match (__tl-project-field-name observed-slot "state")
                        [GeneratedHashmapSlotState.Empty
                          (if (< first 0)
                            (begin
                              ;; The cursor is already a masked in-bounds index
                              ;; and `data` is the array the loop just read
                              ;; through, so publishing through the same raw
                              ;; pointer skips re-deriving the array and the
                              ;; bounds check `array-ref` would repeat.
                              (unsafe
                                (ptr-write!
                                  (ptr-offset data cursor)
                                  (GeneratedHashmapSlot
                                    (GeneratedHashmapSlotState.Occupied)
                                    key
                                    value)))
                              (set! map.len (+ map.len 1))
                              (return unit))
                            (begin
                              (unsafe
                                (ptr-write!
                                  (ptr-offset data first)
                                  (GeneratedHashmapSlot
                                    (GeneratedHashmapSlotState.Occupied)
                                    key
                                    value)))
                              (set! map.len (+ map.len 1))
                              (set! map.growth-limit (+ map.growth-limit 1))
                              (return unit)))]
                        [GeneratedHashmapSlotState.Tombstone
                          (begin
                            (if (< first 0)
                              (set! first cursor)
                              unit)
                            ;; Wrap by masking rather than comparing. The capacity
                            ;; is a positive power of two -- the same invariant the
                            ;; masked initial cursor above already relies on -- so
                            ;; for `next` in [1, cap] the mask maps `cap` to 0 and
                            ;; leaves every smaller value alone. One `and` replaces
                            ;; a compare and an unpredictable branch.
                            (set! cursor (bit-and (+ cursor 1) mask)))]
                        [GeneratedHashmapSlotState.Occupied
                          (if (=
                            (__tl-project-field-name observed-slot "key")
                            key)
                            (begin
                              ;; The slot was just classified Occupied with a
                              ;; matching key, so the state re-check inside
                              ;; set-occupied-value! is known-true here.
                              (unsafe
                                (ptr-write!
                                  (ptr-offset data cursor)
                                  (GeneratedHashmapSlot
                                    (GeneratedHashmapSlotState.Occupied)
                                    key
                                    value)))
                              (return unit))
                            (set! cursor (bit-and (+ cursor 1) mask)))]))
                    ;; Map values may be shallow-copied while sharing their
                    ;; slot descriptor. Preserve the prior Full-table behavior
                    ;; for a stale copied len without a per-probe counter.
                    (if (= cursor start)
                      (if (< first 0)
                        (return unit)
                        (begin
                          (unsafe
                            (ptr-write!
                              (ptr-offset data first)
                              (GeneratedHashmapSlot
                                (GeneratedHashmapSlotState.Occupied)
                                key
                                value)))
                          (set! map.len (+ map.len 1))
                          (set! map.growth-limit (+ map.growth-limit 1))
                          (return unit)))
                      unit)))
                unit))))
        `(begin
          (if (needs-grow? map)
            (grow! map)
            unit)
          (let
            [hash : i64 (hash-key ,owned-query-key)]
            (match (probe
              (& map.slots)
              (capacity-mut map)
              ,owned-query-key
              hash)
              [(GeneratedHashmapProbe.Found index) ,update-slot-body]
              [(GeneratedHashmapProbe.Absent index)
                (let
                  [was-tombstone : bool
                    (match (__tl-project-field-name
                      (array-ref map.slots index)
                      "state")
                      [GeneratedHashmapSlotState.Tombstone true]
                      [_ false])]
                  (begin
                    (publish-occupied!
                      (&mut map.slots)
                      index
                      ,insert-key-copy
                      value
                      hash)
                    (set! map.len (+ map.len 1))
                    (if was-tombstone
                      (set! map.growth-limit (+ map.growth-limit 1))
                      unit)))]
              [GeneratedHashmapProbe.Full
                (begin
                  (grow! map)
                  (insert-ref! map key value))]))))]
    ;; Probe body. The scalar arm has no stored hash to pre-compare against, so
    ;; it confirms the key directly, and Occupied leads the arm order because it
    ;; is the tag every collision step reads. Probe order, wrap rule,
    ;; first-tombstone reuse, and the walked bound are identical either way, so
    ;; a key lands in the same slot index and iteration order is unchanged.
    [probe-decl : comptime.Expr
      (if scalar-family
        `(define (probe
          [slots : (& slots (__tl_dyn-array GeneratedHashmapSlot))]
          [capacity : i64]
          [key : ,query-key-type]
          [hash : i64]) : GeneratedHashmapProbe
          (if (<= capacity 0)
            (GeneratedHashmapProbe.Full)
            (let
              [cursor : i64 (bit-and hash (- capacity 1))]
              [walked : i64 0]
              [first : i64 -1]
              [mask : i64 (- capacity 1)]
              (begin
                (while (< walked capacity)
                  (let
                    [slot : (& slots GeneratedHashmapSlot)
                      (& (array-ref slots cursor))]
                    (match (clone (__tl-project-field-name slot "state"))
                      [GeneratedHashmapSlotState.Occupied
                        (if ,probe-key-eq-body
                          (return (GeneratedHashmapProbe.Found cursor))
                          (begin
                            (set! cursor (bit-and (+ cursor 1) mask))
                            (set! walked (+ walked 1))))]
                      [GeneratedHashmapSlotState.Empty
                        (return
                          (GeneratedHashmapProbe.Absent
                            (if (>= first 0)
                              first
                              cursor)))]
                      [GeneratedHashmapSlotState.Tombstone
                        (begin
                          (if (< first 0)
                            (set! first cursor)
                            unit)
                          (set! cursor (bit-and (+ cursor 1) mask))
                          (set! walked (+ walked 1)))])))
                (if (>= first 0)
                  (GeneratedHashmapProbe.Absent first)
                  (GeneratedHashmapProbe.Full))))))
        `(define (probe
          [slots : (& slots (__tl_dyn-array GeneratedHashmapSlot))]
          [capacity : i64]
          [key : ,query-key-type]
          [hash : i64]) : GeneratedHashmapProbe
          (if (<= capacity 0)
            (GeneratedHashmapProbe.Full)
            (let
              [cursor : i64 (bit-and hash (- capacity 1))]
              [walked : i64 0]
              [first : i64 -1]
              [mask : i64 (- capacity 1)]
              (begin
                (while (< walked capacity)
                  (let
                    [slot : (& slots GeneratedHashmapSlot)
                      (& (array-ref slots cursor))]
                    (match (clone (__tl-project-field-name slot "state"))
                      [GeneratedHashmapSlotState.Empty
                        (return
                          (GeneratedHashmapProbe.Absent
                            (if (>= first 0)
                              first
                              cursor)))]
                      [GeneratedHashmapSlotState.Tombstone
                        (begin
                          (if (< first 0)
                            (set! first cursor)
                            unit)
                          (set! cursor (bit-and (+ cursor 1) mask))
                          (set! walked (+ walked 1)))]
                      [GeneratedHashmapSlotState.Occupied
                        (if (if (= (__tl-project-field-name slot "hash") hash)
                          ,probe-key-eq-body
                          false)
                          (return (GeneratedHashmapProbe.Found cursor))
                          (begin
                            (set! cursor (bit-and (+ cursor 1) mask))
                            (set! walked (+ walked 1))))])))
                (if (>= first 0)
                  (GeneratedHashmapProbe.Absent first)
                  (GeneratedHashmapProbe.Full)))))))]
    ;; One index-returning lookup backs get/contains/remove for every family.
    ;; The scalar arm scans through the raw data pointer with the probe order,
    ;; wrap rule and bound `probe` uses; the general arm keeps `probe` so the
    ;; stored-hash pre-compare still guards an expensive `key-eq?`. Absent is
    ;; -1. First-tombstone reuse is an insert-side rule and is never observable
    ;; through a read-only lookup, so dropping the payload enum here changes no
    ;; slot index and no iteration order.
    [find-index-decl : comptime.Expr
      (if scalar-family
        `(define (find-index [map : (& map Map)] [key : ,query-key-type]) : i64
          (let
            [slots : (& map (__tl_dyn-array GeneratedHashmapSlot))
              (& map.slots)]
            [data : (Ptr GeneratedHashmapSlot)
              (unsafe
                (ptr-cast (array-data map.slots) : (Ptr GeneratedHashmapSlot)))]
            [cap : i64 (array_ops.length slots)]
            (if (<= cap 0)
              -1
              (let
                [mask : i64 (- cap 1)]
                [cursor : i64 (bit-and (* key 6364136223846793005) mask)]
                [start : i64 cursor]
                (begin
                  (while true
                    (begin
                      (let
                        [slot : GeneratedHashmapSlot
                          (unsafe
                            (ptr-read (ptr-offset data cursor)))]
                        (match (__tl-project-field-name slot "state")
                          [GeneratedHashmapSlotState.Occupied
                            (if (= (__tl-project-field-name slot "key") key)
                              (return cursor)
                              (set! cursor (bit-and (+ cursor 1) mask)))]
                          [GeneratedHashmapSlotState.Empty (return -1)]
                          [GeneratedHashmapSlotState.Tombstone
                            (set! cursor (bit-and (+ cursor 1) mask))]))
                      (if (= cursor start)
                        (return -1)
                        unit)))
                  -1)))))
        `(define (find-index [map : (& map Map)] [key : ,query-key-type]) : i64
          (match (probe
            (& map.slots)
            (capacity map)
            ,reusable-query-key
            (hash-key ,reusable-query-key))
            [(GeneratedHashmapProbe.Found index) index]
            [_ -1])))]
    ;; Scalar lookup walks the probe itself rather than routing through
    ;; `find-index` and then re-deriving the slot from the returned index.
    ;; `find-index` only ever reports a slot it has already classified Occupied
    ;; with a matching key, so the bounds check `array-ref` repeats and the
    ;; state re-match after it are both provably redundant, and the index round
    ;; trip costs a call besides. The probe order, hash, wrap rule and
    ;; terminating bound below are the ones `find-index` uses, character for
    ;; character, so a key resolves to the same slot and iteration order is
    ;; untouched.
    [scalar-lookup-body : comptime.Expr
      `(let
        [slots : (& map (__tl_dyn-array GeneratedHashmapSlot)) (& map.slots)]
        [data : (Ptr GeneratedHashmapSlot)
          (unsafe
            (ptr-cast (array-data map.slots) : (Ptr GeneratedHashmapSlot)))]
        [cap : i64 (array_ops.length slots)]
        (if (<= cap 0)
          (LookupMissing)
          (let
            [mask : i64 (- cap 1)]
            [cursor : i64 (bit-and (* key 6364136223846793005) mask)]
            [start : i64 cursor]
            (begin
              (while true
                (begin
                  (let
                    [slot : GeneratedHashmapSlot
                      (unsafe
                        (ptr-read (ptr-offset data cursor)))]
                    (match (__tl-project-field-name slot "state")
                      [GeneratedHashmapSlotState.Occupied
                        (if (= (__tl-project-field-name slot "key") key)
                          (return
                            (LookupFound (__tl-project-field-name slot "value")))
                          (set! cursor (bit-and (+ cursor 1) mask)))]
                      [GeneratedHashmapSlotState.Empty (return (LookupMissing))]
                      [GeneratedHashmapSlotState.Tombstone
                        (set! cursor (bit-and (+ cursor 1) mask))]))
                  (if (= cursor start)
                    (return (LookupMissing))
                    unit)))
              (LookupMissing)))))]
    [get-borrowed-body : comptime.Expr
      (if scalar-family
        scalar-lookup-body
        `(let
          [index : i64 (find-index map key)]
          (if (< index 0)
            (LookupMissing)
            (let
              [slot : (& map GeneratedHashmapSlot)
                (& (array-ref map.slots index))]
              (match (clone (__tl-project-field-name slot "state"))
                [GeneratedHashmapSlotState.Occupied
                  (let
                    [value : ,V (__tl-project-field-name slot "value")]
                    (LookupFound ,value-copy))]
                [_ (LookupMissing)])))))]
    ;; `get` and `get-borrowed` take the same argument for a scalar key, so the
    ;; owned entry point is the borrowed one; emitting the probe rather than a
    ;; forwarding call keeps the 31M-per-self-compile owned lookups off a frame
    ;; adjust and a jump that exist only to rename the parameter.
    [get-body : comptime.Expr
      (if scalar-family
        scalar-lookup-body
        `(get-borrowed map ,owned-query-key))]
    [get-value-borrowed-body : comptime.Expr
      `(let
        [index : i64 (find-index map key)]
        (if (< index 0)
          (borrowed-value-missing map)
          (match (clone
            (__tl-project-field-name (array-ref map.slots index) "state"))
            [GeneratedHashmapSlotState.Occupied
              (borrowed-value-found (slot-value-borrowed map index))]
            [_ (borrowed-value-missing map)])))]
    [mut-entry-value-or-body : comptime.Expr
      (if scalar-family
        `(if entry.present
          (let
            [slot : GeneratedHashmapSlot
              (clone (array-ref entry.slots entry.index))]
            (match (clone (__tl-project-field-name slot "state"))
              [GeneratedHashmapSlotState.Occupied
                (__tl-project-field-name slot "value")]
              [_ fallback]))
          fallback)
        `(if entry.present
          (let
            [slot : GeneratedHashmapSlot
              (clone (array-ref entry.slots entry.index))]
            (match (clone (__tl-project-field-name slot "state"))
              [GeneratedHashmapSlotState.Occupied
                (let
                  [value : ,V (clone (__tl-project-field-name slot "value"))]
                  ,value-copy)]
              [_ fallback]))
          fallback))]
    [mut-entry-set-body : comptime.Expr
      `(if entry.present
        (set-occupied-value! entry.slots entry.index value)
        unit)]
    ;; Iteration walks every slot of the table, so the bounds check `array-ref`
    ;; repeats per slot is pure overhead against a cursor the loop condition
    ;; already bounds by the same length. The scalar arm reads through the raw
    ;; data pointer; the visit order, and therefore the iteration order, is
    ;; unchanged.
    [next-occupied-body : comptime.Expr
      (if scalar-family
        `(let
          [slots : (& map (__tl_dyn-array GeneratedHashmapSlot)) (& map.slots)]
          [data : (Ptr GeneratedHashmapSlot)
            (unsafe
              (ptr-cast (array-data map.slots) : (Ptr GeneratedHashmapSlot)))]
          [cap : i64 (array_ops.length slots)]
          [index : i64
            (if (< from 0)
              0
              from)]
          (begin
            (while (< index cap)
              (match (__tl-project-field-name
                (unsafe
                  (ptr-read (ptr-offset data index)))
                "state")
                [GeneratedHashmapSlotState.Occupied (return index)]
                [_ (set! index (+ index 1))]))
            index))
        `(let
          [index : i64
            (if (< from 0)
              0
              from)]
          [cap : i64 (capacity map)]
          [found : bool false]
          (begin
            (while (and (not found) (< index cap))
              (match (clone
                (__tl-project-field-name (array-ref map.slots index) "state"))
                [GeneratedHashmapSlotState.Occupied (set! found true)]
                [_ (set! index (+ index 1))]))
            index)))]
    [entry-at-body : comptime.Expr
      (if scalar-family
        `(if (and (>= index 0) (< index (capacity map)))
          (let
            [data : (Ptr GeneratedHashmapSlot)
              (unsafe
                (ptr-cast (array-data map.slots) : (Ptr GeneratedHashmapSlot)))]
            [slot : GeneratedHashmapSlot
              (unsafe
                (ptr-read (ptr-offset data index)))]
            (match (__tl-project-field-name slot "state")
              [GeneratedHashmapSlotState.Occupied
                (EntrySome
                  (__tl-project-field-name slot "key")
                  (__tl-project-field-name slot "value"))]
              [_ (EntryNone)]))
          (EntryNone))
        `(if (and (>= index 0) (< index (capacity map)))
          (let
            [slot : GeneratedHashmapSlot (clone (array-ref map.slots index))]
            (match (clone (__tl-project-field-name slot "state"))
              [GeneratedHashmapSlotState.Occupied
                (let
                  [key : ,K (clone (__tl-project-field-name slot "key"))]
                  [value : ,V (clone (__tl-project-field-name slot "value"))]
                  (EntrySome ,key-copy ,value-copy))]
              [_ (EntryNone)]))
          (EntryNone)))]
    ;; The scalar family drops the stored hash field; every other family keeps
    ;; it, because their `key-eq?` is expensive enough that the hash pre-compare
    ;; earns its slot word. State leads both structs so their field offsets
    ;; remain exactly those of the former enum layout.
    [slot-payload-decl : comptime.Expr
      (if scalar-family
        `(begin
          (defenum GeneratedHashmapSlotState
            (Empty)
            (Tombstone)
            (Occupied))
          (defstruct GeneratedHashmapSlot
            (state GeneratedHashmapSlotState)
            (key ,K)
            (value ,V)))
        `(begin
          (defenum GeneratedHashmapSlotState
            (Empty)
            (Tombstone)
            (Occupied))
          (defstruct GeneratedHashmapSlot
            (state GeneratedHashmapSlotState)
            (key ,K)
            (value ,V)
            (hash i64))))]
    [publish-occupied-decl : comptime.Expr
      (if scalar-family
        `(define (publish-occupied!
          [slots : (&mut slots (__tl_dyn-array GeneratedHashmapSlot))]
          [index : i64]
          [key : ,K]
          [value : ,V]) : unit
          (let
            [slot : (&mut slots GeneratedHashmapSlot)
              (&mut (array-ref slots index))]
            (begin
              (__tl-project-set-field-name slot "key" key)
              (__tl-project-set-field-name slot "value" value)
              (__tl-project-set-field-name
                slot
                "state"
                (GeneratedHashmapSlotState.Occupied)))))
        `(define (publish-occupied!
          [slots : (&mut slots (__tl_dyn-array GeneratedHashmapSlot))]
          [index : i64]
          [key : ,K]
          [value : ,V]
          [hash : i64]) : unit
          (let
            [slot : (&mut slots GeneratedHashmapSlot)
              (&mut (array-ref slots index))]
            (begin
              (__tl-project-set-field-name slot "key" key)
              (__tl-project-set-field-name slot "value" value)
              (__tl-project-set-field-name slot "hash" hash)
              (__tl-project-set-field-name
                slot
                "state"
                (GeneratedHashmapSlotState.Occupied))))))]
    (if (string.eq value-kind "unsupported")
      `(begin
        (module ,module-name)
        (import stdlib.comptime))
      `(begin
        (module ,module-name)
        (import stdlib.array as array_ops)
        (import stdlib.hash as hash_mod)
        (import stdlib.string as string_mod)
        ,@key-module-imports
        ,slot-payload-decl
        (defenum GeneratedHashmapProbe
          (Found i64)
          (Absent i64)
          (Full))
        (defstruct Map
          (slots (__tl_dyn-array GeneratedHashmapSlot))
          (len i64)
          (growth-limit i64))
        (defenum Lookup
          (LookupMissing)
          (LookupFound ,V))
        (defenum BorrowedValueLookup
          (:lifetimes map)
          (BorrowedValueMissing)
          (BorrowedValueFound (& map ,borrowed-value-type)))
        (defenum RemoveResult
          (RemoveOk)
          (RemoveMissing))
        (defenum EntryOrInsertResult
          (EntryOrInsertFound ,V)
          (EntryOrInsertInserted ,V))
        (defstruct MutEntry
          (:lifetimes map)
          (slots (&mut map (__tl_dyn-array GeneratedHashmapSlot)))
          (index i64)
          (present bool)
          (key ,K)
          (hash i64))
        (defenum Entry
          (EntryNone)
          (EntrySome ,K ,V))
        (define (hash-key [key : ,query-key-type]) : i64
          ,hash-key-body)
        (define (key-eq? [left : ,key-eq-left-type] [right : ,query-key-type]) : bool
          ,key-eq-body)
        ,publish-occupied-decl
        (define (set-occupied-value!
          [slots : (&mut slots (__tl_dyn-array GeneratedHashmapSlot))]
          [index : i64]
          [value : ,V]) : unit
          (let
            [slot : (&mut slots GeneratedHashmapSlot)
              (&mut (array-ref slots index))]
            (begin
              (match (__tl-project-field-name slot "state")
                [GeneratedHashmapSlotState.Occupied
                  (__tl-project-set-field-name slot "value" value)]
                [_ unit])
              unit)))
        (define (mark-occupied-tombstone!
          [slots : (&mut slots (__tl_dyn-array GeneratedHashmapSlot))]
          [index : i64]) : unit
          (let
            [slot : (&mut slots GeneratedHashmapSlot)
              (&mut (array-ref slots index))]
            (__tl-project-set-field-name
              slot
              "state"
              (GeneratedHashmapSlotState.Tombstone))))
        (define (round-capacity [capacity : i64]) : i64
          (if (and (>= capacity 1) (= (bit-and capacity (- capacity 1)) 0))
            capacity
            (let
              [rounded : i64 1]
              (begin
                (while (< rounded capacity)
                  (set! rounded (* rounded 2)))
                rounded))))
        (define (growth-limit-for [capacity : i64]) : i64
          ,growth-limit-body)
        ,probe-decl
        (define (with-capacity [capacity : i64]) : Map
          (let
            [cap : i64
              (round-capacity
                (if (< capacity 1)
                  1
                  capacity))]
            (Map
              (array_ops.make-array GeneratedHashmapSlot cap)
              0
              (growth-limit-for cap))))
        (define (new) : Map
          (with-capacity 4))
        (define (len [map : (& map Map)]) : i64
          map.len)
        (define (capacity [map : (& map Map)]) : i64
          (array_ops.length map.slots))
        (define (capacity-mut [map : (&mut map Map)]) : i64
          (array_ops.length map.slots))
        (define (clear-ref! [map : (&mut map Map)]) : unit
          (let
            [cap : i64 (capacity-mut map)]
            [index : i64 0]
            (begin
              (while (< index cap)
                (begin
                  (__tl-project-set-field-name
                    (array-ref map.slots index)
                    "state"
                    (GeneratedHashmapSlotState.Empty))
                  (set! index (+ index 1))))
              (set! map.len 0)
              (set! map.growth-limit (growth-limit-for cap)))))
        (define (deleted [map : (& map Map)]) : i64
          (- (growth-limit-for (capacity map)) map.growth-limit))
        (define (is-empty? [map : (& map Map)]) : bool
          (<= map.len 0))
        (define (lookup-value-or [lookup : Lookup] [fallback : ,V]) : ,V
          (match lookup
            [(LookupFound value) value]
            [(LookupMissing) fallback]))
        ,find-index-decl
        (define (get-borrowed [map : (& map Map)] [key : ,query-key-type]) : Lookup
          ,get-borrowed-body)
        (define (get [map : (& map Map)] [key : ,K]) : Lookup
          ,get-body)
        (define (get-value-or [map : (& map Map)] [key : ,K] [fallback : ,V]) : ,V
          ,get-value-or-body)
        (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
            map)
          (BorrowedValueMissing))
        (define (borrowed-value-found [value : (& map ,borrowed-value-type)]) : (BorrowedValueLookup
            map)
          (BorrowedValueFound value))
        (define (slot-value-borrowed [map : (& map Map)] [index : i64]) : (&
            map
            ,borrowed-value-type)
          (& (__tl-project-field-name (array-ref map.slots index) "value")))
        (define (get-value-borrowed [map : (& map Map)] [key : ,query-key-type]) : (BorrowedValueLookup
            map)
          ,get-value-borrowed-body)
        (define (borrowed-value-found? [lookup : (BorrowedValueLookup map)]) : bool
          (match lookup
            [(BorrowedValueFound _) true]
            [(BorrowedValueMissing) false]))
        (define (contains-borrowed? [map : (& map Map)] [key : ,query-key-type]) : bool
          (>= (find-index map key) 0))
        (define (contains? [map : (& map Map)] [key : ,K]) : bool
          (contains-borrowed? map ,owned-query-key))
        (define (grow! [map : (&mut map Map)]) : unit
          (let
            [old-capacity : i64 (capacity-mut map)]
            [new-capacity : i64
              (if (< old-capacity 1)
                1
                (* old-capacity 2))]
            [fresh : (__tl_dyn-array GeneratedHashmapSlot)
              (array_ops.make-array GeneratedHashmapSlot new-capacity)]
            [scan : i64 0]
            ;; Read the capacity back off `fresh` and mask with that, under an
            ;; explicit `cap >= 1` guard. `array_ops.length fresh` is
            ;; `new-capacity` by construction, so the arithmetic is unchanged --
            ;; but it gives the optimizer ONE value serving as both the mask base
            ;; and the bound on every `array-ref fresh`, which is what lets it
            ;; prove `hash & (cap - 1)` is in range and drop the probe-loop
            ;; bounds checks. Masking only bounds the index when `cap >= 1`
            ;; (at `cap = 0` the mask is -1 and masking bounds nothing), so the
            ;; guard is what makes the proof available rather than decoration.
            [cap : i64 (array_ops.length fresh)]
            [mask : i64 (- cap 1)]
            (begin
              (if (>= cap 1)
                ,grow-rehash-body
                unit)
              (set! map.slots fresh)
              (set! map.growth-limit (growth-limit-for cap)))))
        (define (needs-grow? [map : (&mut map Map)]) : bool
          (>= map.len map.growth-limit))
        (define (insert-ref! [map : (&mut map Map)] [key : ,K] [value : ,V]) : unit
          ,insert-ref-body)
        (define (insert-or-update-ref!
          [map : (&mut map Map)]
          [key : ,K]
          [value : ,V]) : unit
          (insert-ref! map key value))
        (define (insert-if-absent-ref!
          [map : (&mut map Map)]
          [key : ,K]
          [value : ,V]) : bool
          (if (contains-borrowed? (& map) ,owned-query-key)
            false
            (begin
              (insert-ref! map key value)
              true)))
        (define (remove-borrowed-ref!
          [map : (&mut map Map)]
          [key : ,query-key-type]) : RemoveResult
          (let
            [index : i64 (find-index (& map) key)]
            (if (< index 0)
              (RemoveMissing)
              (begin
                (mark-occupied-tombstone! (&mut map.slots) index)
                (set! map.len (- map.len 1))
                (set! map.growth-limit (- map.growth-limit 1))
                (RemoveOk)))))
        (define (remove-ref! [map : (&mut map Map)] [key : ,K]) : RemoveResult
          (remove-borrowed-ref! map ,owned-query-key))
        (define (remove-ok? [result : RemoveResult]) : bool
          (match result
            [(RemoveOk) true]
            [(RemoveMissing) false]))
        (define (entry-or-insert-ref!
          [map : (&mut map Map)]
          [key : ,K]
          [default-value : ,V]) : EntryOrInsertResult
          (match (get-borrowed (& map) ,owned-query-key)
            [(LookupFound value) (EntryOrInsertFound value)]
            [(LookupMissing)
              (begin
                (insert-ref! map key (clone default-value))
                (EntryOrInsertInserted default-value))]))
        (define (entry-or-insert-inserted? [result : EntryOrInsertResult]) : bool
          (match result
            [(EntryOrInsertInserted _) true]
            [(EntryOrInsertFound _) false]))
        (define (entry-or-insert-value-or
          [result : EntryOrInsertResult]
          [fallback : ,V]) : ,V
          (match result
            [(EntryOrInsertFound value) value]
            [(EntryOrInsertInserted value) value]))
        (define (get-mut-entry-borrowed
          [map : (&mut map Map)]
          [key : ,query-key-type]) : (MutEntry map)
          (let
            [hash : i64 (hash-key ,reusable-query-key)]
            [slots : (&mut map (__tl_dyn-array GeneratedHashmapSlot))
              (&mut map.slots)]
            [result : GeneratedHashmapProbe
              (probe
                (& slots)
                (array_ops.length slots)
                ,reusable-query-key
                hash)]
            (match result
              [(GeneratedHashmapProbe.Found index)
                (MutEntry slots index true ,query-owned-key hash)]
              [(GeneratedHashmapProbe.Absent index)
                (MutEntry slots index false ,query-owned-key hash)]
              [GeneratedHashmapProbe.Full
                (MutEntry slots -1 false ,query-owned-key hash)])))
        (define (get-mut-entry [map : (&mut map Map)] [key : ,K]) : (MutEntry
            map)
          (get-mut-entry-borrowed map ,owned-query-key))
        (define (mut-entry-present? [entry : (& entry (MutEntry map))]) : bool
          entry.present)
        (define (mut-entry-value-or [entry : (MutEntry map)] [fallback : ,V]) : ,V
          ,mut-entry-value-or-body)
        (define (mut-entry-set! [entry : (MutEntry map)] [value : ,V]) : unit
          ,mut-entry-set-body)
        (define (next-occupied [map : (& map Map)] [from : i64]) : i64
          ,next-occupied-body)
        (define (entry-at [map : (& map Map)] [index : i64]) : Entry
          ,entry-at-body)
        (define (entry-value-or [entry : Entry] [fallback : ,V]) : ,V
          (match entry
            [(EntrySome _ value) value]
            [(EntryNone) fallback]))
        (defmacro (insert! [place : Expr] [key : Expr] [value : Expr]) : unit
          (expr-mut-call2 (expr-var ,insert-helper-name) place key value))
        (defmacro (insert-or-update! [place : Expr] [key : Expr] [value : Expr]) : unit
          (expr-mut-call2
            (expr-var ,insert-or-update-helper-name)
            place
            key
            value))
        (defmacro (insert-if-absent! [place : Expr] [key : Expr] [value : Expr]) : bool
          (expr-mut-call2
            (expr-var ,insert-if-absent-helper-name)
            place
            key
            value))
        (defmacro (remove! [place : Expr] [key : Expr]) : RemoveResult
          (expr-mut-call1 (expr-var ,remove-helper-name) place key))
        (defmacro (remove-borrowed! [place : Expr] [key : Expr]) : RemoveResult
          (expr-mut-call1 (expr-var ,remove-borrowed-helper-name) place key))
        (defmacro (entry-or-insert!
          [place : Expr]
          [key : Expr]
          [default-value : Expr]) : EntryOrInsertResult
          (expr-mut-call2
            (expr-var ,entry-or-insert-helper-name)
            place
            key
            default-value))))))

;; Aggregate fixture types exercise generated struct/enum values and nested
;; nominal keys without retaining any concrete map implementation.
(cfg
  test
  (defstruct HashPayload
    (score i64)
    (weight i64)))

(cfg
  test
  (defenum HashState
    (HashReady i64)
    (HashFailed)
    (HashPaused i64)))

(cfg
  test
  (defstruct HashPoint
    (x i64)
    (enabled bool)
    (label String)
    (code char)))

(cfg
  test
  (defenum HashTag
    (HashTagNone)
    (HashTagNumber i64)
    (HashTagOtherNumber i64)
    (HashTagText bool String char)))

(cfg
  test
  (defstruct HashNestedKey
    (point HashPoint)
    (tag HashTag)))

(cfg test (import stdlib.test))
(cfg test (import (hashmap String i64) as hashmap_string_i64))
(cfg test (import (hashmap String String) as hashmap_string_string))
(cfg test (import (hashmap i64 i64) as hashmap_i64_i64))
(cfg test (import (hashmap i64 String) as hashmap_i64_string))
(cfg test (import (hashmap String HashPayload) as hashmap_string_payload))
(cfg test (import (hashmap i64 HashState) as hashmap_i64_state))
(cfg test (import (hashmap HashNestedKey i64) as hashmap_nested_i64))

;: Compare an owned test string without borrowing a temporary call result.
(cfg
  test
  (define (hashmap-test-assert-string
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (test.assert-string-eq (& actual) (& expected) message)))

;: Test helper for aggregate values.
(cfg
  test
  (define (hash-payload-score [value : HashPayload]) : i64
    (+ value.score value.weight)))

;: Test helper for aggregate enum values.
(cfg
  test
  (define (hash-state-score [value : HashState]) : i64
    (match value
      [(HashReady score) score]
      [(HashFailed) -1]
      [(HashPaused score) (- 0 score)])))

;: Stable nested-key fixture.
(cfg
  test
  (define (hash-key-alpha) : HashNestedKey
    (HashNestedKey (HashPoint 1 true "alpha" 'A') (HashTagNumber 7))))

;: Equal-but-distinct nested-key fixture.
(cfg
  test
  (define (hash-key-alpha-copy) : HashNestedKey
    (HashNestedKey (HashPoint 1 true "alpha" 'A') (HashTagNumber 7))))

;: Same payload with a distinct enum tag.
(cfg
  test
  (define (hash-key-beta) : HashNestedKey
    (HashNestedKey (HashPoint 1 true "alpha" 'A') (HashTagOtherNumber 7))))

;: Missing nested-key fixture.
(cfg
  test
  (define (hash-key-missing) : HashNestedKey
    (HashNestedKey (HashPoint 99 false "missing" 'M') (HashTagNumber 7))))

(cfg
  test
  (test
    hashmap-generated-string-and-i64-families
    (let
      [sm : hashmap_string_i64.Map (hashmap_string_i64.with-capacity 1)]
      [im : hashmap_i64_i64.Map (hashmap_i64_i64.with-capacity 1)]
      (begin
        (hashmap_string_i64.insert! sm "alpha" 10)
        (hashmap_string_i64.insert! sm "beta" 20)
        (hashmap_i64_i64.insert! im 1 100)
        (hashmap_i64_i64.insert! im 2 200)
        (test.assert-i64-eq
          (hashmap_string_i64.lookup-value-or
            (hashmap_string_i64.get (& sm) "alpha")
            -1)
          10
          "generated string-key lookup")
        (test.assert-i64-eq
          (hashmap_i64_i64.get-value-or (& im) 2 -1)
          200
          "generated i64-key lookup")
        (test.assert-true
          (hashmap_string_i64.remove-ok? (hashmap_string_i64.remove! sm "beta"))
          "generated string-key remove")
        (test.assert-true
          (hashmap_i64_i64.insert-if-absent! im 3 300)
          "generated i64 insert-if-absent")
        (let
          [old-capacity : i64 (hashmap_i64_i64.capacity (& im))]
          (begin
            (hashmap_i64_i64.remove! im 1)
            (hashmap_i64_i64.clear-ref! (&mut im))
            (test.assert-true
              (hashmap_i64_i64.is-empty? (& im))
              "generated i64 clear empties map")
            (test.assert-i64-eq
              (hashmap_i64_i64.capacity (& im))
              old-capacity
              "generated i64 clear retains capacity")
            (test.assert-i64-eq
              (hashmap_i64_i64.deleted (& im))
              0
              "generated i64 clear removes tombstones")
            (hashmap_i64_i64.insert! im 4 400)
            (test.assert-i64-eq
              (hashmap_i64_i64.get-value-or (& im) 4 -1)
              400
              "generated i64 insert after clear")))))))

(cfg
  test
  (test
    hashmap-generated-string-values-and-mut-entry
    (let
      [key : String "alpha"]
      [sm : hashmap_string_string.Map (hashmap_string_string.new)]
      [im : hashmap_i64_string.Map (hashmap_i64_string.new)]
      (begin
        (hashmap_string_string.insert! sm "alpha" "red")
        (hashmap_string_string.insert! sm "alpha" "blue")
        (hashmap_i64_string.insert! im 7 "seven")
        (let
          [entry : (hashmap_string_string.MutEntry sm)
            (hashmap_string_string.get-mut-entry-borrowed (&mut sm) (& key))]
          (begin
            (test.assert-true
              (hashmap_string_string.mut-entry-present? entry)
              "generated mut entry present")
            (hashmap_string_string.mut-entry-set! entry "green")))
        (hashmap-test-assert-string
          (hashmap_string_string.lookup-value-or
            (hashmap_string_string.get (& sm) "alpha")
            "missing")
          "green"
          "generated string value update")
        (test.assert-true
          (hashmap_i64_string.borrowed-value-found?
            (hashmap_i64_string.get-value-borrowed (& im) 7))
          "generated borrowed string value")))))

(cfg
  test
  (test
    hashmap-generated-aggregate-families
    (let
      [alpha : HashNestedKey (hash-key-alpha)]
      [equal-alpha : HashNestedKey (hash-key-alpha-copy)]
      [beta : HashNestedKey (hash-key-beta)]
      [nested : hashmap_nested_i64.Map (hashmap_nested_i64.new)]
      [payloads : hashmap_string_payload.Map (hashmap_string_payload.new)]
      [states : hashmap_i64_state.Map (hashmap_i64_state.new)]
      (begin
        (hashmap_nested_i64.insert! nested alpha 11)
        (hashmap_nested_i64.insert! nested beta 22)
        (hashmap_string_payload.insert! payloads "p" (HashPayload 3 4))
        (hashmap_i64_state.insert! states 1 (HashPaused 7))
        (hashmap_string_payload.insert! payloads "p" (HashPayload 5 6))
        (hashmap_i64_state.insert! states 1 (HashReady 9))
        (let
          [entry : (hashmap_string_payload.MutEntry payloads)
            (hashmap_string_payload.get-mut-entry (&mut payloads) "p")]
          (hashmap_string_payload.mut-entry-set! entry (HashPayload 7 8)))
        (let
          [entry : (hashmap_i64_state.MutEntry states)
            (hashmap_i64_state.get-mut-entry (&mut states) 1)]
          (hashmap_i64_state.mut-entry-set! entry (HashPaused 4)))
        (test.assert-i64-eq
          (hashmap_nested_i64.lookup-value-or
            (hashmap_nested_i64.get (& nested) equal-alpha)
            -1)
          11
          "generated aggregate key equality")
        (test.assert-i64-eq
          (hash-payload-score
            (hashmap_string_payload.lookup-value-or
              (hashmap_string_payload.get (& payloads) "p")
              (HashPayload 0 0)))
          15
          "generated aggregate struct update and mut entry")
        (test.assert-i64-eq
          (hash-state-score
            (hashmap_i64_state.lookup-value-or
              (hashmap_i64_state.get (& states) 1)
              (HashFailed)))
          -4
          "generated aggregate enum update and mut entry")))))

(cfg
  test
  (test
    hashmap-generated-insert-update-tombstone-grow-parity
    (let
      [scalar : hashmap_i64_i64.Map (hashmap_i64_i64.with-capacity 4)]
      [general : hashmap_string_i64.Map (hashmap_string_i64.with-capacity 4)]
      [inactive-scalar : hashmap_i64_i64.Map (hashmap_i64_i64.with-capacity 1)]
      [inactive-general : hashmap_string_i64.Map
        (hashmap_string_i64.with-capacity 1)]
      (begin
        (let
          [entry : (hashmap_i64_i64.MutEntry inactive-scalar)
            (hashmap_i64_i64.MutEntry (&mut inactive-scalar.slots) 0 true 99 0)]
          (hashmap_i64_i64.mut-entry-set! entry 77))
        (test.assert-i64-eq
          (hashmap_i64_i64.len (& inactive-scalar))
          0
          "present bit cannot make an empty slot writable")
        (hashmap_string_i64.insert! inactive-general "stale" 1)
        (test.assert-true
          (hashmap_string_i64.remove-ok?
            (hashmap_string_i64.remove! inactive-general "stale"))
          "stale-entry fixture creates a tombstone")
        (let
          [entry : (hashmap_string_i64.MutEntry inactive-general)
            (hashmap_string_i64.MutEntry
              (&mut inactive-general.slots)
              0
              true
              "stale"
              0)]
          (hashmap_string_i64.mut-entry-set! entry 77))
        (test.assert-i64-eq
          (hashmap_string_i64.lookup-value-or
            (hashmap_string_i64.get (& inactive-general) "stale")
            -1)
          -1
          "present bit cannot make a tombstone payload writable")
        (hashmap_i64_i64.insert! scalar 1 10)
        (hashmap_string_i64.insert! general "one" 10)
        (hashmap_i64_i64.insert! scalar 1 11)
        (hashmap_string_i64.insert! general "one" 11)
        (let
          [entry : (hashmap_i64_i64.MutEntry scalar)
            (hashmap_i64_i64.get-mut-entry (&mut scalar) 1)]
          (hashmap_i64_i64.mut-entry-set! entry 13))
        (let
          [entry : (hashmap_string_i64.MutEntry general)
            (hashmap_string_i64.get-mut-entry (&mut general) "one")]
          (hashmap_string_i64.mut-entry-set! entry 13))
        (test.assert-i64-eq
          (hashmap_i64_i64.get-value-or (& scalar) 1 -1)
          13
          "scalar insert and mut entry update in place")
        (test.assert-i64-eq
          (hashmap_string_i64.lookup-value-or
            (hashmap_string_i64.get (& general) "one")
            -1)
          13
          "general insert and mut entry update in place")
        (test.assert-true
          (hashmap_i64_i64.remove-ok? (hashmap_i64_i64.remove! scalar 1))
          "scalar remove creates tombstone")
        (test.assert-true
          (hashmap_string_i64.remove-ok?
            (hashmap_string_i64.remove! general "one"))
          "general remove creates tombstone")
        (test.assert-i64-eq
          (hashmap_i64_i64.deleted (& scalar))
          1
          "scalar tombstone count after remove")
        (test.assert-i64-eq
          (hashmap_string_i64.deleted (& general))
          1
          "general tombstone count after remove")
        (hashmap_i64_i64.insert! scalar 1 12)
        (hashmap_string_i64.insert! general "one" 12)
        (test.assert-i64-eq
          (hashmap_i64_i64.deleted (& scalar))
          0
          "scalar insert reuses one tombstone")
        (test.assert-i64-eq
          (hashmap_string_i64.deleted (& general))
          0
          "general insert reuses one tombstone")
        (hashmap_i64_i64.insert! scalar 2 20)
        (hashmap_i64_i64.insert! scalar 3 30)
        (hashmap_i64_i64.insert! scalar 4 40)
        (hashmap_string_i64.insert! general "two" 20)
        (hashmap_string_i64.insert! general "three" 30)
        (hashmap_string_i64.insert! general "four" 40)
        (test.assert-i64-eq
          (hashmap_i64_i64.capacity (& scalar))
          8
          "scalar growth runs exactly once before probing")
        (test.assert-i64-eq
          (hashmap_string_i64.capacity (& general))
          8
          "general growth runs exactly once before probing")
        (test.assert-i64-eq
          (hashmap_i64_i64.len (& scalar))
          4
          "scalar insert parity after growth")
        (test.assert-i64-eq
          (hashmap_string_i64.len (& general))
          4
          "general insert parity after growth")
        (test.assert-i64-eq
          (hashmap_i64_i64.get-value-or (& scalar) 1 -1)
          12
          "scalar tombstone value survives growth")
        (test.assert-i64-eq
          (hashmap_string_i64.lookup-value-or
            (hashmap_string_i64.get (& general) "one")
            -1)
          12
          "general tombstone value survives growth")))))