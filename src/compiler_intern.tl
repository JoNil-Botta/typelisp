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
;: Local arena hooks keep this module import-free while letting persistent
;: intern entries survive scoped compile arenas.
(extern (tl_arena_make) : i64)
(extern (tl_arena_current) : i64)
(extern (tl_region_mark) : i64)
(extern (tl_oob_abort) : never)

(unsafe
  (extern (tl_arena_set [arg0 : i64]) : unit))

(unsafe
  (extern (tl_arena_destroy [arg0 : i64]) : unit))

(unsafe
  (extern (tl_region_reset [arg0 : i64]) : unit))

(define (intern-private-string-length [text : String]) : i64
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_length text)
    (string-length text)))

(define (intern-private-string-ref [text : String] [index : i64]) : char
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_ref text index)
    (string-ref text index)))

(define (intern-private-string-eq [left : String] [right : String]) : bool
  (let
    [left-len : i64
      (cfg
        feature-compiler-private-string-intrinsics
        (__tl_string_length left)
        (intern-private-string-length left))]
    [right-len : i64
      (cfg
        feature-compiler-private-string-intrinsics
        (__tl_string_length right)
        (intern-private-string-length right))]
    (if (not (= left-len right-len))
      false
      (unsafe
        (let
          [lp : (Ptr u8) (string-data (& left))]
          [rp : (Ptr u8) (string-data (& right))]
          (if (= (ptr->int lp) (ptr->int rp))
            true
            (let
              [lw : (Ptr i64) (ptr-cast lp : (Ptr i64))]
              [rw : (Ptr i64) (ptr-cast rp : (Ptr i64))]
              [words : i64 (shr left-len 3)]
              [i : i64 0]
              [same : bool true]
              (begin
                (while (and same (< i words))
                  (if (=
                    (ptr-read (ptr-offset lw i))
                    (ptr-read (ptr-offset rw i)))
                    (set! i (+ i 1))
                    (set! same false)))
                (if same
                  (let
                    [j : i64 (* words 8)]
                    (begin
                      (while (and same (< j left-len))
                        (if (=
                          (cast (ptr-read (ptr-offset lp j)) : i64)
                          (cast (ptr-read (ptr-offset rp j)) : i64))
                          (set! j (+ j 1))
                          (set! same false)))
                      same))
                  false)))))))))

(defmacro (intern-private-string-eq-places [left : Expr] [right : Expr]) : bool
  (cfg
    feature-compiler-private-string-intrinsics
    `(let
      [left-len : i64 (__tl_string_length ,left)]
      [right-len : i64 (__tl_string_length ,right)]
      (if (not (= left-len right-len))
        false
        (unsafe
          (let
            [lp : (Ptr u8) (string-data (& ,left))]
            [rp : (Ptr u8) (string-data (& ,right))]
            (if (= (ptr->int lp) (ptr->int rp))
              true
              (let
                [lw : (Ptr i64) (ptr-cast lp : (Ptr i64))]
                [rw : (Ptr i64) (ptr-cast rp : (Ptr i64))]
                [words : i64 (shr left-len 3)]
                [i : i64 0]
                [same : bool true]
                (begin
                  (while (and same (< i words))
                    (if (=
                      (ptr-read (ptr-offset lw i))
                      (ptr-read (ptr-offset rw i)))
                      (set! i (+ i 1))
                      (set! same false)))
                  (if same
                    (let
                      [j : i64 (* words 8)]
                      (begin
                        (while (and same (< j left-len))
                          (if (=
                            (cast (ptr-read (ptr-offset lp j)) : i64)
                            (cast (ptr-read (ptr-offset rp j)) : i64))
                            (set! j (+ j 1))
                            (set! same false)))
                        same))
                    false))))))))
    `(intern-private-string-eq ,left ,right)))

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
(define intern-pool-first-dot-slots : (Array i64)
  (make-array i64 262144))
(define intern-pool-leading-dot-id-slots : (Array i64)
  (make-array i64 262144))
(define intern-pool-module-id-slots : (Array i64)
  (make-array i64 262144))
(define intern-pool-base-id-slots : (Array i64)
  (make-array i64 262144))
(define intern-pointer-id-slots : (Array i64)
  (make-array i64 1))
(define intern-pointer-key-slots : (Array i64)
  (make-array i64 1))
(define intern-reader-pointer-slots : (Array i64)
  (make-array i64 1))
(define intern-reader-id-slots : (Array i64)
  (make-array i64 1))
(define intern-pool-count : i64
  0)
(define intern-generated-next-id : i64
  (- (intern-capacity) 1))

(define (intern-pool-len) : i64
  intern-pool-count)

;; Identity of the currently installed compatibility intern table. Generation
;; alone is not enough for process-global caches: CompilerDriverState can swap
;; between distinct tables whose per-state generation counters are equal.
(define (intern-active-pool-data-addr) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (array-data intern-pool-slots) : (Ptr u8))))
    : i64))

(define intern-map-slots : (Array InternSlot)
  (make-array InternSlot 262144))

;; Compact read lanes for post-parse lookup. InternCompatState keeps the
;; authoritative enum map; these process-local lanes are rebuilt whenever a
;; state is installed and updated alongside global insertions.
(define intern-map-id-slots : (Array i64)
  (make-array i64 262144))
(define intern-map-hash-slots : (Array i64)
  (make-array i64 262144))
(define intern-map-ready : bool
  false)
(define intern-reset-generation : i64
  0)
(define intern-name-cache-name : String
  "")
(define intern-name-cache-id : i64
  -1)
(define intern-name-cache-ready : bool
  false)
(define intern-slice-cache0-name : String
  "")
(define intern-slice-cache0-id : i64
  -1)
(define intern-slice-cache0-ready : bool
  false)
(define intern-slice-cache1-name : String
  "")
(define intern-slice-cache1-id : i64
  -1)
(define intern-slice-cache1-ready : bool
  false)
(define intern-slice-cache2-name : String
  "")
(define intern-slice-cache2-id : i64
  -1)
(define intern-slice-cache2-ready : bool
  false)
(define intern-slice-cache3-name : String
  "")
(define intern-slice-cache3-id : i64
  -1)
(define intern-slice-cache3-ready : bool
  false)
(define intern-pointer-storage-arena : i64
  (tl_arena_make))
(define intern-persistent-arena : i64
  (tl_arena_make))
(define intern-persistent-arena-floor-mark : i64
  0)
(define intern-persistent-storage-enabled : bool
  false)

;; CompilerDriverState installs its owned pointer indexes before reset. Keep
;; the compatibility globals cheap at process startup, while preserving direct
;; compiler_intern users that reset the default table without a driver state.
(define (intern-pointer-storage-ensure!) : unit
  (if (= (array-length intern-pointer-id-slots) (intern-capacity))
    unit
    (let
      [prev-arena : i64 (tl_arena_current)]
      [_set-arena : unit
        (unsafe
          (tl_arena_set intern-pointer-storage-arena))]
      [pointer-id-slots : (Array i64) (make-array i64 262144)]
      [pointer-key-slots : (Array i64) (make-array i64 262144)]
      [reader-pointer-slots : (Array i64) (make-array i64 262144)]
      [reader-id-slots : (Array i64) (make-array i64 262144)]
      [storage-arena : i64 (tl_arena_current)]
      (begin
        (unsafe
          (tl_arena_set prev-arena))
        (set! intern-pointer-storage-arena storage-arena)
        (set! intern-pointer-id-slots pointer-id-slots)
        (set! intern-pointer-key-slots pointer-key-slots)
        (set! intern-reader-pointer-slots reader-pointer-slots)
        (set! intern-reader-id-slots reader-id-slots)))))

(define (intern-map-read-lanes-rebuild!) : unit
  (let
    [index : i64 0]
    [count : i64 (array-length intern-map-slots)]
    (while (< index count)
      (begin
        (match (array-ref intern-map-slots index)
          [(InternEmpty) (array-set! intern-map-id-slots index 0)]
          [(InternUsed _ id hash)
            (begin
              (array-set! intern-map-id-slots index (+ id 1))
              (array-set! intern-map-hash-slots index hash))])
        (set! index (+ index 1))))))

(define (intern-map-read-lanes-clear!) : unit
  (let
    [index : i64 0]
    [count : i64 (array-length intern-map-id-slots)]
    (while (< index count)
      (begin
        (array-set! intern-map-id-slots index 0)
        (set! index (+ index 1))))))

