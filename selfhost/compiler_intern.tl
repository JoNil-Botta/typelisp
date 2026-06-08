;; compiler_intern.tl - process-global string interning table for identifiers.
;;
;; SELF-CONTAINED (no imports): every programmer-written identifier is interned
;; to a stable i64 id, so name comparisons become i64 `=`, id-keyed lookups
;; replace string hashing, and the AST stores ids instead of copied Strings.
;; Being import-free is deliberate -- this module is reached from the core
;; compiler_ast_types.tl (and from sym_i64_env.tl), which are imported by tiny
;; integration cases; pulling stdlib/hashmap here would ripple new transitive
;; deps onto every one of those cases.
;;
;; The table is PERSISTENT for a compile (ids stay valid across the loader's
;; per-file parse-arena destroy -- ids are integers, so they survive); it resets
;; between compiles (REPL/LSP and single-source smoke compiles) via intern-reset!.
;; It mirrors the node pools: two plain mutable globals (id->String array + count)
;; plus a fixed open-addressing dedup table, all PRE-SIZED so neither ever grows
;; (a grow! reassigns a global in the inlined hot path -> opt2 miscompile).
;;
;; IDs are assigned in INSERTION (parse) order, independent of the hash function,
;; so the emitted output is identical regardless of the probe's hash -- the hash
;; only affects bucket placement, never the id a string gets.
;: Capacity must stay a power of two so the bucket index is a mask, not a modulo.
(define (intern-capacity) : i64
  262144)

(defenum InternSlot
  (InternEmpty)
  (InternUsed String i64 i64))

(define intern-pool-slots : (Array String)
  (make-array String 262144))

(define intern-pool-count : i64
  0)

(define intern-map-slots : (Array InternSlot)
  (make-array InternSlot 262144))

(define intern-map-ready : bool
  false)

(define intern-reset-generation : i64
  0)

;: djb2 string hash over the raw bytes. Overflow wraps in i64; the result may be
;: negative, which is fine -- the bucket mask keeps only the low bits.
(define (intern-hash [s : String]) : i64
  (let
    [len : i64 (string-length s)]
    [h : i64 5381]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (set! h (+ (* h 33) (cast (string-ref s i) : i64)))
          (set! i (+ i 1))))
      h)))

;: Mask `hash` into `[0, capacity)`; capacity is a power of two.
(define (intern-bucket [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

;: Set slots `[index, count)` to InternEmpty.
(define (intern-fill-empty [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! intern-map-slots index (InternEmpty))
      (intern-fill-empty (+ index 1) count))))

;: Reset the intern table for a fresh compile and (re)initialize the dedup slots
;: to Empty. `make-array` does not produce valid `Empty` enum slots, so the fill
;: is mandatory before the first probe; this runs it once (idempotent).
(define (intern-reset!) : unit
  (begin
    (set! intern-pool-count 0)
    (intern-fill-empty 0 (array-length intern-map-slots))
    (set! intern-reset-generation (+ intern-reset-generation 1))
    (set! intern-map-ready true)))

;: Intern `name`, returning its stable i64 id. Equal strings map to equal ids.
;: Lazily initializes the dedup table so callers need not order intern-reset!.
(define (intern [name : String]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (let
      [capacity : i64 (array-length intern-map-slots)]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : i64 -1]
      [done : bool false]
      (begin
        (while (if done
          false
          (< steps capacity))
          (match (array-ref intern-map-slots cursor)
            [(InternEmpty)
              (let
                [id : i64 intern-pool-count]
                (begin
                  (array-set! intern-pool-slots id name)
                  (array-set! intern-map-slots cursor (InternUsed name id hash))
                  (set! intern-pool-count (+ id 1))
                  (set! out id)
                  (set! done true)))]
            [(InternUsed slot-key slot-id slot-hash)
              (if (if (= slot-hash hash)
                (string-eq slot-key name)
                false)
                (begin
                  (set! out slot-id)
                  (set! done true))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))]))
        out))))

;: Recover the original String for an interned id.
(define (intern-str [id : i64]) : String
  (array-ref intern-pool-slots id))

(define (intern-generation) : i64
  intern-reset-generation)