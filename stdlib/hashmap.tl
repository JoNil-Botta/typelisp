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
;# Unsupported key types are intentionally rejected by the generator request
;# path instead of falling back to a trait or implicit `Hash`/`Eq` bound.
;#
;# ```typelisp
;# (import stdlib.hashmap)
;# (define (main) : i64
;#   (match (hashmap.string-i64-map-probe (make-array hashmap.StringI64MapSlot 4) 4 "k" 0)
;#     [(hashmap.StringI64MapProbeAbsent slot) slot]
;#     [(hashmap.StringI64MapProbeFound slot) slot]
;#     [(hashmap.StringI64MapProbeFull) -1]))
;# ```
(module stdlib.hashmap)

(import stdlib.hash as hash_mod)

(import stdlib.string as string_mod)

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
        stdlib.hashmap.StringI64MapProbeFull))))

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
        stdlib.hashmap.StringI64MapProbeFull))))

;: Probe `slots` for a borrowed string key with a precomputed `hash`.
(define (string-i64-map-probe-borrowed
  [slots : (Array StringI64MapSlot)]
  [capacity : i64]
  [key : (& key str)]
  [hash : i64]) : StringI64MapProbe
  (if (<= capacity 0)
    stdlib.hashmap.StringI64MapProbeFull
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
    stdlib.hashmap.StringI64MapProbeFull
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
      (array-set! slots index stdlib.hashmap.StringI64MapEmpty)
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
(define (string-i64-map-borrowed-value-missing [map : (& map StringI64Map)]) : (StringI64MapBorrowedValueLookup
    map)
  stdlib.hashmap.StringI64MapBorrowedValueMissing)

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
      stdlib.hashmap.StringI64MapMissing
      (let
        [hash : i64 (hash_mod.hash-string key)]
        [cursor : i64
          (stdlib.hashmap.string-i64-map-normalized-bucket-index hash capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (match (stdlib.hashmap.string-i64-map-slot-at slots cursor)
              [(StringI64MapEmpty) (return stdlib.hashmap.StringI64MapMissing)]
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
          stdlib.hashmap.StringI64MapMissing)))))

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
                    (return
                      (StringI64MapInsertOk
                        (StringI64Map
                          slots
                          (+ (stdlib.hashmap.string-i64-map-len map) 1)
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
                (StringI64MapInsertOk
                  (StringI64Map
                    slots
                    (+ (stdlib.hashmap.string-i64-map-len map) 1)
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
                    (array-set!
                      slots
                      cursor
                      stdlib.hashmap.StringI64MapTombstone)
                    (return
                      (StringI64MapRemoveOk
                        (StringI64Map
                          slots
                          (- (stdlib.hashmap.string-i64-map-len map) 1)
                          (+ (stdlib.hashmap.string-i64-map-deleted map) 1)))))
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
      (StringI64Map dst (stdlib.hashmap.string-i64-map-len map) 0))))

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
  [slots : (Array StringI64MapSlot)]
  [borrow : (&mut map (Array StringI64MapSlot))]
  [info : StringI64MapMutEntryInfo]) : (StringI64MapMutEntry map)
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
  `(stdlib.hashmap.string-i64-map-mut-entry-from-info
    (struct-get ,map slots)
    (&mut (struct-get ,map slots))
    (stdlib.hashmap.string-i64-map-mut-entry-info
      (struct-get ,map slots)
      (array-length (struct-get ,map slots))
      ,key)))

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
;: v1 iterates in *bucket order* â€” ascending slot index, skipping empty and
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
;: (define (sum-values [m : hashmap.StringI64Map] [i : i64] [acc : i64]) : i64
;:   (if (>= i (hashmap.string-i64-map-capacity m))
;:     acc
;:     (sum-values
;:       m
;:       (hashmap.string-i64-map-next-occupied m (+ i 1))
;:       (match (hashmap.string-i64-map-entry-at m i)
;:         [(hashmap.StringI64MapEntrySome _ v) (+ acc v)]
;:         [(hashmap.StringI64MapEntryNone) acc]))))
;: (define (main) : i64
;:   (let
;:     [m : hashmap.StringI64Map (hashmap.string-i64-map-put (hashmap.string-i64-map-with-capacity 8) "k" 42)]
;:     (sum-values m (hashmap.string-i64-map-next-occupied m 0) 0)))
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
      stdlib.hashmap.StringI64MapEntryNone
      (match (stdlib.hashmap.string-i64-map-slot-at slots index)
        [(StringI64MapOccupied key value _) (StringI64MapEntrySome key value)]
        [(StringI64MapEmpty) stdlib.hashmap.StringI64MapEntryNone]
        [(StringI64MapTombstone) stdlib.hashmap.StringI64MapEntryNone]))))

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

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value hashmap-string-key-descriptor-key)
  (value hashmap-i64-key-descriptor-key)
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
  (value string-string-map-hash-normalize)
  (value string-string-map-hash-key)
  (value string-string-map-power-two-capacity?)
  (value string-string-map-round-capacity)
  (value string-string-map-normalized-bucket-index)
  (value string-string-map-bucket-index)
  (value string-string-map-next-index)
  (value string-string-map-insert-slot)
  (value string-string-map-key-eq?)
  (value string-string-map-probe-borrowed-from)
  (value string-string-map-probe-borrowed)
  (value string-string-map-probe)
  (value string-string-map-slots)
  (value string-string-map-len)
  (value string-string-map-capacity)
  (value string-string-map-deleted)
  (value string-string-map-fill-empty)
  (value string-string-map-with-capacity)
  (value string-string-map-borrowed-value-missing)
  (value string-string-map-borrowed-value-found)
  (value string-string-map-get-borrowed)
  (value string-string-map-get)
  (value string-string-map-get-value-borrowed)
  (value string-string-map-contains-borrowed?)
  (value string-string-map-contains?)
  (value string-string-map-slot-tombstone?)
  (value string-string-map-insert)
  (value string-string-map-remove-borrowed)
  (value string-string-map-remove)
  (value string-string-map-update-borrowed-if-present)
  (value string-string-map-update-if-present)
  (value string-string-map-insert-into-empty)
  (value string-string-map-rehash-from)
  (value string-string-map-resized)
  (value string-string-map-grow-capacity)
  (value string-string-map-grow)
  (value string-string-map-needs-grow?)
  (value string-string-map-put)
  (value string-string-map-insert-or-update)
  (value string-string-map-entry-or-insert)
  (value string-string-map-mut-entry-info)
  (value string-string-map-mut-entry-from-info)
  (value string-string-map-mut-entry-present?)
  (value string-string-map-mut-entry-value-or)
  (value string-string-map-mut-entry-set!)
  (value string-string-map-next-occupied-from)
  (value string-string-map-next-occupied)
  (value string-string-map-entry-at)
  (value i64-i64-map-hash-normalize)
  (value i64-i64-map-hash-key)
  (value i64-i64-map-power-two-capacity?)
  (value i64-i64-map-round-capacity)
  (value i64-i64-map-normalized-bucket-index)
  (value i64-i64-map-bucket-index)
  (value i64-i64-map-next-index)
  (value i64-i64-map-insert-slot)
  (value i64-i64-map-probe-from)
  (value i64-i64-map-probe)
  (value i64-i64-map-slots)
  (value i64-i64-map-len)
  (value i64-i64-map-capacity)
  (value i64-i64-map-deleted)
  (value i64-i64-map-fill-empty)
  (value i64-i64-map-with-capacity)
  (value i64-i64-map-borrowed-value-missing)
  (value i64-i64-map-borrowed-value-found)
  (value i64-i64-map-get)
  (value i64-i64-map-get-value-borrowed)
  (value i64-i64-map-contains?)
  (value i64-i64-map-slot-tombstone?)
  (value i64-i64-map-insert)
  (value i64-i64-map-remove)
  (value i64-i64-map-update-if-present)
  (value i64-i64-map-insert-into-empty)
  (value i64-i64-map-rehash-from)
  (value i64-i64-map-resized)
  (value i64-i64-map-grow-capacity)
  (value i64-i64-map-grow)
  (value i64-i64-map-needs-grow?)
  (value i64-i64-map-put)
  (value i64-i64-map-insert-or-update)
  (value i64-i64-map-entry-or-insert)
  (value i64-i64-map-mut-entry-info)
  (value i64-i64-map-mut-entry-from-info)
  (value i64-i64-map-mut-entry-present?)
  (value i64-i64-map-mut-entry-value-or)
  (value i64-i64-map-mut-entry-set!)
  (value i64-i64-map-next-occupied-from)
  (value i64-i64-map-next-occupied)
  (value i64-i64-map-entry-at)
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
  (type StringStringMapSlot)
  (type StringStringMapProbe)
  (type StringStringMap)
  (type StringStringMapLookup)
  (type StringStringMapBorrowedValueLookup)
  (type StringStringMapInsertResult)
  (type StringStringMapRemoveResult)
  (type StringStringMapUpdateResult)
  (type StringStringMapEntryOrInsertResult)
  (type StringStringMapMutEntryInfo)
  (type StringStringMapMutEntry)
  (type StringStringMapEntry)
  (type I64I64MapSlot)
  (type I64I64MapProbe)
  (type I64I64Map)
  (type I64I64MapLookup)
  (type I64I64MapBorrowedValueLookup)
  (type I64I64MapInsertResult)
  (type I64I64MapRemoveResult)
  (type I64I64MapUpdateResult)
  (type I64I64MapEntryOrInsertResult)
  (type I64I64MapMutEntryInfo)
  (type I64I64MapMutEntry)
  (type I64I64MapEntry)
  (constructor StringI64Map)
  (constructor StringI64MapMutEntryInfo)
  (constructor StringI64MapMutEntry)
  (constructor StringStringMap)
  (constructor StringStringMapMutEntryInfo)
  (constructor StringStringMapMutEntry)
  (constructor I64I64Map)
  (constructor I64I64MapMutEntryInfo)
  (constructor I64I64MapMutEntry)
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
  (field StringStringMap slots)
  (field StringStringMap len)
  (field StringStringMap deleted)
  (field StringStringMapMutEntryInfo index)
  (field StringStringMapMutEntryInfo present)
  (field StringStringMapMutEntryInfo key)
  (field StringStringMapMutEntryInfo hash)
  (field StringStringMapMutEntry slots)
  (field StringStringMapMutEntry borrow)
  (field StringStringMapMutEntry index)
  (field StringStringMapMutEntry present)
  (field StringStringMapMutEntry key)
  (field StringStringMapMutEntry hash)
  (field I64I64Map slots)
  (field I64I64Map len)
  (field I64I64Map deleted)
  (field I64I64MapMutEntryInfo index)
  (field I64I64MapMutEntryInfo present)
  (field I64I64MapMutEntryInfo key)
  (field I64I64MapMutEntryInfo hash)
  (field I64I64MapMutEntry slots)
  (field I64I64MapMutEntry borrow)
  (field I64I64MapMutEntry index)
  (field I64I64MapMutEntry present)
  (field I64I64MapMutEntry key)
  (field I64I64MapMutEntry hash)
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
  (variant StringStringMapEmpty)
  (variant StringStringMapTombstone)
  (variant StringStringMapOccupied)
  (variant StringStringMapProbeFound)
  (variant StringStringMapProbeAbsent)
  (variant StringStringMapProbeFull)
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
  (variant I64I64MapEmpty)
  (variant I64I64MapTombstone)
  (variant I64I64MapOccupied)
  (variant I64I64MapProbeFound)
  (variant I64I64MapProbeAbsent)
  (variant I64I64MapProbeFull)
  (variant I64I64MapMissing)
  (variant I64I64MapFound)
  (variant I64I64MapBorrowedValueMissing)
  (variant I64I64MapBorrowedValueFound)
  (variant I64I64MapInsertOk)
  (variant I64I64MapInsertFull)
  (variant I64I64MapRemoveOk)
  (variant I64I64MapRemoveMissing)
  (variant I64I64MapUpdateOk)
  (variant I64I64MapUpdateMissing)
  (variant I64I64MapEntryOrInsertFound)
  (variant I64I64MapEntryOrInsertInserted)
  (variant I64I64MapEntryNone)
  (variant I64I64MapEntrySome)
  (macro string-i64-map-get-mut-entry-borrowed)
  (macro string-string-map-get-mut-entry-borrowed)
  (macro i64-i64-map-get-mut-entry))