(defstruct InternCompatState
  (pool-slots (Array String))
  (pool-qualified-slots (Array bool))
  (pool-last-slash-slots (Array i64))
  (pool-first-dot-slots (Array i64))
  (pool-leading-dot-id-slots (Array i64))
  (pool-module-id-slots (Array i64))
  (pool-base-id-slots (Array i64))
  (pointer-id-slots (Array i64))
  (pointer-key-slots (Array i64))
  (reader-pointer-slots (Array i64))
  (reader-id-slots (Array i64))
  (pool-count (Array i64))
  (generated-next-id (Array i64))
  (map-slots (Array InternSlot))
  (map-ready (Array bool))
  (reset-generation (Array i64))
  (persistent-arena (Array i64))
  (persistent-arena-floor-mark (Array i64))
  (persistent-storage-enabled (Array bool)))

(define (intern-compat-state-new) : InternCompatState
  (let
    [pool-count : (Array i64) (make-array i64 1)]
    [generated-next-id : (Array i64) (make-array i64 1)]
    [map-ready : (Array bool) (make-array bool 1)]
    [reset-generation : (Array i64) (make-array i64 1)]
    [persistent-arena : (Array i64) (make-array i64 1)]
    [persistent-arena-floor-mark : (Array i64) (make-array i64 1)]
    [persistent-storage-enabled : (Array bool) (make-array bool 1)]
    (begin
      (array-set! pool-count 0 0)
      (array-set! generated-next-id 0 (- (intern-capacity) 1))
      (array-set! map-ready 0 false)
      (array-set! reset-generation 0 0)
      (array-set! persistent-arena 0 (tl_arena_make))
      (array-set! persistent-arena-floor-mark 0 0)
      (array-set! persistent-storage-enabled 0 false)
      (InternCompatState
        (make-array String 262144)
        (make-array bool 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        pool-count
        generated-next-id
        (make-array InternSlot 262144)
        map-ready
        reset-generation
        persistent-arena
        persistent-arena-floor-mark
        persistent-storage-enabled))))

(define (intern-compat-state-pool-len [state : InternCompatState]) : i64
  (array-ref (struct-get state pool-count) 0))

(define (intern-compat-state-generation [state : InternCompatState]) : i64
  (array-ref (struct-get state reset-generation) 0))

(define (intern-compat-state-pool-data-addr [state : InternCompatState]) : i64
  (cast
    (unsafe
      (ptr->int
        (ptr-cast (array-data (struct-get state pool-slots)) : (Ptr u8))))
    : i64))

(define (intern-compat-state-install! [state : InternCompatState]) : unit
  (let
    [next-map-slots : (Array InternSlot) (struct-get state map-slots)]
    [map-changed : bool
      (not
        (=
          (cast
            (unsafe
              (ptr->int (ptr-cast (array-data intern-map-slots) : (Ptr u8))))
            : i64)
          (cast
            (unsafe
              (ptr->int (ptr-cast (array-data next-map-slots) : (Ptr u8))))
            : i64)))]
    (begin
      (set! intern-pool-slots (struct-get state pool-slots))
      (set! intern-pool-qualified-slots (struct-get state pool-qualified-slots))
      (set!
        intern-pool-last-slash-slots
        (struct-get state pool-last-slash-slots))
      (set! intern-pool-first-dot-slots (struct-get state pool-first-dot-slots))
      (set!
        intern-pool-leading-dot-id-slots
        (struct-get state pool-leading-dot-id-slots))
      (set! intern-pool-module-id-slots (struct-get state pool-module-id-slots))
      (set! intern-pool-base-id-slots (struct-get state pool-base-id-slots))
      (set! intern-pointer-id-slots (struct-get state pointer-id-slots))
      (set! intern-pointer-key-slots (struct-get state pointer-key-slots))
      (set! intern-reader-pointer-slots (struct-get state reader-pointer-slots))
      (set! intern-reader-id-slots (struct-get state reader-id-slots))
      (set! intern-pool-count (array-ref (struct-get state pool-count) 0))
      (set!
        intern-generated-next-id
        (array-ref (struct-get state generated-next-id) 0))
      (set! intern-map-slots next-map-slots)
      (if map-changed
        (if (array-ref (struct-get state map-ready) 0)
          (intern-map-read-lanes-rebuild!)
          (intern-map-read-lanes-clear!))
        unit)
      (set! intern-map-ready (array-ref (struct-get state map-ready) 0))
      (set!
        intern-reset-generation
        (array-ref (struct-get state reset-generation) 0))
      (set! intern-name-cache-ready false)
      (set! intern-slice-cache0-ready false)
      (set! intern-slice-cache1-ready false)
      (set! intern-slice-cache2-ready false)
      (set! intern-slice-cache3-ready false)
      (set!
        intern-persistent-arena
        (array-ref (struct-get state persistent-arena) 0))
      (set!
        intern-persistent-arena-floor-mark
        (array-ref (struct-get state persistent-arena-floor-mark) 0))
      (set!
        intern-persistent-storage-enabled
        (array-ref (struct-get state persistent-storage-enabled) 0)))))

(define (intern-compat-state-capture-from-globals! [state : InternCompatState]) : unit
  (begin
    (array-set! (struct-get state pool-count) 0 intern-pool-count)
    (array-set! (struct-get state generated-next-id) 0 intern-generated-next-id)
    (array-set! (struct-get state map-ready) 0 intern-map-ready)
    (array-set! (struct-get state reset-generation) 0 intern-reset-generation)
    (array-set! (struct-get state persistent-arena) 0 intern-persistent-arena)
    (array-set!
      (struct-get state persistent-arena-floor-mark)
      0
      intern-persistent-arena-floor-mark)
    (array-set!
      (struct-get state persistent-storage-enabled)
      0
      intern-persistent-storage-enabled)))

(define (intern-persistent-storage-enable!) : unit
  (set! intern-persistent-storage-enabled true))

(define (intern-persistent-storage-disable!) : unit
  (set! intern-persistent-storage-enabled false))

(define (intern-persistent-storage-on?) : bool
  intern-persistent-storage-enabled)

(define (intern-persistent-arena-reset!) : unit
  (let
    [old-arena : i64 intern-persistent-arena]
    [new-arena : i64 (tl_arena_make)]
    [prev-arena : i64 (tl_arena_current)]
    (begin
      (set! intern-persistent-arena new-arena)
      (set! intern-persistent-arena-floor-mark 0)
      (if (= prev-arena old-arena)
        (unsafe
          (tl_arena_set new-arena))
        unit)
      (unsafe
        (tl_arena_destroy old-arena))
      (intern-persistent-arena-floor-refresh!))))

(define (intern-persistent-arena-floor-refresh!) : unit
  (let
    [prev-arena : i64 (tl_arena_current)]
    (begin
      (unsafe
        (tl_arena_set intern-persistent-arena))
      (set! intern-persistent-arena-floor-mark (tl_region_mark))
      (unsafe
        (tl_arena_set prev-arena)))))

(define (intern-persistent-arena-floor-ensure!) : unit
  (if (= intern-persistent-arena-floor-mark 0)
    (intern-persistent-arena-floor-refresh!)
    unit))

(define (intern-persistent-arena-reset-to-floor!) : unit
  (let
    [prev-arena : i64 (tl_arena_current)]
    (begin
      (intern-persistent-arena-floor-ensure!)
      (unsafe
        (tl_arena_set intern-persistent-arena)
        (tl_region_reset intern-persistent-arena-floor-mark)
        (tl_arena_set prev-arena)))))

;: Word-at-a-time multiply-mix hash over the raw bytes. The hash only affects
;: bucket placement, never the id a string gets (ids are insertion-ordered),
;: so the function is free to change: byte-at-a-time djb2 was 18.6% of a
;: stage2 self-compile profile before the marker memos and still ~8% after.
;: Eight bytes are folded per step with a wrapping multiply; the byte tail is
;: assembled into one final word. Overflow wraps in i64; the result may be
;: negative, which is fine -- the bucket mask keeps only the low bits.
;; --- compile-profile interning instrumentation ---
;; Deterministic per (compiler, input) counters that drive the redundant-
;; interning elimination work: hash-words counts every string hash (the real
;; cost), and the entry counters attribute those hashes to intern/intern-slice/
;; intern-lookup. `compiler_intern` is import-free, so it only exposes reset and
;; value accessors; the driver (which owns `io`) prints them at compile end.
(cfg
  compile-profile
  (define intern-profile-hash-words-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-intern-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-slice-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-lookup-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-pointer-lookup-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-pointer-hit-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-pointer-probe-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-preserving-lookup-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-generated-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-invalid-str-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-invalid-str-last-id : i64
    0))
(cfg
  compile-profile
  (define intern-profile-invalid-str-detail-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-invalid-str-detail-ids : (Array i64)
    (make-array i64 256)))
(cfg
  compile-profile
  (define intern-profile-source-bytes-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-source-symbol-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-source-symbol-bytes-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-slice-bytes-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-slice-hit-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-slice-miss-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-id-counts : (Array i64)
    (make-array i64 262144)))
(cfg
  compile-profile
  (define intern-profile-id-epochs : (Array i64)
    (make-array i64 262144)))
(cfg
  compile-profile
  (define intern-profile-id-epoch : i64
    1))

(cfg
  compile-profile
  (define (intern-profile-reset!) : unit
    (begin
      (set! intern-profile-hash-words-count 0)
      (set! intern-profile-intern-count 0)
      (set! intern-profile-slice-count 0)
      (set! intern-profile-lookup-count 0)
      (set! intern-profile-pointer-lookup-count 0)
      (set! intern-profile-pointer-hit-count 0)
      (set! intern-profile-pointer-probe-count 0)
      (set! intern-profile-preserving-lookup-count 0)
      (set! intern-profile-generated-count 0)
      (set! intern-profile-invalid-str-count 0)
      (set! intern-profile-invalid-str-last-id 0)
      (set! intern-profile-invalid-str-detail-count 0)
      (set! intern-profile-source-bytes-count 0)
      (set! intern-profile-source-symbol-count 0)
      (set! intern-profile-source-symbol-bytes-count 0)
      (set! intern-profile-slice-bytes-count 0)
      (set! intern-profile-slice-hit-count 0)
      (set! intern-profile-slice-miss-count 0)
      (set! intern-profile-id-epoch (+ intern-profile-id-epoch 1))
      (set! intern-profile-hit-same-obj-count 0)
      (set! intern-profile-hit-diff-obj-count 0)
      (set! intern-profile-miss-count 0))))

(cfg
  compile-profile
  (define (intern-profile-hash-words-value) : i64
    intern-profile-hash-words-count))

(cfg
  compile-profile
  (define (intern-profile-intern-value) : i64
    intern-profile-intern-count))

(cfg
  compile-profile
  (define (intern-profile-slice-value) : i64
    intern-profile-slice-count))

(cfg
  compile-profile
  (define (intern-profile-lookup-value) : i64
    intern-profile-lookup-count))

(cfg
  compile-profile
  (define (intern-profile-pointer-lookup-value) : i64
    intern-profile-pointer-lookup-count))

(cfg
  compile-profile
  (define (intern-profile-pointer-hit-value) : i64
    intern-profile-pointer-hit-count))

(cfg
  compile-profile
  (define (intern-profile-pointer-probe-value) : i64
    intern-profile-pointer-probe-count))

(cfg
  compile-profile
  (define (intern-profile-preserving-lookup-value) : i64
    intern-profile-preserving-lookup-count))

(cfg
  compile-profile
  (define (intern-profile-generated-value) : i64
    intern-profile-generated-count))

(cfg
  compile-profile
  (define (intern-profile-invalid-str-value) : i64
    intern-profile-invalid-str-count))

(cfg
  compile-profile
  (define (intern-profile-invalid-str-last-id-value) : i64
    intern-profile-invalid-str-last-id))

(cfg
  compile-profile
  (define (intern-profile-invalid-str-detail-count-value) : i64
    intern-profile-invalid-str-detail-count))

(cfg
  compile-profile
  (define (intern-profile-invalid-str-detail-id-at [index : i64]) : i64
    (array-ref intern-profile-invalid-str-detail-ids index)))

(cfg
  compile-profile
  (define (intern-profile-source-bytes-value) : i64
    intern-profile-source-bytes-count))

(cfg
  compile-profile
  (define (intern-profile-source-symbol-value) : i64
    intern-profile-source-symbol-count))

(cfg
  compile-profile
  (define (intern-profile-source-symbol-bytes-value) : i64
    intern-profile-source-symbol-bytes-count))

(cfg
  compile-profile
  (define (intern-profile-slice-bytes-value) : i64
    intern-profile-slice-bytes-count))

(cfg
  compile-profile
  (define (intern-profile-slice-hit-value) : i64
    intern-profile-slice-hit-count))

(cfg
  compile-profile
  (define (intern-profile-slice-miss-value) : i64
    intern-profile-slice-miss-count))

(cfg
  compile-profile
  (define (intern-profile-id-value [id : i64]) : i64
    (if (and
      (>= id 0)
      (< id (array-length intern-profile-id-counts))
      (= (array-ref intern-profile-id-epochs id) intern-profile-id-epoch))
      (array-ref intern-profile-id-counts id)
      0)))

(cfg
  compile-profile
  (define (intern-profile-note-id [id : i64]) : unit
    (if (or (< id 0) (>= id (array-length intern-profile-id-counts)))
      unit
      (if (= (array-ref intern-profile-id-epochs id) intern-profile-id-epoch)
        (array-set!
          intern-profile-id-counts
          id
          (+ (array-ref intern-profile-id-counts id) 1))
        (begin
          (array-set! intern-profile-id-epochs id intern-profile-id-epoch)
          (array-set! intern-profile-id-counts id 1))))))

(cfg
  compile-profile
  (define (intern-profile-hit-same-obj-value) : i64
    intern-profile-hit-same-obj-count))

(cfg
  compile-profile
  (define (intern-profile-hit-diff-obj-value) : i64
    intern-profile-hit-diff-obj-count))

(cfg
  compile-profile
  (define (intern-profile-miss-value) : i64
    intern-profile-miss-count))

(cfg
  compile-profile
  (define (intern-profile-note-intern) : unit
    (set! intern-profile-intern-count (+ intern-profile-intern-count 1))))

(cfg
  compile-profile
  (define (intern-profile-note-generated) : unit
    (set! intern-profile-generated-count (+ intern-profile-generated-count 1))))

(cfg
  compile-profile
  (define (intern-profile-note-source-bytes [len : i64]) : unit
    (set!
      intern-profile-source-bytes-count
      (+ intern-profile-source-bytes-count len))))

(cfg
  compile-profile
  (define (intern-profile-note-slice [len : i64]) : unit
    (begin
      (set! intern-profile-slice-count (+ intern-profile-slice-count 1))
      (set!
        intern-profile-slice-bytes-count
        (+ intern-profile-slice-bytes-count len)))))

(cfg
  compile-profile
  (define (intern-profile-note-lookup) : unit
    (set! intern-profile-lookup-count (+ intern-profile-lookup-count 1))))

;; --- compile-profile interning instrumentation: hit classification ---
;; `hit_same_obj` counts intern() hits where the input String is the same object
;; the pool already stores (pointer-identical) -- the case id-threading
;; eliminates (no re-intern at all). `hit_diff_obj` counts hits on a freshly-built
;; object with the same content (mangled-name rebuilds) -- the per-id memo
;; target. `miss` counts genuine first-time insertions. These cfg-gated counters
;; drive the systematic id-threading work: the goal is to drive intern_calls
;; (and these hits) toward only the genuine first-time `miss` count.
(cfg
  compile-profile
  (define intern-profile-hit-same-obj-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-hit-diff-obj-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-miss-count : i64
    0))

(cfg
  compile-profile
  (define (intern-profile-string-data-ptr [s : String]) : i64
    (cast
      (unsafe
        (ptr->int (string-data (& s))))
      : i64)))

(define (intern-hash-words [src : (Ptr u8)] [start : i64] [len : i64]) : i64
  (let
    [h : i64 (+ 5381 len)]
    [i : i64 0]
    [words : i64 (- len 7)]
    (begin
      (cfg
        compile-profile
        (set!
          intern-profile-hash-words-count
          (+
            intern-profile-hash-words-count
            (+
              (/ len 8)
              (if (= (% len 8) 0)
                0
                1)))))
      (while (< i words)
        (begin
          (set!
            h
            (*
              (bit-xor
                h
                (unsafe
                  (ptr-read (ptr-cast (ptr-offset src (+ start i)) : (Ptr i64)))))
              -7046029254386353131))
          (set! i (+ i 8))))
      (let
        [tail : i64 0]
        (begin
          (while (< i len)
            (begin
              (set!
                tail
                (+
                  (* tail 256)
                  (cast
                    (unsafe
                      (ptr-read (ptr-offset src (+ start i))))
                    : i64)))
              (set! i (+ i 1))))
          (set! h (* (bit-xor h tail) -7046029254386353131))
          (bit-xor h (cast (shr (cast h : u64) 29) : i64)))))))

(define (intern-hash [s : String]) : i64
  (intern-hash-words
    (unsafe
      (string-data (& s)))
    0
    (cfg
      feature-compiler-private-string-intrinsics
      (__tl_string_length s)
      (intern-private-string-length s))))

;: Hash over a source slice without first allocating a substring.
(define (intern-hash-slice [s : String] [start : i64] [len : i64]) : i64
  (intern-hash-words
    (unsafe
      (string-data (& s)))
    start
    len))

;: Mask `hash` into `[0, capacity)`; capacity is a power of two.
(define (intern-bucket [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

(define (intern-string-data-pointer [name : String]) : i64
  (cast
    (unsafe
      (ptr->int (string-data (& name))))
    : i64))

(define (intern-pointer-id-bucket [ptr : i64] [len : i64] [capacity : i64]) : i64
  (intern-bucket (bit-xor (shr ptr 3) (* len -7046029254386353131)) capacity))

(define (intern-pointer-id-bits) : i64
  19)

(define (intern-pointer-id-mask) : i64
  524287)

(define (intern-pointer-slot-pack [id : i64] [len : i64]) : i64
  (bit-or (shl len (intern-pointer-id-bits)) (+ id 1)))

(define (intern-pointer-slot-id [slot : i64]) : i64
  (- (bit-and slot (intern-pointer-id-mask)) 1))

(define (intern-pointer-slot-len [slot : i64]) : i64
  (shr slot (intern-pointer-id-bits)))

;; Slots pack length and id + 1 so zero remains the empty sentinel. Keeping the
;; pointer key beside the packed value avoids reloading the candidate String
;; from the pool on every post-parse probe.
(define (intern-pointer-id-lookup [name : String]) : i64
  (let
    [needle : i64 (intern-string-data-pointer name)]
    [needle-len : i64 (intern-private-string-length name)]
    [ids : (Ptr i64)
      (unsafe
        (ptr-cast (array-data intern-pointer-id-slots) : (Ptr i64)))]
    [keys : (Ptr i64)
      (unsafe
        (ptr-cast (array-data intern-pointer-key-slots) : (Ptr i64)))]
    [mask : i64 262143]
    [cursor : i64
      (bit-and
        (bit-xor (shr needle 3) (* needle-len -7046029254386353131))
        mask)]
    (begin
      (cfg
        compile-profile
        (set!
          intern-profile-pointer-lookup-count
          (+ intern-profile-pointer-lookup-count 1)))
      (while true
        (let
          [stored : i64
            (unsafe
              (ptr-read (ptr-offset ids cursor)))]
          (begin
            (cfg
              compile-profile
              (set!
                intern-profile-pointer-probe-count
                (+ intern-profile-pointer-probe-count 1)))
            (if (= stored 0)
              (return -1)
              (let
                [id : i64 (- (bit-and stored 524287) 1)]
                (if (and
                  (=
                    (unsafe
                      (ptr-read (ptr-offset keys cursor)))
                    needle)
                  (= (shr stored 19) needle-len))
                  (begin
                    (cfg
                      compile-profile
                      (set!
                        intern-profile-pointer-hit-count
                        (+ intern-profile-pointer-hit-count 1)))
                    (return id))
                  (set! cursor (bit-and (+ cursor 1) mask))))))))
      -1)))

(define (intern-pointer-id-record! [name : String] [id : i64]) : unit
  (let
    [needle : i64 (intern-string-data-pointer name)]
    [needle-len : i64 (intern-private-string-length name)]
    [capacity : i64 (array-length intern-pointer-id-slots)]
    [cursor : i64 (intern-pointer-id-bucket needle needle-len capacity)]
    [steps : i64 0]
    (begin
      (while (< steps capacity)
        (let
          [stored : i64 (array-ref intern-pointer-id-slots cursor)]
          (if (= stored 0)
            (begin
              (array-set! intern-pointer-key-slots cursor needle)
              (array-set!
                intern-pointer-id-slots
                cursor
                (intern-pointer-slot-pack id needle-len))
              (return unit))
            (let
              [existing-id : i64 (intern-pointer-slot-id stored)]
              (if (and
                (= (array-ref intern-pointer-key-slots cursor) needle)
                (= (intern-pointer-slot-len stored) needle-len))
                (begin
                  ;; Source identity wins over an opaque generated identity.
                  ;; Among generated identities, retain the most recent id,
                  ;; matching the old high-id linear scan.
                  (if (or
                    (< id intern-pool-count)
                    (not (< existing-id intern-pool-count)))
                    (array-set!
                      intern-pointer-id-slots
                      cursor
                      (intern-pointer-slot-pack id needle-len))
                    unit)
                  (return unit))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))))))
      unit)))

;; Persistence replaces a pool string's backing allocation. Leave the packed
;; slot occupied so its probe cluster remains valid, but clear the pointer key
;; before that allocation can be reused for another string.
(define (intern-pointer-id-retire! [name : String] [id : i64]) : unit
  (let
    [needle : i64 (intern-string-data-pointer name)]
    [needle-len : i64 (intern-private-string-length name)]
    [capacity : i64 (array-length intern-pointer-id-slots)]
    [cursor : i64 (intern-pointer-id-bucket needle needle-len capacity)]
    [steps : i64 0]
    (begin
      (while (< steps capacity)
        (let
          [stored : i64 (array-ref intern-pointer-id-slots cursor)]
          (if (= stored 0)
            (return unit)
            (if (and
              (= (array-ref intern-pointer-key-slots cursor) needle)
              (= (intern-pointer-slot-len stored) needle-len)
              (= (intern-pointer-slot-id stored) id))
              (begin
                (array-set! intern-pointer-key-slots cursor 0)
                (return unit))
              (begin
                (set! cursor (intern-bucket (+ cursor 1) capacity))
                (set! steps (+ steps 1)))))))
      unit)))

;; Reader compatibility Strings can be aliases rather than canonical pool
;; objects, so their current provenance is a separate last-writer-wins index.
;; The arrays live in InternCompatState and are cleared with the intern table.
(define (intern-reader-pointer-id-lookup [name : String]) : i64
  (if intern-map-ready
    (let
      [needle : i64 (intern-string-data-pointer name)]
      [capacity : i64 (array-length intern-reader-id-slots)]
      [cursor : i64 (intern-pointer-id-bucket needle 0 capacity)]
      [steps : i64 0]
      (begin
        (while (< steps capacity)
          (let
            [stored : i64 (array-ref intern-reader-id-slots cursor)]
            (if (= stored 0)
              (return -1)
              (if (= (array-ref intern-reader-pointer-slots cursor) needle)
                (return (- stored 1))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1)))))))
        -1))
    -1))

