;# Generated concrete hashmap family (collections v1, #817/#825).
;#
;# Open-addressed, linear-probing maps generated as checked-in concrete
;# declarations. `StringI64Map` remains the compatibility `HashMap<String,i64>`
;# template chosen in #824/#825; this module also provides generated
;# `StringStringMap` and `I64I64Map` families using the same representation and
;# API shape. String-key maps use the same string hash and equality rules as
;# `hash-string`; i64-key maps normalize the scalar key directly and compare with
;# `=`.
;#
;# Capacity may be any positive `i64`: the start bucket is the normalized hash
;# modulo capacity, and probing wraps with modulo arithmetic (no power-of-two
;# requirement). Each occupied slot caches its key hash so probing compares the
;# cheap `i64` hash before the full key comparison. The probe visits at most
;# `capacity` slots, so a full table terminates instead of looping forever.
;#
;# Usage: `(import "stdlib/hashmap.tl")`
;#
;# Generic source syntax such as `HashMap<K,V>` is intentionally not exposed
;# yet; TypeLisp still uses `comptime-decl` and generated concrete declarations
;# instead of source-level generics or traits. These maps are the stdlib choice
;# for ordinary program data keyed by `String` or `i64`; compiler-internal symbol
;# tables may keep using specialized maps when their value domain or lifecycle is
;# tighter than a public stdlib collection.
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

;: Return the start bucket for `hash` in a table of `capacity` slots.
;: `capacity` must be positive; the result is in `[0, capacity)`.
(define (string-i64-map-bucket-index [hash : i64] [capacity : i64]) : i64
  (% (hash-normalize hash) capacity))

;: Return the start bucket when `hash` is already in the public hash range.
(define (string-i64-map-normalized-bucket-index
  [hash : i64]
  [capacity : i64]) : i64
  (% hash capacity))

;: Advance a bucket index by one slot, wrapping around the table.
(define (string-i64-map-next-index [index : i64] [capacity : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next capacity)
      0
      next)))

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
        (match (array-ref slots cursor)
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
  (if (>= steps capacity)
    (if (>= first-tombstone 0)
      (StringI64MapProbeAbsent first-tombstone)
      (StringI64MapProbeFull))
    (match (array-ref slots index)
      [(StringI64MapEmpty)
        (StringI64MapProbeAbsent
          (string-i64-map-insert-slot first-tombstone index))]
      [(StringI64MapTombstone)
        (string-i64-map-probe-borrowed-from
          slots
          capacity
          key
          hash
          (string-i64-map-next-index index capacity)
          (+ steps 1)
          (if (>= first-tombstone 0)
            first-tombstone
            index))]
      [(StringI64MapOccupied slot-key _ slot-hash)
        (if (if (= slot-hash hash)
          (hash-key-string-eq? (& slot-key) key)
          false)
          (StringI64MapProbeFound index)
          (string-i64-map-probe-borrowed-from
            slots
            capacity
            key
            hash
            (string-i64-map-next-index index capacity)
            (+ steps 1)
            first-tombstone))])))

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

;: Create an empty map with `capacity` slots. `capacity` should be positive;
;: a non-positive capacity yields a zero-slot map whose inserts return `Full`.
(define (string-i64-map-with-capacity [capacity : i64]) : StringI64Map
  (let
    [slots : (Array StringI64MapSlot) (make-array StringI64MapSlot capacity)]
    (begin
      (string-i64-map-fill-empty slots 0 capacity)
      (StringI64Map slots 0 0))))

;: Look up borrowed `key`, returning its copied `i64` value or `Missing`.
(define (string-i64-map-get-borrowed [map : StringI64Map] [key : (& key str)]) : StringI64MapLookup
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [capacity : i64 (array-length slots)]
    (match (string-i64-map-probe-borrowed
      slots
      capacity
      key
      (hash-string key))
      [(StringI64MapProbeFound index)
        (match (array-ref slots index)
          [(StringI64MapOccupied _ value _) (StringI64MapFound value)]
          [(StringI64MapEmpty) (StringI64MapMissing)]
          [(StringI64MapTombstone) (StringI64MapMissing)])]
      [(StringI64MapProbeAbsent _) (StringI64MapMissing)]
      [(StringI64MapProbeFull) (StringI64MapMissing)])))

