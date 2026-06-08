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
;# Usage: `(import "stdlib/hashmap.tl")`
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
;# Unsupported key types are intentionally rejected by the generator request
;# path instead of falling back to a trait or implicit `Hash`/`Eq` bound.
;#
;# ```typelisp
;# (import "stdlib/hashmap.tl")
;# (define (main) : i64
;#   (match (string-i64-map-probe (make-array StringI64MapSlot 4) 4 "k" 0)
;#     [(StringI64MapProbeAbsent slot) slot]
;#     [(StringI64MapProbeFound slot) slot]
;#     [(StringI64MapProbeFull) -1]))
;# ```
(import "hash.tl")

(import "string.tl")

;: Stable descriptor identity for generated `String`-key hashmap families.
(define (hashmap-string-key-descriptor-key) : String
  "stdlib/hashmap/string-key-v1")

;: Stable descriptor identity for generated `i64`-key hashmap families.
(define (hashmap-i64-key-descriptor-key) : String
  "stdlib/hashmap/i64-key-v1")

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
  (string-i64-map-normalized-bucket-index (hash-normalize hash) capacity))

;: Advance a bucket index by one slot, wrapping around the table.
(define (string-i64-map-next-index [index : i64] [capacity : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next capacity)
      0
      next)))

;: Unchecked slot read. Probe/iteration indices are always in [0, capacity)
;: (masked bucket index, wrapped with next-index), so the array-ref bounds check
;: is dead weight; this body inlines to gep+load+return at opt2.
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
        (match (string-i64-map-slot-at slots cursor)
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
              (hash-key-string-eq? (& slot-key) (& key))
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
  (string-i64-map-probe-borrowed slots capacity (& key) hash))

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
        (match (string-i64-map-slot-at slots cursor)
          [(StringI64MapEmpty)
            (return
              (StringI64MapProbeAbsent
                (string-i64-map-insert-slot first cursor)))]
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
              (hash-key-string-eq? (& slot-key) key)
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
    (string-i64-map-probe-borrowed-from
      slots
      capacity
      key
      hash
      (string-i64-map-bucket-index hash capacity)
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
    (string-i64-map-probe-from
      slots
      capacity
      key
      hash
      (string-i64-map-normalized-bucket-index hash capacity)
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
      (string-i64-map-fill-empty slots (+ index 1) count))))

;: Create an empty map with `capacity` rounded up to a positive power of two.
(define (string-i64-map-with-capacity [capacity : i64]) : StringI64Map
  (let
    [rounded-capacity : i64 (string-i64-map-round-capacity capacity)]
    [slots : (Array StringI64MapSlot)
      (make-array StringI64MapSlot rounded-capacity)]
    (begin
      (string-i64-map-fill-empty slots 0 rounded-capacity)
      (StringI64Map slots 0 0))))

(define (string-i64-map-borrowed-value-missing [map : (& map StringI64Map)]) : (StringI64MapBorrowedValueLookup
  map)
  (StringI64MapBorrowedValueMissing))

(define (string-i64-map-borrowed-value-found [value : (& map i64)]) : (StringI64MapBorrowedValueLookup
  map)
  (StringI64MapBorrowedValueFound value))

;: Look up borrowed `key`, returning its copied `i64` value or `Missing`.
(define (string-i64-map-get-borrowed [map : StringI64Map] [key : (& key str)]) : StringI64MapLookup
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [capacity : i64 (array-length slots)]
    (if (<= capacity 0)
      (StringI64MapMissing)
      (let
        [hash : i64 (hash-string key)]
        [cursor : i64 (string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (string-i64-map-slot-at slots cursor)
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
                  (hash-key-string-eq? (& slot-key) key)
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
  (string-i64-map-get-borrowed map (& key)))

;: Look up borrowed `key`, returning a reference to the map-owned `i64` value
;: or `Missing`. The reference is invalidated by any map mutation/resizing.
(define (string-i64-map-get-value-borrowed
  [map : (& map StringI64Map)]
  [key : (& key str)]) : (StringI64MapBorrowedValueLookup map)
  (let
    [capacity : i64 (array-length (struct-get map slots))]
    (if (<= capacity 0)
      (string-i64-map-borrowed-value-missing map)
      (let
        [hash : i64 (hash-string key)]
        [cursor : i64 (string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (array-ref (struct-get map slots) cursor)
              [(StringI64MapEmpty)
                (return (string-i64-map-borrowed-value-missing map))]
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
                  (hash-key-string-eq? (& slot-key) key)
                  false)
                  (match (& (array-ref (struct-get map slots) cursor))
                    [(StringI64MapOccupied _ value _)
                      (return (string-i64-map-borrowed-value-found value))]
                    [(StringI64MapEmpty)
                      (return (string-i64-map-borrowed-value-missing map))]
                    [(StringI64MapTombstone)
                      (return (string-i64-map-borrowed-value-missing map))])
                  (let
                    [next : i64 (+ cursor 1)]
                    (begin
                      (set!
                        cursor
                        (if (>= next capacity)
                          0
                          next))
                      (set! walked (+ walked 1)))))]))
          (string-i64-map-borrowed-value-missing map))))))