(define (intern-reader-pointer-id-record! [name : String] [id : i64]) : unit
  (let
    [needle : i64 (intern-string-data-pointer name)]
    [capacity : i64 (array-length intern-reader-id-slots)]
    [cursor : i64 (intern-pointer-id-bucket needle 0 capacity)]
    [steps : i64 0]
    (begin
      (while (< steps capacity)
        (let
          [stored : i64 (array-ref intern-reader-id-slots cursor)]
          (if (or
            (= stored 0)
            (= (array-ref intern-reader-pointer-slots cursor) needle))
            (begin
              (array-set! intern-reader-pointer-slots cursor needle)
              (array-set! intern-reader-id-slots cursor (+ id 1))
              (return unit))
            (begin
              (set! cursor (intern-bucket (+ cursor 1) capacity))
              (set! steps (+ steps 1))))))
      unit)))

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

(define (intern-persistent-substring [text : String] [start : i64] [len : i64]) : String
  (let
    [prev-arena : i64 (tl_arena_current)]
    (if (= prev-arena intern-persistent-arena)
      (intern-substring text start len)
      (let
        [out : String
          (begin
            (unsafe
              (tl_arena_set intern-persistent-arena))
            (let
              [copied : String (intern-substring text start len)]
              (begin
                (unsafe
                  (tl_arena_set prev-arena))
                copied)))]
        out))))