;: Compatibility owned-key lookup wrapper for existing callers.
(define (string-i64-map-get [map : StringI64Map] [key : String]) : StringI64MapLookup
  (string-i64-map-get-borrowed map (& key)))

;: True when borrowed `key` has a live value in `map`.
(define (string-i64-map-contains-borrowed?
  [map : StringI64Map]
  [key : (& key str)]) : bool
  (match (string-i64-map-get-borrowed map key)
    [(StringI64MapFound _) true]
    [(StringI64MapMissing) false]))

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
    (match (string-i64-map-probe-normalized slots capacity key hash)
      [(StringI64MapProbeFound index)
        (begin
          (array-set! slots index (StringI64MapOccupied key value hash))
          (StringI64MapInsertOk map))]
      [(StringI64MapProbeAbsent index)
        (let
          [reused-tombstone : bool
            (string-i64-map-slot-tombstone? (array-ref slots index))]
          (begin
            (array-set! slots index (StringI64MapOccupied key value hash))
            (StringI64MapInsertOk
              (StringI64Map
                slots
                (+ (string-i64-map-len map) 1)
                (if reused-tombstone
                  (- (string-i64-map-deleted map) 1)
                  (string-i64-map-deleted map))))))]
      [(StringI64MapProbeFull) (StringI64MapInsertFull map)])))

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
    (match (string-i64-map-probe-borrowed
      slots
      capacity
      key
      (hash-string key))
      [(StringI64MapProbeFound index)
        (begin
          (array-set! slots index (StringI64MapTombstone))
          (StringI64MapRemoveOk
            (StringI64Map
              slots
              (- (string-i64-map-len map) 1)
              (+ (string-i64-map-deleted map) 1))))]
      [(StringI64MapProbeAbsent _) (StringI64MapRemoveMissing map)]
      [(StringI64MapProbeFull) (StringI64MapRemoveMissing map)])))

;: Compatibility owned-key remove wrapper for existing callers.
(define (string-i64-map-remove [map : StringI64Map] [key : String]) : StringI64MapRemoveResult
  (string-i64-map-remove-borrowed map (& key)))

;: Re-insert every live (occupied) entry of `src` slots `[index, count)` into
;: the fresh `dst` table (`dst-capacity` empty slots), dropping tombstones.
;: `dst-capacity` must hold every live entry, so the probe never returns `Full`.
(define (string-i64-map-rehash-from
  [src : (Array StringI64MapSlot)]
  [dst : (Array StringI64MapSlot)]
  [dst-capacity : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (match (array-ref src index)
        [(StringI64MapOccupied key value hash)
          (match (string-i64-map-probe-normalized dst dst-capacity key hash)
            [(StringI64MapProbeAbsent slot)
              (array-set! dst slot (StringI64MapOccupied key value hash))]
            [(StringI64MapProbeFound slot)
              (array-set! dst slot (StringI64MapOccupied key value hash))]
            [(StringI64MapProbeFull) unit])]
        [(StringI64MapEmpty) unit]
        [(StringI64MapTombstone) unit])
      (string-i64-map-rehash-from src dst dst-capacity (+ index 1) count))))

;: Rebuild `map` as a fresh `new-capacity`-slot table holding only its live
;: entries (tombstones dropped, so the deleted count resets to 0). The backing
;: array is newly allocated; the old one is reclaimed when the arena resets.
;: `new-capacity` must be at least the live `len`.
(define (string-i64-map-resized [map : StringI64Map] [new-capacity : i64]) : StringI64Map
  (let
    [src : (Array StringI64MapSlot) (string-i64-map-slots map)]
    [old-capacity : i64 (array-length src)]
    [dst : (Array StringI64MapSlot) (make-array StringI64MapSlot new-capacity)]
    (begin
      (string-i64-map-fill-empty dst 0 new-capacity)
      (string-i64-map-rehash-from src dst new-capacity 0 old-capacity)
      (StringI64Map dst (string-i64-map-len map) 0))))

