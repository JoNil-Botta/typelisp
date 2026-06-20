;# Generated concrete hashmap family (collections v1, #817/#825).
;#
;# Open-addressed, linear-probing maps generated from explicit declaration
;# requests. `StringI64Map` remains the checked-in compatibility
;# `HashMap<String,i64>` template chosen in #824/#825; this module requests
;# generated `StringStringMap` and `I64I64Map` families with the same
;# representation and API shape. String-key maps use the same string hash and
;# equality rules as `hash-string`; i64-key maps normalize the scalar key
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
;# yet; TypeLisp still uses `comptime-decl` generator requests instead of
;# source-level generics or traits. These maps
;# are the stdlib choice for ordinary program data keyed by `String` or `i64`;
;# compiler-internal symbol tables may keep using specialized maps when their
;# value domain or lifecycle is tighter than a public stdlib collection.
;#
;# `stdlib/hashmap-family` generation keys include a key descriptor identity in
;# addition to key and value `type-key` strings. The built-in descriptors are:
;# - `stdlib/hashmap/string-key-v1`: owned `String` keys, `hash-string`,
;#   `hash-key-string-eq?`, borrowed key lookup/contains/remove wrappers, and
;#   borrowed value lookup results tied to the map lifetime.
;# - `stdlib/hashmap/i64-key-v1`: scalar `i64` keys, `hash-i64`,
;#   `hash-key-i64-eq?`, no borrowed-key wrappers, and generated borrowed
;#   value lookup results tied to the map lifetime.
;# - `stdlib/hashmap/aggregate-key-v1`: owned nominal struct/enum keys. Hashing
;#   and equality are derived from supported fields/payloads in declaration
;#   order (`i64`, `bool`, `char`, `String`, and nested supported nominal
;#   aggregates). No borrowed-key wrappers are emitted.
;# Unsupported key types are intentionally rejected by the generator request
;# path instead of falling back to a trait or implicit `Hash`/`Eq` bound.
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

(import stdlib.hash as hash_mod)
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
    (hash_mod.hash-normalize hash)
    capacity))

;: Advance a bucket index by one slot, wrapping around the table.
(define (string-i64-map-next-index [index : i64] [capacity : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next capacity)
      0
      next)))

;: Read the slot at `index`. Probe/iteration indices are always in
;: `[0, capacity)`, so the bounds check never fires. Keep this on `array-ref`
;: until the published stage0 includes aggregate raw-pointer read/offset fixes;
;: stdlib/hashmap.tl is compiled into the next compiler by the previous seed
;: (#2840).
(define (string-i64-map-slot-at
  [slots : (Array StringI64MapSlot)]
  [index : i64]) : StringI64MapSlot
  (array-ref slots index))

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
              (hash_mod.hash-key-string-eq? (& slot-key) (& key))
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
;: inserted (`Absent`), or `Full`. Callers compute `hash` with `hash-string`.
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
              (hash_mod.hash-key-string-eq? (& slot-key) key)
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

;: Probe when `hash` is already normalized, as produced by `hash-string` or
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

;: Live mutable entry handle for an existing bucket. The direct `slots` handle is
;: used for reads/writes on current stage0; `borrow` carries the unique borrow so
;: the checker rejects another mutable entry or table mutation while live.
(defstruct StringI64MapMutEntry
  (:lifetimes map)
  (slots (Array StringI64MapSlot))
  (borrow (&mut map (Array StringI64MapSlot)))
  (index i64)
  (present bool)
  (key String)
  (hash i64))

;: The map's backing slot array.
(define (string-i64-map-slots [map : StringI64Map]) : (Array StringI64MapSlot)
  (struct-get map slots))

;: Number of live (occupied) entries.
(define (string-i64-map-len [map : StringI64Map]) : i64
  (struct-get map len))

;: Number of slots in the backing table.
(define (string-i64-map-capacity [map : StringI64Map]) : i64
  (array-length (struct-get map slots)))

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
  (if (>= index count)
    unit
    (begin
      (array-set! slots index (StringI64MapEmpty))
      (stdlib.hashmap.string-i64-map-fill-empty slots (+ index 1) count))))