(define (intern-persistent-copy [text : String]) : String
  (if (= (tl_arena_current) intern-persistent-arena)
    text
    (intern-persistent-substring
      text
      0
      (cfg
        feature-compiler-private-string-intrinsics
        (__tl_string_length text)
        (intern-private-string-length text)))))

;: Reserve a source id from the low end of the shared pool. Generated ids grow
;: down from the high end, so neither kind can silently overwrite the other.
(define (intern-source-id-allocate!) : i64
  (if (> intern-pool-count intern-generated-next-id)
    (tl_oob_abort)
    (let
      [id : i64 intern-pool-count]
      (begin
        (set! intern-pool-count (+ id 1))
        id))))

(define (intern-generated-id-allocate!) : i64
  (if (< intern-generated-next-id intern-pool-count)
    (tl_oob_abort)
    (let
      [id : i64 intern-generated-next-id]
      (begin
        (set! intern-generated-next-id (- id 1))
        id))))

(define (intern-generated-id-active? [id : i64]) : bool
  (and
    (>= id intern-pool-count)
    (> id intern-generated-next-id)
    (< id (intern-capacity))))

;; Preserve a generated identity when a downstream representation owns a
;; distinct display String. Pointer identity keeps equal spellings distinct.
(define (intern-register-generated-display-id! [name : String] [id : i64]) : unit
  (if (intern-generated-id-active? id)
    (intern-pointer-id-record! name id)
    unit))