;: True when borrowed `key` has a live value in `map`.
(define (string-i64-map-contains-borrowed?
  [map : StringI64Map]
  [key : (& key str)]) : bool
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [capacity : i64 (array-length slots)]
    (if (<= capacity 0)
      false
      (let
        [hash : i64 (hash-string key)]
        [cursor : i64 (string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (string-i64-map-slot-at slots cursor)
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
                  (hash-key-string-eq? (& slot-key) key)
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
  (string-i64-map-contains-borrowed? map (& key)))

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
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [capacity : i64 (array-length slots)]
    [hash : i64 (hash-string (& key))]
    (if (<= capacity 0)
      (StringI64MapInsertFull map)
      (let
        [cursor : i64 (string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        [first : i64 -1]
        (begin
          (while (< walked capacity)
            (match (string-i64-map-slot-at slots cursor)
              [(StringI64MapEmpty)
                (let
                  [index : i64
                    (if (>= first 0)
                      first
                      cursor)]
                  [reused-tombstone : bool (>= first 0)]
                  [deleted : i64 (string-i64-map-deleted map)]
                  (begin
                    (array-set!
                      slots
                      index
                      (StringI64MapOccupied key value hash))
                    (return
                      (StringI64MapInsertOk
                        (StringI64Map
                          slots
                          (+ (string-i64-map-len map) 1)
                          (if reused-tombstone
                            (- deleted 1)
                            deleted))))))]
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
                  (hash-key-string-eq? (& slot-key) (& key))
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
              [deleted : i64 (string-i64-map-deleted map)]
              (begin
                (array-set! slots first (StringI64MapOccupied key value hash))
                (StringI64MapInsertOk
                  (StringI64Map
                    slots
                    (+ (string-i64-map-len map) 1)
                    (- deleted 1)))))
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
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [capacity : i64 (array-length slots)]
    (if (<= capacity 0)
      (StringI64MapRemoveMissing map)
      (let
        [hash : i64 (hash-string key)]
        [cursor : i64 (string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (string-i64-map-slot-at slots cursor)
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
                  (hash-key-string-eq? (& slot-key) key)
                  false)
                  (begin
                    (array-set! slots cursor (StringI64MapTombstone))
                    (return
                      (StringI64MapRemoveOk
                        (StringI64Map
                          slots
                          (- (string-i64-map-len map) 1)
                          (+ (string-i64-map-deleted map) 1)))))
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
  (string-i64-map-remove-borrowed map (& key)))

;: Update borrowed `key` only when it is already present. This preserves the
;: stored key object and hash, mutating only the occupied slot value.
(define (string-i64-map-update-borrowed-if-present
  [map : StringI64Map]
  [key : (& key str)]
  [value : i64]) : StringI64MapUpdateResult
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [hash : i64 (hash-string key)]
    (match (string-i64-map-probe-borrowed
      slots
      (string-i64-map-capacity map)
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
  (string-i64-map-update-borrowed-if-present map (& key) value))

;: Insert into a fresh destination table during rehash. Source entries are
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
      [cursor : i64 (string-i64-map-normalized-bucket-index hash capacity)]
      [walked : i64 0]
      [done : bool false]
      (begin
        (while (if done
          false
          (< walked capacity))
          (match (string-i64-map-slot-at slots cursor)
            [(StringI64MapEmpty)
              (begin
                (array-set! slots cursor (StringI64MapOccupied key value hash))
                (set! done true))]
            [_
              (begin
                (set! cursor (string-i64-map-next-index cursor capacity))
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
      (match (string-i64-map-slot-at src index)
        [(StringI64MapOccupied key value hash)
          (string-i64-map-insert-into-empty dst dst-capacity key value hash)]
        [(StringI64MapEmpty) unit]
        [(StringI64MapTombstone) unit])
      (string-i64-map-rehash-from src dst dst-capacity (+ index 1) count))))

;: Rebuild `map` as a fresh power-of-two table holding only its live entries
;: (tombstones dropped, so the deleted count resets to 0). The backing array is
;: newly allocated; the old one is reclaimed when the arena resets.
(define (string-i64-map-resized [map : StringI64Map] [new-capacity : i64]) : StringI64Map
  (let
    [src : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [old-capacity : i64 (array-length src)]
    [requested-capacity : i64
      (if (> (string-i64-map-len map) new-capacity)
        (string-i64-map-len map)
        new-capacity)]
    [rounded-capacity : i64 (string-i64-map-round-capacity requested-capacity)]
    [dst : (Array StringI64MapSlot)
      (make-array StringI64MapSlot rounded-capacity)]
    (begin
      (string-i64-map-fill-empty dst 0 rounded-capacity)
      (string-i64-map-rehash-from src dst rounded-capacity 0 old-capacity)
      (StringI64Map dst (string-i64-map-len map) 0))))

;: Next capacity when growing: double, with a small floor so a tiny or empty
;: table grows to a useful size in one step.
(define (string-i64-map-grow-capacity [capacity : i64]) : i64
  (if (< capacity 4)
    8
    (* (string-i64-map-round-capacity capacity) 2)))

;: Grow `map` to the next capacity, rehashing its live entries.
(define (string-i64-map-grow [map : StringI64Map]) : StringI64Map
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    (string-i64-map-resized
      map
      (string-i64-map-grow-capacity (array-length slots)))))

;: True when the table has reached the 3/4 load threshold, counting both live
;: entries and tombstones (both consume probe positions). A non-positive
;: capacity always needs to grow before it can hold anything.
(define (string-i64-map-needs-grow? [map : StringI64Map]) : bool
  (let
    [capacity : i64 (array-length (string-i64-map-slots map))]
    [used : i64 (+ (string-i64-map-len map) (string-i64-map-deleted map))]
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
      (if (string-i64-map-needs-grow? map)
        (string-i64-map-grow map)
        map)]
    (match (string-i64-map-insert grown key value)
      [(StringI64MapInsertOk updated) updated]
      [(StringI64MapInsertFull full)
        ;; `needs-grow?` keeps a positive-capacity table below full; a leftover
        ;; `Full` (e.g. a capacity-0 seed) is handled by one more grow + retry.
        (match (string-i64-map-insert (string-i64-map-grow full) key value)
          [(StringI64MapInsertOk u) u]
          [(StringI64MapInsertFull u) u])])))

;: Insert `key -> value`, or update the existing key to `value`.
(define (string-i64-map-insert-or-update
  [map : StringI64Map]
  [key : String]
  [value : i64]) : StringI64Map
  (string-i64-map-put map key value))

;: Return the existing value for `key`, or insert `default-value` and return it.
;: This does not expose a live bucket handle; callers thread the returned map.
(define (string-i64-map-entry-or-insert
  [map : StringI64Map]
  [key : String]
  [default-value : i64]) : StringI64MapEntryOrInsertResult
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [hash : i64 (hash-string (& key))]
    (match (string-i64-map-probe-borrowed
      slots
      (string-i64-map-capacity map)
      (& key)
      hash)
      [(StringI64MapProbeFound index)
        (match (array-ref slots index)
          [(StringI64MapOccupied _ value _)
            (StringI64MapEntryOrInsertFound map value)]
          [(StringI64MapEmpty)
            (let
              [updated : StringI64Map
                (string-i64-map-put map key default-value)]
              (StringI64MapEntryOrInsertInserted updated default-value))]
          [(StringI64MapTombstone)
            (let
              [updated : StringI64Map
                (string-i64-map-put map key default-value)]
              (StringI64MapEntryOrInsertInserted updated default-value))])]
      [(StringI64MapProbeAbsent _)
        (let
          [updated : StringI64Map (string-i64-map-put map key default-value)]
          (StringI64MapEntryOrInsertInserted updated default-value))]
      [(StringI64MapProbeFull)
        (let
          [updated : StringI64Map (string-i64-map-put map key default-value)]
          (StringI64MapEntryOrInsertInserted updated default-value))])))

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
    (match (string-i64-map-slot-at slots index)
      [(StringI64MapOccupied _ _ _) index]
      [(StringI64MapEmpty)
        (string-i64-map-next-occupied-from slots (+ index 1) capacity)]
      [(StringI64MapTombstone)
        (string-i64-map-next-occupied-from slots (+ index 1) capacity)])))

;: Iteration cursor: the index of the first occupied slot at or after `from`
;: (in ascending bucket order), or the capacity when no live entry remains.
;: A negative `from` is clamped to 0.
;:
;: v1 iterates in *bucket order* — ascending slot index, skipping empty and
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
;: (import "stdlib/hashmap.tl")
;: (define (sum-values [m : StringI64Map] [i : i64] [acc : i64]) : i64
;:   (if (>= i (string-i64-map-capacity m))
;:     acc
;:     (sum-values
;:       m
;:       (string-i64-map-next-occupied m (+ i 1))
;:       (match (string-i64-map-entry-at m i)
;:         [(StringI64MapEntrySome _ v) (+ acc v)]
;:         [(StringI64MapEntryNone) acc]))))
;: (define (main) : i64
;:   (let
;:     [m : StringI64Map (string-i64-map-put (string-i64-map-with-capacity 8) "k" 42)]
;:     (sum-values m (string-i64-map-next-occupied m 0) 0)))
;: ```
(define (string-i64-map-next-occupied [map : StringI64Map] [from : i64]) : i64
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    (string-i64-map-next-occupied-from
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
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    (if (if (< index 0)
      true
      (>= index (array-length slots)))
      (StringI64MapEntryNone)
      (match (string-i64-map-slot-at slots index)
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