;: Create an empty map with `capacity` rounded up to a positive power of two.
(define (string-i64-map-with-capacity [capacity : i64]) : StringI64Map
  (let
    [rounded-capacity : i64
      (stdlib.hashmap.string-i64-map-round-capacity capacity)]
    [slots : (Array StringI64MapSlot)
      (make-array StringI64MapSlot rounded-capacity)]
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
    [capacity : i64 (array-length slots)]
    (if (<= capacity 0)
      (StringI64MapMissing)
      (let
        [hash : i64 (hash_mod.hash-string key)]
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
                  (hash_mod.hash-key-string-eq? (& slot-key) key)
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

;: Look up borrowed `key`, returning a reference to the map-owned `i64` value
;: or `Missing`. The reference is invalidated by any map mutation/resizing.
(define (string-i64-map-get-value-borrowed
  [map : (& map StringI64Map)]
  [key : (& key str)]) : (StringI64MapBorrowedValueLookup map)
  (let
    [capacity : i64 (array-length (struct-get map slots))]
    (if (<= capacity 0)
      (stdlib.hashmap.string-i64-map-borrowed-value-missing map)
      (let
        [hash : i64 (hash_mod.hash-string key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array-ref (struct-get map slots) cursor)
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
                  (hash_mod.hash-key-string-eq? (& slot-key) key)
                  false)
                  (match (& (array-ref (struct-get map slots) cursor))
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
    [capacity : i64 (array-length slots)]
    (if (<= capacity 0)
      false
      (let
        [hash : i64 (hash_mod.hash-string key)]
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
                  (hash_mod.hash-key-string-eq? (& slot-key) key)
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
    [capacity : i64 (array-length slots)]
    [hash : i64 (hash_mod.hash-string (& key))]
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
                    (array-set!
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
                  (hash_mod.hash-key-string-eq? (& slot-key) (& key))
                  false)
                  (begin
                    (array-set!
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
                (array-set! slots first (StringI64MapOccupied key value hash))
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
    [capacity : i64 (array-length slots)]
    (if (<= capacity 0)
      (StringI64MapRemoveMissing map)
      (let
        [hash : i64 (hash_mod.hash-string key)]
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
                  (hash_mod.hash-key-string-eq? (& slot-key) key)
                  false)
                  (begin
                    (array-set! slots cursor (StringI64MapTombstone))
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
    [hash : i64 (hash_mod.hash-string key)]
    (match (stdlib.hashmap.string-i64-map-probe-borrowed
      slots
      (stdlib.hashmap.string-i64-map-capacity map)
      key
      hash)
      [(StringI64MapProbeFound index)
        (match (array-ref slots index)
          [(StringI64MapOccupied slot-key _ slot-hash)
            (begin
              (array-set!
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
                (array-set! slots cursor (StringI64MapOccupied key value hash))
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
  (if (>= index count)
    unit
    (begin
      (match (stdlib.hashmap.string-i64-map-slot-at src index)
        [(StringI64MapOccupied key value hash)
          (stdlib.hashmap.string-i64-map-insert-into-empty
            dst
            dst-capacity
            key
            value
            hash)]
        [(StringI64MapEmpty) unit]
        [(StringI64MapTombstone) unit])
      (stdlib.hashmap.string-i64-map-rehash-from
        src
        dst
        dst-capacity
        (+ index 1)
        count))))

;: Rebuild `map` as a fresh power-of-two table holding only its live entries
;: (tombstones dropped, so the deleted count resets to 0). The backing array is
;: newly allocated; the old one is reclaimed when the arena resets.
(define (string-i64-map-resized [map : StringI64Map] [new-capacity : i64]) : StringI64Map
  (let
    [src : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    [old-capacity : i64 (array-length src)]
    [requested-capacity : i64
      (if (> (stdlib.hashmap.string-i64-map-len map) new-capacity)
        (stdlib.hashmap.string-i64-map-len map)
        new-capacity)]
    [rounded-capacity : i64
      (stdlib.hashmap.string-i64-map-round-capacity requested-capacity)]
    [dst : (Array StringI64MapSlot)
      (make-array StringI64MapSlot rounded-capacity)]
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
      (stdlib.hashmap.string-i64-map-grow-capacity (array-length slots)))))

;: True when the table has reached the 3/4 load threshold, counting both live
;: entries and tombstones (both consume probe positions). A non-positive
;: capacity always needs to grow before it can hold anything.
(define (string-i64-map-needs-grow? [map : StringI64Map]) : bool
  (let
    [capacity : i64 (array-length (stdlib.hashmap.string-i64-map-slots map))]
    [used : i64
      (+
        (stdlib.hashmap.string-i64-map-len map)
        (stdlib.hashmap.string-i64-map-deleted map))]
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
    [hash : i64 (hash_mod.hash-string (& key))]
    (match (stdlib.hashmap.string-i64-map-probe-borrowed
      slots
      (stdlib.hashmap.string-i64-map-capacity map)
      (& key)
      hash)
      [(StringI64MapProbeFound index)
        (match (array-ref slots index)
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
      [hash : i64 (hash_mod.hash-string key)]
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
                (hash_mod.hash-key-string-eq? (& slot-key) key)
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
  [slots : (Array StringI64MapSlot)]
  [borrow : (&mut map (Array StringI64MapSlot))]) : (StringI64MapMutEntry map)
  (StringI64MapMutEntry
    slots
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
      (array-length (struct-get ,map slots))
      ,key)
    (struct-get ,map slots)
    (&mut (struct-get ,map slots))))

;: Return whether a mutable-entry handle currently points at an occupied slot.
(define (string-i64-map-mut-entry-present? [entry : (StringI64MapMutEntry map)]) : bool
  (struct-get entry present))

;: Return the handle's current value when present, otherwise `fallback`.
(define (string-i64-map-mut-entry-value-or
  [entry : (StringI64MapMutEntry map)]
  [fallback : i64]) : i64
  (if (stdlib.hashmap.string-i64-map-mut-entry-present? entry)
    (match (array-ref (struct-get entry slots) (struct-get entry index))
      [(StringI64MapOccupied _ value _) value]
      [(StringI64MapEmpty) fallback]
      [(StringI64MapTombstone) fallback])
    fallback))

;: Update the handle's occupied slot in place. Missing-entry handles are a no-op.
(define (string-i64-map-mut-entry-set!
  [entry : (StringI64MapMutEntry map)]
  [value : i64]) : unit
  (if (stdlib.hashmap.string-i64-map-mut-entry-present? entry)
    (array-set!
      (struct-get entry slots)
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
  (if (>= index capacity)
    capacity
    (match (stdlib.hashmap.string-i64-map-slot-at slots index)
      [(StringI64MapOccupied _ _ _) index]
      [(StringI64MapEmpty)
        (stdlib.hashmap.string-i64-map-next-occupied-from
          slots
          (+ index 1)
          capacity)]
      [(StringI64MapTombstone)
        (stdlib.hashmap.string-i64-map-next-occupied-from
          slots
          (+ index 1)
          capacity)])))

;: Iteration cursor: the index of the first occupied slot at or after `from`
;: (in ascending bucket order), or the capacity when no live entry remains.
;: A negative `from` is clamped to 0.
;:
;: v1 iterates in *bucket order* Ã¢â‚¬â€ ascending slot index, skipping empty and
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
      (array-length slots))))

;: The live entry at `index`, or `None` for an empty slot, a tombstone, or an
;: index outside `[0, capacity)`. Pair with `string-i64-map-next-occupied` to
;: walk the map in bucket order. The key is handed back by value; v1 does not
;: yet enforce that the borrow outlives the map (revisited under #806).
(define (string-i64-map-entry-at [map : StringI64Map] [index : i64]) : StringI64MapEntry
  (let
    [slots : (Array StringI64MapSlot) (stdlib.hashmap.string-i64-map-slots map)]
    (if (if (< index 0)
      true
      (>= index (array-length slots)))
      (StringI64MapEntryNone)
      (match (stdlib.hashmap.string-i64-map-slot-at slots index)
        [(StringI64MapOccupied key value _) (StringI64MapEntrySome key value)]
        [(StringI64MapEmpty) (StringI64MapEntryNone)]
        [(StringI64MapTombstone) (StringI64MapEntryNone)]))))

;: Generated `HashMap<String,String>` family request. The full public API is
;: produced by the `stdlib/hashmap-family` declaration generator.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMap (type-key (type String)) (type-key
    (type String)) "stdlib/hashmap/string-key-v1")
  (defstruct StringStringMap
    (__hashmap_family_request i64)))

;: Generated `HashMap<i64,i64>` family request. The full public API is
;: produced by the `stdlib/hashmap-family` declaration generator.
(comptime-decl
  (:generated stdlib/hashmap-family I64I64Map (type-key (type i64)) (type-key
    (type i64)) "stdlib/hashmap/i64-key-v1")
  (defstruct I64I64Map
    (__hashmap_family_request i64)))

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

(cfg
  test
  (comptime-decl
    (:generated stdlib/hashmap-family I64StringMap (type-key (type i64)) (type-key
      (type String)) "stdlib/hashmap/i64-key-v1")
    (defstruct I64StringMap
      (__hashmap_family_request i64))))

(cfg
  test
  (comptime-decl
    (:generated stdlib/hashmap-family StringHashPayloadMap (type-key
      (type String)) (type-key (type HashPayload)) "stdlib/hashmap/string-key-v1")
    (defstruct StringHashPayloadMap
      (__hashmap_family_request i64))))

(cfg
  test
  (comptime-decl
    (:generated stdlib/hashmap-family I64HashStateMap (type-key (type i64)) (type-key
      (type HashState)) "stdlib/hashmap/i64-key-v1")
    (defstruct I64HashStateMap
      (__hashmap_family_request i64))))

(cfg
  test
  (comptime-decl
    (:generated stdlib/hashmap-family HashNestedKeyI64Map (type-key
      (type HashNestedKey)) (type-key (type i64)) "stdlib/hashmap/aggregate-key-v1")
    (defstruct HashNestedKeyI64Map
      (__hashmap_family_request i64))))

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
            (array-set! slots i (StringI64MapEmpty))
            (set! i (+ i 1))))
        slots))))

(cfg
  test
  (define (new-slots [n : i64]) : (Array StringI64MapSlot)
    (stdlib.hashmap.fill-empty (make-array StringI64MapSlot n) n)))

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
;; `(string-i64-map-next-occupied m 0)` and advanced with the cursor.
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
    (if (>= i (string-string-map-capacity m))
      acc
      (stdlib.hashmap.string-string-iter-count
        m
        (string-string-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (string-string-iter-value-length-sum
    [m : StringStringMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (string-string-map-capacity m))
      acc
      (stdlib.hashmap.string-string-iter-value-length-sum
        m
        (string-string-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.string-string-entry-value-length-or
            (string-string-map-entry-at m i)
            0))))))

(cfg
  test
  (define (i64-i64-iter-count [m : I64I64Map] [i : i64] [acc : i64]) : i64
    (if (>= i (i64-i64-map-capacity m))
      acc
      (stdlib.hashmap.i64-i64-iter-count
        m
        (i64-i64-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (i64-i64-iter-value-sum [m : I64I64Map] [i : i64] [acc : i64]) : i64
    (if (>= i (i64-i64-map-capacity m))
      acc
      (stdlib.hashmap.i64-i64-iter-value-sum
        m
        (i64-i64-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.i64-i64-entry-value-or (i64-i64-map-entry-at m i) 0))))))

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
    (if (>= i (string-hash-payload-map-capacity m))
      acc
      (stdlib.hashmap.string-hash-payload-iter-count
        m
        (string-hash-payload-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (string-hash-payload-iter-score-sum
    [m : StringHashPayloadMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (string-hash-payload-map-capacity m))
      acc
      (stdlib.hashmap.string-hash-payload-iter-score-sum
        m
        (string-hash-payload-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.string-hash-payload-entry-score-or
            (string-hash-payload-map-entry-at m i)
            0))))))

(cfg
  test
  (define (i64-hash-state-iter-count
    [m : I64HashStateMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (i64-hash-state-map-capacity m))
      acc
      (stdlib.hashmap.i64-hash-state-iter-count
        m
        (i64-hash-state-map-next-occupied m (+ i 1))
        (+ acc 1)))))

(cfg
  test
  (define (i64-hash-state-iter-score-sum
    [m : I64HashStateMap]
    [i : i64]
    [acc : i64]) : i64
    (if (>= i (i64-hash-state-map-capacity m))
      acc
      (stdlib.hashmap.i64-hash-state-iter-score-sum
        m
        (i64-hash-state-map-next-occupied m (+ i 1))
        (+
          acc
          (stdlib.hashmap.i64-hash-state-entry-score-or
            (i64-hash-state-map-entry-at m i)
            0))))))

(cfg
  test
  (test
    hashmap-descriptor-contract
    (begin
      ;; --- hashmap-family key descriptor contract (#2056) ---
      (hashmap-test-assert-owned-string-eq
        (stdlib.hashmap.hashmap-string-key-descriptor-key)
        "stdlib/hashmap/string-key-v1"
        "String key descriptor identity")
      (hashmap-test-assert-owned-string-eq
        (stdlib.hashmap.hashmap-i64-key-descriptor-key)
        "stdlib/hashmap/i64-key-v1"
        "i64 key descriptor identity")
      (hashmap-test-assert-owned-string-eq
        (stdlib.hashmap.hashmap-aggregate-key-descriptor-key)
        "stdlib/hashmap/aggregate-key-v1"
        "aggregate key descriptor identity")
      unit)))

(cfg
  test
  (test
    hashmap-aggregate-key-fixtures
    (begin
      ;; --- hashmap-family aggregate key fixtures (#2729) ---
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
    hashmap-extra-family-requests
    (begin
      ;; --- hashmap-family marker request fixture beyond shipped families ---
      (let
        [fixture0 : I64StringMap (i64-string-map-with-capacity 2)]
        [fixture1 : I64StringMap (i64-string-map-put fixture0 7 "seven")]
        (begin
          (test.assert-i64-eq
            (i64-string-map-len fixture1)
            1
            "i64->String fixture generated len helper")
          (hashmap-test-assert-owned-string-eq
            (match (i64-string-map-get fixture1 7)
              [(I64StringMapFound value) value]
              [(I64StringMapMissing) "missing"])
            "seven"
            "i64->String fixture generated get helper")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-string-borrowed-value-length-or
              (i64-string-map-get-value-borrowed (& fixture1) 7)
              -1)
            5
            "i64->String fixture borrowed value helper")
          (test.assert-false
            (i64-string-map-contains? fixture1 9)
            "i64->String fixture generated contains helper")))
      unit)))

(cfg
  test
  (test
    hashmap-aggregate-value-fixtures
    (begin
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
          (stdlib.hashmap.string-hash-payload-update-result-map payload-hit)]
        (begin
          (test.assert-true
            (> (string-hash-payload-map-capacity payload4) 2)
            "StringHashPayload grows aggregate values")
          (test.assert-true
            (stdlib.hashmap.string-hash-payload-update-ok? payload-hit)
            "StringHashPayload borrowed update hit")
          (test.assert-i64-eq
            (stdlib.hashmap.string-hash-payload-lookup-score-or
              (string-hash-payload-map-get payload4 "alpha")
              -1)
            21
            "StringHashPayload owned get updated aggregate")
          (test.assert-i64-eq
            (stdlib.hashmap.string-hash-payload-borrowed-score-or
              (string-hash-payload-map-get-value-borrowed
                (& payload4)
                (& alpha))
              -1)
            21
            "StringHashPayload borrowed value exposes fields")
          (let
            [payload-remove : StringHashPayloadMapRemoveResult
              (string-hash-payload-map-remove payload4 "beta")]
            [payload5 : StringHashPayloadMap
              (stdlib.hashmap.string-hash-payload-remove-result-map
                payload-remove)]
            (begin
              (test.assert-true
                (stdlib.hashmap.string-hash-payload-remove-ok? payload-remove)
                "StringHashPayload remove aggregate")
              (test.assert-false
                (string-hash-payload-map-contains? payload5 "beta")
                "StringHashPayload removed key absent")
              (test.assert-i64-eq
                (stdlib.hashmap.string-hash-payload-iter-count
                  payload5
                  (string-hash-payload-map-next-occupied payload5 0)
                  0)
                2
                "StringHashPayload iteration count")
              (test.assert-i64-eq
                (stdlib.hashmap.string-hash-payload-iter-score-sum
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
        [states4 : I64HashStateMap
          (stdlib.hashmap.i64-hash-state-update-result-map state-hit)]
        (begin
          (test.assert-true
            (> (i64-hash-state-map-capacity states4) 2)
            "I64HashState grows enum values")
          (test.assert-true
            (stdlib.hashmap.i64-hash-state-update-ok? state-hit)
            "I64HashState update hit")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-hash-state-lookup-score-or
              (i64-hash-state-map-get states4 2)
              -1)
            22
            "I64HashState get updated enum")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-hash-state-lookup-score-or
              (i64-hash-state-map-get states4 99)
              -1)
            -1
            "I64HashState missing enum")
          (let
            [state-remove : I64HashStateMapRemoveResult
              (i64-hash-state-map-remove states4 1)]
            [states5 : I64HashStateMap
              (stdlib.hashmap.i64-hash-state-remove-result-map state-remove)]
            [state-inserted : I64HashStateMapEntryOrInsertResult
              (i64-hash-state-map-entry-or-insert states5 4 (HashReady 40))]
            [states6 : I64HashStateMap
              (stdlib.hashmap.i64-hash-state-entry-or-insert-result-map
                state-inserted)]
            [state-found : I64HashStateMapEntryOrInsertResult
              (i64-hash-state-map-entry-or-insert states6 2 (HashFailed))]
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
                  (i64-hash-state-map-next-occupied states7 0)
                  0)
                3
                "I64HashState iteration count")
              (test.assert-i64-eq
                (stdlib.hashmap.i64-hash-state-iter-score-sum
                  states7
                  (i64-hash-state-map-next-occupied states7 0)
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
          (array-set! found 1 (StringI64MapOccupied "k" 7 5))
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
          (array-set! collide 1 (StringI64MapOccupied "other" 9 5))
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
          (array-set! wrap 3 (StringI64MapOccupied "o" 9 3))
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
          (array-set! tomb 1 (StringI64MapTombstone))
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
          (array-set! tf 1 (StringI64MapTombstone))
          (array-set! tf 2 (StringI64MapOccupied "k" 7 5))
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
          (array-set! full 0 (StringI64MapOccupied "a" 1 10))
          (array-set! full 1 (StringI64MapOccupied "b" 2 11))
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
          (array-set! fulltomb 0 (StringI64MapOccupied "a" 1 10))
          (array-set! fulltomb 1 (StringI64MapTombstone))
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
        [ss0 : StringStringMap (string-string-map-with-capacity 4)]
        [ss1 : StringStringMap (string-string-map-put ss0 "alpha" "red")]
        [ss2 : StringStringMap (string-string-map-put ss1 "beta" "amber")]
        [ss3 : StringStringMap (string-string-map-put ss2 "gamma" "blue")]
        [ss4 : StringStringMap (string-string-map-put ss3 "delta" "gold")]
        [ss5 : StringStringMap (string-string-map-put ss4 "alpha" "green")]
        (begin
          (test.assert-i64-eq (string-string-map-len ss5) 4 "StringString len")
          (test.assert-true
            (> (string-string-map-capacity ss5) 4)
            "StringString grew past seed capacity")
          (hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (string-string-map-get-borrowed ss5 (& alpha))
              "fallback")
            "green"
            "StringString borrowed get updated alpha")
          (test.assert-i64-eq
            (stdlib.hashmap.string-string-borrowed-value-length-or
              (string-string-map-get-value-borrowed (& ss5) (& alpha))
              -1)
            5
            "StringString borrowed value get returns alpha by reference")
          (hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (string-string-map-get ss5 "gamma")
              "fallback")
            "blue"
            "StringString owned get gamma")
          (hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (string-string-map-get-borrowed ss5 (& missing))
              "fallback")
            "fallback"
            "StringString missing borrowed get")
          (test.assert-i64-eq
            (stdlib.hashmap.string-string-borrowed-value-length-or
              (string-string-map-get-value-borrowed (& ss5) (& missing))
              -1)
            -1
            "StringString missing borrowed value get")
          (test.assert-true
            (string-string-map-contains-borrowed? ss5 (& beta))
            "StringString borrowed contains beta")
          (let
            [removed : StringStringMapRemoveResult
              (string-string-map-remove-borrowed ss5 (& beta))]
            (begin
              (test.assert-true
                (stdlib.hashmap.string-string-remove-ok? removed)
                "StringString remove borrowed beta")
              (let
                [ss6 : StringStringMap
                  (stdlib.hashmap.string-string-remove-result-map removed)]
                (begin
                  (test.assert-i64-eq
                    (string-string-map-len ss6)
                    3
                    "StringString len after remove")
                  (test.assert-i64-eq
                    (string-string-map-deleted ss6)
                    1
                    "StringString tombstone after remove")
                  (test.assert-false
                    (string-string-map-contains-borrowed? ss6 (& beta))
                    "StringString beta absent after remove")
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-string-iter-count
                      ss6
                      (string-string-map-next-occupied ss6 0)
                      0)
                    3
                    "StringString iteration count")
                  (test.assert-i64-eq
                    (stdlib.hashmap.string-string-iter-value-length-sum
                      ss6
                      (string-string-map-next-occupied ss6 0)
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
        [ssu0 : StringStringMap (string-string-map-with-capacity 4)]
        [ssu1 : StringStringMap
          (string-string-map-insert-or-update ssu0 "alpha" "red")]
        [ssu2 : StringStringMap
          (string-string-map-insert-or-update ssu1 "beta" "amber")]
        [ssu-hit : StringStringMapUpdateResult
          (string-string-map-update-borrowed-if-present
            ssu2
            (& alpha-update)
            "green")]
        [ssu3 : StringStringMap
          (stdlib.hashmap.string-string-update-result-map ssu-hit)]
        (begin
          (test.assert-true
            (stdlib.hashmap.string-string-update-ok? ssu-hit)
            "StringString borrowed update hit")
          (hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (string-string-map-get ssu3 "alpha")
              "fallback")
            "green"
            "StringString update overwrites alpha")))
      (let
        [ssu0 : StringStringMap (string-string-map-with-capacity 4)]
        [ssu1 : StringStringMap
          (string-string-map-insert-or-update ssu0 "alpha" "red")]
        [ssu-miss : StringStringMapUpdateResult
          (string-string-map-update-if-present ssu1 "missing" "black")]
        [ssu2 : StringStringMap
          (stdlib.hashmap.string-string-update-result-map ssu-miss)]
        (begin
          (test.assert-false
            (stdlib.hashmap.string-string-update-ok? ssu-miss)
            "StringString update miss")
          (test.assert-i64-eq
            (string-string-map-len ssu2)
            1
            "StringString update miss keeps len")))
      (let
        [ssu0 : StringStringMap (string-string-map-with-capacity 4)]
        [ssu1 : StringStringMap
          (string-string-map-insert-or-update ssu0 "alpha" "green")]
        [ssu2 : StringStringMap
          (string-string-map-insert-or-update ssu1 "beta" "amber")]
        [ssu-removed : StringStringMapRemoveResult
          (string-string-map-remove ssu2 "beta")]
        [ssu3 : StringStringMap
          (stdlib.hashmap.string-string-remove-result-map ssu-removed)]
        [ssu-inserted : StringStringMapEntryOrInsertResult
          (string-string-map-entry-or-insert ssu3 "beta" "gold")]
        [ssu4 : StringStringMap
          (stdlib.hashmap.string-string-entry-or-insert-result-map ssu-inserted)]
        [ssu-found : StringStringMapEntryOrInsertResult
          (string-string-map-entry-or-insert ssu4 "alpha" "purple")]
        [ssu5 : StringStringMap
          (stdlib.hashmap.string-string-entry-or-insert-result-map ssu-found)]
        (begin
          (test.assert-true
            (stdlib.hashmap.string-string-entry-or-insert-inserted?
              ssu-inserted)
            "StringString entry-or-insert inserted")
          (hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-entry-or-insert-value-or
              ssu-inserted
              "fallback")
            "gold"
            "StringString entry-or-insert returns default")
          (test.assert-i64-eq
            (string-string-map-deleted ssu4)
            0
            "StringString entry-or-insert reuses tombstone")
          (test.assert-false
            (stdlib.hashmap.string-string-entry-or-insert-inserted? ssu-found)
            "StringString entry-or-insert found")
          (hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-entry-or-insert-value-or
              ssu-found
              "fallback")
            "green"
            "StringString entry-or-insert returns existing")
          (hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (string-string-map-get ssu5 "alpha")
              "fallback")
            "green"
            "StringString entry-or-insert found does not overwrite")))
      (let
        [ssu0 : StringStringMap (string-string-map-with-capacity 2)]
        [ssu1 : StringStringMap
          (string-string-map-insert-or-update ssu0 "alpha" "green")]
        [ssu2 : StringStringMap
          (string-string-map-insert-or-update ssu1 "beta" "gold")]
        [ssu3 : StringStringMap
          (string-string-map-insert-or-update ssu2 "gamma" "blue")]
        (begin
          (hashmap-test-assert-owned-string-eq
            (stdlib.hashmap.string-string-lookup-value-or
              (string-string-map-get ssu3 "gamma")
              "fallback")
            "blue"
            "StringString insert-or-update inserts new key")
          (test.assert-true
            (> (string-string-map-capacity ssu3) 2)
            "StringString insert-or-update grows")))
      unit)))

(cfg
  test
  (test
    hashmap-i64-i64-family
    (begin
      ;; --- generated i64 -> i64 map family (#817) ---
      (let
        [ii0 : I64I64Map (i64-i64-map-with-capacity 4)]
        [ii1 : I64I64Map (i64-i64-map-put ii0 1 10)]
        [ii2 : I64I64Map (i64-i64-map-put ii1 2 20)]
        [ii3 : I64I64Map (i64-i64-map-put ii2 3 30)]
        [ii4 : I64I64Map (i64-i64-map-put ii3 4 40)]
        [ii5 : I64I64Map (i64-i64-map-put ii4 1 99)]
        (begin
          (test.assert-i64-eq (i64-i64-map-len ii5) 4 "I64I64 len")
          (test.assert-true
            (> (i64-i64-map-capacity ii5) 4)
            "I64I64 grew past seed capacity")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or (i64-i64-map-get ii5 1) -1)
            99
            "I64I64 updated key 1")
          (test.assert-true
            (stdlib.hashmap.i64-i64-borrowed-value-found?
              (i64-i64-map-get-value-borrowed (& ii5) 1))
            "I64I64 borrowed value get finds key 1")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or (i64-i64-map-get ii5 3) -1)
            30
            "I64I64 get key 3")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or (i64-i64-map-get ii5 99) -1)
            -1
            "I64I64 missing key")
          (test.assert-false
            (stdlib.hashmap.i64-i64-borrowed-value-found?
              (i64-i64-map-get-value-borrowed (& ii5) 99))
            "I64I64 missing borrowed value get")
          (test.assert-true
            (i64-i64-map-contains? ii5 2)
            "I64I64 contains key 2")
          (let
            [removed : I64I64MapRemoveResult (i64-i64-map-remove ii5 2)]
            (begin
              (test.assert-true
                (stdlib.hashmap.i64-i64-remove-ok? removed)
                "I64I64 remove key 2")
              (let
                [ii6 : I64I64Map
                  (stdlib.hashmap.i64-i64-remove-result-map removed)]
                (begin
                  (test.assert-i64-eq
                    (i64-i64-map-len ii6)
                    3
                    "I64I64 len after remove")
                  (test.assert-i64-eq
                    (i64-i64-map-deleted ii6)
                    1
                    "I64I64 tombstone after remove")
                  (test.assert-false
                    (i64-i64-map-contains? ii6 2)
                    "I64I64 removed key absent")
                  (test.assert-i64-eq
                    (stdlib.hashmap.i64-i64-iter-count
                      ii6
                      (i64-i64-map-next-occupied ii6 0)
                      0)
                    3
                    "I64I64 iteration count")
                  (test.assert-i64-eq
                    (stdlib.hashmap.i64-i64-iter-value-sum
                      ii6
                      (i64-i64-map-next-occupied ii6 0)
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
        [iiu0 : I64I64Map (i64-i64-map-with-capacity 4)]
        [iiu1 : I64I64Map (i64-i64-map-insert-or-update iiu0 1 10)]
        [iiu2 : I64I64Map (i64-i64-map-insert-or-update iiu1 2 20)]
        [iiu-hit : I64I64MapUpdateResult
          (i64-i64-map-update-if-present iiu2 1 70)]
        [iiu3 : I64I64Map (stdlib.hashmap.i64-i64-update-result-map iiu-hit)]
        (begin
          (test.assert-true
            (stdlib.hashmap.i64-i64-update-ok? iiu-hit)
            "I64I64 update hit")
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or (i64-i64-map-get iiu3 1) -1)
            70
            "I64I64 update overwrites key 1")))
      (let
        [iiu0 : I64I64Map (i64-i64-map-with-capacity 4)]
        [iiu1 : I64I64Map (i64-i64-map-insert-or-update iiu0 1 10)]
        [iiu-miss : I64I64MapUpdateResult
          (i64-i64-map-update-if-present iiu1 99 990)]
        [iiu2 : I64I64Map (stdlib.hashmap.i64-i64-update-result-map iiu-miss)]
        (begin
          (test.assert-false
            (stdlib.hashmap.i64-i64-update-ok? iiu-miss)
            "I64I64 update miss")
          (test.assert-i64-eq
            (i64-i64-map-len iiu2)
            1
            "I64I64 update miss keeps len")))
      (let
        [iiu0 : I64I64Map (i64-i64-map-with-capacity 4)]
        [iiu1 : I64I64Map (i64-i64-map-insert-or-update iiu0 1 70)]
        [iiu2 : I64I64Map (i64-i64-map-insert-or-update iiu1 2 20)]
        [iiu-removed : I64I64MapRemoveResult (i64-i64-map-remove iiu2 2)]
        [iiu5 : I64I64Map
          (stdlib.hashmap.i64-i64-remove-result-map iiu-removed)]
        [iiu-inserted : I64I64MapEntryOrInsertResult
          (i64-i64-map-entry-or-insert iiu5 2 222)]
        [iiu6 : I64I64Map
          (stdlib.hashmap.i64-i64-entry-or-insert-result-map iiu-inserted)]
        [iiu-found : I64I64MapEntryOrInsertResult
          (i64-i64-map-entry-or-insert iiu6 1 111)]
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
            (i64-i64-map-deleted iiu6)
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
            (stdlib.hashmap.i64-i64-lookup-value-or (i64-i64-map-get iiu7 1) -1)
            70
            "I64I64 entry-or-insert found does not overwrite")))
      (let
        [iiu0 : I64I64Map (i64-i64-map-with-capacity 2)]
        [iiu1 : I64I64Map (i64-i64-map-insert-or-update iiu0 1 70)]
        [iiu2 : I64I64Map (i64-i64-map-insert-or-update iiu1 2 222)]
        [iiu8 : I64I64Map (i64-i64-map-insert-or-update iiu2 3 30)]
        (begin
          (test.assert-i64-eq
            (stdlib.hashmap.i64-i64-lookup-value-or (i64-i64-map-get iiu8 3) -1)
            30
            "I64I64 insert-or-update inserts key 3")
          (test.assert-true
            (> (i64-i64-map-capacity iiu8) 2)
            "I64I64 insert-or-update grows")))
      unit)))

(export
  (value hashmap-string-key-descriptor-key)
  (value hashmap-i64-key-descriptor-key)
  (value hashmap-aggregate-key-descriptor-key)
  (value string-i64-map-power-two-capacity?)
  (value string-i64-map-round-capacity)
  (value string-i64-map-normalized-bucket-index)
  (value string-i64-map-bucket-index)
  (value string-i64-map-next-index)
  (value string-i64-map-slot-at)
  (value string-i64-map-insert-slot)
  (value string-i64-map-probe-from)
  (value string-i64-map-probe)
  (value string-i64-map-probe-borrowed-from)
  (value string-i64-map-probe-borrowed)
  (value string-i64-map-probe-normalized)
  (value string-i64-map-slots)
  (value string-i64-map-len)
  (value string-i64-map-capacity)
  (value string-i64-map-deleted)
  (value string-i64-map-fill-empty)
  (value string-i64-map-with-capacity)
  (value string-i64-map-borrowed-value-missing)
  (value string-i64-map-borrowed-value-found)
  (value string-i64-map-get-borrowed)
  (value string-i64-map-get)
  (value string-i64-map-get-value-borrowed)
  (value string-i64-map-contains-borrowed?)
  (value string-i64-map-contains?)
  (value string-i64-map-slot-tombstone?)
  (value string-i64-map-insert)
  (value string-i64-map-remove-borrowed)
  (value string-i64-map-remove)
  (value string-i64-map-update-borrowed-if-present)
  (value string-i64-map-update-if-present)
  (value string-i64-map-insert-into-empty)
  (value string-i64-map-rehash-from)
  (value string-i64-map-resized)
  (value string-i64-map-grow-capacity)
  (value string-i64-map-grow)
  (value string-i64-map-needs-grow?)
  (value string-i64-map-put)
  (value string-i64-map-insert-or-update)
  (value string-i64-map-entry-or-insert)
  (value string-i64-map-mut-entry-info)
  (value string-i64-map-mut-entry-from-info)
  (value string-i64-map-mut-entry-present?)
  (value string-i64-map-mut-entry-value-or)
  (value string-i64-map-mut-entry-set!)
  (value string-i64-map-next-occupied-from)
  (value string-i64-map-next-occupied)
  (value string-i64-map-entry-at)
  (value string-string-map-with-capacity)
  (value string-string-map-len)
  (value string-string-map-capacity)
  (value string-string-map-put)
  (value string-string-map-get-value-borrowed)
  (value string-string-map-insert)
  (value string-string-map-remove-borrowed)
  (value string-string-map-resized)
  (type StringI64MapSlot)
  (type StringI64MapProbe)
  (type StringI64Map)
  (type StringI64MapLookup)
  (type StringI64MapBorrowedValueLookup)
  (type StringI64MapInsertResult)
  (type StringI64MapRemoveResult)
  (type StringI64MapUpdateResult)
  (type StringI64MapEntryOrInsertResult)
  (type StringI64MapMutEntryInfo)
  (type StringI64MapMutEntry)
  (type StringI64MapEntry)
  (type StringStringMap)
  (type StringStringMapLookup)
  (type StringStringMapBorrowedValueLookup)
  (type StringStringMapInsertResult)
  (type StringStringMapRemoveResult)
  (type StringStringMapUpdateResult)
  (type StringStringMapEntryOrInsertResult)
  (type StringStringMapEntry)
  (type I64I64Map)
  (constructor StringI64Map)
  (constructor StringI64MapMutEntryInfo)
  (constructor StringI64MapMutEntry)
  (constructor StringStringMap)
  (constructor I64I64Map)
  (field StringI64Map slots)
  (field StringI64Map len)
  (field StringI64Map deleted)
  (field StringI64MapMutEntryInfo index)
  (field StringI64MapMutEntryInfo present)
  (field StringI64MapMutEntryInfo key)
  (field StringI64MapMutEntryInfo hash)
  (field StringI64MapMutEntry slots)
  (field StringI64MapMutEntry borrow)
  (field StringI64MapMutEntry index)
  (field StringI64MapMutEntry present)
  (field StringI64MapMutEntry key)
  (field StringI64MapMutEntry hash)
  (variant StringI64MapEmpty)
  (variant StringI64MapTombstone)
  (variant StringI64MapOccupied)
  (variant StringI64MapProbeFound)
  (variant StringI64MapProbeAbsent)
  (variant StringI64MapProbeFull)
  (variant StringI64MapMissing)
  (variant StringI64MapFound)
  (variant StringI64MapBorrowedValueMissing)
  (variant StringI64MapBorrowedValueFound)
  (variant StringI64MapInsertOk)
  (variant StringI64MapInsertFull)
  (variant StringI64MapRemoveOk)
  (variant StringI64MapRemoveMissing)
  (variant StringI64MapUpdateOk)
  (variant StringI64MapUpdateMissing)
  (variant StringI64MapEntryOrInsertFound)
  (variant StringI64MapEntryOrInsertInserted)
  (variant StringI64MapEntryNone)
  (variant StringI64MapEntrySome)
  (variant StringStringMapMissing)
  (variant StringStringMapFound)
  (variant StringStringMapBorrowedValueMissing)
  (variant StringStringMapBorrowedValueFound)
  (variant StringStringMapInsertOk)
  (variant StringStringMapInsertFull)
  (variant StringStringMapRemoveOk)
  (variant StringStringMapRemoveMissing)
  (variant StringStringMapUpdateOk)
  (variant StringStringMapUpdateMissing)
  (variant StringStringMapEntryOrInsertFound)
  (variant StringStringMapEntryOrInsertInserted)
  (variant StringStringMapEntryNone)
  (variant StringStringMapEntrySome)
  (macro string-i64-map-get-mut-entry-borrowed))