(define (intern-private-last-slash [name : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (intern-private-string-length name)]
    [slash : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (= (intern-private-string-ref name i) '/')
            (set! slash i)
            unit)
          (set! i (+ i 1))))
      slash)))

(define (intern-private-first-dot [name : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (intern-private-string-length name)]
    [dot : i64 -1]
    (begin
      (while (and (< i n) (< dot 0))
        (begin
          (if (= (intern-private-string-ref name i) '.')
            (set! dot i)
            unit)
          (set! i (+ i 1))))
      dot)))

(define (intern-generated-name-store
  [name : String]
  [qualified : bool]
  [module-id : i64]
  [base-id : i64]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (cfg compile-profile (intern-profile-note-generated))
    (let
      [persistent-name : String (intern-persistent-copy name)]
      [id : i64 (intern-generated-id-allocate!)]
      (begin
        (array-set! intern-pool-slots id persistent-name)
        (intern-pointer-id-record! persistent-name id)
        (array-set! intern-pool-qualified-slots id qualified)
        (array-set!
          intern-pool-last-slash-slots
          id
          (if qualified
            (intern-private-last-slash persistent-name)
            -1))
        (array-set! intern-pool-first-dot-slots id -1)
        (array-set! intern-pool-leading-dot-id-slots id -1)
        (array-set! intern-pool-module-id-slots id module-id)
        (array-set!
          intern-pool-base-id-slots
          id
          (if qualified
            base-id
            id))
        id))))

;: Allocate an opaque generated symbol. Display punctuation is intentionally
;: not interpreted: hygiene locals may contain `/` without being qualified.
(define (intern-generated-name [name : String]) : i64
  (intern-generated-name-store name false -1 -1))

;: Allocate a generated qualified symbol without hashing its display spelling.
;: The caller supplies the already-known structural module and base identities.
(define (intern-generated-qualified-name
  [name : String]
  [module-id : i64]
  [base-id : i64]) : i64
  (intern-generated-name-store name true module-id base-id))

;: Allocate a generated dotted symbol such as `Type.Variant`. The caller
;: supplies the source identity for the segment before the first dot, avoiding
;: a lookup or insertion for either the prefix or the combined spelling.
(define (intern-generated-dotted-name [name : String] [leading-dot-id : i64]) : i64
  (let
    [first-dot : i64 (intern-private-first-dot name)]
    (if (or (< first-dot 1) (< leading-dot-id 0))
      (tl_oob_abort)
      (let
        [id : i64 (intern-generated-name-store name false -1 -1)]
        (begin
          (array-set! intern-pool-first-dot-slots id first-dot)
          (array-set! intern-pool-leading-dot-id-slots id leading-dot-id)
          id)))))

(define (intern-persist-range! [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (let
      [name : String (array-ref intern-pool-slots index)]
      [persistent-name : String (intern-persistent-copy name)]
      (begin
        (intern-pointer-id-retire! name index)
        (array-set! intern-pool-slots index persistent-name)
        (intern-pointer-id-record! persistent-name index)
        (intern-persist-range! (+ index 1) count)))))

(define (intern-string-slice-eq?
  [name : String]
  [text : String]
  [start : i64]
  [len : i64]) : bool
  (if (=
    (cfg
      feature-compiler-private-string-intrinsics
      (__tl_string_length name)
      (intern-private-string-length name))
    len)
    (let
      [name-ptr : (Ptr u8)
        (unsafe
          (string-data (& name)))]
      [text-ptr : (Ptr u8)
        (unsafe
          (string-data (& text)))]
      [i : i64 0]
      [ok : bool true]
      (begin
        (while (and (< i len) ok)
          (begin
            (if (=
              (unsafe
                (ptr-read (ptr-offset name-ptr i)))
              (unsafe
                (ptr-read (ptr-offset text-ptr (+ start i)))))
              unit
              (set! ok false))
            (set! i (+ i 1))))
        ok))
    false))

(define (intern-record-qualified-metadata [id : i64] [name : String]) : unit
  (let
    [i : i64 0]
    [n : i64
      (cfg
        feature-compiler-private-string-intrinsics
        (__tl_string_length name)
        (intern-private-string-length name))]
    [slash : i64 -1]
    [dot : i64 -1]
    (begin
      (while (< i n)
        (let
          [c : char
            (cfg
              feature-compiler-private-string-intrinsics
              (__tl_string_ref name i)
              (intern-private-string-ref name i))]
          (begin
            (if (= c '/')
              (set! slash i)
              unit)
            (if (and (< dot 0) (= c '.'))
              (set! dot i)
              unit)
            (set! i (+ i 1)))))
      (array-set! intern-pool-last-slash-slots id slash)
      (array-set! intern-pool-first-dot-slots id dot)
      (array-set!
        intern-pool-leading-dot-id-slots
        id
        (if (< dot 0)
          -1
          (intern-slice name 0 dot)))
      (if (< slash 0)
        (begin
          (array-set! intern-pool-qualified-slots id false)
          (array-set! intern-pool-module-id-slots id -1)
          (array-set!
            intern-pool-base-id-slots
            id
            (if (< dot 0)
              id
              (intern-slice name (+ dot 1) (- n (+ dot 1))))))
        (let
          [base-start : i64 (+ slash 1)]
          (begin
            (array-set! intern-pool-qualified-slots id true)
            (array-set!
              intern-pool-module-id-slots
              id
              (intern-slice name 0 slash))
            (array-set!
              intern-pool-base-id-slots
              id
              (intern-slice name base-start (- n base-start)))))))))

;: Set slots `[index, count)` to InternEmpty.
(define (intern-fill-empty [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! intern-map-slots index (InternEmpty))
      (array-set! intern-map-id-slots index 0)
      (intern-fill-empty (+ index 1) count))))

(define (intern-fill-pointer-id-empty [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! intern-pointer-id-slots index 0)
      (intern-fill-pointer-id-empty (+ index 1) count))))

(define (intern-fill-reader-id-empty [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! intern-reader-id-slots index 0)
      (intern-fill-reader-id-empty (+ index 1) count))))

(define (intern-reset-name-cache!) : unit
  (set! intern-name-cache-ready false))

(define (intern-name-cache-record [name : String] [id : i64]) : unit
  (begin
    (set! intern-name-cache-name name)
    (set! intern-name-cache-id id)
    (set! intern-name-cache-ready true)))

(define (intern-reset-slice-cache!) : unit
  (begin
    (intern-reset-name-cache!)
    (set! intern-slice-cache0-ready false)
    (set! intern-slice-cache1-ready false)
    (set! intern-slice-cache2-ready false)
    (set! intern-slice-cache3-ready false)))

(define (intern-map-insert-existing-from
  [name : String]
  [id : i64]
  [hash : i64]
  [cursor : i64]
  [steps : i64]
  [capacity : i64]) : unit
  (if (>= steps capacity)
    unit
    (match (array-ref intern-map-slots cursor)
      [(InternEmpty)
        (begin
          (array-set! intern-map-slots cursor (InternUsed name id hash))
          (array-set! intern-map-id-slots cursor (+ id 1))
          (array-set! intern-map-hash-slots cursor hash))]
      [_
        (intern-map-insert-existing-from
          name
          id
          hash
          (intern-bucket (+ cursor 1) capacity)
          (+ steps 1)
          capacity)])))

(define (intern-map-insert-existing! [id : i64]) : unit
  (let
    [name : String (array-ref intern-pool-slots id)]
    [hash : i64 (intern-hash name)]
    [capacity : i64 (array-length intern-map-slots)]
    (begin
      (intern-map-insert-existing-from
        name
        id
        hash
        (intern-bucket hash capacity)
        0
        capacity)
      (intern-pointer-id-record! name id))))

(define (intern-map-rebuild-prefix [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (intern-map-insert-existing! index)
      (intern-map-rebuild-prefix (+ index 1) count))))