;: Next capacity when growing: double, with a small floor so a tiny or empty
;: table grows to a useful size in one step.
(define (string-i64-map-grow-capacity [capacity : i64]) : i64
  (if (< capacity 4)
    8
    (* capacity 2)))

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
    (match (array-ref slots index)
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
      (match (array-ref slots index)
        [(StringI64MapOccupied key value _) (StringI64MapEntrySome key value)]
        [(StringI64MapEmpty) (StringI64MapEntryNone)]
        [(StringI64MapTombstone) (StringI64MapEntryNone)]))))

;: Generated `HashMap<String,String>` slot family.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMapSlot (type-key (type String)) (type-key
    (type String)))
  (defenum StringStringMapSlot
    (StringStringMapEmpty)
    (StringStringMapTombstone)
    (StringStringMapOccupied String String i64)))

;: Result of probing for a `StringStringMap` key.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMapProbe (type-key
    (type String)) (type-key (type String)))
  (defenum StringStringMapProbe
    (StringStringMapProbeFound i64)
    (StringStringMapProbeAbsent i64)
    (StringStringMapProbeFull)))

;: Normalize any generated `StringStringMap` hash into the public hash range.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-hash-normalize (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-hash-normalize [value : i64]) : i64
    (let
      [m : i64 2147483647]
      [raw : i64 (% value 2147483647)]
      (if (< raw 0)
        (+ raw m)
        raw))))

;: Hash a borrowed `StringStringMap` key without relying on imported helpers.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-hash-key (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-hash-key [key : (& key str)]) : i64
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
        hash))))

;: Return the start bucket for `hash` in a `StringStringMap`.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-bucket-index (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-bucket-index [hash : i64] [capacity : i64]) : i64
    (% (string-string-map-hash-normalize hash) capacity)))

;: Advance a `StringStringMap` bucket index by one slot, wrapping around.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-next-index (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-next-index [index : i64] [capacity : i64]) : i64
    (% (+ index 1) capacity)))

;: Pick the insertion slot for an absent `StringStringMap` key.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-insert-slot (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-insert-slot
    [first-tombstone : i64]
    [empty-index : i64]) : i64
    (if (>= first-tombstone 0)
      first-tombstone
      empty-index)))

;: Linear probe for a borrowed `StringStringMap` key.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-probe-borrowed-from (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-probe-borrowed-from
    [slots : (Array StringStringMapSlot)]
    [capacity : i64]
    [key : (& key str)]
    [hash : i64]
    [index : i64]
    [steps : i64]
    [first-tombstone : i64]) : StringStringMapProbe
    (if (>= steps capacity)
      (if (>= first-tombstone 0)
        (StringStringMapProbeAbsent first-tombstone)
        (StringStringMapProbeFull))
      (match (array-ref slots index)
        [(StringStringMapEmpty)
          (StringStringMapProbeAbsent
            (string-string-map-insert-slot first-tombstone index))]
        [(StringStringMapTombstone)
          (string-string-map-probe-borrowed-from
            slots
            capacity
            key
            hash
            (string-string-map-next-index index capacity)
            (+ steps 1)
            (if (>= first-tombstone 0)
              first-tombstone
              index))]
        [(StringStringMapOccupied slot-key _ slot-hash)
          (if (if (= slot-hash hash)
            (string-eq-borrowed (& slot-key) key)
            false)
            (StringStringMapProbeFound index)
            (string-string-map-probe-borrowed-from
              slots
              capacity
              key
              hash
              (string-string-map-next-index index capacity)
              (+ steps 1)
              first-tombstone))]))))

;: Probe `slots` for a borrowed `StringStringMap` key.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-probe-borrowed (type-key
    (type String)) (type-key (type String)))
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
        (string-string-map-bucket-index hash capacity)
        0
        -1))))

;: Compatibility owned-key probe wrapper.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-probe (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-probe
    [slots : (Array StringStringMapSlot)]
    [capacity : i64]
    [key : String]
    [hash : i64]) : StringStringMapProbe
    (string-string-map-probe-borrowed slots capacity (& key) hash)))

