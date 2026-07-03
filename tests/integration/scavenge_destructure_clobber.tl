(import "stdlib/io.tl")
(import stdlib.array)
(import "stdlib/string.tl")

;; FORCING / CORRECTNESS test for the register-scavenger fused-destructure clobber
;; (latent backend miscompile, surfaced by loop-carry phi coalescing lowering
;; pressure). Mirrors intern-lookup's `InternUsed` arm shape:
;;
;;   (match slot
;;     [(Used slot-key slot-id slot-hash)            ; key=POINTER, id=int, hash=int
;;       (if (= slot-hash hash)
;;         (string-eq slot-key name)                  ; DEREFERENCES slot-key
;;         false) ...])
;;
;; The arm binds a register-homed POINTER field (`slot-key`) that is live ACROSS a
;; SIBLING spilled int field-load (`slot-id`, stored to the stack). When the two
;; field-loads fuse into one emission step, the spilled load's staging scratch is
;; scavenged at the step's emit position -- BEFORE slot-key's def point -- so the
;; occupancy mask reports slot-key's register FREE and the scratch picks it,
;; clobbering the live pointer. The later `string-eq slot-key name` then derefs an
;; integer-as-pointer -> SIGSEGV / wrong result (exactly intern-lookup+356's
;; `mov 0x8(%r9),%rdi` with %r9 = a slot-id value).
;;
;; CORRECTNESS GUARD: the lookup returns the id whose key string-equals the query.
;; If slot-key is clobbered by slot-id's load, the string compare reads garbage
;; (crash or false), so the wrong id (or none) is returned -> exit 1. Seeded from
;; (arg-count) so the optimizer cannot fold the loop, and the key strings are
;; distinct heap pointers so the compare must really dereference them.
(defenum Slot
  (SlotEmpty)
  (SlotUsed String i64 i64))

;; Linear-probe lookup mirroring intern-lookup: walk slots, on a hash hit compare
;; the (pointer) key against `name`, and on a key match return the (int) id.
(define (slot-lookup
  [slots : (Array Slot)]
  [n : i64]
  [name : String]
  [hash : i64]) : i64
  (let
    [i : i64 0]
    [out : i64 -1]
    [done : bool false]
    (begin
      (while (if done
        false
        (< i n))
        (match (array.array-ref slots i)
          [(SlotEmpty)
            (begin
              (set! out -1)
              (set! done true))]
          [(SlotUsed slot-key slot-id slot-hash)
            (if (if (= slot-hash hash)
              (string-eq slot-key name)
              false)
              (begin
                (set! out slot-id)
                (set! done true))
              (set! i (+ i 1)))]))
      out)))

(define (main) : i64
  (let
    [s : i64 (arg-count)]
    [n : i64 6]
    [slots : (Array Slot) (array.make-array Slot n)]
    (begin
      ;; Distinct heap key strings; ids offset by the seed so they are not folded.
      (array.array-set! slots 0 (SlotUsed "alpha" (+ s 10) 100))
      (array.array-set! slots 1 (SlotUsed "beta" (+ s 20) 200))
      (array.array-set! slots 2 (SlotUsed "gamma" (+ s 30) 300))
      (array.array-set! slots 3 (SlotUsed "delta" (+ s 40) 400))
      (array.array-set! slots 4 (SlotUsed "epsilon" (+ s 50) 500))
      (array.array-set! slots 5 (SlotEmpty))
      ;; gamma -> id (s+30) at hash 300; delta -> id (s+40) at hash 400.
      (let
        [g : i64 (slot-lookup slots n "gamma" 300)]
        [d : i64 (slot-lookup slots n "delta" 400)]
        [miss : i64 (slot-lookup slots n "zzz" 999)]
        (if (and (and (= g (+ s 30)) (= d (+ s 40))) (= miss -1))
          42
          1)))))