;: Reset the intern table for a fresh compile and (re)initialize the dedup slots
;: to Empty. `make-array` does not produce valid `Empty` enum slots, so the fill
;: is mandatory before the first probe; this runs it once (idempotent).
(define (intern-reset!) : unit
  (begin
    (intern-pointer-storage-ensure!)
    (set! intern-pool-count 0)
    (set! intern-generated-next-id (- (intern-capacity) 1))
    (intern-fill-empty 0 (array-length intern-map-slots))
    (intern-fill-pointer-id-empty 0 (array-length intern-pointer-id-slots))
    (intern-fill-reader-id-empty 0 (array-length intern-reader-id-slots))
    (intern-reset-slice-cache!)
    (set! intern-reset-generation (+ intern-reset-generation 1))
    (set! intern-map-ready true)))

(define (intern-reset-to! [mark : i64]) : unit
  (begin
    (intern-pointer-storage-ensure!)
    (set! intern-pool-count mark)
    (set! intern-generated-next-id (- (intern-capacity) 1))
    (intern-fill-empty 0 (array-length intern-map-slots))
    (intern-fill-pointer-id-empty 0 (array-length intern-pointer-id-slots))
    (intern-fill-reader-id-empty 0 (array-length intern-reader-id-slots))
    (intern-map-rebuild-prefix 0 mark)
    (intern-reset-slice-cache!)
    (set! intern-reset-generation (+ intern-reset-generation 1))
    (set! intern-map-ready true)))

(define (intern-slice-cache-lookup [text : String] [start : i64] [len : i64]) : i64
  (begin
    (when
      (and
        intern-slice-cache0-ready
        (intern-string-slice-eq? intern-slice-cache0-name text start len))
      (return intern-slice-cache0-id))
    (when
      (and
        intern-slice-cache1-ready
        (intern-string-slice-eq? intern-slice-cache1-name text start len))
      (return intern-slice-cache1-id))
    (when
      (and
        intern-slice-cache2-ready
        (intern-string-slice-eq? intern-slice-cache2-name text start len))
      (return intern-slice-cache2-id))
    (when
      (and
        intern-slice-cache3-ready
        (intern-string-slice-eq? intern-slice-cache3-name text start len))
      (return intern-slice-cache3-id))
    -1))

(define (intern-slice-cache-record [name : String] [id : i64]) : unit
  (if (and intern-slice-cache0-ready (= intern-slice-cache0-id id))
    unit
    (begin
      (set! intern-slice-cache3-name intern-slice-cache2-name)
      (set! intern-slice-cache3-id intern-slice-cache2-id)
      (set! intern-slice-cache3-ready intern-slice-cache2-ready)
      (set! intern-slice-cache2-name intern-slice-cache1-name)
      (set! intern-slice-cache2-id intern-slice-cache1-id)
      (set! intern-slice-cache2-ready intern-slice-cache1-ready)
      (set! intern-slice-cache1-name intern-slice-cache0-name)
      (set! intern-slice-cache1-id intern-slice-cache0-id)
      (set! intern-slice-cache1-ready intern-slice-cache0-ready)
      (set! intern-slice-cache0-name name)
      (set! intern-slice-cache0-id id)
      (set! intern-slice-cache0-ready true))))

;: Intern `name`, returning its stable i64 id. Equal strings map to equal ids.
;: Lazily initializes the dedup table so callers need not order intern-reset!.
(define (intern [name : String]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (when
      (and
        intern-name-cache-ready
        (intern-private-string-eq-places intern-name-cache-name name))
      (return intern-name-cache-id))
    (cfg compile-profile (intern-profile-note-intern))
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
                [persistent-name : String
                  (if intern-persistent-storage-enabled
                    (intern-persistent-copy name)
                    name)]
                [id : i64 (intern-source-id-allocate!)]
                (begin
                  (cfg
                    compile-profile
                    (set!
                      intern-profile-miss-count
                      (+ intern-profile-miss-count 1)))
                  (array-set! intern-pool-slots id persistent-name)
                  (intern-pointer-id-record! persistent-name id)
                  (array-set!
                    intern-map-slots
                    cursor
                    (InternUsed persistent-name id hash))
                  (array-set! intern-map-id-slots cursor (+ id 1))
                  (array-set! intern-map-hash-slots cursor hash)
                  (intern-record-qualified-metadata id persistent-name)
                  (intern-name-cache-record persistent-name id)
                  (set! out id)
                  (set! done true)))]
            [(InternUsed slot-key slot-id slot-hash)
              (if (if (= slot-hash hash)
                (intern-private-string-eq-places slot-key name)
                false)
                (begin
                  (intern-name-cache-record slot-key slot-id)
                  (cfg
                    compile-profile
                    (if (=
                      (intern-profile-string-data-ptr name)
                      (intern-profile-string-data-ptr slot-key))
                      (set!
                        intern-profile-hit-same-obj-count
                        (+ intern-profile-hit-same-obj-count 1))
                      (set!
                        intern-profile-hit-diff-obj-count
                        (+ intern-profile-hit-diff-obj-count 1))))
                  (set! out slot-id)
                  (set! done true))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))]))
        (begin
          (cfg compile-profile (intern-profile-note-id out))
          out)))))

;: Intern a source slice without allocating unless the slice is a new name.
(define (intern-slice [text : String] [start : i64] [len : i64]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (cfg compile-profile (intern-profile-note-slice len))
    (let
      [cached : i64 (intern-slice-cache-lookup text start len)]
      (if (>= cached 0)
        (begin
          (cfg
            compile-profile
            (set!
              intern-profile-slice-hit-count
              (+ intern-profile-slice-hit-count 1)))
          cached)
        (let
          [capacity : i64 (array-length intern-map-slots)]
          [hash : i64 (intern-hash-slice text start len)]
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
                    [name : String
                      (if intern-persistent-storage-enabled
                        (intern-persistent-substring text start len)
                        (intern-substring text start len))]
                    [id : i64 (intern-source-id-allocate!)]
                    (begin
                      (cfg
                        compile-profile
                        (set!
                          intern-profile-slice-miss-count
                          (+ intern-profile-slice-miss-count 1)))
                      (array-set! intern-pool-slots id name)
                      (intern-pointer-id-record! name id)
                      (array-set!
                        intern-map-slots
                        cursor
                        (InternUsed name id hash))
                      (array-set! intern-map-id-slots cursor (+ id 1))
                      (array-set! intern-map-hash-slots cursor hash)
                      (intern-record-qualified-metadata id name)
                      (intern-slice-cache-record name id)
                      (set! out id)
                      (set! done true)))]
                [(InternUsed slot-key slot-id slot-hash)
                  (if (if (= slot-hash hash)
                    (intern-string-slice-eq? slot-key text start len)
                    false)
                    (begin
                      (cfg
                        compile-profile
                        (set!
                          intern-profile-slice-hit-count
                          (+ intern-profile-slice-hit-count 1)))
                      (intern-slice-cache-record slot-key slot-id)
                      (set! out slot-id)
                      (set! done true))
                    (begin
                      (set! cursor (intern-bucket (+ cursor 1) capacity))
                      (set! steps (+ steps 1))))]))
            out))))))

;: Lexer-only entry point. Keeping source-token volume separate from internal
;: metadata slices makes the expected parse-time intern count measurable.
(define (intern-source-slice [text : String] [start : i64] [len : i64]) : i64
  (begin
    (cfg
      compile-profile
      (begin
        (set!
          intern-profile-source-symbol-count
          (+ intern-profile-source-symbol-count 1))
        (set!
          intern-profile-source-symbol-bytes-count
          (+ intern-profile-source-symbol-bytes-count len))))
    (intern-slice text start len)))

;: Look up an already-interned name without mutating the table. This lets later
;: compiler phases use id-keyed indexes without interning backend-generated
;: probe strings as a side effect.
(define (intern-lookup-content [name : String]) : InternLookup
  (if intern-map-ready
    (let
      [capacity : i64 (array-length intern-map-id-slots)]
      [hash : i64 (intern-hash name)]
      [mask : i64 (- capacity 1)]
      [cursor : i64 (bit-and hash mask)]
      [steps : i64 0]
      [ids : (Ptr i64)
        (unsafe
          (ptr-cast (array-data intern-map-id-slots) : (Ptr i64)))]
      [hashes : (Ptr i64)
        (unsafe
          (ptr-cast (array-data intern-map-hash-slots) : (Ptr i64)))]
      (begin
        (while (< steps capacity)
          (let
            [stored : i64
              (unsafe
                (ptr-read (ptr-offset ids cursor)))]
            (if (= stored 0)
              (return (InternLookupMissing))
              (let
                [slot-id : i64 (- stored 1)]
                (if (and
                  (=
                    (unsafe
                      (ptr-read (ptr-offset hashes cursor)))
                    hash)
                  (intern-private-string-eq-places
                    (array-ref intern-pool-slots slot-id)
                    name))
                  (return (InternLookupFound slot-id))
                  (begin
                    (set! cursor (bit-and (+ cursor 1) mask))
                    (set! steps (+ steps 1))))))))
        (InternLookupMissing)))
    (InternLookupMissing)))