;: Generated `HashMap<String,String>` map.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMap (type-key (type String)) (type-key
    (type String)))
  (defstruct StringStringMap
    (slots (Array StringStringMapSlot))
    (len i64)
    (deleted i64)))

;: Result of a `StringStringMap` lookup.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMapLookup (type-key
    (type String)) (type-key (type String)))
  (defenum StringStringMapLookup
    (StringStringMapMissing)
    (StringStringMapFound String)))

;: Result of a fixed-capacity `StringStringMap` insert.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMapInsertResult (type-key
    (type String)) (type-key (type String)))
  (defenum StringStringMapInsertResult
    (StringStringMapInsertOk StringStringMap)
    (StringStringMapInsertFull StringStringMap)))

;: Result of a `StringStringMap` removal.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMapRemoveResult (type-key
    (type String)) (type-key (type String)))
  (defenum StringStringMapRemoveResult
    (StringStringMapRemoveOk StringStringMap)
    (StringStringMapRemoveMissing StringStringMap)))

;: The map's backing slot array.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-slots (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-slots [map : StringStringMap]) : (Array
    StringStringMapSlot)
    (struct-get map slots)))

;: Number of live entries.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-len (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-len [map : StringStringMap]) : i64
    (struct-get map len)))

;: Number of slots in the backing table.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-capacity (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-capacity [map : StringStringMap]) : i64
    (array-length (struct-get map slots))))

;: Number of tombstone slots awaiting reuse.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-deleted (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-deleted [map : StringStringMap]) : i64
    (struct-get map deleted)))

;: Set slots `[index, count)` to `StringStringMapEmpty`.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-fill-empty (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-fill-empty
    [slots : (Array StringStringMapSlot)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! slots index (StringStringMapEmpty))
        (string-string-map-fill-empty slots (+ index 1) count)))))

;: Create an empty `StringStringMap` with `capacity` slots.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-with-capacity (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-with-capacity [capacity : i64]) : StringStringMap
    (let
      [slots : (Array StringStringMapSlot)
        (make-array StringStringMapSlot capacity)]
      (begin
        (string-string-map-fill-empty slots 0 capacity)
        (StringStringMap slots 0 0)))))

;: Look up borrowed `key`, returning its copied string value or `Missing`.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-get-borrowed (type-key
    (type String)) (type-key (type String)))
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
        [(StringStringMapProbeFull) (StringStringMapMissing)]))))

;: Compatibility owned-key lookup wrapper.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-get (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-get [map : StringStringMap] [key : String]) : StringStringMapLookup
    (string-string-map-get-borrowed map (& key))))

;: True when borrowed `key` has a live value in `map`.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-contains-borrowed? (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-contains-borrowed?
    [map : StringStringMap]
    [key : (& key str)]) : bool
    (match (string-string-map-get-borrowed map key)
      [(StringStringMapFound _) true]
      [(StringStringMapMissing) false])))

;: Compatibility owned-key containment wrapper.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-contains? (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-contains? [map : StringStringMap] [key : String]) : bool
    (string-string-map-contains-borrowed? map (& key))))

;: True when `slot` is a reusable tombstone.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-slot-tombstone? (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-slot-tombstone? [slot : StringStringMapSlot]) : bool
    (match slot
      [(StringStringMapTombstone) true]
      [(StringStringMapEmpty) false]
      [(StringStringMapOccupied _ _ _) false])))

;: Insert or update `key` -> `value`, mutating the backing slot array.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-insert (type-key
    (type String)) (type-key (type String)))
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
              (StringStringMapInsertOk
                (StringStringMap
                  slots
                  (+ (string-string-map-len map) 1)
                  (if reused-tombstone
                    (- (string-string-map-deleted map) 1)
                    (string-string-map-deleted map))))))]
        [(StringStringMapProbeFull) (StringStringMapInsertFull map)]))))

