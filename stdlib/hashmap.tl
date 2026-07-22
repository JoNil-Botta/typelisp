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
    [owned-query-key : comptime.Expr
      (if (string.eq key-kind "string")
        `(& key)
        `key)]
    [query-owned-key : comptime.Expr
      (if (string.eq key-kind "string")
        `(string_mod.copy key)
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
    [entry-key-copy : comptime.Expr
      (match key-kind
        ["string" `(string_mod.copy (& (struct-get entry key)))]
        ["i64" `(struct-get entry key)]
        [_ `(clone (struct-get entry key))])]
    [hash-key-body : comptime.Expr
      (match key-kind
        ["string" `(hash_mod.string-key key)]
        ["i64" `(* key 6364136223846793005)]
        [_ `(key_hash.hash key)])]
    [key-eq-body : comptime.Expr
      (match key-kind
        ["string" `(hash_mod.key-string-eq? (& left) right)]
        ["i64" `(= left right)]
        [_ `(key_eq.eq left right)])]
    ;; Keep the generated i64 -> i64 hot path as lean as the former concrete
    ;; family. Its raw reads are bounded by the positive power-of-two capacity;
    ;; growth finishes before a pointer is captured, and no scan reallocates.
    [scalar-family : bool
      (if (string.eq key-kind "i64")
        (string.eq value-kind "i64")
        false)]
    [get-value-or-body : comptime.Expr
      (if scalar-family
        `(let
          [slots : (& map (Array GeneratedHashmapSlot))
            (& (struct-get map slots))]
          [data : (Ptr GeneratedHashmapSlot)
            (unsafe
              (ptr-cast
                (array-data (struct-get map slots))
                : (Ptr GeneratedHashmapSlot)))]
          [cap : i64 (array_ops.length slots)]
          (if (<= cap 0)
            fallback
            (let
              [hash : i64 (* key 6364136223846793005)]
              [cursor : i64 (bit-and hash (- cap 1))]
              [walked : i64 0]
              [mask : i64 (- cap 1)]
              (begin
                (while (< walked cap)
                  (match (unsafe
                    (ptr-read (ptr-offset data cursor)))
                    [GeneratedHashmapSlot.Empty (return fallback)]
                    [GeneratedHashmapSlot.Tombstone
                      (begin
                        (set! cursor (bit-and (+ cursor 1) mask))
                        (set! walked (+ walked 1)))]
                    [(GeneratedHashmapSlot.Occupied existing value _)
                      (if (= existing key)
                        (return value)
                        (begin
                          (set! cursor (bit-and (+ cursor 1) mask))
                          (set! walked (+ walked 1))))]))
                fallback))))
        `(lookup-value-or (get map key) fallback))]
    [update-slot-body : comptime.Expr
      (if (string.eq key-kind "generated")
        `(match (array-ref (struct-get map slots) index)
          [(GeneratedHashmapSlot.Occupied existing _ existing-hash)
            (array-set!
              (struct-get map slots)
              index
              (GeneratedHashmapSlot.Occupied
                (clone existing)
                value
                existing-hash))]
          [_ unit])
        `(array-set!
          (struct-get map slots)
          index
          (GeneratedHashmapSlot.Occupied key value hash)))]
    [insert-ref-body : comptime.Expr
      (if scalar-family
        `(let
          [capacity-before : i64 (array_ops.length (struct-get map slots))]
          [used-before : i64 (+ (struct-get map len) (struct-get map deleted))]
          (begin
            ;; Preserve the pre-probe len + deleted growth condition: below
            ;; the threshold at least one Empty slot remains in the table.
            ;; Perform this exactly once before deriving data or probing, so a
            ;; grow cannot invalidate the raw pointer used by the loop.
            (if (if (<= capacity-before 0)
              true
              (>= (* used-before 4) (* capacity-before 3)))
              (grow! map)
              unit)
            (let
              [data : (MutPtr GeneratedHashmapSlot)
                (unsafe
                  (ptr-cast
                    (array-data (struct-get map slots))
                    : (MutPtr GeneratedHashmapSlot)))]
              ;; with-capacity and grow! preserve a positive power-of-two
              ;; capacity, making the masked initial cursor in bounds.
              [cap : i64 (array_ops.length (struct-get map slots))]
              [hash : i64 (* key 6364136223846793005)]
              [cursor : i64 (bit-and hash (- cap 1))]
              [start : i64 cursor]
              [first : i64 -1]
              (begin
                ;; The preserved growth predicate guarantees an Empty slot,
                ;; so this loop terminates without a redundant walked bound.
                (while true
                  (begin
                    (match (unsafe
                      (ptr-read (ptr-offset data cursor)))
                      [GeneratedHashmapSlot.Empty
                        (if (< first 0)
                          (let
                            ;; scalar-family fixes Occupied to the tag followed
                            ;; by its i64 key, value, and hash payload words.
                            [slot : (MutPtr i64)
                              (unsafe
                                (ptr-cast
                                  (ptr-offset data cursor)
                                  : (MutPtr i64)))]
                            (begin
                              (unsafe
                                (ptr-write! slot 2))
                              (unsafe
                                (ptr-write! (ptr-offset slot 1) key))
                              (unsafe
                                (ptr-write! (ptr-offset slot 2) value))
                              (unsafe
                                (ptr-write! (ptr-offset slot 3) hash))
                              (set!
                                (struct-get map len)
                                (+ (struct-get map len) 1))
                              (return unit)))
                          (let
                            [slot : (MutPtr i64)
                              (unsafe
                                (ptr-cast
                                  (ptr-offset data first)
                                  : (MutPtr i64)))]
                            (begin
                              (unsafe
                                (ptr-write! slot 2))
                              (unsafe
                                (ptr-write! (ptr-offset slot 1) key))
                              (unsafe
                                (ptr-write! (ptr-offset slot 2) value))
                              (unsafe
                                (ptr-write! (ptr-offset slot 3) hash))
                              (set!
                                (struct-get map len)
                                (+ (struct-get map len) 1))
                              (set!
                                (struct-get map deleted)
                                (- (struct-get map deleted) 1))
                              (return unit))))]
                      [GeneratedHashmapSlot.Tombstone
                        (let
                          [next : i64 (+ cursor 1)]
                          (begin
                            (if (< first 0)
                              (set! first cursor)
                              unit)
                            (set!
                              cursor
                              (if (>= next cap)
                                0
                                next))
                            unit))]
                      [(GeneratedHashmapSlot.Occupied existing _ _)
                        (if (= existing key)
                          (let
                            [slot : (MutPtr i64)
                              (unsafe
                                (ptr-cast
                                  (ptr-offset data cursor)
                                  : (MutPtr i64)))]
                            (begin
                              (unsafe
                                (ptr-write! slot 2))
                              (unsafe
                                (ptr-write! (ptr-offset slot 1) key))
                              (unsafe
                                (ptr-write! (ptr-offset slot 2) value))
                              (unsafe
                                (ptr-write! (ptr-offset slot 3) hash))
                              (return unit)))
                          (let
                            [next : i64 (+ cursor 1)]
                            (begin
                              (set!
                                cursor
                                (if (>= next cap)
                                  0
                                  next))
                              unit)))])
                    ;; Map values may be shallow-copied while sharing their
                    ;; slot descriptor. Preserve the prior Full-table behavior
                    ;; for a stale copied len without a per-probe counter.
                    (if (= cursor start)
                      (if (< first 0)
                        (return unit)
                        (let
                          [slot : (MutPtr i64)
                            (unsafe
                              (ptr-cast (ptr-offset data first) : (MutPtr i64)))]
                          (begin
                            (unsafe
                              (ptr-write! slot 2))
                            (unsafe
                              (ptr-write! (ptr-offset slot 1) key))
                            (unsafe
                              (ptr-write! (ptr-offset slot 2) value))
                            (unsafe
                              (ptr-write! (ptr-offset slot 3) hash))
                            (set!
                              (struct-get map len)
                              (+ (struct-get map len) 1))
                            (set!
                              (struct-get map deleted)
                              (- (struct-get map deleted) 1))
                            (return unit))))
                      unit)))
                unit))))
        `(begin
          (if (needs-grow? map)
            (grow! map)
            unit)
          (let
            [hash : i64 (hash-key ,owned-query-key)]
            (match (probe
              (& (struct-get map slots))
              (capacity-mut map)
              ,owned-query-key
              hash)
              [(GeneratedHashmapProbe.Found index) ,update-slot-body]
              [(GeneratedHashmapProbe.Absent index)
                (let
                  [was-tombstone : bool
                    (match (array-ref (struct-get map slots) index)
                      [GeneratedHashmapSlot.Tombstone true]
                      [_ false])]
                  (begin
                    (array-set!
                      (struct-get map slots)
                      index
                      (GeneratedHashmapSlot.Occupied
                        ,insert-key-copy
                        value
                        hash))
                    (set! (struct-get map len) (+ (struct-get map len) 1))
                    (if was-tombstone
                      (set!
                        (struct-get map deleted)
                        (- (struct-get map deleted) 1))
                      unit)))]
              [GeneratedHashmapProbe.Full
                (begin
                  (grow! map)
                  (insert-ref! map key value))]))))]
    [remove-ref-body : comptime.Expr
      (if scalar-family
        `(let
          [data : (Ptr GeneratedHashmapSlot)
            (unsafe
              (ptr-cast
                (array-data (struct-get map slots))
                : (Ptr GeneratedHashmapSlot)))]
          [slots : (&mut map (Array GeneratedHashmapSlot))
            (&mut (struct-get map slots))]
          [cap : i64 (array_ops.length slots)]
          (if (<= cap 0)
            (RemoveMissing)
            (let
              [hash : i64 (* key 6364136223846793005)]
              [cursor : i64 (bit-and hash (- cap 1))]
              [walked : i64 0]
              [mask : i64 (- cap 1)]
              (begin
                (while (< walked cap)
                  (match (unsafe
                    (ptr-read (ptr-offset data cursor)))
                    [GeneratedHashmapSlot.Empty (return (RemoveMissing))]
                    [GeneratedHashmapSlot.Tombstone
                      (begin
                        (set! cursor (bit-and (+ cursor 1) mask))
                        (set! walked (+ walked 1)))]
                    [(GeneratedHashmapSlot.Occupied existing _ _)
                      (if (= existing key)
                        (begin
                          (array-set!
                            slots
                            cursor
                            (GeneratedHashmapSlot.Tombstone))
                          (set! (struct-get map len) (- (struct-get map len) 1))
                          (set!
                            (struct-get map deleted)
                            (+ (struct-get map deleted) 1))
                          (return (RemoveOk)))
                        (begin
                          (set! cursor (bit-and (+ cursor 1) mask))
                          (set! walked (+ walked 1))))]))
                (RemoveMissing)))))
        `(remove-borrowed-ref! map ,owned-query-key))]
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
        (defenum GeneratedHashmapSlot
          (Empty)
          (Tombstone)
          (Occupied ,K ,V i64))
        (defenum GeneratedHashmapProbe
          (Found i64)
          (Absent i64)
          (Full))
        (defstruct Map
          (slots (Array GeneratedHashmapSlot))
          (len i64)
          (deleted i64))
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
          (slots (&mut map (Array GeneratedHashmapSlot)))
          (index i64)
          (present bool)
          (key ,K)
          (hash i64))
        (defenum Entry
          (EntryNone)
          (EntrySome ,K ,V))
        (define (hash-key [key : ,query-key-type]) : i64
          ,hash-key-body)
        (define (key-eq? [left : ,K] [right : ,query-key-type]) : bool
          ,key-eq-body)
        (define (round-capacity [capacity : i64]) : i64
          (let
            [rounded : i64 1]
            (begin
              (while (< rounded capacity)
                (set! rounded (* rounded 2)))
              rounded)))
        (define (probe
          [slots : (& slots (Array GeneratedHashmapSlot))]
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
                  (match (array-ref slots cursor)
                    [GeneratedHashmapSlot.Empty
                      (return
                        (GeneratedHashmapProbe.Absent
                          (if (>= first 0)
                            first
                            cursor)))]
                    [GeneratedHashmapSlot.Tombstone
                      (begin
                        (if (< first 0)
                          (set! first cursor)
                          unit)
                        (set! cursor (bit-and (+ cursor 1) mask))
                        (set! walked (+ walked 1)))]
                    [(GeneratedHashmapSlot.Occupied existing _ existing-hash)
                      (if (if (= existing-hash hash)
                        (key-eq? existing key)
                        false)
                        (return (GeneratedHashmapProbe.Found cursor))
                        (begin
                          (set! cursor (bit-and (+ cursor 1) mask))
                          (set! walked (+ walked 1))))]))
                (if (>= first 0)
                  (GeneratedHashmapProbe.Absent first)
                  (GeneratedHashmapProbe.Full))))))
        (define (with-capacity [capacity : i64]) : Map
          (let
            [cap : i64
              (round-capacity
                (if (< capacity 1)
                  1
                  capacity))]
            (Map (array_ops.make-array GeneratedHashmapSlot cap) 0 0)))
        (define (new) : Map
          (with-capacity 4))
        (define (len [map : (& map Map)]) : i64
          (struct-get map len))
        (define (capacity [map : (& map Map)]) : i64
          (array_ops.length (struct-get map slots)))
        (define (capacity-mut [map : (&mut map Map)]) : i64
          (array_ops.length (struct-get map slots)))
        (define (deleted [map : (& map Map)]) : i64
          (struct-get map deleted))
        (define (is-empty? [map : (& map Map)]) : bool
          (<= (struct-get map len) 0))
        (define (lookup-value-or [lookup : Lookup] [fallback : ,V]) : ,V
          (match lookup
            [(LookupFound value) value]
            [(LookupMissing) fallback]))
        (define (get-borrowed [map : (& map Map)] [key : ,query-key-type]) : Lookup
          (let
            [cap : i64 (capacity map)]
            (match (probe (& (struct-get map slots)) cap key (hash-key key))
              [(GeneratedHashmapProbe.Found index)
                (match (array-ref (struct-get map slots) index)
                  [(GeneratedHashmapSlot.Occupied _ value _)
                    (LookupFound ,value-copy)]
                  [_ (LookupMissing)])]
              [_ (LookupMissing)])))
        (define (get [map : (& map Map)] [key : ,K]) : Lookup
          (get-borrowed map ,owned-query-key))
        (define (get-value-or [map : (& map Map)] [key : ,K] [fallback : ,V]) : ,V
          ,get-value-or-body)
        (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
            map)
          (BorrowedValueMissing))
        (define (borrowed-value-found [value : (& map ,borrowed-value-type)]) : (BorrowedValueLookup
            map)
          (BorrowedValueFound value))
        (define (get-value-borrowed [map : (& map Map)] [key : ,query-key-type]) : (BorrowedValueLookup
            map)
          (let
            [cap : i64 (capacity map)]
            (match (probe (& (struct-get map slots)) cap key (hash-key key))
              [(GeneratedHashmapProbe.Found index)
                (match (& (array-ref (struct-get map slots) index))
                  [(GeneratedHashmapSlot.Occupied _ value _)
                    (borrowed-value-found value)]
                  [_ (borrowed-value-missing map)])]
              [_ (borrowed-value-missing map)])))
        (define (borrowed-value-found? [lookup : (BorrowedValueLookup map)]) : bool
          (match lookup
            [(BorrowedValueFound _) true]
            [(BorrowedValueMissing) false]))
        (define (contains-borrowed? [map : (& map Map)] [key : ,query-key-type]) : bool
          (match (probe
            (& (struct-get map slots))
            (capacity map)
            key
            (hash-key key))
            [(GeneratedHashmapProbe.Found _) true]
            [_ false]))
        (define (contains? [map : (& map Map)] [key : ,K]) : bool
          (contains-borrowed? map ,owned-query-key))
        (define (grow! [map : (&mut map Map)]) : unit
          (let
            [old-capacity : i64 (capacity-mut map)]
            [new-capacity : i64
              (if (< old-capacity 1)
                1
                (* old-capacity 2))]
            [fresh : (Array GeneratedHashmapSlot)
              (array_ops.make-array GeneratedHashmapSlot new-capacity)]
            [scan : i64 0]
            [mask : i64 (- new-capacity 1)]
            (begin
              (while (< scan old-capacity)
                (begin
                  (match (array-ref (struct-get map slots) scan)
                    [(GeneratedHashmapSlot.Occupied key value hash)
                      (let
                        [index : i64 (bit-and hash mask)]
                        (begin
                          (while (match (array-ref fresh index)
                            [GeneratedHashmapSlot.Empty false]
                            [_ true])
                            (set! index (bit-and (+ index 1) mask)))
                          (array-set!
                            fresh
                            index
                            (GeneratedHashmapSlot.Occupied
                              ,key-copy
                              ,value-copy
                              hash))))]
                    [_ unit])
                  (set! scan (+ scan 1))))
              (set! (struct-get map slots) fresh)
              (set! (struct-get map deleted) 0))))
        (define (needs-grow? [map : (&mut map Map)]) : bool
          (>
            (* (+ (+ (struct-get map len) (struct-get map deleted)) 1) 4)
            (* (capacity-mut map) 3)))
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
          (match (probe
            (& (struct-get map slots))
            (capacity-mut map)
            key
            (hash-key key))
            [(GeneratedHashmapProbe.Found index)
              (begin
                (array-set!
                  (struct-get map slots)
                  index
                  (GeneratedHashmapSlot.Tombstone))
                (set! (struct-get map len) (- (struct-get map len) 1))
                (set! (struct-get map deleted) (+ (struct-get map deleted) 1))
                (RemoveOk))]
            [_ (RemoveMissing)]))
        (define (remove-ref! [map : (&mut map Map)] [key : ,K]) : RemoveResult
          ,remove-ref-body)
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
                (insert-ref! map key default-value)
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
            [hash : i64 (hash-key key)]
            [slots : (&mut map (Array GeneratedHashmapSlot))
              (&mut (struct-get map slots))]
            [result : GeneratedHashmapProbe
              (probe (& slots) (array_ops.length slots) key hash)]
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
        (define (mut-entry-present? [entry : (MutEntry map)]) : bool
          (struct-get entry present))
        (define (mut-entry-value-or [entry : (MutEntry map)] [fallback : ,V]) : ,V
          (if (struct-get entry present)
            (match (array-ref (struct-get entry slots) (struct-get entry index))
              [(GeneratedHashmapSlot.Occupied _ value _) ,value-copy]
              [_ fallback])
            fallback))
        (define (mut-entry-set! [entry : (MutEntry map)] [value : ,V]) : unit
          (if (struct-get entry present)
            (array-set!
              (struct-get entry slots)
              (struct-get entry index)
              (GeneratedHashmapSlot.Occupied
                ,entry-key-copy
                value
                (struct-get entry hash)))
            unit))
        (define (next-occupied [map : (& map Map)] [from : i64]) : i64
          (let
            [index : i64
              (if (< from 0)
                0
                from)]
            [cap : i64 (capacity map)]
            [found : bool false]
            (begin
              (while (and (not found) (< index cap))
                (match (array-ref (struct-get map slots) index)
                  [(GeneratedHashmapSlot.Occupied _ _ _) (set! found true)]
                  [_ (set! index (+ index 1))]))
              index)))
        (define (entry-at [map : (& map Map)] [index : i64]) : Entry
          (if (and (>= index 0) (< index (capacity map)))
            (match (array-ref (struct-get map slots) index)
              [(GeneratedHashmapSlot.Occupied key value _)
                (EntrySome ,key-copy ,value-copy)]
              [_ (EntryNone)])
            (EntryNone)))
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
    (+ (struct-get value score) (struct-get value weight))))

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
          "generated i64 insert-if-absent")))))

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
          7
          "generated aggregate struct value")
        (test.assert-i64-eq
          (hash-state-score
            (hashmap_i64_state.lookup-value-or
              (hashmap_i64_state.get (& states) 1)
              (HashFailed)))
          -7
          "generated aggregate enum value")))))

(cfg
  test
  (test
    hashmap-generated-insert-update-tombstone-grow-parity
    (let
      [scalar : hashmap_i64_i64.Map (hashmap_i64_i64.with-capacity 4)]
      [general : hashmap_string_i64.Map (hashmap_string_i64.with-capacity 4)]
      (begin
        (hashmap_i64_i64.insert! scalar 1 10)
        (hashmap_string_i64.insert! general "one" 10)
        (hashmap_i64_i64.insert! scalar 1 11)
        (hashmap_string_i64.insert! general "one" 11)
        (test.assert-i64-eq
          (hashmap_i64_i64.get-value-or (& scalar) 1 -1)
          11
          "scalar insert updates in place")
        (test.assert-i64-eq
          (hashmap_string_i64.lookup-value-or
            (hashmap_string_i64.get (& general) "one")
            -1)
          11
          "general insert updates in place")
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