(define (intern-lookup [name : String]) : InternLookup
  (if intern-map-ready
    (begin
      (cfg compile-profile (intern-profile-note-lookup))
      (let
        [pointer-id : i64 (intern-pointer-id-lookup name)]
        (if (and (>= pointer-id 0) (< pointer-id intern-pool-count))
          (InternLookupFound pointer-id)
          (intern-lookup-content name))))
    (InternLookupMissing)))

(define (intern-lookup-preserving-generated-id-or
  [name : String]
  [fallback : i64]) : i64
  (if intern-map-ready
    (let
      [pointer-id : i64 (intern-pointer-id-lookup name)]
      (begin
        (cfg compile-profile (intern-profile-note-lookup))
        (cfg
          compile-profile
          (set!
            intern-profile-preserving-lookup-count
            (+ intern-profile-preserving-lookup-count 1)))
        (if (>= pointer-id 0)
          pointer-id
          (match (intern-lookup-content name)
            [(InternLookupFound id) id]
            [(InternLookupMissing) fallback]))))
    fallback))

;: Preserve the identity of a generated symbol when a compatibility boundary
;: temporarily exposes only its display String. Generated symbols are not in
;: the hash table because equal display spellings can intentionally denote
;: distinct identities, so only pointer identity is valid for this fallback.
(define (intern-lookup-preserving-generated-id [name : String]) : InternLookup
  (if intern-map-ready
    (let
      [pointer-id : i64 (intern-pointer-id-lookup name)]
      (begin
        (cfg compile-profile (intern-profile-note-lookup))
        (cfg
          compile-profile
          (set!
            intern-profile-preserving-lookup-count
            (+ intern-profile-preserving-lookup-count 1)))
        (if (>= pointer-id 0)
          (InternLookupFound pointer-id)
          (intern-lookup-content name))))
    (InternLookupMissing)))

;: Recover the original String for an interned id.
(define (intern-str [id : i64]) : String
  (cfg
    compile-profile
    (if (or (< id 0) (>= id (array-length intern-pool-slots)))
      (begin
        (if (<
          intern-profile-invalid-str-detail-count
          (array-length intern-profile-invalid-str-detail-ids))
          (array-set!
            intern-profile-invalid-str-detail-ids
            intern-profile-invalid-str-detail-count
            id)
          unit)
        (set!
          intern-profile-invalid-str-detail-count
          (+ intern-profile-invalid-str-detail-count 1))
        (set!
          intern-profile-invalid-str-count
          (+ intern-profile-invalid-str-count 1))
        (set! intern-profile-invalid-str-last-id id)
        "<invalid-intern-id>")
      (array-ref intern-pool-slots id))
    (array-ref intern-pool-slots id)))

(define (intern-generation) : i64
  intern-reset-generation)

;: Identity of the currently installed intern pool. Compat states may have the
;: same generation, so generation-aware side caches must include this value.
(define (intern-pool-data-addr) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (array-data intern-pool-slots) : (Ptr u8))))
    : i64))

(define (intern-qualified? [id : i64]) : bool
  (array-ref intern-pool-qualified-slots id))

(define (intern-qualified-last-slash [id : i64]) : i64
  (array-ref intern-pool-last-slash-slots id))

(define (intern-first-dot [id : i64]) : i64
  (array-ref intern-pool-first-dot-slots id))

(define (intern-leading-dot-id [id : i64]) : i64
  (array-ref intern-pool-leading-dot-id-slots id))

;; Source dotted names retain the suffix after their first dot in the base-id
;; slot. Each suffix is interned while the source token is first recorded, so
;; later phases can recover every segment without slicing or interning.
(define (intern-dotted-tail-id [id : i64]) : i64
  (let
    [base-id : i64
      (if (intern-qualified? id)
        (intern-qualified-base-id id)
        id)]
    (if (< (intern-first-dot base-id) 0)
      -1
      (let
        [tail-id : i64 (array-ref intern-pool-base-id-slots base-id)]
        (if (= tail-id base-id)
          -1
          tail-id)))))

(define (intern-dotted-final-id [id : i64]) : i64
  (let
    [current : i64
      (if (intern-qualified? id)
        (intern-qualified-base-id id)
        id)]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [tail-id : i64 (intern-dotted-tail-id current)]
          (if (< tail-id 0)
            (set! done true)
            (set! current tail-id))))
      current)))

(define (intern-dotted? [id : i64]) : bool
  (>= (intern-first-dot id) 0))

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

(define (intern-name-first-dot [name : String]) : i64
  (intern-first-dot (intern name)))

(define (intern-name-dotted? [name : String]) : bool
  (intern-dotted? (intern name)))

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
    (= (intern-qualified? id) qualified)
    (intern-private-string-eq (intern-qualified-module id) module-name)
    (intern-private-string-eq (intern-qualified-base id) base-name)))

(define (intern-generated-name-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [source-id : i64 (intern "generated-source-anchor")]
      [module-id : i64 (intern "generated-module")]
      [base-id : i64 (intern "generated-base")]
      [source-len : i64 (intern-pool-len)]
      [home : i64 (tl_arena_current)]
      [scratch : i64 (tl_arena_make)]
      [opaque-id : i64
        (begin
          (unsafe
            (tl_arena_set scratch))
          (let
            [temporary : String (intern-substring "xxhygiene/localyy" 2 13)]
            [id : i64 (intern-generated-name temporary)]
            (begin
              (unsafe
                (tl_arena_set home))
              (unsafe
                (tl_arena_destroy scratch))
              id)))]
      [opaque-again-id : i64 (intern-generated-name "hygiene/local")]
      [duplicate-display-id : i64
        (intern-generated-name
          (intern-substring "xxgenerated-source-anchorzz" 2 23))]
      [qualified-id : i64
        (intern-generated-qualified-name
          "generated-module/generated-base"
          module-id
          base-id)]
      [dotted-id : i64
        (intern-generated-dotted-name "generated-base.Variant" base-id)]
      [dotted-name : String (intern-str dotted-id)]
      [ok : bool true]
      (begin
        (unless (= (intern-pool-len) source-len) (set! ok false))
        (unless (= opaque-id (- (intern-capacity) 1)) (set! ok false))
        (unless (= opaque-again-id (- (intern-capacity) 2)) (set! ok false))
        (unless
          (= duplicate-display-id (- (intern-capacity) 3))
          (set! ok false))
        (unless (= qualified-id (- (intern-capacity) 4)) (set! ok false))
        (unless (= dotted-id (- (intern-capacity) 5)) (set! ok false))
        (unless (not (= opaque-id opaque-again-id)) (set! ok false))
        (unless
          (intern-private-string-eq (intern-str opaque-id) "hygiene/local")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok?
            opaque-id
            false
            -1
            ""
            "hygiene/local")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok?
            qualified-id
            true
            16
            "generated-module"
            "generated-base")
          (set! ok false))
        (unless (= (intern-first-dot dotted-id) 14) (set! ok false))
        (unless (= (intern-leading-dot-id dotted-id) base-id) (set! ok false))
        (unless (intern-dotted? dotted-id) (set! ok false))
        (unless (not (intern-qualified? dotted-id)) (set! ok false))
        (unless
          (= (intern-pointer-id-lookup (intern-str source-id)) source-id)
          (set! ok false))
        (unless
          (= (intern-pointer-id-lookup (intern-str opaque-id)) opaque-id)
          (set! ok false))
        (unless
          (= (intern-pointer-id-lookup (intern-str qualified-id)) qualified-id)
          (set! ok false))
        (unless
          (= (intern-pointer-id-lookup dotted-name) dotted-id)
          (set! ok false))
        (match (intern-lookup "hygiene/local")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (match (intern-lookup "generated-module/generated-base")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (match (intern-lookup "generated-base.Variant")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (match (intern-lookup "generated-source-anchor")
          [(InternLookupFound found-id)
            (unless (= found-id source-id) (set! ok false))]
          [(InternLookupMissing) (set! ok false)])
        (match (intern-lookup-preserving-generated-id
          (intern-str duplicate-display-id))
          [(InternLookupFound found-id)
            (unless (= found-id duplicate-display-id) (set! ok false))]
          [(InternLookupMissing) (set! ok false)])
        (match (intern-lookup-preserving-generated-id (intern-str source-id))
          [(InternLookupFound found-id)
            (unless (= found-id source-id) (set! ok false))]
          [(InternLookupMissing) (set! ok false)])
        (intern-reset-to! source-len)
        (unless (= (intern-pointer-id-lookup dotted-name) -1) (set! ok false))
        (unless
          (= (intern-pointer-id-lookup (intern-str source-id)) source-id)
          (set! ok false))
        (let
          [after-reset-to-id : i64 (intern-generated-name "after/reset-to")]
          (begin
            (unless (= (intern-pool-len) source-len) (set! ok false))
            (unless
              (= after-reset-to-id (- (intern-capacity) 1))
              (set! ok false))
            (unless
              (intern-private-string-eq
                (intern-str after-reset-to-id)
                "after/reset-to")
              (set! ok false))
            (unless
              (=
                (intern-pointer-id-lookup (intern-str after-reset-to-id))
                after-reset-to-id)
              (set! ok false))))
        (intern-reset!)
        (let
          [after-reset-id : i64 (intern-generated-name "after/reset")]
          (begin
            (unless (= (intern-pool-len) 0) (set! ok false))
            (unless (= after-reset-id (- (intern-capacity) 1)) (set! ok false))
            (unless
              (intern-private-string-eq
                (intern-str after-reset-id)
                "after/reset")
              (set! ok false))
            (unless
              (=
                (intern-pointer-id-lookup (intern-str after-reset-id))
                after-reset-id)
              (set! ok false))))
        (intern-reset!)
        ok))))