;: Remove borrowed `key`, replacing its live slot with a tombstone.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-remove-borrowed (type-key
    (type String)) (type-key (type String)))
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
            (StringStringMapRemoveOk
              (StringStringMap
                slots
                (- (string-string-map-len map) 1)
                (+ (string-string-map-deleted map) 1))))]
        [(StringStringMapProbeAbsent _) (StringStringMapRemoveMissing map)]
        [(StringStringMapProbeFull) (StringStringMapRemoveMissing map)]))))

;: Compatibility owned-key remove wrapper.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-remove (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-remove [map : StringStringMap] [key : String]) : StringStringMapRemoveResult
    (string-string-map-remove-borrowed map (& key))))

;: Re-insert every live entry into a fresh `StringStringMap` table.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-rehash-from (type-key
    (type String)) (type-key (type String)))
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
            (match (string-string-map-probe-borrowed
              dst
              dst-capacity
              (& key)
              hash)
              [(StringStringMapProbeAbsent slot)
                (array-set! dst slot (StringStringMapOccupied key value hash))]
              [(StringStringMapProbeFound slot)
                (array-set! dst slot (StringStringMapOccupied key value hash))]
              [(StringStringMapProbeFull) unit])]
          [(StringStringMapEmpty) unit]
          [(StringStringMapTombstone) unit])
        (string-string-map-rehash-from src dst dst-capacity (+ index 1) count)))))

;: Rebuild `map` as a fresh `new-capacity` table holding only live entries.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-resized (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-resized
    [map : StringStringMap]
    [new-capacity : i64]) : StringStringMap
    (let
      [src : (Array StringStringMapSlot) (string-string-map-slots map)]
      [old-capacity : i64 (string-string-map-capacity map)]
      [dst : (Array StringStringMapSlot)
        (make-array StringStringMapSlot new-capacity)]
      (begin
        (string-string-map-fill-empty dst 0 new-capacity)
        (string-string-map-rehash-from src dst new-capacity 0 old-capacity)
        (StringStringMap dst (string-string-map-len map) 0)))))

;: Next capacity when growing.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-grow-capacity (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-grow-capacity [capacity : i64]) : i64
    (if (< capacity 4)
      8
      (* capacity 2))))

;: Grow `map` to the next capacity.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-grow (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-grow [map : StringStringMap]) : StringStringMap
    (string-string-map-resized
      map
      (string-string-map-grow-capacity (string-string-map-capacity map)))))

;: True when the table has reached the 3/4 load threshold.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-needs-grow? (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-needs-grow? [map : StringStringMap]) : bool
    (let
      [capacity : i64 (string-string-map-capacity map)]
      [used : i64
        (+ (string-string-map-len map) (string-string-map-deleted map))]
      (if (<= capacity 0)
        true
        (>= (* used 4) (* capacity 3))))))

;: Insert or update `key` -> `value`, growing as needed.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-put (type-key
    (type String)) (type-key (type String)))
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
            [(StringStringMapInsertFull u) u])]))))

;: A single `StringStringMap` iteration entry, or none.
(comptime-decl
  (:generated stdlib/hashmap-family StringStringMapEntry (type-key
    (type String)) (type-key (type String)))
  (defenum StringStringMapEntry
    (StringStringMapEntryNone)
    (StringStringMapEntrySome String String)))

;: Scan `slots` from `index` for the first occupied slot.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-next-occupied-from (type-key
    (type String)) (type-key (type String)))
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
          (string-string-map-next-occupied-from slots (+ index 1) capacity)]))))

;: Iteration cursor for `StringStringMap` in deterministic bucket order.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-next-occupied (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-next-occupied [map : StringStringMap] [from : i64]) : i64
    (string-string-map-next-occupied-from
      (string-string-map-slots map)
      (if (< from 0)
        0
        from)
      (string-string-map-capacity map))))

;: The live `StringStringMap` entry at `index`, or `None`.
(comptime-decl
  (:generated stdlib/hashmap-family string-string-map-entry-at (type-key
    (type String)) (type-key (type String)))
  (define (string-string-map-entry-at [map : StringStringMap] [index : i64]) : StringStringMapEntry
    (if (if (< index 0)
      true
      (>= index (string-string-map-capacity map)))
      (StringStringMapEntryNone)
      (match (array-ref (string-string-map-slots map) index)
        [(StringStringMapOccupied key value _)
          (StringStringMapEntrySome key value)]
        [(StringStringMapEmpty) (StringStringMapEntryNone)]
        [(StringStringMapTombstone) (StringStringMapEntryNone)]))))

