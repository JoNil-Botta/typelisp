;;;; String -> i64 hashmap probing core (#825).
;;;;
;;;; Open-addressed, fixed-capacity, linear-probing core for the v1
;;;; `String -> i64` map whose representation was chosen in #824. This slice
;;;; provides the slot type, the bucket-index math, and the collision-probing
;;;; walk with full-table detection. Insert / lookup / remove APIs build on
;;;; `string-i64-map-probe` and are tracked separately (#826, #829).
;;;;
;;;; Capacity may be any positive `i64`: the start bucket is the normalized hash
;;;; modulo capacity, and probing wraps with modulo arithmetic (no power-of-two
;;;; requirement). Each occupied slot caches its key hash so probing compares the
;;;; cheap `i64` hash before the full key comparison. The probe visits at most
;;;; `capacity` slots, so a full table terminates instead of looping forever.
;;;;
;;;; Usage: `(import "stdlib/hashmap.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/hashmap.tl")
;;;; (define (main) : i64
;;;;   (match (string-i64-map-probe (make-array StringI64MapSlot 4) 4 "k" 0)
;;;;     [(StringI64MapProbeAbsent slot) slot]
;;;;     [(StringI64MapProbeFound slot) slot]
;;;;     [(StringI64MapProbeFull) -1]))
;;;; ```
(import "stdlib/hash.tl")

;;; One open-addressing slot: empty, a deleted tombstone, or an occupied entry
;;; carrying the owned key, its copied value, and the cached key hash (#824).
(defenum StringI64MapSlot
  (StringI64MapEmpty)
  (StringI64MapTombstone)
  (StringI64MapOccupied String i64 i64))

;;; Result of probing for a key in a slot array:
;;; - `Found` carries the slot index that holds the key.
;;; - `Absent` carries the slot index where the key may be inserted (the first
;;;   tombstone seen, otherwise the first empty slot).
;;; - `Full` means the key is not present and the table has neither an empty
;;;   slot nor a reusable tombstone.
(defenum StringI64MapProbe
  (StringI64MapProbeFound i64)
  (StringI64MapProbeAbsent i64)
  (StringI64MapProbeFull))

;;; Return the start bucket for `hash` in a table of `capacity` slots.
;;; `capacity` must be positive; the result is in `[0, capacity)`.
(define (string-i64-map-bucket-index [hash : i64] [capacity : i64]) : i64
  (% (hash-normalize hash) capacity))

;;; Advance a bucket index by one slot, wrapping around the table.
(define (string-i64-map-next-index [index : i64] [capacity : i64]) : i64
  (% (+ index 1) capacity))

;;; Pick the insertion slot for an absent key: reuse the first tombstone seen
;;; (`first-tombstone` >= 0) so deletes do not strand keys, otherwise the empty
;;; slot the probe stopped on.
(define (string-i64-map-insert-slot [first-tombstone : i64] [empty-index : i64]) : i64
  (if (>= first-tombstone 0)
    first-tombstone
    empty-index))

;;; Linear-probing walk from `index`, having taken `steps` steps and remembered
;;; the first tombstone index (`-1` when none seen yet). Terminates after at most
;;; `capacity` steps so a full table never loops forever.
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

;;; Probe `slots` (a `capacity`-length open-addressing table) for `key` with the
;;; precomputed `hash`. Returns where the key lives (`Found`), where it could be
;;; inserted (`Absent`), or `Full`. Callers compute `hash` with `hash-string`.
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