(define (intern-slice-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [slice-source : String "alpha beta alpha pkg/name"]
      [slice-alpha : i64 (intern-slice slice-source 0 5)]
      [slice-beta : i64 (intern-slice slice-source 6 4)]
      [slice-alpha-again : i64 (intern-slice slice-source 11 5)]
      [slice-qualified : i64 (intern-slice slice-source 17 8)]
      [long-slice-source : String "xxmultiword-hash-namezz"]
      [long-full : i64 (intern "multiword-hash-name")]
      [long-slice : i64 (intern-slice long-slice-source 2 19)]
      [ok : bool
        (and
          (= slice-alpha slice-alpha-again)
          (not (= slice-alpha slice-beta))
          (= long-full long-slice)
          (intern-private-string-eq
            (intern-str long-slice)
            "multiword-hash-name")
          (intern-private-string-eq (intern-str slice-alpha) "alpha")
          (intern-qualified-metadata-case-ok?
            slice-qualified
            true
            3
            "pkg"
            "name"))]
      (begin
        (intern-reset!)
        ok))))

(define (intern-pointer-storage-arena-tests-ok?) : bool
  (begin
    (intern-reset!)
    (set! intern-pointer-id-slots (make-array i64 1))
    (set! intern-pointer-key-slots (make-array i64 1))
    (set! intern-reader-pointer-slots (make-array i64 1))
    (set! intern-reader-id-slots (make-array i64 1))
    (let
      [home : i64 (tl_arena_current)]
      [scratch : i64 (tl_arena_make)]
      (begin
        (unsafe
          (tl_arena_set scratch))
        (intern-reset!)
        (let
          [id : i64 (intern "scratch-pointer-storage")]
          (begin
            (unsafe
              (tl_arena_set home))
            (unsafe
              (tl_arena_destroy scratch))
            (let
              [ok : bool (= (intern-pointer-id-lookup (intern-str id)) id)]
              (begin
                (intern-reset!)
                ok))))))))

(define (intern-persistent-arena-tests-ok?) : bool
  (begin
    (intern-reset!)
    (intern-persistent-storage-enable!)
    (let
      [home : i64 (tl_arena_current)]
      [scratch : i64 (tl_arena_make)]
      [id : i64
        (begin
          (unsafe
            (tl_arena_set scratch))
          (let
            [name : String (intern-substring "persist/entry" 0 13)]
            [stored : i64 (intern name)]
            (begin
              (unsafe
                (tl_arena_set home))
              (unsafe
                (tl_arena_destroy scratch))
              stored)))]
      [again : i64 (intern "persist/entry")]
      [ok : bool
        (and
          (= id again)
          (= (intern-pointer-id-lookup (intern-str id)) id)
          (intern-private-string-eq (intern-str id) "persist/entry")
          (intern-qualified-metadata-case-ok? id true 7 "persist" "entry"))]
      (begin
        (intern-reset!)
        (intern-persistent-storage-disable!)
        ok))))

(define (intern-reset-to-tests-ok?) : bool
  (begin
    (intern-reset!)
    (intern-persistent-storage-enable!)
    (let
      [kept : i64 (intern "keep/name")]
      [plain : i64 (intern "plain")]
      [mark : i64 (intern-pool-len)]
      [_drop : i64 (intern "drop/name")]
      [ok : bool true]
      (begin
        (intern-reset-to! mark)
        (unless (= (intern-pool-len) mark) (set! ok false))
        (unless (= (intern "keep/name") kept) (set! ok false))
        (unless (= (intern "plain") plain) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? kept true 4 "keep" "name")
          (set! ok false))
        (match (intern-lookup "drop/name")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (unless (= (intern "drop/name") mark) (set! ok false))
        (intern-reset!)
        (intern-persistent-storage-disable!)
        ok))))

(define (intern-persistent-floor-reset-tests-ok?) : bool
  (begin
    (intern-reset!)
    (intern-persistent-arena-reset!)
    (intern-persistent-storage-enable!)
    (let
      [kept : i64 (intern "floor_keep")]
      (begin
        (intern-persistent-arena-floor-refresh!)
        (let
          [drop-id : i64 (intern "floor_drop")]
          [ok : bool true]
          (begin
            (intern-reset-to! (+ kept 1))
            (intern-persistent-arena-reset-to-floor!)
            (unless (= (intern "floor_keep") kept) (set! ok false))
            (match (intern-lookup "floor_drop")
              [(InternLookupMissing) unit]
              [(InternLookupFound _) (set! ok false)])
            (unless (= (intern "floor_drop") drop-id) (set! ok false))
            (intern-reset!)
            (intern-persistent-storage-disable!)
            (intern-persistent-arena-reset!)
            ok))))))

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
      [dotted : i64 (intern "point.x")]
      [nested-dotted : i64 (intern "point.inner.x")]
      [ok : bool true]
      (begin
        (unless
          (intern-qualified-metadata-case-ok? plain false -1 "" "name")
          (set! ok false))
        (unless (= (intern-qualified-base-id plain) plain) (set! ok false))
        (unless (= (intern-qualified-module-id plain) -1) (set! ok false))
        (unless (= (intern-first-dot plain) -1) (set! ok false))
        (unless (not (intern-dotted? plain)) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? qualified true 6 "module" "name")
          (set! ok false))
        (unless (= (intern-first-dot qualified) -1) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? nested true 7 "pkg/sub" "name")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? leading true 0 "" "name")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? trailing true 6 "module" "")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? slash true 0 "" "")
          (set! ok false))
        (unless (= (intern-first-dot dotted) 5) (set! ok false))
        (unless (intern-dotted? dotted) (set! ok false))
        (unless
          (intern-private-string-eq
            (intern-str (intern-dotted-tail-id dotted))
            "x")
          (set! ok false))
        (unless
          (intern-private-string-eq
            (intern-str (intern-dotted-final-id dotted))
            "x")
          (set! ok false))
        (unless (= (intern-first-dot nested-dotted) 5) (set! ok false))
        (unless
          (intern-private-string-eq
            (intern-str (intern-dotted-tail-id nested-dotted))
            "inner.x")
          (set! ok false))
        (unless
          (intern-private-string-eq
            (intern-str (intern-dotted-final-id nested-dotted))
            "x")
          (set! ok false))
        (unless (intern-name-dotted? "point.x") (set! ok false))
        (unless (= (intern-name-first-dot "point.x") 5) (set! ok false))
        (unless (intern-slice-tests-ok?) (set! ok false))
        (unless (intern-pointer-storage-arena-tests-ok?) (set! ok false))
        (unless (intern-generated-name-tests-ok?) (set! ok false))
        (unless (intern-persistent-arena-tests-ok?) (set! ok false))
        (unless (intern-reset-to-tests-ok?) (set! ok false))
        (unless (intern-persistent-floor-reset-tests-ok?) (set! ok false))
        (intern-reset!)
        ok))))