;: Generated `HashMap<i64,i64>` slot family.
(comptime-decl
  (:generated stdlib/hashmap-family I64I64MapSlot (type-key (type i64)) (type-key
    (type i64)))
  (defenum I64I64MapSlot
    (I64I64MapEmpty)
    (I64I64MapTombstone)
    (I64I64MapOccupied i64 i64 i64)))

;: Result of probing for an `I64I64Map` key.
(comptime-decl
  (:generated stdlib/hashmap-family I64I64MapProbe (type-key (type i64)) (type-key
    (type i64)))
  (defenum I64I64MapProbe
    (I64I64MapProbeFound i64)
    (I64I64MapProbeAbsent i64)
    (I64I64MapProbeFull)))

;: Normalize any generated `I64I64Map` hash into the public hash range.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-hash-normalize (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-hash-normalize [value : i64]) : i64
    (let
      [m : i64 2147483647]
      [raw : i64 (% value 2147483647)]
      (if (< raw 0)
        (+ raw m)
        raw))))

;: Hash an `I64I64Map` key without relying on imported helpers.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-hash-key (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-hash-key [key : i64]) : i64
    (i64-i64-map-hash-normalize key)))

;: Return the start bucket for `hash` in an `I64I64Map`.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-bucket-index (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-bucket-index [hash : i64] [capacity : i64]) : i64
    (% (i64-i64-map-hash-normalize hash) capacity)))

;: Advance an `I64I64Map` bucket index by one slot, wrapping around.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-next-index (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-next-index [index : i64] [capacity : i64]) : i64
    (% (+ index 1) capacity)))

;: Pick the insertion slot for an absent `I64I64Map` key.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-insert-slot (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-insert-slot [first-tombstone : i64] [empty-index : i64]) : i64
    (if (>= first-tombstone 0)
      first-tombstone
      empty-index)))

;: Linear probe for an `I64I64Map` key.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-probe-from (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-probe-from
    [slots : (Array I64I64MapSlot)]
    [capacity : i64]
    [key : i64]
    [hash : i64]
    [index : i64]
    [steps : i64]
    [first-tombstone : i64]) : I64I64MapProbe
    (if (>= steps capacity)
      (if (>= first-tombstone 0)
        (I64I64MapProbeAbsent first-tombstone)
        (I64I64MapProbeFull))
      (match (array-ref slots index)
        [(I64I64MapEmpty)
          (I64I64MapProbeAbsent (i64-i64-map-insert-slot first-tombstone index))]
        [(I64I64MapTombstone)
          (i64-i64-map-probe-from
            slots
            capacity
            key
            hash
            (i64-i64-map-next-index index capacity)
            (+ steps 1)
            (if (>= first-tombstone 0)
              first-tombstone
              index))]
        [(I64I64MapOccupied slot-key _ slot-hash)
          (if (if (= slot-hash hash)
            (= slot-key key)
            false)
            (I64I64MapProbeFound index)
            (i64-i64-map-probe-from
              slots
              capacity
              key
              hash
              (i64-i64-map-next-index index capacity)
              (+ steps 1)
              first-tombstone))]))))

;: Probe `slots` for an `I64I64Map` key.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-probe (type-key (type i64)) (type-key
    (type i64)))
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
        (i64-i64-map-bucket-index hash capacity)
        0
        -1))))

;: Generated `HashMap<i64,i64>` map.
(comptime-decl
  (:generated stdlib/hashmap-family I64I64Map (type-key (type i64)) (type-key
    (type i64)))
  (defstruct I64I64Map
    (slots (Array I64I64MapSlot))
    (len i64)
    (deleted i64)))

;: Result of an `I64I64Map` lookup.
(comptime-decl
  (:generated stdlib/hashmap-family I64I64MapLookup (type-key (type i64)) (type-key
    (type i64)))
  (defenum I64I64MapLookup
    (I64I64MapMissing)
    (I64I64MapFound i64)))

