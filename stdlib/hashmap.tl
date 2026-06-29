;# Generated concrete hashmap family (collections v1, #817/#825).
;#
;# Open-addressed, linear-probing maps generated from explicit declaration
;# requests. `StringI64Map` remains the checked-in compatibility
;# `HashMap<String,i64>` template chosen in #824/#825; this module requests
;# generated `StringStringMap`, `I64I64Map`, and `I64StringMap` families with the same
;# representation and API shape. String-key maps use the same string hash and
;# equality rules as `hash.string-key`; i64-key maps normalize the scalar key
;# directly and compare with `=`.
;#
;# Public constructors and resizing round capacities up to a positive power of
;# two, so bucket selection is a mask instead of a modulo in the hot path.
;# Probing wraps with a branch. Each occupied slot caches its key hash so probing
;# compares the cheap `i64` hash before the full key comparison. The probe visits
;# at most `capacity` slots, so a full table terminates instead of looping
;# forever.
;#
;# Usage: `(import stdlib.hashmap)`
;#
;# Generic source syntax such as `HashMap<K,V>` is intentionally not exposed
;# yet; TypeLisp uses stdlib module macros and checked-in concrete families
;# instead of source-level generics or traits. These maps are the stdlib choice
;# for ordinary program data keyed by `String` or `i64`; compiler-internal
;# symbol tables may keep using specialized maps when their value domain or
;# lifecycle is tighter than a public stdlib collection.
;#
;# The checked-in base families cover `String` and `i64` keys plus the aggregate
;# fixture families used by inline tests. String-key maps support borrowed key
;# lookup/contains/remove wrappers and borrowed value lookup results tied to the
;# map lifetime. i64-key maps use scalar keys directly and still expose borrowed
;# value lookup. Aggregate fixture keys derive deterministic hash/equality from
;# declaration-order struct fields or enum variant tag plus declaration-order
;# payloads for supported members (`i64`, `bool`, `char`, `String`, and nested
;# supported nominal aggregates).
;#
;# ```typelisp
;# (import stdlib.hashmap)
;# (define (main) : i64
;#   (let
;#     [m : hashmap.StringI64Map
;#       (hashmap.string-i64-map-put
;#         (hashmap.string-i64-map-with-capacity 4)
;#         "k"
;#         42)]
;#     (hashmap.string-i64-map-len m)))
;# ```
(module stdlib.hashmap)

(import stdlib.array)
(import stdlib.hash as hash_mod)

;; lint-allow: unused-import
(import stdlib.string)

;: Stable descriptor identity for generated `String`-key hashmap families.
(define (hashmap-string-key-descriptor-key) : String
  "stdlib/hashmap/string-key-v1")

;: Stable descriptor identity for generated `i64`-key hashmap families.
(define (hashmap-i64-key-descriptor-key) : String
  "stdlib/hashmap/i64-key-v1")

;: Stable descriptor identity for generated nominal aggregate-key hashmap families.
(define (hashmap-aggregate-key-descriptor-key) : String
  "stdlib/hashmap/aggregate-key-v1")

;: Emit the module-shaped hashmap surface for supported key/value pairs.
;:
;: This first stdlib macro slice exposes `String -> i64` as `Map` plus
;: module-relative helpers. It delegates to the checked-in `StringI64Map`
;: implementation while presenting the new `&`/`&mut` collection API shape.
(defmacro (hashmap [K : type] [V : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append
          "stdlib.hashmap.generated."
          (string-append (type-key K) (string-append "." (type-key V)))))]
    (match (type-key K)
      ["String"
        (match (type-key V)
          ["i64"
            `(begin
              (module ,module-name)
              (import stdlib.array as array_ops)
              (import stdlib.hashmap as base)
              (defstruct Map
                (inner base.StringI64Map))
              (defenum Lookup
                (LookupMissing)
                (LookupFound i64))
              (defenum BorrowedValueLookup
                (:lifetimes map)
                (BorrowedValueMissing)
                (BorrowedValueFound (& map i64)))
              (defenum RemoveResult
                (RemoveOk)
                (RemoveMissing))
              (defenum EntryOrInsertResult
                (EntryOrInsertFound i64)
                (EntryOrInsertInserted i64))
              (defstruct MutEntry
                (:lifetimes map)
                (inner (base.StringI64MapMutEntry map)))
              (defenum Entry
                (EntryNone)
                (EntrySome String i64))
              (define (with-capacity [capacity : i64]) : Map
                (Map (base.string-i64-map-with-capacity capacity)))
              (define (new) : Map
                (with-capacity 4))
              (define (len [map : (& map Map)]) : i64
                (struct-get (struct-get map inner) len))
              (define (capacity [map : (& map Map)]) : i64
                (array_ops.array-length
                  (struct-get (struct-get map inner) slots)))
              (define (deleted [map : (& map Map)]) : i64
                (struct-get (struct-get map inner) deleted))
              (define (inner-mut [map : (&mut map Map)]) : (&mut
                  map
                  base.StringI64Map)
                (&mut (struct-get map inner)))
              (define (is-empty? [map : (& map Map)]) : bool
                (<= (len map) 0))
              (define (lookup-from-base [lookup : base.StringI64MapLookup]) : Lookup
                (match lookup
                  [(base.StringI64MapFound value) (LookupFound value)]
                  [(base.StringI64MapMissing) (LookupMissing)]))
              (define (get-borrowed [map : (& map Map)] [key : (& key str)]) : Lookup
                (lookup-from-base
                  (base.string-i64-map-get-borrowed-ref
                    (& (struct-get map inner))
                    key)))
              (define (get [map : (& map Map)] [key : String]) : Lookup
                (get-borrowed map (& key)))
              (define (lookup-value-or [lookup : Lookup] [fallback : i64]) : i64
                (match lookup
                  [(LookupFound value) value]
                  [(LookupMissing) fallback]))
              (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueMissing))
              (define (borrowed-value-found [value : (& map i64)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueFound value))
              (define (get-value-borrowed
                [map : (& map Map)]
                [key : (& key str)]) : (BorrowedValueLookup map)
                (match (base.string-i64-map-get-value-borrowed
                  (& (struct-get map inner))
                  key)
                  [(base.StringI64MapBorrowedValueFound value)
                    (borrowed-value-found value)]
                  [(base.StringI64MapBorrowedValueMissing)
                    (borrowed-value-missing map)]))
              (define (borrowed-value-found?
                [lookup : (BorrowedValueLookup map)]) : bool
                (match lookup
                  [(BorrowedValueFound _) true]
                  [(BorrowedValueMissing) false]))
              (define (contains-borrowed?
                [map : (& map Map)]
                [key : (& key str)]) : bool
                (base.string-i64-map-contains-borrowed-ref?
                  (& (struct-get map inner))
                  key))
              (define (contains? [map : (& map Map)] [key : String]) : bool
                (contains-borrowed? map (& key)))
              (define (insert
                [map : (&mut map Map)]
                [key : String]
                [value : i64]) : unit
                (base.string-i64-map-put! (inner-mut map) key value))
              (define (insert-or-update
                [map : (&mut map Map)]
                [key : String]
                [value : i64]) : unit
                (insert map key value))
              (define (remove-borrowed
                [map : (&mut map Map)]
                [key : (& key str)]) : RemoveResult
                (if (base.string-i64-map-remove-borrowed! (inner-mut map) key)
                  (RemoveOk)
                  (RemoveMissing)))
              (define (remove [map : (&mut map Map)] [key : String]) : RemoveResult
                (remove-borrowed map (& key)))
              (define (remove-ok? [result : RemoveResult]) : bool
                (match result
                  [(RemoveOk) true]
                  [(RemoveMissing) false]))
              (define (entry-or-insert
                [map : (&mut map Map)]
                [key : String]
                [default-value : i64]) : EntryOrInsertResult
                (let
                  [present : bool
                    (base.string-i64-map-contains-borrowed-mut?
                      (inner-mut map)
                      (& key))]
                  (if present
                    (EntryOrInsertFound
                      (lookup-value-or
                        (lookup-from-base
                          (base.string-i64-map-get-borrowed-mut
                            (inner-mut map)
                            (& key)))
                        default-value))
                    (begin
                      (insert map key default-value)
                      (EntryOrInsertInserted default-value)))))
              (define (entry-or-insert-inserted? [result : EntryOrInsertResult]) : bool
                (match result
                  [(EntryOrInsertInserted _) true]
                  [(EntryOrInsertFound _) false]))
              (define (entry-or-insert-value-or
                [result : EntryOrInsertResult]
                [fallback : i64]) : i64
                (match result
                  [(EntryOrInsertFound value) value]
                  [(EntryOrInsertInserted value) value]))
              (define (get-mut-entry-borrowed
                [map : (&mut map Map)]
                [key : (& key str)]) : (MutEntry map)
                (MutEntry
                  (base.string-i64-map-get-mut-entry-borrowed!
                    (inner-mut map)
                    key)))
              (define (mut-entry-present? [entry : (MutEntry map)]) : bool
                (base.string-i64-map-mut-entry-present?
                  (struct-get entry inner)))
              (define (mut-entry-value-or
                [entry : (MutEntry map)]
                [fallback : i64]) : i64
                (base.string-i64-map-mut-entry-value-or
                  (struct-get entry inner)
                  fallback))
              (define (mut-entry-set! [entry : (MutEntry map)] [value : i64]) : unit
                (base.string-i64-map-mut-entry-set!
                  (struct-get entry inner)
                  value))
              (define (next-occupied [map : (& map Map)] [from : i64]) : i64
                (base.string-i64-map-next-occupied-ref
                  (& (struct-get map inner))
                  from))
              (define (entry-at [map : (& map Map)] [index : i64]) : Entry
                (match (base.string-i64-map-entry-at-ref
                  (& (struct-get map inner))
                  index)
                  [(base.StringI64MapEntrySome key value) (EntrySome key value)]
                  [(base.StringI64MapEntryNone) (EntryNone)]))
              (define (entry-value-or [entry : Entry] [fallback : i64]) : i64
                (match entry
                  [(EntrySome _ value) value]
                  [(EntryNone) fallback])))]
          ["String"
            `(begin
              (module ,module-name)
              (import stdlib.array as array_ops)
              (import stdlib.hashmap as base)
              (import stdlib.string)
              (defstruct Map
                (inner base.StringStringMap))
              (defenum Lookup
                (LookupMissing)
                (LookupFound String))
              (defenum BorrowedValueLookup
                (:lifetimes map)
                (BorrowedValueMissing)
                (BorrowedValueFound (& map str)))
              (defenum RemoveResult
                (RemoveOk)
                (RemoveMissing))
              (defenum EntryOrInsertResult
                (EntryOrInsertFound String)
                (EntryOrInsertInserted String))
              (defstruct MutEntry
                (:lifetimes map)
                (inner (base.StringStringMapMutEntryRef map)))
              (defenum Entry
                (EntryNone)
                (EntrySome String String))
              (define (with-capacity [capacity : i64]) : Map
                (Map (base.string-string-map-with-capacity capacity)))
              (define (new) : Map
                (with-capacity 4))
              (define (len [map : (& map Map)]) : i64
                (struct-get (struct-get map inner) len))
              (define (capacity [map : (& map Map)]) : i64
                (array_ops.array-length
                  (struct-get (struct-get map inner) slots)))
              (define (deleted [map : (& map Map)]) : i64
                (struct-get (struct-get map inner) deleted))
              (define (inner-mut [map : (&mut map Map)]) : (&mut
                  map
                  base.StringStringMap)
                (&mut (struct-get map inner)))
              (define (is-empty? [map : (& map Map)]) : bool
                (<= (len map) 0))
              (define (lookup-from-base [lookup : base.StringStringMapLookup]) : Lookup
                (match lookup
                  [(base.StringStringMapFound value) (LookupFound value)]
                  [(base.StringStringMapMissing) (LookupMissing)]))
              (define (get-borrowed [map : (& map Map)] [key : (& key str)]) : Lookup
                (lookup-from-base
                  (base.string-string-map-get-borrowed-ref
                    (& (struct-get map inner))
                    key)))
              (define (get [map : (& map Map)] [key : String]) : Lookup
                (get-borrowed map (& key)))
              (define (lookup-value-or [lookup : Lookup] [fallback : String]) : String
                (match lookup
                  [(LookupFound value) value]
                  [(LookupMissing) fallback]))
              (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueMissing))
              (define (borrowed-value-found [value : (& map str)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueFound value))
              (define (get-value-borrowed
                [map : (& map Map)]
                [key : (& key str)]) : (BorrowedValueLookup map)
                (match (base.string-string-map-get-value-borrowed
                  (& (struct-get map inner))
                  key)
                  [(base.StringStringMapBorrowedValueFound value)
                    (borrowed-value-found value)]
                  [(base.StringStringMapBorrowedValueMissing)
                    (borrowed-value-missing map)]))
              (define (borrowed-value-found?
                [lookup : (BorrowedValueLookup map)]) : bool
                (match lookup
                  [(BorrowedValueFound _) true]
                  [(BorrowedValueMissing) false]))
              (define (contains-borrowed?
                [map : (& map Map)]
                [key : (& key str)]) : bool
                (match (get-borrowed map key)
                  [(LookupFound _) true]
                  [(LookupMissing) false]))
              (define (contains? [map : (& map Map)] [key : String]) : bool
                (contains-borrowed? map (& key)))
              (define (insert
                [map : (&mut map Map)]
                [key : String]
                [value : String]) : unit
                (base.string-string-map-put! (inner-mut map) key value))
              (define (insert-or-update
                [map : (&mut map Map)]
                [key : String]
                [value : String]) : unit
                (insert map key value))
              (define (remove-borrowed
                [map : (&mut map Map)]
                [key : (& key str)]) : RemoveResult
                (if (base.string-string-map-remove-borrowed!
                  (inner-mut map)
                  key)
                  (RemoveOk)
                  (RemoveMissing)))
              (define (remove [map : (&mut map Map)] [key : String]) : RemoveResult
                (remove-borrowed map (& key)))
              (define (remove-ok? [result : RemoveResult]) : bool
                (match result
                  [(RemoveOk) true]
                  [(RemoveMissing) false]))
              (define (entry-or-insert
                [map : (&mut map Map)]
                [key : String]
                [default-value : String]) : EntryOrInsertResult
                (match (base.string-string-map-get-borrowed-ref
                  (& (struct-get map inner))
                  (& key))
                  [(base.StringStringMapFound value) (EntryOrInsertFound value)]
                  [(base.StringStringMapMissing)
                    (begin
                      (insert map key default-value)
                      (EntryOrInsertInserted default-value))]))
              (define (entry-or-insert-inserted? [result : EntryOrInsertResult]) : bool
                (match result
                  [(EntryOrInsertInserted _) true]
                  [(EntryOrInsertFound _) false]))
              (define (entry-or-insert-value-or
                [result : EntryOrInsertResult]
                [fallback : String]) : String
                (match result
                  [(EntryOrInsertFound value) value]
                  [(EntryOrInsertInserted value) value]))
              (define (get-mut-entry-borrowed
                [map : (&mut map Map)]
                [key : (& key str)]) : (MutEntry map)
                (MutEntry
                  (base.string-string-map-get-mut-entry-borrowed!
                    (inner-mut map)
                    key)))
              (define (mut-entry-present? [entry : (MutEntry map)]) : bool
                (base.string-string-map-mut-entry-ref-present?
                  (struct-get entry inner)))
              (define (mut-entry-value-or
                [entry : (MutEntry map)]
                [fallback : String]) : String
                (base.string-string-map-mut-entry-ref-value-or
                  (struct-get entry inner)
                  fallback))
              (define (mut-entry-set! [entry : (MutEntry map)] [value : String]) : unit
                (base.string-string-map-mut-entry-ref-set!
                  (struct-get entry inner)
                  value))
              (define (next-occupied [map : (& map Map)] [from : i64]) : i64
                (base.string-string-map-next-occupied-ref
                  (& (struct-get map inner))
                  from))
              (define (entry-at [map : (& map Map)] [index : i64]) : Entry
                (match (base.string-string-map-entry-at-ref
                  (& (struct-get map inner))
                  index)
                  [(base.StringStringMapEntrySome key value)
                    (EntrySome key value)]
                  [(base.StringStringMapEntryNone) (EntryNone)]))
              (define (entry-value-or [entry : Entry] [fallback : String]) : String
                (match entry
                  [(EntrySome _ value) value]
                  [(EntryNone) fallback])))]
          ["struct_stdlib.hashmap/HashPayload"
            `(begin
              (module ,module-name)
              (import stdlib.hashmap as base)
              (defstruct Map
                (inner base.StringHashPayloadMap))
              (defenum Lookup
                (LookupMissing)
                (LookupFound ,V))
              (defenum BorrowedValueLookup
                (:lifetimes map)
                (BorrowedValueMissing)
                (BorrowedValueFound (& map ,V)))
              (defenum RemoveResult
                (RemoveOk)
                (RemoveMissing))
              (defenum EntryOrInsertResult
                (EntryOrInsertFound ,V)
                (EntryOrInsertInserted ,V))
              (defenum Entry
                (EntryNone)
                (EntrySome String ,V))
              (define (with-capacity [capacity : i64]) : Map
                (Map (base.string-hash-payload-map-with-capacity capacity)))
              (define (new) : Map
                (with-capacity 4))
              (define (len [map : Map]) : i64
                (base.string-hash-payload-map-len (struct-get map inner)))
              (define (capacity [map : Map]) : i64
                (base.string-hash-payload-map-capacity (struct-get map inner)))
              (define (deleted [map : Map]) : i64
                (base.string-hash-payload-map-deleted (struct-get map inner)))
              (define (inner-mut [map : (&mut map Map)]) : (&mut
                  map
                  base.StringHashPayloadMap)
                (&mut (struct-get map inner)))
              (define (is-empty? [map : Map]) : bool
                (<= (len map) 0))
              (define (lookup-from-base
                [lookup : base.StringHashPayloadMapLookup]) : Lookup
                (match lookup
                  [(base.StringHashPayloadMapFound value) (LookupFound value)]
                  [(base.StringHashPayloadMapMissing) (LookupMissing)]))
              (define (get-borrowed [map : Map] [key : (& key str)]) : Lookup
                (lookup-from-base
                  (base.string-hash-payload-map-get-borrowed
                    (struct-get map inner)
                    key)))
              (define (get [map : Map] [key : String]) : Lookup
                (get-borrowed map (& key)))
              (define (lookup-value-or [lookup : Lookup] [fallback : ,V]) : ,V
                (match lookup
                  [(LookupFound value) value]
                  [(LookupMissing) fallback]))
              (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueMissing))
              (define (borrowed-value-found [value : (& map ,V)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueFound value))
              (define (get-value-borrowed
                [map : (& map Map)]
                [key : (& key str)]) : (BorrowedValueLookup map)
                (match (base.string-hash-payload-map-get-value-borrowed
                  (& (struct-get map inner))
                  key)
                  [(base.StringHashPayloadMapBorrowedValueFound value)
                    (borrowed-value-found value)]
                  [(base.StringHashPayloadMapBorrowedValueMissing)
                    (borrowed-value-missing map)]))
              (define (borrowed-value-found?
                [lookup : (BorrowedValueLookup map)]) : bool
                (match lookup
                  [(BorrowedValueFound _) true]
                  [(BorrowedValueMissing) false]))
              (define (contains-borrowed? [map : Map] [key : (& key str)]) : bool
                (base.string-hash-payload-map-contains-borrowed?
                  (struct-get map inner)
                  key))
              (define (contains? [map : Map] [key : String]) : bool
                (contains-borrowed? map (& key)))
              (define (insert
                [map : (&mut map Map)]
                [key : String]
                [value : ,V]) : unit
                (base.string-hash-payload-map-put! (inner-mut map) key value))
              (define (insert-or-update
                [map : (&mut map Map)]
                [key : String]
                [value : ,V]) : unit
                (insert map key value))
              (define (remove-borrowed
                [map : (&mut map Map)]
                [key : (& key str)]) : RemoveResult
                (if (base.string-hash-payload-map-remove-borrowed!
                  (inner-mut map)
                  key)
                  (RemoveOk)
                  (RemoveMissing)))
              (define (remove [map : (&mut map Map)] [key : String]) : RemoveResult
                (remove-borrowed map (& key)))
              (define (remove-ok? [result : RemoveResult]) : bool
                (match result
                  [(RemoveOk) true]
                  [(RemoveMissing) false]))
              (define (entry-or-insert
                [map : (&mut map Map)]
                [key : String]
                [default-value : ,V]) : EntryOrInsertResult
                (match (base.string-hash-payload-map-get-borrowed-ref
                  (& (struct-get map inner))
                  (& key))
                  [(base.StringHashPayloadMapFound value)
                    (EntryOrInsertFound value)]
                  [(base.StringHashPayloadMapMissing)
                    (begin
                      (insert map key default-value)
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
              (define (next-occupied [map : Map] [from : i64]) : i64
                (base.string-hash-payload-map-next-occupied
                  (struct-get map inner)
                  from))
              (define (entry-at [map : Map] [index : i64]) : Entry
                (match (base.string-hash-payload-map-entry-at
                  (struct-get map inner)
                  index)
                  [(base.StringHashPayloadMapEntrySome key value)
                    (EntrySome key value)]
                  [(base.StringHashPayloadMapEntryNone) (EntryNone)]))
              (define (entry-value-or [entry : Entry] [fallback : ,V]) : ,V
                (match entry
                  [(EntrySome _ value) value]
                  [(EntryNone) fallback])))]
          [_
            `(begin
              (module ,module-name))])]
      ["i64"
        (match (type-key V)
          ["i64"
            `(begin
              (module ,module-name)
              (import stdlib.array as array_ops)
              (import stdlib.hashmap as base)
              (defstruct Map
                (inner base.I64I64Map))
              (defenum Lookup
                (LookupMissing)
                (LookupFound i64))
              (defenum BorrowedValueLookup
                (:lifetimes map)
                (BorrowedValueMissing)
                (BorrowedValueFound (& map i64)))
              (defenum RemoveResult
                (RemoveOk)
                (RemoveMissing))
              (defenum EntryOrInsertResult
                (EntryOrInsertFound i64)
                (EntryOrInsertInserted i64))
              (defstruct MutEntry
                (:lifetimes map)
                (inner (base.I64I64MapMutEntryRef map)))
              (defenum Entry
                (EntryNone)
                (EntrySome i64 i64))
              (define (with-capacity [capacity : i64]) : Map
                (Map (base.i64-i64-map-with-capacity capacity)))
              (define (new) : Map
                (with-capacity 4))
              (define (len [map : (& map Map)]) : i64
                (struct-get (struct-get map inner) len))
              (define (capacity [map : (& map Map)]) : i64
                (array_ops.array-length
                  (struct-get (struct-get map inner) slots)))
              (define (deleted [map : (& map Map)]) : i64
                (struct-get (struct-get map inner) deleted))
              (define (inner-mut [map : (&mut map Map)]) : (&mut
                  map
                  base.I64I64Map)
                (&mut (struct-get map inner)))
              (define (is-empty? [map : (& map Map)]) : bool
                (<= (len map) 0))
              (define (lookup-from-base [lookup : base.I64I64MapLookup]) : Lookup
                (match lookup
                  [(base.I64I64MapFound value) (LookupFound value)]
                  [(base.I64I64MapMissing) (LookupMissing)]))
              (define (get [map : (& map Map)] [key : i64]) : Lookup
                (lookup-from-base
                  (base.i64-i64-map-get-ref (& (struct-get map inner)) key)))
              (define (lookup-value-or [lookup : Lookup] [fallback : i64]) : i64
                (match lookup
                  [(LookupFound value) value]
                  [(LookupMissing) fallback]))
              (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueMissing))
              (define (borrowed-value-found [value : (& map i64)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueFound value))
              (define (get-value-borrowed [map : (& map Map)] [key : i64]) : (BorrowedValueLookup
                  map)
                (match (base.i64-i64-map-get-value-borrowed
                  (& (struct-get map inner))
                  key)
                  [(base.I64I64MapBorrowedValueFound value)
                    (borrowed-value-found value)]
                  [(base.I64I64MapBorrowedValueMissing)
                    (borrowed-value-missing map)]))
              (define (borrowed-value-found?
                [lookup : (BorrowedValueLookup map)]) : bool
                (match lookup
                  [(BorrowedValueFound _) true]
                  [(BorrowedValueMissing) false]))
              (define (contains? [map : (& map Map)] [key : i64]) : bool
                (match (get map key)
                  [(LookupFound _) true]
                  [(LookupMissing) false]))
              (define (insert [map : (&mut map Map)] [key : i64] [value : i64]) : unit
                (base.i64-i64-map-put! (inner-mut map) key value))
              (define (insert-or-update
                [map : (&mut map Map)]
                [key : i64]
                [value : i64]) : unit
                (insert map key value))
              (define (remove [map : (&mut map Map)] [key : i64]) : RemoveResult
                (if (base.i64-i64-map-remove! (inner-mut map) key)
                  (RemoveOk)
                  (RemoveMissing)))
              (define (remove-ok? [result : RemoveResult]) : bool
                (match result
                  [(RemoveOk) true]
                  [(RemoveMissing) false]))
              (define (entry-or-insert
                [map : (&mut map Map)]
                [key : i64]
                [default-value : i64]) : EntryOrInsertResult
                (match (base.i64-i64-map-get-ref (& (struct-get map inner)) key)
                  [(base.I64I64MapFound value) (EntryOrInsertFound value)]
                  [(base.I64I64MapMissing)
                    (begin
                      (insert map key default-value)
                      (EntryOrInsertInserted default-value))]))
              (define (entry-or-insert-inserted? [result : EntryOrInsertResult]) : bool
                (match result
                  [(EntryOrInsertInserted _) true]
                  [(EntryOrInsertFound _) false]))
              (define (entry-or-insert-value-or
                [result : EntryOrInsertResult]
                [fallback : i64]) : i64
                (match result
                  [(EntryOrInsertFound value) value]
                  [(EntryOrInsertInserted value) value]))
              (define (get-mut-entry [map : (&mut map Map)] [key : i64]) : (MutEntry
                  map)
                (MutEntry (base.i64-i64-map-get-mut-entry! (inner-mut map) key)))
              (define (mut-entry-present? [entry : (MutEntry map)]) : bool
                (base.i64-i64-map-mut-entry-ref-present?
                  (struct-get entry inner)))
              (define (mut-entry-value-or
                [entry : (MutEntry map)]
                [fallback : i64]) : i64
                (base.i64-i64-map-mut-entry-ref-value-or
                  (struct-get entry inner)
                  fallback))
              (define (mut-entry-set! [entry : (MutEntry map)] [value : i64]) : unit
                (base.i64-i64-map-mut-entry-ref-set!
                  (struct-get entry inner)
                  value))
              (define (next-occupied [map : (& map Map)] [from : i64]) : i64
                (base.i64-i64-map-next-occupied-ref
                  (& (struct-get map inner))
                  from))
              (define (entry-at [map : (& map Map)] [index : i64]) : Entry
                (match (base.i64-i64-map-entry-at-ref
                  (& (struct-get map inner))
                  index)
                  [(base.I64I64MapEntrySome key value) (EntrySome key value)]
                  [(base.I64I64MapEntryNone) (EntryNone)]))
              (define (entry-value-or [entry : Entry] [fallback : i64]) : i64
                (match entry
                  [(EntrySome _ value) value]
                  [(EntryNone) fallback])))]
          ["String"
            `(begin
              (module ,module-name)
              (import stdlib.array as array_ops)
              (import stdlib.hashmap as base)
              (import stdlib.string)
              (defstruct Map
                (inner base.I64StringMap))
              (defenum Lookup
                (LookupMissing)
                (LookupFound String))
              (defenum BorrowedValueLookup
                (:lifetimes map)
                (BorrowedValueMissing)
                (BorrowedValueFound (& map str)))
              (defenum RemoveResult
                (RemoveOk)
                (RemoveMissing))
              (defenum EntryOrInsertResult
                (EntryOrInsertFound String)
                (EntryOrInsertInserted String))
              (defstruct MutEntry
                (:lifetimes map)
                (inner (base.I64StringMapMutEntryRef map)))
              (defenum Entry
                (EntryNone)
                (EntrySome i64 String))
              (define (with-capacity [capacity : i64]) : Map
                (Map (base.i64-string-map-with-capacity capacity)))
              (define (new) : Map
                (with-capacity 4))
              (define (len [map : (& map Map)]) : i64
                (struct-get (struct-get map inner) len))
              (define (capacity [map : (& map Map)]) : i64
                (array_ops.array-length
                  (struct-get (struct-get map inner) slots)))
              (define (deleted [map : (& map Map)]) : i64
                (struct-get (struct-get map inner) deleted))
              (define (inner-mut [map : (&mut map Map)]) : (&mut
                  map
                  base.I64StringMap)
                (&mut (struct-get map inner)))
              (define (is-empty? [map : (& map Map)]) : bool
                (<= (len map) 0))
              (define (lookup-from-base [lookup : base.I64StringMapLookup]) : Lookup
                (match lookup
                  [(base.I64StringMapFound value) (LookupFound value)]
                  [(base.I64StringMapMissing) (LookupMissing)]))
              (define (get [map : (& map Map)] [key : i64]) : Lookup
                (lookup-from-base
                  (base.i64-string-map-get-ref (& (struct-get map inner)) key)))
              (define (lookup-value-or [lookup : Lookup] [fallback : String]) : String
                (match lookup
                  [(LookupFound value) value]
                  [(LookupMissing) fallback]))
              (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueMissing))
              (define (borrowed-value-found [value : (& map str)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueFound value))
              (define (get-value-borrowed [map : (& map Map)] [key : i64]) : (BorrowedValueLookup
                  map)
                (match (base.i64-string-map-get-value-borrowed
                  (& (struct-get map inner))
                  key)
                  [(base.I64StringMapBorrowedValueFound value)
                    (borrowed-value-found value)]
                  [(base.I64StringMapBorrowedValueMissing)
                    (borrowed-value-missing map)]))
              (define (borrowed-value-found?
                [lookup : (BorrowedValueLookup map)]) : bool
                (match lookup
                  [(BorrowedValueFound _) true]
                  [(BorrowedValueMissing) false]))
              (define (contains? [map : (& map Map)] [key : i64]) : bool
                (match (get map key)
                  [(LookupFound _) true]
                  [(LookupMissing) false]))
              (define (insert
                [map : (&mut map Map)]
                [key : i64]
                [value : String]) : unit
                (base.i64-string-map-put! (inner-mut map) key value))
              (define (insert-or-update
                [map : (&mut map Map)]
                [key : i64]
                [value : String]) : unit
                (insert map key value))
              (define (remove [map : (&mut map Map)] [key : i64]) : RemoveResult
                (if (base.i64-string-map-remove! (inner-mut map) key)
                  (RemoveOk)
                  (RemoveMissing)))
              (define (remove-ok? [result : RemoveResult]) : bool
                (match result
                  [(RemoveOk) true]
                  [(RemoveMissing) false]))
              (define (entry-or-insert
                [map : (&mut map Map)]
                [key : i64]
                [default-value : String]) : EntryOrInsertResult
                (match (base.i64-string-map-get-ref
                  (& (struct-get map inner))
                  key)
                  [(base.I64StringMapFound value) (EntryOrInsertFound value)]
                  [(base.I64StringMapMissing)
                    (begin
                      (insert map key default-value)
                      (EntryOrInsertInserted default-value))]))
              (define (entry-or-insert-inserted? [result : EntryOrInsertResult]) : bool
                (match result
                  [(EntryOrInsertInserted _) true]
                  [(EntryOrInsertFound _) false]))
              (define (entry-or-insert-value-or
                [result : EntryOrInsertResult]
                [fallback : String]) : String
                (match result
                  [(EntryOrInsertFound value) value]
                  [(EntryOrInsertInserted value) value]))
              (define (get-mut-entry [map : (&mut map Map)] [key : i64]) : (MutEntry
                  map)
                (MutEntry
                  (base.i64-string-map-get-mut-entry! (inner-mut map) key)))
              (define (mut-entry-present? [entry : (MutEntry map)]) : bool
                (base.i64-string-map-mut-entry-ref-present?
                  (struct-get entry inner)))
              (define (mut-entry-value-or
                [entry : (MutEntry map)]
                [fallback : String]) : String
                (base.i64-string-map-mut-entry-ref-value-or
                  (struct-get entry inner)
                  fallback))
              (define (mut-entry-set! [entry : (MutEntry map)] [value : String]) : unit
                (base.i64-string-map-mut-entry-ref-set!
                  (struct-get entry inner)
                  value))
              (define (next-occupied [map : (& map Map)] [from : i64]) : i64
                (base.i64-string-map-next-occupied-ref
                  (& (struct-get map inner))
                  from))
              (define (entry-at [map : (& map Map)] [index : i64]) : Entry
                (match (base.i64-string-map-entry-at-ref
                  (& (struct-get map inner))
                  index)
                  [(base.I64StringMapEntrySome key value) (EntrySome key value)]
                  [(base.I64StringMapEntryNone) (EntryNone)]))
              (define (entry-value-or [entry : Entry] [fallback : String]) : String
                (match entry
                  [(EntrySome _ value) value]
                  [(EntryNone) fallback])))]
          ["enum_stdlib.hashmap/HashState"
            `(begin
              (module ,module-name)
              (import stdlib.hashmap as base)
              (defstruct Map
                (inner base.I64HashStateMap))
              (defenum Lookup
                (LookupMissing)
                (LookupFound ,V))
              (defenum BorrowedValueLookup
                (:lifetimes map)
                (BorrowedValueMissing)
                (BorrowedValueFound (& map ,V)))
              (defenum RemoveResult
                (RemoveOk)
                (RemoveMissing))
              (defenum EntryOrInsertResult
                (EntryOrInsertFound ,V)
                (EntryOrInsertInserted ,V))
              (defenum Entry
                (EntryNone)
                (EntrySome i64 ,V))
              (define (with-capacity [capacity : i64]) : Map
                (Map (base.i64-hash-state-map-with-capacity capacity)))
              (define (new) : Map
                (with-capacity 4))
              (define (len [map : Map]) : i64
                (base.i64-hash-state-map-len (struct-get map inner)))
              (define (capacity [map : Map]) : i64
                (base.i64-hash-state-map-capacity (struct-get map inner)))
              (define (deleted [map : Map]) : i64
                (base.i64-hash-state-map-deleted (struct-get map inner)))
              (define (inner-mut [map : (&mut map Map)]) : (&mut
                  map
                  base.I64HashStateMap)
                (&mut (struct-get map inner)))
              (define (is-empty? [map : Map]) : bool
                (<= (len map) 0))
              (define (lookup-from-base [lookup : base.I64HashStateMapLookup]) : Lookup
                (match lookup
                  [(base.I64HashStateMapFound value) (LookupFound value)]
                  [(base.I64HashStateMapMissing) (LookupMissing)]))
              (define (get [map : Map] [key : i64]) : Lookup
                (lookup-from-base
                  (base.i64-hash-state-map-get (struct-get map inner) key)))
              (define (lookup-value-or [lookup : Lookup] [fallback : ,V]) : ,V
                (match lookup
                  [(LookupFound value) value]
                  [(LookupMissing) fallback]))
              (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueMissing))
              (define (borrowed-value-found [value : (& map ,V)]) : (BorrowedValueLookup
                  map)
                (BorrowedValueFound value))
              (define (get-value-borrowed [map : (& map Map)] [key : i64]) : (BorrowedValueLookup
                  map)
                (match (base.i64-hash-state-map-get-value-borrowed
                  (& (struct-get map inner))
                  key)
                  [(base.I64HashStateMapBorrowedValueFound value)
                    (borrowed-value-found value)]
                  [(base.I64HashStateMapBorrowedValueMissing)
                    (borrowed-value-missing map)]))
              (define (borrowed-value-found?
                [lookup : (BorrowedValueLookup map)]) : bool
                (match lookup
                  [(BorrowedValueFound _) true]
                  [(BorrowedValueMissing) false]))
              (define (contains? [map : Map] [key : i64]) : bool
                (match (get map key)
                  [(LookupFound _) true]
                  [(LookupMissing) false]))
              (define (insert [map : (&mut map Map)] [key : i64] [value : ,V]) : unit
                (base.i64-hash-state-map-put! (inner-mut map) key value))
              (define (insert-or-update
                [map : (&mut map Map)]
                [key : i64]
                [value : ,V]) : unit
                (insert map key value))
              (define (remove [map : (&mut map Map)] [key : i64]) : RemoveResult
                (if (base.i64-hash-state-map-remove! (inner-mut map) key)
                  (RemoveOk)
                  (RemoveMissing)))
              (define (remove-ok? [result : RemoveResult]) : bool
                (match result
                  [(RemoveOk) true]
                  [(RemoveMissing) false]))
              (define (entry-or-insert
                [map : (&mut map Map)]
                [key : i64]
                [default-value : ,V]) : EntryOrInsertResult
                (match (base.i64-hash-state-map-get-ref
                  (& (struct-get map inner))
                  key)
                  [(base.I64HashStateMapFound value) (EntryOrInsertFound value)]
                  [(base.I64HashStateMapMissing)
                    (begin
                      (insert map key default-value)
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
              (define (next-occupied [map : Map] [from : i64]) : i64
                (base.i64-hash-state-map-next-occupied
                  (struct-get map inner)
                  from))
              (define (entry-at [map : Map] [index : i64]) : Entry
                (match (base.i64-hash-state-map-entry-at
                  (struct-get map inner)
                  index)
                  [(base.I64HashStateMapEntrySome key value)
                    (EntrySome key value)]
                  [(base.I64HashStateMapEntryNone) (EntryNone)]))
              (define (entry-value-or [entry : Entry] [fallback : ,V]) : ,V
                (match entry
                  [(EntrySome _ value) value]
                  [(EntryNone) fallback])))]
          [_
            `(begin
              (module ,module-name))])]
      [_
        (match (type-key K)
          ["struct_stdlib.hashmap/HashNestedKey"
            (match (type-key V)
              ["i64"
                `(begin
                  (module ,module-name)
                  (import stdlib.hashmap as base)
                  (defstruct Map
                    (inner base.HashNestedKeyI64Map))
                  (defenum Lookup
                    (LookupMissing)
                    (LookupFound i64))
                  (defenum BorrowedValueLookup
                    (:lifetimes map)
                    (BorrowedValueMissing)
                    (BorrowedValueFound (& map i64)))
                  (defenum RemoveResult
                    (RemoveOk)
                    (RemoveMissing))
                  (defenum EntryOrInsertResult
                    (EntryOrInsertFound i64)
                    (EntryOrInsertInserted i64))
                  (defenum Entry
                    (EntryNone)
                    (EntrySome ,K i64))
                  (define (with-capacity [capacity : i64]) : Map
                    (Map (base.hash-nested-key-i64-map-with-capacity capacity)))
                  (define (new) : Map
                    (with-capacity 4))
                  (define (len [map : Map]) : i64
                    (base.hash-nested-key-i64-map-len (struct-get map inner)))
                  (define (capacity [map : Map]) : i64
                    (base.hash-nested-key-i64-map-capacity
                      (struct-get map inner)))
                  (define (deleted [map : Map]) : i64
                    (base.hash-nested-key-i64-map-deleted
                      (struct-get map inner)))
                  (define (inner-mut [map : (&mut map Map)]) : (&mut
                      map
                      base.HashNestedKeyI64Map)
                    (&mut (struct-get map inner)))
                  (define (is-empty? [map : Map]) : bool
                    (<= (len map) 0))
                  (define (lookup-from-base
                    [lookup : base.HashNestedKeyI64MapLookup]) : Lookup
                    (match lookup
                      [(base.HashNestedKeyI64MapFound value)
                        (LookupFound value)]
                      [(base.HashNestedKeyI64MapMissing) (LookupMissing)]))
                  (define (get [map : Map] [key : ,K]) : Lookup
                    (lookup-from-base
                      (base.hash-nested-key-i64-map-get
                        (struct-get map inner)
                        key)))
                  (define (lookup-value-or [lookup : Lookup] [fallback : i64]) : i64
                    (match lookup
                      [(LookupFound value) value]
                      [(LookupMissing) fallback]))
                  (define (borrowed-value-missing [_map : (& map Map)]) : (BorrowedValueLookup
                      map)
                    (BorrowedValueMissing))
                  (define (borrowed-value-found [value : (& map i64)]) : (BorrowedValueLookup
                      map)
                    (BorrowedValueFound value))
                  (define (get-value-borrowed [map : (& map Map)] [key : ,K]) : (BorrowedValueLookup
                      map)
                    (match (base.hash-nested-key-i64-map-get-value-borrowed
                      (& (struct-get map inner))
                      key)
                      [(base.HashNestedKeyI64MapBorrowedValueFound value)
                        (borrowed-value-found value)]
                      [(base.HashNestedKeyI64MapBorrowedValueMissing)
                        (borrowed-value-missing map)]))
                  (define (borrowed-value-found?
                    [lookup : (BorrowedValueLookup map)]) : bool
                    (match lookup
                      [(BorrowedValueFound _) true]
                      [(BorrowedValueMissing) false]))
                  (define (contains? [map : Map] [key : ,K]) : bool
                    (base.hash-nested-key-i64-map-contains?
                      (struct-get map inner)
                      key))
                  (define (insert
                    [map : (&mut map Map)]
                    [key : ,K]
                    [value : i64]) : unit
                    (base.hash-nested-key-i64-map-put!
                      (inner-mut map)
                      key
                      value))
                  (define (insert-or-update
                    [map : (&mut map Map)]
                    [key : ,K]
                    [value : i64]) : unit
                    (insert map key value))
                  (define (remove [map : (&mut map Map)] [key : ,K]) : RemoveResult
                    (if (base.hash-nested-key-i64-map-remove!
                      (inner-mut map)
                      key)
                      (RemoveOk)
                      (RemoveMissing)))
                  (define (remove-ok? [result : RemoveResult]) : bool
                    (match result
                      [(RemoveOk) true]
                      [(RemoveMissing) false]))
                  (define (entry-or-insert
                    [map : (&mut map Map)]
                    [key : ,K]
                    [default-value : i64]) : EntryOrInsertResult
                    (match (base.hash-nested-key-i64-map-get-ref
                      (& (struct-get map inner))
                      key)
                      [(base.HashNestedKeyI64MapFound value)
                        (EntryOrInsertFound value)]
                      [(base.HashNestedKeyI64MapMissing)
                        (begin
                          (insert map key default-value)
                          (EntryOrInsertInserted default-value))]))
                  (define (entry-or-insert-inserted?
                    [result : EntryOrInsertResult]) : bool
                    (match result
                      [(EntryOrInsertInserted _) true]
                      [(EntryOrInsertFound _) false]))
                  (define (entry-or-insert-value-or
                    [result : EntryOrInsertResult]
                    [fallback : i64]) : i64
                    (match result
                      [(EntryOrInsertFound value) value]
                      [(EntryOrInsertInserted value) value]))
                  (define (next-occupied [map : Map] [from : i64]) : i64
                    (base.hash-nested-key-i64-map-next-occupied
                      (struct-get map inner)
                      from))
                  (define (entry-at [map : Map] [index : i64]) : Entry
                    (match (base.hash-nested-key-i64-map-entry-at
                      (struct-get map inner)
                      index)
                      [(base.HashNestedKeyI64MapEntrySome key value)
                        (EntrySome key value)]
                      [(base.HashNestedKeyI64MapEntryNone) (EntryNone)]))
                  (define (entry-value-or [entry : Entry] [fallback : i64]) : i64
                    (match entry
                      [(EntrySome _ value) value]
                      [(EntryNone) fallback])))]
              [_
                `(begin
                  (module ,module-name))])]
          [_
            `(begin
              (module ,module-name))])])))

;: One open-addressing slot: empty, a deleted tombstone, or an occupied entry
;: carrying the owned key, its copied value, and the cached key hash (#824).
(defenum StringI64MapSlot
  (StringI64MapEmpty)
  (StringI64MapTombstone)
  (StringI64MapOccupied String i64 i64))

;: Result of probing for a key in a slot array:
;: - `Found` carries the slot index that holds the key.
;: - `Absent` carries the slot index where the key may be inserted (the first
;:   tombstone seen, otherwise the first empty slot).
;: - `Full` means the key is not present and the table has neither an empty
;:   slot nor a reusable tombstone.
(defenum StringI64MapProbe
  (StringI64MapProbeFound i64)
  (StringI64MapProbeAbsent i64)
  (StringI64MapProbeFull))

;: Return whether `capacity` is positive and a power of two.
(define (string-i64-map-power-two-capacity? [capacity : i64]) : bool
  (and (> capacity 0) (= (bit-and capacity (- capacity 1)) 0)))

;: Round `capacity` up to the next positive power of two. Non-positive requests
;: become capacity 1 so every constructed map keeps the mask invariant.
(define (string-i64-map-round-capacity [capacity : i64]) : i64
  (let
    [rounded : i64 1]
    (begin
      (while (< rounded capacity)
        (set! rounded (* rounded 2)))
      rounded)))

;: Return the start bucket when `hash` is already in the public hash range.
;: `capacity` must be a positive power of two.
(define (string-i64-map-normalized-bucket-index [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

;: Return the start bucket for `hash` in a table of `capacity` slots.
;: `capacity` must be positive; the result is in `[0, capacity)`.
(define (string-i64-map-bucket-index [hash : i64] [capacity : i64]) : i64
  (stdlib.hashmap.string-i64-map-normalized-bucket-index
    (hash_mod.normalize hash)
    capacity))

;: Advance a bucket index by one slot, wrapping around the table.
(define (string-i64-map-next-index [index : i64] [capacity : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next capacity)
      0
      next)))

;: Read the slot at `index`. Probe/iteration indices are always in
;: `[0, capacity)`, so skip the redundant dynamic-array bounds check.
(define (string-i64-map-slot-at
  [slots : (Array StringI64MapSlot)]
  [index : i64]) : StringI64MapSlot
  (unsafe
    (ptr-read
      (ptr-offset (ptr-cast (array-data slots) : (Ptr StringI64MapSlot)) index))))

;: Pick the insertion slot for an absent key: reuse the first tombstone seen
;: (`first-tombstone` >= 0) so deletes do not strand keys, otherwise the empty
;: slot the probe stopped on.
(define (string-i64-map-insert-slot [first-tombstone : i64] [empty-index : i64]) : i64
  (if (>= first-tombstone 0)
    first-tombstone
    empty-index))

;: Linear-probing walk from `index`, having taken `steps` steps and remembered
;: the first tombstone index (`-1` when none seen yet). Terminates after at most
;: `capacity` steps so a full table never loops forever.
(define (string-i64-map-probe-from
  [slots : (Array StringI64MapSlot)]
  [capacity : i64]
  [key : String]
  [hash : i64]
  [index : i64]
  [steps : i64]
  [first-tombstone : i64]) : StringI64MapProbe
  (let
    [cursor : i64 index]
    [walked : i64 steps]
    [first : i64 first-tombstone]
    (begin
      (while (< walked capacity)
        (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
          [(StringI64MapEmpty)
            (return
              (StringI64MapProbeAbsent
                (if (>= first 0)
                  first
                  cursor)))]
          [(StringI64MapTombstone)
            (let
              [next : i64 (+ cursor 1)]
              (begin
                (if (< first 0)
                  (set! first cursor)
                  unit)
                (set!
                  cursor
                  (if (>= next capacity)
                    0
                    next))
                (set! walked (+ walked 1))))]
          [(StringI64MapOccupied slot-key _ slot-hash)
            (if (if (= slot-hash hash)
              (hash_mod.key-string-eq? (& slot-key) (& key))
              false)
              (return (StringI64MapProbeFound cursor))
              (let
                [next : i64 (+ cursor 1)]
                (begin
                  (set!
                    cursor
                    (if (>= next capacity)
                      0
                      next))
                  (set! walked (+ walked 1)))))]))
      (if (>= first 0)
        (StringI64MapProbeAbsent first)
        (StringI64MapProbeFull)))))

;: Probe `slots` (a `capacity`-length open-addressing table) for `key` with the
;: precomputed `hash`. Returns where the key lives (`Found`), where it could be
;: inserted (`Absent`), or `Full`. Callers compute `hash` with `hash.string-key`.
(define (string-i64-map-probe
  [slots : (Array StringI64MapSlot)]
  [capacity : i64]
  [key : String]
  [hash : i64]) : StringI64MapProbe
  (stdlib.hashmap.string-i64-map-probe-borrowed slots capacity (& key) hash))

;: Borrowed-key probing for the compatibility `String -> i64` map. This keeps
;: old owned-key probe callers working while exposing the generated-family lookup
;: shape used by newer string-key maps.
(define (string-i64-map-probe-borrowed-from
  [slots : (Array StringI64MapSlot)]
  [capacity : i64]
  [key : (& key str)]
  [hash : i64]
  [index : i64]
  [steps : i64]
  [first-tombstone : i64]) : StringI64MapProbe
  (let
    [cursor : i64 index]
    [walked : i64 steps]
    [first : i64 first-tombstone]
    (begin
      (while (< walked capacity)
        (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
          [(StringI64MapEmpty)
            (return
              (StringI64MapProbeAbsent
                (stdlib.hashmap.string-i64-map-insert-slot first cursor)))]
          [(StringI64MapTombstone)
            (let
              [next : i64 (+ cursor 1)]
              (begin
                (if (< first 0)
                  (set! first cursor)
                  unit)
                (set!
                  cursor
                  (if (>= next capacity)
                    0
                    next))
                (set! walked (+ walked 1))))]
          [(StringI64MapOccupied slot-key _ slot-hash)
            (if (if (= slot-hash hash)
              (hash_mod.key-string-eq? (& slot-key) key)
              false)
              (return (StringI64MapProbeFound cursor))
              (let
                [next : i64 (+ cursor 1)]
                (begin
                  (set!
                    cursor
                    (if (>= next capacity)
                      0
                      next))
                  (set! walked (+ walked 1)))))]))
      (if (>= first 0)
        (StringI64MapProbeAbsent first)
        (StringI64MapProbeFull)))))

;: Probe `slots` for a borrowed string key with a precomputed `hash`.
(define (string-i64-map-probe-borrowed
  [slots : (Array StringI64MapSlot)]
  [capacity : i64]
  [key : (& key str)]
  [hash : i64]) : StringI64MapProbe
  (if (<= capacity 0)
    (StringI64MapProbeFull)
    (stdlib.hashmap.string-i64-map-probe-borrowed-from
      slots
      capacity
      key
      hash
      (stdlib.hashmap.string-i64-map-bucket-index hash capacity)
      0
      -1)))

;: Probe when `hash` is already normalized, as produced by `hash.string-key` or
;: copied from an occupied slot.
(define (string-i64-map-probe-normalized
  [slots : (Array StringI64MapSlot)]
  [capacity : i64]
  [key : String]
  [hash : i64]) : StringI64MapProbe
  (if (<= capacity 0)
    (StringI64MapProbeFull)
    (stdlib.hashmap.string-i64-map-probe-from
      slots
      capacity
      key
      hash
      (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)
      0
      -1)))

;: The v1 fixed-capacity `String -> i64` map (representation from #824): the
;: open-addressing slot table, the live-entry count, and the tombstone count.
(defstruct StringI64Map
  (slots (Array StringI64MapSlot))
  (len i64)
  (deleted i64))

;: Result of a lookup: the key's copied value, or missing.
(defenum StringI64MapLookup
  (StringI64MapMissing)
  (StringI64MapFound i64))

;: Result of a borrowed-value lookup: a reference to the map-owned value, or
;: missing. The returned reference is tied to the borrowed map.
(defenum StringI64MapBorrowedValueLookup
  (:lifetimes map)
  (StringI64MapBorrowedValueMissing)
  (StringI64MapBorrowedValueFound (& map i64)))

;: Result of an insert: the updated map (the bucket array is mutated in place,
;: so callers thread the returned map forward), or `Full` when the
;: fixed-capacity table has no slot for a new key.
(defenum StringI64MapInsertResult
  (StringI64MapInsertOk StringI64Map)
  (StringI64MapInsertFull StringI64Map))

;: Result of a removal: the updated map (a live slot becomes a tombstone in
;: place, so callers thread the returned map forward) when the key was present,
;: or `Missing` with the map unchanged when it was not.
(defenum StringI64MapRemoveResult
  (StringI64MapRemoveOk StringI64Map)
  (StringI64MapRemoveMissing StringI64Map))

;: Result of an update-only operation: the updated map when the key was present,
;: or `Missing` with the map unchanged when it was absent.
(defenum StringI64MapUpdateResult
  (StringI64MapUpdateOk StringI64Map)
  (StringI64MapUpdateMissing StringI64Map))

;: Result of `entry-or-insert`: the map plus the live value. `Found` means the
;: key already existed and the map was not changed; `Inserted` means the default
;: value was inserted, growing/rehashing first if needed.
(defenum StringI64MapEntryOrInsertResult
  (StringI64MapEntryOrInsertFound StringI64Map i64)
  (StringI64MapEntryOrInsertInserted StringI64Map i64))

;: Probe metadata used to construct a live mutable entry after the caller takes
;: the unique slot borrow. `present=false` means `index` is a sentinel and the
;: entry setter is a no-op.
(defstruct StringI64MapMutEntryInfo
  (index i64)
  (present bool)
  (key String)
  (hash i64))

;: Live mutable entry handle for an existing bucket. `borrow` carries the unique
;: slot-array borrow and is used for reads/writes, so the checker rejects
;: another mutable entry or table mutation while live.
(defstruct StringI64MapMutEntry
  (:lifetimes map)
  (borrow (&mut map (Array StringI64MapSlot)))
  (index i64)
  (present bool)
  (key String)
  (hash i64))

;: The map's backing slot array.
(define (string-i64-map-slots [map : StringI64Map]) : (Array StringI64MapSlot)
  (struct-get map slots))

;: Mutable access to the map's backing slot array for wrapper modules.
(define (string-i64-map-slots-mut [map : (&mut map StringI64Map)]) : (&mut
    map
    (Array StringI64MapSlot))
  (&mut (struct-get map slots)))

;: Number of live (occupied) entries.
(define (string-i64-map-len [map : StringI64Map]) : i64
  (struct-get map len))

;: Number of slots in the backing table.
(define (string-i64-map-capacity [map : StringI64Map]) : i64
  (array.array-length (struct-get map slots)))

;: Number of tombstone (deleted) slots awaiting reuse. Live entries plus
;: tombstones never exceed the capacity; this count feeds resize thresholds
;: (#827).
(define (string-i64-map-deleted [map : StringI64Map]) : i64
  (struct-get map deleted))

;: Set slots `[index, count)` of `slots` to `StringI64MapEmpty`.
(define (string-i64-map-fill-empty
  [slots : (Array StringI64MapSlot)]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (begin
      (while (< i count)
        (begin
          (array.array-set! slots i (StringI64MapEmpty))
          (set! i (+ i 1))))
      unit)))

;: Create an empty map with `capacity` rounded up to a positive power of two.
(define (string-i64-map-with-capacity [capacity : i64]) : StringI64Map
  (let
    [rounded-capacity : i64
      (stdlib.hashmap.string-i64-map-round-capacity capacity)]
    [slots : (Array StringI64MapSlot)
      (array.make-array StringI64MapSlot rounded-capacity)]
    (begin
      (stdlib.hashmap.string-i64-map-fill-empty slots 0 rounded-capacity)
      (StringI64Map slots 0 0))))

;: Construct a missing borrowed-value lookup result tied to `map`.
(define (string-i64-map-borrowed-value-missing [_map : (& map StringI64Map)]) : (StringI64MapBorrowedValueLookup
    map)
  (StringI64MapBorrowedValueMissing))

;: Construct a found borrowed-value lookup result tied to `map`.
(define (string-i64-map-borrowed-value-found [value : (& map i64)]) : (StringI64MapBorrowedValueLookup
    map)
  (StringI64MapBorrowedValueFound value))

;: Look up borrowed `key`, returning its copied `i64` value or `Missing`.
(define (string-i64-map-get-borrowed [map : StringI64Map] [key : (& key str)]) : StringI64MapLookup
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    [capacity : i64 (array.array-length slots)]
    (if (<= capacity 0)
      (StringI64MapMissing)
      (let
        [hash : i64 (hash_mod.string-key key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
              [(StringI64MapEmpty) (return (StringI64MapMissing))]
              [(StringI64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringI64MapOccupied slot-key value slot-hash)
                (if (if (= slot-hash hash)
                  (hash_mod.key-string-eq? (& slot-key) key)
                  false)
                  (return (StringI64MapFound value))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (StringI64MapMissing))))))

;: Compatibility owned-key lookup wrapper for existing callers.
(define (string-i64-map-get [map : StringI64Map] [key : String]) : StringI64MapLookup
  (stdlib.hashmap.string-i64-map-get-borrowed map (& key)))

;: Borrowed lookup through an immutable map reference.
(define (string-i64-map-get-borrowed-ref
  [map : (& map StringI64Map)]
  [key : (& key str)]) : StringI64MapLookup
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    (if (<= capacity 0)
      (StringI64MapMissing)
      (let
        [hash : i64 (hash_mod.string-key key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref (struct-get map slots) cursor)
              [(StringI64MapEmpty) (return (StringI64MapMissing))]
              [(StringI64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringI64MapOccupied slot-key value slot-hash)
                (if (if (= slot-hash hash)
                  (hash_mod.key-string-eq? (& slot-key) key)
                  false)
                  (return (StringI64MapFound value))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (StringI64MapMissing))))))

;: Borrowed lookup through a mutable map reference.
(define (string-i64-map-get-borrowed-mut
  [map : (&mut map StringI64Map)]
  [key : (& key str)]) : StringI64MapLookup
  (let
    [slots : (&mut map (Array StringI64MapSlot))
      (stdlib.hashmap.string-i64-map-slots-mut map)]
    [capacity : i64 (array.array-length slots)]
    (if (<= capacity 0)
      (StringI64MapMissing)
      (let
        [hash : i64 (hash_mod.string-key key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref slots cursor)
              [(StringI64MapEmpty) (return (StringI64MapMissing))]
              [(StringI64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringI64MapOccupied slot-key value slot-hash)
                (if (if (= slot-hash hash)
                  (hash_mod.key-string-eq? (& slot-key) key)
                  false)
                  (return (StringI64MapFound value))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (StringI64MapMissing))))))

;: Containment through an immutable map reference.
(define (string-i64-map-contains-borrowed-ref?
  [map : (& map StringI64Map)]
  [key : (& key str)]) : bool
  (match (stdlib.hashmap.string-i64-map-get-borrowed-ref map key)
    [(StringI64MapFound _) true]
    [(StringI64MapMissing) false]))

;: Containment through a mutable map reference.
(define (string-i64-map-contains-borrowed-mut?
  [map : (&mut map StringI64Map)]
  [key : (& key str)]) : bool
  (match (stdlib.hashmap.string-i64-map-get-borrowed-mut map key)
    [(StringI64MapFound _) true]
    [(StringI64MapMissing) false]))

;: Look up borrowed `key`, returning a reference to the map-owned `i64` value
;: or `Missing`. The reference is invalidated by any map mutation/resizing.
(define (string-i64-map-get-value-borrowed
  [map : (& map StringI64Map)]
  [key : (& key str)]) : (StringI64MapBorrowedValueLookup map)
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    (if (<= capacity 0)
      (stdlib.hashmap.string-i64-map-borrowed-value-missing map)
      (let
        [hash : i64 (hash_mod.string-key key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref (struct-get map slots) cursor)
              [(StringI64MapEmpty)
                (return
                  (stdlib.hashmap.string-i64-map-borrowed-value-missing map))]
              [(StringI64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringI64MapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (hash_mod.key-string-eq? (& slot-key) key)
                  false)
                  (match (& (array.array-ref (struct-get map slots) cursor))
                    [(StringI64MapOccupied _ value _)
                      (return
                        (stdlib.hashmap.string-i64-map-borrowed-value-found
                          value))]
                    [(StringI64MapEmpty)
                      (return
                        (stdlib.hashmap.string-i64-map-borrowed-value-missing
                          map))]
                    [(StringI64MapTombstone)
                      (return
                        (stdlib.hashmap.string-i64-map-borrowed-value-missing
                          map))])
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (stdlib.hashmap.string-i64-map-borrowed-value-missing map))))))

;: True when borrowed `key` has a live value in `map`.
(define (string-i64-map-contains-borrowed?
  [map : StringI64Map]
  [key : (& key str)]) : bool
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    [capacity : i64 (array.array-length slots)]
    (if (<= capacity 0)
      false
      (let
        [hash : i64 (hash_mod.string-key key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
              [(StringI64MapEmpty) (return false)]
              [(StringI64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringI64MapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (hash_mod.key-string-eq? (& slot-key) key)
                  false)
                  (return true)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          false)))))

;: Compatibility owned-key containment wrapper for existing callers.
(define (string-i64-map-contains? [map : StringI64Map] [key : String]) : bool
  (stdlib.hashmap.string-i64-map-contains-borrowed? map (& key)))

;: True when `slot` is a reusable tombstone.
(define (string-i64-map-slot-tombstone? [slot : StringI64MapSlot]) : bool
  (match slot
    [(StringI64MapTombstone) true]
    [(StringI64MapEmpty) false]
    [(StringI64MapOccupied _ _ _) false]))

;: Insert or update `key` -> `value`, mutating the backing slot array and
;: returning the updated map. Updating an existing key leaves `len` unchanged;
;: inserting a new key increments it; reusing a tombstone slot also decrements
;: the deleted count. `Full` when a fixed-capacity table cannot place a new key.
(define (string-i64-map-insert
  [map : StringI64Map]
  [key : String]
  [value : i64]) : StringI64MapInsertResult
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    [capacity : i64 (array.array-length slots)]
    [hash : i64 (hash_mod.string-key (& key))]
    (if (<= capacity 0)
      (StringI64MapInsertFull map)
      (let
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        [first : i64 -1]
        (begin
          (while (< walked capacity)
            (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
              [(StringI64MapEmpty)
                (let
                  [index : i64
                    (if (>= first 0)
                      first
                      cursor)]
                  [reused-tombstone : bool (>= first 0)]
                  [deleted : i64 (stdlib.hashmap.string-i64-map-deleted map)]
                  (begin
                    (array.array-set!
                      slots
                      index
                      (StringI64MapOccupied key value hash))
                    (set!
                      (struct-get map len)
                      (+ (stdlib.hashmap.string-i64-map-len map) 1))
                    (if reused-tombstone
                      (set! (struct-get map deleted) (- deleted 1))
                      unit)
                    (return (StringI64MapInsertOk map))))]
              [(StringI64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (if (< first 0)
                      (set! first cursor)
                      unit)
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringI64MapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (hash_mod.key-string-eq? (& slot-key) (& key))
                  false)
                  (begin
                    (array.array-set!
                      slots
                      cursor
                      (StringI64MapOccupied key value hash))
                    (return (StringI64MapInsertOk map)))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (if (>= first 0)
            (let
              [deleted : i64 (stdlib.hashmap.string-i64-map-deleted map)]
              (begin
                (array.array-set!
                  slots
                  first
                  (StringI64MapOccupied key value hash))
                (set!
                  (struct-get map len)
                  (+ (stdlib.hashmap.string-i64-map-len map) 1))
                (set! (struct-get map deleted) (- deleted 1))
                (StringI64MapInsertOk map)))
            (StringI64MapInsertFull map)))))))

;: Remove borrowed `key`, replacing its live slot with a tombstone (so probing
;: past it still finds later collided keys) and returning the updated map with
;: `len` decremented and the deleted count incremented. Returns `Missing` with
;: the map unchanged when the key is absent. A later insert can reuse the
;: tombstone. The backing array is mutated in place, so thread the result
;: forward.
(define (string-i64-map-remove-borrowed
  [map : StringI64Map]
  [key : (& key str)]) : StringI64MapRemoveResult
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    [capacity : i64 (array.array-length slots)]
    (if (<= capacity 0)
      (StringI64MapRemoveMissing map)
      (let
        [hash : i64 (hash_mod.string-key key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
              [(StringI64MapEmpty) (return (StringI64MapRemoveMissing map))]
              [(StringI64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringI64MapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (hash_mod.key-string-eq? (& slot-key) key)
                  false)
                  (begin
                    (array.array-set! slots cursor (StringI64MapTombstone))
                    (set!
                      (struct-get map len)
                      (- (stdlib.hashmap.string-i64-map-len map) 1))
                    (set!
                      (struct-get map deleted)
                      (+ (stdlib.hashmap.string-i64-map-deleted map) 1))
                    (return (StringI64MapRemoveOk map)))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (StringI64MapRemoveMissing map))))))

;: Compatibility owned-key remove wrapper for existing callers.
(define (string-i64-map-remove [map : StringI64Map] [key : String]) : StringI64MapRemoveResult
  (stdlib.hashmap.string-i64-map-remove-borrowed map (& key)))

;: Update borrowed `key` only when it is already present. This preserves the
;: stored key object and hash, mutating only the occupied slot value.
(define (string-i64-map-update-borrowed-if-present
  [map : StringI64Map]
  [key : (& key str)]
  [value : i64]) : StringI64MapUpdateResult
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    [hash : i64 (hash_mod.string-key key)]
    (match (stdlib.hashmap.string-i64-map-probe-borrowed
      slots
      (stdlib.hashmap.string-i64-map-capacity map)
      key
      hash)
      [(StringI64MapProbeFound index)
        (match (array.array-ref slots index)
          [(StringI64MapOccupied slot-key _ slot-hash)
            (begin
              (array.array-set!
                slots
                index
                (StringI64MapOccupied slot-key value slot-hash))
              (StringI64MapUpdateOk map))]
          [(StringI64MapEmpty) (StringI64MapUpdateMissing map)]
          [(StringI64MapTombstone) (StringI64MapUpdateMissing map)])]
      [(StringI64MapProbeAbsent _) (StringI64MapUpdateMissing map)]
      [(StringI64MapProbeFull) (StringI64MapUpdateMissing map)])))

;: Owned-key wrapper for update-only mutation.
(define (string-i64-map-update-if-present
  [map : StringI64Map]
  [key : String]
  [value : i64]) : StringI64MapUpdateResult
  (stdlib.hashmap.string-i64-map-update-borrowed-if-present map (& key) value))

;: Remove borrowed `key` in place through a mutable map reference.
(define (string-i64-map-remove-borrowed!
  [map : (&mut map StringI64Map)]
  [key : (& key str)]) : bool
  (let
    [slots : (&mut map (Array StringI64MapSlot))
      (stdlib.hashmap.string-i64-map-slots-mut map)]
    [capacity : i64 (array.array-length slots)]
    (if (<= capacity 0)
      false
      (let
        [hash : i64 (hash_mod.string-key key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref slots cursor)
              [(StringI64MapEmpty) (return false)]
              [(StringI64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringI64MapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (hash_mod.key-string-eq? (& slot-key) key)
                  false)
                  (begin
                    (array.array-set! slots cursor (StringI64MapTombstone))
                    (set! (struct-get map len) (- (struct-get map len) 1))
                    (set!
                      (struct-get map deleted)
                      (+ (struct-get map deleted) 1))
                    (return true))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          false)))))

;: Insert into a fresh destination table during rehash_mod. Source entries are
;: unique, and the destination has no tombstones, so only the first empty slot
;: matters.
(define (string-i64-map-insert-into-empty
  [slots : (Array StringI64MapSlot)]
  [capacity : i64]
  [key : String]
  [value : i64]
  [hash : i64]) : unit
  (if (<= capacity 0)
    unit
    (let
      [cursor : i64
        (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
      [walked : i64 0]
      [done : bool false]
      (begin
        (while (if done
          false
          (< walked capacity))
          (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
            [(StringI64MapEmpty)
              (begin
                (array.array-set!
                  slots
                  cursor
                  (StringI64MapOccupied key value hash))
                (set! done true))]
            [_
              (begin
                (set!
                  cursor
                  (stdlib.hashmap.string-i64-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        unit))))

;: Re-insert every live (occupied) entry of `src` slots `[index, count)` into
;: the fresh `dst` table (`dst-capacity` empty slots), dropping tombstones.
(define (string-i64-map-rehash-from
  [src : (Array StringI64MapSlot)]
  [dst : (Array StringI64MapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (begin
      (while (< i count)
        (begin
          (match (stdlib.hashmap.string-i64-map-slot-at src i)
            [(StringI64MapOccupied key value hash)
              (stdlib.hashmap.string-i64-map-insert-into-empty
                dst
                dst-capacity
                key
                value
                hash)]
            [(StringI64MapEmpty) unit]
            [(StringI64MapTombstone) unit])
          (set! i (+ i 1))))
      unit)))

;: Borrowed-source variant used by in-place resize helpers.
(define (string-i64-map-rehash-from-ref
  [src : (& src (Array StringI64MapSlot))]
  [dst : (Array StringI64MapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (begin
      (while (< i count)
        (begin
          (match (array.array-ref src i)
            [(StringI64MapOccupied key value hash)
              (stdlib.hashmap.string-i64-map-insert-into-empty
                dst
                dst-capacity
                key
                value
                hash)]
            [(StringI64MapEmpty) unit]
            [(StringI64MapTombstone) unit])
          (set! i (+ i 1))))
      unit)))

;: Rebuild `map` as a fresh power-of-two table holding only its live entries
;: (tombstones dropped, so the deleted count resets to 0). The backing array is
;: newly allocated; the old one is reclaimed when the arena resets.
(define (string-i64-map-resized [map : StringI64Map] [new-capacity : i64]) : StringI64Map
  (let
    [src : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    [old-capacity : i64 (array.array-length src)]
    [requested-capacity : i64
      (if (> (stdlib.hashmap.string-i64-map-len map) new-capacity)
        (stdlib.hashmap.string-i64-map-len map)
        new-capacity)]
    [rounded-capacity : i64
      (stdlib.hashmap.string-i64-map-round-capacity requested-capacity)]
    [dst : (Array StringI64MapSlot)
      (array.make-array StringI64MapSlot rounded-capacity)]
    (begin
      (stdlib.hashmap.string-i64-map-fill-empty dst 0 rounded-capacity)
      (stdlib.hashmap.string-i64-map-rehash-from
        src
        dst
        rounded-capacity
        0
        old-capacity)
      (set! (struct-get map slots) dst)
      (set! (struct-get map deleted) 0)
      map)))

;: Next capacity when growing: double, with a small floor so a tiny or empty
;: table grows to a useful size in one step.
(define (string-i64-map-grow-capacity [capacity : i64]) : i64
  (if (< capacity 4)
    8
    (* (stdlib.hashmap.string-i64-map-round-capacity capacity) 2)))

;: Grow `map` to the next capacity, rehashing its live entries.
(define (string-i64-map-grow [map : StringI64Map]) : StringI64Map
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    (stdlib.hashmap.string-i64-map-resized
      map
      (stdlib.hashmap.string-i64-map-grow-capacity (array.array-length slots)))))

;: True when the table has reached the 3/4 load threshold, counting both live
;: entries and tombstones (both consume probe positions). A non-positive
;: capacity always needs to grow before it can hold anything.
(define (string-i64-map-needs-grow? [map : StringI64Map]) : bool
  (let
    [capacity : i64
      (array.array-length (stdlib.hashmap.string-i64-map-slots map))]
    [used : i64
      (+
        (stdlib.hashmap.string-i64-map-len map)
        (stdlib.hashmap.string-i64-map-deleted map))]
    (if (<= capacity 0)
      true
      (>= (* used 4) (* capacity 3)))))

;: Mutable-reference variant of `string-i64-map-needs-grow?`.
(define (string-i64-map-needs-grow-mut? [map : (&mut map StringI64Map)]) : bool
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    [used : i64 (+ (struct-get map len) (struct-get map deleted))]
    (if (<= capacity 0)
      true
      (>= (* used 4) (* capacity 3)))))

;: Insert or update `key` -> `value`, growing (rehashing) the table first when
;: it has reached the load threshold so insertion never fails. Returns the
;: updated map directly. Use this instead of `string-i64-map-insert` when the
;: map should grow on demand rather than report `Full`.
(define (string-i64-map-put [map : StringI64Map] [key : String] [value : i64]) : StringI64Map
  (let
    [grown : StringI64Map
      (if (stdlib.hashmap.string-i64-map-needs-grow? map)
        (stdlib.hashmap.string-i64-map-grow map)
        map)]
    (match (stdlib.hashmap.string-i64-map-insert grown key value)
      [(StringI64MapInsertOk updated) updated]
      [(StringI64MapInsertFull full)
        ;; `needs-grow?` keeps a positive-capacity table below full; a leftover
        ;; `Full` (e.g. a capacity-0 seed) is handled by one more grow + retry.
        (match (stdlib.hashmap.string-i64-map-insert
          (stdlib.hashmap.string-i64-map-grow full)
          key
          value)
          [(StringI64MapInsertOk u) u]
          [(StringI64MapInsertFull u) u])])))

;: Resize `map` in place, dropping tombstones and preserving live entries.
(define (string-i64-map-resize!
  [map : (&mut map StringI64Map)]
  [new-capacity : i64]) : unit
  (let
    [old-capacity : i64 (array.array-length (struct-get map slots))]
    [requested-capacity : i64
      (if (> (struct-get map len) new-capacity)
        (struct-get map len)
        new-capacity)]
    [rounded-capacity : i64
      (stdlib.hashmap.string-i64-map-round-capacity requested-capacity)]
    [dst : (Array StringI64MapSlot)
      (array.make-array StringI64MapSlot rounded-capacity)]
    (begin
      (stdlib.hashmap.string-i64-map-fill-empty dst 0 rounded-capacity)
      (stdlib.hashmap.string-i64-map-rehash-from-ref
        (& (struct-get map slots))
        dst
        rounded-capacity
        0
        old-capacity)
      (set! (struct-get map slots) dst)
      (set! (struct-get map deleted) 0))))

;: Grow `map` in place to the next table capacity.
(define (string-i64-map-grow! [map : (&mut map StringI64Map)]) : unit
  (stdlib.hashmap.string-i64-map-resize!
    map
    (stdlib.hashmap.string-i64-map-grow-capacity
      (array.array-length (struct-get map slots)))))

;: Insert or update through a mutable map reference.
(define (string-i64-map-put!
  [map : (&mut map StringI64Map)]
  [key : String]
  [value : i64]) : unit
  (begin
    (if (stdlib.hashmap.string-i64-map-needs-grow-mut? map)
      (stdlib.hashmap.string-i64-map-grow! map)
      unit)
    (let
      [slots : (&mut map (Array StringI64MapSlot))
        (stdlib.hashmap.string-i64-map-slots-mut map)]
      [capacity : i64 (array.array-length slots)]
      [hash : i64 (hash_mod.string-key (& key))]
      (if (<= capacity 0)
        unit
        (let
          [cursor : i64
            (stdlib.hashmap.string-i64-map-normalized-bucket-index
              hash
              capacity)]
          [walked : i64 0]
          [first : i64 -1]
          (begin
            (while (< walked capacity)
              (match (array.array-ref slots cursor)
                [(StringI64MapEmpty)
                  (let
                    [index : i64
                      (if (>= first 0)
                        first
                        cursor)]
                    [reused-tombstone : bool (>= first 0)]
                    (begin
                      (array.array-set!
                        slots
                        index
                        (StringI64MapOccupied key value hash))
                      (set! (struct-get map len) (+ (struct-get map len) 1))
                      (if reused-tombstone
                        (set!
                          (struct-get map deleted)
                          (- (struct-get map deleted) 1))
                        unit)
                      (return unit)))]
                [(StringI64MapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (if (< first 0)
                        (set! first cursor)
                        unit)
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(StringI64MapOccupied slot-key _ slot-hash)
                  (if (if (= slot-hash hash)
                    (hash_mod.key-string-eq? (& slot-key) (& key))
                    false)
                    (begin
                      (array.array-set! slots cursor (StringI64MapTombstone))
                      (set! (struct-get map len) (- (struct-get map len) 1))
                      (set!
                        (struct-get map deleted)
                        (+ (struct-get map deleted) 1))
                      (set! first cursor)
                      (set! walked capacity))
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            (if (>= first 0)
              (begin
                (array.array-set!
                  slots
                  first
                  (StringI64MapOccupied key value hash))
                (set! (struct-get map len) (+ (struct-get map len) 1))
                (set! (struct-get map deleted) (- (struct-get map deleted) 1)))
              unit)))))))

;: Insert `key -> value`, or update the existing key to `value`.
(define (string-i64-map-insert-or-update
  [map : StringI64Map]
  [key : String]
  [value : i64]) : StringI64Map
  (stdlib.hashmap.string-i64-map-put map key value))

;: Return the existing value for `key`, or insert `default-value` and return it.
;: This does not expose a live bucket handle; callers thread the returned map.
(define (string-i64-map-entry-or-insert
  [map : StringI64Map]
  [key : String]
  [default-value : i64]) : StringI64MapEntryOrInsertResult
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    [hash : i64 (hash_mod.string-key (& key))]
    (match (stdlib.hashmap.string-i64-map-probe-borrowed
      slots
      (stdlib.hashmap.string-i64-map-capacity map)
      (& key)
      hash)
      [(StringI64MapProbeFound index)
        (match (array.array-ref slots index)
          [(StringI64MapOccupied _ value _)
            (StringI64MapEntryOrInsertFound map value)]
          [(StringI64MapEmpty)
            (let
              [updated : StringI64Map
                (stdlib.hashmap.string-i64-map-put map key default-value)]
              (StringI64MapEntryOrInsertInserted updated default-value))]
          [(StringI64MapTombstone)
            (let
              [updated : StringI64Map
                (stdlib.hashmap.string-i64-map-put map key default-value)]
              (StringI64MapEntryOrInsertInserted updated default-value))])]
      [(StringI64MapProbeAbsent _)
        (let
          [updated : StringI64Map
            (stdlib.hashmap.string-i64-map-put map key default-value)]
          (StringI64MapEntryOrInsertInserted updated default-value))]
      [(StringI64MapProbeFull)
        (let
          [updated : StringI64Map
            (stdlib.hashmap.string-i64-map-put map key default-value)]
          (StringI64MapEntryOrInsertInserted updated default-value))])))

;: Probe for a borrowed key and return the immutable information needed to
;: construct a live mutable-entry handle. This helper does not borrow the map.
(define (string-i64-map-mut-entry-info
  [slots : (Array StringI64MapSlot)]
  [capacity : i64]
  [key : (& key str)]) : StringI64MapMutEntryInfo
  (if (<= capacity 0)
    (StringI64MapMutEntryInfo -1 false "" 0)
    (let
      [hash : i64 (hash_mod.string-key key)]
      [cursor : i64 (stdlib.hashmap.string-i64-map-bucket-index hash capacity)]
      [walked : i64 0]
      [found : i64 -1]
      [present : bool false]
      [entry-key : String ""]
      [entry-hash : i64 0]
      [done : bool false]
      (begin
        (while (and (< walked capacity) (not done))
          (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
            [(StringI64MapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (hash_mod.key-string-eq? (& slot-key) key)
                false)
                (begin
                  (set! found cursor)
                  (set! present true)
                  (set! entry-key slot-key)
                  (set! entry-hash slot-hash)
                  (set! done true))
                (begin
                  (set!
                    cursor
                    (stdlib.hashmap.string-i64-map-next-index cursor capacity))
                  (set! walked (+ walked 1))))]
            [(StringI64MapEmpty) (set! done true)]
            [(StringI64MapTombstone)
              (begin
                (set!
                  cursor
                  (stdlib.hashmap.string-i64-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        (StringI64MapMutEntryInfo found present entry-key entry-hash)))))

;: Mutable-array variant of `string-i64-map-mut-entry-info` for wrapper APIs.
(define (string-i64-map-mut-entry-info-mut
  [slots : (&mut slots (Array StringI64MapSlot))]
  [capacity : i64]
  [key : (& key str)]) : StringI64MapMutEntryInfo
  (if (<= capacity 0)
    (StringI64MapMutEntryInfo -1 false "" 0)
    (let
      [hash : i64 (hash_mod.string-key key)]
      [cursor : i64 (stdlib.hashmap.string-i64-map-bucket-index hash capacity)]
      [walked : i64 0]
      [found : i64 -1]
      [present : bool false]
      [entry-key : String ""]
      [entry-hash : i64 0]
      [done : bool false]
      (begin
        (while (and (< walked capacity) (not done))
          (match (array.array-ref slots cursor)
            [(StringI64MapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (hash_mod.key-string-eq? (& slot-key) key)
                false)
                (begin
                  (set! found cursor)
                  (set! present true)
                  (set! entry-key slot-key)
                  (set! entry-hash slot-hash)
                  (set! done true))
                (begin
                  (set!
                    cursor
                    (stdlib.hashmap.string-i64-map-next-index cursor capacity))
                  (set! walked (+ walked 1))))]
            [(StringI64MapEmpty) (set! done true)]
            [(StringI64MapTombstone)
              (begin
                (set!
                  cursor
                  (stdlib.hashmap.string-i64-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        (StringI64MapMutEntryInfo found present entry-key entry-hash)))))

;: Combine direct slot access, a live mutable slots borrow, and probe metadata
;: into a mutable-entry handle tied to the map borrow lifetime.
(define (string-i64-map-mut-entry-from-info
  [info : StringI64MapMutEntryInfo]
  [borrow : (&mut map (Array StringI64MapSlot))]) : (StringI64MapMutEntry map)
  (StringI64MapMutEntry
    borrow
    (struct-get info index)
    (struct-get info present)
    (struct-get info key)
    (struct-get info hash)))

;: Borrow `map` mutably and return a live mutable entry for borrowed `key`.
;: The handle can update an existing entry in place; missing entries are
;: reported as absent and are not inserted by the handle API.
(defmacro (string-i64-map-get-mut-entry-borrowed [map : Expr] [key : Expr]) : Expr
  `(string-i64-map-mut-entry-from-info
    (string-i64-map-mut-entry-info
      (struct-get ,map slots)
      (stdlib.array.array-length (struct-get ,map slots))
      ,key)
    (&mut (struct-get ,map slots))))

;: Borrow `map` mutably and return a live mutable entry for borrowed `key`.
(define (string-i64-map-get-mut-entry-borrowed!
  [map : (&mut map StringI64Map)]
  [key : (& key str)]) : (StringI64MapMutEntry map)
  (let
    [slots : (&mut map (Array StringI64MapSlot))
      (stdlib.hashmap.string-i64-map-slots-mut map)]
    (stdlib.hashmap.string-i64-map-mut-entry-from-info
      (stdlib.hashmap.string-i64-map-mut-entry-info-mut
        slots
        (array.array-length slots)
        key)
      slots)))

;: Return whether a mutable-entry handle currently points at an occupied slot.
(define (string-i64-map-mut-entry-present? [entry : (StringI64MapMutEntry map)]) : bool
  (struct-get entry present))

;: Return the handle's current value when present, otherwise `fallback`.
(define (string-i64-map-mut-entry-value-or
  [entry : (StringI64MapMutEntry map)]
  [fallback : i64]) : i64
  (if (stdlib.hashmap.string-i64-map-mut-entry-present? entry)
    (match (array.array-ref (struct-get entry borrow) (struct-get entry index))
      [(StringI64MapOccupied _ value _) value]
      [(StringI64MapEmpty) fallback]
      [(StringI64MapTombstone) fallback])
    fallback))

;: Update the handle's occupied slot in place. Missing-entry handles are a no-op.
(define (string-i64-map-mut-entry-set!
  [entry : (StringI64MapMutEntry map)]
  [value : i64]) : unit
  (if (stdlib.hashmap.string-i64-map-mut-entry-present? entry)
    (array.array-set!
      (struct-get entry borrow)
      (struct-get entry index)
      (StringI64MapOccupied
        (struct-get entry key)
        value
        (struct-get entry hash)))
    unit))

;: A single iteration step: an occupied entry (its key and value) or none.
;: `string-i64-map-entry-at` returns `None` for an empty slot, a tombstone, or
;: an out-of-range index, and `Some` for a live entry.
(defenum StringI64MapEntry
  (StringI64MapEntryNone)
  (StringI64MapEntrySome String i64))

;: Scan `slots` from `index` forward for the first occupied slot, returning its
;: index or `capacity` when none remains. Bounded by `capacity` (the array
;: length), so it always terminates.
(define (string-i64-map-next-occupied-from
  [slots : (Array StringI64MapSlot)]
  [index : i64]
  [capacity : i64]) : i64
  (let
    [i : i64 index]
    (begin
      (while (< i capacity)
        (match (stdlib.hashmap.string-i64-map-slot-at slots i)
          [(StringI64MapOccupied _ _ _) (return i)]
          [(StringI64MapEmpty) (set! i (+ i 1))]
          [(StringI64MapTombstone) (set! i (+ i 1))]))
      capacity)))

;: Iteration cursor: the index of the first occupied slot at or after `from`
;: (in ascending bucket order), or the capacity when no live entry remains.
;: A negative `from` is clamped to 0.
;:
;: v1 iterates in *bucket order* - ascending slot index, skipping empty and
;: tombstone slots. This order is deterministic for a fixed table state but is
;: NOT insertion order, and it can change across a resize/rehash (#827). Walk
;: live entries by starting at `(string-i64-map-next-occupied map 0)` and
;: advancing with `(string-i64-map-next-occupied map (+ index 1))` until the
;: cursor reaches the capacity, reading each entry with
;: `string-i64-map-entry-at`. Do not insert into or remove from the map during
;: a walk: a resize rebuilds the slot array and invalidates live indices.
;: (Borrow-rule enforcement of this is revisited under #806.)
;:
;: ```typelisp
;: (import stdlib.hashmap)
;: (define (main) : i64
;:   (let
;:     [m : hashmap.StringI64Map
;:       (hashmap.string-i64-map-put
;:         (hashmap.string-i64-map-with-capacity 8)
;:         "k"
;:         42)]
;:     (hashmap.string-i64-map-next-occupied m 0)))
;: ```
(define (string-i64-map-next-occupied [map : StringI64Map] [from : i64]) : i64
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    (stdlib.hashmap.string-i64-map-next-occupied-from
      slots
      (if (< from 0)
        0
        from)
      (array.array-length slots))))

;: The live entry at `index`, or `None` for an empty slot, a tombstone, or an
;: index outside `[0, capacity)`. Pair with `string-i64-map-next-occupied` to
;: walk the map in bucket order. The key is handed back by value; v1 does not
;: yet enforce that the borrow outlives the map (revisited under #806).
(define (string-i64-map-entry-at [map : StringI64Map] [index : i64]) : StringI64MapEntry
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    (if (if (< index 0)
      true
      (>= index (array.array-length slots)))
      (StringI64MapEntryNone)
      (match (stdlib.hashmap.string-i64-map-slot-at slots index)
        [(StringI64MapOccupied key value _) (StringI64MapEntrySome key value)]
        [(StringI64MapEmpty) (StringI64MapEntryNone)]
        [(StringI64MapTombstone) (StringI64MapEntryNone)]))))

;: Reference variant of `string-i64-map-next-occupied`.
(define (string-i64-map-next-occupied-ref
  [map : (& map StringI64Map)]
  [from : i64]) : i64
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    [index : i64
      (if (< from 0)
        0
        from)]
    (begin
      (while (< index capacity)
        (match (array.array-ref (struct-get map slots) index)
          [(StringI64MapOccupied _ _ _) (return index)]
          [(StringI64MapEmpty) (set! index (+ index 1))]
          [(StringI64MapTombstone) (set! index (+ index 1))]))
      capacity)))

;: Reference variant of `string-i64-map-entry-at`.
(define (string-i64-map-entry-at-ref [map : (& map StringI64Map)] [index : i64]) : StringI64MapEntry
  (if (if (< index 0)
    true
    (>= index (array.array-length (struct-get map slots))))
    (StringI64MapEntryNone)
    (match (array.array-ref (struct-get map slots) index)
      [(StringI64MapOccupied key value _)
        (StringI64MapEntrySome (string.string-copy (& key)) value)]
      [(StringI64MapEmpty) (StringI64MapEntryNone)]
      [(StringI64MapTombstone) (StringI64MapEntryNone)])))

;: Checked-in `StringStringMap` base family.
(defenum StringStringMapSlot
  (StringStringMapEmpty)
  (StringStringMapTombstone)
  (StringStringMapOccupied String String i64))

;: Generated concrete hashmap family helper.
(defenum StringStringMapProbe
  (StringStringMapProbeFound i64)
  (StringStringMapProbeAbsent i64)
  (StringStringMapProbeFull))

;: Generated concrete hashmap family helper.
(define (string-string-map-hash-normalize [value : i64]) : i64
  (let
    [m : i64 2147483647]
    [raw : i64 (% value 2147483647)]
    (if (< raw 0)
      (+ raw m)
      raw)))

;: Generated concrete hashmap family helper.
(define (string-string-map-hash-key [key : (& key str)]) : i64
  (let
    [n : i64 (__tl_string_length key)]
    [i : i64 0]
    [hash : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            hash
            (%
              (+ (+ (* hash 131) (cast (__tl_string_ref key i) : i64)) 1)
              2147483647))
          (set! i (+ i 1))))
      hash)))

;: Generated concrete hashmap family helper.
(define (string-string-map-power-two-capacity? [capacity : i64]) : bool
  (if (> capacity 0)
    (= (bit-and capacity (- capacity 1)) 0)
    false))

;: Generated concrete hashmap family helper.
(define (string-string-map-round-capacity [capacity : i64]) : i64
  (let
    [rounded : i64 1]
    (begin
      (while (< rounded capacity)
        (set! rounded (* rounded 2)))
      rounded)))

;: Generated concrete hashmap family helper.
(define (string-string-map-normalized-bucket-index
  [hash : i64]
  [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

;: Generated concrete hashmap family helper.
(define (string-string-map-bucket-index [hash : i64] [capacity : i64]) : i64
  (string-string-map-normalized-bucket-index
    (string-string-map-hash-normalize hash)
    capacity))

;: Generated concrete hashmap family helper.
(define (string-string-map-next-index [index : i64] [capacity : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next capacity)
      0
      next)))

;: Generated concrete hashmap family helper.
(define (string-string-map-insert-slot
  [first-tombstone : i64]
  [empty-index : i64]) : i64
  (if (>= first-tombstone 0)
    first-tombstone
    empty-index))

;: Generated concrete hashmap family helper.
(define (string-string-map-key-eq?
  [left : (& left str)]
  [right : (& right str)]) : bool
  (__tl_string_eq left right))

;: Generated concrete hashmap family helper.
(define (string-string-map-probe-borrowed-from
  [slots : (Array StringStringMapSlot)]
  [capacity : i64]
  [key : (& key str)]
  [hash : i64]
  [index : i64]
  [steps : i64]
  [first-tombstone : i64]) : StringStringMapProbe
  (let
    [cursor : i64 index]
    [walked : i64 steps]
    [first : i64 first-tombstone]
    (begin
      (while (< walked capacity)
        (match (array-ref slots cursor)
          [(StringStringMapEmpty)
            (return
              (StringStringMapProbeAbsent
                (string-string-map-insert-slot first cursor)))]
          [(StringStringMapTombstone)
            (let
              [next : i64 (+ cursor 1)]
              (begin
                (if (< first 0)
                  (set! first cursor)
                  unit)
                (set!
                  cursor
                  (if (>= next capacity)
                    0
                    next))
                (set! walked (+ walked 1))))]
          [(StringStringMapOccupied slot-key _ slot-hash)
            (if (if (= slot-hash hash)
              (string-string-map-key-eq? (& slot-key) key)
              false)
              (return (StringStringMapProbeFound cursor))
              (let
                [next : i64 (+ cursor 1)]
                (begin
                  (set!
                    cursor
                    (if (>= next capacity)
                      0
                      next))
                  (set! walked (+ walked 1)))))]))
      (if (>= first 0)
        (StringStringMapProbeAbsent first)
        (StringStringMapProbeFull)))))

;: Generated concrete hashmap family helper.
(define (string-string-map-probe-borrowed
  [slots : (Array StringStringMapSlot)]
  [capacity : i64]
  [key : (& key str)]
  [hash : i64]) : StringStringMapProbe
  (if (<= capacity 0)
    (StringStringMapProbeFull)
    (string-string-map-probe-borrowed-from
      slots
      capacity
      key
      hash
      (string-string-map-normalized-bucket-index hash capacity)
      0
      -1)))

;: Generated concrete hashmap family helper.
(define (string-string-map-probe
  [slots : (Array StringStringMapSlot)]
  [capacity : i64]
  [key : String]
  [hash : i64]) : StringStringMapProbe
  (string-string-map-probe-borrowed slots capacity (& key) hash))

;: Generated concrete hashmap family helper.
(defstruct StringStringMap
  (slots (Array StringStringMapSlot))
  (len i64)
  (deleted i64))

;: Generated concrete hashmap family helper.
(defenum StringStringMapLookup
  (StringStringMapMissing)
  (StringStringMapFound String))

;: Generated concrete hashmap family helper.
(defenum StringStringMapBorrowedValueLookup
  (:lifetimes map)
  (StringStringMapBorrowedValueMissing)
  (StringStringMapBorrowedValueFound (& map str)))

;: Generated concrete hashmap family helper.
(defenum StringStringMapInsertResult
  (StringStringMapInsertOk StringStringMap)
  (StringStringMapInsertFull StringStringMap))

;: Generated concrete hashmap family helper.
(defenum StringStringMapRemoveResult
  (StringStringMapRemoveOk StringStringMap)
  (StringStringMapRemoveMissing StringStringMap))

;: Generated concrete hashmap family helper.
(defenum StringStringMapUpdateResult
  (StringStringMapUpdateOk StringStringMap)
  (StringStringMapUpdateMissing StringStringMap))

;: Generated concrete hashmap family helper.
(defenum StringStringMapEntryOrInsertResult
  (StringStringMapEntryOrInsertFound StringStringMap String)
  (StringStringMapEntryOrInsertInserted StringStringMap String))

;: Generated concrete hashmap family helper.
(defstruct StringStringMapMutEntryInfo
  (index i64)
  (present bool)
  (key String)
  (hash i64))

;: Generated concrete hashmap family helper.
(defstruct StringStringMapMutEntry
  (:lifetimes map)
  (slots (Array StringStringMapSlot))
  (borrow (&mut map (Array StringStringMapSlot)))
  (index i64)
  (present bool)
  (key String)
  (hash i64))

;: Generated concrete hashmap family helper.
(define (string-string-map-slots [map : StringStringMap]) : (Array
    StringStringMapSlot)
  (struct-get map slots))

;: Generated concrete hashmap family helper.
(define (string-string-map-len [map : StringStringMap]) : i64
  (struct-get map len))

;: Generated concrete hashmap family helper.
(define (string-string-map-capacity [map : StringStringMap]) : i64
  (array-length (struct-get map slots)))

;: Generated concrete hashmap family helper.
(define (string-string-map-deleted [map : StringStringMap]) : i64
  (struct-get map deleted))

;: Generated concrete hashmap family helper.
(define (string-string-map-fill-empty
  [slots : (Array StringStringMapSlot)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! slots index (StringStringMapEmpty))
      (string-string-map-fill-empty slots (+ index 1) count))))

;: Generated concrete hashmap family helper.
(define (string-string-map-with-capacity [capacity : i64]) : StringStringMap
  (let
    [rounded-capacity : i64 (string-string-map-round-capacity capacity)]
    [slots : (Array StringStringMapSlot)
      (make-array StringStringMapSlot rounded-capacity)]
    (begin
      (string-string-map-fill-empty slots 0 rounded-capacity)
      (StringStringMap slots 0 0))))

;: Generated concrete hashmap family helper.
(define (string-string-map-borrowed-value-missing
  [map : (& map StringStringMap)]) : (StringStringMapBorrowedValueLookup map)
  (StringStringMapBorrowedValueMissing))

;: Generated concrete hashmap family helper.
(define (string-string-map-borrowed-value-found [value : (& map str)]) : (StringStringMapBorrowedValueLookup
    map)
  (StringStringMapBorrowedValueFound value))

;: Generated concrete hashmap family helper.
(define (string-string-map-get-borrowed
  [map : StringStringMap]
  [key : (& key str)]) : StringStringMapLookup
  (let
    [slots : (Array StringStringMapSlot) (string-string-map-slots map)]
    (match (string-string-map-probe-borrowed
      slots
      (string-string-map-capacity map)
      key
      (string-string-map-hash-key key))
      [(StringStringMapProbeFound index)
        (match (array-ref slots index)
          [(StringStringMapOccupied _ value _) (StringStringMapFound value)]
          [(StringStringMapEmpty) (StringStringMapMissing)]
          [(StringStringMapTombstone) (StringStringMapMissing)])]
      [(StringStringMapProbeAbsent _) (StringStringMapMissing)]
      [(StringStringMapProbeFull) (StringStringMapMissing)])))

;: Generated concrete hashmap family helper.
(define (string-string-map-get [map : StringStringMap] [key : String]) : StringStringMapLookup
  (string-string-map-get-borrowed map (& key)))

;: Generated concrete hashmap family helper.
(define (string-string-map-get-value-borrowed
  [map : (& map StringStringMap)]
  [key : (& key str)]) : (StringStringMapBorrowedValueLookup map)
  (let
    [capacity : i64 (array-length (struct-get map slots))]
    (if (<= capacity 0)
      (string-string-map-borrowed-value-missing map)
      (let
        [hash : i64 (string-string-map-hash-key key)]
        [cursor : i64 (string-string-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array-ref (struct-get map slots) cursor)
              [(StringStringMapEmpty)
                (return (string-string-map-borrowed-value-missing map))]
              [(StringStringMapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringStringMapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (string-string-map-key-eq? (& slot-key) key)
                  false)
                  (match (& (array-ref (struct-get map slots) cursor))
                    [(StringStringMapOccupied _ value _)
                      (return (string-string-map-borrowed-value-found value))]
                    [(StringStringMapEmpty)
                      (return (string-string-map-borrowed-value-missing map))]
                    [(StringStringMapTombstone)
                      (return (string-string-map-borrowed-value-missing map))])
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (string-string-map-borrowed-value-missing map))))))

;: Generated concrete hashmap family helper.
(define (string-string-map-contains-borrowed?
  [map : StringStringMap]
  [key : (& key str)]) : bool
  (match (string-string-map-get-borrowed map key)
    [(StringStringMapFound _) true]
    [(StringStringMapMissing) false]))

;: Generated concrete hashmap family helper.
(define (string-string-map-contains? [map : StringStringMap] [key : String]) : bool
  (string-string-map-contains-borrowed? map (& key)))

;: Generated concrete hashmap family helper.
(define (string-string-map-slot-tombstone? [slot : StringStringMapSlot]) : bool
  (match slot
    [(StringStringMapTombstone) true]
    [(StringStringMapEmpty) false]
    [(StringStringMapOccupied _ _ _) false]))

;: Generated concrete hashmap family helper.
(define (string-string-map-insert
  [map : StringStringMap]
  [key : String]
  [value : String]) : StringStringMapInsertResult
  (let
    [slots : (Array StringStringMapSlot) (string-string-map-slots map)]
    [hash : i64 (string-string-map-hash-key (& key))]
    (match (string-string-map-probe-borrowed
      slots
      (string-string-map-capacity map)
      (& key)
      hash)
      [(StringStringMapProbeFound index)
        (begin
          (array-set! slots index (StringStringMapOccupied key value hash))
          (StringStringMapInsertOk map))]
      [(StringStringMapProbeAbsent index)
        (let
          [reused-tombstone : bool
            (string-string-map-slot-tombstone? (array-ref slots index))]
          (begin
            (array-set! slots index (StringStringMapOccupied key value hash))
            (set! (struct-get map len) (+ (string-string-map-len map) 1))
            (if reused-tombstone
              (set!
                (struct-get map deleted)
                (- (string-string-map-deleted map) 1))
              unit)
            (StringStringMapInsertOk map)))]
      [(StringStringMapProbeFull) (StringStringMapInsertFull map)])))

;: Generated concrete hashmap family helper.
(define (string-string-map-remove-borrowed
  [map : StringStringMap]
  [key : (& key str)]) : StringStringMapRemoveResult
  (let
    [slots : (Array StringStringMapSlot) (string-string-map-slots map)]
    (match (string-string-map-probe-borrowed
      slots
      (string-string-map-capacity map)
      key
      (string-string-map-hash-key key))
      [(StringStringMapProbeFound index)
        (begin
          (array-set! slots index (StringStringMapTombstone))
          (set! (struct-get map len) (- (string-string-map-len map) 1))
          (set! (struct-get map deleted) (+ (string-string-map-deleted map) 1))
          (StringStringMapRemoveOk map))]
      [(StringStringMapProbeAbsent _) (StringStringMapRemoveMissing map)]
      [(StringStringMapProbeFull) (StringStringMapRemoveMissing map)])))

;: Generated concrete hashmap family helper.
(define (string-string-map-remove [map : StringStringMap] [key : String]) : StringStringMapRemoveResult
  (string-string-map-remove-borrowed map (& key)))

;: Generated concrete hashmap family helper.
(define (string-string-map-update-borrowed-if-present
  [map : StringStringMap]
  [key : (& key str)]
  [value : String]) : StringStringMapUpdateResult
  (let
    [slots : (Array StringStringMapSlot) (string-string-map-slots map)]
    [hash : i64 (string-string-map-hash-key key)]
    (match (string-string-map-probe-borrowed
      slots
      (string-string-map-capacity map)
      key
      hash)
      [(StringStringMapProbeFound index)
        (match (array-ref slots index)
          [(StringStringMapOccupied slot-key _ slot-hash)
            (begin
              (array-set!
                slots
                index
                (StringStringMapOccupied slot-key value slot-hash))
              (StringStringMapUpdateOk map))]
          [(StringStringMapEmpty) (StringStringMapUpdateMissing map)]
          [(StringStringMapTombstone) (StringStringMapUpdateMissing map)])]
      [(StringStringMapProbeAbsent _) (StringStringMapUpdateMissing map)]
      [(StringStringMapProbeFull) (StringStringMapUpdateMissing map)])))

;: Generated concrete hashmap family helper.
(define (string-string-map-update-if-present
  [map : StringStringMap]
  [key : String]
  [value : String]) : StringStringMapUpdateResult
  (string-string-map-update-borrowed-if-present map (& key) value))

;: Generated concrete hashmap family helper.
(define (string-string-map-insert-into-empty
  [slots : (Array StringStringMapSlot)]
  [capacity : i64]
  [key : String]
  [value : String]
  [hash : i64]) : unit
  (if (<= capacity 0)
    unit
    (let
      [cursor : i64 (string-string-map-normalized-bucket-index hash capacity)]
      [walked : i64 0]
      [done : bool false]
      (begin
        (while (if done
          false
          (< walked capacity))
          (match (array-ref slots cursor)
            [(StringStringMapEmpty)
              (begin
                (array-set!
                  slots
                  cursor
                  (StringStringMapOccupied key value hash))
                (set! done true))]
            [_
              (begin
                (set! cursor (string-string-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        unit))))

;: Generated concrete hashmap family helper.
(define (string-string-map-rehash-from
  [src : (Array StringStringMapSlot)]
  [dst : (Array StringStringMapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (match (array-ref src index)
        [(StringStringMapOccupied key value hash)
          (string-string-map-insert-into-empty dst dst-capacity key value hash)]
        [(StringStringMapEmpty) unit]
        [(StringStringMapTombstone) unit])
      (string-string-map-rehash-from src dst dst-capacity (+ index 1) count))))

;: Generated concrete hashmap family helper.
(define (string-string-map-resized [map : StringStringMap] [new-capacity : i64]) : StringStringMap
  (let
    [src : (Array StringStringMapSlot) (string-string-map-slots map)]
    [old-capacity : i64 (string-string-map-capacity map)]
    [requested-capacity : i64
      (if (> (string-string-map-len map) new-capacity)
        (string-string-map-len map)
        new-capacity)]
    [rounded-capacity : i64
      (string-string-map-round-capacity requested-capacity)]
    [dst : (Array StringStringMapSlot)
      (make-array StringStringMapSlot rounded-capacity)]
    (begin
      (string-string-map-fill-empty dst 0 rounded-capacity)
      (string-string-map-rehash-from src dst rounded-capacity 0 old-capacity)
      (set! (struct-get map slots) dst)
      (set! (struct-get map deleted) 0)
      map)))

;: Generated concrete hashmap family helper.
(define (string-string-map-grow-capacity [capacity : i64]) : i64
  (if (< capacity 4)
    8
    (* (string-string-map-round-capacity capacity) 2)))

;: Generated concrete hashmap family helper.
(define (string-string-map-grow [map : StringStringMap]) : StringStringMap
  (string-string-map-resized
    map
    (string-string-map-grow-capacity (string-string-map-capacity map))))

;: Generated concrete hashmap family helper.
(define (string-string-map-needs-grow? [map : StringStringMap]) : bool
  (let
    [capacity : i64 (string-string-map-capacity map)]
    [used : i64 (+ (string-string-map-len map) (string-string-map-deleted map))]
    (if (<= capacity 0)
      true
      (>= (* used 4) (* capacity 3)))))

;: Generated concrete hashmap family helper.
(define (string-string-map-put
  [map : StringStringMap]
  [key : String]
  [value : String]) : StringStringMap
  (let
    [grown : StringStringMap
      (if (string-string-map-needs-grow? map)
        (string-string-map-grow map)
        map)]
    (match (string-string-map-insert grown key value)
      [(StringStringMapInsertOk updated) updated]
      [(StringStringMapInsertFull full)
        (match (string-string-map-insert
          (string-string-map-grow full)
          key
          value)
          [(StringStringMapInsertOk u) u]
          [(StringStringMapInsertFull u) u])])))

;: Generated concrete hashmap family helper.
(define (string-string-map-insert-or-update
  [map : StringStringMap]
  [key : String]
  [value : String]) : StringStringMap
  (string-string-map-put map key value))

;: Generated concrete hashmap family helper.
(define (string-string-map-entry-or-insert
  [map : StringStringMap]
  [key : String]
  [default-value : String]) : StringStringMapEntryOrInsertResult
  (let
    [slots : (Array StringStringMapSlot) (string-string-map-slots map)]
    [hash : i64 (string-string-map-hash-key (& key))]
    (match (string-string-map-probe-borrowed
      slots
      (string-string-map-capacity map)
      (& key)
      hash)
      [(StringStringMapProbeFound index)
        (match (array-ref slots index)
          [(StringStringMapOccupied _ value _)
            (StringStringMapEntryOrInsertFound map value)]
          [(StringStringMapEmpty)
            (let
              [updated : StringStringMap
                (string-string-map-put map key default-value)]
              (StringStringMapEntryOrInsertInserted updated default-value))]
          [(StringStringMapTombstone)
            (let
              [updated : StringStringMap
                (string-string-map-put map key default-value)]
              (StringStringMapEntryOrInsertInserted updated default-value))])]
      [(StringStringMapProbeAbsent _)
        (let
          [updated : StringStringMap
            (string-string-map-put map key default-value)]
          (StringStringMapEntryOrInsertInserted updated default-value))]
      [(StringStringMapProbeFull)
        (let
          [updated : StringStringMap
            (string-string-map-put map key default-value)]
          (StringStringMapEntryOrInsertInserted updated default-value))])))

;: Generated concrete hashmap family helper.
(define (string-string-map-mut-entry-info
  [slots : (Array StringStringMapSlot)]
  [capacity : i64]
  [key : (& key str)]) : StringStringMapMutEntryInfo
  (if (<= capacity 0)
    (StringStringMapMutEntryInfo -1 false "" 0)
    (let
      [hash : i64 (string-string-map-hash-key key)]
      [cursor : i64 (string-string-map-bucket-index hash capacity)]
      [walked : i64 0]
      [found : i64 -1]
      [present : bool false]
      [entry-key : String ""]
      [entry-hash : i64 0]
      [done : bool false]
      (begin
        (while (if (< walked capacity)
          (not done)
          false)
          (match (array-ref slots cursor)
            [(StringStringMapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (string-string-map-key-eq? (& slot-key) key)
                false)
                (begin
                  (set! found cursor)
                  (set! present true)
                  (set! entry-key slot-key)
                  (set! entry-hash slot-hash)
                  (set! done true))
                (begin
                  (set! cursor (string-string-map-next-index cursor capacity))
                  (set! walked (+ walked 1))))]
            [(StringStringMapEmpty) (set! done true)]
            [(StringStringMapTombstone)
              (begin
                (set! cursor (string-string-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        (StringStringMapMutEntryInfo found present entry-key entry-hash)))))

;: Generated concrete hashmap family helper.
(define (string-string-map-mut-entry-from-info
  [info : StringStringMapMutEntryInfo]
  [slots : (Array StringStringMapSlot)]
  [borrow : (&mut map (Array StringStringMapSlot))]) : (StringStringMapMutEntry
    map)
  (StringStringMapMutEntry
    slots
    borrow
    (struct-get info index)
    (struct-get info present)
    (struct-get info key)
    (struct-get info hash)))

;: Generated concrete hashmap family helper.
(defmacro (string-string-map-get-mut-entry-borrowed [map : Expr] [key : Expr]) : Expr
  `(string-string-map-mut-entry-from-info
    (string-string-map-mut-entry-info
      (struct-get ,map slots)
      (array-length (struct-get ,map slots))
      ,key)
    (struct-get ,map slots)
    (&mut (struct-get ,map slots))))

;: Generated concrete hashmap family helper.
(define (string-string-map-mut-entry-present?
  [entry : (StringStringMapMutEntry map)]) : bool
  (struct-get entry present))

;: Generated concrete hashmap family helper.
(define (string-string-map-mut-entry-value-or
  [entry : (StringStringMapMutEntry map)]
  [fallback : String]) : String
  (if (string-string-map-mut-entry-present? entry)
    (match (array-ref (struct-get entry slots) (struct-get entry index))
      [(StringStringMapOccupied _ value _) value]
      [(StringStringMapEmpty) fallback]
      [(StringStringMapTombstone) fallback])
    fallback))

;: Generated concrete hashmap family helper.
(define (string-string-map-mut-entry-set!
  [entry : (StringStringMapMutEntry map)]
  [value : String]) : unit
  (if (string-string-map-mut-entry-present? entry)
    (array-set!
      (struct-get entry slots)
      (struct-get entry index)
      (StringStringMapOccupied
        (struct-get entry key)
        value
        (struct-get entry hash)))
    unit))

;: Generated concrete hashmap family helper.
(defenum StringStringMapEntry
  (StringStringMapEntryNone)
  (StringStringMapEntrySome String String))

;: Generated concrete hashmap family helper.
(define (string-string-map-next-occupied-from
  [slots : (Array StringStringMapSlot)]
  [index : i64]
  [capacity : i64]) : i64
  (if (>= index capacity)
    capacity
    (match (array-ref slots index)
      [(StringStringMapOccupied _ _ _) index]
      [(StringStringMapEmpty)
        (string-string-map-next-occupied-from slots (+ index 1) capacity)]
      [(StringStringMapTombstone)
        (string-string-map-next-occupied-from slots (+ index 1) capacity)])))

;: Generated concrete hashmap family helper.
(define (string-string-map-next-occupied [map : StringStringMap] [from : i64]) : i64
  (string-string-map-next-occupied-from
    (string-string-map-slots map)
    (if (< from 0)
      0
      from)
    (string-string-map-capacity map)))

;: Generated concrete hashmap family helper.
(define (string-string-map-entry-at [map : StringStringMap] [index : i64]) : StringStringMapEntry
  (if (if (< index 0)
    true
    (>= index (string-string-map-capacity map)))
    (StringStringMapEntryNone)
    (match (array-ref (string-string-map-slots map) index)
      [(StringStringMapOccupied key value _)
        (StringStringMapEntrySome key value)]
      [(StringStringMapEmpty) (StringStringMapEntryNone)]
      [(StringStringMapTombstone) (StringStringMapEntryNone)])))

;: Checked-in `I64I64Map` base family.
(defenum I64I64MapSlot
  (I64I64MapEmpty)
  (I64I64MapTombstone)
  (I64I64MapOccupied i64 i64 i64))

;: Generated concrete hashmap family helper.
(defenum I64I64MapProbe
  (I64I64MapProbeFound i64)
  (I64I64MapProbeAbsent i64)
  (I64I64MapProbeFull))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-hash-normalize [value : i64]) : i64
  (let
    [m : i64 2147483647]
    [raw : i64 (% value 2147483647)]
    (if (< raw 0)
      (+ raw m)
      raw)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-hash-key [key : i64]) : i64
  (i64-i64-map-hash-normalize (* key 6364136223846793005)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-power-two-capacity? [capacity : i64]) : bool
  (if (> capacity 0)
    (= (bit-and capacity (- capacity 1)) 0)
    false))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-round-capacity [capacity : i64]) : i64
  (let
    [rounded : i64 1]
    (begin
      (while (< rounded capacity)
        (set! rounded (* rounded 2)))
      rounded)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-normalized-bucket-index [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-bucket-index [hash : i64] [capacity : i64]) : i64
  (i64-i64-map-normalized-bucket-index
    (i64-i64-map-hash-normalize hash)
    capacity))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-next-index [index : i64] [capacity : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next capacity)
      0
      next)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-insert-slot [first-tombstone : i64] [empty-index : i64]) : i64
  (if (>= first-tombstone 0)
    first-tombstone
    empty-index))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-probe-from
  [slots : (Array I64I64MapSlot)]
  [capacity : i64]
  [key : i64]
  [hash : i64]
  [index : i64]
  [steps : i64]
  [first-tombstone : i64]) : I64I64MapProbe
  (let
    [cursor : i64 index]
    [walked : i64 steps]
    [first : i64 first-tombstone]
    (begin
      (while (< walked capacity)
        (match (array-ref slots cursor)
          [(I64I64MapEmpty)
            (return
              (I64I64MapProbeAbsent (i64-i64-map-insert-slot first cursor)))]
          [(I64I64MapTombstone)
            (let
              [next : i64 (+ cursor 1)]
              (begin
                (if (< first 0)
                  (set! first cursor)
                  unit)
                (set!
                  cursor
                  (if (>= next capacity)
                    0
                    next))
                (set! walked (+ walked 1))))]
          [(I64I64MapOccupied slot-key _ slot-hash)
            (if (if (= slot-hash hash)
              (= slot-key key)
              false)
              (return (I64I64MapProbeFound cursor))
              (let
                [next : i64 (+ cursor 1)]
                (begin
                  (set!
                    cursor
                    (if (>= next capacity)
                      0
                      next))
                  (set! walked (+ walked 1)))))]))
      (if (>= first 0)
        (I64I64MapProbeAbsent first)
        (I64I64MapProbeFull)))))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-probe
  [slots : (Array I64I64MapSlot)]
  [capacity : i64]
  [key : i64]
  [hash : i64]) : I64I64MapProbe
  (if (<= capacity 0)
    (I64I64MapProbeFull)
    (i64-i64-map-probe-from
      slots
      capacity
      key
      hash
      (i64-i64-map-normalized-bucket-index hash capacity)
      0
      -1)))

;: Generated concrete hashmap family helper.
(defstruct I64I64Map
  (slots (Array I64I64MapSlot))
  (len i64)
  (deleted i64))

;: Generated concrete hashmap family helper.
(defenum I64I64MapLookup
  (I64I64MapMissing)
  (I64I64MapFound i64))

;: Generated concrete hashmap family helper.
(defenum I64I64MapBorrowedValueLookup
  (:lifetimes map)
  (I64I64MapBorrowedValueMissing)
  (I64I64MapBorrowedValueFound (& map i64)))

;: Generated concrete hashmap family helper.
(defenum I64I64MapInsertResult
  (I64I64MapInsertOk I64I64Map)
  (I64I64MapInsertFull I64I64Map))

;: Generated concrete hashmap family helper.
(defenum I64I64MapRemoveResult
  (I64I64MapRemoveOk I64I64Map)
  (I64I64MapRemoveMissing I64I64Map))

;: Generated concrete hashmap family helper.
(defenum I64I64MapUpdateResult
  (I64I64MapUpdateOk I64I64Map)
  (I64I64MapUpdateMissing I64I64Map))

;: Generated concrete hashmap family helper.
(defenum I64I64MapEntryOrInsertResult
  (I64I64MapEntryOrInsertFound I64I64Map i64)
  (I64I64MapEntryOrInsertInserted I64I64Map i64))

;: Generated concrete hashmap family helper.
(defstruct I64I64MapMutEntryInfo
  (index i64)
  (present bool)
  (key i64)
  (hash i64))

;: Generated concrete hashmap family helper.
(defstruct I64I64MapMutEntry
  (:lifetimes map)
  (slots (Array I64I64MapSlot))
  (borrow (&mut map (Array I64I64MapSlot)))
  (index i64)
  (present bool)
  (key i64)
  (hash i64))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-slots [map : I64I64Map]) : (Array I64I64MapSlot)
  (struct-get map slots))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-len [map : I64I64Map]) : i64
  (struct-get map len))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-capacity [map : I64I64Map]) : i64
  (array-length (struct-get map slots)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-deleted [map : I64I64Map]) : i64
  (struct-get map deleted))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-fill-empty
  [slots : (Array I64I64MapSlot)]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (begin
      (while (< i count)
        (begin
          (array-set! slots i (I64I64MapEmpty))
          (set! i (+ i 1))))
      unit)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-with-capacity [capacity : i64]) : I64I64Map
  (let
    [rounded-capacity : i64 (i64-i64-map-round-capacity capacity)]
    [slots : (Array I64I64MapSlot) (make-array I64I64MapSlot rounded-capacity)]
    (begin
      (i64-i64-map-fill-empty slots 0 rounded-capacity)
      (I64I64Map slots 0 0))))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-borrowed-value-missing [map : (& map I64I64Map)]) : (I64I64MapBorrowedValueLookup
    map)
  (I64I64MapBorrowedValueMissing))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-borrowed-value-found [value : (& map i64)]) : (I64I64MapBorrowedValueLookup
    map)
  (I64I64MapBorrowedValueFound value))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-get [map : I64I64Map] [key : i64]) : I64I64MapLookup
  (let
    [slots : (Array I64I64MapSlot) (i64-i64-map-slots map)]
    (match (i64-i64-map-probe
      slots
      (i64-i64-map-capacity map)
      key
      (i64-i64-map-hash-key key))
      [(I64I64MapProbeFound index)
        (match (array-ref slots index)
          [(I64I64MapOccupied _ value _) (I64I64MapFound value)]
          [(I64I64MapEmpty) (I64I64MapMissing)]
          [(I64I64MapTombstone) (I64I64MapMissing)])]
      [(I64I64MapProbeAbsent _) (I64I64MapMissing)]
      [(I64I64MapProbeFull) (I64I64MapMissing)])))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-get-value-borrowed [map : (& map I64I64Map)] [key : i64]) : (I64I64MapBorrowedValueLookup
    map)
  (let
    [capacity : i64 (array-length (struct-get map slots))]
    (if (<= capacity 0)
      (i64-i64-map-borrowed-value-missing map)
      (let
        [hash : i64 (i64-i64-map-hash-key key)]
        [cursor : i64 (i64-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array-ref (struct-get map slots) cursor)
              [(I64I64MapEmpty)
                (return (i64-i64-map-borrowed-value-missing map))]
              [(I64I64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(I64I64MapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (= slot-key key)
                  false)
                  (match (& (array-ref (struct-get map slots) cursor))
                    [(I64I64MapOccupied _ value _)
                      (return (i64-i64-map-borrowed-value-found value))]
                    [(I64I64MapEmpty)
                      (return (i64-i64-map-borrowed-value-missing map))]
                    [(I64I64MapTombstone)
                      (return (i64-i64-map-borrowed-value-missing map))])
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (i64-i64-map-borrowed-value-missing map))))))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-contains? [map : I64I64Map] [key : i64]) : bool
  (match (i64-i64-map-get map key)
    [(I64I64MapFound _) true]
    [(I64I64MapMissing) false]))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-slot-tombstone? [slot : I64I64MapSlot]) : bool
  (match slot
    [(I64I64MapTombstone) true]
    [(I64I64MapEmpty) false]
    [(I64I64MapOccupied _ _ _) false]))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-insert [map : I64I64Map] [key : i64] [value : i64]) : I64I64MapInsertResult
  (let
    [slots : (Array I64I64MapSlot) (i64-i64-map-slots map)]
    [hash : i64 (i64-i64-map-hash-key key)]
    (match (i64-i64-map-probe slots (i64-i64-map-capacity map) key hash)
      [(I64I64MapProbeFound index)
        (begin
          (array-set! slots index (I64I64MapOccupied key value hash))
          (I64I64MapInsertOk map))]
      [(I64I64MapProbeAbsent index)
        (let
          [reused-tombstone : bool
            (i64-i64-map-slot-tombstone? (array-ref slots index))]
          (begin
            (array-set! slots index (I64I64MapOccupied key value hash))
            (set! (struct-get map len) (+ (i64-i64-map-len map) 1))
            (if reused-tombstone
              (set! (struct-get map deleted) (- (i64-i64-map-deleted map) 1))
              unit)
            (I64I64MapInsertOk map)))]
      [(I64I64MapProbeFull) (I64I64MapInsertFull map)])))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-remove [map : I64I64Map] [key : i64]) : I64I64MapRemoveResult
  (let
    [slots : (Array I64I64MapSlot) (i64-i64-map-slots map)]
    (match (i64-i64-map-probe
      slots
      (i64-i64-map-capacity map)
      key
      (i64-i64-map-hash-key key))
      [(I64I64MapProbeFound index)
        (begin
          (array-set! slots index (I64I64MapTombstone))
          (set! (struct-get map len) (- (i64-i64-map-len map) 1))
          (set! (struct-get map deleted) (+ (i64-i64-map-deleted map) 1))
          (I64I64MapRemoveOk map))]
      [(I64I64MapProbeAbsent _) (I64I64MapRemoveMissing map)]
      [(I64I64MapProbeFull) (I64I64MapRemoveMissing map)])))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-update-if-present
  [map : I64I64Map]
  [key : i64]
  [value : i64]) : I64I64MapUpdateResult
  (let
    [slots : (Array I64I64MapSlot) (i64-i64-map-slots map)]
    [hash : i64 (i64-i64-map-hash-key key)]
    (match (i64-i64-map-probe slots (i64-i64-map-capacity map) key hash)
      [(I64I64MapProbeFound index)
        (match (array-ref slots index)
          [(I64I64MapOccupied slot-key _ slot-hash)
            (begin
              (array-set!
                slots
                index
                (I64I64MapOccupied slot-key value slot-hash))
              (I64I64MapUpdateOk map))]
          [(I64I64MapEmpty) (I64I64MapUpdateMissing map)]
          [(I64I64MapTombstone) (I64I64MapUpdateMissing map)])]
      [(I64I64MapProbeAbsent _) (I64I64MapUpdateMissing map)]
      [(I64I64MapProbeFull) (I64I64MapUpdateMissing map)])))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-insert-into-empty
  [slots : (Array I64I64MapSlot)]
  [capacity : i64]
  [key : i64]
  [value : i64]
  [hash : i64]) : unit
  (if (<= capacity 0)
    unit
    (let
      [cursor : i64 (i64-i64-map-normalized-bucket-index hash capacity)]
      [walked : i64 0]
      [done : bool false]
      (begin
        (while (if done
          false
          (< walked capacity))
          (match (array-ref slots cursor)
            [(I64I64MapEmpty)
              (begin
                (array-set! slots cursor (I64I64MapOccupied key value hash))
                (set! done true))]
            [_
              (begin
                (set! cursor (i64-i64-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        unit))))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-rehash-from
  [src : (Array I64I64MapSlot)]
  [dst : (Array I64I64MapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (begin
      (while (< i count)
        (begin
          (match (array-ref src i)
            [(I64I64MapOccupied key value hash)
              (i64-i64-map-insert-into-empty dst dst-capacity key value hash)]
            [(I64I64MapEmpty) unit]
            [(I64I64MapTombstone) unit])
          (set! i (+ i 1))))
      unit)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-resized [map : I64I64Map] [new-capacity : i64]) : I64I64Map
  (let
    [src : (Array I64I64MapSlot) (i64-i64-map-slots map)]
    [old-capacity : i64 (i64-i64-map-capacity map)]
    [requested-capacity : i64
      (if (> (i64-i64-map-len map) new-capacity)
        (i64-i64-map-len map)
        new-capacity)]
    [rounded-capacity : i64 (i64-i64-map-round-capacity requested-capacity)]
    [dst : (Array I64I64MapSlot) (make-array I64I64MapSlot rounded-capacity)]
    (begin
      (i64-i64-map-fill-empty dst 0 rounded-capacity)
      (i64-i64-map-rehash-from src dst rounded-capacity 0 old-capacity)
      (set! (struct-get map slots) dst)
      (set! (struct-get map deleted) 0)
      map)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-grow-capacity [capacity : i64]) : i64
  (if (< capacity 4)
    8
    (* (i64-i64-map-round-capacity capacity) 2)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-grow [map : I64I64Map]) : I64I64Map
  (i64-i64-map-resized
    map
    (i64-i64-map-grow-capacity (i64-i64-map-capacity map))))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-needs-grow? [map : I64I64Map]) : bool
  (let
    [capacity : i64 (i64-i64-map-capacity map)]
    [used : i64 (+ (i64-i64-map-len map) (i64-i64-map-deleted map))]
    (if (<= capacity 0)
      true
      (>= (* used 4) (* capacity 3)))))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-put [map : I64I64Map] [key : i64] [value : i64]) : I64I64Map
  (let
    [grown : I64I64Map
      (if (i64-i64-map-needs-grow? map)
        (i64-i64-map-grow map)
        map)]
    (match (i64-i64-map-insert grown key value)
      [(I64I64MapInsertOk updated) updated]
      [(I64I64MapInsertFull full)
        (match (i64-i64-map-insert (i64-i64-map-grow full) key value)
          [(I64I64MapInsertOk u) u]
          [(I64I64MapInsertFull u) u])])))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-insert-or-update
  [map : I64I64Map]
  [key : i64]
  [value : i64]) : I64I64Map
  (i64-i64-map-put map key value))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-entry-or-insert
  [map : I64I64Map]
  [key : i64]
  [default-value : i64]) : I64I64MapEntryOrInsertResult
  (let
    [slots : (Array I64I64MapSlot) (i64-i64-map-slots map)]
    [hash : i64 (i64-i64-map-hash-key key)]
    (match (i64-i64-map-probe slots (i64-i64-map-capacity map) key hash)
      [(I64I64MapProbeFound index)
        (match (array-ref slots index)
          [(I64I64MapOccupied _ value _)
            (I64I64MapEntryOrInsertFound map value)]
          [(I64I64MapEmpty)
            (let
              [updated : I64I64Map (i64-i64-map-put map key default-value)]
              (I64I64MapEntryOrInsertInserted updated default-value))]
          [(I64I64MapTombstone)
            (let
              [updated : I64I64Map (i64-i64-map-put map key default-value)]
              (I64I64MapEntryOrInsertInserted updated default-value))])]
      [(I64I64MapProbeAbsent _)
        (let
          [updated : I64I64Map (i64-i64-map-put map key default-value)]
          (I64I64MapEntryOrInsertInserted updated default-value))]
      [(I64I64MapProbeFull)
        (let
          [updated : I64I64Map (i64-i64-map-put map key default-value)]
          (I64I64MapEntryOrInsertInserted updated default-value))])))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-mut-entry-info
  [slots : (Array I64I64MapSlot)]
  [capacity : i64]
  [key : i64]) : I64I64MapMutEntryInfo
  (if (<= capacity 0)
    (I64I64MapMutEntryInfo -1 false 0 0)
    (let
      [hash : i64 (i64-i64-map-hash-key key)]
      [cursor : i64 (i64-i64-map-bucket-index hash capacity)]
      [walked : i64 0]
      [found : i64 -1]
      [present : bool false]
      [entry-key : i64 0]
      [entry-hash : i64 0]
      [done : bool false]
      (begin
        (while (if (< walked capacity)
          (not done)
          false)
          (match (array-ref slots cursor)
            [(I64I64MapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (= slot-key key)
                false)
                (begin
                  (set! found cursor)
                  (set! present true)
                  (set! entry-key slot-key)
                  (set! entry-hash slot-hash)
                  (set! done true))
                (begin
                  (set! cursor (i64-i64-map-next-index cursor capacity))
                  (set! walked (+ walked 1))))]
            [(I64I64MapEmpty) (set! done true)]
            [(I64I64MapTombstone)
              (begin
                (set! cursor (i64-i64-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        (I64I64MapMutEntryInfo found present entry-key entry-hash)))))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-mut-entry-from-info
  [info : I64I64MapMutEntryInfo]
  [slots : (Array I64I64MapSlot)]
  [borrow : (&mut map (Array I64I64MapSlot))]) : (I64I64MapMutEntry map)
  (I64I64MapMutEntry
    slots
    borrow
    (struct-get info index)
    (struct-get info present)
    (struct-get info key)
    (struct-get info hash)))

;: Generated concrete hashmap family helper.
(defmacro (i64-i64-map-get-mut-entry [map : Expr] [key : Expr]) : Expr
  `(i64-i64-map-mut-entry-from-info
    (i64-i64-map-mut-entry-info
      (struct-get ,map slots)
      (array-length (struct-get ,map slots))
      ,key)
    (struct-get ,map slots)
    (&mut (struct-get ,map slots))))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-mut-entry-present? [entry : (I64I64MapMutEntry map)]) : bool
  (struct-get entry present))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-mut-entry-value-or
  [entry : (I64I64MapMutEntry map)]
  [fallback : i64]) : i64
  (if (i64-i64-map-mut-entry-present? entry)
    (match (array-ref (struct-get entry slots) (struct-get entry index))
      [(I64I64MapOccupied _ value _) value]
      [(I64I64MapEmpty) fallback]
      [(I64I64MapTombstone) fallback])
    fallback))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-mut-entry-set!
  [entry : (I64I64MapMutEntry map)]
  [value : i64]) : unit
  (if (i64-i64-map-mut-entry-present? entry)
    (array-set!
      (struct-get entry slots)
      (struct-get entry index)
      (I64I64MapOccupied (struct-get entry key) value (struct-get entry hash)))
    unit))

;: Generated concrete hashmap family helper.
(defenum I64I64MapEntry
  (I64I64MapEntryNone)
  (I64I64MapEntrySome i64 i64))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-next-occupied-from
  [slots : (Array I64I64MapSlot)]
  [index : i64]
  [capacity : i64]) : i64
  (let
    [i : i64 index]
    (begin
      (while (< i capacity)
        (match (array-ref slots i)
          [(I64I64MapOccupied _ _ _) (return i)]
          [(I64I64MapEmpty) (set! i (+ i 1))]
          [(I64I64MapTombstone) (set! i (+ i 1))]))
      capacity)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-next-occupied [map : I64I64Map] [from : i64]) : i64
  (i64-i64-map-next-occupied-from
    (i64-i64-map-slots map)
    (if (< from 0)
      0
      from)
    (i64-i64-map-capacity map)))

;: Generated concrete hashmap family helper.
(define (i64-i64-map-entry-at [map : I64I64Map] [index : i64]) : I64I64MapEntry
  (if (if (< index 0)
    true
    (>= index (i64-i64-map-capacity map)))
    (I64I64MapEntryNone)
    (match (array-ref (i64-i64-map-slots map) index)
      [(I64I64MapOccupied key value _) (I64I64MapEntrySome key value)]
      [(I64I64MapEmpty) (I64I64MapEntryNone)]
      [(I64I64MapTombstone) (I64I64MapEntryNone)])))

;: Checked-in `I64StringMap` base family.
(defenum I64StringMapSlot
  (I64StringMapEmpty)
  (I64StringMapTombstone)
  (I64StringMapOccupied i64 String i64))

;: Generated concrete hashmap family helper.
(defenum I64StringMapProbe
  (I64StringMapProbeFound i64)
  (I64StringMapProbeAbsent i64)
  (I64StringMapProbeFull))

;: Generated concrete hashmap family helper.
(define (i64-string-map-hash-normalize [value : i64]) : i64
  (let
    [m : i64 2147483647]
    [raw : i64 (% value 2147483647)]
    (if (< raw 0)
      (+ raw m)
      raw)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-hash-key [key : i64]) : i64
  (i64-string-map-hash-normalize (* key 6364136223846793005)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-power-two-capacity? [capacity : i64]) : bool
  (if (> capacity 0)
    (= (bit-and capacity (- capacity 1)) 0)
    false))

;: Generated concrete hashmap family helper.
(define (i64-string-map-round-capacity [capacity : i64]) : i64
  (let
    [rounded : i64 1]
    (begin
      (while (< rounded capacity)
        (set! rounded (* rounded 2)))
      rounded)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-normalized-bucket-index [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-bucket-index [hash : i64] [capacity : i64]) : i64
  (i64-string-map-normalized-bucket-index
    (i64-string-map-hash-normalize hash)
    capacity))

;: Generated concrete hashmap family helper.
(define (i64-string-map-next-index [index : i64] [capacity : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next capacity)
      0
      next)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-insert-slot [first-tombstone : i64] [empty-index : i64]) : i64
  (if (>= first-tombstone 0)
    first-tombstone
    empty-index))

;: Generated concrete hashmap family helper.
(define (i64-string-map-probe-from
  [slots : (Array I64StringMapSlot)]
  [capacity : i64]
  [key : i64]
  [hash : i64]
  [index : i64]
  [steps : i64]
  [first-tombstone : i64]) : I64StringMapProbe
  (let
    [cursor : i64 index]
    [walked : i64 steps]
    [first : i64 first-tombstone]
    (begin
      (while (< walked capacity)
        (match (array-ref slots cursor)
          [(I64StringMapEmpty)
            (return
              (I64StringMapProbeAbsent
                (i64-string-map-insert-slot first cursor)))]
          [(I64StringMapTombstone)
            (let
              [next : i64 (+ cursor 1)]
              (begin
                (if (< first 0)
                  (set! first cursor)
                  unit)
                (set!
                  cursor
                  (if (>= next capacity)
                    0
                    next))
                (set! walked (+ walked 1))))]
          [(I64StringMapOccupied slot-key _ slot-hash)
            (if (if (= slot-hash hash)
              (= slot-key key)
              false)
              (return (I64StringMapProbeFound cursor))
              (let
                [next : i64 (+ cursor 1)]
                (begin
                  (set!
                    cursor
                    (if (>= next capacity)
                      0
                      next))
                  (set! walked (+ walked 1)))))]))
      (if (>= first 0)
        (I64StringMapProbeAbsent first)
        (I64StringMapProbeFull)))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-probe
  [slots : (Array I64StringMapSlot)]
  [capacity : i64]
  [key : i64]
  [hash : i64]) : I64StringMapProbe
  (if (<= capacity 0)
    (I64StringMapProbeFull)
    (i64-string-map-probe-from
      slots
      capacity
      key
      hash
      (i64-string-map-normalized-bucket-index hash capacity)
      0
      -1)))

;: Generated concrete hashmap family helper.
(defstruct I64StringMap
  (slots (Array I64StringMapSlot))
  (len i64)
  (deleted i64))

;: Generated concrete hashmap family helper.
(defenum I64StringMapLookup
  (I64StringMapMissing)
  (I64StringMapFound String))

;: Generated concrete hashmap family helper.
(defenum I64StringMapBorrowedValueLookup
  (:lifetimes map)
  (I64StringMapBorrowedValueMissing)
  (I64StringMapBorrowedValueFound (& map str)))

;: Generated concrete hashmap family helper.
(defenum I64StringMapInsertResult
  (I64StringMapInsertOk I64StringMap)
  (I64StringMapInsertFull I64StringMap))

;: Generated concrete hashmap family helper.
(defenum I64StringMapRemoveResult
  (I64StringMapRemoveOk I64StringMap)
  (I64StringMapRemoveMissing I64StringMap))

;: Generated concrete hashmap family helper.
(defenum I64StringMapUpdateResult
  (I64StringMapUpdateOk I64StringMap)
  (I64StringMapUpdateMissing I64StringMap))

;: Generated concrete hashmap family helper.
(defenum I64StringMapEntryOrInsertResult
  (I64StringMapEntryOrInsertFound I64StringMap String)
  (I64StringMapEntryOrInsertInserted I64StringMap String))

;: Generated concrete hashmap family helper.
(defstruct I64StringMapMutEntryInfo
  (index i64)
  (present bool)
  (key i64)
  (hash i64))

;: Generated concrete hashmap family helper.
(defstruct I64StringMapMutEntry
  (:lifetimes map)
  (slots (Array I64StringMapSlot))
  (borrow (&mut map (Array I64StringMapSlot)))
  (index i64)
  (present bool)
  (key i64)
  (hash i64))

;: Generated concrete hashmap family helper.
(define (i64-string-map-slots [map : I64StringMap]) : (Array I64StringMapSlot)
  (struct-get map slots))

;: Generated concrete hashmap family helper.
(define (i64-string-map-len [map : I64StringMap]) : i64
  (struct-get map len))

;: Generated concrete hashmap family helper.
(define (i64-string-map-capacity [map : I64StringMap]) : i64
  (array-length (struct-get map slots)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-deleted [map : I64StringMap]) : i64
  (struct-get map deleted))

;: Generated concrete hashmap family helper.
(define (i64-string-map-fill-empty
  [slots : (Array I64StringMapSlot)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! slots index (I64StringMapEmpty))
      (i64-string-map-fill-empty slots (+ index 1) count))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-with-capacity [capacity : i64]) : I64StringMap
  (let
    [rounded-capacity : i64 (i64-string-map-round-capacity capacity)]
    [slots : (Array I64StringMapSlot)
      (make-array I64StringMapSlot rounded-capacity)]
    (begin
      (i64-string-map-fill-empty slots 0 rounded-capacity)
      (I64StringMap slots 0 0))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-borrowed-value-missing [map : (& map I64StringMap)]) : (I64StringMapBorrowedValueLookup
    map)
  (I64StringMapBorrowedValueMissing))

;: Generated concrete hashmap family helper.
(define (i64-string-map-borrowed-value-found [value : (& map str)]) : (I64StringMapBorrowedValueLookup
    map)
  (I64StringMapBorrowedValueFound value))

;: Generated concrete hashmap family helper.
(define (i64-string-map-get [map : I64StringMap] [key : i64]) : I64StringMapLookup
  (let
    [slots : (Array I64StringMapSlot) (i64-string-map-slots map)]
    (match (i64-string-map-probe
      slots
      (i64-string-map-capacity map)
      key
      (i64-string-map-hash-key key))
      [(I64StringMapProbeFound index)
        (match (array-ref slots index)
          [(I64StringMapOccupied _ value _) (I64StringMapFound value)]
          [(I64StringMapEmpty) (I64StringMapMissing)]
          [(I64StringMapTombstone) (I64StringMapMissing)])]
      [(I64StringMapProbeAbsent _) (I64StringMapMissing)]
      [(I64StringMapProbeFull) (I64StringMapMissing)])))

;: Generated concrete hashmap family helper.
(define (i64-string-map-get-value-borrowed
  [map : (& map I64StringMap)]
  [key : i64]) : (I64StringMapBorrowedValueLookup map)
  (let
    [capacity : i64 (array-length (struct-get map slots))]
    (if (<= capacity 0)
      (i64-string-map-borrowed-value-missing map)
      (let
        [hash : i64 (i64-string-map-hash-key key)]
        [cursor : i64 (i64-string-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array-ref (struct-get map slots) cursor)
              [(I64StringMapEmpty)
                (return (i64-string-map-borrowed-value-missing map))]
              [(I64StringMapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(I64StringMapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (= slot-key key)
                  false)
                  (match (& (array-ref (struct-get map slots) cursor))
                    [(I64StringMapOccupied _ value _)
                      (return (i64-string-map-borrowed-value-found value))]
                    [(I64StringMapEmpty)
                      (return (i64-string-map-borrowed-value-missing map))]
                    [(I64StringMapTombstone)
                      (return (i64-string-map-borrowed-value-missing map))])
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (i64-string-map-borrowed-value-missing map))))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-contains? [map : I64StringMap] [key : i64]) : bool
  (match (i64-string-map-get map key)
    [(I64StringMapFound _) true]
    [(I64StringMapMissing) false]))

;: Generated concrete hashmap family helper.
(define (i64-string-map-slot-tombstone? [slot : I64StringMapSlot]) : bool
  (match slot
    [(I64StringMapTombstone) true]
    [(I64StringMapEmpty) false]
    [(I64StringMapOccupied _ _ _) false]))

;: Generated concrete hashmap family helper.
(define (i64-string-map-insert
  [map : I64StringMap]
  [key : i64]
  [value : String]) : I64StringMapInsertResult
  (let
    [slots : (Array I64StringMapSlot) (i64-string-map-slots map)]
    [hash : i64 (i64-string-map-hash-key key)]
    (match (i64-string-map-probe slots (i64-string-map-capacity map) key hash)
      [(I64StringMapProbeFound index)
        (begin
          (array-set! slots index (I64StringMapOccupied key value hash))
          (I64StringMapInsertOk map))]
      [(I64StringMapProbeAbsent index)
        (let
          [reused-tombstone : bool
            (i64-string-map-slot-tombstone? (array-ref slots index))]
          (begin
            (array-set! slots index (I64StringMapOccupied key value hash))
            (set! (struct-get map len) (+ (i64-string-map-len map) 1))
            (if reused-tombstone
              (set! (struct-get map deleted) (- (i64-string-map-deleted map) 1))
              unit)
            (I64StringMapInsertOk map)))]
      [(I64StringMapProbeFull) (I64StringMapInsertFull map)])))

;: Generated concrete hashmap family helper.
(define (i64-string-map-remove [map : I64StringMap] [key : i64]) : I64StringMapRemoveResult
  (let
    [slots : (Array I64StringMapSlot) (i64-string-map-slots map)]
    (match (i64-string-map-probe
      slots
      (i64-string-map-capacity map)
      key
      (i64-string-map-hash-key key))
      [(I64StringMapProbeFound index)
        (begin
          (array-set! slots index (I64StringMapTombstone))
          (set! (struct-get map len) (- (i64-string-map-len map) 1))
          (set! (struct-get map deleted) (+ (i64-string-map-deleted map) 1))
          (I64StringMapRemoveOk map))]
      [(I64StringMapProbeAbsent _) (I64StringMapRemoveMissing map)]
      [(I64StringMapProbeFull) (I64StringMapRemoveMissing map)])))

;: Generated concrete hashmap family helper.
(define (i64-string-map-update-if-present
  [map : I64StringMap]
  [key : i64]
  [value : String]) : I64StringMapUpdateResult
  (let
    [slots : (Array I64StringMapSlot) (i64-string-map-slots map)]
    [hash : i64 (i64-string-map-hash-key key)]
    (match (i64-string-map-probe slots (i64-string-map-capacity map) key hash)
      [(I64StringMapProbeFound index)
        (match (array-ref slots index)
          [(I64StringMapOccupied slot-key _ slot-hash)
            (begin
              (array-set!
                slots
                index
                (I64StringMapOccupied slot-key value slot-hash))
              (I64StringMapUpdateOk map))]
          [(I64StringMapEmpty) (I64StringMapUpdateMissing map)]
          [(I64StringMapTombstone) (I64StringMapUpdateMissing map)])]
      [(I64StringMapProbeAbsent _) (I64StringMapUpdateMissing map)]
      [(I64StringMapProbeFull) (I64StringMapUpdateMissing map)])))

;: Generated concrete hashmap family helper.
(define (i64-string-map-insert-into-empty
  [slots : (Array I64StringMapSlot)]
  [capacity : i64]
  [key : i64]
  [value : String]
  [hash : i64]) : unit
  (if (<= capacity 0)
    unit
    (let
      [cursor : i64 (i64-string-map-normalized-bucket-index hash capacity)]
      [walked : i64 0]
      [done : bool false]
      (begin
        (while (if done
          false
          (< walked capacity))
          (match (array-ref slots cursor)
            [(I64StringMapEmpty)
              (begin
                (array-set! slots cursor (I64StringMapOccupied key value hash))
                (set! done true))]
            [_
              (begin
                (set! cursor (i64-string-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        unit))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-rehash-from
  [src : (Array I64StringMapSlot)]
  [dst : (Array I64StringMapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (match (array-ref src index)
        [(I64StringMapOccupied key value hash)
          (i64-string-map-insert-into-empty dst dst-capacity key value hash)]
        [(I64StringMapEmpty) unit]
        [(I64StringMapTombstone) unit])
      (i64-string-map-rehash-from src dst dst-capacity (+ index 1) count))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-resized [map : I64StringMap] [new-capacity : i64]) : I64StringMap
  (let
    [src : (Array I64StringMapSlot) (i64-string-map-slots map)]
    [old-capacity : i64 (i64-string-map-capacity map)]
    [requested-capacity : i64
      (if (> (i64-string-map-len map) new-capacity)
        (i64-string-map-len map)
        new-capacity)]
    [rounded-capacity : i64 (i64-string-map-round-capacity requested-capacity)]
    [dst : (Array I64StringMapSlot)
      (make-array I64StringMapSlot rounded-capacity)]
    (begin
      (i64-string-map-fill-empty dst 0 rounded-capacity)
      (i64-string-map-rehash-from src dst rounded-capacity 0 old-capacity)
      (set! (struct-get map slots) dst)
      (set! (struct-get map deleted) 0)
      map)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-grow-capacity [capacity : i64]) : i64
  (if (< capacity 4)
    8
    (* (i64-string-map-round-capacity capacity) 2)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-grow [map : I64StringMap]) : I64StringMap
  (i64-string-map-resized
    map
    (i64-string-map-grow-capacity (i64-string-map-capacity map))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-needs-grow? [map : I64StringMap]) : bool
  (let
    [capacity : i64 (i64-string-map-capacity map)]
    [used : i64 (+ (i64-string-map-len map) (i64-string-map-deleted map))]
    (if (<= capacity 0)
      true
      (>= (* used 4) (* capacity 3)))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-put [map : I64StringMap] [key : i64] [value : String]) : I64StringMap
  (let
    [grown : I64StringMap
      (if (i64-string-map-needs-grow? map)
        (i64-string-map-grow map)
        map)]
    (match (i64-string-map-insert grown key value)
      [(I64StringMapInsertOk updated) updated]
      [(I64StringMapInsertFull full)
        (match (i64-string-map-insert (i64-string-map-grow full) key value)
          [(I64StringMapInsertOk u) u]
          [(I64StringMapInsertFull u) u])])))

;: Generated concrete hashmap family helper.
(define (i64-string-map-insert-or-update
  [map : I64StringMap]
  [key : i64]
  [value : String]) : I64StringMap
  (i64-string-map-put map key value))

;: Generated concrete hashmap family helper.
(define (i64-string-map-entry-or-insert
  [map : I64StringMap]
  [key : i64]
  [default-value : String]) : I64StringMapEntryOrInsertResult
  (let
    [slots : (Array I64StringMapSlot) (i64-string-map-slots map)]
    [hash : i64 (i64-string-map-hash-key key)]
    (match (i64-string-map-probe slots (i64-string-map-capacity map) key hash)
      [(I64StringMapProbeFound index)
        (match (array-ref slots index)
          [(I64StringMapOccupied _ value _)
            (I64StringMapEntryOrInsertFound map value)]
          [(I64StringMapEmpty)
            (let
              [updated : I64StringMap
                (i64-string-map-put map key default-value)]
              (I64StringMapEntryOrInsertInserted updated default-value))]
          [(I64StringMapTombstone)
            (let
              [updated : I64StringMap
                (i64-string-map-put map key default-value)]
              (I64StringMapEntryOrInsertInserted updated default-value))])]
      [(I64StringMapProbeAbsent _)
        (let
          [updated : I64StringMap (i64-string-map-put map key default-value)]
          (I64StringMapEntryOrInsertInserted updated default-value))]
      [(I64StringMapProbeFull)
        (let
          [updated : I64StringMap (i64-string-map-put map key default-value)]
          (I64StringMapEntryOrInsertInserted updated default-value))])))

;: Generated concrete hashmap family helper.
(define (i64-string-map-mut-entry-info
  [slots : (Array I64StringMapSlot)]
  [capacity : i64]
  [key : i64]) : I64StringMapMutEntryInfo
  (if (<= capacity 0)
    (I64StringMapMutEntryInfo -1 false 0 0)
    (let
      [hash : i64 (i64-string-map-hash-key key)]
      [cursor : i64 (i64-string-map-bucket-index hash capacity)]
      [walked : i64 0]
      [found : i64 -1]
      [present : bool false]
      [entry-key : i64 0]
      [entry-hash : i64 0]
      [done : bool false]
      (begin
        (while (if (< walked capacity)
          (not done)
          false)
          (match (array-ref slots cursor)
            [(I64StringMapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (= slot-key key)
                false)
                (begin
                  (set! found cursor)
                  (set! present true)
                  (set! entry-key slot-key)
                  (set! entry-hash slot-hash)
                  (set! done true))
                (begin
                  (set! cursor (i64-string-map-next-index cursor capacity))
                  (set! walked (+ walked 1))))]
            [(I64StringMapEmpty) (set! done true)]
            [(I64StringMapTombstone)
              (begin
                (set! cursor (i64-string-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        (I64StringMapMutEntryInfo found present entry-key entry-hash)))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-mut-entry-from-info
  [info : I64StringMapMutEntryInfo]
  [slots : (Array I64StringMapSlot)]
  [borrow : (&mut map (Array I64StringMapSlot))]) : (I64StringMapMutEntry map)
  (I64StringMapMutEntry
    slots
    borrow
    (struct-get info index)
    (struct-get info present)
    (struct-get info key)
    (struct-get info hash)))

;: Generated concrete hashmap family helper.
(defmacro (i64-string-map-get-mut-entry [map : Expr] [key : Expr]) : Expr
  `(i64-string-map-mut-entry-from-info
    (i64-string-map-mut-entry-info
      (struct-get ,map slots)
      (array-length (struct-get ,map slots))
      ,key)
    (struct-get ,map slots)
    (&mut (struct-get ,map slots))))

;: Generated concrete hashmap family helper.
(define (i64-string-map-mut-entry-present? [entry : (I64StringMapMutEntry map)]) : bool
  (struct-get entry present))

;: Generated concrete hashmap family helper.
(define (i64-string-map-mut-entry-value-or
  [entry : (I64StringMapMutEntry map)]
  [fallback : String]) : String
  (if (i64-string-map-mut-entry-present? entry)
    (match (array-ref (struct-get entry slots) (struct-get entry index))
      [(I64StringMapOccupied _ value _) value]
      [(I64StringMapEmpty) fallback]
      [(I64StringMapTombstone) fallback])
    fallback))

;: Generated concrete hashmap family helper.
(define (i64-string-map-mut-entry-set!
  [entry : (I64StringMapMutEntry map)]
  [value : String]) : unit
  (if (i64-string-map-mut-entry-present? entry)
    (array-set!
      (struct-get entry slots)
      (struct-get entry index)
      (I64StringMapOccupied
        (struct-get entry key)
        value
        (struct-get entry hash)))
    unit))

;: Generated concrete hashmap family helper.
(defenum I64StringMapEntry
  (I64StringMapEntryNone)
  (I64StringMapEntrySome i64 String))

;: Generated concrete hashmap family helper.
(define (i64-string-map-next-occupied-from
  [slots : (Array I64StringMapSlot)]
  [index : i64]
  [capacity : i64]) : i64
  (if (>= index capacity)
    capacity
    (match (array-ref slots index)
      [(I64StringMapOccupied _ _ _) index]
      [(I64StringMapEmpty)
        (i64-string-map-next-occupied-from slots (+ index 1) capacity)]
      [(I64StringMapTombstone)
        (i64-string-map-next-occupied-from slots (+ index 1) capacity)])))

;: Generated concrete hashmap family helper.
(define (i64-string-map-next-occupied [map : I64StringMap] [from : i64]) : i64
  (i64-string-map-next-occupied-from
    (i64-string-map-slots map)
    (if (< from 0)
      0
      from)
    (i64-string-map-capacity map)))

;: Generated concrete hashmap family helper.
(define (i64-string-map-entry-at [map : I64StringMap] [index : i64]) : I64StringMapEntry
  (if (if (< index 0)
    true
    (>= index (i64-string-map-capacity map)))
    (I64StringMapEntryNone)
    (match (array-ref (i64-string-map-slots map) index)
      [(I64StringMapOccupied key value _) (I64StringMapEntrySome key value)]
      [(I64StringMapEmpty) (I64StringMapEntryNone)]
      [(I64StringMapTombstone) (I64StringMapEntryNone)])))

;: Mutable-entry reference handle used by the String -> String module wrapper.
(defstruct StringStringMapMutEntryRef
  (:lifetimes map)
  (borrow (&mut map (Array StringStringMapSlot)))
  (index i64)
  (present bool)
  (key String)
  (hash i64))

;: Mutable-entry reference handle used by the i64 -> i64 module wrapper.
(defstruct I64I64MapMutEntryRef
  (:lifetimes map)
  (borrow (&mut map (Array I64I64MapSlot)))
  (index i64)
  (present bool)
  (key i64)
  (hash i64))

;: Mutable-entry reference handle used by the i64 -> String module wrapper.
(defstruct I64StringMapMutEntryRef
  (:lifetimes map)
  (borrow (&mut map (Array I64StringMapSlot)))
  (index i64)
  (present bool)
  (key i64)
  (hash i64))

;: Borrowed lookup through an immutable generated String -> String map reference.
(define (string-string-map-get-borrowed-ref
  [map : (& map StringStringMap)]
  [key : (& key str)]) : StringStringMapLookup
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    (if (<= capacity 0)
      (StringStringMapMissing)
      (let
        [hash : i64 (string-string-map-hash-key key)]
        [cursor : i64 (string-string-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref (struct-get map slots) cursor)
              [(StringStringMapEmpty) (return (StringStringMapMissing))]
              [(StringStringMapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringStringMapOccupied slot-key value slot-hash)
                (if (if (= slot-hash hash)
                  (string-string-map-key-eq? (& slot-key) key)
                  false)
                  (return (StringStringMapFound (string.string-copy (& value))))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (StringStringMapMissing))))))

;: Rehash a borrowed String -> String slot array into a fresh destination.
(define (string-string-map-rehash-from-ref
  [src : (& src (Array StringStringMapSlot))]
  [dst : (Array StringStringMapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (match (array.array-ref src index)
        [(StringStringMapOccupied key value hash)
          (string-string-map-insert-into-empty
            dst
            dst-capacity
            (string.string-copy (& key))
            (string.string-copy (& value))
            hash)]
        [(StringStringMapEmpty) unit]
        [(StringStringMapTombstone) unit])
      (string-string-map-rehash-from-ref src dst dst-capacity (+ index 1) count))))

;: Resize a generated String -> String map in place.
(define (string-string-map-resize!
  [map : (&mut map StringStringMap)]
  [new-capacity : i64]) : unit
  (let
    [old-capacity : i64 (array.array-length (struct-get map slots))]
    [requested-capacity : i64
      (if (> (struct-get map len) new-capacity)
        (struct-get map len)
        new-capacity)]
    [rounded-capacity : i64
      (string-string-map-round-capacity requested-capacity)]
    [dst : (Array StringStringMapSlot)
      (array.make-array StringStringMapSlot rounded-capacity)]
    (begin
      (string-string-map-fill-empty dst 0 rounded-capacity)
      (string-string-map-rehash-from-ref
        (& (struct-get map slots))
        dst
        rounded-capacity
        0
        old-capacity)
      (set! (struct-get map slots) dst)
      (set! (struct-get map deleted) 0))))

;: Insert or update String -> String through a mutable map reference.
(define (string-string-map-put!
  [map : (&mut map StringStringMap)]
  [key : String]
  [value : String]) : unit
  (let
    [capacity-before : i64 (array.array-length (struct-get map slots))]
    [used-before : i64 (+ (struct-get map len) (struct-get map deleted))]
    (begin
      (if (if (<= capacity-before 0)
        true
        (>= (* used-before 4) (* capacity-before 3)))
        (string-string-map-resize!
          map
          (string-string-map-grow-capacity capacity-before))
        unit)
      (let
        [slots : (&mut map (Array StringStringMapSlot))
          (&mut (struct-get map slots))]
        [capacity : i64 (array.array-length slots)]
        [hash : i64 (string-string-map-hash-key (& key))]
        (if (<= capacity 0)
          unit
          (let
            [cursor : i64
              (string-string-map-normalized-bucket-index hash capacity)]
            [walked : i64 0]
            [first : i64 -1]
            (begin
              (while (< walked capacity)
                (match (array.array-ref slots cursor)
                  [(StringStringMapEmpty)
                    (let
                      [index : i64
                        (if (>= first 0)
                          first
                          cursor)]
                      [reused-tombstone : bool (>= first 0)]
                      (begin
                        (array.array-set!
                          slots
                          index
                          (StringStringMapOccupied key value hash))
                        (set! (struct-get map len) (+ (struct-get map len) 1))
                        (if reused-tombstone
                          (set!
                            (struct-get map deleted)
                            (- (struct-get map deleted) 1))
                          unit)
                        (return unit)))]
                  [(StringStringMapTombstone)
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (if (< first 0)
                          (set! first cursor)
                          unit)
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1))))]
                  [(StringStringMapOccupied slot-key _ slot-hash)
                    (if (if (= slot-hash hash)
                      (string-string-map-key-eq? (& slot-key) (& key))
                      false)
                      (begin
                        (array.array-set!
                          slots
                          cursor
                          (StringStringMapOccupied key value hash))
                        (return unit))
                      (let
                        [next : i64 (+ cursor 1)]
                        (begin
                          (set!
                            cursor
                            (if (>= next capacity)
                              0
                              next))
                          (set! walked (+ walked 1)))))]))
              (if (>= first 0)
                (begin
                  (array.array-set!
                    slots
                    first
                    (StringStringMapOccupied key value hash))
                  (set! (struct-get map len) (+ (struct-get map len) 1))
                  (set! (struct-get map deleted) (- (struct-get map deleted) 1)))
                unit))))))))

;: Remove a borrowed String key from String -> String through a mutable map reference.
(define (string-string-map-remove-borrowed!
  [map : (&mut map StringStringMap)]
  [key : (& key str)]) : bool
  (let
    [slots : (&mut map (Array StringStringMapSlot))
      (&mut (struct-get map slots))]
    [capacity : i64 (array.array-length slots)]
    (if (<= capacity 0)
      false
      (let
        [hash : i64 (string-string-map-hash-key key)]
        [cursor : i64 (string-string-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref slots cursor)
              [(StringStringMapEmpty) (return false)]
              [(StringStringMapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(StringStringMapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (string-string-map-key-eq? (& slot-key) key)
                  false)
                  (begin
                    (array.array-set! slots cursor (StringStringMapTombstone))
                    (set! (struct-get map len) (- (struct-get map len) 1))
                    (set!
                      (struct-get map deleted)
                      (+ (struct-get map deleted) 1))
                    (return true))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          false)))))

;: Reference variant of `string-string-map-next-occupied`.
(define (string-string-map-next-occupied-ref
  [map : (& map StringStringMap)]
  [from : i64]) : i64
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    [index : i64
      (if (< from 0)
        0
        from)]
    (begin
      (while (< index capacity)
        (match (array.array-ref (struct-get map slots) index)
          [(StringStringMapOccupied _ _ _) (return index)]
          [(StringStringMapEmpty) (set! index (+ index 1))]
          [(StringStringMapTombstone) (set! index (+ index 1))]))
      capacity)))

;: Reference variant of `string-string-map-entry-at`.
(define (string-string-map-entry-at-ref
  [map : (& map StringStringMap)]
  [index : i64]) : StringStringMapEntry
  (if (if (< index 0)
    true
    (>= index (array.array-length (struct-get map slots))))
    (StringStringMapEntryNone)
    (match (array.array-ref (struct-get map slots) index)
      [(StringStringMapOccupied key value _)
        (StringStringMapEntrySome
          (string.string-copy (& key))
          (string.string-copy (& value)))]
      [(StringStringMapEmpty) (StringStringMapEntryNone)]
      [(StringStringMapTombstone) (StringStringMapEntryNone)])))

;: Probe mutable String -> String slots and return mutable-entry metadata.
(define (string-string-map-mut-entry-info-mut
  [slots : (&mut slots (Array StringStringMapSlot))]
  [capacity : i64]
  [key : (& key str)]) : StringStringMapMutEntryInfo
  (if (<= capacity 0)
    (StringStringMapMutEntryInfo -1 false "" 0)
    (let
      [hash : i64 (string-string-map-hash-key key)]
      [cursor : i64 (string-string-map-bucket-index hash capacity)]
      [walked : i64 0]
      [found : i64 -1]
      [present : bool false]
      [entry-key : String ""]
      [entry-hash : i64 0]
      [done : bool false]
      (begin
        (while (if (< walked capacity)
          (not done)
          false)
          (match (array.array-ref slots cursor)
            [(StringStringMapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (string-string-map-key-eq? (& slot-key) key)
                false)
                (begin
                  (set! found cursor)
                  (set! present true)
                  (set! entry-key slot-key)
                  (set! entry-hash slot-hash)
                  (set! done true))
                (begin
                  (set! cursor (string-string-map-next-index cursor capacity))
                  (set! walked (+ walked 1))))]
            [(StringStringMapEmpty) (set! done true)]
            [(StringStringMapTombstone)
              (begin
                (set! cursor (string-string-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        (StringStringMapMutEntryInfo found present entry-key entry-hash)))))

;: Borrow String -> String slots mutably and return a wrapper mutable entry.
(define (string-string-map-get-mut-entry-borrowed!
  [map : (&mut map StringStringMap)]
  [key : (& key str)]) : (StringStringMapMutEntryRef map)
  (let
    [slots : (&mut map (Array StringStringMapSlot))
      (&mut (struct-get map slots))]
    [info : StringStringMapMutEntryInfo
      (string-string-map-mut-entry-info-mut
        slots
        (array.array-length slots)
        key)]
    (StringStringMapMutEntryRef
      slots
      (struct-get info index)
      (struct-get info present)
      (struct-get info key)
      (struct-get info hash))))

;: Return whether a String -> String wrapper mutable entry points at a live slot.
(define (string-string-map-mut-entry-ref-present?
  [entry : (StringStringMapMutEntryRef map)]) : bool
  (struct-get entry present))

;: Read a String -> String wrapper mutable entry value, or `fallback`.
(define (string-string-map-mut-entry-ref-value-or
  [entry : (StringStringMapMutEntryRef map)]
  [fallback : String]) : String
  (if (string-string-map-mut-entry-ref-present? entry)
    (match (array.array-ref (struct-get entry borrow) (struct-get entry index))
      [(StringStringMapOccupied _ value _) (string.string-copy (& value))]
      [(StringStringMapEmpty) fallback]
      [(StringStringMapTombstone) fallback])
    fallback))

;: Update a String -> String wrapper mutable entry in place when present.
(define (string-string-map-mut-entry-ref-set!
  [entry : (StringStringMapMutEntryRef map)]
  [value : String]) : unit
  (if (string-string-map-mut-entry-ref-present? entry)
    (array.array-set!
      (struct-get entry borrow)
      (struct-get entry index)
      (StringStringMapOccupied
        (struct-get entry key)
        value
        (struct-get entry hash)))
    unit))

;: Lookup through an immutable generated i64 -> i64 map reference.
(define (i64-i64-map-get-ref [map : (& map I64I64Map)] [key : i64]) : I64I64MapLookup
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    (if (<= capacity 0)
      (I64I64MapMissing)
      (let
        [hash : i64 (i64-i64-map-hash-key key)]
        [cursor : i64 (i64-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref (struct-get map slots) cursor)
              [(I64I64MapEmpty) (return (I64I64MapMissing))]
              [(I64I64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(I64I64MapOccupied slot-key value slot-hash)
                (if (if (= slot-hash hash)
                  (= slot-key key)
                  false)
                  (return (I64I64MapFound value))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (I64I64MapMissing))))))

;: Rehash a borrowed i64 -> i64 slot array into a fresh destination.
(define (i64-i64-map-rehash-from-ref
  [src : (& src (Array I64I64MapSlot))]
  [dst : (Array I64I64MapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (begin
      (while (< i count)
        (begin
          (match (array.array-ref src i)
            [(I64I64MapOccupied key value hash)
              (i64-i64-map-insert-into-empty dst dst-capacity key value hash)]
            [(I64I64MapEmpty) unit]
            [(I64I64MapTombstone) unit])
          (set! i (+ i 1))))
      unit)))

;: Resize a generated i64 -> i64 map in place.
(define (i64-i64-map-resize! [map : (&mut map I64I64Map)] [new-capacity : i64]) : unit
  (let
    [old-capacity : i64 (array.array-length (struct-get map slots))]
    [requested-capacity : i64
      (if (> (struct-get map len) new-capacity)
        (struct-get map len)
        new-capacity)]
    [rounded-capacity : i64 (i64-i64-map-round-capacity requested-capacity)]
    [dst : (Array I64I64MapSlot)
      (array.make-array I64I64MapSlot rounded-capacity)]
    (begin
      (i64-i64-map-fill-empty dst 0 rounded-capacity)
      (i64-i64-map-rehash-from-ref
        (& (struct-get map slots))
        dst
        rounded-capacity
        0
        old-capacity)
      (set! (struct-get map slots) dst)
      (set! (struct-get map deleted) 0))))

;: Insert or update i64 -> i64 through a mutable map reference.
(define (i64-i64-map-put!
  [map : (&mut map I64I64Map)]
  [key : i64]
  [value : i64]) : unit
  (let
    [capacity-before : i64 (array.array-length (struct-get map slots))]
    [used-before : i64 (+ (struct-get map len) (struct-get map deleted))]
    (begin
      (if (if (<= capacity-before 0)
        true
        (>= (* used-before 4) (* capacity-before 3)))
        (i64-i64-map-resize! map (i64-i64-map-grow-capacity capacity-before))
        unit)
      (let
        [slots : (&mut map (Array I64I64MapSlot)) (&mut (struct-get map slots))]
        [capacity : i64 (array.array-length slots)]
        [hash : i64 (i64-i64-map-hash-key key)]
        (if (<= capacity 0)
          unit
          (let
            [cursor : i64 (i64-i64-map-normalized-bucket-index hash capacity)]
            [walked : i64 0]
            [first : i64 -1]
            (begin
              (while (< walked capacity)
                (match (array.array-ref slots cursor)
                  [(I64I64MapEmpty)
                    (let
                      [index : i64
                        (if (>= first 0)
                          first
                          cursor)]
                      [reused-tombstone : bool (>= first 0)]
                      (begin
                        (array.array-set!
                          slots
                          index
                          (I64I64MapOccupied key value hash))
                        (set! (struct-get map len) (+ (struct-get map len) 1))
                        (if reused-tombstone
                          (set!
                            (struct-get map deleted)
                            (- (struct-get map deleted) 1))
                          unit)
                        (return unit)))]
                  [(I64I64MapTombstone)
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (if (< first 0)
                          (set! first cursor)
                          unit)
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1))))]
                  [(I64I64MapOccupied slot-key _ slot-hash)
                    (if (if (= slot-hash hash)
                      (= slot-key key)
                      false)
                      (begin
                        (array.array-set!
                          slots
                          cursor
                          (I64I64MapOccupied key value hash))
                        (return unit))
                      (let
                        [next : i64 (+ cursor 1)]
                        (begin
                          (set!
                            cursor
                            (if (>= next capacity)
                              0
                              next))
                          (set! walked (+ walked 1)))))]))
              (if (>= first 0)
                (begin
                  (array.array-set!
                    slots
                    first
                    (I64I64MapOccupied key value hash))
                  (set! (struct-get map len) (+ (struct-get map len) 1))
                  (set! (struct-get map deleted) (- (struct-get map deleted) 1)))
                unit))))))))

;: Remove an i64 key from i64 -> i64 through a mutable map reference.
(define (i64-i64-map-remove! [map : (&mut map I64I64Map)] [key : i64]) : bool
  (let
    [slots : (&mut map (Array I64I64MapSlot)) (&mut (struct-get map slots))]
    [capacity : i64 (array.array-length slots)]
    (if (<= capacity 0)
      false
      (let
        [hash : i64 (i64-i64-map-hash-key key)]
        [cursor : i64 (i64-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref slots cursor)
              [(I64I64MapEmpty) (return false)]
              [(I64I64MapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(I64I64MapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (= slot-key key)
                  false)
                  (begin
                    (array.array-set! slots cursor (I64I64MapTombstone))
                    (set! (struct-get map len) (- (struct-get map len) 1))
                    (set!
                      (struct-get map deleted)
                      (+ (struct-get map deleted) 1))
                    (return true))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          false)))))

;: Reference variant of `i64-i64-map-next-occupied`.
(define (i64-i64-map-next-occupied-ref [map : (& map I64I64Map)] [from : i64]) : i64
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    [index : i64
      (if (< from 0)
        0
        from)]
    (begin
      (while (< index capacity)
        (match (array.array-ref (struct-get map slots) index)
          [(I64I64MapOccupied _ _ _) (return index)]
          [(I64I64MapEmpty) (set! index (+ index 1))]
          [(I64I64MapTombstone) (set! index (+ index 1))]))
      capacity)))

;: Reference variant of `i64-i64-map-entry-at`.
(define (i64-i64-map-entry-at-ref [map : (& map I64I64Map)] [index : i64]) : I64I64MapEntry
  (if (if (< index 0)
    true
    (>= index (array.array-length (struct-get map slots))))
    (I64I64MapEntryNone)
    (match (array.array-ref (struct-get map slots) index)
      [(I64I64MapOccupied key value _) (I64I64MapEntrySome key value)]
      [(I64I64MapEmpty) (I64I64MapEntryNone)]
      [(I64I64MapTombstone) (I64I64MapEntryNone)])))

;: Probe mutable i64 -> i64 slots and return mutable-entry metadata.
(define (i64-i64-map-mut-entry-info-mut
  [slots : (&mut slots (Array I64I64MapSlot))]
  [capacity : i64]
  [key : i64]) : I64I64MapMutEntryInfo
  (if (<= capacity 0)
    (I64I64MapMutEntryInfo -1 false 0 0)
    (let
      [hash : i64 (i64-i64-map-hash-key key)]
      [cursor : i64 (i64-i64-map-bucket-index hash capacity)]
      [walked : i64 0]
      [found : i64 -1]
      [present : bool false]
      [entry-key : i64 0]
      [entry-hash : i64 0]
      [done : bool false]
      (begin
        (while (if (< walked capacity)
          (not done)
          false)
          (match (array.array-ref slots cursor)
            [(I64I64MapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (= slot-key key)
                false)
                (begin
                  (set! found cursor)
                  (set! present true)
                  (set! entry-key slot-key)
                  (set! entry-hash slot-hash)
                  (set! done true))
                (begin
                  (set! cursor (i64-i64-map-next-index cursor capacity))
                  (set! walked (+ walked 1))))]
            [(I64I64MapEmpty) (set! done true)]
            [(I64I64MapTombstone)
              (begin
                (set! cursor (i64-i64-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        (I64I64MapMutEntryInfo found present entry-key entry-hash)))))

;: Borrow i64 -> i64 slots mutably and return a wrapper mutable entry.
(define (i64-i64-map-get-mut-entry! [map : (&mut map I64I64Map)] [key : i64]) : (I64I64MapMutEntryRef
    map)
  (let
    [slots : (&mut map (Array I64I64MapSlot)) (&mut (struct-get map slots))]
    [info : I64I64MapMutEntryInfo
      (i64-i64-map-mut-entry-info-mut slots (array.array-length slots) key)]
    (I64I64MapMutEntryRef
      slots
      (struct-get info index)
      (struct-get info present)
      (struct-get info key)
      (struct-get info hash))))

;: Return whether an i64 -> i64 wrapper mutable entry points at a live slot.
(define (i64-i64-map-mut-entry-ref-present?
  [entry : (I64I64MapMutEntryRef map)]) : bool
  (struct-get entry present))

;: Read an i64 -> i64 wrapper mutable entry value, or `fallback`.
(define (i64-i64-map-mut-entry-ref-value-or
  [entry : (I64I64MapMutEntryRef map)]
  [fallback : i64]) : i64
  (if (i64-i64-map-mut-entry-ref-present? entry)
    (match (array.array-ref (struct-get entry borrow) (struct-get entry index))
      [(I64I64MapOccupied _ value _) value]
      [(I64I64MapEmpty) fallback]
      [(I64I64MapTombstone) fallback])
    fallback))

;: Update an i64 -> i64 wrapper mutable entry in place when present.
(define (i64-i64-map-mut-entry-ref-set!
  [entry : (I64I64MapMutEntryRef map)]
  [value : i64]) : unit
  (if (i64-i64-map-mut-entry-ref-present? entry)
    (array.array-set!
      (struct-get entry borrow)
      (struct-get entry index)
      (I64I64MapOccupied (struct-get entry key) value (struct-get entry hash)))
    unit))

;: Lookup through an immutable generated i64 -> String map reference.
(define (i64-string-map-get-ref [map : (& map I64StringMap)] [key : i64]) : I64StringMapLookup
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    (if (<= capacity 0)
      (I64StringMapMissing)
      (let
        [hash : i64 (i64-string-map-hash-key key)]
        [cursor : i64 (i64-string-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref (struct-get map slots) cursor)
              [(I64StringMapEmpty) (return (I64StringMapMissing))]
              [(I64StringMapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(I64StringMapOccupied slot-key value slot-hash)
                (if (if (= slot-hash hash)
                  (= slot-key key)
                  false)
                  (return (I64StringMapFound (string.string-copy (& value))))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (I64StringMapMissing))))))

;: Rehash a borrowed i64 -> String slot array into a fresh destination.
(define (i64-string-map-rehash-from-ref
  [src : (& src (Array I64StringMapSlot))]
  [dst : (Array I64StringMapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (match (array.array-ref src index)
        [(I64StringMapOccupied key value hash)
          (i64-string-map-insert-into-empty
            dst
            dst-capacity
            key
            (string.string-copy (& value))
            hash)]
        [(I64StringMapEmpty) unit]
        [(I64StringMapTombstone) unit])
      (i64-string-map-rehash-from-ref src dst dst-capacity (+ index 1) count))))

;: Resize a generated i64 -> String map in place.
(define (i64-string-map-resize!
  [map : (&mut map I64StringMap)]
  [new-capacity : i64]) : unit
  (let
    [old-capacity : i64 (array.array-length (struct-get map slots))]
    [requested-capacity : i64
      (if (> (struct-get map len) new-capacity)
        (struct-get map len)
        new-capacity)]
    [rounded-capacity : i64 (i64-string-map-round-capacity requested-capacity)]
    [dst : (Array I64StringMapSlot)
      (array.make-array I64StringMapSlot rounded-capacity)]
    (begin
      (i64-string-map-fill-empty dst 0 rounded-capacity)
      (i64-string-map-rehash-from-ref
        (& (struct-get map slots))
        dst
        rounded-capacity
        0
        old-capacity)
      (set! (struct-get map slots) dst)
      (set! (struct-get map deleted) 0))))

;: Insert or update i64 -> String through a mutable map reference.
(define (i64-string-map-put!
  [map : (&mut map I64StringMap)]
  [key : i64]
  [value : String]) : unit
  (let
    [capacity-before : i64 (array.array-length (struct-get map slots))]
    [used-before : i64 (+ (struct-get map len) (struct-get map deleted))]
    (begin
      (if (if (<= capacity-before 0)
        true
        (>= (* used-before 4) (* capacity-before 3)))
        (i64-string-map-resize!
          map
          (i64-string-map-grow-capacity capacity-before))
        unit)
      (let
        [slots : (&mut map (Array I64StringMapSlot))
          (&mut (struct-get map slots))]
        [capacity : i64 (array.array-length slots)]
        [hash : i64 (i64-string-map-hash-key key)]
        (if (<= capacity 0)
          unit
          (let
            [cursor : i64
              (i64-string-map-normalized-bucket-index hash capacity)]
            [walked : i64 0]
            [first : i64 -1]
            (begin
              (while (< walked capacity)
                (match (array.array-ref slots cursor)
                  [(I64StringMapEmpty)
                    (let
                      [index : i64
                        (if (>= first 0)
                          first
                          cursor)]
                      [reused-tombstone : bool (>= first 0)]
                      (begin
                        (array.array-set!
                          slots
                          index
                          (I64StringMapOccupied key value hash))
                        (set! (struct-get map len) (+ (struct-get map len) 1))
                        (if reused-tombstone
                          (set!
                            (struct-get map deleted)
                            (- (struct-get map deleted) 1))
                          unit)
                        (return unit)))]
                  [(I64StringMapTombstone)
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (if (< first 0)
                          (set! first cursor)
                          unit)
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1))))]
                  [(I64StringMapOccupied slot-key _ slot-hash)
                    (if (if (= slot-hash hash)
                      (= slot-key key)
                      false)
                      (begin
                        (array.array-set!
                          slots
                          cursor
                          (I64StringMapOccupied key value hash))
                        (return unit))
                      (let
                        [next : i64 (+ cursor 1)]
                        (begin
                          (set!
                            cursor
                            (if (>= next capacity)
                              0
                              next))
                          (set! walked (+ walked 1)))))]))
              (if (>= first 0)
                (begin
                  (array.array-set!
                    slots
                    first
                    (I64StringMapOccupied key value hash))
                  (set! (struct-get map len) (+ (struct-get map len) 1))
                  (set! (struct-get map deleted) (- (struct-get map deleted) 1)))
                unit))))))))

;: Remove an i64 key from i64 -> String through a mutable map reference.
(define (i64-string-map-remove! [map : (&mut map I64StringMap)] [key : i64]) : bool
  (let
    [slots : (&mut map (Array I64StringMapSlot)) (&mut (struct-get map slots))]
    [capacity : i64 (array.array-length slots)]
    (if (<= capacity 0)
      false
      (let
        [hash : i64 (i64-string-map-hash-key key)]
        [cursor : i64 (i64-string-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array.array-ref slots cursor)
              [(I64StringMapEmpty) (return false)]
              [(I64StringMapTombstone)
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1))))]
              [(I64StringMapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (= slot-key key)
                  false)
                  (begin
                    (array.array-set! slots cursor (I64StringMapTombstone))
                    (set! (struct-get map len) (- (struct-get map len) 1))
                    (set!
                      (struct-get map deleted)
                      (+ (struct-get map deleted) 1))
                    (return true))
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          false)))))

;: Reference variant of `i64-string-map-next-occupied`.
(define (i64-string-map-next-occupied-ref
  [map : (& map I64StringMap)]
  [from : i64]) : i64
  (let
    [capacity : i64 (array.array-length (struct-get map slots))]
    [index : i64
      (if (< from 0)
        0
        from)]
    (begin
      (while (< index capacity)
        (match (array.array-ref (struct-get map slots) index)
          [(I64StringMapOccupied _ _ _) (return index)]
          [(I64StringMapEmpty) (set! index (+ index 1))]
          [(I64StringMapTombstone) (set! index (+ index 1))]))
      capacity)))

;: Reference variant of `i64-string-map-entry-at`.
(define (i64-string-map-entry-at-ref [map : (& map I64StringMap)] [index : i64]) : I64StringMapEntry
  (if (if (< index 0)
    true
    (>= index (array.array-length (struct-get map slots))))
    (I64StringMapEntryNone)
    (match (array.array-ref (struct-get map slots) index)
      [(I64StringMapOccupied key value _)
        (I64StringMapEntrySome key (string.string-copy (& value)))]
      [(I64StringMapEmpty) (I64StringMapEntryNone)]
      [(I64StringMapTombstone) (I64StringMapEntryNone)])))

;: Probe mutable i64 -> String slots and return mutable-entry metadata.
(define (i64-string-map-mut-entry-info-mut
  [slots : (&mut slots (Array I64StringMapSlot))]
  [capacity : i64]
  [key : i64]) : I64StringMapMutEntryInfo
  (if (<= capacity 0)
    (I64StringMapMutEntryInfo -1 false 0 0)
    (let
      [hash : i64 (i64-string-map-hash-key key)]
      [cursor : i64 (i64-string-map-bucket-index hash capacity)]
      [walked : i64 0]
      [found : i64 -1]
      [present : bool false]
      [entry-key : i64 0]
      [entry-hash : i64 0]
      [done : bool false]
      (begin
        (while (if (< walked capacity)
          (not done)
          false)
          (match (array.array-ref slots cursor)
            [(I64StringMapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (= slot-key key)
                false)
                (begin
                  (set! found cursor)
                  (set! present true)
                  (set! entry-key slot-key)
                  (set! entry-hash slot-hash)
                  (set! done true))
                (begin
                  (set! cursor (i64-string-map-next-index cursor capacity))
                  (set! walked (+ walked 1))))]
            [(I64StringMapEmpty) (set! done true)]
            [(I64StringMapTombstone)
              (begin
                (set! cursor (i64-string-map-next-index cursor capacity))
                (set! walked (+ walked 1)))]))
        (I64StringMapMutEntryInfo found present entry-key entry-hash)))))

;: Borrow i64 -> String slots mutably and return a wrapper mutable entry.
(define (i64-string-map-get-mut-entry!
  [map : (&mut map I64StringMap)]
  [key : i64]) : (I64StringMapMutEntryRef map)
  (let
    [slots : (&mut map (Array I64StringMapSlot)) (&mut (struct-get map slots))]
    [info : I64StringMapMutEntryInfo
      (i64-string-map-mut-entry-info-mut slots (array.array-length slots) key)]
    (I64StringMapMutEntryRef
      slots
      (struct-get info index)
      (struct-get info present)
      (struct-get info key)
      (struct-get info hash))))

;: Return whether an i64 -> String wrapper mutable entry points at a live slot.
(define (i64-string-map-mut-entry-ref-present?
  [entry : (I64StringMapMutEntryRef map)]) : bool
  (struct-get entry present))

;: Read an i64 -> String wrapper mutable entry value, or `fallback`.
(define (i64-string-map-mut-entry-ref-value-or
  [entry : (I64StringMapMutEntryRef map)]
  [fallback : String]) : String
  (if (i64-string-map-mut-entry-ref-present? entry)
    (match (array.array-ref (struct-get entry borrow) (struct-get entry index))
      [(I64StringMapOccupied _ value _) (string.string-copy (& value))]
      [(I64StringMapEmpty) fallback]
      [(I64StringMapTombstone) fallback])
    fallback))

;: Update an i64 -> String wrapper mutable entry in place when present.
(define (i64-string-map-mut-entry-ref-set!
  [entry : (I64StringMapMutEntryRef map)]
  [value : String]) : unit
  (if (i64-string-map-mut-entry-ref-present? entry)
    (array.array-set!
      (struct-get entry borrow)
      (struct-get entry index)
      (I64StringMapOccupied
        (struct-get entry key)
        value
        (struct-get entry hash)))
    unit))

;; Inline coverage migrated from stdlib/tests/hashmap_api.tl (#3083).
(cfg test (import stdlib.test))

(cfg
  test
  (define (hashmap-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (test.assert-string-eq (& actual) (& expected) message)))

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

;: Checked-in `StringHashPayloadMap` fixture family.
(cfg
  test
  (defenum StringHashPayloadMapSlot
    (StringHashPayloadMapEmpty)
    (StringHashPayloadMapTombstone)
    (StringHashPayloadMapOccupied String HashPayload i64)))

(cfg
  test
  (defenum StringHashPayloadMapProbe
    (StringHashPayloadMapProbeFound i64)
    (StringHashPayloadMapProbeAbsent i64)
    (StringHashPayloadMapProbeFull)))

(cfg
  test
  (define (string-hash-payload-map-hash-normalize [value : i64]) : i64
    (let
      [m : i64 2147483647]
      [raw : i64 (% value 2147483647)]
      (if (< raw 0)
        (+ raw m)
        raw))))

(cfg
  test
  (define (string-hash-payload-map-hash-key [key : (& key str)]) : i64
    (let
      [n : i64 (__tl_string_length key)]
      [i : i64 0]
      [hash : i64 0]
      (begin
        (while (< i n)
          (begin
            (set!
              hash
              (%
                (+ (+ (* hash 131) (cast (__tl_string_ref key i) : i64)) 1)
                2147483647))
            (set! i (+ i 1))))
        hash))))

(cfg
  test
  (define (string-hash-payload-map-power-two-capacity? [capacity : i64]) : bool
    (if (> capacity 0)
      (= (bit-and capacity (- capacity 1)) 0)
      false)))

(cfg
  test
  (define (string-hash-payload-map-round-capacity [capacity : i64]) : i64
    (let
      [rounded : i64 1]
      (begin
        (while (< rounded capacity)
          (set! rounded (* rounded 2)))
        rounded))))

(cfg
  test
  (define (string-hash-payload-map-normalized-bucket-index
    [hash : i64]
    [capacity : i64]) : i64
    (bit-and hash (- capacity 1))))

(cfg
  test
  (define (string-hash-payload-map-bucket-index [hash : i64] [capacity : i64]) : i64
    (string-hash-payload-map-normalized-bucket-index
      (string-hash-payload-map-hash-normalize hash)
      capacity)))

(cfg
  test
  (define (string-hash-payload-map-next-index [index : i64] [capacity : i64]) : i64
    (let
      [next : i64 (+ index 1)]
      (if (>= next capacity)
        0
        next))))

(cfg
  test
  (define (string-hash-payload-map-insert-slot
    [first-tombstone : i64]
    [empty-index : i64]) : i64
    (if (>= first-tombstone 0)
      first-tombstone
      empty-index)))

(cfg
  test
  (define (string-hash-payload-map-key-eq?
    [left : (& left str)]
    [right : (& right str)]) : bool
    (__tl_string_eq left right)))

(cfg
  test
  (define (string-hash-payload-map-probe-borrowed-from
    [slots : (Array StringHashPayloadMapSlot)]
    [capacity : i64]
    [key : (& key str)]
    [hash : i64]
    [index : i64]
    [steps : i64]
    [first-tombstone : i64]) : StringHashPayloadMapProbe
    (let
      [cursor : i64 index]
      [walked : i64 steps]
      [first : i64 first-tombstone]
      (begin
        (while (< walked capacity)
          (match (array-ref slots cursor)
            [(StringHashPayloadMapEmpty)
              (return
                (StringHashPayloadMapProbeAbsent
                  (string-hash-payload-map-insert-slot first cursor)))]
            [(StringHashPayloadMapTombstone)
              (let
                [next : i64 (+ cursor 1)]
                (begin
                  (if (< first 0)
                    (set! first cursor)
                    unit)
                  (set!
                    cursor
                    (if (>= next capacity)
                      0
                      next))
                  (set! walked (+ walked 1))))]
            [(StringHashPayloadMapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (string-hash-payload-map-key-eq? (& slot-key) key)
                false)
                (return (StringHashPayloadMapProbeFound cursor))
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1)))))]))
        (if (>= first 0)
          (StringHashPayloadMapProbeAbsent first)
          (StringHashPayloadMapProbeFull))))))

(cfg
  test
  (define (string-hash-payload-map-probe-borrowed
    [slots : (Array StringHashPayloadMapSlot)]
    [capacity : i64]
    [key : (& key str)]
    [hash : i64]) : StringHashPayloadMapProbe
    (if (<= capacity 0)
      (StringHashPayloadMapProbeFull)
      (string-hash-payload-map-probe-borrowed-from
        slots
        capacity
        key
        hash
        (string-hash-payload-map-normalized-bucket-index hash capacity)
        0
        -1))))

(cfg
  test
  (define (string-hash-payload-map-probe
    [slots : (Array StringHashPayloadMapSlot)]
    [capacity : i64]
    [key : String]
    [hash : i64]) : StringHashPayloadMapProbe
    (string-hash-payload-map-probe-borrowed slots capacity (& key) hash)))

(cfg
  test
  (defstruct StringHashPayloadMap
    (slots (Array StringHashPayloadMapSlot))
    (len i64)
    (deleted i64)))

(cfg
  test
  (defenum StringHashPayloadMapLookup
    (StringHashPayloadMapMissing)
    (StringHashPayloadMapFound HashPayload)))

(cfg
  test
  (defenum StringHashPayloadMapBorrowedValueLookup
    (:lifetimes map)
    (StringHashPayloadMapBorrowedValueMissing)
    (StringHashPayloadMapBorrowedValueFound (& map HashPayload))))

(cfg
  test
  (defenum StringHashPayloadMapInsertResult
    (StringHashPayloadMapInsertOk StringHashPayloadMap)
    (StringHashPayloadMapInsertFull StringHashPayloadMap)))

(cfg
  test
  (defenum StringHashPayloadMapRemoveResult
    (StringHashPayloadMapRemoveOk StringHashPayloadMap)
    (StringHashPayloadMapRemoveMissing StringHashPayloadMap)))

(cfg
  test
  (defenum StringHashPayloadMapUpdateResult
    (StringHashPayloadMapUpdateOk StringHashPayloadMap)
    (StringHashPayloadMapUpdateMissing StringHashPayloadMap)))

(cfg
  test
  (defenum StringHashPayloadMapEntryOrInsertResult
    (StringHashPayloadMapEntryOrInsertFound StringHashPayloadMap HashPayload)
    (StringHashPayloadMapEntryOrInsertInserted StringHashPayloadMap HashPayload)))

(cfg
  test
  (defstruct StringHashPayloadMapMutEntryInfo
    (index i64)
    (present bool)
    (key String)
    (hash i64)))

(cfg
  test
  (defstruct StringHashPayloadMapMutEntry
    (:lifetimes map)
    (slots (Array StringHashPayloadMapSlot))
    (borrow (&mut map (Array StringHashPayloadMapSlot)))
    (index i64)
    (present bool)
    (key String)
    (hash i64)))

(cfg
  test
  (define (string-hash-payload-map-slots [map : StringHashPayloadMap]) : (Array
      StringHashPayloadMapSlot)
    (struct-get map slots)))

(cfg
  test
  (define (string-hash-payload-map-len [map : StringHashPayloadMap]) : i64
    (struct-get map len)))

(cfg
  test
  (define (string-hash-payload-map-capacity [map : StringHashPayloadMap]) : i64
    (array-length (struct-get map slots))))

(cfg
  test
  (define (string-hash-payload-map-deleted [map : StringHashPayloadMap]) : i64
    (struct-get map deleted)))

(cfg
  test
  (define (string-hash-payload-map-fill-empty
    [slots : (Array StringHashPayloadMapSlot)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! slots index (StringHashPayloadMapEmpty))
        (string-hash-payload-map-fill-empty slots (+ index 1) count)))))

(cfg
  test
  (define (string-hash-payload-map-with-capacity [capacity : i64]) : StringHashPayloadMap
    (let
      [rounded-capacity : i64 (string-hash-payload-map-round-capacity capacity)]
      [slots : (Array StringHashPayloadMapSlot)
        (make-array StringHashPayloadMapSlot rounded-capacity)]
      (begin
        (string-hash-payload-map-fill-empty slots 0 rounded-capacity)
        (StringHashPayloadMap slots 0 0)))))

(cfg
  test
  (define (string-hash-payload-map-borrowed-value-missing
    [map : (& map StringHashPayloadMap)]) : (StringHashPayloadMapBorrowedValueLookup
      map)
    (StringHashPayloadMapBorrowedValueMissing)))

(cfg
  test
  (define (string-hash-payload-map-borrowed-value-found
    [value : (& map HashPayload)]) : (StringHashPayloadMapBorrowedValueLookup
      map)
    (StringHashPayloadMapBorrowedValueFound value)))

(cfg
  test
  (define (string-hash-payload-map-get-borrowed
    [map : StringHashPayloadMap]
    [key : (& key str)]) : StringHashPayloadMapLookup
    (let
      [slots : (Array StringHashPayloadMapSlot)
        (string-hash-payload-map-slots map)]
      (match (string-hash-payload-map-probe-borrowed
        slots
        (string-hash-payload-map-capacity map)
        key
        (string-hash-payload-map-hash-key key))
        [(StringHashPayloadMapProbeFound index)
          (match (array-ref slots index)
            [(StringHashPayloadMapOccupied _ value _)
              (StringHashPayloadMapFound value)]
            [(StringHashPayloadMapEmpty) (StringHashPayloadMapMissing)]
            [(StringHashPayloadMapTombstone) (StringHashPayloadMapMissing)])]
        [(StringHashPayloadMapProbeAbsent _) (StringHashPayloadMapMissing)]
        [(StringHashPayloadMapProbeFull) (StringHashPayloadMapMissing)]))))

(cfg
  test
  (define (string-hash-payload-map-get
    [map : StringHashPayloadMap]
    [key : String]) : StringHashPayloadMapLookup
    (string-hash-payload-map-get-borrowed map (& key))))

(cfg
  test
  (define (string-hash-payload-map-get-borrowed-ref
    [map : (& map StringHashPayloadMap)]
    [key : (& key str)]) : StringHashPayloadMapLookup
    (let
      [capacity : i64 (array-length (struct-get map slots))]
      (if (<= capacity 0)
        (StringHashPayloadMapMissing)
        (let
          [hash : i64 (string-hash-payload-map-hash-key key)]
          [cursor : i64
            (string-hash-payload-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref (struct-get map slots) cursor)
                [(StringHashPayloadMapEmpty)
                  (return (StringHashPayloadMapMissing))]
                [(StringHashPayloadMapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(StringHashPayloadMapOccupied slot-key value slot-hash)
                  (if (if (= slot-hash hash)
                    (string-hash-payload-map-key-eq? (& slot-key) key)
                    false)
                    (return (StringHashPayloadMapFound (clone value)))
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            (StringHashPayloadMapMissing)))))))

(cfg
  test
  (define (string-hash-payload-map-get-value-borrowed
    [map : (& map StringHashPayloadMap)]
    [key : (& key str)]) : (StringHashPayloadMapBorrowedValueLookup map)
    (let
      [capacity : i64 (array-length (struct-get map slots))]
      (if (<= capacity 0)
        (string-hash-payload-map-borrowed-value-missing map)
        (let
          [hash : i64 (string-hash-payload-map-hash-key key)]
          [cursor : i64
            (string-hash-payload-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref (struct-get map slots) cursor)
                [(StringHashPayloadMapEmpty)
                  (return (string-hash-payload-map-borrowed-value-missing map))]
                [(StringHashPayloadMapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(StringHashPayloadMapOccupied slot-key _ slot-hash)
                  (if (if (= slot-hash hash)
                    (string-hash-payload-map-key-eq? (& slot-key) key)
                    false)
                    (match (& (array-ref (struct-get map slots) cursor))
                      [(StringHashPayloadMapOccupied _ value _)
                        (return
                          (string-hash-payload-map-borrowed-value-found value))]
                      [(StringHashPayloadMapEmpty)
                        (return
                          (string-hash-payload-map-borrowed-value-missing map))]
                      [(StringHashPayloadMapTombstone)
                        (return
                          (string-hash-payload-map-borrowed-value-missing map))])
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            (string-hash-payload-map-borrowed-value-missing map)))))))

(cfg
  test
  (define (string-hash-payload-map-contains-borrowed?
    [map : StringHashPayloadMap]
    [key : (& key str)]) : bool
    (match (string-hash-payload-map-get-borrowed map key)
      [(StringHashPayloadMapFound _) true]
      [(StringHashPayloadMapMissing) false])))

(cfg
  test
  (define (string-hash-payload-map-contains?
    [map : StringHashPayloadMap]
    [key : String]) : bool
    (string-hash-payload-map-contains-borrowed? map (& key))))

(cfg
  test
  (define (string-hash-payload-map-slot-tombstone?
    [slot : StringHashPayloadMapSlot]) : bool
    (match slot
      [(StringHashPayloadMapTombstone) true]
      [(StringHashPayloadMapEmpty) false]
      [(StringHashPayloadMapOccupied _ _ _) false])))

(cfg
  test
  (define (string-hash-payload-map-insert
    [map : StringHashPayloadMap]
    [key : String]
    [value : HashPayload]) : StringHashPayloadMapInsertResult
    (let
      [slots : (Array StringHashPayloadMapSlot)
        (string-hash-payload-map-slots map)]
      [hash : i64 (string-hash-payload-map-hash-key (& key))]
      (match (string-hash-payload-map-probe-borrowed
        slots
        (string-hash-payload-map-capacity map)
        (& key)
        hash)
        [(StringHashPayloadMapProbeFound index)
          (begin
            (array-set!
              slots
              index
              (StringHashPayloadMapOccupied key value hash))
            (StringHashPayloadMapInsertOk map))]
        [(StringHashPayloadMapProbeAbsent index)
          (let
            [reused-tombstone : bool
              (string-hash-payload-map-slot-tombstone? (array-ref slots index))]
            (begin
              (array-set!
                slots
                index
                (StringHashPayloadMapOccupied key value hash))
              (set!
                (struct-get map len)
                (+ (string-hash-payload-map-len map) 1))
              (if reused-tombstone
                (set!
                  (struct-get map deleted)
                  (- (string-hash-payload-map-deleted map) 1))
                unit)
              (StringHashPayloadMapInsertOk map)))]
        [(StringHashPayloadMapProbeFull) (StringHashPayloadMapInsertFull map)]))))

(cfg
  test
  (define (string-hash-payload-map-remove-borrowed
    [map : StringHashPayloadMap]
    [key : (& key str)]) : StringHashPayloadMapRemoveResult
    (let
      [slots : (Array StringHashPayloadMapSlot)
        (string-hash-payload-map-slots map)]
      (match (string-hash-payload-map-probe-borrowed
        slots
        (string-hash-payload-map-capacity map)
        key
        (string-hash-payload-map-hash-key key))
        [(StringHashPayloadMapProbeFound index)
          (begin
            (array-set! slots index (StringHashPayloadMapTombstone))
            (set! (struct-get map len) (- (string-hash-payload-map-len map) 1))
            (set!
              (struct-get map deleted)
              (+ (string-hash-payload-map-deleted map) 1))
            (StringHashPayloadMapRemoveOk map))]
        [(StringHashPayloadMapProbeAbsent _)
          (StringHashPayloadMapRemoveMissing map)]
        [(StringHashPayloadMapProbeFull)
          (StringHashPayloadMapRemoveMissing map)]))))

(cfg
  test
  (define (string-hash-payload-map-remove
    [map : StringHashPayloadMap]
    [key : String]) : StringHashPayloadMapRemoveResult
    (string-hash-payload-map-remove-borrowed map (& key))))

(cfg
  test
  (define (string-hash-payload-map-update-borrowed-if-present
    [map : StringHashPayloadMap]
    [key : (& key str)]
    [value : HashPayload]) : StringHashPayloadMapUpdateResult
    (let
      [slots : (Array StringHashPayloadMapSlot)
        (string-hash-payload-map-slots map)]
      [hash : i64 (string-hash-payload-map-hash-key key)]
      (match (string-hash-payload-map-probe-borrowed
        slots
        (string-hash-payload-map-capacity map)
        key
        hash)
        [(StringHashPayloadMapProbeFound index)
          (match (array-ref slots index)
            [(StringHashPayloadMapOccupied slot-key _ slot-hash)
              (begin
                (array-set!
                  slots
                  index
                  (StringHashPayloadMapOccupied slot-key value slot-hash))
                (StringHashPayloadMapUpdateOk map))]
            [(StringHashPayloadMapEmpty)
              (StringHashPayloadMapUpdateMissing map)]
            [(StringHashPayloadMapTombstone)
              (StringHashPayloadMapUpdateMissing map)])]
        [(StringHashPayloadMapProbeAbsent _)
          (StringHashPayloadMapUpdateMissing map)]
        [(StringHashPayloadMapProbeFull)
          (StringHashPayloadMapUpdateMissing map)]))))

(cfg
  test
  (define (string-hash-payload-map-update-if-present
    [map : StringHashPayloadMap]
    [key : String]
    [value : HashPayload]) : StringHashPayloadMapUpdateResult
    (string-hash-payload-map-update-borrowed-if-present map (& key) value)))

(cfg
  test
  (define (string-hash-payload-map-insert-into-empty
    [slots : (Array StringHashPayloadMapSlot)]
    [capacity : i64]
    [key : String]
    [value : HashPayload]
    [hash : i64]) : unit
    (if (<= capacity 0)
      unit
      (let
        [cursor : i64
          (string-hash-payload-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        [done : bool false]
        (begin
          (while (if done
            false
            (< walked capacity))
            (match (array-ref slots cursor)
              [(StringHashPayloadMapEmpty)
                (begin
                  (array-set!
                    slots
                    cursor
                    (StringHashPayloadMapOccupied key value hash))
                  (set! done true))]
              [_
                (begin
                  (set!
                    cursor
                    (string-hash-payload-map-next-index cursor capacity))
                  (set! walked (+ walked 1)))]))
          unit)))))

(cfg
  test
  (define (string-hash-payload-map-rehash-from
    [src : (Array StringHashPayloadMapSlot)]
    [dst : (Array StringHashPayloadMapSlot)]
    [dst-capacity : i64]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (match (array-ref src index)
          [(StringHashPayloadMapOccupied key value hash)
            (string-hash-payload-map-insert-into-empty
              dst
              dst-capacity
              key
              value
              hash)]
          [(StringHashPayloadMapEmpty) unit]
          [(StringHashPayloadMapTombstone) unit])
        (string-hash-payload-map-rehash-from
          src
          dst
          dst-capacity
          (+ index 1)
          count)))))

(cfg
  test
  (define (string-hash-payload-map-rehash-from-ref
    [src : (& src (Array StringHashPayloadMapSlot))]
    [dst : (Array StringHashPayloadMapSlot)]
    [dst-capacity : i64]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (match (array-ref src index)
          [(StringHashPayloadMapOccupied key value hash)
            (string-hash-payload-map-insert-into-empty
              dst
              dst-capacity
              (string.string-copy (& key))
              (clone value)
              hash)]
          [(StringHashPayloadMapEmpty) unit]
          [(StringHashPayloadMapTombstone) unit])
        (string-hash-payload-map-rehash-from-ref
          src
          dst
          dst-capacity
          (+ index 1)
          count)))))

(cfg
  test
  (define (string-hash-payload-map-resized
    [map : StringHashPayloadMap]
    [new-capacity : i64]) : StringHashPayloadMap
    (let
      [src : (Array StringHashPayloadMapSlot)
        (string-hash-payload-map-slots map)]
      [old-capacity : i64 (string-hash-payload-map-capacity map)]
      [requested-capacity : i64
        (if (> (string-hash-payload-map-len map) new-capacity)
          (string-hash-payload-map-len map)
          new-capacity)]
      [rounded-capacity : i64
        (string-hash-payload-map-round-capacity requested-capacity)]
      [dst : (Array StringHashPayloadMapSlot)
        (make-array StringHashPayloadMapSlot rounded-capacity)]
      (begin
        (string-hash-payload-map-fill-empty dst 0 rounded-capacity)
        (string-hash-payload-map-rehash-from
          src
          dst
          rounded-capacity
          0
          old-capacity)
        (set! (struct-get map slots) dst)
        (set! (struct-get map deleted) 0)
        map))))

(cfg
  test
  (define (string-hash-payload-map-grow-capacity [capacity : i64]) : i64
    (if (< capacity 4)
      8
      (* (string-hash-payload-map-round-capacity capacity) 2))))

(cfg
  test
  (define (string-hash-payload-map-grow [map : StringHashPayloadMap]) : StringHashPayloadMap
    (string-hash-payload-map-resized
      map
      (string-hash-payload-map-grow-capacity
        (string-hash-payload-map-capacity map)))))

(cfg
  test
  (define (string-hash-payload-map-needs-grow? [map : StringHashPayloadMap]) : bool
    (let
      [capacity : i64 (string-hash-payload-map-capacity map)]
      [used : i64
        (+
          (string-hash-payload-map-len map)
          (string-hash-payload-map-deleted map))]
      (if (<= capacity 0)
        true
        (>= (* used 4) (* capacity 3))))))

(cfg
  test
  (define (string-hash-payload-map-resized!
    [map : (&mut map StringHashPayloadMap)]
    [new-capacity : i64]) : unit
    (let
      [old-capacity : i64 (array-length (struct-get map slots))]
      [requested-capacity : i64
        (if (> (struct-get map len) new-capacity)
          (struct-get map len)
          new-capacity)]
      [rounded-capacity : i64
        (string-hash-payload-map-round-capacity requested-capacity)]
      [dst : (Array StringHashPayloadMapSlot)
        (make-array StringHashPayloadMapSlot rounded-capacity)]
      (begin
        (string-hash-payload-map-fill-empty dst 0 rounded-capacity)
        (string-hash-payload-map-rehash-from-ref
          (& (struct-get map slots))
          dst
          rounded-capacity
          0
          old-capacity)
        (set! (struct-get map slots) dst)
        (set! (struct-get map deleted) 0)))))

(cfg
  test
  (define (string-hash-payload-map-put!
    [map : (&mut map StringHashPayloadMap)]
    [key : String]
    [value : HashPayload]) : unit
    (let
      [capacity-before : i64 (array-length (struct-get map slots))]
      [used-before : i64 (+ (struct-get map len) (struct-get map deleted))]
      (begin
        (if (if (<= capacity-before 0)
          true
          (>= (* used-before 4) (* capacity-before 3)))
          (string-hash-payload-map-resized!
            map
            (string-hash-payload-map-grow-capacity capacity-before))
          unit)
        (let
          [slots : (&mut map (Array StringHashPayloadMapSlot))
            (&mut (struct-get map slots))]
          [capacity : i64 (array-length slots)]
          [hash : i64 (string-hash-payload-map-hash-key (& key))]
          (if (<= capacity 0)
            unit
            (let
              [cursor : i64
                (string-hash-payload-map-normalized-bucket-index hash capacity)]
              [walked : i64 0]
              [first : i64 -1]
              (begin
                (while (< walked capacity)
                  (match (array-ref slots cursor)
                    [(StringHashPayloadMapEmpty)
                      (let
                        [index : i64
                          (if (>= first 0)
                            first
                            cursor)]
                        [reused-tombstone : bool (>= first 0)]
                        (begin
                          (array-set!
                            slots
                            index
                            (StringHashPayloadMapOccupied key value hash))
                          (set! (struct-get map len) (+ (struct-get map len) 1))
                          (if reused-tombstone
                            (set!
                              (struct-get map deleted)
                              (- (struct-get map deleted) 1))
                            unit)
                          (return unit)))]
                    [(StringHashPayloadMapTombstone)
                      (let
                        [next : i64 (+ cursor 1)]
                        (begin
                          (if (< first 0)
                            (set! first cursor)
                            unit)
                          (set!
                            cursor
                            (if (>= next capacity)
                              0
                              next))
                          (set! walked (+ walked 1))))]
                    [(StringHashPayloadMapOccupied slot-key _ slot-hash)
                      (if (if (= slot-hash hash)
                        (string-hash-payload-map-key-eq? (& slot-key) (& key))
                        false)
                        (begin
                          (array-set!
                            slots
                            cursor
                            (StringHashPayloadMapOccupied key value hash))
                          (return unit))
                        (let
                          [next : i64 (+ cursor 1)]
                          (begin
                            (set!
                              cursor
                              (if (>= next capacity)
                                0
                                next))
                            (set! walked (+ walked 1)))))]))
                (if (>= first 0)
                  (begin
                    (array-set!
                      slots
                      first
                      (StringHashPayloadMapOccupied key value hash))
                    (set! (struct-get map len) (+ (struct-get map len) 1))
                    (set!
                      (struct-get map deleted)
                      (- (struct-get map deleted) 1)))
                  unit)))))))))

(cfg
  test
  (define (string-hash-payload-map-remove-borrowed!
    [map : (&mut map StringHashPayloadMap)]
    [key : (& key str)]) : bool
    (let
      [slots : (&mut map (Array StringHashPayloadMapSlot))
        (&mut (struct-get map slots))]
      [capacity : i64 (array-length slots)]
      (if (<= capacity 0)
        false
        (let
          [hash : i64 (string-hash-payload-map-hash-key key)]
          [cursor : i64
            (string-hash-payload-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref slots cursor)
                [(StringHashPayloadMapEmpty) (return false)]
                [(StringHashPayloadMapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(StringHashPayloadMapOccupied slot-key _ slot-hash)
                  (if (if (= slot-hash hash)
                    (string-hash-payload-map-key-eq? (& slot-key) key)
                    false)
                    (begin
                      (array-set! slots cursor (StringHashPayloadMapTombstone))
                      (set! (struct-get map len) (- (struct-get map len) 1))
                      (set!
                        (struct-get map deleted)
                        (+ (struct-get map deleted) 1))
                      (return true))
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            false))))))

(cfg
  test
  (define (string-hash-payload-map-put
    [map : StringHashPayloadMap]
    [key : String]
    [value : HashPayload]) : StringHashPayloadMap
    (let
      [grown : StringHashPayloadMap
        (if (string-hash-payload-map-needs-grow? map)
          (string-hash-payload-map-grow map)
          map)]
      (match (string-hash-payload-map-insert grown key value)
        [(StringHashPayloadMapInsertOk updated) updated]
        [(StringHashPayloadMapInsertFull full)
          (match (string-hash-payload-map-insert
            (string-hash-payload-map-grow full)
            key
            value)
            [(StringHashPayloadMapInsertOk u) u]
            [(StringHashPayloadMapInsertFull u) u])]))))

(cfg
  test
  (define (string-hash-payload-map-insert-or-update
    [map : StringHashPayloadMap]
    [key : String]
    [value : HashPayload]) : StringHashPayloadMap
    (string-hash-payload-map-put map key value)))

(cfg
  test
  (define (string-hash-payload-map-entry-or-insert
    [map : StringHashPayloadMap]
    [key : String]
    [default-value : HashPayload]) : StringHashPayloadMapEntryOrInsertResult
    (let
      [slots : (Array StringHashPayloadMapSlot)
        (string-hash-payload-map-slots map)]
      [hash : i64 (string-hash-payload-map-hash-key (& key))]
      (match (string-hash-payload-map-probe-borrowed
        slots
        (string-hash-payload-map-capacity map)
        (& key)
        hash)
        [(StringHashPayloadMapProbeFound index)
          (match (array-ref slots index)
            [(StringHashPayloadMapOccupied _ value _)
              (StringHashPayloadMapEntryOrInsertFound map value)]
            [(StringHashPayloadMapEmpty)
              (let
                [updated : StringHashPayloadMap
                  (string-hash-payload-map-put map key default-value)]
                (StringHashPayloadMapEntryOrInsertInserted
                  updated
                  default-value))]
            [(StringHashPayloadMapTombstone)
              (let
                [updated : StringHashPayloadMap
                  (string-hash-payload-map-put map key default-value)]
                (StringHashPayloadMapEntryOrInsertInserted
                  updated
                  default-value))])]
        [(StringHashPayloadMapProbeAbsent _)
          (let
            [updated : StringHashPayloadMap
              (string-hash-payload-map-put map key default-value)]
            (StringHashPayloadMapEntryOrInsertInserted updated default-value))]
        [(StringHashPayloadMapProbeFull)
          (let
            [updated : StringHashPayloadMap
              (string-hash-payload-map-put map key default-value)]
            (StringHashPayloadMapEntryOrInsertInserted updated default-value))]))))

(cfg
  test
  (define (string-hash-payload-map-mut-entry-info
    [slots : (Array StringHashPayloadMapSlot)]
    [capacity : i64]
    [key : (& key str)]) : StringHashPayloadMapMutEntryInfo
    (if (<= capacity 0)
      (StringHashPayloadMapMutEntryInfo -1 false "" 0)
      (let
        [hash : i64 (string-hash-payload-map-hash-key key)]
        [cursor : i64 (string-hash-payload-map-bucket-index hash capacity)]
        [walked : i64 0]
        [found : i64 -1]
        [present : bool false]
        [entry-key : String ""]
        [entry-hash : i64 0]
        [done : bool false]
        (begin
          (while (if (< walked capacity)
            (not done)
            false)
            (match (array-ref slots cursor)
              [(StringHashPayloadMapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (string-hash-payload-map-key-eq? (& slot-key) key)
                  false)
                  (begin
                    (set! found cursor)
                    (set! present true)
                    (set! entry-key slot-key)
                    (set! entry-hash slot-hash)
                    (set! done true))
                  (begin
                    (set!
                      cursor
                      (string-hash-payload-map-next-index cursor capacity))
                    (set! walked (+ walked 1))))]
              [(StringHashPayloadMapEmpty) (set! done true)]
              [(StringHashPayloadMapTombstone)
                (begin
                  (set!
                    cursor
                    (string-hash-payload-map-next-index cursor capacity))
                  (set! walked (+ walked 1)))]))
          (StringHashPayloadMapMutEntryInfo found present entry-key entry-hash))))))

(cfg
  test
  (define (string-hash-payload-map-mut-entry-from-info
    [info : StringHashPayloadMapMutEntryInfo]
    [slots : (Array StringHashPayloadMapSlot)]
    [borrow : (&mut map (Array StringHashPayloadMapSlot))]) : (StringHashPayloadMapMutEntry
      map)
    (StringHashPayloadMapMutEntry
      slots
      borrow
      (struct-get info index)
      (struct-get info present)
      (struct-get info key)
      (struct-get info hash))))

(cfg
  test
  (defmacro (string-hash-payload-map-get-mut-entry-borrowed
    [map : Expr]
    [key : Expr]) : Expr
    `(string-hash-payload-map-mut-entry-from-info
      (string-hash-payload-map-mut-entry-info
        (struct-get ,map slots)
        (array-length (struct-get ,map slots))
        ,key)
      (struct-get ,map slots)
      (&mut (struct-get ,map slots)))))

(cfg
  test
  (define (string-hash-payload-map-mut-entry-present?
    [entry : (StringHashPayloadMapMutEntry map)]) : bool
    (struct-get entry present)))

(cfg
  test
  (define (string-hash-payload-map-mut-entry-value-or
    [entry : (StringHashPayloadMapMutEntry map)]
    [fallback : HashPayload]) : HashPayload
    (if (string-hash-payload-map-mut-entry-present? entry)
      (match (array-ref (struct-get entry slots) (struct-get entry index))
        [(StringHashPayloadMapOccupied _ value _) value]
        [(StringHashPayloadMapEmpty) fallback]
        [(StringHashPayloadMapTombstone) fallback])
      fallback)))

(cfg
  test
  (define (string-hash-payload-map-mut-entry-set!
    [entry : (StringHashPayloadMapMutEntry map)]
    [value : HashPayload]) : unit
    (if (string-hash-payload-map-mut-entry-present? entry)
      (array-set!
        (struct-get entry slots)
        (struct-get entry index)
        (StringHashPayloadMapOccupied
          (struct-get entry key)
          value
          (struct-get entry hash)))
      unit)))

(cfg
  test
  (defenum StringHashPayloadMapEntry
    (StringHashPayloadMapEntryNone)
    (StringHashPayloadMapEntrySome String HashPayload)))

(cfg
  test
  (define (string-hash-payload-map-next-occupied-from
    [slots : (Array StringHashPayloadMapSlot)]
    [index : i64]
    [capacity : i64]) : i64
    (if (>= index capacity)
      capacity
      (match (array-ref slots index)
        [(StringHashPayloadMapOccupied _ _ _) index]
        [(StringHashPayloadMapEmpty)
          (string-hash-payload-map-next-occupied-from
            slots
            (+ index 1)
            capacity)]
        [(StringHashPayloadMapTombstone)
          (string-hash-payload-map-next-occupied-from
            slots
            (+ index 1)
            capacity)]))))

(cfg
  test
  (define (string-hash-payload-map-next-occupied
    [map : StringHashPayloadMap]
    [from : i64]) : i64
    (string-hash-payload-map-next-occupied-from
      (string-hash-payload-map-slots map)
      (if (< from 0)
        0
        from)
      (string-hash-payload-map-capacity map))))

(cfg
  test
  (define (string-hash-payload-map-entry-at
    [map : StringHashPayloadMap]
    [index : i64]) : StringHashPayloadMapEntry
    (if (if (< index 0)
      true
      (>= index (string-hash-payload-map-capacity map)))
      (StringHashPayloadMapEntryNone)
      (match (array-ref (string-hash-payload-map-slots map) index)
        [(StringHashPayloadMapOccupied key value _)
          (StringHashPayloadMapEntrySome key value)]
        [(StringHashPayloadMapEmpty) (StringHashPayloadMapEntryNone)]
        [(StringHashPayloadMapTombstone) (StringHashPayloadMapEntryNone)]))))

;: Checked-in `I64HashStateMap` fixture family.
(cfg
  test
  (defenum I64HashStateMapSlot
    (I64HashStateMapEmpty)
    (I64HashStateMapTombstone)
    (I64HashStateMapOccupied i64 HashState i64)))

(cfg
  test
  (defenum I64HashStateMapProbe
    (I64HashStateMapProbeFound i64)
    (I64HashStateMapProbeAbsent i64)
    (I64HashStateMapProbeFull)))

(cfg
  test
  (define (i64-hash-state-map-hash-normalize [value : i64]) : i64
    (let
      [m : i64 2147483647]
      [raw : i64 (% value 2147483647)]
      (if (< raw 0)
        (+ raw m)
        raw))))

(cfg
  test
  (define (i64-hash-state-map-hash-key [key : i64]) : i64
    (i64-hash-state-map-hash-normalize (* key 6364136223846793005))))

(cfg
  test
  (define (i64-hash-state-map-power-two-capacity? [capacity : i64]) : bool
    (if (> capacity 0)
      (= (bit-and capacity (- capacity 1)) 0)
      false)))

(cfg
  test
  (define (i64-hash-state-map-round-capacity [capacity : i64]) : i64
    (let
      [rounded : i64 1]
      (begin
        (while (< rounded capacity)
          (set! rounded (* rounded 2)))
        rounded))))

(cfg
  test
  (define (i64-hash-state-map-normalized-bucket-index
    [hash : i64]
    [capacity : i64]) : i64
    (bit-and hash (- capacity 1))))

(cfg
  test
  (define (i64-hash-state-map-bucket-index [hash : i64] [capacity : i64]) : i64
    (i64-hash-state-map-normalized-bucket-index
      (i64-hash-state-map-hash-normalize hash)
      capacity)))

(cfg
  test
  (define (i64-hash-state-map-next-index [index : i64] [capacity : i64]) : i64
    (let
      [next : i64 (+ index 1)]
      (if (>= next capacity)
        0
        next))))

(cfg
  test
  (define (i64-hash-state-map-insert-slot
    [first-tombstone : i64]
    [empty-index : i64]) : i64
    (if (>= first-tombstone 0)
      first-tombstone
      empty-index)))

(cfg
  test
  (define (i64-hash-state-map-probe-from
    [slots : (Array I64HashStateMapSlot)]
    [capacity : i64]
    [key : i64]
    [hash : i64]
    [index : i64]
    [steps : i64]
    [first-tombstone : i64]) : I64HashStateMapProbe
    (let
      [cursor : i64 index]
      [walked : i64 steps]
      [first : i64 first-tombstone]
      (begin
        (while (< walked capacity)
          (match (array-ref slots cursor)
            [(I64HashStateMapEmpty)
              (return
                (I64HashStateMapProbeAbsent
                  (i64-hash-state-map-insert-slot first cursor)))]
            [(I64HashStateMapTombstone)
              (let
                [next : i64 (+ cursor 1)]
                (begin
                  (if (< first 0)
                    (set! first cursor)
                    unit)
                  (set!
                    cursor
                    (if (>= next capacity)
                      0
                      next))
                  (set! walked (+ walked 1))))]
            [(I64HashStateMapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (= slot-key key)
                false)
                (return (I64HashStateMapProbeFound cursor))
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1)))))]))
        (if (>= first 0)
          (I64HashStateMapProbeAbsent first)
          (I64HashStateMapProbeFull))))))

(cfg
  test
  (define (i64-hash-state-map-probe
    [slots : (Array I64HashStateMapSlot)]
    [capacity : i64]
    [key : i64]
    [hash : i64]) : I64HashStateMapProbe
    (if (<= capacity 0)
      (I64HashStateMapProbeFull)
      (i64-hash-state-map-probe-from
        slots
        capacity
        key
        hash
        (i64-hash-state-map-normalized-bucket-index hash capacity)
        0
        -1))))

(cfg
  test
  (defstruct I64HashStateMap
    (slots (Array I64HashStateMapSlot))
    (len i64)
    (deleted i64)))

(cfg
  test
  (defenum I64HashStateMapLookup
    (I64HashStateMapMissing)
    (I64HashStateMapFound HashState)))

(cfg
  test
  (defenum I64HashStateMapBorrowedValueLookup
    (:lifetimes map)
    (I64HashStateMapBorrowedValueMissing)
    (I64HashStateMapBorrowedValueFound (& map HashState))))

(cfg
  test
  (defenum I64HashStateMapInsertResult
    (I64HashStateMapInsertOk I64HashStateMap)
    (I64HashStateMapInsertFull I64HashStateMap)))

(cfg
  test
  (defenum I64HashStateMapRemoveResult
    (I64HashStateMapRemoveOk I64HashStateMap)
    (I64HashStateMapRemoveMissing I64HashStateMap)))

(cfg
  test
  (defenum I64HashStateMapUpdateResult
    (I64HashStateMapUpdateOk I64HashStateMap)
    (I64HashStateMapUpdateMissing I64HashStateMap)))

(cfg
  test
  (defenum I64HashStateMapEntryOrInsertResult
    (I64HashStateMapEntryOrInsertFound I64HashStateMap HashState)
    (I64HashStateMapEntryOrInsertInserted I64HashStateMap HashState)))

(cfg
  test
  (defstruct I64HashStateMapMutEntryInfo
    (index i64)
    (present bool)
    (key i64)
    (hash i64)))

(cfg
  test
  (defstruct I64HashStateMapMutEntry
    (:lifetimes map)
    (slots (Array I64HashStateMapSlot))
    (borrow (&mut map (Array I64HashStateMapSlot)))
    (index i64)
    (present bool)
    (key i64)
    (hash i64)))

(cfg
  test
  (define (i64-hash-state-map-slots [map : I64HashStateMap]) : (Array
      I64HashStateMapSlot)
    (struct-get map slots)))

(cfg
  test
  (define (i64-hash-state-map-len [map : I64HashStateMap]) : i64
    (struct-get map len)))

(cfg
  test
  (define (i64-hash-state-map-capacity [map : I64HashStateMap]) : i64
    (array-length (struct-get map slots))))

(cfg
  test
  (define (i64-hash-state-map-deleted [map : I64HashStateMap]) : i64
    (struct-get map deleted)))

(cfg
  test
  (define (i64-hash-state-map-fill-empty
    [slots : (Array I64HashStateMapSlot)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! slots index (I64HashStateMapEmpty))
        (i64-hash-state-map-fill-empty slots (+ index 1) count)))))

(cfg
  test
  (define (i64-hash-state-map-with-capacity [capacity : i64]) : I64HashStateMap
    (let
      [rounded-capacity : i64 (i64-hash-state-map-round-capacity capacity)]
      [slots : (Array I64HashStateMapSlot)
        (make-array I64HashStateMapSlot rounded-capacity)]
      (begin
        (i64-hash-state-map-fill-empty slots 0 rounded-capacity)
        (I64HashStateMap slots 0 0)))))

(cfg
  test
  (define (i64-hash-state-map-borrowed-value-missing
    [map : (& map I64HashStateMap)]) : (I64HashStateMapBorrowedValueLookup map)
    (I64HashStateMapBorrowedValueMissing)))

(cfg
  test
  (define (i64-hash-state-map-borrowed-value-found [value : (& map HashState)]) : (I64HashStateMapBorrowedValueLookup
      map)
    (I64HashStateMapBorrowedValueFound value)))

(cfg
  test
  (define (i64-hash-state-map-get [map : I64HashStateMap] [key : i64]) : I64HashStateMapLookup
    (let
      [slots : (Array I64HashStateMapSlot) (i64-hash-state-map-slots map)]
      (match (i64-hash-state-map-probe
        slots
        (i64-hash-state-map-capacity map)
        key
        (i64-hash-state-map-hash-key key))
        [(I64HashStateMapProbeFound index)
          (match (array-ref slots index)
            [(I64HashStateMapOccupied _ value _) (I64HashStateMapFound value)]
            [(I64HashStateMapEmpty) (I64HashStateMapMissing)]
            [(I64HashStateMapTombstone) (I64HashStateMapMissing)])]
        [(I64HashStateMapProbeAbsent _) (I64HashStateMapMissing)]
        [(I64HashStateMapProbeFull) (I64HashStateMapMissing)]))))

(cfg
  test
  (define (i64-hash-state-map-get-ref
    [map : (& map I64HashStateMap)]
    [key : i64]) : I64HashStateMapLookup
    (let
      [capacity : i64 (array-length (struct-get map slots))]
      (if (<= capacity 0)
        (I64HashStateMapMissing)
        (let
          [hash : i64 (i64-hash-state-map-hash-key key)]
          [cursor : i64
            (i64-hash-state-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref (struct-get map slots) cursor)
                [(I64HashStateMapEmpty) (return (I64HashStateMapMissing))]
                [(I64HashStateMapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(I64HashStateMapOccupied slot-key value slot-hash)
                  (if (if (= slot-hash hash)
                    (= slot-key key)
                    false)
                    (return (I64HashStateMapFound (clone value)))
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            (I64HashStateMapMissing)))))))

(cfg
  test
  (define (i64-hash-state-map-get-value-borrowed
    [map : (& map I64HashStateMap)]
    [key : i64]) : (I64HashStateMapBorrowedValueLookup map)
    (let
      [capacity : i64 (array-length (struct-get map slots))]
      (if (<= capacity 0)
        (i64-hash-state-map-borrowed-value-missing map)
        (let
          [hash : i64 (i64-hash-state-map-hash-key key)]
          [cursor : i64
            (i64-hash-state-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref (struct-get map slots) cursor)
                [(I64HashStateMapEmpty)
                  (return (i64-hash-state-map-borrowed-value-missing map))]
                [(I64HashStateMapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(I64HashStateMapOccupied slot-key _ slot-hash)
                  (if (if (= slot-hash hash)
                    (= slot-key key)
                    false)
                    (match (& (array-ref (struct-get map slots) cursor))
                      [(I64HashStateMapOccupied _ value _)
                        (return (i64-hash-state-map-borrowed-value-found value))]
                      [(I64HashStateMapEmpty)
                        (return (i64-hash-state-map-borrowed-value-missing map))]
                      [(I64HashStateMapTombstone)
                        (return (i64-hash-state-map-borrowed-value-missing map))])
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            (i64-hash-state-map-borrowed-value-missing map)))))))

(cfg
  test
  (define (i64-hash-state-map-contains? [map : I64HashStateMap] [key : i64]) : bool
    (match (i64-hash-state-map-get map key)
      [(I64HashStateMapFound _) true]
      [(I64HashStateMapMissing) false])))

(cfg
  test
  (define (i64-hash-state-map-slot-tombstone? [slot : I64HashStateMapSlot]) : bool
    (match slot
      [(I64HashStateMapTombstone) true]
      [(I64HashStateMapEmpty) false]
      [(I64HashStateMapOccupied _ _ _) false])))

(cfg
  test
  (define (i64-hash-state-map-insert
    [map : I64HashStateMap]
    [key : i64]
    [value : HashState]) : I64HashStateMapInsertResult
    (let
      [slots : (Array I64HashStateMapSlot) (i64-hash-state-map-slots map)]
      [hash : i64 (i64-hash-state-map-hash-key key)]
      (match (i64-hash-state-map-probe
        slots
        (i64-hash-state-map-capacity map)
        key
        hash)
        [(I64HashStateMapProbeFound index)
          (begin
            (array-set! slots index (I64HashStateMapOccupied key value hash))
            (I64HashStateMapInsertOk map))]
        [(I64HashStateMapProbeAbsent index)
          (let
            [reused-tombstone : bool
              (i64-hash-state-map-slot-tombstone? (array-ref slots index))]
            (begin
              (array-set! slots index (I64HashStateMapOccupied key value hash))
              (set! (struct-get map len) (+ (i64-hash-state-map-len map) 1))
              (if reused-tombstone
                (set!
                  (struct-get map deleted)
                  (- (i64-hash-state-map-deleted map) 1))
                unit)
              (I64HashStateMapInsertOk map)))]
        [(I64HashStateMapProbeFull) (I64HashStateMapInsertFull map)]))))

(cfg
  test
  (define (i64-hash-state-map-remove [map : I64HashStateMap] [key : i64]) : I64HashStateMapRemoveResult
    (let
      [slots : (Array I64HashStateMapSlot) (i64-hash-state-map-slots map)]
      (match (i64-hash-state-map-probe
        slots
        (i64-hash-state-map-capacity map)
        key
        (i64-hash-state-map-hash-key key))
        [(I64HashStateMapProbeFound index)
          (begin
            (array-set! slots index (I64HashStateMapTombstone))
            (set! (struct-get map len) (- (i64-hash-state-map-len map) 1))
            (set!
              (struct-get map deleted)
              (+ (i64-hash-state-map-deleted map) 1))
            (I64HashStateMapRemoveOk map))]
        [(I64HashStateMapProbeAbsent _) (I64HashStateMapRemoveMissing map)]
        [(I64HashStateMapProbeFull) (I64HashStateMapRemoveMissing map)]))))

(cfg
  test
  (define (i64-hash-state-map-update-if-present
    [map : I64HashStateMap]
    [key : i64]
    [value : HashState]) : I64HashStateMapUpdateResult
    (let
      [slots : (Array I64HashStateMapSlot) (i64-hash-state-map-slots map)]
      [hash : i64 (i64-hash-state-map-hash-key key)]
      (match (i64-hash-state-map-probe
        slots
        (i64-hash-state-map-capacity map)
        key
        hash)
        [(I64HashStateMapProbeFound index)
          (match (array-ref slots index)
            [(I64HashStateMapOccupied slot-key _ slot-hash)
              (begin
                (array-set!
                  slots
                  index
                  (I64HashStateMapOccupied slot-key value slot-hash))
                (I64HashStateMapUpdateOk map))]
            [(I64HashStateMapEmpty) (I64HashStateMapUpdateMissing map)]
            [(I64HashStateMapTombstone) (I64HashStateMapUpdateMissing map)])]
        [(I64HashStateMapProbeAbsent _) (I64HashStateMapUpdateMissing map)]
        [(I64HashStateMapProbeFull) (I64HashStateMapUpdateMissing map)]))))

(cfg
  test
  (define (i64-hash-state-map-insert-into-empty
    [slots : (Array I64HashStateMapSlot)]
    [capacity : i64]
    [key : i64]
    [value : HashState]
    [hash : i64]) : unit
    (if (<= capacity 0)
      unit
      (let
        [cursor : i64
          (i64-hash-state-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        [done : bool false]
        (begin
          (while (if done
            false
            (< walked capacity))
            (match (array-ref slots cursor)
              [(I64HashStateMapEmpty)
                (begin
                  (array-set!
                    slots
                    cursor
                    (I64HashStateMapOccupied key value hash))
                  (set! done true))]
              [_
                (begin
                  (set! cursor (i64-hash-state-map-next-index cursor capacity))
                  (set! walked (+ walked 1)))]))
          unit)))))

(cfg
  test
  (define (i64-hash-state-map-rehash-from
    [src : (Array I64HashStateMapSlot)]
    [dst : (Array I64HashStateMapSlot)]
    [dst-capacity : i64]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (match (array-ref src index)
          [(I64HashStateMapOccupied key value hash)
            (i64-hash-state-map-insert-into-empty
              dst
              dst-capacity
              key
              value
              hash)]
          [(I64HashStateMapEmpty) unit]
          [(I64HashStateMapTombstone) unit])
        (i64-hash-state-map-rehash-from src dst dst-capacity (+ index 1) count)))))

(cfg
  test
  (define (i64-hash-state-map-rehash-from-ref
    [src : (& src (Array I64HashStateMapSlot))]
    [dst : (Array I64HashStateMapSlot)]
    [dst-capacity : i64]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (match (array-ref src index)
          [(I64HashStateMapOccupied key value hash)
            (i64-hash-state-map-insert-into-empty
              dst
              dst-capacity
              key
              (clone value)
              hash)]
          [(I64HashStateMapEmpty) unit]
          [(I64HashStateMapTombstone) unit])
        (i64-hash-state-map-rehash-from-ref
          src
          dst
          dst-capacity
          (+ index 1)
          count)))))

(cfg
  test
  (define (i64-hash-state-map-resized
    [map : I64HashStateMap]
    [new-capacity : i64]) : I64HashStateMap
    (let
      [src : (Array I64HashStateMapSlot) (i64-hash-state-map-slots map)]
      [old-capacity : i64 (i64-hash-state-map-capacity map)]
      [requested-capacity : i64
        (if (> (i64-hash-state-map-len map) new-capacity)
          (i64-hash-state-map-len map)
          new-capacity)]
      [rounded-capacity : i64
        (i64-hash-state-map-round-capacity requested-capacity)]
      [dst : (Array I64HashStateMapSlot)
        (make-array I64HashStateMapSlot rounded-capacity)]
      (begin
        (i64-hash-state-map-fill-empty dst 0 rounded-capacity)
        (i64-hash-state-map-rehash-from src dst rounded-capacity 0 old-capacity)
        (set! (struct-get map slots) dst)
        (set! (struct-get map deleted) 0)
        map))))

(cfg
  test
  (define (i64-hash-state-map-grow-capacity [capacity : i64]) : i64
    (if (< capacity 4)
      8
      (* (i64-hash-state-map-round-capacity capacity) 2))))

(cfg
  test
  (define (i64-hash-state-map-grow [map : I64HashStateMap]) : I64HashStateMap
    (i64-hash-state-map-resized
      map
      (i64-hash-state-map-grow-capacity (i64-hash-state-map-capacity map)))))

(cfg
  test
  (define (i64-hash-state-map-needs-grow? [map : I64HashStateMap]) : bool
    (let
      [capacity : i64 (i64-hash-state-map-capacity map)]
      [used : i64
        (+ (i64-hash-state-map-len map) (i64-hash-state-map-deleted map))]
      (if (<= capacity 0)
        true
        (>= (* used 4) (* capacity 3))))))

(cfg
  test
  (define (i64-hash-state-map-resized!
    [map : (&mut map I64HashStateMap)]
    [new-capacity : i64]) : unit
    (let
      [old-capacity : i64 (array-length (struct-get map slots))]
      [requested-capacity : i64
        (if (> (struct-get map len) new-capacity)
          (struct-get map len)
          new-capacity)]
      [rounded-capacity : i64
        (i64-hash-state-map-round-capacity requested-capacity)]
      [dst : (Array I64HashStateMapSlot)
        (make-array I64HashStateMapSlot rounded-capacity)]
      (begin
        (i64-hash-state-map-fill-empty dst 0 rounded-capacity)
        (i64-hash-state-map-rehash-from-ref
          (& (struct-get map slots))
          dst
          rounded-capacity
          0
          old-capacity)
        (set! (struct-get map slots) dst)
        (set! (struct-get map deleted) 0)))))

(cfg
  test
  (define (i64-hash-state-map-put!
    [map : (&mut map I64HashStateMap)]
    [key : i64]
    [value : HashState]) : unit
    (let
      [capacity-before : i64 (array-length (struct-get map slots))]
      [used-before : i64 (+ (struct-get map len) (struct-get map deleted))]
      (begin
        (if (if (<= capacity-before 0)
          true
          (>= (* used-before 4) (* capacity-before 3)))
          (i64-hash-state-map-resized!
            map
            (i64-hash-state-map-grow-capacity capacity-before))
          unit)
        (let
          [slots : (&mut map (Array I64HashStateMapSlot))
            (&mut (struct-get map slots))]
          [capacity : i64 (array-length slots)]
          [hash : i64 (i64-hash-state-map-hash-key key)]
          (if (<= capacity 0)
            unit
            (let
              [cursor : i64
                (i64-hash-state-map-normalized-bucket-index hash capacity)]
              [walked : i64 0]
              [first : i64 -1]
              (begin
                (while (< walked capacity)
                  (match (array-ref slots cursor)
                    [(I64HashStateMapEmpty)
                      (let
                        [index : i64
                          (if (>= first 0)
                            first
                            cursor)]
                        [reused-tombstone : bool (>= first 0)]
                        (begin
                          (array-set!
                            slots
                            index
                            (I64HashStateMapOccupied key value hash))
                          (set! (struct-get map len) (+ (struct-get map len) 1))
                          (if reused-tombstone
                            (set!
                              (struct-get map deleted)
                              (- (struct-get map deleted) 1))
                            unit)
                          (return unit)))]
                    [(I64HashStateMapTombstone)
                      (let
                        [next : i64 (+ cursor 1)]
                        (begin
                          (if (< first 0)
                            (set! first cursor)
                            unit)
                          (set!
                            cursor
                            (if (>= next capacity)
                              0
                              next))
                          (set! walked (+ walked 1))))]
                    [(I64HashStateMapOccupied slot-key _ slot-hash)
                      (if (if (= slot-hash hash)
                        (= slot-key key)
                        false)
                        (begin
                          (array-set!
                            slots
                            cursor
                            (I64HashStateMapOccupied key value hash))
                          (return unit))
                        (let
                          [next : i64 (+ cursor 1)]
                          (begin
                            (set!
                              cursor
                              (if (>= next capacity)
                                0
                                next))
                            (set! walked (+ walked 1)))))]))
                (if (>= first 0)
                  (begin
                    (array-set!
                      slots
                      first
                      (I64HashStateMapOccupied key value hash))
                    (set! (struct-get map len) (+ (struct-get map len) 1))
                    (set!
                      (struct-get map deleted)
                      (- (struct-get map deleted) 1)))
                  unit)))))))))

(cfg
  test
  (define (i64-hash-state-map-remove!
    [map : (&mut map I64HashStateMap)]
    [key : i64]) : bool
    (let
      [slots : (&mut map (Array I64HashStateMapSlot))
        (&mut (struct-get map slots))]
      [capacity : i64 (array-length slots)]
      (if (<= capacity 0)
        false
        (let
          [hash : i64 (i64-hash-state-map-hash-key key)]
          [cursor : i64
            (i64-hash-state-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref slots cursor)
                [(I64HashStateMapEmpty) (return false)]
                [(I64HashStateMapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(I64HashStateMapOccupied slot-key _ slot-hash)
                  (if (if (= slot-hash hash)
                    (= slot-key key)
                    false)
                    (begin
                      (array-set! slots cursor (I64HashStateMapTombstone))
                      (set! (struct-get map len) (- (struct-get map len) 1))
                      (set!
                        (struct-get map deleted)
                        (+ (struct-get map deleted) 1))
                      (return true))
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            false))))))

(cfg
  test
  (define (i64-hash-state-map-put
    [map : I64HashStateMap]
    [key : i64]
    [value : HashState]) : I64HashStateMap
    (let
      [grown : I64HashStateMap
        (if (i64-hash-state-map-needs-grow? map)
          (i64-hash-state-map-grow map)
          map)]
      (match (i64-hash-state-map-insert grown key value)
        [(I64HashStateMapInsertOk updated) updated]
        [(I64HashStateMapInsertFull full)
          (match (i64-hash-state-map-insert
            (i64-hash-state-map-grow full)
            key
            value)
            [(I64HashStateMapInsertOk u) u]
            [(I64HashStateMapInsertFull u) u])]))))

(cfg
  test
  (define (i64-hash-state-map-insert-or-update
    [map : I64HashStateMap]
    [key : i64]
    [value : HashState]) : I64HashStateMap
    (i64-hash-state-map-put map key value)))

(cfg
  test
  (define (i64-hash-state-map-entry-or-insert
    [map : I64HashStateMap]
    [key : i64]
    [default-value : HashState]) : I64HashStateMapEntryOrInsertResult
    (let
      [slots : (Array I64HashStateMapSlot) (i64-hash-state-map-slots map)]
      [hash : i64 (i64-hash-state-map-hash-key key)]
      (match (i64-hash-state-map-probe
        slots
        (i64-hash-state-map-capacity map)
        key
        hash)
        [(I64HashStateMapProbeFound index)
          (match (array-ref slots index)
            [(I64HashStateMapOccupied _ value _)
              (I64HashStateMapEntryOrInsertFound map value)]
            [(I64HashStateMapEmpty)
              (let
                [updated : I64HashStateMap
                  (i64-hash-state-map-put map key default-value)]
                (I64HashStateMapEntryOrInsertInserted updated default-value))]
            [(I64HashStateMapTombstone)
              (let
                [updated : I64HashStateMap
                  (i64-hash-state-map-put map key default-value)]
                (I64HashStateMapEntryOrInsertInserted updated default-value))])]
        [(I64HashStateMapProbeAbsent _)
          (let
            [updated : I64HashStateMap
              (i64-hash-state-map-put map key default-value)]
            (I64HashStateMapEntryOrInsertInserted updated default-value))]
        [(I64HashStateMapProbeFull)
          (let
            [updated : I64HashStateMap
              (i64-hash-state-map-put map key default-value)]
            (I64HashStateMapEntryOrInsertInserted updated default-value))]))))

(cfg
  test
  (define (i64-hash-state-map-mut-entry-info
    [slots : (Array I64HashStateMapSlot)]
    [capacity : i64]
    [key : i64]) : I64HashStateMapMutEntryInfo
    (if (<= capacity 0)
      (I64HashStateMapMutEntryInfo -1 false 0 0)
      (let
        [hash : i64 (i64-hash-state-map-hash-key key)]
        [cursor : i64 (i64-hash-state-map-bucket-index hash capacity)]
        [walked : i64 0]
        [found : i64 -1]
        [present : bool false]
        [entry-key : i64 0]
        [entry-hash : i64 0]
        [done : bool false]
        (begin
          (while (if (< walked capacity)
            (not done)
            false)
            (match (array-ref slots cursor)
              [(I64HashStateMapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (= slot-key key)
                  false)
                  (begin
                    (set! found cursor)
                    (set! present true)
                    (set! entry-key slot-key)
                    (set! entry-hash slot-hash)
                    (set! done true))
                  (begin
                    (set!
                      cursor
                      (i64-hash-state-map-next-index cursor capacity))
                    (set! walked (+ walked 1))))]
              [(I64HashStateMapEmpty) (set! done true)]
              [(I64HashStateMapTombstone)
                (begin
                  (set! cursor (i64-hash-state-map-next-index cursor capacity))
                  (set! walked (+ walked 1)))]))
          (I64HashStateMapMutEntryInfo found present entry-key entry-hash))))))

(cfg
  test
  (define (i64-hash-state-map-mut-entry-from-info
    [info : I64HashStateMapMutEntryInfo]
    [slots : (Array I64HashStateMapSlot)]
    [borrow : (&mut map (Array I64HashStateMapSlot))]) : (I64HashStateMapMutEntry
      map)
    (I64HashStateMapMutEntry
      slots
      borrow
      (struct-get info index)
      (struct-get info present)
      (struct-get info key)
      (struct-get info hash))))

(cfg
  test
  (defmacro (i64-hash-state-map-get-mut-entry [map : Expr] [key : Expr]) : Expr
    `(i64-hash-state-map-mut-entry-from-info
      (i64-hash-state-map-mut-entry-info
        (struct-get ,map slots)
        (array-length (struct-get ,map slots))
        ,key)
      (struct-get ,map slots)
      (&mut (struct-get ,map slots)))))

(cfg
  test
  (define (i64-hash-state-map-mut-entry-present?
    [entry : (I64HashStateMapMutEntry map)]) : bool
    (struct-get entry present)))

(cfg
  test
  (define (i64-hash-state-map-mut-entry-value-or
    [entry : (I64HashStateMapMutEntry map)]
    [fallback : HashState]) : HashState
    (if (i64-hash-state-map-mut-entry-present? entry)
      (match (array-ref (struct-get entry slots) (struct-get entry index))
        [(I64HashStateMapOccupied _ value _) value]
        [(I64HashStateMapEmpty) fallback]
        [(I64HashStateMapTombstone) fallback])
      fallback)))

(cfg
  test
  (define (i64-hash-state-map-mut-entry-set!
    [entry : (I64HashStateMapMutEntry map)]
    [value : HashState]) : unit
    (if (i64-hash-state-map-mut-entry-present? entry)
      (array-set!
        (struct-get entry slots)
        (struct-get entry index)
        (I64HashStateMapOccupied
          (struct-get entry key)
          value
          (struct-get entry hash)))
      unit)))

(cfg
  test
  (defenum I64HashStateMapEntry
    (I64HashStateMapEntryNone)
    (I64HashStateMapEntrySome i64 HashState)))

(cfg
  test
  (define (i64-hash-state-map-next-occupied-from
    [slots : (Array I64HashStateMapSlot)]
    [index : i64]
    [capacity : i64]) : i64
    (if (>= index capacity)
      capacity
      (match (array-ref slots index)
        [(I64HashStateMapOccupied _ _ _) index]
        [(I64HashStateMapEmpty)
          (i64-hash-state-map-next-occupied-from slots (+ index 1) capacity)]
        [(I64HashStateMapTombstone)
          (i64-hash-state-map-next-occupied-from slots (+ index 1) capacity)]))))

(cfg
  test
  (define (i64-hash-state-map-next-occupied
    [map : I64HashStateMap]
    [from : i64]) : i64
    (i64-hash-state-map-next-occupied-from
      (i64-hash-state-map-slots map)
      (if (< from 0)
        0
        from)
      (i64-hash-state-map-capacity map))))

(cfg
  test
  (define (i64-hash-state-map-entry-at [map : I64HashStateMap] [index : i64]) : I64HashStateMapEntry
    (if (if (< index 0)
      true
      (>= index (i64-hash-state-map-capacity map)))
      (I64HashStateMapEntryNone)
      (match (array-ref (i64-hash-state-map-slots map) index)
        [(I64HashStateMapOccupied key value _)
          (I64HashStateMapEntrySome key value)]
        [(I64HashStateMapEmpty) (I64HashStateMapEntryNone)]
        [(I64HashStateMapTombstone) (I64HashStateMapEntryNone)]))))

;: Checked-in `HashNestedKeyI64Map` fixture family.
(cfg
  test
  (defenum HashNestedKeyI64MapSlot
    (HashNestedKeyI64MapEmpty)
    (HashNestedKeyI64MapTombstone)
    (HashNestedKeyI64MapOccupied HashNestedKey i64 i64)))

(cfg
  test
  (defenum HashNestedKeyI64MapProbe
    (HashNestedKeyI64MapProbeFound i64)
    (HashNestedKeyI64MapProbeAbsent i64)
    (HashNestedKeyI64MapProbeFull)))

(cfg
  test
  (define (hash-nested-key-i64-map-hash-normalize [value : i64]) : i64
    (let
      [m : i64 2147483647]
      [raw : i64 (% value 2147483647)]
      (if (< raw 0)
        (+ raw m)
        raw))))

(cfg
  test
  (define (hash-nested-key-i64-map-hash-combine [seed : i64] [component : i64]) : i64
    (hash-nested-key-i64-map-hash-normalize
      (+
        (+
          (* (hash-nested-key-i64-map-hash-normalize seed) 131)
          (hash-nested-key-i64-map-hash-normalize component))
        1))))

(cfg
  test
  (define (hash-nested-key-i64-map-string-hash [key : (& key str)]) : i64
    (let
      [n : i64 (__tl_string_length key)]
      [i : i64 0]
      [hash : i64 0]
      (begin
        (while (< i n)
          (begin
            (set!
              hash
              (%
                (+ (+ (* hash 131) (cast (__tl_string_ref key i) : i64)) 1)
                2147483647))
            (set! i (+ i 1))))
        hash))))

(cfg
  test
  (define (hash-nested-key-i64-map-string-key-eq?
    [left : (& left str)]
    [right : (& right str)]) : bool
    (__tl_string_eq left right)))

(cfg
  test
  (define (hash-nested-key-i64-map-hash-key [key : (& key HashNestedKey)]) : i64
    (hash-nested-key-i64-map-hash-combine
      (hash-nested-key-i64-map-hash-combine
        0
        (hash-nested-key-i64-map-hash-combine
          (hash-nested-key-i64-map-hash-combine
            (hash-nested-key-i64-map-hash-combine
              (hash-nested-key-i64-map-hash-combine
                0
                (hash-nested-key-i64-map-hash-normalize
                  (struct-get (struct-get key point) x)))
              (if (struct-get (struct-get key point) enabled)
                1
                0))
            (hash-nested-key-i64-map-string-hash
              (& (struct-get (struct-get key point) label))))
          (hash-nested-key-i64-map-hash-normalize
            (cast (struct-get (struct-get key point) code) : i64))))
      (match (struct-get key tag)
        [(HashTagNone)
          (hash-nested-key-i64-map-hash-combine
            0
            (hash-nested-key-i64-map-hash-normalize 0))]
        [(HashTagNumber hashmap-payload-1-0)
          (hash-nested-key-i64-map-hash-combine
            (hash-nested-key-i64-map-hash-combine
              0
              (hash-nested-key-i64-map-hash-normalize 1))
            (hash-nested-key-i64-map-hash-normalize hashmap-payload-1-0))]
        [(HashTagOtherNumber hashmap-payload-2-0)
          (hash-nested-key-i64-map-hash-combine
            (hash-nested-key-i64-map-hash-combine
              0
              (hash-nested-key-i64-map-hash-normalize 2))
            (hash-nested-key-i64-map-hash-normalize hashmap-payload-2-0))]
        [(HashTagText
            hashmap-payload-3-0
            hashmap-payload-3-1
            hashmap-payload-3-2)
          (hash-nested-key-i64-map-hash-combine
            (hash-nested-key-i64-map-hash-combine
              (hash-nested-key-i64-map-hash-combine
                (hash-nested-key-i64-map-hash-combine
                  0
                  (hash-nested-key-i64-map-hash-normalize 3))
                (if hashmap-payload-3-0
                  1
                  0))
              (hash-nested-key-i64-map-string-hash (& hashmap-payload-3-1)))
            (hash-nested-key-i64-map-hash-normalize
              (cast hashmap-payload-3-2 : i64)))]))))

(cfg
  test
  (define (hash-nested-key-i64-map-key-eq?
    [left : (& left HashNestedKey)]
    [right : (& right HashNestedKey)]) : bool
    (if (if (=
      (struct-get (struct-get left point) x)
      (struct-get (struct-get right point) x))
      (if (=
        (struct-get (struct-get left point) enabled)
        (struct-get (struct-get right point) enabled))
        (if (hash-nested-key-i64-map-string-key-eq?
          (& (struct-get (struct-get left point) label))
          (& (struct-get (struct-get right point) label)))
          (if (=
            (cast (struct-get (struct-get left point) code) : i64)
            (cast (struct-get (struct-get right point) code) : i64))
            true
            false)
          false)
        false)
      false)
      (if (match (struct-get left tag)
        [(HashTagNone)
          (match (struct-get right tag)
            [(HashTagNone) true]
            [_ false])]
        [(HashTagNumber hashmap-left-1-0)
          (match (struct-get right tag)
            [(HashTagNumber hashmap-right-1-0)
              (if (= hashmap-left-1-0 hashmap-right-1-0)
                true
                false)]
            [_ false])]
        [(HashTagOtherNumber hashmap-left-2-0)
          (match (struct-get right tag)
            [(HashTagOtherNumber hashmap-right-2-0)
              (if (= hashmap-left-2-0 hashmap-right-2-0)
                true
                false)]
            [_ false])]
        [(HashTagText hashmap-left-3-0 hashmap-left-3-1 hashmap-left-3-2)
          (match (struct-get right tag)
            [(HashTagText hashmap-right-3-0 hashmap-right-3-1 hashmap-right-3-2)
              (if (= hashmap-left-3-0 hashmap-right-3-0)
                (if (hash-nested-key-i64-map-string-key-eq?
                  (& hashmap-left-3-1)
                  (& hashmap-right-3-1))
                  (if (=
                    (cast hashmap-left-3-2 : i64)
                    (cast hashmap-right-3-2 : i64))
                    true
                    false)
                  false)
                false)]
            [_ false])])
        true
        false)
      false)))

(cfg
  test
  (define (hash-nested-key-i64-map-power-two-capacity? [capacity : i64]) : bool
    (if (> capacity 0)
      (= (bit-and capacity (- capacity 1)) 0)
      false)))

(cfg
  test
  (define (hash-nested-key-i64-map-round-capacity [capacity : i64]) : i64
    (let
      [rounded : i64 1]
      (begin
        (while (< rounded capacity)
          (set! rounded (* rounded 2)))
        rounded))))

(cfg
  test
  (define (hash-nested-key-i64-map-normalized-bucket-index
    [hash : i64]
    [capacity : i64]) : i64
    (bit-and hash (- capacity 1))))

(cfg
  test
  (define (hash-nested-key-i64-map-bucket-index [hash : i64] [capacity : i64]) : i64
    (hash-nested-key-i64-map-normalized-bucket-index
      (hash-nested-key-i64-map-hash-normalize hash)
      capacity)))

(cfg
  test
  (define (hash-nested-key-i64-map-next-index [index : i64] [capacity : i64]) : i64
    (let
      [next : i64 (+ index 1)]
      (if (>= next capacity)
        0
        next))))

(cfg
  test
  (define (hash-nested-key-i64-map-insert-slot
    [first-tombstone : i64]
    [empty-index : i64]) : i64
    (if (>= first-tombstone 0)
      first-tombstone
      empty-index)))

(cfg
  test
  (define (hash-nested-key-i64-map-probe-from
    [slots : (Array HashNestedKeyI64MapSlot)]
    [capacity : i64]
    [key : (& key HashNestedKey)]
    [hash : i64]
    [index : i64]
    [steps : i64]
    [first-tombstone : i64]) : HashNestedKeyI64MapProbe
    (let
      [cursor : i64 index]
      [walked : i64 steps]
      [first : i64 first-tombstone]
      (begin
        (while (< walked capacity)
          (match (array-ref slots cursor)
            [(HashNestedKeyI64MapEmpty)
              (return
                (HashNestedKeyI64MapProbeAbsent
                  (hash-nested-key-i64-map-insert-slot first cursor)))]
            [(HashNestedKeyI64MapTombstone)
              (let
                [next : i64 (+ cursor 1)]
                (begin
                  (if (< first 0)
                    (set! first cursor)
                    unit)
                  (set!
                    cursor
                    (if (>= next capacity)
                      0
                      next))
                  (set! walked (+ walked 1))))]
            [(HashNestedKeyI64MapOccupied slot-key _ slot-hash)
              (if (if (= slot-hash hash)
                (hash-nested-key-i64-map-key-eq? (& slot-key) (& key))
                false)
                (return (HashNestedKeyI64MapProbeFound cursor))
                (let
                  [next : i64 (+ cursor 1)]
                  (begin
                    (set!
                      cursor
                      (if (>= next capacity)
                        0
                        next))
                    (set! walked (+ walked 1)))))]))
        (if (>= first 0)
          (HashNestedKeyI64MapProbeAbsent first)
          (HashNestedKeyI64MapProbeFull))))))

(cfg
  test
  (define (hash-nested-key-i64-map-probe
    [slots : (Array HashNestedKeyI64MapSlot)]
    [capacity : i64]
    [key : (& key HashNestedKey)]
    [hash : i64]) : HashNestedKeyI64MapProbe
    (if (<= capacity 0)
      (HashNestedKeyI64MapProbeFull)
      (hash-nested-key-i64-map-probe-from
        slots
        capacity
        key
        hash
        (hash-nested-key-i64-map-normalized-bucket-index hash capacity)
        0
        -1))))

(cfg
  test
  (defstruct HashNestedKeyI64Map
    (slots (Array HashNestedKeyI64MapSlot))
    (len i64)
    (deleted i64)))

(cfg
  test
  (defenum HashNestedKeyI64MapLookup
    (HashNestedKeyI64MapMissing)
    (HashNestedKeyI64MapFound i64)))

(cfg
  test
  (defenum HashNestedKeyI64MapBorrowedValueLookup
    (:lifetimes map)
    (HashNestedKeyI64MapBorrowedValueMissing)
    (HashNestedKeyI64MapBorrowedValueFound (& map i64))))

(cfg
  test
  (defenum HashNestedKeyI64MapInsertResult
    (HashNestedKeyI64MapInsertOk HashNestedKeyI64Map)
    (HashNestedKeyI64MapInsertFull HashNestedKeyI64Map)))

(cfg
  test
  (defenum HashNestedKeyI64MapRemoveResult
    (HashNestedKeyI64MapRemoveOk HashNestedKeyI64Map)
    (HashNestedKeyI64MapRemoveMissing HashNestedKeyI64Map)))

(cfg
  test
  (defenum HashNestedKeyI64MapUpdateResult
    (HashNestedKeyI64MapUpdateOk HashNestedKeyI64Map)
    (HashNestedKeyI64MapUpdateMissing HashNestedKeyI64Map)))

(cfg
  test
  (defenum HashNestedKeyI64MapEntryOrInsertResult
    (HashNestedKeyI64MapEntryOrInsertFound HashNestedKeyI64Map i64)
    (HashNestedKeyI64MapEntryOrInsertInserted HashNestedKeyI64Map i64)))

(cfg
  test
  (defstruct HashNestedKeyI64MapMutEntryInfo
    (index i64)
    (present bool)
    (key HashNestedKey)
    (hash i64)))

(cfg
  test
  (defstruct HashNestedKeyI64MapMutEntry
    (:lifetimes map)
    (slots (Array HashNestedKeyI64MapSlot))
    (borrow (&mut map (Array HashNestedKeyI64MapSlot)))
    (index i64)
    (present bool)
    (key HashNestedKey)
    (hash i64)))

(cfg
  test
  (define (hash-nested-key-i64-map-slots [map : HashNestedKeyI64Map]) : (Array
      HashNestedKeyI64MapSlot)
    (struct-get map slots)))

(cfg
  test
  (define (hash-nested-key-i64-map-len [map : HashNestedKeyI64Map]) : i64
    (struct-get map len)))

(cfg
  test
  (define (hash-nested-key-i64-map-capacity [map : HashNestedKeyI64Map]) : i64
    (array-length (struct-get map slots))))

(cfg
  test
  (define (hash-nested-key-i64-map-deleted [map : HashNestedKeyI64Map]) : i64
    (struct-get map deleted)))

(cfg
  test
  (define (hash-nested-key-i64-map-fill-empty
    [slots : (Array HashNestedKeyI64MapSlot)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! slots index (HashNestedKeyI64MapEmpty))
        (hash-nested-key-i64-map-fill-empty slots (+ index 1) count)))))

(cfg
  test
  (define (hash-nested-key-i64-map-with-capacity [capacity : i64]) : HashNestedKeyI64Map
    (let
      [rounded-capacity : i64 (hash-nested-key-i64-map-round-capacity capacity)]
      [slots : (Array HashNestedKeyI64MapSlot)
        (make-array HashNestedKeyI64MapSlot rounded-capacity)]
      (begin
        (hash-nested-key-i64-map-fill-empty slots 0 rounded-capacity)
        (HashNestedKeyI64Map slots 0 0)))))

(cfg
  test
  (define (hash-nested-key-i64-map-borrowed-value-missing
    [map : (& map HashNestedKeyI64Map)]) : (HashNestedKeyI64MapBorrowedValueLookup
      map)
    (HashNestedKeyI64MapBorrowedValueMissing)))

(cfg
  test
  (define (hash-nested-key-i64-map-borrowed-value-found [value : (& map i64)]) : (HashNestedKeyI64MapBorrowedValueLookup
      map)
    (HashNestedKeyI64MapBorrowedValueFound value)))

(cfg
  test
  (define (hash-nested-key-i64-map-get
    [map : HashNestedKeyI64Map]
    [key : HashNestedKey]) : HashNestedKeyI64MapLookup
    (let
      [slots : (Array HashNestedKeyI64MapSlot)
        (hash-nested-key-i64-map-slots map)]
      (match (hash-nested-key-i64-map-probe
        slots
        (hash-nested-key-i64-map-capacity map)
        (& key)
        (hash-nested-key-i64-map-hash-key (& key)))
        [(HashNestedKeyI64MapProbeFound index)
          (match (array-ref slots index)
            [(HashNestedKeyI64MapOccupied _ value _)
              (HashNestedKeyI64MapFound value)]
            [(HashNestedKeyI64MapEmpty) (HashNestedKeyI64MapMissing)]
            [(HashNestedKeyI64MapTombstone) (HashNestedKeyI64MapMissing)])]
        [(HashNestedKeyI64MapProbeAbsent _) (HashNestedKeyI64MapMissing)]
        [(HashNestedKeyI64MapProbeFull) (HashNestedKeyI64MapMissing)]))))

(cfg
  test
  (define (hash-nested-key-i64-map-get-ref
    [map : (& map HashNestedKeyI64Map)]
    [key : HashNestedKey]) : HashNestedKeyI64MapLookup
    (let
      [capacity : i64 (array-length (struct-get map slots))]
      (if (<= capacity 0)
        (HashNestedKeyI64MapMissing)
        (let
          [hash : i64 (hash-nested-key-i64-map-hash-key (& key))]
          [cursor : i64
            (hash-nested-key-i64-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref (struct-get map slots) cursor)
                [(HashNestedKeyI64MapEmpty)
                  (return (HashNestedKeyI64MapMissing))]
                [(HashNestedKeyI64MapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(HashNestedKeyI64MapOccupied slot-key value slot-hash)
                  (if (if (= slot-hash hash)
                    (hash-nested-key-i64-map-key-eq? (& slot-key) (& key))
                    false)
                    (return (HashNestedKeyI64MapFound value))
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            (HashNestedKeyI64MapMissing)))))))

(cfg
  test
  (define (hash-nested-key-i64-map-get-value-borrowed
    [map : (& map HashNestedKeyI64Map)]
    [key : HashNestedKey]) : (HashNestedKeyI64MapBorrowedValueLookup map)
    (let
      [capacity : i64 (array-length (struct-get map slots))]
      (if (<= capacity 0)
        (hash-nested-key-i64-map-borrowed-value-missing map)
        (let
          [hash : i64 (hash-nested-key-i64-map-hash-key (& key))]
          [cursor : i64
            (hash-nested-key-i64-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref (struct-get map slots) cursor)
                [(HashNestedKeyI64MapEmpty)
                  (return (hash-nested-key-i64-map-borrowed-value-missing map))]
                [(HashNestedKeyI64MapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(HashNestedKeyI64MapOccupied slot-key _ slot-hash)
                  (if (if (= slot-hash hash)
                    (hash-nested-key-i64-map-key-eq? (& slot-key) (& key))
                    false)
                    (match (& (array-ref (struct-get map slots) cursor))
                      [(HashNestedKeyI64MapOccupied _ value _)
                        (return
                          (hash-nested-key-i64-map-borrowed-value-found value))]
                      [(HashNestedKeyI64MapEmpty)
                        (return
                          (hash-nested-key-i64-map-borrowed-value-missing map))]
                      [(HashNestedKeyI64MapTombstone)
                        (return
                          (hash-nested-key-i64-map-borrowed-value-missing map))])
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            (hash-nested-key-i64-map-borrowed-value-missing map)))))))

(cfg
  test
  (define (hash-nested-key-i64-map-contains?
    [map : HashNestedKeyI64Map]
    [key : HashNestedKey]) : bool
    (match (hash-nested-key-i64-map-get map key)
      [(HashNestedKeyI64MapFound _) true]
      [(HashNestedKeyI64MapMissing) false])))

(cfg
  test
  (define (hash-nested-key-i64-map-slot-tombstone?
    [slot : HashNestedKeyI64MapSlot]) : bool
    (match slot
      [(HashNestedKeyI64MapTombstone) true]
      [(HashNestedKeyI64MapEmpty) false]
      [(HashNestedKeyI64MapOccupied _ _ _) false])))

(cfg
  test
  (define (hash-nested-key-i64-map-insert
    [map : HashNestedKeyI64Map]
    [key : HashNestedKey]
    [value : i64]) : HashNestedKeyI64MapInsertResult
    (let
      [slots : (Array HashNestedKeyI64MapSlot)
        (hash-nested-key-i64-map-slots map)]
      [hash : i64 (hash-nested-key-i64-map-hash-key (& key))]
      (match (hash-nested-key-i64-map-probe
        slots
        (hash-nested-key-i64-map-capacity map)
        (& key)
        hash)
        [(HashNestedKeyI64MapProbeFound index)
          (begin
            (array-set!
              slots
              index
              (HashNestedKeyI64MapOccupied key value hash))
            (HashNestedKeyI64MapInsertOk map))]
        [(HashNestedKeyI64MapProbeAbsent index)
          (let
            [reused-tombstone : bool
              (hash-nested-key-i64-map-slot-tombstone? (array-ref slots index))]
            (begin
              (array-set!
                slots
                index
                (HashNestedKeyI64MapOccupied key value hash))
              (set!
                (struct-get map len)
                (+ (hash-nested-key-i64-map-len map) 1))
              (if reused-tombstone
                (set!
                  (struct-get map deleted)
                  (- (hash-nested-key-i64-map-deleted map) 1))
                unit)
              (HashNestedKeyI64MapInsertOk map)))]
        [(HashNestedKeyI64MapProbeFull) (HashNestedKeyI64MapInsertFull map)]))))

(cfg
  test
  (define (hash-nested-key-i64-map-remove
    [map : HashNestedKeyI64Map]
    [key : HashNestedKey]) : HashNestedKeyI64MapRemoveResult
    (let
      [slots : (Array HashNestedKeyI64MapSlot)
        (hash-nested-key-i64-map-slots map)]
      (match (hash-nested-key-i64-map-probe
        slots
        (hash-nested-key-i64-map-capacity map)
        (& key)
        (hash-nested-key-i64-map-hash-key (& key)))
        [(HashNestedKeyI64MapProbeFound index)
          (begin
            (array-set! slots index (HashNestedKeyI64MapTombstone))
            (set! (struct-get map len) (- (hash-nested-key-i64-map-len map) 1))
            (set!
              (struct-get map deleted)
              (+ (hash-nested-key-i64-map-deleted map) 1))
            (HashNestedKeyI64MapRemoveOk map))]
        [(HashNestedKeyI64MapProbeAbsent _)
          (HashNestedKeyI64MapRemoveMissing map)]
        [(HashNestedKeyI64MapProbeFull) (HashNestedKeyI64MapRemoveMissing map)]))))

(cfg
  test
  (define (hash-nested-key-i64-map-update-if-present
    [map : HashNestedKeyI64Map]
    [key : HashNestedKey]
    [value : i64]) : HashNestedKeyI64MapUpdateResult
    (let
      [slots : (Array HashNestedKeyI64MapSlot)
        (hash-nested-key-i64-map-slots map)]
      [hash : i64 (hash-nested-key-i64-map-hash-key (& key))]
      (match (hash-nested-key-i64-map-probe
        slots
        (hash-nested-key-i64-map-capacity map)
        (& key)
        hash)
        [(HashNestedKeyI64MapProbeFound index)
          (match (array-ref slots index)
            [(HashNestedKeyI64MapOccupied slot-key _ slot-hash)
              (begin
                (array-set!
                  slots
                  index
                  (HashNestedKeyI64MapOccupied slot-key value slot-hash))
                (HashNestedKeyI64MapUpdateOk map))]
            [(HashNestedKeyI64MapEmpty) (HashNestedKeyI64MapUpdateMissing map)]
            [(HashNestedKeyI64MapTombstone)
              (HashNestedKeyI64MapUpdateMissing map)])]
        [(HashNestedKeyI64MapProbeAbsent _)
          (HashNestedKeyI64MapUpdateMissing map)]
        [(HashNestedKeyI64MapProbeFull) (HashNestedKeyI64MapUpdateMissing map)]))))

(cfg
  test
  (define (hash-nested-key-i64-map-insert-into-empty
    [slots : (Array HashNestedKeyI64MapSlot)]
    [capacity : i64]
    [key : HashNestedKey]
    [value : i64]
    [hash : i64]) : unit
    (if (<= capacity 0)
      unit
      (let
        [cursor : i64
          (hash-nested-key-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        [done : bool false]
        (begin
          (while (if done
            false
            (< walked capacity))
            (match (array-ref slots cursor)
              [(HashNestedKeyI64MapEmpty)
                (begin
                  (array-set!
                    slots
                    cursor
                    (HashNestedKeyI64MapOccupied key value hash))
                  (set! done true))]
              [_
                (begin
                  (set!
                    cursor
                    (hash-nested-key-i64-map-next-index cursor capacity))
                  (set! walked (+ walked 1)))]))
          unit)))))

(cfg
  test
  (define (hash-nested-key-i64-map-rehash-from
    [src : (Array HashNestedKeyI64MapSlot)]
    [dst : (Array HashNestedKeyI64MapSlot)]
    [dst-capacity : i64]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (match (array-ref src index)
          [(HashNestedKeyI64MapOccupied key value hash)
            (hash-nested-key-i64-map-insert-into-empty
              dst
              dst-capacity
              key
              value
              hash)]
          [(HashNestedKeyI64MapEmpty) unit]
          [(HashNestedKeyI64MapTombstone) unit])
        (hash-nested-key-i64-map-rehash-from
          src
          dst
          dst-capacity
          (+ index 1)
          count)))))

(cfg
  test
  (define (hash-nested-key-i64-map-rehash-from-ref
    [src : (& src (Array HashNestedKeyI64MapSlot))]
    [dst : (Array HashNestedKeyI64MapSlot)]
    [dst-capacity : i64]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (match (array-ref src index)
          [(HashNestedKeyI64MapOccupied key value hash)
            (hash-nested-key-i64-map-insert-into-empty
              dst
              dst-capacity
              (clone key)
              value
              hash)]
          [(HashNestedKeyI64MapEmpty) unit]
          [(HashNestedKeyI64MapTombstone) unit])
        (hash-nested-key-i64-map-rehash-from-ref
          src
          dst
          dst-capacity
          (+ index 1)
          count)))))

(cfg
  test
  (define (hash-nested-key-i64-map-resized
    [map : HashNestedKeyI64Map]
    [new-capacity : i64]) : HashNestedKeyI64Map
    (let
      [src : (Array HashNestedKeyI64MapSlot)
        (hash-nested-key-i64-map-slots map)]
      [old-capacity : i64 (hash-nested-key-i64-map-capacity map)]
      [requested-capacity : i64
        (if (> (hash-nested-key-i64-map-len map) new-capacity)
          (hash-nested-key-i64-map-len map)
          new-capacity)]
      [rounded-capacity : i64
        (hash-nested-key-i64-map-round-capacity requested-capacity)]
      [dst : (Array HashNestedKeyI64MapSlot)
        (make-array HashNestedKeyI64MapSlot rounded-capacity)]
      (begin
        (hash-nested-key-i64-map-fill-empty dst 0 rounded-capacity)
        (hash-nested-key-i64-map-rehash-from
          src
          dst
          rounded-capacity
          0
          old-capacity)
        (set! (struct-get map slots) dst)
        (set! (struct-get map deleted) 0)
        map))))

(cfg
  test
  (define (hash-nested-key-i64-map-grow-capacity [capacity : i64]) : i64
    (if (< capacity 4)
      8
      (* (hash-nested-key-i64-map-round-capacity capacity) 2))))

(cfg
  test
  (define (hash-nested-key-i64-map-grow [map : HashNestedKeyI64Map]) : HashNestedKeyI64Map
    (hash-nested-key-i64-map-resized
      map
      (hash-nested-key-i64-map-grow-capacity
        (hash-nested-key-i64-map-capacity map)))))

(cfg
  test
  (define (hash-nested-key-i64-map-needs-grow? [map : HashNestedKeyI64Map]) : bool
    (let
      [capacity : i64 (hash-nested-key-i64-map-capacity map)]
      [used : i64
        (+
          (hash-nested-key-i64-map-len map)
          (hash-nested-key-i64-map-deleted map))]
      (if (<= capacity 0)
        true
        (>= (* used 4) (* capacity 3))))))

(cfg
  test
  (define (hash-nested-key-i64-map-resized!
    [map : (&mut map HashNestedKeyI64Map)]
    [new-capacity : i64]) : unit
    (let
      [old-capacity : i64 (array-length (struct-get map slots))]
      [requested-capacity : i64
        (if (> (struct-get map len) new-capacity)
          (struct-get map len)
          new-capacity)]
      [rounded-capacity : i64
        (hash-nested-key-i64-map-round-capacity requested-capacity)]
      [dst : (Array HashNestedKeyI64MapSlot)
        (make-array HashNestedKeyI64MapSlot rounded-capacity)]
      (begin
        (hash-nested-key-i64-map-fill-empty dst 0 rounded-capacity)
        (hash-nested-key-i64-map-rehash-from-ref
          (& (struct-get map slots))
          dst
          rounded-capacity
          0
          old-capacity)
        (set! (struct-get map slots) dst)
        (set! (struct-get map deleted) 0)))))

(cfg
  test
  (define (hash-nested-key-i64-map-put!
    [map : (&mut map HashNestedKeyI64Map)]
    [key : HashNestedKey]
    [value : i64]) : unit
    (let
      [capacity-before : i64 (array-length (struct-get map slots))]
      [used-before : i64 (+ (struct-get map len) (struct-get map deleted))]
      (begin
        (if (if (<= capacity-before 0)
          true
          (>= (* used-before 4) (* capacity-before 3)))
          (hash-nested-key-i64-map-resized!
            map
            (hash-nested-key-i64-map-grow-capacity capacity-before))
          unit)
        (let
          [slots : (&mut map (Array HashNestedKeyI64MapSlot))
            (&mut (struct-get map slots))]
          [capacity : i64 (array-length slots)]
          [hash : i64 (hash-nested-key-i64-map-hash-key (& key))]
          (if (<= capacity 0)
            unit
            (let
              [cursor : i64
                (hash-nested-key-i64-map-normalized-bucket-index hash capacity)]
              [walked : i64 0]
              [first : i64 -1]
              (begin
                (while (< walked capacity)
                  (match (array-ref slots cursor)
                    [(HashNestedKeyI64MapEmpty)
                      (let
                        [index : i64
                          (if (>= first 0)
                            first
                            cursor)]
                        [reused-tombstone : bool (>= first 0)]
                        (begin
                          (array-set!
                            slots
                            index
                            (HashNestedKeyI64MapOccupied key value hash))
                          (set! (struct-get map len) (+ (struct-get map len) 1))
                          (if reused-tombstone
                            (set!
                              (struct-get map deleted)
                              (- (struct-get map deleted) 1))
                            unit)
                          (return unit)))]
                    [(HashNestedKeyI64MapTombstone)
                      (let
                        [next : i64 (+ cursor 1)]
                        (begin
                          (if (< first 0)
                            (set! first cursor)
                            unit)
                          (set!
                            cursor
                            (if (>= next capacity)
                              0
                              next))
                          (set! walked (+ walked 1))))]
                    [(HashNestedKeyI64MapOccupied slot-key _ slot-hash)
                      (if (if (= slot-hash hash)
                        (hash-nested-key-i64-map-key-eq? (& slot-key) (& key))
                        false)
                        (begin
                          (array-set!
                            slots
                            cursor
                            (HashNestedKeyI64MapOccupied key value hash))
                          (return unit))
                        (let
                          [next : i64 (+ cursor 1)]
                          (begin
                            (set!
                              cursor
                              (if (>= next capacity)
                                0
                                next))
                            (set! walked (+ walked 1)))))]))
                (if (>= first 0)
                  (begin
                    (array-set!
                      slots
                      first
                      (HashNestedKeyI64MapOccupied key value hash))
                    (set! (struct-get map len) (+ (struct-get map len) 1))
                    (set!
                      (struct-get map deleted)
                      (- (struct-get map deleted) 1)))
                  unit)))))))))

(cfg
  test
  (define (hash-nested-key-i64-map-remove!
    [map : (&mut map HashNestedKeyI64Map)]
    [key : HashNestedKey]) : bool
    (let
      [slots : (&mut map (Array HashNestedKeyI64MapSlot))
        (&mut (struct-get map slots))]
      [capacity : i64 (array-length slots)]
      (if (<= capacity 0)
        false
        (let
          [hash : i64 (hash-nested-key-i64-map-hash-key (& key))]
          [cursor : i64
            (hash-nested-key-i64-map-normalized-bucket-index hash capacity)]
          [walked : i64 0]
          (begin
            (while (< walked capacity)
              (match (array-ref slots cursor)
                [(HashNestedKeyI64MapEmpty) (return false)]
                [(HashNestedKeyI64MapTombstone)
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1))))]
                [(HashNestedKeyI64MapOccupied slot-key _ slot-hash)
                  (if (if (= slot-hash hash)
                    (hash-nested-key-i64-map-key-eq? (& slot-key) (& key))
                    false)
                    (begin
                      (array-set! slots cursor (HashNestedKeyI64MapTombstone))
                      (set! (struct-get map len) (- (struct-get map len) 1))
                      (set!
                        (struct-get map deleted)
                        (+ (struct-get map deleted) 1))
                      (return true))
                    (let
                      [next : i64 (+ cursor 1)]
                      (begin
                        (set!
                          cursor
                          (if (>= next capacity)
                            0
                            next))
                        (set! walked (+ walked 1)))))]))
            false))))))

(cfg
  test
  (define (hash-nested-key-i64-map-put
    [map : HashNestedKeyI64Map]
    [key : HashNestedKey]
    [value : i64]) : HashNestedKeyI64Map
    (let
      [grown : HashNestedKeyI64Map
        (if (hash-nested-key-i64-map-needs-grow? map)
          (hash-nested-key-i64-map-grow map)
          map)]
      (match (hash-nested-key-i64-map-insert grown key value)
        [(HashNestedKeyI64MapInsertOk updated) updated]
        [(HashNestedKeyI64MapInsertFull full)
          (match (hash-nested-key-i64-map-insert
            (hash-nested-key-i64-map-grow full)
            key
            value)
            [(HashNestedKeyI64MapInsertOk u) u]
            [(HashNestedKeyI64MapInsertFull u) u])]))))

(cfg
  test
  (define (hash-nested-key-i64-map-insert-or-update
    [map : HashNestedKeyI64Map]
    [key : HashNestedKey]
    [value : i64]) : HashNestedKeyI64Map
    (hash-nested-key-i64-map-put map key value)))

(cfg
  test
  (define (hash-nested-key-i64-map-entry-or-insert
    [map : HashNestedKeyI64Map]
    [key : HashNestedKey]
    [default-value : i64]) : HashNestedKeyI64MapEntryOrInsertResult
    (let
      [slots : (Array HashNestedKeyI64MapSlot)
        (hash-nested-key-i64-map-slots map)]
      [hash : i64 (hash-nested-key-i64-map-hash-key (& key))]
      (match (hash-nested-key-i64-map-probe
        slots
        (hash-nested-key-i64-map-capacity map)
        (& key)
        hash)
        [(HashNestedKeyI64MapProbeFound index)
          (match (array-ref slots index)
            [(HashNestedKeyI64MapOccupied _ value _)
              (HashNestedKeyI64MapEntryOrInsertFound map value)]
            [(HashNestedKeyI64MapEmpty)
              (let
                [updated : HashNestedKeyI64Map
                  (hash-nested-key-i64-map-put map key default-value)]
                (HashNestedKeyI64MapEntryOrInsertInserted updated default-value))]
            [(HashNestedKeyI64MapTombstone)
              (let
                [updated : HashNestedKeyI64Map
                  (hash-nested-key-i64-map-put map key default-value)]
                (HashNestedKeyI64MapEntryOrInsertInserted updated default-value))])]
        [(HashNestedKeyI64MapProbeAbsent _)
          (let
            [updated : HashNestedKeyI64Map
              (hash-nested-key-i64-map-put map key default-value)]
            (HashNestedKeyI64MapEntryOrInsertInserted updated default-value))]
        [(HashNestedKeyI64MapProbeFull)
          (let
            [updated : HashNestedKeyI64Map
              (hash-nested-key-i64-map-put map key default-value)]
            (HashNestedKeyI64MapEntryOrInsertInserted updated default-value))]))))

(cfg
  test
  (define (hash-nested-key-i64-map-mut-entry-info
    [slots : (Array HashNestedKeyI64MapSlot)]
    [capacity : i64]
    [key : HashNestedKey]) : HashNestedKeyI64MapMutEntryInfo
    (if (<= capacity 0)
      (HashNestedKeyI64MapMutEntryInfo -1 false (init : HashNestedKey) 0)
      (let
        [hash : i64 (hash-nested-key-i64-map-hash-key (& key))]
        [cursor : i64 (hash-nested-key-i64-map-bucket-index hash capacity)]
        [walked : i64 0]
        [found : i64 -1]
        [present : bool false]
        [entry-key : HashNestedKey (init : HashNestedKey)]
        [entry-hash : i64 0]
        [done : bool false]
        (begin
          (while (if (< walked capacity)
            (not done)
            false)
            (match (array-ref slots cursor)
              [(HashNestedKeyI64MapOccupied slot-key _ slot-hash)
                (if (if (= slot-hash hash)
                  (hash-nested-key-i64-map-key-eq? (& slot-key) (& key))
                  false)
                  (begin
                    (set! found cursor)
                    (set! present true)
                    (set! entry-key slot-key)
                    (set! entry-hash slot-hash)
                    (set! done true))
                  (begin
                    (set!
                      cursor
                      (hash-nested-key-i64-map-next-index cursor capacity))
                    (set! walked (+ walked 1))))]
              [(HashNestedKeyI64MapEmpty) (set! done true)]
              [(HashNestedKeyI64MapTombstone)
                (begin
                  (set!
                    cursor
                    (hash-nested-key-i64-map-next-index cursor capacity))
                  (set! walked (+ walked 1)))]))
          (HashNestedKeyI64MapMutEntryInfo found present entry-key entry-hash))))))

(cfg
  test
  (define (hash-nested-key-i64-map-mut-entry-from-info
    [info : HashNestedKeyI64MapMutEntryInfo]
    [slots : (Array HashNestedKeyI64MapSlot)]
    [borrow : (&mut map (Array HashNestedKeyI64MapSlot))]) : (HashNestedKeyI64MapMutEntry
      map)
    (HashNestedKeyI64MapMutEntry
      slots
      borrow
      (struct-get info index)
      (struct-get info present)
      (struct-get info key)
      (struct-get info hash))))

(cfg
  test
  (defmacro (hash-nested-key-i64-map-get-mut-entry [map : Expr] [key : Expr]) : Expr
    `(hash-nested-key-i64-map-mut-entry-from-info
      (hash-nested-key-i64-map-mut-entry-info
        (struct-get ,map slots)
        (array-length (struct-get ,map slots))
        ,key)
      (struct-get ,map slots)
      (&mut (struct-get ,map slots)))))

(cfg
  test
  (define (hash-nested-key-i64-map-mut-entry-present?
    [entry : (HashNestedKeyI64MapMutEntry map)]) : bool
    (struct-get entry present)))

(cfg
  test
  (define (hash-nested-key-i64-map-mut-entry-value-or
    [entry : (HashNestedKeyI64MapMutEntry map)]
    [fallback : i64]) : i64
    (if (hash-nested-key-i64-map-mut-entry-present? entry)
      (match (array-ref (struct-get entry slots) (struct-get entry index))
        [(HashNestedKeyI64MapOccupied _ value _) value]
        [(HashNestedKeyI64MapEmpty) fallback]
        [(HashNestedKeyI64MapTombstone) fallback])
      fallback)))

(cfg
  test
  (define (hash-nested-key-i64-map-mut-entry-set!
    [entry : (HashNestedKeyI64MapMutEntry map)]
    [value : i64]) : unit
    (if (hash-nested-key-i64-map-mut-entry-present? entry)
      (array-set!
        (struct-get entry slots)
        (struct-get entry index)
        (HashNestedKeyI64MapOccupied
          (struct-get entry key)
          value
          (struct-get entry hash)))
      unit)))

(cfg
  test
  (defenum HashNestedKeyI64MapEntry
    (HashNestedKeyI64MapEntryNone)
    (HashNestedKeyI64MapEntrySome HashNestedKey i64)))

(cfg
  test
  (define (hash-nested-key-i64-map-next-occupied-from
    [slots : (Array HashNestedKeyI64MapSlot)]
    [index : i64]
    [capacity : i64]) : i64
    (if (>= index capacity)
      capacity
      (match (array-ref slots index)
        [(HashNestedKeyI64MapOccupied _ _ _) index]
        [(HashNestedKeyI64MapEmpty)
          (hash-nested-key-i64-map-next-occupied-from
            slots
            (+ index 1)
            capacity)]
        [(HashNestedKeyI64MapTombstone)
          (hash-nested-key-i64-map-next-occupied-from
            slots
            (+ index 1)
            capacity)]))))

(cfg
  test
  (define (hash-nested-key-i64-map-next-occupied
    [map : HashNestedKeyI64Map]
    [from : i64]) : i64
    (hash-nested-key-i64-map-next-occupied-from
      (hash-nested-key-i64-map-slots map)
      (if (< from 0)
        0
        from)
      (hash-nested-key-i64-map-capacity map))))

(cfg
  test
  (define (hash-nested-key-i64-map-entry-at
    [map : HashNestedKeyI64Map]
    [index : i64]) : HashNestedKeyI64MapEntry
    (if (if (< index 0)
      true
      (>= index (hash-nested-key-i64-map-capacity map)))
      (HashNestedKeyI64MapEntryNone)
      (match (array-ref (hash-nested-key-i64-map-slots map) index)
        [(HashNestedKeyI64MapOccupied key value _)
          (HashNestedKeyI64MapEntrySome key value)]
        [(HashNestedKeyI64MapEmpty) (HashNestedKeyI64MapEntryNone)]
        [(HashNestedKeyI64MapTombstone) (HashNestedKeyI64MapEntryNone)]))))

(cfg
  test
  (define (hash-key-alpha) : HashNestedKey
    (HashNestedKey (HashPoint 1 true "alpha" 'A') (HashTagNumber 7))))

(cfg
  test
  (define (hash-key-alpha-copy) : HashNestedKey
    (HashNestedKey (HashPoint 1 true "alpha" 'A') (HashTagNumber 7))))

(cfg
  test
  (define (hash-key-beta) : HashNestedKey
    (HashNestedKey (HashPoint 1 true "alpha" 'A') (HashTagOtherNumber 7))))

(cfg
  test
  (define (hash-key-gamma) : HashNestedKey
    (HashNestedKey
      (HashPoint 3 false "gamma" 'G')
      (HashTagText true "payload" 'P'))))

(cfg
  test
  (define (hash-key-delta) : HashNestedKey
    (HashNestedKey (HashPoint 4 true "delta" 'D') (HashTagNone))))

(cfg
  test
  (define (hash-key-missing) : HashNestedKey
    (HashNestedKey (HashPoint 99 false "missing" 'M') (HashTagNumber 7))))

;; Predicate/extractor helpers return concrete bool/i64 (no panic in a match
;; arm) so the module typechecks on every stage0, independent of never-type.
(cfg
  test
  (define (probe-found? [p : StringI64MapProbe]) : bool
    (match p
      [(StringI64MapProbeFound _) true]
      [(StringI64MapProbeAbsent _) false]
      [(StringI64MapProbeFull) false])))

(cfg
  test
  (define (probe-absent? [p : StringI64MapProbe]) : bool
    (match p
      [(StringI64MapProbeAbsent _) true]
      [(StringI64MapProbeFound _) false]
      [(StringI64MapProbeFull) false])))

(cfg
  test
  (define (probe-full? [p : StringI64MapProbe]) : bool
    (match p
      [(StringI64MapProbeFull) true]
      [(StringI64MapProbeFound _) false]
      [(StringI64MapProbeAbsent _) false])))

;; Slot index carried by Found/Absent; `fallback` for Full.
(cfg
  test
  (define (probe-index-or [p : StringI64MapProbe] [fallback : i64]) : i64
    (match p
      [(StringI64MapProbeFound i) i]
      [(StringI64MapProbeAbsent i) i]
      [(StringI64MapProbeFull) fallback])))

;; Fill every slot of an `n`-length array with `StringI64MapEmpty`.
(cfg
  test
  (define (fill-empty [slots : (Array StringI64MapSlot)] [n : i64]) : (Array
      StringI64MapSlot)
    (let
      [i : i64 0]
      (begin
        (while (< i n)
          (begin
            (array.array-set! slots i (StringI64MapEmpty))
            (set! i (+ i 1))))
        slots))))

(cfg
  test
  (define (new-slots [n : i64]) : (Array StringI64MapSlot)
    (stdlib.hashmap.fill-empty (array.make-array StringI64MapSlot n) n)))

;; Lookup/insert-result extractors (concrete returns, no panic in a match arm).
(cfg
  test
  (define (lookup-value-or [l : StringI64MapLookup] [fallback : i64]) : i64
    (match l
      [(StringI64MapFound v) v]
      [(StringI64MapMissing) fallback])))

(cfg
  test
  (define (string-i64-borrowed-value-found?
    [l : (StringI64MapBorrowedValueLookup map)]) : bool
    (match l
      [(StringI64MapBorrowedValueFound _) true]
      [(StringI64MapBorrowedValueMissing) false])))

(cfg
  test
  (define (insert-ok? [r : StringI64MapInsertResult]) : bool
    (match r
      [(StringI64MapInsertOk _) true]
      [(StringI64MapInsertFull _) false])))

(cfg
  test
  (define (insert-result-map [r : StringI64MapInsertResult]) : StringI64Map
    (match r
      [(StringI64MapInsertOk m) m]
      [(StringI64MapInsertFull m) m])))

(cfg
  test
  (define (remove-ok? [r : StringI64MapRemoveResult]) : bool
    (match r
      [(StringI64MapRemoveOk _) true]
      [(StringI64MapRemoveMissing _) false])))

(cfg
  test
  (define (remove-result-map [r : StringI64MapRemoveResult]) : StringI64Map
    (match r
      [(StringI64MapRemoveOk m) m]
      [(StringI64MapRemoveMissing m) m])))

(cfg
  test
  (define (update-ok? [r : StringI64MapUpdateResult]) : bool
    (match r
      [(StringI64MapUpdateOk _) true]
      [(StringI64MapUpdateMissing _) false])))

(cfg
  test
  (define (update-result-map [r : StringI64MapUpdateResult]) : StringI64Map
    (match r
      [(StringI64MapUpdateOk m) m]
      [(StringI64MapUpdateMissing m) m])))

(cfg
  test
  (define (entry-or-insert-inserted? [r : StringI64MapEntryOrInsertResult]) : bool
    (match r
      [(StringI64MapEntryOrInsertInserted _ _) true]
      [(StringI64MapEntryOrInsertFound _ _) false])))

(cfg
  test
  (define (entry-or-insert-result-map [r : StringI64MapEntryOrInsertResult]) : StringI64Map
    (match r
      [(StringI64MapEntryOrInsertFound m _) m]
      [(StringI64MapEntryOrInsertInserted m _) m])))

(cfg
  test
  (define (entry-or-insert-value-or
    [r : StringI64MapEntryOrInsertResult]
    [fallback : i64]) : i64
    (match r
      [(StringI64MapEntryOrInsertFound _ v) v]
      [(StringI64MapEntryOrInsertInserted _ v) v])))

;; Iteration entry extractors (concrete returns, no panic in a match arm).
(cfg
  test
  (define (entry-none? [e : StringI64MapEntry]) : bool
    (match e
      [(StringI64MapEntryNone) true]
      [(StringI64MapEntrySome _ _) false])))

(cfg
  test
  (define (entry-value-or [e : StringI64MapEntry] [fallback : i64]) : i64
    (match e
      [(StringI64MapEntrySome _ v) v]
      [(StringI64MapEntryNone) fallback])))

;; Generated `String -> String` map helpers.
(cfg
  test
  (define (string-string-lookup-value-or
    [l : StringStringMapLookup]
    [fallback : String]) : String
    (match l
      [(StringStringMapFound v) v]
      [(StringStringMapMissing) fallback])))

(cfg
  test
  (define (string-string-borrowed-value-length-or
    [l : (StringStringMapBorrowedValueLookup map)]
    [fallback : i64]) : i64
    (match l
      [(StringStringMapBorrowedValueFound v) (string-length v)]
      [(StringStringMapBorrowedValueMissing) fallback])))

(cfg
  test
  (define (string-string-insert-result-map [r : StringStringMapInsertResult]) : StringStringMap
    (match r
      [(StringStringMapInsertOk m) m]
      [(StringStringMapInsertFull m) m])))

(cfg
  test
  (define (string-string-remove-ok? [r : StringStringMapRemoveResult]) : bool
    (match r
      [(StringStringMapRemoveOk _) true]
      [(StringStringMapRemoveMissing _) false])))

(cfg
  test
  (define (string-string-remove-result-map [r : StringStringMapRemoveResult]) : StringStringMap
    (match r
      [(StringStringMapRemoveOk m) m]
      [(StringStringMapRemoveMissing m) m])))

(cfg
  test
  (define (string-string-update-ok? [r : StringStringMapUpdateResult]) : bool
    (match r
      [(StringStringMapUpdateOk _) true]
      [(StringStringMapUpdateMissing _) false])))

(cfg
  test
  (define (string-string-update-result-map [r : StringStringMapUpdateResult]) : StringStringMap
    (match r
      [(StringStringMapUpdateOk m) m]
      [(StringStringMapUpdateMissing m) m])))

(cfg
  test
  (define (string-string-entry-or-insert-inserted?
    [r : StringStringMapEntryOrInsertResult]) : bool
    (match r
      [(StringStringMapEntryOrInsertInserted _ _) true]
      [(StringStringMapEntryOrInsertFound _ _) false])))

(cfg
  test
  (define (string-string-entry-or-insert-result-map
    [r : StringStringMapEntryOrInsertResult]) : StringStringMap
    (match r
      [(StringStringMapEntryOrInsertFound m _) m]
      [(StringStringMapEntryOrInsertInserted m _) m])))

(cfg
  test
  (define (string-string-entry-or-insert-value-or
    [r : StringStringMapEntryOrInsertResult]
    [fallback : String]) : String
    (match r
      [(StringStringMapEntryOrInsertFound _ v) v]
      [(StringStringMapEntryOrInsertInserted _ v) v])))

(cfg
  test
  (define (string-string-entry-value-length-or
    [e : StringStringMapEntry]
    [fallback : i64]) : i64
    (match e
      [(StringStringMapEntrySome _ v) (string-length v)]
      [(StringStringMapEntryNone) fallback])))

;; Generated `i64 -> i64` map helpers.
(cfg
  test
  (define (i64-i64-lookup-value-or [l : I64I64MapLookup] [fallback : i64]) : i64
    (match l
      [(I64I64MapFound v) v]
      [(I64I64MapMissing) fallback])))

(cfg
  test
  (define (i64-i64-borrowed-value-found?
    [l : (I64I64MapBorrowedValueLookup map)]) : bool
    (match l
      [(I64I64MapBorrowedValueFound _) true]
      [(I64I64MapBorrowedValueMissing) false])))

(cfg
  test
  (define (i64-string-borrowed-value-length-or
    [l : (I64StringMapBorrowedValueLookup map)]
    [fallback : i64]) : i64
    (match l
      [(I64StringMapBorrowedValueFound v) (string-length v)]
      [(I64StringMapBorrowedValueMissing) fallback])))

(cfg
  test
  (define (i64-i64-insert-result-map [r : I64I64MapInsertResult]) : I64I64Map
    (match r
      [(I64I64MapInsertOk m) m]
      [(I64I64MapInsertFull m) m])))

(cfg
  test
  (define (i64-i64-remove-ok? [r : I64I64MapRemoveResult]) : bool
    (match r
      [(I64I64MapRemoveOk _) true]
      [(I64I64MapRemoveMissing _) false])))

(cfg
  test
  (define (i64-i64-remove-result-map [r : I64I64MapRemoveResult]) : I64I64Map
    (match r
      [(I64I64MapRemoveOk m) m]
      [(I64I64MapRemoveMissing m) m])))

(cfg
  test
  (define (i64-i64-update-ok? [r : I64I64MapUpdateResult]) : bool
    (match r
      [(I64I64MapUpdateOk _) true]
      [(I64I64MapUpdateMissing _) false])))

(cfg
  test
  (define (i64-i64-update-result-map [r : I64I64MapUpdateResult]) : I64I64Map
    (match r
      [(I64I64MapUpdateOk m) m]
      [(I64I64MapUpdateMissing m) m])))

(cfg
  test
  (define (i64-i64-entry-or-insert-inserted? [r : I64I64MapEntryOrInsertResult]) : bool
    (match r
      [(I64I64MapEntryOrInsertInserted _ _) true]
      [(I64I64MapEntryOrInsertFound _ _) false])))

(cfg
  test
  (define (i64-i64-entry-or-insert-result-map
    [r : I64I64MapEntryOrInsertResult]) : I64I64Map
    (match r
      [(I64I64MapEntryOrInsertFound m _) m]
      [(I64I64MapEntryOrInsertInserted m _) m])))

(cfg
  test
  (define (i64-i64-entry-or-insert-value-or
    [r : I64I64MapEntryOrInsertResult]
    [fallback : i64]) : i64
    (match r
      [(I64I64MapEntryOrInsertFound _ v) v]
      [(I64I64MapEntryOrInsertInserted _ v) v])))

(cfg
  test
  (define (i64-i64-entry-value-or [e : I64I64MapEntry] [fallback : i64]) : i64
    (match e
      [(I64I64MapEntrySome _ v) v]
      [(I64I64MapEntryNone) fallback])))

;; Generated aggregate-key `HashNestedKey -> i64` map helpers.
(cfg
  test
  (define (hash-nested-key-i64-lookup-value-or
    [l : HashNestedKeyI64MapLookup]
    [fallback : i64]) : i64
    (match l
      [(HashNestedKeyI64MapFound v) v]
      [(HashNestedKeyI64MapMissing) fallback])))

(cfg
  test
  (define (hash-nested-key-i64-borrowed-value-found?
    [l : (HashNestedKeyI64MapBorrowedValueLookup map)]) : bool
    (match l
      [(HashNestedKeyI64MapBorrowedValueFound _) true]
      [(HashNestedKeyI64MapBorrowedValueMissing) false])))

(cfg
  test
  (define (hash-nested-key-i64-insert-full?
    [r : HashNestedKeyI64MapInsertResult]) : bool
    (match r
      [(HashNestedKeyI64MapInsertOk _) false]
      [(HashNestedKeyI64MapInsertFull _) true])))

(cfg
  test
  (define (hash-nested-key-i64-remove-ok? [r : HashNestedKeyI64MapRemoveResult]) : bool
    (match r
      [(HashNestedKeyI64MapRemoveOk _) true]
      [(HashNestedKeyI64MapRemoveMissing _) false])))

(cfg
  test
  (define (hash-nested-key-i64-remove-result-map
    [r : HashNestedKeyI64MapRemoveResult]) : HashNestedKeyI64Map
    (match r
      [(HashNestedKeyI64MapRemoveOk m) m]
      [(HashNestedKeyI64MapRemoveMissing m) m])))

(cfg
  test
  (define (hash-nested-key-i64-update-ok? [r : HashNestedKeyI64MapUpdateResult]) : bool
    (match r
      [(HashNestedKeyI64MapUpdateOk _) true]
      [(HashNestedKeyI64MapUpdateMissing _) false])))

(cfg
  test
  (define (hash-nested-key-i64-update-result-map
    [r : HashNestedKeyI64MapUpdateResult]) : HashNestedKeyI64Map
    (match r
      [(HashNestedKeyI64MapUpdateOk m) m]
      [(HashNestedKeyI64MapUpdateMissing m) m])))

(cfg
  test
  (define (hash-nested-key-i64-entry-or-insert-inserted?
    [r : HashNestedKeyI64MapEntryOrInsertResult]) : bool
    (match r
      [(HashNestedKeyI64MapEntryOrInsertInserted _ _) true]
      [(HashNestedKeyI64MapEntryOrInsertFound _ _) false])))

(cfg
  test
  (define (hash-nested-key-i64-entry-or-insert-result-map
    [r : HashNestedKeyI64MapEntryOrInsertResult]) : HashNestedKeyI64Map
    (match r
      [(HashNestedKeyI64MapEntryOrInsertFound m _) m]
      [(HashNestedKeyI64MapEntryOrInsertInserted m _) m])))

(cfg
  test
  (define (hash-nested-key-i64-entry-or-insert-value-or
    [r : HashNestedKeyI64MapEntryOrInsertResult]
    [fallback : i64]) : i64
    (match r
      [(HashNestedKeyI64MapEntryOrInsertFound _ v) v]
      [(HashNestedKeyI64MapEntryOrInsertInserted _ v) v])))

(cfg
  test
  (define (hash-nested-key-i64-entry-value-or
    [e : HashNestedKeyI64MapEntry]
    [fallback : i64]) : i64
    (match e
      [(HashNestedKeyI64MapEntrySome _ v) v]
      [(HashNestedKeyI64MapEntryNone) fallback])))

;; Generated `String -> HashPayload` aggregate-value map helpers.
(cfg
  test
  (define (hash-payload-score [value : HashPayload]) : i64
    (+ (struct-get value score) (struct-get value weight))))

(cfg
  test
  (define (string-hash-payload-lookup-score-or
    [l : StringHashPayloadMapLookup]
    [fallback : i64]) : i64
    (match l
      [(StringHashPayloadMapFound v) (stdlib.hashmap.hash-payload-score v)]
      [(StringHashPayloadMapMissing) fallback])))

(cfg
  test
  (define (string-hash-payload-borrowed-score-or
    [l : (StringHashPayloadMapBorrowedValueLookup map)]
    [fallback : i64]) : i64
    (match l
      [(StringHashPayloadMapBorrowedValueFound v)
        (+ (struct-get v score) (struct-get v weight))]
      [(StringHashPayloadMapBorrowedValueMissing) fallback])))

(cfg
  test
  (define (string-hash-payload-remove-ok?
    [r : StringHashPayloadMapRemoveResult]) : bool
    (match r
      [(StringHashPayloadMapRemoveOk _) true]
      [(StringHashPayloadMapRemoveMissing _) false])))

(cfg
  test
  (define (string-hash-payload-remove-result-map
    [r : StringHashPayloadMapRemoveResult]) : StringHashPayloadMap
    (match r
      [(StringHashPayloadMapRemoveOk m) m]
      [(StringHashPayloadMapRemoveMissing m) m])))

(cfg
  test
  (define (string-hash-payload-update-ok?
    [r : StringHashPayloadMapUpdateResult]) : bool
    (match r
      [(StringHashPayloadMapUpdateOk _) true]
      [(StringHashPayloadMapUpdateMissing _) false])))

(cfg
  test
  (define (string-hash-payload-update-result-map
    [r : StringHashPayloadMapUpdateResult]) : StringHashPayloadMap
    (match r
      [(StringHashPayloadMapUpdateOk m) m]
      [(StringHashPayloadMapUpdateMissing m) m])))

(cfg
  test
  (define (string-hash-payload-entry-score-or
    [e : StringHashPayloadMapEntry]
    [fallback : i64]) : i64
    (match e
      [(StringHashPayloadMapEntrySome _ v)
        (stdlib.hashmap.hash-payload-score v)]
      [(StringHashPayloadMapEntryNone) fallback])))

;; Generated `i64 -> HashState` aggregate-value map helpers.
(cfg
  test
  (define (hash-state-score [value : HashState]) : i64
    (match value
      [(HashReady n) n]
      [(HashFailed) -100]
      [(HashPaused n) (- 0 n)])))

(cfg
  test
  (define (i64-hash-state-lookup-score-or
    [l : I64HashStateMapLookup]
    [fallback : i64]) : i64
    (match l
      [(I64HashStateMapFound v) (stdlib.hashmap.hash-state-score v)]
      [(I64HashStateMapMissing) fallback])))

(cfg
  test
  (define (i64-hash-state-remove-ok? [r : I64HashStateMapRemoveResult]) : bool
    (match r
      [(I64HashStateMapRemoveOk _) true]
      [(I64HashStateMapRemoveMissing _) false])))

(cfg
  test
  (define (i64-hash-state-remove-result-map [r : I64HashStateMapRemoveResult]) : I64HashStateMap
    (match r
      [(I64HashStateMapRemoveOk m) m]
      [(I64HashStateMapRemoveMissing m) m])))

(cfg
  test
  (define (i64-hash-state-update-ok? [r : I64HashStateMapUpdateResult]) : bool
    (match r
      [(I64HashStateMapUpdateOk _) true]
      [(I64HashStateMapUpdateMissing _) false])))

(cfg
  test
  (define (i64-hash-state-update-result-map [r : I64HashStateMapUpdateResult]) : I64HashStateMap
    (match r
      [(I64HashStateMapUpdateOk m) m]
      [(I64HashStateMapUpdateMissing m) m])))

(cfg
  test
  (define (i64-hash-state-entry-or-insert-inserted?
    [r : I64HashStateMapEntryOrInsertResult]) : bool
    (match r
      [(I64HashStateMapEntryOrInsertInserted _ _) true]
      [(I64HashStateMapEntryOrInsertFound _ _) false])))

(cfg
  test
  (define (i64-hash-state-entry-or-insert-result-map
    [r : I64HashStateMapEntryOrInsertResult]) : I64HashStateMap
    (match r
      [(I64HashStateMapEntryOrInsertFound m _) m]
      [(I64HashStateMapEntryOrInsertInserted m _) m])))

(cfg
  test
  (define (i64-hash-state-entry-or-insert-score-or
    [r : I64HashStateMapEntryOrInsertResult]) : i64
    (match r
      [(I64HashStateMapEntryOrInsertFound _ v)
        (stdlib.hashmap.hash-state-score v)]
      [(I64HashStateMapEntryOrInsertInserted _ v)
        (stdlib.hashmap.hash-state-score v)])))

(cfg
  test
  (define (i64-hash-state-entry-score-or
    [e : I64HashStateMapEntry]
    [fallback : i64]) : i64
    (match e
      [(I64HashStateMapEntrySome _ v) (stdlib.hashmap.hash-state-score v)]
      [(I64HashStateMapEntryNone) fallback])))

;; Iteration walkers (deterministic bucket order, #829). No first-class
;; functions yet, so each walk is its own tail-recursive helper started at
;; `(stdlib.hashmap.string-i64-map-next-occupied m 0)` and advanced with the cursor.
;; Number of live entries the cursor visits (should equal the map's len).
(cfg
  test
  (define (iter-count [m : StringI64Map] [i : i64] [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.string-i64-map-capacity m))
      acc
      (stdlib.hashmap.iter-count
        m
        (stdlib.hashmap.string-i64-map-next-occupied m (+ i 1))
        (+ acc 1)))))

;; Sum of every live value, visiting entries once in bucket order.
(cfg
  test
  (define (iter-sum-values [m : StringI64Map] [i : i64] [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.string-i64-map-capacity m))
      acc
      (stdlib.hashmap.iter-sum-values
        m
        (stdlib.hashmap.string-i64-map-next-occupied m (+ i 1))
        (match (stdlib.hashmap.string-i64-map-entry-at m i)
          [(StringI64MapEntrySome _ v) (+ acc v)]
          [(StringI64MapEntryNone) acc])))))

;; True when the cursor visits strictly increasing indices: bucket order is
;; deterministic and monotonic, so each next index exceeds the current one.
(cfg
  test
  (define (iter-monotonic? [m : StringI64Map] [i : i64]) : bool
    (if (>= i (stdlib.hashmap.string-i64-map-capacity m))
      true
      (let
        [nxt : i64 (stdlib.hashmap.string-i64-map-next-occupied m (+ i 1))]
        (if (> nxt i)
          (stdlib.hashmap.iter-monotonic? m nxt)
          false)))))

(cfg
  test
  (define (string-string-iter-count [m : StringStringMap] [i : i64] [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.string-string-map-capacity m))
      acc
      (stdlib.hashmap.string-string-iter-count
        m
        (stdlib.hashmap.string-string-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (string-string-iter-value-length-sum
    [m : StringStringMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.string-string-map-capacity m))
      acc
      (stdlib.hashmap.string-string-iter-value-length-sum
        m
        (stdlib.hashmap.string-string-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.string-string-entry-value-length-or
            (stdlib.hashmap.string-string-map-entry-at m i)
            0))))))

(cfg
  test
  (define (i64-i64-iter-count [m : I64I64Map] [i : i64] [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.i64-i64-map-capacity m))
      acc
      (stdlib.hashmap.i64-i64-iter-count
        m
        (stdlib.hashmap.i64-i64-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (i64-i64-iter-value-sum [m : I64I64Map] [i : i64] [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.i64-i64-map-capacity m))
      acc
      (stdlib.hashmap.i64-i64-iter-value-sum
        m
        (stdlib.hashmap.i64-i64-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.i64-i64-entry-value-or
            (stdlib.hashmap.i64-i64-map-entry-at m i)
            0))))))

(cfg
  test
  (define (hash-nested-key-i64-iter-count
    [m : HashNestedKeyI64Map]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.hash-nested-key-i64-map-capacity m))
      acc
      (stdlib.hashmap.hash-nested-key-i64-iter-count
        m
        (stdlib.hashmap.hash-nested-key-i64-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (hash-nested-key-i64-iter-value-sum
    [m : HashNestedKeyI64Map]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.hash-nested-key-i64-map-capacity m))
      acc
      (stdlib.hashmap.hash-nested-key-i64-iter-value-sum
        m
        (stdlib.hashmap.hash-nested-key-i64-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.hash-nested-key-i64-entry-value-or
            (stdlib.hashmap.hash-nested-key-i64-map-entry-at m i)
            0))))))

(cfg
  test
  (define (hash-nested-key-i64-iter-monotonic?
    [m : HashNestedKeyI64Map]
    [i : i64]) : bool
    (if (>= i (stdlib.hashmap.hash-nested-key-i64-map-capacity m))
      true
      (let
        [nxt : i64
          (stdlib.hashmap.hash-nested-key-i64-map-next-occupied m (+ i 1))]
        (if (> nxt i)
          (stdlib.hashmap.hash-nested-key-i64-iter-monotonic? m nxt)
          false)))))

(cfg
  test
  (define (string-hash-payload-iter-count
    [m : StringHashPayloadMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.string-hash-payload-map-capacity m))
      acc
      (stdlib.hashmap.string-hash-payload-iter-count
        m
        (stdlib.hashmap.string-hash-payload-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (string-hash-payload-iter-score-sum
    [m : StringHashPayloadMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.string-hash-payload-map-capacity m))
      acc
      (stdlib.hashmap.string-hash-payload-iter-score-sum
        m
        (stdlib.hashmap.string-hash-payload-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.string-hash-payload-entry-score-or
            (stdlib.hashmap.string-hash-payload-map-entry-at m i)
            0))))))

(cfg
  test
  (define (i64-hash-state-iter-count
    [m : I64HashStateMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.i64-hash-state-map-capacity m))
      acc
      (stdlib.hashmap.i64-hash-state-iter-count
        m
        (stdlib.hashmap.i64-hash-state-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (i64-hash-state-iter-score-sum
    [m : I64HashStateMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (stdlib.hashmap.i64-hash-state-map-capacity m))
      acc
      (stdlib.hashmap.i64-hash-state-iter-score-sum
        m
        (stdlib.hashmap.i64-hash-state-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.i64-hash-state-entry-score-or
            (stdlib.hashmap.i64-hash-state-map-entry-at m i)
            0))))))

(cfg
  test
  (test
    hashmap-descriptor-contract
    (begin
      ;; --- hashmap key descriptor contract (#2056) ---
      (stdlib.hashmap.hashmap-test-assert-owned-string-eq
        (hashmap-string-key-descriptor-key)
        "stdlib/hashmap/string-key-v1"
        "String key descriptor identity")
      (stdlib.hashmap.hashmap-test-assert-owned-string-eq
        (hashmap-i64-key-descriptor-key)
        "stdlib/hashmap/i64-key-v1"
        "i64 key descriptor identity")
      (stdlib.hashmap.hashmap-test-assert-owned-string-eq
        (hashmap-aggregate-key-descriptor-key)
        "stdlib/hashmap/aggregate-key-v1"
        "aggregate key descriptor identity")
      unit)))

(cfg
  test
  (test
    hashmap-aggregate-key-fixtures
    (begin
      ;; --- hashmap aggregate key fixtures (#2729) ---
      (let
        [c0 : HashNestedKeyI64Map
          (stdlib.hashmap.hash-nested-key-i64-map-with-capacity 1)]
        [c1r : HashNestedKeyI64MapInsertResult
          (stdlib.hashmap.hash-nested-key-i64-map-insert
            c0
            (stdlib.hashmap.hash-key-alpha)
            1)]
        [c1 : HashNestedKeyI64Map
          (match c1r
            [(HashNestedKeyI64MapInsertOk m) m]
            [(HashNestedKeyI64MapInsertFull m) m])]
        [c2r : HashNestedKeyI64MapInsertResult
          (stdlib.hashmap.hash-nested-key-i64-map-insert
            c1
            (stdlib.hashmap.hash-key-beta)
            2)]
        (begin
          (test.assert-true
            (stdlib.hashmap.hash-nested-key-i64-insert-full? c2r)
            "aggregate key fixed-capacity insert reports full collision")))
      (let
        [ak0 : HashNestedKeyI64Map
          (stdlib.hashmap.hash-nested-key-i64-map-with-capacity 2)]
        [ak1 : HashNestedKeyI64Map
          (stdlib.hashmap.hash-nested-key-i64-map-put
            ak0
            (stdlib.hashmap.hash-key-alpha)
            10)]
        [ak2 : HashNestedKeyI64Map
          (stdlib.hashmap.hash-nested-key-i64-map-put
            ak1
            (stdlib.hashmap.hash-key-beta)
            20)]
        [ak3 : HashNestedKeyI64Map
          (stdlib.hashmap.hash-nested-key-i64-map-put
            ak2
            (stdlib.hashmap.hash-key-gamma)
            30)]
        [ak4 : HashNestedKeyI64Map
          (stdlib.hashmap.hash-nested-key-i64-map-put
            ak3
            (stdlib.hashmap.hash-key-alpha-copy)
            15)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.hash-nested-key-i64-map-len ak4)
            3
            "aggregate key equal copy updates existing entry")
          (test.assert-true
            (> (stdlib.hashmap.hash-nested-key-i64-map-capacity ak4) 2)
            "aggregate key map grows and rehashes")
          (test.assert-i64-eq
            (stdlib.hashmap.hash-nested-key-i64-lookup-value-or
              (stdlib.hashmap.hash-nested-key-i64-map-get
                ak4
                (stdlib.hashmap.hash-key-alpha))
              -1)
            15
            "aggregate key get finds updated struct key")
          (test.assert-i64-eq
            (stdlib.hashmap.hash-nested-key-i64-lookup-value-or
              (stdlib.hashmap.hash-nested-key-i64-map-get
                ak4
                (stdlib.hashmap.hash-key-beta))
              -1)
            20
            "aggregate key enum tag participates in equality")
          (test.assert-i64-eq
            (stdlib.hashmap.hash-nested-key-i64-lookup-value-or
              (stdlib.hashmap.hash-nested-key-i64-map-get
                ak4
                (stdlib.hashmap.hash-key-missing))
              -1)
            -1
            "aggregate key missing lookup")
          (test.assert-true
            (stdlib.hashmap.hash-nested-key-i64-map-contains?
              ak4
              (stdlib.hashmap.hash-key-gamma))
            "aggregate key contains nested enum payload")
          (test.assert-false
            (stdlib.hashmap.hash-nested-key-i64-map-contains?
              ak4
              (stdlib.hashmap.hash-key-missing))
            "aggregate key contains rejects missing")
          (test.assert-true
            (stdlib.hashmap.hash-nested-key-i64-borrowed-value-found?
              (stdlib.hashmap.hash-nested-key-i64-map-get-value-borrowed
                (& ak4)
                (stdlib.hashmap.hash-key-beta)))
            "aggregate key borrowed value lookup finds beta")
          (let
            [removed : HashNestedKeyI64MapRemoveResult
              (stdlib.hashmap.hash-nested-key-i64-map-remove
                ak4
                (stdlib.hashmap.hash-key-beta))]
            (begin
              (test.assert-true
                (stdlib.hashmap.hash-nested-key-i64-remove-ok? removed)
                "aggregate key remove finds beta")
              (let
                [ak5 : HashNestedKeyI64Map
                  (stdlib.hashmap.hash-nested-key-i64-remove-result-map removed)]
                [ak5-len : i64 (stdlib.hashmap.hash-nested-key-i64-map-len ak5)]
                [ak5-deleted : i64
                  (stdlib.hashmap.hash-nested-key-i64-map-deleted ak5)]
                [ak6 : HashNestedKeyI64Map
                  (stdlib.hashmap.hash-nested-key-i64-map-put
                    ak5
                    (stdlib.hashmap.hash-key-delta)
                    40)]
                [ak6-delta-value : i64
                  (stdlib.hashmap.hash-nested-key-i64-lookup-value-or
                    (stdlib.hashmap.hash-nested-key-i64-map-get
                      ak6
                      (stdlib.hashmap.hash-key-delta))
                    -1)]
                [hit : HashNestedKeyI64MapUpdateResult
                  (stdlib.hashmap.hash-nested-key-i64-map-update-if-present
                    ak6
                    (stdlib.hashmap.hash-key-gamma)
                    31)]
                [ak7 : HashNestedKeyI64Map
                  (stdlib.hashmap.hash-nested-key-i64-update-result-map hit)]
                [miss : HashNestedKeyI64MapUpdateResult
                  (stdlib.hashmap.hash-nested-key-i64-map-update-if-present
                    ak7
                    (stdlib.hashmap.hash-key-missing)
                    99)]
                [ak8 : HashNestedKeyI64Map
                  (stdlib.hashmap.hash-nested-key-i64-update-result-map miss)]
                [removed-delta : HashNestedKeyI64MapRemoveResult
                  (stdlib.hashmap.hash-nested-key-i64-map-remove
                    ak8
                    (stdlib.hashmap.hash-key-delta))]
                [ak9 : HashNestedKeyI64Map
                  (stdlib.hashmap.hash-nested-key-i64-remove-result-map
                    removed-delta)]
                [inserted : HashNestedKeyI64MapEntryOrInsertResult
                  (stdlib.hashmap.hash-nested-key-i64-map-entry-or-insert
                    ak9
                    (stdlib.hashmap.hash-key-delta)
                    44)]
                [ak10 : HashNestedKeyI64Map
                  (stdlib.hashmap.hash-nested-key-i64-entry-or-insert-result-map
                    inserted)]
                [found : HashNestedKeyI64MapEntryOrInsertResult
                  (stdlib.hashmap.hash-nested-key-i64-map-entry-or-insert
                    ak10
                    (stdlib.hashmap.hash-key-alpha)
                    99)]
                [ak11 : HashNestedKeyI64Map
                  (stdlib.hashmap.hash-nested-key-i64-entry-or-insert-result-map
                    found)]
                (begin
                  (test.assert-i64-eq
                    ak5-len
                    2
                    "aggregate key len after remove")
                  (test.assert-i64-eq
                    ak5-deleted
                    1
                    "aggregate key tombstone after remove")
                  (test.assert-i64-eq
                    ak6-delta-value
                    40
                    "aggregate key put reuses or clears tombstone")
                  (test.assert-true
                    (stdlib.hashmap.hash-nested-key-i64-update-ok? hit)
                    "aggregate key update hit")
                  (test.assert-false
                    (stdlib.hashmap.hash-nested-key-i64-update-ok? miss)
                    "aggregate key update miss")
                  (test.assert-i64-eq
                    (stdlib.hashmap.hash-nested-key-i64-lookup-value-or
                      (stdlib.hashmap.hash-nested-key-i64-map-get
                        ak8
                        (stdlib.hashmap.hash-key-gamma))
                      -1)
                    31
                    "aggregate key update writes value")
                  (test.assert-true
                    (stdlib.hashmap.hash-nested-key-i64-entry-or-insert-inserted?
                      inserted)
                    "aggregate key entry-or-insert inserts removed key")
                  (test.assert-i64-eq
                    (stdlib.hashmap.hash-nested-key-i64-entry-or-insert-value-or
                      inserted
                      -1)
                    44
                    "aggregate key entry-or-insert returns inserted value")
                  (test.assert-false
                    (stdlib.hashmap.hash-nested-key-i64-entry-or-insert-inserted?
                      found)
                    "aggregate key entry-or-insert finds existing key")
                  (test.assert-i64-eq
                    (stdlib.hashmap.hash-nested-key-i64-entry-or-insert-value-or
                      found
                      -1)
                    15
                    "aggregate key entry-or-insert returns existing value")
                  (test.assert-i64-eq
                    (stdlib.hashmap.hash-nested-key-i64-iter-count
                      ak11
                      (stdlib.hashmap.hash-nested-key-i64-map-next-occupied
                        ak11
                        0)
                      0)
                    (stdlib.hashmap.hash-nested-key-i64-map-len ak11)
                    "aggregate key iteration count matches len")
                  (test.assert-i64-eq
                    (stdlib.hashmap.hash-nested-key-i64-iter-value-sum
                      ak11
                      (stdlib.hashmap.hash-nested-key-i64-map-next-occupied
                        ak11
                        0)
                      0)
                    90
                    "aggregate key iteration sums live values")
                  (test.assert-true
                    (stdlib.hashmap.hash-nested-key-i64-iter-monotonic?
                      ak11
                      (stdlib.hashmap.hash-nested-key-i64-map-next-occupied
                        ak11
                        0))
                    "aggregate key iteration order is deterministic")))))))
      unit)))

(cfg
  test
  (test
    hashmap-i64-string-family
    (begin
      ;; --- i64-to-String checked-in family fixture ---
      (let
        [fixture0 : I64StringMap (i64-string-map-with-capacity 2)]
        [fixture1 : I64StringMap (i64-string-map-put fixture0 7 "seven")]
        (begin
          (test.assert-i64-eq
            (i64-string-map-len fixture1)
            1
            "i64->String fixture len helper")
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (match (i64-string-map-get fixture1 7)
              [(I64StringMapFound value) value]
              [(I64StringMapMissing) "missing"])
            "seven"
            "i64->String fixture get helper")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-string-borrowed-value-length-or
              (i64-string-map-get-value-borrowed (& fixture1) 7)
              -1)
            5
            "i64->String fixture borrowed value helper")
          (test.assert-false
            (i64-string-map-contains? fixture1 9)
            "i64->String fixture contains helper")))
      unit)))

(cfg
  test
  (test
    hashmap-aggregate-value-fixtures
    (begin
      ;; --- hashmap aggregate value fixtures (#2728) ---
      (let
        [alpha : String "alpha"]
        [payload0 : StringHashPayloadMap
          (stdlib.hashmap.string-hash-payload-map-with-capacity 2)]
        [payload1 : StringHashPayloadMap
          (stdlib.hashmap.string-hash-payload-map-put
            payload0
            "alpha"
            (HashPayload 3 4))]
        [payload2 : StringHashPayloadMap
          (stdlib.hashmap.string-hash-payload-map-put
            payload1
            "beta"
            (HashPayload 5 6))]
        [payload3 : StringHashPayloadMap
          (stdlib.hashmap.string-hash-payload-map-put
            payload2
            "gamma"
            (HashPayload 7 8))]
        [payload-hit : StringHashPayloadMapUpdateResult
          (stdlib.hashmap.string-hash-payload-map-update-borrowed-if-present
            payload3
            (& alpha)
            (HashPayload 20 1))]
        [payload4 : StringHashPayloadMap
          (stdlib.hashmap.string-hash-payload-update-result-map payload-hit)]
        (begin
          (test.assert-true
            (> (stdlib.hashmap.string-hash-payload-map-capacity payload4) 2)
            "StringHashPayload grows aggregate values")
          (test.assert-true
            (stdlib.hashmap.string-hash-payload-update-ok? payload-hit)
            "StringHashPayload borrowed update hit")
          (test.assert-i64-eq
            (stdlib.hashmap.string-hash-payload-lookup-score-or
              (stdlib.hashmap.string-hash-payload-map-get payload4 "alpha")
              -1)
            21
            "StringHashPayload owned get updated aggregate")
          (test.assert-i64-eq
            (stdlib.hashmap.string-hash-payload-borrowed-score-or
              (stdlib.hashmap.string-hash-payload-map-get-value-borrowed
                (& payload4)
                (& alpha))
              -1)
            21
            "StringHashPayload borrowed value exposes fields")
          (let
            [payload-remove : StringHashPayloadMapRemoveResult
              (stdlib.hashmap.string-hash-payload-map-remove payload4 "beta")]
            [payload5 : StringHashPayloadMap
              (stdlib.hashmap.string-hash-payload-remove-result-map
                payload-remove)]
            (begin
              (test.assert-true
                (stdlib.hashmap.string-hash-payload-remove-ok? payload-remove)
                "StringHashPayload remove aggregate")
              (test.assert-false
                (stdlib.hashmap.string-hash-payload-map-contains?
                  payload5
                  "beta")
                "StringHashPayload removed key absent")
              (test.assert-i64-eq
                (stdlib.hashmap.string-hash-payload-iter-count
                  payload5
                  (stdlib.hashmap.string-hash-payload-map-next-occupied
                    payload5
                    0)
                  0)
                2
                "StringHashPayload iteration count")
              (test.assert-i64-eq
                (stdlib.hashmap.string-hash-payload-iter-score-sum
                  payload5
                  (stdlib.hashmap.string-hash-payload-map-next-occupied
                    payload5
                    0)
                  0)
                36
                "StringHashPayload iteration score sum")))))
      (let
        [states0 : I64HashStateMap
          (stdlib.hashmap.i64-hash-state-map-with-capacity 2)]
        [states1 : I64HashStateMap
          (stdlib.hashmap.i64-hash-state-map-put states0 1 (HashReady 10))]
        [states2 : I64HashStateMap
          (stdlib.hashmap.i64-hash-state-map-put states1 2 (HashFailed))]
        [states3 : I64HashStateMap
          (stdlib.hashmap.i64-hash-state-map-put states2 3 (HashPaused 7))]
        [state-hit : I64HashStateMapUpdateResult
          (stdlib.hashmap.i64-hash-state-map-update-if-present
            states3
            2
            (HashReady 22))]
        [states4 : I64HashStateMap
          (stdlib.hashmap.i64-hash-state-update-result-map state-hit)]
        (begin
          (test.assert-true
            (> (stdlib.hashmap.i64-hash-state-map-capacity states4) 2)
            "I64HashState grows enum values")
          (test.assert-true
            (stdlib.hashmap.i64-hash-state-update-ok? state-hit)
            "I64HashState update hit")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-hash-state-lookup-score-or
              (stdlib.hashmap.i64-hash-state-map-get states4 2)
              -1)
            22
            "I64HashState get updated enum")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-hash-state-lookup-score-or
              (stdlib.hashmap.i64-hash-state-map-get states4 99)
              -1)
            -1
            "I64HashState missing enum")
          (let
            [state-remove : I64HashStateMapRemoveResult
              (stdlib.hashmap.i64-hash-state-map-remove states4 1)]
            [states5 : I64HashStateMap
              (stdlib.hashmap.i64-hash-state-remove-result-map state-remove)]
            [state-inserted : I64HashStateMapEntryOrInsertResult
              (stdlib.hashmap.i64-hash-state-map-entry-or-insert
                states5
                4
                (HashReady 40))]
            [states6 : I64HashStateMap
              (stdlib.hashmap.i64-hash-state-entry-or-insert-result-map
                state-inserted)]
            [state-found : I64HashStateMapEntryOrInsertResult
              (stdlib.hashmap.i64-hash-state-map-entry-or-insert
                states6
                2
                (HashFailed))]
            [states7 : I64HashStateMap
              (stdlib.hashmap.i64-hash-state-entry-or-insert-result-map
                state-found)]
            (begin
              (test.assert-true
                (stdlib.hashmap.i64-hash-state-remove-ok? state-remove)
                "I64HashState remove enum")
              (test.assert-true
                (stdlib.hashmap.i64-hash-state-entry-or-insert-inserted?
                  state-inserted)
                "I64HashState entry-or-insert inserted")
              (test.assert-i64-eq
                (stdlib.hashmap.i64-hash-state-entry-or-insert-score-or
                  state-inserted)
                40
                "I64HashState entry-or-insert default enum")
              (test.assert-false
                (stdlib.hashmap.i64-hash-state-entry-or-insert-inserted?
                  state-found)
                "I64HashState entry-or-insert found")
              (test.assert-i64-eq
                (stdlib.hashmap.i64-hash-state-entry-or-insert-score-or
                  state-found)
                22
                "I64HashState entry-or-insert existing enum")
              (test.assert-i64-eq
                (stdlib.hashmap.i64-hash-state-iter-count
                  states7
                  (stdlib.hashmap.i64-hash-state-map-next-occupied states7 0)
                  0)
                3
                "I64HashState iteration count")
              (test.assert-i64-eq
                (stdlib.hashmap.i64-hash-state-iter-score-sum
                  states7
                  (stdlib.hashmap.i64-hash-state-map-next-occupied states7 0)
                  0)
                55
                "I64HashState iteration score sum")))))
      unit)))

(cfg
  test
  (test
    hashmap-bucket-index
    (begin
      ;; --- bucket-index math + wraparound ---
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-bucket-index 5 4)
        1
        "bucket 5 mask 4")
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-bucket-index 8 4)
        0
        "bucket 8 mask 4")
      ;; negative hash is normalized into [0, modulus) first: -1 -> 2147483646,
      ;; and 2147483646 & 3 = 2.
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-bucket-index -1 4)
        2
        "bucket negative")
      (test.assert-true
        (stdlib.hashmap.string-i64-map-power-two-capacity? 8)
        "power-of-two capacity recognized")
      (test.assert-false
        (stdlib.hashmap.string-i64-map-power-two-capacity? 10)
        "non-power-of-two capacity rejected")
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-round-capacity 0)
        1
        "zero requested capacity rounds to one")
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-round-capacity 3)
        4
        "capacity 3 rounds to 4")
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-round-capacity 10)
        16
        "capacity 10 rounds to 16")
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-normalized-bucket-index 13 8)
        5
        "normalized bucket masks capacity")
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-next-index 3 4)
        0
        "next wraps 3 -> 0")
      (test.assert-i64-eq
        (stdlib.hashmap.string-i64-map-next-index 1 4)
        2
        "next 1 -> 2")
      unit)))

(cfg
  test
  (test
    hashmap-probe-zero-one-capacity
    (begin
      ;; --- zero / one capacity ---
      (test.assert-true
        (stdlib.hashmap.probe-full?
          (stdlib.hashmap.string-i64-map-probe
            (stdlib.hashmap.new-slots 1)
            0
            "k"
            5))
        "zero capacity is full")
      (let
        [one : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 1)]
        (begin
          (test.assert-true
            (stdlib.hashmap.probe-absent?
              (stdlib.hashmap.string-i64-map-probe one 1 "k" 5))
            "capacity one empty is absent")
          (test.assert-i64-eq
            (stdlib.hashmap.probe-index-or
              (stdlib.hashmap.string-i64-map-probe one 1 "k" 5)
              -1)
            0
            "capacity one absent slot 0")))
      unit)))

(cfg
  test
  (test
    hashmap-probe-empty-table
    (begin
      ;; --- empty table: absent at the start bucket ---
      (let
        [empty : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 4)]
        (begin
          (test.assert-true
            (stdlib.hashmap.probe-absent?
              (stdlib.hashmap.string-i64-map-probe empty 4 "k" 5))
            "empty table absent")
          (test.assert-i64-eq
            (stdlib.hashmap.probe-index-or
              (stdlib.hashmap.string-i64-map-probe empty 4 "k" 5)
              -1)
            1
            "empty absent at bucket 1")))
      unit)))

(cfg
  test
  (test
    hashmap-probe-found
    (begin
      ;; --- found: occupied slot with matching hash + key ---
      (let
        [found : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 4)]
        (begin
          (array.array-set! found 1 (StringI64MapOccupied "k" 7 5))
          (test.assert-true
            (stdlib.hashmap.probe-found?
              (stdlib.hashmap.string-i64-map-probe found 4 "k" 5))
            "occupied key found")
          (test.assert-i64-eq
            (stdlib.hashmap.probe-index-or
              (stdlib.hashmap.string-i64-map-probe found 4 "k" 5)
              -1)
            1
            "found at slot 1")))
      unit)))

(cfg
  test
  (test
    hashmap-probe-collision-walk
    (begin
      ;; --- collision walk: same hash, different key, walk to next empty ---
      (let
        [collide : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 4)]
        (begin
          (array.array-set! collide 1 (StringI64MapOccupied "other" 9 5))
          (test.assert-true
            (stdlib.hashmap.probe-absent?
              (stdlib.hashmap.string-i64-map-probe collide 4 "k" 5))
            "collision then absent")
          (test.assert-i64-eq
            (stdlib.hashmap.probe-index-or
              (stdlib.hashmap.string-i64-map-probe collide 4 "k" 5)
              -1)
            2
            "collision walks to slot 2")))
      unit)))

(cfg
  test
  (test
    hashmap-probe-wraparound
    (begin
      ;; --- wraparound: bucket 3 occupied, walk wraps to slot 0 ---
      (let
        [wrap : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 4)]
        (begin
          (array.array-set! wrap 3 (StringI64MapOccupied "o" 9 3))
          (test.assert-i64-eq
            (stdlib.hashmap.probe-index-or
              (stdlib.hashmap.string-i64-map-probe wrap 4 "k" 3)
              -1)
            0
            "wraparound walks 3 -> 0")))
      unit)))

(cfg
  test
  (test
    hashmap-probe-tombstone-reuse
    (begin
      ;; --- tombstone reuse: insert position is the tombstone, not the empty ---
      (let
        [tomb : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 4)]
        (begin
          (array.array-set! tomb 1 (StringI64MapTombstone))
          (test.assert-true
            (stdlib.hashmap.probe-absent?
              (stdlib.hashmap.string-i64-map-probe tomb 4 "k" 5))
            "tombstone path absent")
          (test.assert-i64-eq
            (stdlib.hashmap.probe-index-or
              (stdlib.hashmap.string-i64-map-probe tomb 4 "k" 5)
              -1)
            1
            "tombstone reused at slot 1")))
      unit)))

(cfg
  test
  (test
    hashmap-probe-through-tombstone
    (begin
      ;; --- found after a tombstone: probing does not stop at a tombstone ---
      (let
        [tf : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 4)]
        (begin
          (array.array-set! tf 1 (StringI64MapTombstone))
          (array.array-set! tf 2 (StringI64MapOccupied "k" 7 5))
          (test.assert-true
            (stdlib.hashmap.probe-found?
              (stdlib.hashmap.string-i64-map-probe tf 4 "k" 5))
            "found past tombstone")
          (test.assert-i64-eq
            (stdlib.hashmap.probe-index-or
              (stdlib.hashmap.string-i64-map-probe tf 4 "k" 5)
              -1)
            2
            "found at slot 2 past tombstone")))
      unit)))

(cfg
  test
  (test
    hashmap-probe-full-table
    (begin
      ;; --- full table, no tombstone: probe terminates as full ---
      (let
        [full : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 2)]
        (begin
          (array.array-set! full 0 (StringI64MapOccupied "a" 1 10))
          (array.array-set! full 1 (StringI64MapOccupied "b" 2 11))
          (test.assert-true
            (stdlib.hashmap.probe-full?
              (stdlib.hashmap.string-i64-map-probe full 2 "k" 4))
            "full table is full")))
      unit)))

(cfg
  test
  (test
    hashmap-probe-full-table-with-tombstone
    (begin
      ;; --- full table with a tombstone: absent at the tombstone, not full ---
      (let
        [fulltomb : (Array StringI64MapSlot) (stdlib.hashmap.new-slots 2)]
        (begin
          (array.array-set! fulltomb 0 (StringI64MapOccupied "a" 1 10))
          (array.array-set! fulltomb 1 (StringI64MapTombstone))
          (test.assert-true
            (stdlib.hashmap.probe-absent?
              (stdlib.hashmap.string-i64-map-probe fulltomb 2 "k" 4))
            "full-with-tombstone is absent")
          (test.assert-i64-eq
            (stdlib.hashmap.probe-index-or
              (stdlib.hashmap.string-i64-map-probe fulltomb 2 "k" 4)
              -1)
            1
            "absent at the tombstone slot")))
      unit)))

(cfg
  test
  (test
    hashmap-string-i64-api
    (begin
      ;; --- map API (#826): with-capacity / insert / get / contains? / len ---
      (let
        [alpha-key : String "alpha"]
        [missing-key : String "missing"]
        [m0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 8)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-len m0)
            0
            "fresh map len 0")
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-capacity
              (stdlib.hashmap.string-i64-map-with-capacity 10))
            16
            "manual map rounds requested capacity")
          (test.assert-false
            (stdlib.hashmap.string-i64-map-contains? m0 "x")
            "fresh map has no key")
          (let
            [m1 : StringI64Map
              (stdlib.hashmap.insert-result-map
                (stdlib.hashmap.string-i64-map-insert m0 "alpha" 11))]
            [m2 : StringI64Map
              (stdlib.hashmap.insert-result-map
                (stdlib.hashmap.string-i64-map-insert m1 "beta" 22))]
            [m3 : StringI64Map
              (stdlib.hashmap.insert-result-map
                (stdlib.hashmap.string-i64-map-insert m2 "gamma" 33))]
            (begin
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-len m3)
                3
                "len after three inserts")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get m3 "alpha")
                  -1)
                11
                "get alpha")
              (test.assert-true
                (stdlib.hashmap.string-i64-borrowed-value-found?
                  (stdlib.hashmap.string-i64-map-get-value-borrowed
                    (& m3)
                    (& alpha-key)))
                "StringI64 borrowed value get finds alpha")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get m3 "beta")
                  -1)
                22
                "get beta")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get m3 "gamma")
                  -1)
                33
                "get gamma")
              (test.assert-true
                (stdlib.hashmap.string-i64-map-contains? m3 "beta")
                "contains beta")
              (test.assert-false
                (stdlib.hashmap.string-i64-map-contains? m3 "missing")
                "missing key absent")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get m3 "missing")
                  -1)
                -1
                "get missing -> fallback")
              (test.assert-false
                (stdlib.hashmap.string-i64-borrowed-value-found?
                  (stdlib.hashmap.string-i64-map-get-value-borrowed
                    (& m3)
                    (& missing-key)))
                "StringI64 missing borrowed value get")
              ;; updating an existing key keeps len and changes the value
              (let
                [m4 : StringI64Map
                  (stdlib.hashmap.insert-result-map
                    (stdlib.hashmap.string-i64-map-insert m3 "alpha" 99))]
                (begin
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-i64-map-len m4)
                    3
                    "len unchanged on update")
                  (test.assert-i64-eq
                    (stdlib.hashmap.lookup-value-or
                      (stdlib.hashmap.string-i64-map-get m4 "alpha")
                      -1)
                    99
                    "alpha updated to 99")))
              ;; a fixed capacity-1 table is full for a second distinct key
              (let
                [s0 : StringI64Map
                  (stdlib.hashmap.string-i64-map-with-capacity 1)]
                [s1 : StringI64Map
                  (stdlib.hashmap.insert-result-map
                    (stdlib.hashmap.string-i64-map-insert s0 "only" 7))]
                (begin
                  (test.assert-i64-eq
                    (stdlib.hashmap.lookup-value-or
                      (stdlib.hashmap.string-i64-map-get s1 "only")
                      -1)
                    7
                    "capacity-1 get only")
                  (test.assert-false
                    (stdlib.hashmap.insert-ok?
                      (stdlib.hashmap.string-i64-map-insert s1 "second" 8))
                    "capacity-1 second insert is full")))))))
      unit)))

(cfg
  test
  (test
    hashmap-string-i64-removal
    (begin
      ;; --- removal + tombstone accounting (#829) ---
      (let
        [r0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 8)]
        [r1 : StringI64Map
          (stdlib.hashmap.insert-result-map
            (stdlib.hashmap.string-i64-map-insert r0 "k1" 10))]
        [r2 : StringI64Map
          (stdlib.hashmap.insert-result-map
            (stdlib.hashmap.string-i64-map-insert r1 "k2" 20))]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-len r2)
            2
            "removal: two inserts len 2")
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-deleted r2)
            0
            "removal: no tombstones yet")
          ;; remove-miss: absent key leaves the map unchanged and untouched.
          (let
            [miss : StringI64MapRemoveResult
              (stdlib.hashmap.string-i64-map-remove r2 "absent")]
            (begin
              (test.assert-false
                (stdlib.hashmap.remove-ok? miss)
                "remove-miss is not ok")
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-len
                  (stdlib.hashmap.remove-result-map miss))
                2
                "remove-miss keeps len")
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-deleted
                  (stdlib.hashmap.remove-result-map miss))
                0
                "remove-miss adds no tombstone")))
          ;; remove-hit: k1 becomes a tombstone; len-1, deleted+1, k2 survives.
          (let
            [hit : StringI64MapRemoveResult
              (stdlib.hashmap.string-i64-map-remove r2 "k1")]
            (begin
              (test.assert-true
                (stdlib.hashmap.remove-ok? hit)
                "remove-hit is ok")
              (let
                [r3 : StringI64Map (stdlib.hashmap.remove-result-map hit)]
                (begin
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-i64-map-len r3)
                    1
                    "remove-hit len 1")
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-i64-map-deleted r3)
                    1
                    "remove-hit deleted 1")
                  (test.assert-i64-eq
                    (stdlib.hashmap.lookup-value-or
                      (stdlib.hashmap.string-i64-map-get r3 "k1")
                      -1)
                    -1
                    "k1 missing after remove")
                  (test.assert-true
                    (stdlib.hashmap.string-i64-map-contains? r3 "k2")
                    "k2 survives k1 removal")
                  ;; reinsert after delete reuses the tombstone: len back to 2,
                  ;; deleted back to 0, new value visible.
                  (let
                    [r4 : StringI64Map
                      (stdlib.hashmap.insert-result-map
                        (stdlib.hashmap.string-i64-map-insert r3 "k1" 111))]
                    (begin
                      (test.assert-i64-eq
                        (stdlib.hashmap.string-i64-map-len r4)
                        2
                        "reinsert len 2")
                      (test.assert-i64-eq
                        (stdlib.hashmap.string-i64-map-deleted r4)
                        0
                        "reinsert reuses tombstone (deleted 0)")
                      (test.assert-i64-eq
                        (stdlib.hashmap.lookup-value-or
                          (stdlib.hashmap.string-i64-map-get r4 "k1")
                          -1)
                        111
                        "k1 reinserted value")))))))))
      unit)))

(cfg
  test
  (test
    hashmap-string-i64-update-entry
    (begin
      ;; --- update / entry-or-insert API (#888) ---
      (let
        [u0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [u1 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
        [u2 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u1 "beta" 20)]
        [hit : StringI64MapUpdateResult
          (stdlib.hashmap.string-i64-map-update-if-present u2 "alpha" 70)]
        [u3 : StringI64Map (stdlib.hashmap.update-result-map hit)]
        (begin
          (test.assert-true
            (stdlib.hashmap.update-ok? hit)
            "update-if-present hit is ok")
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-len u3)
            2
            "update hit keeps len")
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get u3 "alpha")
              -1)
            70
            "update hit overwrites alpha")))
      (let
        [u0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [u1 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
        [miss : StringI64MapUpdateResult
          (stdlib.hashmap.string-i64-map-update-if-present u1 "missing" 999)]
        [u2 : StringI64Map (stdlib.hashmap.update-result-map miss)]
        (begin
          (test.assert-false
            (stdlib.hashmap.update-ok? miss)
            "update missing is not ok")
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-len u2)
            1
            "update missing keeps len")
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get u2 "missing")
              -1)
            -1
            "update missing does not insert")))
      (let
        [u0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [u1 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u0 "beta" 20)]
        [borrow-key : String "beta"]
        [borrow-hit : StringI64MapUpdateResult
          (stdlib.hashmap.string-i64-map-update-borrowed-if-present
            u1
            (& borrow-key)
            80)]
        [u2 : StringI64Map (stdlib.hashmap.update-result-map borrow-hit)]
        (begin
          (test.assert-true
            (stdlib.hashmap.update-ok? borrow-hit)
            "borrowed update-if-present hit is ok")
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get u2 "beta")
              -1)
            80
            "borrowed update overwrites beta")))
      (let
        [u0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [u1 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
        [u2 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u1 "beta" 20)]
        [removed : StringI64MapRemoveResult
          (stdlib.hashmap.string-i64-map-remove u2 "alpha")]
        [u6 : StringI64Map (stdlib.hashmap.remove-result-map removed)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-deleted u6)
            1
            "entry test starts with one tombstone")
          (let
            [inserted : StringI64MapEntryOrInsertResult
              (stdlib.hashmap.string-i64-map-entry-or-insert u6 "alpha" 111)]
            [u7 : StringI64Map
              (stdlib.hashmap.entry-or-insert-result-map inserted)]
            [found : StringI64MapEntryOrInsertResult
              (stdlib.hashmap.string-i64-map-entry-or-insert u7 "alpha" 222)]
            [u8 : StringI64Map
              (stdlib.hashmap.entry-or-insert-result-map found)]
            (begin
              (test.assert-true
                (stdlib.hashmap.entry-or-insert-inserted? inserted)
                "entry-or-insert inserts missing key")
              (test.assert-i64-eq
                (stdlib.hashmap.entry-or-insert-value-or inserted -1)
                111
                "entry-or-insert returns inserted default")
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-deleted u7)
                0
                "entry-or-insert reuses tombstone")
              (test.assert-false
                (stdlib.hashmap.entry-or-insert-inserted? found)
                "entry-or-insert finds existing key")
              (test.assert-i64-eq
                (stdlib.hashmap.entry-or-insert-value-or found -1)
                111
                "entry-or-insert returns existing value")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get u8 "alpha")
                  -1)
                111
                "entry-or-insert found does not overwrite")))))
      (let
        [u0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [u1 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u0 "alpha" 111)]
        [u9 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u1 "alpha" 333)]
        [grow0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 1)]
        [grow1 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update grow0 "a" 1)]
        [grow2 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update grow1 "b" 2)]
        [grow3 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update grow2 "c" 3)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get u9 "alpha")
              -1)
            333
            "insert-or-update overwrites existing key")
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-len grow3)
            3
            "insert-or-update inserts multiple keys")
          (test.assert-true
            (> (stdlib.hashmap.string-i64-map-capacity grow3) 1)
            "insert-or-update grows tiny table")))
      (let
        [key : String "alpha"]
        [u0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [u1 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
        (begin
          (let
            [entry : (StringI64MapMutEntry u1)
              (stdlib.hashmap.string-i64-map-get-mut-entry-borrowed u1 (& key))]
            (begin
              (test.assert-true
                (stdlib.hashmap.string-i64-map-mut-entry-present? entry)
                "mut entry finds existing key")
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-mut-entry-value-or entry -1)
                10
                "mut entry reads existing value")
              (stdlib.hashmap.string-i64-map-mut-entry-set! entry 77)))
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get u1 "alpha")
              -1)
            77
            "mut entry set updates map storage")))
      (let
        [key : String "missing"]
        [u0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [u1 : StringI64Map
          (stdlib.hashmap.string-i64-map-insert-or-update u0 "alpha" 10)]
        (begin
          (let
            [entry : (StringI64MapMutEntry u1)
              (stdlib.hashmap.string-i64-map-get-mut-entry-borrowed u1 (& key))]
            (begin
              (test.assert-false
                (stdlib.hashmap.string-i64-map-mut-entry-present? entry)
                "mut entry reports missing key")
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-mut-entry-value-or entry -1)
                -1
                "missing mut entry returns fallback")
              (stdlib.hashmap.string-i64-map-mut-entry-set! entry 99)))
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-len u1)
            1
            "missing mut entry no-op")
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get u1 "alpha")
              -1)
            10
            "missing mut entry leaves map unchanged")))
      unit)))

(cfg
  test
  (test
    hashmap-string-i64-resize-rehash
    (begin
      ;; --- resize / rehash (#827) ---
      ;; needs-grow? threshold: a fresh capacity-4 table is below the 3/4 load.
      (test.assert-false
        (stdlib.hashmap.string-i64-map-needs-grow?
          (stdlib.hashmap.string-i64-map-with-capacity 4))
        "fresh cap-4 below load threshold")
      (test.assert-false
        (stdlib.hashmap.string-i64-map-needs-grow?
          (stdlib.hashmap.string-i64-map-with-capacity 0))
        "zero requested capacity rounds to a fresh cap-1 table")
      ;; string-i64-map-put auto-grows past the fixed capacity and preserves every
      ;; entry across the rehash (collision preservation + lookup after rehash).
      (let
        [g0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [g1 : StringI64Map (stdlib.hashmap.string-i64-map-put g0 "a" 1)]
        [g2 : StringI64Map (stdlib.hashmap.string-i64-map-put g1 "b" 2)]
        [g3 : StringI64Map (stdlib.hashmap.string-i64-map-put g2 "c" 3)]
        [g4 : StringI64Map (stdlib.hashmap.string-i64-map-put g3 "d" 4)]
        [g5 : StringI64Map (stdlib.hashmap.string-i64-map-put g4 "e" 5)]
        [g6 : StringI64Map (stdlib.hashmap.string-i64-map-put g5 "f" 6)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-len g6)
            6
            "put six -> len 6")
          (test.assert-true
            (> (stdlib.hashmap.string-i64-map-capacity g6) 4)
            "table grew past the seed capacity")
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-deleted g6)
            0
            "grown table has no tombstones")
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get g6 "a")
              -1)
            1
            "get a after grow")
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get g6 "c")
              -1)
            3
            "get c after grow")
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get g6 "f")
              -1)
            6
            "get f after grow")
          (test.assert-i64-eq
            (stdlib.hashmap.lookup-value-or
              (stdlib.hashmap.string-i64-map-get g6 "missing")
              -1)
            -1
            "absent key after grow")
          ;; overwrite across resize: updating an existing key keeps len.
          (let
            [g7 : StringI64Map (stdlib.hashmap.string-i64-map-put g6 "a" 99)]
            (begin
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-len g7)
                6
                "update keeps len after grow")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get g7 "a")
                  -1)
                99
                "a updated to 99 after grow")))))
      ;; resized drops tombstones: insert 3, remove 1 (deleted=1), resize to 16.
      (let
        [t0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 8)]
        [t1 : StringI64Map
          (stdlib.hashmap.insert-result-map
            (stdlib.hashmap.string-i64-map-insert t0 "x" 10))]
        [t2 : StringI64Map
          (stdlib.hashmap.insert-result-map
            (stdlib.hashmap.string-i64-map-insert t1 "y" 20))]
        [t3 : StringI64Map
          (stdlib.hashmap.insert-result-map
            (stdlib.hashmap.string-i64-map-insert t2 "z" 30))]
        [t4 : StringI64Map
          (stdlib.hashmap.remove-result-map
            (stdlib.hashmap.string-i64-map-remove t3 "y"))]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-deleted t4)
            1
            "one tombstone before resize")
          (let
            [t5 : StringI64Map (stdlib.hashmap.string-i64-map-resized t4 16)]
            [t6 : StringI64Map (stdlib.hashmap.string-i64-map-resized t4 10)]
            (begin
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-capacity t5)
                16
                "resized capacity 16")
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-capacity t6)
                16
                "resized capacity rounds to power of two")
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-len t5)
                2
                "resized len 2")
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-deleted t5)
                0
                "resize drops tombstones")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get t5 "x")
                  -1)
                10
                "x survives resize")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get t5 "z")
                  -1)
                30
                "z survives resize")
              (test.assert-i64-eq
                (stdlib.hashmap.lookup-value-or
                  (stdlib.hashmap.string-i64-map-get t5 "y")
                  -1)
                -1
                "removed y absent after resize")))))
      unit)))

(cfg
  test
  (test
    hashmap-string-i64-iteration
    (begin
      ;; --- deterministic bucket-order iteration (#829) ---
      ;; empty map: the cursor starts at the capacity; count and sum are zero.
      (let
        [e0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 8)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-next-occupied e0 0)
            8
            "empty map cursor starts at capacity")
          (test.assert-i64-eq
            (stdlib.hashmap.iter-count
              e0
              (stdlib.hashmap.string-i64-map-next-occupied e0 0)
              0)
            0
            "empty map iterates zero entries")
          (test.assert-i64-eq
            (stdlib.hashmap.iter-sum-values
              e0
              (stdlib.hashmap.string-i64-map-next-occupied e0 0)
              0)
            0
            "empty map sum is zero")))
      ;; non-empty map: the cursor visits exactly `len` entries, sums every value
      ;; once, and walks strictly increasing (deterministic bucket) indices.
      (let
        [i0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 8)]
        [i1 : StringI64Map (stdlib.hashmap.string-i64-map-put i0 "a" 1)]
        [i2 : StringI64Map (stdlib.hashmap.string-i64-map-put i1 "b" 2)]
        [i3 : StringI64Map (stdlib.hashmap.string-i64-map-put i2 "c" 4)]
        [i4 : StringI64Map (stdlib.hashmap.string-i64-map-put i3 "d" 8)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.string-i64-map-len i4)
            4
            "iteration map has four entries")
          (test.assert-i64-eq
            (stdlib.hashmap.iter-count
              i4
              (stdlib.hashmap.string-i64-map-next-occupied i4 0)
              0)
            4
            "cursor visits exactly len entries")
          (test.assert-i64-eq
            (stdlib.hashmap.iter-sum-values
              i4
              (stdlib.hashmap.string-i64-map-next-occupied i4 0)
              0)
            15
            "cursor sums every value once (1+2+4+8)")
          (test.assert-true
            (stdlib.hashmap.iter-monotonic?
              i4
              (stdlib.hashmap.string-i64-map-next-occupied i4 0))
            "cursor visits strictly increasing indices")
          ;; a removed key is skipped: its tombstone is not iterated.
          (let
            [i5 : StringI64Map
              (stdlib.hashmap.remove-result-map
                (stdlib.hashmap.string-i64-map-remove i4 "b"))]
            (begin
              (test.assert-i64-eq
                (stdlib.hashmap.string-i64-map-len i5)
                3
                "len 3 after removing b")
              (test.assert-i64-eq
                (stdlib.hashmap.iter-count
                  i5
                  (stdlib.hashmap.string-i64-map-next-occupied i5 0)
                  0)
                3
                "cursor skips the tombstone (count 3)")
              (test.assert-i64-eq
                (stdlib.hashmap.iter-sum-values
                  i5
                  (stdlib.hashmap.string-i64-map-next-occupied i5 0)
                  0)
                13
                "cursor sum excludes the removed value (1+4+8)")))))
      ;; entry-at: out-of-range -> None, the only occupied slot -> Some value.
      (let
        [b0 : StringI64Map (stdlib.hashmap.string-i64-map-with-capacity 4)]
        [b1 : StringI64Map (stdlib.hashmap.string-i64-map-put b0 "only" 7)]
        (begin
          (test.assert-true
            (stdlib.hashmap.entry-none?
              (stdlib.hashmap.string-i64-map-entry-at b1 -1))
            "entry-at negative index is None")
          (test.assert-true
            (stdlib.hashmap.entry-none?
              (stdlib.hashmap.string-i64-map-entry-at b1 4))
            "entry-at out-of-range index is None")
          (test.assert-i64-eq
            (stdlib.hashmap.entry-value-or
              (stdlib.hashmap.string-i64-map-entry-at
                b1
                (stdlib.hashmap.string-i64-map-next-occupied b1 0))
              -1)
            7
            "entry-at the only occupied slot is Some 7")))
      unit)))

(cfg
  test
  (test
    hashmap-string-string-family
    (begin
      ;; --- generated String -> String map family (#817) ---
      (let
        [alpha : String "alpha"]
        [beta : String "beta"]
        [missing : String "missing"]
        [ss0 : StringStringMap
          (stdlib.hashmap.string-string-map-with-capacity 4)]
        [ss1 : StringStringMap
          (stdlib.hashmap.string-string-map-put ss0 "alpha" "red")]
        [ss2 : StringStringMap
          (stdlib.hashmap.string-string-map-put ss1 "beta" "amber")]
        [ss3 : StringStringMap
          (stdlib.hashmap.string-string-map-put ss2 "gamma" "blue")]
        [ss4 : StringStringMap
          (stdlib.hashmap.string-string-map-put ss3 "delta" "gold")]
        [ss5 : StringStringMap
          (stdlib.hashmap.string-string-map-put ss4 "alpha" "green")]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.string-string-map-len ss5)
            4
            "StringString len")
          (test.assert-true
            (> (stdlib.hashmap.string-string-map-capacity ss5) 4)
            "StringString grew past seed capacity")
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (stdlib.hashmap.string-string-map-get-borrowed ss5 (& alpha))
              "fallback")
            "green"
            "StringString borrowed get updated alpha")
          (test.assert-i64-eq
            (stdlib.hashmap.string-string-borrowed-value-length-or
              (stdlib.hashmap.string-string-map-get-value-borrowed
                (& ss5)
                (& alpha))
              -1)
            5
            "StringString borrowed value get returns alpha by reference")
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (stdlib.hashmap.string-string-map-get ss5 "gamma")
              "fallback")
            "blue"
            "StringString owned get gamma")
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (stdlib.hashmap.string-string-map-get-borrowed ss5 (& missing))
              "fallback")
            "fallback"
            "StringString missing borrowed get")
          (test.assert-i64-eq
            (stdlib.hashmap.string-string-borrowed-value-length-or
              (stdlib.hashmap.string-string-map-get-value-borrowed
                (& ss5)
                (& missing))
              -1)
            -1
            "StringString missing borrowed value get")
          (test.assert-true
            (stdlib.hashmap.string-string-map-contains-borrowed? ss5 (& beta))
            "StringString borrowed contains beta")
          (let
            [removed : StringStringMapRemoveResult
              (stdlib.hashmap.string-string-map-remove-borrowed ss5 (& beta))]
            (begin
              (test.assert-true
                (stdlib.hashmap.string-string-remove-ok? removed)
                "StringString remove borrowed beta")
              (let
                [ss6 : StringStringMap
                  (stdlib.hashmap.string-string-remove-result-map removed)]
                (begin
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-string-map-len ss6)
                    3
                    "StringString len after remove")
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-string-map-deleted ss6)
                    1
                    "StringString tombstone after remove")
                  (test.assert-false
                    (stdlib.hashmap.string-string-map-contains-borrowed?
                      ss6
                      (& beta))
                    "StringString beta absent after remove")
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-string-iter-count
                      ss6
                      (stdlib.hashmap.string-string-map-next-occupied ss6 0)
                      0)
                    3
                    "StringString iteration count")
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-string-iter-value-length-sum
                      ss6
                      (stdlib.hashmap.string-string-map-next-occupied ss6 0)
                      0)
                    13
                    "StringString iteration value length sum")))))))
      unit)))

(cfg
  test
  (test
    hashmap-string-string-update-entry
    (begin
      ;; --- generated String -> String update / entry-or-insert API (#888) ---
      (let
        [alpha-update : String "alpha"]
        [ssu0 : StringStringMap
          (stdlib.hashmap.string-string-map-with-capacity 4)]
        [ssu1 : StringStringMap
          (stdlib.hashmap.string-string-map-insert-or-update ssu0 "alpha" "red")]
        [ssu2 : StringStringMap
          (stdlib.hashmap.string-string-map-insert-or-update
            ssu1
            "beta"
            "amber")]
        [ssu-hit : StringStringMapUpdateResult
          (stdlib.hashmap.string-string-map-update-borrowed-if-present
            ssu2
            (& alpha-update)
            "green")]
        [ssu3 : StringStringMap
          (stdlib.hashmap.string-string-update-result-map ssu-hit)]
        (begin
          (test.assert-true
            (stdlib.hashmap.string-string-update-ok? ssu-hit)
            "StringString borrowed update hit")
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (stdlib.hashmap.string-string-map-get ssu3 "alpha")
              "fallback")
            "green"
            "StringString update overwrites alpha")))
      (let
        [ssu0 : StringStringMap
          (stdlib.hashmap.string-string-map-with-capacity 4)]
        [ssu1 : StringStringMap
          (stdlib.hashmap.string-string-map-insert-or-update ssu0 "alpha" "red")]
        [ssu-miss : StringStringMapUpdateResult
          (stdlib.hashmap.string-string-map-update-if-present
            ssu1
            "missing"
            "black")]
        [ssu2 : StringStringMap
          (stdlib.hashmap.string-string-update-result-map ssu-miss)]
        (begin
          (test.assert-false
            (stdlib.hashmap.string-string-update-ok? ssu-miss)
            "StringString update miss")
          (test.assert-i64-eq
            (stdlib.hashmap.string-string-map-len ssu2)
            1
            "StringString update miss keeps len")))
      (let
        [ssu0 : StringStringMap
          (stdlib.hashmap.string-string-map-with-capacity 4)]
        [ssu1 : StringStringMap
          (stdlib.hashmap.string-string-map-insert-or-update
            ssu0
            "alpha"
            "green")]
        [ssu2 : StringStringMap
          (stdlib.hashmap.string-string-map-insert-or-update
            ssu1
            "beta"
            "amber")]
        [ssu-removed : StringStringMapRemoveResult
          (stdlib.hashmap.string-string-map-remove ssu2 "beta")]
        [ssu3 : StringStringMap
          (stdlib.hashmap.string-string-remove-result-map ssu-removed)]
        [ssu-inserted : StringStringMapEntryOrInsertResult
          (stdlib.hashmap.string-string-map-entry-or-insert ssu3 "beta" "gold")]
        [ssu4 : StringStringMap
          (stdlib.hashmap.string-string-entry-or-insert-result-map ssu-inserted)]
        [ssu-found : StringStringMapEntryOrInsertResult
          (stdlib.hashmap.string-string-map-entry-or-insert
            ssu4
            "alpha"
            "purple")]
        [ssu5 : StringStringMap
          (stdlib.hashmap.string-string-entry-or-insert-result-map ssu-found)]
        (begin
          (test.assert-true
            (stdlib.hashmap.string-string-entry-or-insert-inserted?
              ssu-inserted)
            "StringString entry-or-insert inserted")
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-entry-or-insert-value-or
              ssu-inserted
              "fallback")
            "gold"
            "StringString entry-or-insert returns default")
          (test.assert-i64-eq
            (stdlib.hashmap.string-string-map-deleted ssu4)
            0
            "StringString entry-or-insert reuses tombstone")
          (test.assert-false
            (stdlib.hashmap.string-string-entry-or-insert-inserted? ssu-found)
            "StringString entry-or-insert found")
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-entry-or-insert-value-or
              ssu-found
              "fallback")
            "green"
            "StringString entry-or-insert returns existing")
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (stdlib.hashmap.string-string-map-get ssu5 "alpha")
              "fallback")
            "green"
            "StringString entry-or-insert found does not overwrite")))
      (let
        [ssu0 : StringStringMap
          (stdlib.hashmap.string-string-map-with-capacity 2)]
        [ssu1 : StringStringMap
          (stdlib.hashmap.string-string-map-insert-or-update
            ssu0
            "alpha"
            "green")]
        [ssu2 : StringStringMap
          (stdlib.hashmap.string-string-map-insert-or-update ssu1 "beta" "gold")]
        [ssu3 : StringStringMap
          (stdlib.hashmap.string-string-map-insert-or-update
            ssu2
            "gamma"
            "blue")]
        (begin
          (stdlib.hashmap.hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (stdlib.hashmap.string-string-map-get ssu3 "gamma")
              "fallback")
            "blue"
            "StringString insert-or-update inserts new key")
          (test.assert-true
            (> (stdlib.hashmap.string-string-map-capacity ssu3) 2)
            "StringString insert-or-update grows")))
      unit)))

(cfg
  test
  (test
    hashmap-i64-i64-family
    (begin
      ;; --- generated i64 -> i64 map family (#817) ---
      (let
        [ii0 : I64I64Map (stdlib.hashmap.i64-i64-map-with-capacity 4)]
        [ii1 : I64I64Map (stdlib.hashmap.i64-i64-map-put ii0 1 10)]
        [ii2 : I64I64Map (stdlib.hashmap.i64-i64-map-put ii1 2 20)]
        [ii3 : I64I64Map (stdlib.hashmap.i64-i64-map-put ii2 3 30)]
        [ii4 : I64I64Map (stdlib.hashmap.i64-i64-map-put ii3 4 40)]
        [ii5 : I64I64Map (stdlib.hashmap.i64-i64-map-put ii4 1 99)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-map-len ii5)
            4
            "I64I64 len")
          (test.assert-true
            (> (stdlib.hashmap.i64-i64-map-capacity ii5) 4)
            "I64I64 grew past seed capacity")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or
              (stdlib.hashmap.i64-i64-map-get ii5 1)
              -1)
            99
            "I64I64 updated key 1")
          (test.assert-true
            (stdlib.hashmap.i64-i64-borrowed-value-found?
              (stdlib.hashmap.i64-i64-map-get-value-borrowed (& ii5) 1))
            "I64I64 borrowed value get finds key 1")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or
              (stdlib.hashmap.i64-i64-map-get ii5 3)
              -1)
            30
            "I64I64 get key 3")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or
              (stdlib.hashmap.i64-i64-map-get ii5 99)
              -1)
            -1
            "I64I64 missing key")
          (test.assert-false
            (stdlib.hashmap.i64-i64-borrowed-value-found?
              (stdlib.hashmap.i64-i64-map-get-value-borrowed (& ii5) 99))
            "I64I64 missing borrowed value get")
          (test.assert-true
            (stdlib.hashmap.i64-i64-map-contains? ii5 2)
            "I64I64 contains key 2")
          (let
            [removed : I64I64MapRemoveResult
              (stdlib.hashmap.i64-i64-map-remove ii5 2)]
            (begin
              (test.assert-true
                (stdlib.hashmap.i64-i64-remove-ok? removed)
                "I64I64 remove key 2")
              (let
                [ii6 : I64I64Map
                  (stdlib.hashmap.i64-i64-remove-result-map removed)]
                (begin
                  (test.assert-i64-eq
                    (stdlib.hashmap.i64-i64-map-len ii6)
                    3
                    "I64I64 len after remove")
                  (test.assert-i64-eq
                    (stdlib.hashmap.i64-i64-map-deleted ii6)
                    1
                    "I64I64 tombstone after remove")
                  (test.assert-false
                    (stdlib.hashmap.i64-i64-map-contains? ii6 2)
                    "I64I64 removed key absent")
                  (test.assert-i64-eq
                    (stdlib.hashmap.i64-i64-iter-count
                      ii6
                      (stdlib.hashmap.i64-i64-map-next-occupied ii6 0)
                      0)
                    3
                    "I64I64 iteration count")
                  (test.assert-i64-eq
                    (stdlib.hashmap.i64-i64-iter-value-sum
                      ii6
                      (stdlib.hashmap.i64-i64-map-next-occupied ii6 0)
                      0)
                    169
                    "I64I64 iteration value sum")))))))
      unit)))

(cfg
  test
  (test
    hashmap-i64-i64-update-entry
    (begin
      ;; --- generated i64 -> i64 update / entry-or-insert API (#888) ---
      (let
        [iiu0 : I64I64Map (stdlib.hashmap.i64-i64-map-with-capacity 4)]
        [iiu1 : I64I64Map
          (stdlib.hashmap.i64-i64-map-insert-or-update iiu0 1 10)]
        [iiu2 : I64I64Map
          (stdlib.hashmap.i64-i64-map-insert-or-update iiu1 2 20)]
        [iiu-hit : I64I64MapUpdateResult
          (stdlib.hashmap.i64-i64-map-update-if-present iiu2 1 70)]
        [iiu3 : I64I64Map (stdlib.hashmap.i64-i64-update-result-map iiu-hit)]
        (begin
          (test.assert-true
            (stdlib.hashmap.i64-i64-update-ok? iiu-hit)
            "I64I64 update hit")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or
              (stdlib.hashmap.i64-i64-map-get iiu3 1)
              -1)
            70
            "I64I64 update overwrites key 1")))
      (let
        [iiu0 : I64I64Map (stdlib.hashmap.i64-i64-map-with-capacity 4)]
        [iiu1 : I64I64Map
          (stdlib.hashmap.i64-i64-map-insert-or-update iiu0 1 10)]
        [iiu-miss : I64I64MapUpdateResult
          (stdlib.hashmap.i64-i64-map-update-if-present iiu1 99 990)]
        [iiu2 : I64I64Map (stdlib.hashmap.i64-i64-update-result-map iiu-miss)]
        (begin
          (test.assert-false
            (stdlib.hashmap.i64-i64-update-ok? iiu-miss)
            "I64I64 update miss")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-map-len iiu2)
            1
            "I64I64 update miss keeps len")))
      (let
        [iiu0 : I64I64Map (stdlib.hashmap.i64-i64-map-with-capacity 4)]
        [iiu1 : I64I64Map
          (stdlib.hashmap.i64-i64-map-insert-or-update iiu0 1 70)]
        [iiu2 : I64I64Map
          (stdlib.hashmap.i64-i64-map-insert-or-update iiu1 2 20)]
        [iiu-removed : I64I64MapRemoveResult
          (stdlib.hashmap.i64-i64-map-remove iiu2 2)]
        [iiu5 : I64I64Map
          (stdlib.hashmap.i64-i64-remove-result-map iiu-removed)]
        [iiu-inserted : I64I64MapEntryOrInsertResult
          (stdlib.hashmap.i64-i64-map-entry-or-insert iiu5 2 222)]
        [iiu6 : I64I64Map
          (stdlib.hashmap.i64-i64-entry-or-insert-result-map iiu-inserted)]
        [iiu-found : I64I64MapEntryOrInsertResult
          (stdlib.hashmap.i64-i64-map-entry-or-insert iiu6 1 111)]
        [iiu7 : I64I64Map
          (stdlib.hashmap.i64-i64-entry-or-insert-result-map iiu-found)]
        (begin
          (test.assert-true
            (stdlib.hashmap.i64-i64-entry-or-insert-inserted? iiu-inserted)
            "I64I64 entry-or-insert inserted")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-entry-or-insert-value-or iiu-inserted -1)
            222
            "I64I64 entry-or-insert returns default")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-map-deleted iiu6)
            0
            "I64I64 entry-or-insert reuses tombstone")
          (test.assert-false
            (stdlib.hashmap.i64-i64-entry-or-insert-inserted? iiu-found)
            "I64I64 entry-or-insert found")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-entry-or-insert-value-or iiu-found -1)
            70
            "I64I64 entry-or-insert returns existing")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or
              (stdlib.hashmap.i64-i64-map-get iiu7 1)
              -1)
            70
            "I64I64 entry-or-insert found does not overwrite")))
      (let
        [iiu0 : I64I64Map (stdlib.hashmap.i64-i64-map-with-capacity 2)]
        [iiu1 : I64I64Map
          (stdlib.hashmap.i64-i64-map-insert-or-update iiu0 1 70)]
        [iiu2 : I64I64Map
          (stdlib.hashmap.i64-i64-map-insert-or-update iiu1 2 222)]
        [iiu8 : I64I64Map
          (stdlib.hashmap.i64-i64-map-insert-or-update iiu2 3 30)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or
              (stdlib.hashmap.i64-i64-map-get iiu8 3)
              -1)
            30
            "I64I64 insert-or-update inserts key 3")
          (test.assert-true
            (> (stdlib.hashmap.i64-i64-map-capacity iiu8) 2)
            "I64I64 insert-or-update grows")))
      unit)))