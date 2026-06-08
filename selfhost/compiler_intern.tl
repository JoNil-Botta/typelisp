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

(defenum InternLookup
  (InternLookupMissing)
  (InternLookupFound i64))

(define intern-pool-slots : (Array String)
  (make-array String 262144))

(define intern-pool-qualified-slots : (Array bool)
  (make-array bool 262144))

(define intern-pool-last-slash-slots : (Array i64)
  (make-array i64 262144))

(define intern-pool-module-id-slots : (Array i64)
  (make-array i64 262144))

(define intern-pool-base-id-slots : (Array i64)
  (make-array i64 262144))

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

(define (intern-substring [text : String] [start : i64] [len : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 len)]
    [src : (Ptr u8)
      (unsafe
        (string-data (& text)))]
    [dst : (MutPtr u8)
      (unsafe
        (array-data buf))]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset dst i)
              (ptr-read (ptr-offset src (+ start i)))))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) len)))))

(define (intern-compute-last-slash [name : String]) : i64
  (let
    [i : i64 (- (string-length name) 1)]
    (begin
      (while (>= i 0)
        (if (= (string-ref name i) #/')
          (return i)
          (set! i (- i 1))))
      -1)))

(define (intern-record-qualified-metadata [id : i64] [name : String]) : unit
  (let
    [slash : i64 (intern-compute-last-slash name)]
    (begin
      (array-set! intern-pool-last-slash-slots id slash)
      (if (< slash 0)
        (begin
          (array-set! intern-pool-qualified-slots id false)
          (array-set! intern-pool-module-id-slots id -1)
          (array-set! intern-pool-base-id-slots id id))
        (let
          [base-start : i64 (+ slash 1)]
          [module-name : String (intern-substring name 0 slash)]
          [base-name : String
            (intern-substring
              name
              base-start
              (- (string-length name) base-start))]
          (begin
            (array-set! intern-pool-qualified-slots id true)
            (array-set! intern-pool-module-id-slots id (intern module-name))
            (array-set! intern-pool-base-id-slots id (intern base-name))))))))

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
                  (intern-record-qualified-metadata id name)
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

;: Look up an already-interned name without mutating the table. This lets later
;: compiler phases use id-keyed indexes without interning backend-generated
;: probe strings as a side effect.
(define (intern-lookup [name : String]) : InternLookup
  (if intern-map-ready
    (let
      [capacity : i64 (array-length intern-map-slots)]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : InternLookup InternLookupMissing]
      [done : bool false]
      (begin
        (while (if done
          false
          (< steps capacity))
          (match (array-ref intern-map-slots cursor)
            [(InternEmpty)
              (begin
                (set! out (InternLookupMissing))
                (set! done true))]
            [(InternUsed slot-key slot-id slot-hash)
              (if (if (= slot-hash hash)
                (string-eq slot-key name)
                false)
                (begin
                  (set! out (InternLookupFound slot-id))
                  (set! done true))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))]))
        out))
    (InternLookupMissing)))

;: Recover the original String for an interned id.
(define (intern-str [id : i64]) : String
  (array-ref intern-pool-slots id))

(define (intern-generation) : i64
  intern-reset-generation)

(define (intern-qualified? [id : i64]) : bool
  (array-ref intern-pool-qualified-slots id))

(define (intern-qualified-last-slash [id : i64]) : i64
  (array-ref intern-pool-last-slash-slots id))

(define (intern-qualified-module-id [id : i64]) : i64
  (array-ref intern-pool-module-id-slots id))

(define (intern-qualified-base-id [id : i64]) : i64
  (array-ref intern-pool-base-id-slots id))

(define (intern-qualified-module [id : i64]) : String
  (let
    [module-id : i64 (intern-qualified-module-id id)]
    (if (< module-id 0)
      ""
      (intern-str module-id))))

(define (intern-qualified-base [id : i64]) : String
  (intern-str (intern-qualified-base-id id)))

(define (intern-name-qualified? [name : String]) : bool
  (intern-qualified? (intern name)))

(define (intern-name-last-slash [name : String]) : i64
  (intern-qualified-last-slash (intern name)))

(define (intern-name-module [name : String]) : String
  (intern-qualified-module (intern name)))

(define (intern-name-base [name : String]) : String
  (intern-qualified-base (intern name)))

(define (intern-qualified-metadata-case-ok?
  [id : i64]
  [qualified : bool]
  [last-slash : i64]
  [module-name : String]
  [base-name : String]) : bool
  (and
    (= (intern-qualified-last-slash id) last-slash)
    (and
      (= (intern-qualified? id) qualified)
      (and
        (string-eq (intern-qualified-module id) module-name)
        (string-eq (intern-qualified-base id) base-name)))))

(define (intern-qualified-metadata-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [plain : i64 (intern "name")]
      [qualified : i64 (intern "module/name")]
      [nested : i64 (intern "pkg/sub/name")]
      [leading : i64 (intern "/name")]
      [trailing : i64 (intern "module/")]
      [slash : i64 (intern "/")]
      [ok : bool
        (and
          (intern-qualified-metadata-case-ok? plain false -1 "" "name")
          (and
            (= (intern-qualified-base-id plain) plain)
            (and
              (= (intern-qualified-module-id plain) -1)
              (and
                (intern-qualified-metadata-case-ok?
                  qualified
                  true
                  6
                  "module"
                  "name")
                (and
                  (intern-qualified-metadata-case-ok?
                    nested
                    true
                    7
                    "pkg/sub"
                    "name")
                  (and
                    (intern-qualified-metadata-case-ok?
                      leading
                      true
                      0
                      ""
                      "name")
                    (and
                      (intern-qualified-metadata-case-ok?
                        trailing
                        true
                        6
                        "module"
                        "")
                      (intern-qualified-metadata-case-ok? slash true 0 "" ""))))))))]
      (begin
        (intern-reset!)
        ok))))