;: Result of a fixed-capacity `I64I64Map` insert.
(comptime-decl
  (:generated stdlib/hashmap-family I64I64MapInsertResult (type-key (type i64)) (type-key
    (type i64)))
  (defenum I64I64MapInsertResult
    (I64I64MapInsertOk I64I64Map)
    (I64I64MapInsertFull I64I64Map)))

;: Result of an `I64I64Map` removal.
(comptime-decl
  (:generated stdlib/hashmap-family I64I64MapRemoveResult (type-key (type i64)) (type-key
    (type i64)))
  (defenum I64I64MapRemoveResult
    (I64I64MapRemoveOk I64I64Map)
    (I64I64MapRemoveMissing I64I64Map)))

;: The map's backing slot array.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-slots (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-slots [map : I64I64Map]) : (Array I64I64MapSlot)
    (struct-get map slots)))

;: Number of live entries.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-len (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-len [map : I64I64Map]) : i64
    (struct-get map len)))

;: Number of slots in the backing table.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-capacity (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-capacity [map : I64I64Map]) : i64
    (array-length (struct-get map slots))))

;: Number of tombstone slots awaiting reuse.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-deleted (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-deleted [map : I64I64Map]) : i64
    (struct-get map deleted)))

;: Set slots `[index, count)` to `I64I64MapEmpty`.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-fill-empty (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-fill-empty
    [slots : (Array I64I64MapSlot)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! slots index (I64I64MapEmpty))
        (i64-i64-map-fill-empty slots (+ index 1) count)))))

;: Create an empty `I64I64Map` with `capacity` slots.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-with-capacity (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-with-capacity [capacity : i64]) : I64I64Map
    (let
      [slots : (Array I64I64MapSlot) (make-array I64I64MapSlot capacity)]
      (begin
        (i64-i64-map-fill-empty slots 0 capacity)
        (I64I64Map slots 0 0)))))

;: Look up `key`, returning its copied value or `Missing`.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-get (type-key (type i64)) (type-key
    (type i64)))
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
        [(I64I64MapProbeFull) (I64I64MapMissing)]))))

;: True when `key` has a live value in `map`.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-contains? (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-contains? [map : I64I64Map] [key : i64]) : bool
    (match (i64-i64-map-get map key)
      [(I64I64MapFound _) true]
      [(I64I64MapMissing) false])))

;: True when `slot` is a reusable tombstone.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-slot-tombstone? (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-slot-tombstone? [slot : I64I64MapSlot]) : bool
    (match slot
      [(I64I64MapTombstone) true]
      [(I64I64MapEmpty) false]
      [(I64I64MapOccupied _ _ _) false])))

;: Insert or update `key` -> `value`, mutating the backing slot array.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-insert (type-key (type i64)) (type-key
    (type i64)))
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
              (I64I64MapInsertOk
                (I64I64Map
                  slots
                  (+ (i64-i64-map-len map) 1)
                  (if reused-tombstone
                    (- (i64-i64-map-deleted map) 1)
                    (i64-i64-map-deleted map))))))]
        [(I64I64MapProbeFull) (I64I64MapInsertFull map)]))))

;: Remove `key`, replacing its live slot with a tombstone.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-remove (type-key (type i64)) (type-key
    (type i64)))
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
            (I64I64MapRemoveOk
              (I64I64Map
                slots
                (- (i64-i64-map-len map) 1)
                (+ (i64-i64-map-deleted map) 1))))]
        [(I64I64MapProbeAbsent _) (I64I64MapRemoveMissing map)]
        [(I64I64MapProbeFull) (I64I64MapRemoveMissing map)]))))

;: Re-insert every live entry into a fresh `I64I64Map` table.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-rehash-from (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-rehash-from
    [src : (Array I64I64MapSlot)]
    [dst : (Array I64I64MapSlot)]
    [dst-capacity : i64]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (match (array-ref src index)
          [(I64I64MapOccupied key value hash)
            (match (i64-i64-map-probe dst dst-capacity key hash)
              [(I64I64MapProbeAbsent slot)
                (array-set! dst slot (I64I64MapOccupied key value hash))]
              [(I64I64MapProbeFound slot)
                (array-set! dst slot (I64I64MapOccupied key value hash))]
              [(I64I64MapProbeFull) unit])]
          [(I64I64MapEmpty) unit]
          [(I64I64MapTombstone) unit])
        (i64-i64-map-rehash-from src dst dst-capacity (+ index 1) count)))))

