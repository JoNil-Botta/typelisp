;# String -> i64 hashmap probing core (#825).
;#
;# Open-addressed, fixed-capacity, linear-probing core for the v1
;# `String -> i64` map whose representation was chosen in #824. This slice
;# provides the slot type, the bucket-index math, and the collision-probing
;# walk with full-table detection. Insert / lookup / remove APIs build on
;# `string-i64-map-probe` and are tracked separately (#826, #829).
;#
;# Capacity may be any positive `i64`: the start bucket is the normalized hash
;# modulo capacity, and probing wraps with modulo arithmetic (no power-of-two
;# requirement). Each occupied slot caches its key hash so probing compares the
;# cheap `i64` hash before the full key comparison. The probe visits at most
;# `capacity` slots, so a full table terminates instead of looping forever.
;#
;# Usage: `(import "stdlib/hashmap.tl")`
;#
;# ```typelisp
;# (import "stdlib/hashmap.tl")
;# (define (main) : i64
;#   (match (string-i64-map-probe (make-array StringI64MapSlot 4) 4 "k" 0)
;#     [(StringI64MapProbeAbsent slot) slot]
;#     [(StringI64MapProbeFound slot) slot]
;#     [(StringI64MapProbeFull) -1]))
;# ```
(import "stdlib/hash.tl")

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

;: Advance a bucket index by one slot, wrapping around the table.
(define (string-i64-map-next-index [index : i64] [capacity : i64]) : i64
  (% (+ index 1) capacity))

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
  (if (>= steps capacity)
    (if (>= first-tombstone 0)
      (StringI64MapProbeAbsent first-tombstone)
      (StringI64MapProbeFull))
    (match (array-ref slots index)
      [(StringI64MapEmpty)
        (StringI64MapProbeAbsent
          (string-i64-map-insert-slot first-tombstone index))]
      [(StringI64MapTombstone)
        (string-i64-map-probe-from
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
          (hash-key-string-eq? slot-key key)
          false)
          (StringI64MapProbeFound index)
          (string-i64-map-probe-from
            slots
            capacity
            key
            hash
            (string-i64-map-next-index index capacity)
            (+ steps 1)
            first-tombstone))])))

;: Probe `slots` (a `capacity`-length open-addressing table) for `key` with the
;: precomputed `hash`. Returns where the key lives (`Found`), where it could be
;: inserted (`Absent`), or `Full`. Callers compute `hash` with `hash-string`.
(define (string-i64-map-probe
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
      (string-i64-map-bucket-index hash capacity)
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

;: Look up `key`, returning its copied `i64` value or `Missing`.
(define (string-i64-map-get [map : StringI64Map] [key : String]) : StringI64MapLookup
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    (match (string-i64-map-probe
      slots
      (string-i64-map-capacity map)
      key
      (hash-string key))
      [(StringI64MapProbeFound index)
        (match (array-ref slots index)
          [(StringI64MapOccupied _ value _) (StringI64MapFound value)]
          [(StringI64MapEmpty) (StringI64MapMissing)]
          [(StringI64MapTombstone) (StringI64MapMissing)])]
      [(StringI64MapProbeAbsent _) (StringI64MapMissing)]
      [(StringI64MapProbeFull) (StringI64MapMissing)])))

;: True when `key` has a live value in `map`.
(define (string-i64-map-contains? [map : StringI64Map] [key : String]) : bool
  (match (string-i64-map-get map key)
    [(StringI64MapFound _) true]
    [(StringI64MapMissing) false]))

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
    [hash : i64 (hash-string key)]
    (match (string-i64-map-probe slots (string-i64-map-capacity map) key hash)
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

;: Remove `key`, replacing its live slot with a tombstone (so probing past it
;: still finds later collided keys) and returning the updated map with `len`
;: decremented and the deleted count incremented. Returns `Missing` with the
;: map unchanged when the key is absent. A later insert can reuse the
;: tombstone. The backing array is mutated in place, so thread the result
;: forward.
(define (string-i64-map-remove [map : StringI64Map] [key : String]) : StringI64MapRemoveResult
  (let
    [slots : (Array StringI64MapSlot) (string-i64-map-slots map)]
    (match (string-i64-map-probe
      slots
      (string-i64-map-capacity map)
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
          (match (string-i64-map-probe dst dst-capacity key hash)
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
    [old-capacity : i64 (string-i64-map-capacity map)]
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
  (string-i64-map-resized
    map
    (string-i64-map-grow-capacity (string-i64-map-capacity map))))

;: True when the table has reached the 3/4 load threshold, counting both live
;: entries and tombstones (both consume probe positions). A non-positive
;: capacity always needs to grow before it can hold anything.
(define (string-i64-map-needs-grow? [map : StringI64Map]) : bool
  (let
    [capacity : i64 (string-i64-map-capacity map)]
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
  (string-i64-map-next-occupied-from
    (string-i64-map-slots map)
    (if (< from 0)
      0
      from)
    (string-i64-map-capacity map)))

;: The live entry at `index`, or `None` for an empty slot, a tombstone, or an
;: index outside `[0, capacity)`. Pair with `string-i64-map-next-occupied` to
;: walk the map in bucket order. The key is handed back by value; v1 does not
;: yet enforce that the borrow outlives the map (revisited under #806).
(define (string-i64-map-entry-at [map : StringI64Map] [index : i64]) : StringI64MapEntry
  (if (if (< index 0)
    true
    (>= index (string-i64-map-capacity map)))
    (StringI64MapEntryNone)
    (match (array-ref (string-i64-map-slots map) index)
      [(StringI64MapOccupied key value _) (StringI64MapEntrySome key value)]
      [(StringI64MapEmpty) (StringI64MapEntryNone)]
      [(StringI64MapTombstone) (StringI64MapEntryNone)])))