;: Rebuild `map` as a fresh `new-capacity` table holding only live entries.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-resized (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-resized [map : I64I64Map] [new-capacity : i64]) : I64I64Map
    (let
      [src : (Array I64I64MapSlot) (i64-i64-map-slots map)]
      [old-capacity : i64 (i64-i64-map-capacity map)]
      [dst : (Array I64I64MapSlot) (make-array I64I64MapSlot new-capacity)]
      (begin
        (i64-i64-map-fill-empty dst 0 new-capacity)
        (i64-i64-map-rehash-from src dst new-capacity 0 old-capacity)
        (I64I64Map dst (i64-i64-map-len map) 0)))))

;: Next capacity when growing.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-grow-capacity (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-grow-capacity [capacity : i64]) : i64
    (if (< capacity 4)
      8
      (* capacity 2))))

;: Grow `map` to the next capacity.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-grow (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-grow [map : I64I64Map]) : I64I64Map
    (i64-i64-map-resized
      map
      (i64-i64-map-grow-capacity (i64-i64-map-capacity map)))))

;: True when the table has reached the 3/4 load threshold.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-needs-grow? (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-needs-grow? [map : I64I64Map]) : bool
    (let
      [capacity : i64 (i64-i64-map-capacity map)]
      [used : i64 (+ (i64-i64-map-len map) (i64-i64-map-deleted map))]
      (if (<= capacity 0)
        true
        (>= (* used 4) (* capacity 3))))))

;: Insert or update `key` -> `value`, growing as needed.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-put (type-key (type i64)) (type-key
    (type i64)))
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
            [(I64I64MapInsertFull u) u])]))))

;: A single `I64I64Map` iteration entry, or none.
(comptime-decl
  (:generated stdlib/hashmap-family I64I64MapEntry (type-key (type i64)) (type-key
    (type i64)))
  (defenum I64I64MapEntry
    (I64I64MapEntryNone)
    (I64I64MapEntrySome i64 i64)))

;: Scan `slots` from `index` for the first occupied slot.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-next-occupied-from (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-next-occupied-from
    [slots : (Array I64I64MapSlot)]
    [index : i64]
    [capacity : i64]) : i64
    (if (>= index capacity)
      capacity
      (match (array-ref slots index)
        [(I64I64MapOccupied _ _ _) index]
        [(I64I64MapEmpty)
          (i64-i64-map-next-occupied-from slots (+ index 1) capacity)]
        [(I64I64MapTombstone)
          (i64-i64-map-next-occupied-from slots (+ index 1) capacity)]))))

;: Iteration cursor for `I64I64Map` in deterministic bucket order.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-next-occupied (type-key
    (type i64)) (type-key (type i64)))
  (define (i64-i64-map-next-occupied [map : I64I64Map] [from : i64]) : i64
    (i64-i64-map-next-occupied-from
      (i64-i64-map-slots map)
      (if (< from 0)
        0
        from)
      (i64-i64-map-capacity map))))

;: The live `I64I64Map` entry at `index`, or `None`.
(comptime-decl
  (:generated stdlib/hashmap-family i64-i64-map-entry-at (type-key (type i64)) (type-key
    (type i64)))
  (define (i64-i64-map-entry-at [map : I64I64Map] [index : i64]) : I64I64MapEntry
    (if (if (< index 0)
      true
      (>= index (i64-i64-map-capacity map)))
      (I64I64MapEntryNone)
      (match (array-ref (i64-i64-map-slots map) index)
        [(I64I64MapOccupied key value _) (I64I64MapEntrySome key value)]
        [(I64I64MapEmpty) (I64I64MapEntryNone)]
        [(I64I64MapTombstone) (I64I64MapEntryNone)]))))
