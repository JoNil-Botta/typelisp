;; compiler_intern.tl - process-global string interning table for identifiers.
;;
;; LEAF-DEPENDENCY ONLY: every programmer-written identifier is interned
;; to a stable u32-backed id, so name comparisons become integer `=`, id-keyed lookups
;; replace string hashing, and the AST stores ids instead of copied Strings.
;; Keeping dependencies minimal is deliberate -- this module is reached from the core
;; compiler_ast_types.tl (and from sym_i64_env.tl), which are imported by tiny
;; integration cases. The dependency-free arena leaf provides checker-visible
;; allocation extents without pulling collection or formatting modules into them.
;;
(import compiler_owned_view as owned_view)

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
;;
;; ID provenance contract:
;; - `intern-source-slice` owns parser-token insertion. Parsed AST names carry
;;   those IDs directly; later phases may look them up or render them, but must
;;   not intern their String spelling again.
;; - Compiler-synthesized names use the `intern-generated-*` APIs. Canonical
;;   generated names deduplicate only in the generated domain; opaque generated
;;   names deliberately receive distinct identities. Empty generated names are
;;   valid when their construction API permits them.
;; - Builtin IDs are ordinary intern IDs installed for the current table.
;;   Hygiene, dotted, and module-qualified helpers preserve or explicitly create
;;   IDs and their metadata instead of recovering identity from String storage.
;; - Negative sentinels and opaque structural registry/environment handles are
;;   not intern IDs and must never be passed to `intern-str`.
;; - An ID is valid only while its owning `InternCompatState` table and generation
;;   are installed. Reset and reset-to-mark invalidate removed source IDs and all
;;   generated IDs. Equal numeric IDs in two driver states do not imply equal
;;   spelling; install the owner before rendering or consuming either one.
;;
;; `InternId` is the compact public representation for a renderable name.
;; `InternSlotId` is the separate id+1 encoding used by optional table slots.
;; Structural keys remain i64 so neither type can accidentally bless them as
;; renderable names. The compiler call graph still exposes some i64 boundaries
;; while the public `InternId` distinction migrates outward from this
;; authoritative table.
(import stdlib.arena)

;: Low-level arena hooks retain the explicit non-local reset/destroy protocols;
;: persistent allocation extents use the typed arena leaf above.
(extern (tl_arena_make) : i64)
(extern (tl_arena_current) : i64)
(extern (tl_region_mark) : i64)
(extern (tl_oob_abort) : never)
(cfg
  (not stage0-seed-intern-abort)
  (extern (intern-runtime-abort-string [message : String]) : never (:symbol "tl_abort_string")))

(unsafe
  (extern (tl_arena_set [arg0 : i64]) : unit))

(unsafe
  (extern (tl_arena_destroy [arg0 : i64]) : unit))

(unsafe
  (extern (tl_region_reset [arg0 : i64]) : unit))

(unsafe
  (extern (intern-runtime-copy-bytes!
    [dst : (MutPtr u8)]
    [src : (Ptr u8)]
    [count : i64]) : unit (:symbol "tl_memcpy")))

(defmacro (intern-i64-array-address [items : Expr]) : u64
  `(unsafe
    (ptr->int (ptr-cast (__tl_array-data ,items) : (Ptr u8)))))

(defmacro (intern-active-i64-ref [address : Expr] [index : Expr]) : i64
  `(unsafe
    (ptr-read (ptr-offset (int->ptr ,address : (Ptr i64)) ,index))))

(defmacro (intern-active-u8-ref [address : Expr] [index : Expr]) : u8
  `(unsafe
    (ptr-read (ptr-offset (int->ptr ,address : (Ptr u8)) ,index))))

(defmacro (intern-active-i64-set!
  [address : Expr]
  [index : Expr]
  [value : Expr]) : unit
  `(unsafe
    (ptr-write! (ptr-offset (int->ptr ,address : (MutPtr i64)) ,index) ,value)))

;; A few compatibility snapshots intentionally share the live process-global
;; intern storage. Require an explicit raw-pointer read for those shallow views;
;; ordinary non-Copy global reads remain rejected.
(defmacro (intern-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(defmacro (intern-array-shared-view [items : Expr] [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (array-data ,items) ,index))))

(define (intern-private-string-length [text : (& text str)]) : i64
  (__tl_string_length text))

(define (intern-private-string-ref [text : (& text str)] [index : i64]) : char
  (__tl_string_ref text index))

(define (intern-private-string-eq [left : (& left str)] [right : (& right str)]) : bool
  (let
    [left-len : i64 (__tl_string_length left)]
    [right-len : i64 (__tl_string_length right)]
    (if (not (= left-len right-len))
      false
      (unsafe
        (let
          [lp : (Ptr u8) (string-data left)]
          [rp : (Ptr u8) (string-data right)]
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
                  false)))))))))

;: Capacity must stay a power of two so the bucket index is a mask, not a modulo.
;: It also bounds one compile's live ids: source ids grow up from 0 and generated
;: ids grow down from capacity-1, so the two lanes together must fit.
;: It CANNOT simply be raised. The remaining arithmetic structural symbol ranges
;: are polynomials in this capacity and share one positive-i64 window. See
;: `intern-id-space-capacity-tests-ok?`, which fails fast before one range can
;: silently decode as another. Refs #6258.
(define (intern-capacity) : i64
  131072)

(define (intern-pool-capacity-abort) : never
  ;; The published seed predates the backend's fixed `tl_abort_string`
  ;; recognition. Only its one-shot stage1 compile selects the old fallback;
  ;; stage1 and every converged/published stage compile the diagnostic branch.
  (cfg
    stage0-seed-intern-abort
    (tl_oob_abort)
    (intern-runtime-abort-string
      "tl: intern pool capacity exhausted: source and generated lanes met\n")))

;; Structural compound identities are session-owned canonical records, not
;; entries in the string pool. Keep their compatibility raw-handle adapters at
;; this lowest layer while typed boundaries migrate outward.
(define (intern-composite-pair-id [left-id : i64] [right-id : i64]) : i64
  (let
    [cache-slot : i64
      (bit-and
        (bit-xor right-id (* left-id 6364136223846793005))
        (- (intern-structural-pair-cache-capacity) 1))]
    [cached-raw : i64
      (intern-active-i64-ref
        intern-active-structural-cache-raws-address
        cache-slot)]
    (begin
      (if (> cached-raw 0)
        (let
          [cached-index : i64
            (- (bit-and cached-raw (intern-structural-key-index-mask)) 1)]
          (if (=
            (intern-active-i64-ref
              intern-active-structural-lefts-address
              cached-index)
            left-id)
            (when
              (=
                (intern-active-i64-ref
                  intern-active-structural-rights-address
                  cached-index)
                right-id)
              (return cached-raw))
            unit))
        unit)
      (let
        [raw : i64
          (intern-structural-table-intern
            (&mut intern-structural-table-cell)
            intern-persistent-arena
            (intern-structural-kind-pair)
            left-id
            0
            right-id)]
        (begin
          (intern-active-i64-set!
            intern-active-structural-cache-raws-address
            cache-slot
            raw)
          (set!
            intern-active-structural-len
            (__tl-project-field (array-ref intern-structural-table-cell 0) len))
          raw)))))

(defmacro (intern-composite-pair-id? [id : Expr]) : bool
  `(let
    [structural-id : i64 ,id]
    [encoded-index : i64 (- structural-id intern-active-structural-prefix)]
    (and
      (> encoded-index 0)
      (<= encoded-index intern-active-structural-len)
      (=
        (cast
          (intern-active-u8-ref
            intern-active-structural-kinds-address
            (- encoded-index 1))
          : i64)
        (intern-structural-kind-pair)))))

(defmacro (intern-composite-left-id-unchecked [id : Expr]) : i64
  `(intern-active-i64-ref
    intern-active-structural-lefts-address
    (- (bit-and ,id (intern-structural-key-index-mask)) 1)))

(defmacro (intern-composite-middle-id-unchecked [id : Expr]) : i64
  `(intern-active-i64-ref
    intern-active-structural-middles-address
    (- (bit-and ,id (intern-structural-key-index-mask)) 1)))

(defmacro (intern-composite-right-id-unchecked [id : Expr]) : i64
  `(intern-active-i64-ref
    intern-active-structural-rights-address
    (- (bit-and ,id (intern-structural-key-index-mask)) 1)))

(define (intern-composite-triple-id
  [left-id : i64]
  [middle-id : i64]
  [right-id : i64]) : i64
  (let
    [cache-slot : i64
      (+
        (intern-structural-pair-cache-capacity)
        (bit-and
          (bit-xor
            right-id
            (bit-xor
              (* left-id 6364136223846793005)
              (* middle-id 1442695040888963407)))
          (- (intern-structural-triple-cache-capacity) 1)))]
    [cached-raw : i64
      (intern-active-i64-ref
        intern-active-structural-cache-raws-address
        cache-slot)]
    (begin
      (if (> cached-raw 0)
        (let
          [cached-index : i64
            (- (bit-and cached-raw (intern-structural-key-index-mask)) 1)]
          (if (=
            (intern-active-i64-ref
              intern-active-structural-lefts-address
              cached-index)
            left-id)
            (if (=
              (intern-active-i64-ref
                intern-active-structural-middles-address
                cached-index)
              middle-id)
              (when
                (=
                  (intern-active-i64-ref
                    intern-active-structural-rights-address
                    cached-index)
                  right-id)
                (return cached-raw))
              unit)
            unit))
        unit)
      (let
        [raw : i64
          (intern-structural-table-intern
            (&mut intern-structural-table-cell)
            intern-persistent-arena
            (intern-structural-kind-triple)
            left-id
            middle-id
            right-id)]
        (begin
          (intern-active-i64-set!
            intern-active-structural-cache-raws-address
            cache-slot
            raw)
          (set!
            intern-active-structural-len
            (__tl-project-field (array-ref intern-structural-table-cell 0) len))
          raw)))))

(defmacro (intern-composite-triple-id? [id : Expr]) : bool
  `(let
    [structural-id : i64 ,id]
    [encoded-index : i64 (- structural-id intern-active-structural-prefix)]
    (and
      (> encoded-index 0)
      (<= encoded-index intern-active-structural-len)
      (=
        (cast
          (intern-active-u8-ref
            intern-active-structural-kinds-address
            (- encoded-index 1))
          : i64)
        (intern-structural-kind-triple)))))

(defmacro (intern-renderable-id? [id : Expr]) : bool
  `(let
    [name-id : i64 ,id]
    (and (>= name-id 0) (< name-id (intern-capacity)))))

;; Quasiquoted source symbols keep their parsed identity without allocating a
;; second intern entry. This range sits above the compiler's other structural
;; symbol ranges and remains within signed i64 at the fixed intern capacity.
;; The cube is what pins the capacity: at 2^17 this is exactly 2^62, one owner
;; stride below the first composite structural key, and it overflows signed i64
;; the moment the capacity moves up. Refs #6258.
(define (intern-template-source-base) : i64
  (let
    [stride : i64 (intern-capacity)]
    (* 2048 (* stride (* stride stride)))))

(define (intern-template-source-id [source-id : i64]) : i64
  (+ (intern-template-source-base) source-id))

(define (intern-template-source-id? [id : i64]) : bool
  (and
    (>= id (intern-template-source-base))
    (< id (+ (intern-template-source-base) (intern-capacity)))))

(define (intern-template-source-name-id [id : i64]) : i64
  (- id (intern-template-source-base)))

;; Compiler rewrites sometimes need a fresh lexical identity while retaining a
;; parsed binding's spelling. Encode that identity structurally instead of
;; allocating another string-pool entry. This range is below the
;; quasiquoted-source range.
(define (intern-structural-local-base) : i64
  (let
    [stride : i64 (intern-capacity)]
    (* 1536 (* stride (* stride stride)))))

(define (intern-structural-local-id [ordinal : i64] [source-name-id : i64]) : i64
  (let
    [stride : i64 (intern-capacity)]
    [id : i64
      (+ (intern-structural-local-base) (+ (* ordinal stride) source-name-id))]
    (if (or
      (< ordinal 0)
      (< source-name-id 0)
      (>= source-name-id stride)
      (>= id (intern-template-source-base)))
      (tl_oob_abort)
      id)))

(define (intern-structural-local-id? [id : i64]) : bool
  (and
    (>= id (intern-structural-local-base))
    (< id (intern-template-source-base))))

(define (intern-structural-local-source-name-id [id : i64]) : i64
  (% (- id (intern-structural-local-base)) (intern-capacity)))

(define (intern-colon-keyword-id? [id : i64]) : bool
  (let
    [text : String (intern-str id)]
    (and
      (> (intern-private-string-length text) 1)
      (= (intern-private-string-ref text 0) ':'))))

;; Name-bearing AST fields accept pool ids plus several structural syntax-id
;; families. Collapse any documented family to its renderable source spelling;
;; callers retain the original integer wherever identity, rather than display,
;; matters. Unknown structural values return the supplied fallback instead of
;; reaching intern-str and aborting on an array index.
(define (intern-syntax-source-name-id-or [id : i64] [fallback : i64]) : i64
  (cond
    [(intern-renderable-id? id) id]
    [(intern-template-source-id? id) (intern-template-source-name-id id)]
    [(intern-structural-local-id? id)
      (intern-structural-local-source-name-id id)]
    [else fallback]))

(define (intern-syntax-name-text-or [id : i64] [fallback : String]) : String
  (let
    [source-id : i64 (intern-syntax-source-name-id-or id -1)]
    (if (>= source-id 0)
      (intern-str source-id)
      fallback)))

(defstruct InternId
  (value u32))

(defmacro (intern-id-value [id : Expr]) : i64
  `(cast (__tl-project-field-name ,id "value") : i64))

(define (intern-id-eq? [left : InternId] [right : InternId]) : bool
  (= (intern-id-value left) (intern-id-value right)))

;; Name-bearing syntax crosses two identity domains: ordinary renderable pool
;; names and session-owned structural names used by macro hygiene and compiler
;; rewrites. Keep that mixed boundary nominal and one word. Consumers must
;; either preserve identity with `intern-syntax-id-value` or explicitly reduce
;; it to a renderable source spelling; a structural key cannot call
;; `intern-id-str` directly.
(defstruct InternSyntaxId
  (value u64))

(defmacro (intern-syntax-id-value [id : Expr]) : i64
  `(cast (__tl-project-field-name ,id "value") : i64))

(define (intern-syntax-id-eq? [left : InternSyntaxId] [right : InternSyntaxId]) : bool
  (= (intern-syntax-id-value left) (intern-syntax-id-value right)))

(define (intern-syntax-id-from-renderable [id : InternId]) : InternSyntaxId
  (InternSyntaxId (cast (intern-id-value id) : u64)))

;; Compatibility constructor for the existing mixed AST/macro fields. Missing
;; sentinels are not syntax identities; reject them at the construction edge.
(define (intern-syntax-id-from-raw [id : i64]) : InternSyntaxId
  (if (< id 0)
    (tl_oob_abort)
    (InternSyntaxId (cast id : u64))))

(define (intern-syntax-id-renderable [id : InternSyntaxId]) : InternId
  (intern-id-from-renderable
    (intern-syntax-source-name-id-or (intern-syntax-id-value id) -1)))

(define (intern-syntax-id-text [id : InternSyntaxId]) : String
  (intern-id-str (intern-syntax-id-renderable id)))

(define (intern-id-from-renderable [id : i64]) : InternId
  (if (intern-renderable-id? id)
    (InternId (cast id : u32))
    (tl_oob_abort)))

;; Optional table lanes reserve zero for missing and store raw id+1. Keeping
;; this encoding nominally separate prevents a missing slot from reaching a
;; render API as if it were the source name with id zero.
(defstruct InternSlotId
  (encoded u32))

(defmacro (intern-slot-id-value [id : Expr]) : i64
  `(cast (__tl-project-field-name ,id "encoded") : i64))

;; Compact lanes reserve zero for an empty/missing slot and store id+1.
(define (intern-id-slot-empty) : InternSlotId
  (InternSlotId (cast 0 : u32)))

(defmacro (intern-id-slot-empty? [id : Expr]) : bool
  `(= (__tl-project-field-name ,id "encoded") (cast 0 : u32)))

(define (intern-id-slot-encode [id : i64]) : InternSlotId
  (InternSlotId (cast (+ id 1) : u32)))

(defmacro (intern-id-slot-decode [encoded : Expr]) : i64
  `(- (intern-slot-id-value ,encoded) 1))

(defenum InternLookup
  (InternLookupMissing)
  (InternLookupFound i64))

;: Canonical macro-hygiene name prefixes. The interner owns the spellings
;: because it classifies every pool entry against them once, when the entry is
;: recorded; downstream phases read the stored class instead of re-deriving it
;: from the rendered string on every visit.
(define (intern-macro-global-prefix) : String
  "__tl_macro_global$")

(define (intern-macro-local-prefix) : String
  "__tl_macro_local$")

(define (intern-macro-template-prefix) : String
  "__tl_macro_template$")

;; Prefix classes stored per pool entry. The three prefixes differ at index 11
;; (`g`/`l`/`t`) and none is a prefix of another, so one class per entry is
;; exact rather than a summary.
(define (intern-macro-prefix-class-none) : i64
  0)

(define (intern-macro-prefix-class-global) : i64
  1)

(define (intern-macro-prefix-class-local) : i64
  2)

(define (intern-macro-prefix-class-template) : i64
  3)

(define (intern-private-string-prefix?
  [text : (& text str)]
  [prefix : (& prefix str)]) : bool
  (let
    [text-len : i64 (intern-private-string-length text)]
    [prefix-len : i64 (intern-private-string-length prefix)]
    [i : i64 0]
    [same : bool true]
    (if (< text-len prefix-len)
      false
      (begin
        (while (and same (< i prefix-len))
          (if (=
            (intern-private-string-ref text i)
            (intern-private-string-ref prefix i))
            (set! i (+ i 1))
            (set! same false)))
        same))))

;; Runs once per recorded pool entry, so a plain byte scan is the right shape:
;; the query side is what has to be cheap, and it becomes a single array read.
(define (intern-private-macro-prefix-class [name : (& name str)]) : u8
  (cond
    [(intern-private-string-prefix? name (intern-macro-global-prefix))
      (cast (intern-macro-prefix-class-global) : u8)]
    [(intern-private-string-prefix? name (intern-macro-local-prefix))
      (cast (intern-macro-prefix-class-local) : u8)]
    [(intern-private-string-prefix? name (intern-macro-template-prefix))
      (cast (intern-macro-prefix-class-template) : u8)]
    [else (cast (intern-macro-prefix-class-none) : u8)]))

(define intern-pool-slots : (__tl_dyn-array String)
  (__tl_make-array String (intern-capacity)))
(define intern-pool-qualified-slots : (__tl_dyn-array bool)
  (__tl_make-array bool (intern-capacity)))
(define intern-pool-last-slash-slots : (__tl_dyn-array i32)
  (__tl_make-array i32 (intern-capacity)))
(define intern-pool-first-dot-slots : (__tl_dyn-array i32)
  (__tl_make-array i32 (intern-capacity)))
(define intern-pool-leading-dot-id-slots : (__tl_dyn-array InternSlotId)
  (__tl_make-array InternSlotId (intern-capacity)))
(define intern-pool-dotted-prefix-id-slots : (__tl_dyn-array InternSlotId)
  (__tl_make-array InternSlotId (intern-capacity)))
(define intern-pool-module-id-slots : (__tl_dyn-array InternSlotId)
  (__tl_make-array InternSlotId (intern-capacity)))
(define intern-pool-base-id-slots : (__tl_dyn-array InternSlotId)
  (__tl_make-array InternSlotId (intern-capacity)))
(define intern-pool-macro-prefix-class-slots : (__tl_dyn-array u8)
  (__tl_make-array u8 (intern-capacity)))
(define intern-pool-count : i64
  0)
(define intern-generated-next-id : i64
  (- (intern-capacity) 1))
(define intern-active-table-id-value : i64
  0)
(define intern-next-table-id : i64
  1)
(define intern-next-generation : i64
  1)
(define intern-next-structural-owner : i64
  1)

(define (intern-pool-len) : i64
  intern-pool-count)

;; Compat states can have the same reset generation. Give each table a stable
;; process-local identity so caches never infer identity from reusable storage.
(define (intern-table-id-allocate!) : i64
  (let
    [id : i64 intern-next-table-id]
    (begin
      (set! intern-next-table-id (+ intern-next-table-id 1))
      id)))

(define (intern-active-table-id) : i64
  intern-active-table-id-value)

(define (intern-generation-allocate!) : i64
  (let
    [generation : i64 intern-next-generation]
    (begin
      (set! intern-next-generation (+ intern-next-generation 1))
      generation)))

(defstruct InternStructuralTable
  (owner i64)
  (kinds (__tl_dyn-array u8))
  (lefts (__tl_dyn-array i64))
  (middles (__tl_dyn-array i64))
  (rights (__tl_dyn-array i64))
  (rendered-names (__tl_dyn-array String))
  ;; Only outer generated-role records populate this lane. Structural
  ;; component records leave it at zero, so role identity is independent of
  ;; both allocation order and eventual display spelling.
  (generated-symbol-handles (__tl_dyn-array InternSlotId))
  (map-slots (__tl_dyn-array i64))
  (structural-cache-raws (__tl_dyn-array i64))
  (len i64))

(define (intern-structural-key-base) : i64
  4611686018427387904)

(define (intern-structural-key-owner-stride) : i64
  2147483648)

(define (intern-structural-key-index-mask) : i64
  2147483647)

(define (intern-structural-kind-pair) : i64
  1)

(define (intern-structural-kind-triple) : i64
  2)

;; These kind assignments reserve the migration targets split from #5210.
;; Handles do not encode this value: ownership selects a record, and the
;; record's u8 kind lane is authoritative. The table accepts the full non-zero
;; u8 range so later identity families do not require another handle-layout
;; transition.
(define (intern-structural-kind-template-source) : i64
  3)

(define (intern-structural-kind-fresh-local) : i64
  4)

(define (intern-structural-kind-macro-global) : i64
  5)

(define (intern-structural-kind-macro-local) : i64
  6)

(define (intern-structural-kind-lower-private) : i64
  7)

(define (intern-structural-kind-arena-phase) : i64
  8)

;; A hygienic local names its macro definition by a nested structural record.
;; Keep this separate from the global/local name records: the definition key is
;; canonical once and remains stable when declaration-list indices move.
(define (intern-structural-kind-macro-definition) : i64
  9)

(define (intern-structural-kind-valid? [kind : i64]) : bool
  (and (> kind 0) (<= kind 255)))

(define (intern-structural-record-slot-bytes) : i64
  (+
    25
    (+
      (comptime (size-of (type String)))
      (comptime (size-of (type InternSlotId))))))

(define (intern-structural-pair-cache-capacity) : i64
  131072)

(define (intern-structural-triple-cache-capacity) : i64
  65536)

(define (intern-structural-cache-capacity) : i64
  (+
    (intern-structural-pair-cache-capacity)
    (intern-structural-triple-cache-capacity)))

(define (intern-structural-owner-allocate!) : i64
  (let
    [owner : i64 intern-next-structural-owner]
    (begin
      (if (>= owner (intern-structural-key-owner-stride))
        (tl_oob_abort)
        unit)
      (set! intern-next-structural-owner (+ owner 1))
      owner)))

(define (intern-structural-table-new) : InternStructuralTable
  (InternStructuralTable
    (intern-structural-owner-allocate!)
    (__tl_make-array u8 256)
    (__tl_make-array i64 256)
    (__tl_make-array i64 256)
    (__tl_make-array i64 256)
    (__tl_make-array String 256)
    (__tl_make-array InternSlotId 256)
    (__tl_make-array i64 512)
    (__tl_make-array i64 (intern-structural-cache-capacity))
    0))

(define (intern-structural-table-cell-new-in-arena [arena-handle : i64]) : (__tl_dyn-array
    InternStructuralTable)
  (let
    [table : InternStructuralTable
      (in-arena (arena.Arena arena-handle) (intern-structural-table-new))]
    (__tl_make-array table)))

(define intern-persistent-arena : i64
  (tl_arena_make))
(define intern-persistent-arena-floor-mark : i64
  0)

;; Structural records have exactly the intern session's lifetime, so they share
;; its persistent arena instead of reserving another arena per compiler state.
;; Persistent full/floor resets reinitialize the table before use; logical
;; intern resets clear and re-owner the retained buffers.
(define intern-structural-table-cell : (__tl_dyn-array InternStructuralTable)
  (intern-structural-table-cell-new-in-arena intern-persistent-arena))
(define intern-active-structural-prefix : i64
  (+
    (intern-structural-key-base)
    (*
      (__tl-project-field (array-ref intern-structural-table-cell 0) owner)
      (intern-structural-key-owner-stride))))
(define intern-active-structural-owner : i64
  (__tl-project-field (array-ref intern-structural-table-cell 0) owner))
(define intern-active-structural-len : i64
  0)
(define intern-active-structural-kinds-address : u64
  (intern-i64-array-address
    (__tl-project-field (array-ref intern-structural-table-cell 0) kinds)))
(define intern-active-structural-lefts-address : u64
  (intern-i64-array-address
    (__tl-project-field (array-ref intern-structural-table-cell 0) lefts)))
(define intern-active-structural-middles-address : u64
  (intern-i64-array-address
    (__tl-project-field (array-ref intern-structural-table-cell 0) middles)))
(define intern-active-structural-rights-address : u64
  (intern-i64-array-address
    (__tl-project-field (array-ref intern-structural-table-cell 0) rights)))
(define intern-active-structural-cache-raws-address : u64
  (intern-i64-array-address
    (__tl-project-field
      (array-ref intern-structural-table-cell 0)
      structural-cache-raws)))

;; Explicit sessions normally name the installed compatibility owner. A
;; structural owner is allocated once process-wide for every table generation,
;; so equality with the installed owner alone proves both table identity and
;; generation. This lets the adapter reuse the synchronized scalar/address
;; snapshot without reloading the session's table id on every name lookup. An
;; isolated or stale session falls back to its own table and never observes
;; this view.
(defmacro (intern-active-structural-session? [structural-owner : Expr]) : bool
  `(= ,structural-owner intern-active-structural-owner))

(defmacro (intern-active-structural-record-kind-or
  [raw : Expr]
  [fallback : Expr]) : i64
  `(let
    [structural-id : i64 ,raw]
    [encoded-index : i64 (- structural-id intern-active-structural-prefix)]
    (if (and
      (> encoded-index 0)
      (<= encoded-index intern-active-structural-len))
      (cast
        (intern-active-u8-ref
          intern-active-structural-kinds-address
          (- encoded-index 1))
        : i64)
      ,fallback)))

(define (intern-active-structural-sync!
  [cell : (& cell (__tl_dyn-array InternStructuralTable))]) : unit
  (let
    [table : (& cell InternStructuralTable) (& (array-ref cell 0))]
    (begin
      (set!
        intern-active-structural-prefix
        (+
          (intern-structural-key-base)
          (* table.owner (intern-structural-key-owner-stride))))
      (set! intern-active-structural-owner table.owner)
      (set! intern-active-structural-len table.len)
      (set!
        intern-active-structural-kinds-address
        (intern-i64-array-address table.kinds))
      (set!
        intern-active-structural-lefts-address
        (intern-i64-array-address table.lefts))
      (set!
        intern-active-structural-middles-address
        (intern-i64-array-address table.middles))
      (set!
        intern-active-structural-rights-address
        (intern-i64-array-address table.rights))
      (set!
        intern-active-structural-cache-raws-address
        (intern-i64-array-address table.structural-cache-raws)))))

(defmacro (intern-structural-raw-for-index [owner : Expr] [index : Expr]) : i64
  `(+
    (intern-structural-key-base)
    (+ (* ,owner (intern-structural-key-owner-stride)) (+ ,index 1))))

(defmacro (intern-structural-hash
  [kind : Expr]
  [left : Expr]
  [middle : Expr]
  [right : Expr]) : i64
  `(bit-xor
    (* (+ ,kind 1) 6364136223846793005)
    (bit-xor
      (* (+ ,left 17) 1442695040888963407)
      (bit-xor
        (* (+ ,middle 31) 2862933555777941757)
        (* (+ ,right 47) 3202034522624059733)))))

(defmacro (intern-structural-table-first-slot
  [table : Expr]
  [kind : Expr]
  [left : Expr]
  [middle : Expr]
  [right : Expr]) : i64
  `(bit-and
    (intern-structural-hash ,kind ,left ,middle ,right)
    (- (array-length (__tl-project-field-name ,table "map-slots")) 1)))

(defmacro (intern-structural-table-record-matches?
  [table : Expr]
  [index : Expr]
  [kind : Expr]
  [left : Expr]
  [middle : Expr]
  [right : Expr]) : bool
  `(and
    (=
      (cast (array-ref (__tl-project-field-name ,table "kinds") ,index) : i64)
      ,kind)
    (= (array-ref (__tl-project-field-name ,table "lefts") ,index) ,left)
    (= (array-ref (__tl-project-field-name ,table "middles") ,index) ,middle)
    (= (array-ref (__tl-project-field-name ,table "rights") ,index) ,right)))

(define (intern-structural-table-map-put-index!
  [table : (&mut table InternStructuralTable)]
  [index : i64]) : unit
  (let
    [kind : i64 (cast (array-ref table.kinds index) : i64)]
    [left : i64 (array-ref table.lefts index)]
    [middle : i64 (array-ref table.middles index)]
    [right : i64 (array-ref table.rights index)]
    [slots-address : u64 (intern-i64-array-address table.map-slots)]
    [mask : i64 (- (array-length table.map-slots) 1)]
    [slot : i64
      (intern-structural-table-first-slot table kind left middle right)]
    (begin
      (while (not (= (intern-active-i64-ref slots-address slot) 0))
        (set! slot (bit-and (+ slot 1) mask)))
      (intern-active-i64-set! slots-address slot (+ index 1)))))

(defmacro (intern-structural-copy-array!
  [from : Expr]
  [to : Expr]
  [bytes : Expr]) : unit
  `(unsafe
    (intern-runtime-copy-bytes!
      (ptr-cast (__tl_array-data ,to) : (MutPtr u8))
      (ptr-cast (__tl_array-data ,from) : (Ptr u8))
      ,bytes)))

(define (intern-structural-table-grow-records!
  [cell : (&mut cell (__tl_dyn-array InternStructuralTable))]
  [arena-handle : i64]) : unit
  (let
    [table : (&mut cell InternStructuralTable) (&mut (array-ref cell 0))]
    [count : i64 table.len]
    [old-capacity : i64 (array-length table.kinds)]
    [new-capacity : i64 (* old-capacity 2)]
    (in-arena
      (arena.Arena arena-handle)
      (let
        [next-kinds : (__tl_dyn-array u8) (__tl_make-array u8 new-capacity)]
        [next-lefts : (__tl_dyn-array i64) (__tl_make-array i64 new-capacity)]
        [next-middles : (__tl_dyn-array i64) (__tl_make-array i64 new-capacity)]
        [next-rights : (__tl_dyn-array i64) (__tl_make-array i64 new-capacity)]
        [next-rendered-names : (__tl_dyn-array String)
          (__tl_make-array String new-capacity)]
        [next-generated-symbol-handles : (__tl_dyn-array InternSlotId)
          (__tl_make-array InternSlotId new-capacity)]
        (begin
          (intern-structural-copy-array! table.kinds next-kinds count)
          (intern-structural-copy-array! table.lefts next-lefts (* count 8))
          (intern-structural-copy-array! table.middles next-middles (* count 8))
          (intern-structural-copy-array! table.rights next-rights (* count 8))
          (intern-structural-copy-array!
            table.generated-symbol-handles
            next-generated-symbol-handles
            (* count 4))
          (let
            [index : i64 0]
            (while (< index count)
              (begin
                (set!
                  (array-ref next-rendered-names index)
                  (intern-substring
                    (& (array-ref table.rendered-names index))
                    0
                    (intern-private-string-length
                      (& (array-ref table.rendered-names index)))))
                (set! index (+ index 1)))))
          (set! table.kinds next-kinds)
          (set! table.lefts next-lefts)
          (set! table.middles next-middles)
          (set! table.rights next-rights)
          (set! table.rendered-names next-rendered-names)
          (set! table.generated-symbol-handles next-generated-symbol-handles)
          (if (= table.owner intern-active-structural-owner)
            (begin
              (set!
                intern-active-structural-kinds-address
                (intern-i64-array-address next-kinds))
              (set!
                intern-active-structural-lefts-address
                (intern-i64-array-address next-lefts))
              (set!
                intern-active-structural-middles-address
                (intern-i64-array-address next-middles))
              (set!
                intern-active-structural-rights-address
                (intern-i64-array-address next-rights)))
            unit)
          unit)))))

(define (intern-structural-table-grow-map!
  [cell : (&mut cell (__tl_dyn-array InternStructuralTable))]
  [arena-handle : i64]) : unit
  (let
    [table : (&mut cell InternStructuralTable) (&mut (array-ref cell 0))]
    [new-capacity : i64 (* (array-length table.map-slots) 2)]
    (in-arena
      (arena.Arena arena-handle)
      (let
        [next-slots : (__tl_dyn-array i64) (__tl_make-array i64 new-capacity)]
        (begin
          (set! table.map-slots next-slots)
          (let
            [index : i64 0]
            (while (< index table.len)
              (begin
                (intern-structural-table-map-put-index! table index)
                (set! index (+ index 1)))))
          unit)))))

(defstruct InternStructuralProbe
  (found i64)
  (owner i64)
  (grow-records? bool)
  (grow-map? bool))

(define (intern-structural-table-probe
  [cell : (& cell (__tl_dyn-array InternStructuralTable))]
  [kind : i64]
  [left : i64]
  [middle : i64]
  [right : i64]) : InternStructuralProbe
  (let
    [table : (& cell InternStructuralTable) (& (array-ref cell 0))]
    [slots-address : u64 (intern-i64-array-address table.map-slots)]
    [mask : i64 (- (array-length table.map-slots) 1)]
    [slot : i64
      (intern-structural-table-first-slot table kind left middle right)]
    [searching? : bool true]
    [found : i64 -1]
    (begin
      (if (intern-structural-kind-valid? kind)
        unit
        (tl_oob_abort))
      (while searching?
        (let
          [encoded : i64 (intern-active-i64-ref slots-address slot)]
          (cond
            [(= encoded 0) (set! searching? false)]
            [(intern-structural-table-record-matches?
                table
                (- encoded 1)
                kind
                left
                middle
                right)
              (begin
                (set! found (- encoded 1))
                (set! searching? false))]
            [else (set! slot (bit-and (+ slot 1) mask))])))
      (InternStructuralProbe
        found
        table.owner
        (>= table.len (array-length table.kinds))
        (>= (* (+ table.len 1) 4) (* (array-length table.map-slots) 3))))))

(define (intern-structural-table-intern
  [cell : (&mut cell (__tl_dyn-array InternStructuralTable))]
  [arena : i64]
  [kind : i64]
  [left : i64]
  [middle : i64]
  [right : i64]) : i64
  (let
    [probe : InternStructuralProbe
      (intern-structural-table-probe cell kind left middle right)]
    (if (>= probe.found 0)
      (intern-structural-raw-for-index probe.owner probe.found)
      (begin
        (if probe.grow-records?
          (intern-structural-table-grow-records! cell arena)
          unit)
        (if probe.grow-map?
          (intern-structural-table-grow-map! cell arena)
          unit)
        (let
          [next-table : (&mut cell InternStructuralTable)
            (&mut (array-ref cell 0))]
          [index : i64 next-table.len]
          (begin
            (if (>= index (intern-structural-key-index-mask))
              (tl_oob_abort)
              unit)
            (set! (array-ref next-table.kinds index) (cast kind : u8))
            (set! (array-ref next-table.lefts index) left)
            (set! (array-ref next-table.middles index) middle)
            (set! (array-ref next-table.rights index) right)
            (set!
              (array-ref next-table.generated-symbol-handles index)
              (intern-id-slot-empty))
            (set! next-table.len (+ index 1))
            (intern-structural-table-map-put-index! next-table index)
            (intern-structural-raw-for-index next-table.owner index)))))))

(define (intern-structural-table-reset!
  [cell : (&mut cell (__tl_dyn-array InternStructuralTable))]) : unit
  (let
    [table : (&mut cell InternStructuralTable) (&mut (array-ref cell 0))]
    [index : i64 0]
    (begin
      (while (< index (array-length table.map-slots))
        (begin
          (set! (array-ref table.map-slots index) 0)
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index table.len)
        (begin
          (set! (array-ref table.rendered-names index) "")
          (set!
            (array-ref table.generated-symbol-handles index)
            (intern-id-slot-empty))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index (array-length table.structural-cache-raws))
        (begin
          (set! (array-ref table.structural-cache-raws index) 0)
          (set! index (+ index 1))))
      (set! table.owner (intern-structural-owner-allocate!))
      (set! table.len 0)
      unit)))

(define (intern-structural-table-reinitialize-in-arena!
  [cell : (&mut cell (__tl_dyn-array InternStructuralTable))]
  [arena-handle : i64]) : unit
  (let
    [next : InternStructuralTable
      (in-arena (arena.Arena arena-handle) (intern-structural-table-new))]
    (set! (array-ref cell 0) next)))

(define (intern-structural-session-reset!
  [table-cell : (&mut table-cell (__tl_dyn-array InternStructuralTable))]) : unit
  (intern-structural-table-reset! table-cell))

;; Bucket IDs use the compact encoded `InternSlotId` representation. The pool owns
;; each spelling, so the hash table needs only identity and hash lanes rather
;; than a second String-bearing enum table.
(define intern-map-id-slots : (__tl_dyn-array InternSlotId)
  (__tl_make-array InternSlotId (intern-capacity)))
(define intern-map-hash-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 (intern-capacity)))

;; Sized with the pool: every generated id is a pool id, so a compile that fills
;; the generated lane must still find a free bucket here rather than exhaust the
;; probe budget in `intern-generated-canonical-name-at`.
(define intern-generated-map-capacity : i64
  131072)
(define intern-generated-map-id-slots : (__tl_dyn-array InternSlotId)
  (__tl_make-array InternSlotId intern-generated-map-capacity))
(define intern-generated-map-hash-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 intern-generated-map-capacity))
(define intern-map-ready : bool
  false)
(define intern-reset-generation : i64
  0)
(define intern-name-cache-id : i64
  -1)
(define intern-name-cache-ready : bool
  false)

;; Capability for rendering an id retained across an intern-state boundary.
;; It is captured by the few consumers that outlive the currently installed
;; table rather than adding ownership metadata to every AST name.
(defstruct InternCompatState
  (table-id (__tl_dyn-array i64))
  (pool-slots (__tl_dyn-array String))
  (pool-qualified-slots (__tl_dyn-array bool))
  (pool-last-slash-slots (__tl_dyn-array i32))
  (pool-first-dot-slots (__tl_dyn-array i32))
  (pool-leading-dot-id-slots (__tl_dyn-array InternSlotId))
  (pool-dotted-prefix-id-slots (__tl_dyn-array InternSlotId))
  (pool-module-id-slots (__tl_dyn-array InternSlotId))
  (pool-base-id-slots (__tl_dyn-array InternSlotId))
  (pool-macro-prefix-class-slots (__tl_dyn-array u8))
  (pool-count (__tl_dyn-array i64))
  (generated-next-id (__tl_dyn-array i64))
  (map-id-slots (__tl_dyn-array InternSlotId))
  (map-hash-slots (__tl_dyn-array i64))
  (generated-map-id-slots (__tl_dyn-array InternSlotId))
  (generated-map-hash-slots (__tl_dyn-array i64))
  (map-ready (__tl_dyn-array bool))
  (reset-generation (__tl_dyn-array i64))
  (persistent-arena (__tl_dyn-array i64))
  (persistent-arena-floor-mark (__tl_dyn-array i64))
  (structural-table-cell (__tl_dyn-array InternStructuralTable)))

;; An immutable compile-intern capability. Source lookup and structural-key
;; ownership share one reset generation and one-word handle; the cells let
;; consumers reject stale identities without consulting whichever compatibility
;; table is active.
(defstruct InternSourceNameSession
  (table-id-cell (__tl_dyn-array i64))
  (reset-generation-cell (__tl_dyn-array i64))
  (pool-slots (__tl_dyn-array String))
  (map-id-slots (__tl_dyn-array InternSlotId))
  (map-hash-slots (__tl_dyn-array i64))
  (map-ready-cell (__tl_dyn-array bool))
  ;; The source-name boundary is also the compile job's immutable structural
  ;; capability. These owner cells let later phases canonicalize and validate
  ;; structural keys without installing whichever table is active globally.
  (persistent-arena-cell (__tl_dyn-array i64))
  (structural-table-cell (__tl_dyn-array InternStructuralTable))
  (table-id i64)
  (reset-generation i64)
  (source-count i64)
  (structural-owner i64))

(defstruct InternSourceNameSessionHandle
  (address i64))

(defstruct InternSyntaxTextIdentity
  (table-id i64)
  (reset-generation i64)
  (id i64))

(defenum InternSourceNameResolution
  (ParsedIdentity i64)
  (GeneratedIdentity i64 InternLookup)
  (WrongOwner)
  (StaleGeneration)
  (InvalidIdentity))

(define (intern-compat-state-new) : InternCompatState
  (let
    [table-id : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [pool-count : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [generated-next-id : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [map-ready : (__tl_dyn-array bool) (__tl_make-array bool 1)]
    [reset-generation : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [persistent-arena-handle : i64 (tl_arena_make)]
    [persistent-arena : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [persistent-arena-floor-mark : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [structural-table-cell : (__tl_dyn-array InternStructuralTable)
      (intern-structural-table-cell-new-in-arena persistent-arena-handle)]
    (begin
      (set! (array-ref table-id 0) (intern-table-id-allocate!))
      (set! (array-ref pool-count 0) 0)
      (set! (array-ref generated-next-id 0) (- (intern-capacity) 1))
      (set! (array-ref map-ready 0) false)
      (set! (array-ref reset-generation 0) (intern-generation-allocate!))
      (set! (array-ref persistent-arena 0) persistent-arena-handle)
      (set! (array-ref persistent-arena-floor-mark 0) 0)
      (InternCompatState
        table-id
        (__tl_make-array String (intern-capacity))
        (__tl_make-array bool (intern-capacity))
        (__tl_make-array i32 (intern-capacity))
        (__tl_make-array i32 (intern-capacity))
        (__tl_make-array InternSlotId (intern-capacity))
        (__tl_make-array InternSlotId (intern-capacity))
        (__tl_make-array InternSlotId (intern-capacity))
        (__tl_make-array InternSlotId (intern-capacity))
        (__tl_make-array u8 (intern-capacity))
        pool-count
        generated-next-id
        (__tl_make-array InternSlotId (intern-capacity))
        (__tl_make-array i64 (intern-capacity))
        (__tl_make-array InternSlotId intern-generated-map-capacity)
        (__tl_make-array i64 intern-generated-map-capacity)
        map-ready
        reset-generation
        persistent-arena
        persistent-arena-floor-mark
        structural-table-cell))))

;; Capture the currently installed compatibility table as a serial/test view.
;; The arrays (including the persistent structural table and arena) are shared
;; with the active table; only scalar cells are fresh.  This deliberately does
;; not allocate a new persistent arena or copy the intern pool.  The view is a
;; serial/test compatibility boundary: explicit state operations may mutate its
;; scalar cells and `intern-compat-state-install!` then republishes those cells.
(define (intern-compat-state-capture-active) : InternCompatState
  (let
    [table-id : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [pool-count : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [generated-next-id : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [map-ready : (__tl_dyn-array bool) (__tl_make-array bool 1)]
    [reset-generation : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [persistent-arena : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [persistent-arena-floor-mark : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (set! (array-ref table-id 0) intern-active-table-id-value)
      (set! (array-ref pool-count 0) intern-pool-count)
      (set! (array-ref generated-next-id 0) intern-generated-next-id)
      (set! (array-ref map-ready 0) intern-map-ready)
      (set! (array-ref reset-generation 0) intern-reset-generation)
      (set! (array-ref persistent-arena 0) intern-persistent-arena)
      (set!
        (array-ref persistent-arena-floor-mark 0)
        intern-persistent-arena-floor-mark)
      (InternCompatState
        table-id
        (intern-global-shared-view intern-pool-slots)
        (intern-global-shared-view intern-pool-qualified-slots)
        (intern-global-shared-view intern-pool-last-slash-slots)
        (intern-global-shared-view intern-pool-first-dot-slots)
        (intern-global-shared-view intern-pool-leading-dot-id-slots)
        (intern-global-shared-view intern-pool-dotted-prefix-id-slots)
        (intern-global-shared-view intern-pool-module-id-slots)
        (intern-global-shared-view intern-pool-base-id-slots)
        (intern-global-shared-view intern-pool-macro-prefix-class-slots)
        pool-count
        generated-next-id
        (intern-global-shared-view intern-map-id-slots)
        (intern-global-shared-view intern-map-hash-slots)
        (intern-global-shared-view intern-generated-map-id-slots)
        (intern-global-shared-view intern-generated-map-hash-slots)
        map-ready
        reset-generation
        persistent-arena
        persistent-arena-floor-mark
        (intern-global-shared-view intern-structural-table-cell)))))

(define (intern-compat-state-pool-len [state : (& state InternCompatState)]) : i64
  (array-ref state.pool-count 0))

(define (intern-compat-state-generation [state : (& state InternCompatState)]) : i64
  (array-ref state.reset-generation 0))

(define (intern-compat-state-table-id [state : (& state InternCompatState)]) : i64
  (array-ref state.table-id 0))

(define (intern-compat-state-persistent-arena
  [state : (& state InternCompatState)]) : i64
  (array-ref state.persistent-arena 0))

;; Test-only raw view of the physical head. Public arena handles remain the
;; persistent root; growth is detected through the root's +56 current field.
(define (intern-compat-state-persistent-arena-current-head
  [state : (& state InternCompatState)]) : i64
  (let
    [root : i64 (intern-compat-state-persistent-arena state)]
    (if (= root 0)
      0
      (unsafe
        (ptr-read (ptr-offset (int->ptr root : (Ptr i64)) 7))))))

(define (intern-compat-state-persistent-arena-floor-mark
  [state : (& state InternCompatState)]) : i64
  (array-ref state.persistent-arena-floor-mark 0))

;; State-owned arena operations do not install an inactive `state` into the
;; compatibility globals. When the state is already active, keep its global
;; arena handles synchronized so they never retain destroyed storage.
(define (intern-compat-state-persistent-arena-floor-refresh!
  [state : (&mut state InternCompatState)]) : unit
  (let
    [prev-arena : i64 (tl_arena_current)]
    (begin
      (set! (array-ref state.persistent-arena-floor-mark 0) (tl_region_mark))
      (if (= (intern-active-table-id) (intern-compat-state-table-id state))
        (set!
          intern-persistent-arena-floor-mark
          (intern-compat-state-persistent-arena-floor-mark state))
        unit)
      unit)))

(define (intern-compat-state-persistent-arena-floor-ensure!
  [state : (&mut state InternCompatState)]) : unit
  (if (= (intern-compat-state-persistent-arena-floor-mark state) 0)
    (intern-compat-state-persistent-arena-floor-refresh! state)
    unit))

(define (intern-compat-state-persistent-arena-reset-to-floor!
  [state : (&mut state InternCompatState)]) : unit
  (let
    [prev-arena : i64 (tl_arena_current)]
    (begin
      (intern-compat-state-persistent-arena-floor-ensure! state)
      (unsafe
        (tl_arena_set (intern-compat-state-persistent-arena state))
        (tl_region_reset
          (intern-compat-state-persistent-arena-floor-mark state)))
      (intern-structural-table-reinitialize-in-arena!
        (&mut state.structural-table-cell)
        (intern-compat-state-persistent-arena state))
      (if (= (intern-active-table-id) (intern-compat-state-table-id state))
        (intern-active-structural-sync! (& state.structural-table-cell))
        unit)
      (unsafe
        (tl_arena_set prev-arena)))))

(define (intern-compat-state-persistent-arena-reset!
  [state : (&mut state InternCompatState)]) : unit
  (let
    [old-arena : i64 (intern-compat-state-persistent-arena state)]
    [new-arena : i64 (tl_arena_make)]
    [prev-arena : i64 (tl_arena_current)]
    [active? : bool
      (= (intern-active-table-id) (intern-compat-state-table-id state))]
    (begin
      (set! (array-ref state.persistent-arena 0) new-arena)
      (set! (array-ref state.persistent-arena-floor-mark 0) 0)
      (if active?
        (begin
          (set! intern-persistent-arena new-arena)
          (set! intern-persistent-arena-floor-mark 0))
        unit)
      (if (= prev-arena old-arena)
        (unsafe
          (tl_arena_set new-arena))
        unit)
      (intern-structural-table-reinitialize-in-arena!
        (&mut state.structural-table-cell)
        new-arena)
      (if active?
        (intern-active-structural-sync! (& state.structural-table-cell))
        unit)
      (unsafe
        (tl_arena_destroy old-arena))
      (intern-compat-state-persistent-arena-floor-refresh! state))))

(define (intern-compat-state-fill-empty!
  [state : (&mut state InternCompatState)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref state.map-id-slots index) (intern-id-slot-empty))
      (intern-compat-state-fill-empty! state (+ index 1) count))))

(define (intern-compat-state-generated-map-clear!
  [state : (&mut state InternCompatState)]) : unit
  (let
    [slots : (__tl_dyn-array InternSlotId) state.generated-map-id-slots]
    [index : i64 0]
    [count : i64 (array-length slots)]
    (while (< index count)
      (begin
        (set! (array-ref slots index) (intern-id-slot-empty))
        (set! index (+ index 1))))))

(define (intern-compat-state-map-insert-existing-from!
  [state : (&mut state InternCompatState)]
  [id : i64]
  [hash : i64]
  [cursor : i64]
  [steps : i64]
  [capacity : i64]) : unit
  (let
    [slot : i64 cursor]
    [probes : i64 steps]
    (while (< probes capacity)
      (if (intern-id-slot-empty? (array-ref state.map-id-slots slot))
        (begin
          (set! (array-ref state.map-id-slots slot) (intern-id-slot-encode id))
          (set! (array-ref state.map-hash-slots slot) hash)
          (return unit))
        (begin
          (set! slot (intern-bucket (+ slot 1) capacity))
          (set! probes (+ probes 1)))))))

(define (intern-compat-state-map-insert-existing!
  [state : (&mut state InternCompatState)]
  [id : i64]) : unit
  (let
    [name : String (intern-array-shared-view state.pool-slots id)]
    [hash : i64 (intern-hash (& name))]
    [capacity : i64 (array-length state.map-id-slots)]
    (intern-compat-state-map-insert-existing-from!
      state
      id
      hash
      (intern-bucket hash capacity)
      0
      capacity)))

(define (intern-compat-state-map-rebuild-prefix!
  [state : (&mut state InternCompatState)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (intern-compat-state-map-insert-existing! state index)
      (intern-compat-state-map-rebuild-prefix! state (+ index 1) count))))

(define (intern-compat-state-reset! [state : (&mut state InternCompatState)]) : unit
  (begin
    (set! (array-ref state.pool-count 0) 0)
    (set! (array-ref state.generated-next-id 0) (- (intern-capacity) 1))
    (intern-compat-state-fill-empty! state 0 (array-length state.map-id-slots))
    (intern-compat-state-generated-map-clear! state)
    (intern-structural-session-reset! (&mut state.structural-table-cell))
    (if (= (intern-active-table-id) (intern-compat-state-table-id state))
      (intern-active-structural-sync! (& state.structural-table-cell))
      unit)
    (set! (array-ref state.reset-generation 0) (intern-generation-allocate!))
    (set! (array-ref state.map-ready 0) true)))

(define (intern-compat-state-reset-to!
  [state : (&mut state InternCompatState)]
  [mark : i64]) : unit
  (begin
    (set! (array-ref state.pool-count 0) mark)
    (set! (array-ref state.generated-next-id 0) (- (intern-capacity) 1))
    (intern-compat-state-fill-empty! state 0 (array-length state.map-id-slots))
    (intern-compat-state-generated-map-clear! state)
    (intern-structural-session-reset! (&mut state.structural-table-cell))
    (if (= (intern-active-table-id) (intern-compat-state-table-id state))
      (intern-active-structural-sync! (& state.structural-table-cell))
      unit)
    (intern-compat-state-map-rebuild-prefix! state 0 mark)
    (set! (array-ref state.reset-generation 0) (intern-generation-allocate!))
    (set! (array-ref state.map-ready 0) true)))

(define (intern-compat-state-persistent-substring-ref
  [state : (& state InternCompatState)]
  [text : (& text str)]
  [start : i64]
  [len : i64]) : String
  (in-arena
    (arena.Arena (array-ref state.persistent-arena 0))
    (intern-substring text start len)))

(define (intern-compat-state-persistent-substring
  [state : (&mut state InternCompatState)]
  [text : (& text str)]
  [start : i64]
  [len : i64]) : String
  (intern-compat-state-persistent-substring-ref (& state) text start len))

(define (intern-compat-state-persistent-copy
  [state : (&mut state InternCompatState)]
  [text : (& text str)]) : String
  (intern-compat-state-persistent-substring
    state
    text
    0
    (intern-private-string-length text)))

(define (intern-compat-state-record-qualified-metadata-ref!
  [state : (& state InternCompatState)]
  [id : i64]
  [name : (& name str)]) : unit
  (let
    [i : i64 0]
    [n : i64 (intern-private-string-length name)]
    [slash : i64 -1]
    [dot : i64 -1]
    [last-dot : i64 -1]
    (begin
      (while (< i n)
        (let
          [c : char (intern-private-string-ref name i)]
          (begin
            (if (= c '/')
              (set! slash i)
              unit)
            (if (= c '.')
              (begin
                (if (< dot 0)
                  (set! dot i)
                  unit)
                (set! last-dot i))
              unit)
            (set! i (+ i 1)))))
      (set! (array-ref state.pool-last-slash-slots id) (cast slash : i32))
      (set! (array-ref state.pool-first-dot-slots id) (cast dot : i32))
      (set!
        (array-ref state.pool-macro-prefix-class-slots id)
        (intern-private-macro-prefix-class name))
      (set!
        (array-ref state.pool-leading-dot-id-slots id)
        (intern-id-slot-encode
          (if (< dot 0)
            -1
            (intern-compat-state-intern-ready-ref
              state
              (intern-substring name 0 dot)))))
      (set!
        (array-ref state.pool-dotted-prefix-id-slots id)
        (intern-id-slot-encode
          (if (< last-dot 0)
            -1
            (intern-compat-state-intern-ready-ref
              state
              (intern-substring name 0 last-dot)))))
      (if (< slash 0)
        (begin
          (set! (array-ref state.pool-qualified-slots id) false)
          (set!
            (array-ref state.pool-module-id-slots id)
            (intern-id-slot-encode -1))
          (set!
            (array-ref state.pool-base-id-slots id)
            (intern-id-slot-encode
              (if (< dot 0)
                id
                (intern-compat-state-intern-ready-ref
                  state
                  (intern-substring name (+ dot 1) (- n (+ dot 1))))))))
        (let
          [base-start : i64 (+ slash 1)]
          (begin
            (set! (array-ref state.pool-qualified-slots id) true)
            (set!
              (array-ref state.pool-module-id-slots id)
              (intern-id-slot-encode
                (intern-compat-state-intern-ready-ref
                  state
                  (intern-substring name 0 slash))))
            (set!
              (array-ref state.pool-base-id-slots id)
              (intern-id-slot-encode
                (intern-compat-state-intern-ready-ref
                  state
                  (intern-substring name base-start (- n base-start)))))))))))

;; State-owned interning mirrors the compatibility table without installing it
;; into process globals. Compile-job setup and reset paths use this API while
;; the legacy parser/typecheck/lower call graph is migrated incrementally.
(define (intern-compat-state-intern-ready-ref
  [state : (& state InternCompatState)]
  [name : (& name str)]) : i64
  (let
    [capacity : i64 (array-length state.map-id-slots)]
    [hash : i64 (intern-hash name)]
    [cursor : i64 (intern-bucket hash capacity)]
    [steps : i64 0]
    [out : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< steps capacity))
        (let
          [stored-empty? : bool
            (intern-id-slot-empty? (array-ref state.map-id-slots cursor))]
          (if stored-empty?
            (let
              [id : i64 (array-ref state.pool-count 0)]
              (if (> id (array-ref state.generated-next-id 0))
                (intern-pool-capacity-abort)
                (let
                  [persistent-name : String
                    (intern-compat-state-persistent-substring-ref
                      state
                      name
                      0
                      (intern-private-string-length name))]
                  (begin
                    (set! (array-ref state.pool-slots id) persistent-name)
                    (set!
                      (array-ref state.map-id-slots cursor)
                      (intern-id-slot-encode id))
                    (set! (array-ref state.map-hash-slots cursor) hash)
                    (set! (array-ref state.pool-count 0) (+ id 1))
                    (intern-compat-state-record-qualified-metadata-ref!
                      state
                      id
                      persistent-name)
                    (set! out id)
                    (set! done true)))))
            (let
              [slot-id : i64
                (intern-id-slot-decode (array-ref state.map-id-slots cursor))]
              [slot-hash : i64 (array-ref state.map-hash-slots cursor)]
              [slot-key : (& state str)
                (& (array-ref state.pool-slots slot-id))]
              (if (and
                (= slot-hash hash)
                (intern-private-string-eq slot-key name))
                (begin
                  (set! out slot-id)
                  (set! done true))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))))))
      out)))

(define (intern-compat-state-ensure-ready!
  [state : (&mut state InternCompatState)]) : unit
  (if (array-ref state.map-ready 0)
    unit
    (intern-compat-state-reset! state)))

(define (intern-compat-state-intern
  [state : (&mut state InternCompatState)]
  [name : String]) : i64
  (begin
    (intern-compat-state-ensure-ready! state)
    (intern-compat-state-intern-ready-ref (& state) (& name))))

;; State-owned source-slice interning. This is the explicit lexer boundary:
;; hits compare against the caller's source bytes without allocating, while
;; misses copy exactly one spelling into the supplied owner's persistent arena.
;; Unlike the active-table compatibility API, no process intern scalar or table
;; selector is read or published here.
(define (intern-compat-state-intern-slice-ready-ref
  [state : (& state InternCompatState)]
  [text : (& text str)]
  [start : i64]
  [len : i64]) : i64
  (begin
    (cfg compile-profile (intern-profile-note-slice len))
    (let
      [capacity : i64 (array-length state.map-id-slots)]
      [hash : i64 (intern-hash-slice text start len)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : i64 -1]
      [done : bool false]
      (begin
        (while (and (not done) (< steps capacity))
          (let
            [stored-empty? : bool
              (intern-id-slot-empty? (array-ref state.map-id-slots cursor))]
            (if stored-empty?
              (let
                [id : i64 (array-ref state.pool-count 0)]
                (if (> id (array-ref state.generated-next-id 0))
                  (intern-pool-capacity-abort)
                  (let
                    [persistent-name : String
                      (intern-compat-state-persistent-substring-ref
                        state
                        text
                        start
                        len)]
                    (begin
                      (cfg
                        compile-profile
                        (set!
                          intern-profile-slice-miss-count
                          (+ intern-profile-slice-miss-count 1)))
                      (set! (array-ref state.pool-slots id) persistent-name)
                      (set!
                        (array-ref state.map-id-slots cursor)
                        (intern-id-slot-encode id))
                      (set! (array-ref state.map-hash-slots cursor) hash)
                      (set! (array-ref state.pool-count 0) (+ id 1))
                      (intern-compat-state-record-qualified-metadata-ref!
                        state
                        id
                        persistent-name)
                      (set! out id)
                      (set! done true)))))
              (let
                [slot-id : i64
                  (intern-id-slot-decode (array-ref state.map-id-slots cursor))]
                [slot-hash : i64 (array-ref state.map-hash-slots cursor)]
                [slot-key : (& state str)
                  (& (array-ref state.pool-slots slot-id))]
                (if (and
                  (= slot-hash hash)
                  (intern-string-slice-eq? slot-key text start len))
                  (begin
                    (cfg
                      compile-profile
                      (set!
                        intern-profile-slice-hit-count
                        (+ intern-profile-slice-hit-count 1)))
                    (set! out slot-id)
                    (set! done true))
                  (begin
                    (set! cursor (intern-bucket (+ cursor 1) capacity))
                    (set! steps (+ steps 1))))))))
        out))))

(define (intern-compat-state-source-slice-id-ready-ref
  [state : (& state InternCompatState)]
  [text : (& text str)]
  [start : i64]
  [len : i64]) : InternId
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
    (intern-id-from-renderable
      (intern-compat-state-intern-slice-ready-ref state text start len))))

(define (intern-compat-state-source-slice-id
  [state : (&mut state InternCompatState)]
  [text : (& text str)]
  [start : i64]
  [len : i64]) : InternId
  (begin
    (intern-compat-state-ensure-ready! state)
    (intern-compat-state-source-slice-id-ready-ref (& state) text start len)))

(define (intern-compat-state-lookup
  [state : (& state InternCompatState)]
  [name : (& name str)]) : InternLookup
  (if (array-ref state.map-ready 0)
    (let
      [capacity : i64 (array-length state.map-id-slots)]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : InternLookup InternLookupMissing]
      [done : bool false]
      (begin
        (while (and (not done) (< steps capacity))
          (let
            [stored-empty? : bool
              (intern-id-slot-empty? (array-ref state.map-id-slots cursor))]
            (if stored-empty?
              (set! done true)
              (let
                [slot-id : i64
                  (intern-id-slot-decode (array-ref state.map-id-slots cursor))]
                [slot-hash : i64 (array-ref state.map-hash-slots cursor)]
                [slot-key : (& state str)
                  (& (array-ref state.pool-slots slot-id))]
                (if (and
                  (= slot-hash hash)
                  (intern-private-string-eq slot-key name))
                  (begin
                    (set! out (InternLookupFound slot-id))
                    (set! done true))
                  (begin
                    (set! cursor (intern-bucket (+ cursor 1) capacity))
                    (set! steps (+ steps 1))))))))
        out))
    (InternLookupMissing)))

(defmacro (intern-compat-state-str [state : Expr] [id : Expr]) : String
  `(intern-array-shared-view (__tl-project-field-name ,state "pool-slots") ,id))

(define (intern-compat-state-qualified?
  [state : (& state InternCompatState)]
  [id : i64]) : bool
  (array-ref state.pool-qualified-slots id))

(define (intern-compat-state-qualified-last-slash
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (cast (array-ref state.pool-last-slash-slots id) : i64))

(define (intern-compat-state-qualified-module-id
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (intern-id-slot-decode (array-ref state.pool-module-id-slots id)))

(define (intern-compat-state-qualified-base-id
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (intern-id-slot-decode (array-ref state.pool-base-id-slots id)))

(define (intern-compat-state-first-dot
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (cast (array-ref state.pool-first-dot-slots id) : i64))

(define (intern-compat-state-dotted-prefix-id
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (intern-id-slot-decode (array-ref state.pool-dotted-prefix-id-slots id)))

(define (intern-compat-state-dotted-tail-id
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (let
    [base-id : i64
      (if (intern-compat-state-qualified? state id)
        (intern-compat-state-qualified-base-id state id)
        id)]
    (if (< (intern-compat-state-first-dot state base-id) 0)
      -1
      (let
        [tail-id : i64
          (intern-id-slot-decode (array-ref state.pool-base-id-slots base-id))]
        (if (= tail-id base-id)
          -1
          tail-id)))))

(define (intern-compat-state-dotted-final-id
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (let
    [current : i64
      (if (intern-compat-state-qualified? state id)
        (intern-compat-state-qualified-base-id state id)
        id)]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [tail-id : i64 (intern-compat-state-dotted-tail-id state current)]
          (if (< tail-id 0)
            (set! done true)
            (set! current tail-id))))
      current)))

(define (intern-compat-state-dotted?
  [state : (& state InternCompatState)]
  [id : i64]) : bool
  (>= (intern-compat-state-first-dot state id) 0))

(define (intern-compat-state-macro-local-name-id?
  [state : (& state InternCompatState)]
  [id : i64]) : bool
  (=
    (array-ref state.pool-macro-prefix-class-slots id)
    (cast (intern-macro-prefix-class-local) : u8)))

(define (intern-compat-state-install! [state : InternCompatState]) : unit
  (let
    [next-table-id : i64 (intern-compat-state-table-id state)]
    (begin
      (set! intern-active-table-id-value next-table-id)
      (set! intern-pool-slots state.pool-slots)
      (set! intern-pool-qualified-slots state.pool-qualified-slots)
      (set! intern-pool-last-slash-slots state.pool-last-slash-slots)
      (set! intern-pool-first-dot-slots state.pool-first-dot-slots)
      (set! intern-pool-leading-dot-id-slots state.pool-leading-dot-id-slots)
      (set!
        intern-pool-dotted-prefix-id-slots
        state.pool-dotted-prefix-id-slots)
      (set! intern-pool-module-id-slots state.pool-module-id-slots)
      (set! intern-pool-base-id-slots state.pool-base-id-slots)
      (set!
        intern-pool-macro-prefix-class-slots
        state.pool-macro-prefix-class-slots)
      (set! intern-pool-count (array-ref state.pool-count 0))
      (set! intern-generated-next-id (array-ref state.generated-next-id 0))
      (set! intern-map-id-slots state.map-id-slots)
      (set! intern-map-hash-slots state.map-hash-slots)
      (set! intern-generated-map-id-slots state.generated-map-id-slots)
      (set! intern-generated-map-hash-slots state.generated-map-hash-slots)
      (set! intern-map-ready (array-ref state.map-ready 0))
      (set! intern-reset-generation (array-ref state.reset-generation 0))
      (set! intern-name-cache-ready false)
      (set! intern-persistent-arena (array-ref state.persistent-arena 0))
      (set!
        intern-persistent-arena-floor-mark
        (array-ref state.persistent-arena-floor-mark 0))
      (set! intern-structural-table-cell state.structural-table-cell)
      (intern-active-structural-sync! (& intern-structural-table-cell)))))

(define (intern-compat-state-capture-from-globals!
  [state : (&mut state InternCompatState)]) : unit
  (begin
    (set! (array-ref state.pool-count 0) intern-pool-count)
    (set! (array-ref state.generated-next-id 0) intern-generated-next-id)
    (set! (array-ref state.map-ready 0) intern-map-ready)
    (set! (array-ref state.reset-generation 0) intern-reset-generation)
    (set! (array-ref state.persistent-arena 0) intern-persistent-arena)
    (set!
      (array-ref state.persistent-arena-floor-mark 0)
      intern-persistent-arena-floor-mark)))

;; Compatibility-only observation for state-isolation tests. Production
;; state-owned operations use `intern-compat-state-persistent-arena` instead.
(define (intern-persistent-arena-handle) : i64
  intern-persistent-arena)

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
      (intern-structural-table-reinitialize-in-arena!
        (&mut intern-structural-table-cell)
        new-arena)
      (intern-active-structural-sync! (& intern-structural-table-cell))
      (unsafe
        (tl_arena_destroy old-arena))
      (intern-persistent-arena-floor-refresh!))))

(define (intern-persistent-arena-floor-refresh!) : unit
  (in-arena
    (arena.Arena intern-persistent-arena)
    (set! intern-persistent-arena-floor-mark (tl_region_mark))))

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
        (tl_region_reset intern-persistent-arena-floor-mark))
      (intern-structural-table-reinitialize-in-arena!
        (&mut intern-structural-table-cell)
        intern-persistent-arena)
      (intern-active-structural-sync! (& intern-structural-table-cell))
      (unsafe
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
;; intern-lookup. The render counter records each successful intern-str call;
;; invalid IDs stay separate so diagnostics cannot hide semantic render work.
;; `compiler_intern` has no formatting dependency, so it only exposes reset and
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
  (define intern-profile-generated-count : i64
    0))
(cfg
  compile-profile
  (define intern-profile-render-count : i64
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
  (define intern-profile-generated-role-create-counts : (__tl_dyn-array i64)
    (__tl_make-array i64 16)))
(cfg
  compile-profile
  (define intern-profile-generated-role-reuse-counts : (__tl_dyn-array i64)
    (__tl_make-array i64 16)))
(cfg
  compile-profile
  (define intern-profile-generated-role-render-counts : (__tl_dyn-array i64)
    (__tl_make-array i64 16)))

(cfg
  compile-profile
  (define (intern-profile-reset!) : unit
    (begin
      (set! intern-profile-hash-words-count 0)
      (set! intern-profile-intern-count 0)
      (set! intern-profile-slice-count 0)
      (set! intern-profile-lookup-count 0)
      (set! intern-profile-generated-count 0)
      (set! intern-profile-render-count 0)
      (set! intern-profile-invalid-str-count 0)
      (set! intern-profile-invalid-str-last-id 0)
      (set! intern-profile-source-bytes-count 0)
      (set! intern-profile-source-symbol-count 0)
      (set! intern-profile-source-symbol-bytes-count 0)
      (set! intern-profile-slice-bytes-count 0)
      (set! intern-profile-slice-hit-count 0)
      (set! intern-profile-slice-miss-count 0)
      (let
        [index : i64 0]
        (while (< index 16)
          (begin
            (set!
              (array-ref intern-profile-generated-role-create-counts index)
              0)
            (set!
              (array-ref intern-profile-generated-role-reuse-counts index)
              0)
            (set!
              (array-ref intern-profile-generated-role-render-counts index)
              0)
            (set! index (+ index 1))))))))

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
  (define (intern-profile-generated-value) : i64
    intern-profile-generated-count))

(cfg
  compile-profile
  (define (intern-profile-render-value) : i64
    intern-profile-render-count))

(cfg
  compile-profile
  (define (intern-profile-invalid-str-value) : i64
    intern-profile-invalid-str-count))

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
  (define (intern-profile-generated-role-create-value [role : i64]) : i64
    (let
      [index : i64 (intern-generated-symbol-role-index role)]
      (if (< index 0)
        (tl_oob_abort)
        (array-ref intern-profile-generated-role-create-counts index)))))

(cfg
  compile-profile
  (define (intern-profile-generated-role-reuse-value [role : i64]) : i64
    (let
      [index : i64 (intern-generated-symbol-role-index role)]
      (if (< index 0)
        (tl_oob_abort)
        (array-ref intern-profile-generated-role-reuse-counts index)))))

(cfg
  compile-profile
  (define (intern-profile-generated-role-render-value [role : i64]) : i64
    (let
      [index : i64 (intern-generated-symbol-role-index role)]
      (if (< index 0)
        (tl_oob_abort)
        (array-ref intern-profile-generated-role-render-counts index)))))

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
  (define (intern-profile-note-generated-role-create [role : i64]) : unit
    (let
      [index : i64 (intern-generated-symbol-role-index role)]
      (if (< index 0)
        (tl_oob_abort)
        (set!
          (array-ref intern-profile-generated-role-create-counts index)
          (+ (array-ref intern-profile-generated-role-create-counts index) 1))))))

(cfg
  compile-profile
  (define (intern-profile-note-generated-role-reuse [role : i64]) : unit
    (let
      [index : i64 (intern-generated-symbol-role-index role)]
      (if (< index 0)
        (tl_oob_abort)
        (set!
          (array-ref intern-profile-generated-role-reuse-counts index)
          (+ (array-ref intern-profile-generated-role-reuse-counts index) 1))))))

(cfg
  compile-profile
  (define (intern-profile-note-generated-role-render [role : i64]) : unit
    (let
      [index : i64 (intern-generated-symbol-role-index role)]
      (if (< index 0)
        (tl_oob_abort)
        (set!
          (array-ref intern-profile-generated-role-render-counts index)
          (+ (array-ref intern-profile-generated-role-render-counts index) 1))))))

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

(define (intern-hash [s : (& s str)]) : i64
  (intern-hash-words
    (unsafe
      (string-data s))
    0
    (__tl_string_length s)))

;: Hash over a source slice without first allocating a substring.
(define (intern-hash-slice [s : (& s str)] [start : i64] [len : i64]) : i64
  (intern-hash-words
    (unsafe
      (string-data s))
    start
    len))

;: Mask `hash` into `[0, capacity)`; capacity is a power of two.
(define (intern-bucket [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

(define (intern-substring [text : (& text str)] [start : i64] [len : i64]) : String
  (let
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 len)]
    [src : (Ptr u8)
      (unsafe
        (string-data text))]
    [dst : (MutPtr u8)
      (unsafe
        (__tl_array-data buf))]
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

(define (intern-persistent-substring
  [text : (& text str)]
  [start : i64]
  [len : i64]) : String
  (let
    [prev-arena : i64 (tl_arena_current)]
    (if (= prev-arena intern-persistent-arena)
      (let
        [copied : String (intern-substring text start len)]
        (begin
          (set! intern-persistent-arena (tl_arena_current))
          copied))
      (let
        [out : String
          (begin
            (unsafe
              (tl_arena_set intern-persistent-arena))
            (let
              [copied : String (intern-substring text start len)]
              (begin
                (set! intern-persistent-arena (tl_arena_current))
                (unsafe
                  (tl_arena_set prev-arena))
                copied)))]
        out))))

(define (intern-persistent-copy [text : (& text str)]) : String
  (intern-persistent-substring text 0 (__tl_string_length text)))

;; Explicit structural-session caches share the source-name session's
;; persistent arena. Keep this small boundary here so the structural adapter
;; does not need to duplicate arena switching and byte-copy details.
(define (intern-persistent-copy-in-arena [arena-handle : i64] [text : String]) : String
  (if (= (tl_arena_current) arena-handle)
    text
    (in-arena
      (arena.Arena arena-handle)
      (intern-substring text 0 (__tl_string_length text)))))

(define (intern-composite-rendered-name [id : i64]) : String
  (if (or (intern-composite-pair-id? id) (intern-composite-triple-id? id))
    (array-ref
      (__tl-project-field
        (array-ref (intern-global-shared-view intern-structural-table-cell) 0)
        rendered-names)
      (- (bit-and id (intern-structural-key-index-mask)) 1))
    ""))

(define (intern-composite-rendered-name-record! [id : i64] [name : String]) : String
  (let
    [cached : String (intern-composite-rendered-name id)]
    (if (> (__tl_string_length cached) 0)
      cached
      (let
        [persistent : String (intern-persistent-copy (& name))]
        [index : i64 (- (bit-and id (intern-structural-key-index-mask)) 1)]
        (begin
          (set!
            (array-ref
              (__tl-project-field
                (array-ref intern-structural-table-cell 0)
                rendered-names)
              index)
            persistent)
          persistent)))))

;: Reserve a source id from the low end of the shared pool. Generated ids grow
;: down from the high end, so neither kind can silently overwrite the other.
(define (intern-source-id-allocate!) : i64
  (if (> intern-pool-count intern-generated-next-id)
    (intern-pool-capacity-abort)
    (let
      [id : i64 intern-pool-count]
      (begin
        (set! intern-pool-count (+ id 1))
        id))))

(define (intern-generated-id-allocate!) : i64
  (if (< intern-generated-next-id intern-pool-count)
    (intern-pool-capacity-abort)
    (let
      [id : i64 intern-generated-next-id]
      (begin
        (set! intern-generated-next-id (- id 1))
        id))))

(define (intern-compat-state-generated-scalars-publish-if-active!
  [state : (& state InternCompatState)]) : unit
  (if (= (intern-active-table-id) (intern-compat-state-table-id state))
    (begin
      (set! intern-pool-count (array-ref state.pool-count 0))
      (set! intern-generated-next-id (array-ref state.generated-next-id 0))
      (set! intern-map-ready (array-ref state.map-ready 0))
      (set! intern-reset-generation (array-ref state.reset-generation 0)))
    unit))

;; State-owned generated allocation. Generated ids share the same high-end
;; lane as the compatibility allocator, but all metadata and the monotonic
;; counter live in the supplied state; no active-table installation is needed.
(define (intern-compat-state-generated-name-store
  [state : (&mut state InternCompatState)]
  [name : String]
  [qualified : bool]
  [module-id : i64]
  [base-id : i64]) : i64
  (begin
    (if (array-ref state.map-ready 0)
      unit
      (intern-compat-state-reset! state))
    (cfg compile-profile (intern-profile-note-generated))
    (let
      [next-id : i64 (array-ref state.generated-next-id 0)]
      (if (< next-id (intern-compat-state-pool-len state))
        (intern-pool-capacity-abort)
        (let
          [persistent-name : String
            (intern-compat-state-persistent-copy state (& name))]
          (begin
            (set! (array-ref state.pool-slots next-id) persistent-name)
            (set! (array-ref state.pool-qualified-slots next-id) qualified)
            (set!
              (array-ref state.pool-macro-prefix-class-slots next-id)
              (intern-private-macro-prefix-class persistent-name))
            (set!
              (array-ref state.pool-last-slash-slots next-id)
              (if qualified
                (cast (intern-private-last-slash persistent-name) : i32)
                (cast -1 : i32)))
            (set!
              (array-ref state.pool-first-dot-slots next-id)
              (cast -1 : i32))
            (set!
              (array-ref state.pool-leading-dot-id-slots next-id)
              (intern-id-slot-encode -1))
            (set!
              (array-ref state.pool-dotted-prefix-id-slots next-id)
              (intern-id-slot-encode -1))
            (set!
              (array-ref state.pool-module-id-slots next-id)
              (intern-id-slot-encode module-id))
            (set!
              (array-ref state.pool-base-id-slots next-id)
              (intern-id-slot-encode
                (if qualified
                  base-id
                  next-id)))
            (set! (array-ref state.generated-next-id 0) (- next-id 1))
            ;; An installed legacy consumer observes scalar counters through
            ;; the compatibility globals even though the owned arrays are
            ;; already shared. Keep that view coherent without installing an
            ;; inactive state or adding a lowerer-side bridge.
            (intern-compat-state-generated-scalars-publish-if-active! state)
            next-id))))))

(define (intern-compat-state-generated-name
  [state : (&mut state InternCompatState)]
  [name : String]) : i64
  (intern-compat-state-generated-name-store state name false -1 -1))

(define (intern-compat-state-generated-canonical-name-at
  [state : (&mut state InternCompatState)]
  [name : String]
  [hash : i64]
  [cursor : i64]
  [steps : i64]
  [qualified : bool]
  [module-id : i64]
  [base-id : i64]) : i64
  (let
    [capacity : i64 (array-length state.generated-map-id-slots)]
    (if (>= steps capacity)
      (tl_oob_abort)
      (let
        [stored-id : InternSlotId
          (array-ref state.generated-map-id-slots cursor)]
        (if (intern-id-slot-empty? stored-id)
          (let
            [id : i64
              (intern-compat-state-generated-name-store
                state
                name
                qualified
                module-id
                base-id)]
            (begin
              (set!
                (array-ref state.generated-map-id-slots cursor)
                (intern-id-slot-encode id))
              (set! (array-ref state.generated-map-hash-slots cursor) hash)
              id))
          (let
            [slot-id : i64 (intern-id-slot-decode stored-id)]
            [slot-hash : i64 (array-ref state.generated-map-hash-slots cursor)]
            (if (and
              (= slot-hash hash)
              (intern-private-string-eq-places
                (array-ref state.pool-slots slot-id)
                name)
              (if qualified
                (and
                  (intern-compat-state-qualified? state slot-id)
                  (=
                    (intern-compat-state-qualified-module-id state slot-id)
                    module-id)
                  (=
                    (intern-compat-state-qualified-base-id state slot-id)
                    base-id))
                (and
                  (not (intern-compat-state-qualified? state slot-id))
                  (<
                    (cast (array-ref state.pool-first-dot-slots slot-id) : i64)
                    0))))
              slot-id
              (intern-compat-state-generated-canonical-name-at
                state
                name
                hash
                (intern-bucket (+ cursor 1) capacity)
                (+ steps 1)
                qualified
                module-id
                base-id))))))))

(define (intern-compat-state-generated-canonical-qualified-name
  [state : (&mut state InternCompatState)]
  [name : String]
  [module-id : i64]
  [base-id : i64]) : i64
  (begin
    (if (or (< module-id 0) (< base-id 0))
      (tl_oob_abort)
      unit)
    (if (array-ref state.map-ready 0)
      unit
      (intern-compat-state-reset! state))
    (let
      [capacity : i64 (array-length state.generated-map-id-slots)]
      [hash : i64
        (bit-xor
          (intern-hash name)
          (bit-xor
            4611686018427387904
            (bit-xor (shl module-id 1) (shl base-id 18))))]
      (intern-compat-state-generated-canonical-name-at
        state
        name
        hash
        (intern-bucket hash capacity)
        0
        true
        module-id
        base-id))))

;; Reserve a renderable generated-symbol lane without constructing its text.
;; The caller owns the structural record and must materialize the exact spelling
;; before crossing a text boundary. Metadata consumers can use the handle in the
;; meantime with the same zero-cost array access as every other generated name.
(define (intern-compat-state-generated-symbol-handle
  [state : (&mut state InternCompatState)]) : i64
  (begin
    (if (array-ref state.map-ready 0)
      unit
      (intern-compat-state-reset! state))
    (let
      [next-id : i64 (array-ref state.generated-next-id 0)]
      (if (< next-id (intern-compat-state-pool-len state))
        (intern-pool-capacity-abort)
        (begin
          (set! (array-ref state.pool-slots next-id) "")
          (set! (array-ref state.pool-qualified-slots next-id) false)
          (set! (array-ref state.pool-last-slash-slots next-id) (cast -1 : i32))
          (set! (array-ref state.pool-first-dot-slots next-id) (cast -1 : i32))
          (set!
            (array-ref state.pool-leading-dot-id-slots next-id)
            (intern-id-slot-encode -1))
          (set!
            (array-ref state.pool-dotted-prefix-id-slots next-id)
            (intern-id-slot-encode -1))
          (set!
            (array-ref state.pool-module-id-slots next-id)
            (intern-id-slot-encode -1))
          (set!
            (array-ref state.pool-base-id-slots next-id)
            (intern-id-slot-encode next-id))
          (set! (array-ref state.generated-next-id 0) (- next-id 1))
          (intern-compat-state-generated-scalars-publish-if-active! state)
          next-id)))))

(define (intern-compat-state-generated-symbol-materialize!
  [state : (&mut state InternCompatState)]
  [id : i64]
  [name : String]) : String
  (if (intern-compat-state-generated-id-active? state id)
    (let
      [cached : String (intern-array-shared-view state.pool-slots id)]
      (if (> (intern-private-string-length cached) 0)
        cached
        (let
          [persistent : String
            (intern-compat-state-persistent-copy state (& name))]
          (begin
            (set! (array-ref state.pool-slots id) persistent)
            persistent))))
    (tl_oob_abort)))

(define (intern-compat-state-generated-id-active?
  [state : (& state InternCompatState)]
  [id : i64]) : bool
  (and
    (>= id (intern-compat-state-pool-len state))
    (> id (array-ref state.generated-next-id 0))
    (< id (intern-capacity))))

(define (intern-compat-state-generated-count
  [state : (& state InternCompatState)]) : i64
  (- (- (intern-capacity) 1) (array-ref state.generated-next-id 0)))

(define (intern-generated-id-active? [id : i64]) : bool
  (and
    (>= id intern-pool-count)
    (> id intern-generated-next-id)
    (< id (intern-capacity))))

;; Snapshot producers enumerate generated identities in allocation order. The
;; high-end numeric representation is deliberately kept behind these helpers:
;; serialized consumers must rebuild process-local identities instead of
;; treating an id from the producing generation as portable.
(define (intern-generated-count) : i64
  (- (- (intern-capacity) 1) intern-generated-next-id))

;; Explicit structural identities mirror the active compatibility helpers while
;; selecting the owner/session table from the argument.  Structural ids are
;; never inserted into the source string interner.
(define (intern-compat-state-structural-prefix
  [state : (& state InternCompatState)]) : i64
  (+
    (intern-structural-key-base)
    (*
      (__tl-project-field (array-ref state.structural-table-cell 0) owner)
      (intern-structural-key-owner-stride))))

(define (intern-compat-state-structural-count
  [state : (& state InternCompatState)]) : i64
  (__tl-project-field (array-ref state.structural-table-cell 0) len))

(define (intern-compat-state-composite-pair-id
  [state : (&mut state InternCompatState)]
  [left-id : i64]
  [right-id : i64]) : i64
  (let
    [arena : i64 (intern-compat-state-persistent-arena state)]
    (intern-structural-table-intern
      (&mut state.structural-table-cell)
      arena
      (intern-structural-kind-pair)
      left-id
      0
      right-id)))

(define (intern-compat-state-composite-triple-id
  [state : (&mut state InternCompatState)]
  [left-id : i64]
  [middle-id : i64]
  [right-id : i64]) : i64
  (let
    [arena : i64 (intern-compat-state-persistent-arena state)]
    (intern-structural-table-intern
      (&mut state.structural-table-cell)
      arena
      (intern-structural-kind-triple)
      left-id
      middle-id
      right-id)))

(define (intern-compat-state-composite-pair-id?
  [state : (& state InternCompatState)]
  [id : i64]) : bool
  (let
    [table : (& state InternStructuralTable)
      (& (array-ref state.structural-table-cell 0))]
    [prefix : i64 (intern-compat-state-structural-prefix state)]
    [encoded-index : i64 (- id prefix)]
    (and
      (> encoded-index 0)
      (<= encoded-index table.len)
      (=
        (cast (array-ref table.kinds (- encoded-index 1)) : i64)
        (intern-structural-kind-pair)))))

(define (intern-compat-state-composite-triple-id?
  [state : (& state InternCompatState)]
  [id : i64]) : bool
  (let
    [table : (& state InternStructuralTable)
      (& (array-ref state.structural-table-cell 0))]
    [prefix : i64 (intern-compat-state-structural-prefix state)]
    [encoded-index : i64 (- id prefix)]
    (and
      (> encoded-index 0)
      (<= encoded-index table.len)
      (=
        (cast (array-ref table.kinds (- encoded-index 1)) : i64)
        (intern-structural-kind-triple)))))

(define (intern-compat-state-composite-left-id-unchecked
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (array-ref
    (__tl-project-field (array-ref state.structural-table-cell 0) lefts)
    (- (bit-and id (intern-structural-key-index-mask)) 1)))

(define (intern-compat-state-composite-middle-id-unchecked
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (array-ref
    (__tl-project-field (array-ref state.structural-table-cell 0) middles)
    (- (bit-and id (intern-structural-key-index-mask)) 1)))

(define (intern-compat-state-composite-right-id-unchecked
  [state : (& state InternCompatState)]
  [id : i64]) : i64
  (array-ref
    (__tl-project-field (array-ref state.structural-table-cell 0) rights)
    (- (bit-and id (intern-structural-key-index-mask)) 1)))

(define (intern-compat-state-composite-rendered-name
  [state : (& state InternCompatState)]
  [id : i64]) : String
  (if (or
    (intern-compat-state-composite-pair-id? state id)
    (intern-compat-state-composite-triple-id? state id))
    (intern-array-shared-view
      (__tl-project-field
        (array-ref state.structural-table-cell 0)
        rendered-names)
      (- (bit-and id (intern-structural-key-index-mask)) 1))
    ""))

(define (intern-compat-state-composite-rendered-name-record!
  [state : (&mut state InternCompatState)]
  [id : i64]
  [name : String]) : String
  (let
    [cached : String (intern-compat-state-composite-rendered-name state id)]
    (if (> (__tl_string_length cached) 0)
      cached
      (let
        [persistent : String
          (intern-compat-state-persistent-copy state (& name))]
        [index : i64 (- (bit-and id (intern-structural-key-index-mask)) 1)]
        (begin
          (set!
            (array-ref
              (__tl-project-field
                (array-ref state.structural-table-cell 0)
                rendered-names)
              index)
            persistent)
          persistent)))))

(define (intern-generated-id-at-allocation-index [index : i64]) : i64
  (if (or (< index 0) (>= index (intern-generated-count)))
    -1
    (- (- (intern-capacity) 1) index)))

(define (intern-generated-canonical-id-at? [id : i64] [index : i64]) : bool
  (if (>= index intern-generated-map-capacity)
    false
    (let
      [stored : InternSlotId (array-ref intern-generated-map-id-slots index)]
      (if (and
        (not (intern-id-slot-empty? stored))
        (= (intern-id-slot-decode stored) id))
        true
        (intern-generated-canonical-id-at? id (+ index 1))))))

(define (intern-generated-canonical-id? [id : i64]) : bool
  (and
    (intern-generated-id-active? id)
    (intern-generated-canonical-id-at? id 0)))

(define (intern-private-last-slash [name : (& name str)]) : i64
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

;; Generated-symbol roles are deliberately outside the source/generated id
;; lanes. They are structural recipe tags, never renderable symbols by
;; themselves. A role recipe is a triple of (role, qualification, components),
;; where qualification is zero or a structural (module, base) pair.
(define (intern-generated-symbol-role-clone-helper) : i64
  -101)

(define (intern-generated-symbol-role-lambda) : i64
  -102)

(define (intern-generated-symbol-role-global-initializer) : i64
  -103)

(define (intern-generated-symbol-role-cleanup-helper) : i64
  -104)

(define (intern-generated-symbol-role-cleanup-parameter) : i64
  -105)

(define (intern-generated-symbol-role-cleanup-payload) : i64
  -106)

(define (intern-generated-symbol-role-dispatch-cache) : i64
  -107)

(define (intern-generated-symbol-role-dispatch-variant) : i64
  -108)

(define (intern-generated-symbol-role-nullary-enum-object) : i64
  -109)

;; SPMD package ABI roles keep the versioned identity recipe distinct from the
;; linker symbol derived from its stable hash. Result wrappers are shared by
;; package exports and same-program private helpers; their structural base
;; handle keeps those two domains distinct without spelling-based lookup.
(define (intern-generated-symbol-role-spmd-identity) : i64
  -110)

(define (intern-generated-symbol-role-spmd-package-symbol) : i64
  -111)

(define (intern-generated-symbol-role-spmd-result-uniform) : i64
  -112)

(define (intern-generated-symbol-role-spmd-result-varying) : i64
  -113)

(define (intern-generated-symbol-role-spmd-result-mask) : i64
  -114)

(define (intern-generated-symbol-role-spmd-private-helper) : i64
  -115)

(define (intern-generated-symbol-role-spmd-private-parameter) : i64
  -116)

(define (intern-generated-symbol-role-index [role : i64]) : i64
  (cond
    [(= role (intern-generated-symbol-role-clone-helper)) 0]
    [(= role (intern-generated-symbol-role-lambda)) 1]
    [(= role (intern-generated-symbol-role-global-initializer)) 2]
    [(= role (intern-generated-symbol-role-cleanup-helper)) 3]
    [(= role (intern-generated-symbol-role-cleanup-parameter)) 4]
    [(= role (intern-generated-symbol-role-cleanup-payload)) 5]
    [(= role (intern-generated-symbol-role-dispatch-cache)) 6]
    [(= role (intern-generated-symbol-role-dispatch-variant)) 7]
    [(= role (intern-generated-symbol-role-nullary-enum-object)) 8]
    [(= role (intern-generated-symbol-role-spmd-identity)) 9]
    [(= role (intern-generated-symbol-role-spmd-package-symbol)) 10]
    [(= role (intern-generated-symbol-role-spmd-result-uniform)) 11]
    [(= role (intern-generated-symbol-role-spmd-result-varying)) 12]
    [(= role (intern-generated-symbol-role-spmd-result-mask)) 13]
    [(= role (intern-generated-symbol-role-spmd-private-helper)) 14]
    [(= role (intern-generated-symbol-role-spmd-private-parameter)) 15]
    [else -1]))

(define (intern-compat-state-generated-role-key
  [state : (&mut state InternCompatState)]
  [role : i64]
  [qualification : i64]
  [components : i64]) : i64
  (if (< (intern-generated-symbol-role-index role) 0)
    (tl_oob_abort)
    (intern-compat-state-composite-triple-id
      state
      role
      qualification
      components)))

(define (intern-compat-state-generated-role-refresh-active!
  [state : (&mut state InternCompatState)]) : unit
  ;; Parsing, macro expansion, and typechecking still have compatibility
  ;; callers that reserve generated IDs through the installed global view.
  ;; A driver-owned state captured before those phases shares the arrays but
  ;; not their scalar frontier cells, so refresh that frontier immediately
  ;; before a role handle is reserved. Inactive simultaneous states remain
  ;; fully independent and are never installed here.
  (if (= (intern-active-table-id) (intern-compat-state-table-id state))
    (intern-compat-state-capture-from-globals! state)
    unit))

(define (intern-compat-state-generated-role-symbol-id-from-key
  [state : (&mut state InternCompatState)]
  [role : i64]
  [key : i64]
  [qualified : bool]
  [module-id : i64]
  [base-id : i64]) : i64
  (let
    [index : i64 (- (bit-and key (intern-structural-key-index-mask)) 1)]
    [table : InternStructuralTable
      (intern-array-shared-view state.structural-table-cell 0)]
    [existing : InternSlotId (array-ref table.generated-symbol-handles index)]
    (if (not (intern-id-slot-empty? existing))
      (let
        [id : i64 (intern-id-slot-decode existing)]
        (begin
          ;; A legacy/global caller can publish this shared record after the
          ;; active explicit-state view captured its scalar frontier. Refresh
          ;; only that stale reuse case; known handles and inactive independent
          ;; states keep the fast path.
          (if (intern-compat-state-generated-id-active? state id)
            unit
            (intern-compat-state-generated-role-refresh-active! state))
          (if (intern-compat-state-generated-id-active? state id)
            unit
            (tl_oob_abort))
          (cfg compile-profile (intern-profile-note-generated-role-reuse role))
          id))
      (let
        [_refresh-active : unit
          (intern-compat-state-generated-role-refresh-active! state)]
        [id : i64 (intern-compat-state-generated-symbol-handle state)]
        (begin
          ;; Structural role membership is an internal O(1) query. Generated
          ;; role names never use source dotted-name metadata, so retain the
          ;; negative role tag in that lane through materialization.
          (set! (array-ref state.pool-first-dot-slots id) (cast role : i32))
          (if qualified
            (begin
              (set! (array-ref state.pool-qualified-slots id) true)
              (set!
                (array-ref state.pool-module-id-slots id)
                (intern-id-slot-encode module-id))
              (set!
                (array-ref state.pool-base-id-slots id)
                (intern-id-slot-encode base-id)))
            unit)
          ;; Allocation may grow unrelated state arrays, but the structural
          ;; table is arena-stable. Reload it before publishing the handle so
          ;; the write always targets the current record storage.
          (set!
            (array-ref
              (__tl-project-field
                (array-ref state.structural-table-cell 0)
                generated-symbol-handles)
              index)
            (intern-id-slot-encode id))
          (cfg compile-profile (intern-profile-note-generated-role-create role))
          id)))))

(define (intern-compat-state-generated-role-symbol-id
  [state : (&mut state InternCompatState)]
  [role : i64]
  [components : i64]) : i64
  (begin
    (if (array-ref state.map-ready 0)
      unit
      (intern-compat-state-reset! state))
    (let
      [key : i64
        (intern-compat-state-generated-role-key state role 0 components)]
      (intern-compat-state-generated-role-symbol-id-from-key
        state
        role
        key
        false
        -1
        -1))))

(define (intern-compat-state-generated-role-qualified-symbol-id
  [state : (&mut state InternCompatState)]
  [role : i64]
  [components : i64]
  [module-id : i64]
  [base-id : i64]) : i64
  (if (or (< module-id 0) (< base-id 0))
    (tl_oob_abort)
    (begin
      (if (array-ref state.map-ready 0)
        unit
        (intern-compat-state-reset! state))
      (let
        [qualification : i64
          (intern-compat-state-composite-pair-id state module-id base-id)]
        [key : i64
          (intern-compat-state-generated-role-key
            state
            role
            qualification
            components)]
        (intern-compat-state-generated-role-symbol-id-from-key
          state
          role
          key
          true
          module-id
          base-id)))))

;; Rendering is explicit and idempotent. Constructors above perform no string
;; concatenation or hashing; the caller supplies the legacy spelling only when
;; crossing a diagnostic, serialization, or backend text boundary.
(define (intern-compat-state-generated-role-symbol-materialize!
  [state : (&mut state InternCompatState)]
  [role : i64]
  [id : i64]
  [name : String]) : String
  (if (< (intern-generated-symbol-role-index role) 0)
    (tl_oob_abort)
    (let
      [cached : String (intern-array-shared-view state.pool-slots id)]
      [rendered : String
        (intern-compat-state-generated-symbol-materialize! state id name)]
      (begin
        (if (= (intern-private-string-length cached) 0)
          (begin
            (set!
              (array-ref state.pool-macro-prefix-class-slots id)
              (intern-private-macro-prefix-class rendered))
            (if (array-ref state.pool-qualified-slots id)
              (set!
                (array-ref state.pool-last-slash-slots id)
                (cast (intern-private-last-slash rendered) : i32))
              unit)
            (cfg
              compile-profile
              (intern-profile-note-generated-role-render role)))
          unit)
        rendered))))

;; Compatibility wrappers for phases that still operate on the installed
;; compile job. They use the same structural table and generated lane as the
;; explicit-state constructors; no second owner or spelling-keyed cache exists.
(define (intern-generated-role-symbol-handle) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (let
      [id : i64 (intern-generated-id-allocate!)]
      (begin
        (set! (array-ref intern-pool-slots id) "")
        (set! (array-ref intern-pool-qualified-slots id) false)
        (set! (array-ref intern-pool-last-slash-slots id) (cast -1 : i32))
        (set! (array-ref intern-pool-first-dot-slots id) (cast -1 : i32))
        (set!
          (array-ref intern-pool-leading-dot-id-slots id)
          (intern-id-slot-encode -1))
        (set!
          (array-ref intern-pool-dotted-prefix-id-slots id)
          (intern-id-slot-encode -1))
        (set!
          (array-ref intern-pool-module-id-slots id)
          (intern-id-slot-encode -1))
        (set!
          (array-ref intern-pool-base-id-slots id)
          (intern-id-slot-encode id))
        id))))

(define (intern-generated-role-key
  [role : i64]
  [qualification : i64]
  [components : i64]) : i64
  (if (< (intern-generated-symbol-role-index role) 0)
    (tl_oob_abort)
    (intern-composite-triple-id role qualification components)))

(define (intern-generated-role-symbol-id-from-key
  [role : i64]
  [key : i64]
  [qualified : bool]
  [module-id : i64]
  [base-id : i64]) : i64
  (let
    [index : i64 (- (bit-and key (intern-structural-key-index-mask)) 1)]
    [table : InternStructuralTable
      (intern-array-shared-view
        (intern-global-shared-view intern-structural-table-cell)
        0)]
    [existing : InternSlotId (array-ref table.generated-symbol-handles index)]
    (if (not (intern-id-slot-empty? existing))
      (begin
        (cfg compile-profile (intern-profile-note-generated-role-reuse role))
        (intern-id-slot-decode existing))
      (let
        [id : i64 (intern-generated-role-symbol-handle)]
        (begin
          (set! (array-ref intern-pool-first-dot-slots id) (cast role : i32))
          (if qualified
            (begin
              (set! (array-ref intern-pool-qualified-slots id) true)
              (set!
                (array-ref intern-pool-module-id-slots id)
                (intern-id-slot-encode module-id))
              (set!
                (array-ref intern-pool-base-id-slots id)
                (intern-id-slot-encode base-id)))
            unit)
          (set!
            (array-ref
              (__tl-project-field
                (array-ref
                  (intern-global-shared-view intern-structural-table-cell)
                  0)
                generated-symbol-handles)
              index)
            (intern-id-slot-encode id))
          (cfg compile-profile (intern-profile-note-generated-role-create role))
          id)))))

(define (intern-generated-role-symbol-id [role : i64] [components : i64]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (let
      [key : i64 (intern-generated-role-key role 0 components)]
      (intern-generated-role-symbol-id-from-key role key false -1 -1))))

(define (intern-generated-role-symbol-materialize!
  [role : i64]
  [id : i64]
  [name : String]) : String
  (if (or
    (< (intern-generated-symbol-role-index role) 0)
    (not (intern-generated-id-active? id)))
    (tl_oob_abort)
    (let
      [cached : String
        (intern-array-shared-view
          (intern-global-shared-view intern-pool-slots)
          id)]
      (if (> (intern-private-string-length cached) 0)
        cached
        (let
          [rendered : String (intern-persistent-copy name)]
          (begin
            (set! (array-ref intern-pool-slots id) rendered)
            (set!
              (array-ref intern-pool-macro-prefix-class-slots id)
              (intern-private-macro-prefix-class rendered))
            (if (array-ref intern-pool-qualified-slots id)
              (set!
                (array-ref intern-pool-last-slash-slots id)
                (cast (intern-private-last-slash rendered) : i32))
              unit)
            (cfg
              compile-profile
              (intern-profile-note-generated-role-render role))
            rendered))))))

(define (intern-compat-state-generated-role-symbol?
  [state : (& state InternCompatState)]
  [id : i64]
  [role : i64]) : bool
  (and
    (>= (intern-generated-symbol-role-index role) 0)
    (intern-compat-state-generated-id-active? state id)
    (= (cast (array-ref state.pool-first-dot-slots id) : i64) role)))

(define (intern-compat-state-generated-role-record-count
  [state : (& state InternCompatState)]) : i64
  (__tl-project-field (array-ref state.structural-table-cell 0) len))

(define (intern-compat-state-generated-role-record-handle-at
  [state : (& state InternCompatState)]
  [index : i64]) : i64
  (let
    [table : InternStructuralTable
      (intern-array-shared-view state.structural-table-cell 0)]
    (if (or (< index 0) (>= index table.len))
      0
      (let
        [handle : InternSlotId (array-ref table.generated-symbol-handles index)]
        (if (intern-id-slot-empty? handle)
          0
          (intern-id-slot-decode handle))))))

(define (intern-compat-state-generated-role-record-role-at
  [state : (& state InternCompatState)]
  [index : i64]) : i64
  (let
    [table : InternStructuralTable
      (intern-array-shared-view state.structural-table-cell 0)]
    (if (or
      (< index 0)
      (>= index table.len)
      (intern-id-slot-empty? (array-ref table.generated-symbol-handles index))
      (not
        (=
          (cast (array-ref table.kinds index) : i64)
          (intern-structural-kind-triple))))
      0
      (array-ref table.lefts index))))

(define (intern-compat-state-generated-role-record-qualification-at
  [state : (& state InternCompatState)]
  [index : i64]) : i64
  (let
    [table : InternStructuralTable
      (intern-array-shared-view state.structural-table-cell 0)]
    (if (or (< index 0) (>= index table.len))
      0
      (array-ref table.middles index))))

(define (intern-compat-state-generated-role-record-components-at
  [state : (& state InternCompatState)]
  [index : i64]) : i64
  (let
    [table : InternStructuralTable
      (intern-array-shared-view state.structural-table-cell 0)]
    (if (or (< index 0) (>= index table.len))
      0
      (array-ref table.rights index))))

(define (intern-private-first-dot [name : (& name str)]) : i64
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
      [persistent-name : String (intern-persistent-copy (& name))]
      [id : i64 (intern-generated-id-allocate!)]
      (begin
        (set! (array-ref intern-pool-slots id) persistent-name)
        (set! (array-ref intern-pool-qualified-slots id) qualified)
        (set!
          (array-ref intern-pool-macro-prefix-class-slots id)
          (intern-private-macro-prefix-class persistent-name))
        (set!
          (array-ref intern-pool-last-slash-slots id)
          (if qualified
            (cast (intern-private-last-slash persistent-name) : i32)
            (cast -1 : i32)))
        (set! (array-ref intern-pool-first-dot-slots id) (cast -1 : i32))
        (set!
          (array-ref intern-pool-leading-dot-id-slots id)
          (intern-id-slot-encode -1))
        (set!
          (array-ref intern-pool-dotted-prefix-id-slots id)
          (intern-id-slot-encode -1))
        (set!
          (array-ref intern-pool-module-id-slots id)
          (intern-id-slot-encode module-id))
        (set!
          (array-ref intern-pool-base-id-slots id)
          (intern-id-slot-encode
            (if qualified
              base-id
              id)))
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

;: Allocate a generated dotted symbol such as `pkg.Type.Variant`. The caller
;: supplies the first segment, full prefix, and first-dot tail identities, so
;: downstream resolution never has to recover them from the display spelling.
(define (intern-generated-dotted-name
  [name : String]
  [leading-dot-id : i64]
  [dotted-prefix-id : i64]
  [dotted-tail-id : i64]) : i64
  (let
    [first-dot : i64 (intern-private-first-dot name)]
    (if (or
      (< first-dot 1)
      (< leading-dot-id 0)
      (< dotted-prefix-id 0)
      (< dotted-tail-id 0))
      (tl_oob_abort)
      (let
        [id : i64 (intern-generated-name-store name false -1 -1)]
        (begin
          (set!
            (array-ref intern-pool-first-dot-slots id)
            (cast first-dot : i32))
          (set!
            (array-ref intern-pool-leading-dot-id-slots id)
            (intern-id-slot-encode leading-dot-id))
          (set!
            (array-ref intern-pool-dotted-prefix-id-slots id)
            (intern-id-slot-encode dotted-prefix-id))
          (set!
            (array-ref intern-pool-base-id-slots id)
            (intern-id-slot-encode dotted-tail-id))
          id)))))

(define (intern-generated-canonical-name-at
  [name : String]
  [hash : i64]
  [cursor : i64]
  [steps : i64]
  [qualified : bool]
  [module-id : i64]
  [base-id : i64]
  [dotted : bool]
  [leading-dot-id : i64]
  [dotted-prefix-id : i64]
  [dotted-tail-id : i64]) : i64
  (if (>= steps intern-generated-map-capacity)
    (tl_oob_abort)
    (let
      [stored-id : InternSlotId
        (array-ref intern-generated-map-id-slots cursor)]
      (if (intern-id-slot-empty? stored-id)
        (let
          [id : i64
            (intern-generated-name-store name qualified module-id base-id)]
          (begin
            (if dotted
              (begin
                (set!
                  (array-ref intern-pool-first-dot-slots id)
                  (cast
                    (intern-private-first-dot
                      (& (array-ref intern-pool-slots id)))
                    : i32))
                (set!
                  (array-ref intern-pool-leading-dot-id-slots id)
                  (intern-id-slot-encode leading-dot-id))
                (set!
                  (array-ref intern-pool-dotted-prefix-id-slots id)
                  (intern-id-slot-encode dotted-prefix-id))
                (set!
                  (array-ref intern-pool-base-id-slots id)
                  (intern-id-slot-encode dotted-tail-id)))
              unit)
            (set!
              (array-ref intern-generated-map-id-slots cursor)
              (intern-id-slot-encode id))
            (set! (array-ref intern-generated-map-hash-slots cursor) hash)
            id))
        (let
          [slot-id : i64 (intern-id-slot-decode stored-id)]
          [slot-hash : i64 (array-ref intern-generated-map-hash-slots cursor)]
          (if (and
            (= slot-hash hash)
            (intern-private-string-eq-places
              (array-ref intern-pool-slots slot-id)
              name)
            (if qualified
              (and
                (intern-qualified? slot-id)
                (= (intern-qualified-module-id slot-id) module-id)
                (= (intern-qualified-base-id slot-id) base-id))
              (and
                (not (intern-qualified? slot-id))
                (if dotted
                  (and
                    (= (intern-leading-dot-id slot-id) leading-dot-id)
                    (= (intern-dotted-prefix-id slot-id) dotted-prefix-id)
                    (= (intern-dotted-tail-id slot-id) dotted-tail-id))
                  (< (intern-first-dot slot-id) 0)))))
            slot-id
            (intern-generated-canonical-name-at
              name
              hash
              (intern-bucket (+ cursor 1) intern-generated-map-capacity)
              (+ steps 1)
              qualified
              module-id
              base-id
              dotted
              leading-dot-id
              dotted-prefix-id
              dotted-tail-id)))))))

;; Canonical generated symbols deduplicate independently from source symbols.
;; Equal display text does not collapse hygiene with a source binding.
(define (intern-generated-canonical-name [name : String]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (let
      [hash : i64 (intern-hash name)]
      (intern-generated-canonical-name-at
        name
        hash
        (intern-bucket hash intern-generated-map-capacity)
        0
        false
        -1
        -1
        false
        -1
        -1
        -1))))

(define (intern-generated-canonical-name-existing-at
  [name : String]
  [hash : i64]
  [cursor : i64]
  [steps : i64]) : i64
  (if (>= steps intern-generated-map-capacity)
    -1
    (let
      [stored-id : InternSlotId
        (array-ref intern-generated-map-id-slots cursor)]
      (if (intern-id-slot-empty? stored-id)
        -1
        (let
          [slot-id : i64 (intern-id-slot-decode stored-id)]
          [slot-hash : i64 (array-ref intern-generated-map-hash-slots cursor)]
          (if (and
            (= slot-hash hash)
            (intern-private-string-eq-places
              (array-ref intern-pool-slots slot-id)
              name)
            (not (intern-qualified? slot-id))
            (< (intern-first-dot slot-id) 0))
            slot-id
            (intern-generated-canonical-name-existing-at
              name
              hash
              (intern-bucket (+ cursor 1) intern-generated-map-capacity)
              (+ steps 1))))))))

;: The canonical generated id `name` already has, or -1. This probes; it never
;: allocates, never resets the table, and matches on exactly the identity
;: `intern-generated-canonical-name` would have matched on.
;:
;: The canonical generated namespace is one namespace, so two mints of one
;: spelling used to be one id however far apart they were -- which is how a
;: derived symbol spelled like a runtime builtin (`tl_arena_current`, say) came
;: out equal to that builtin's id, and why the backend can decide "the runtime
;: provides this" with an integer compare. The IR's derived symbol table mints
;: outside this pool, so it asks here first and defers to an identity that
;: already exists rather than minting a second one for the same spelling.
(define (intern-generated-canonical-name-existing [name : String]) : i64
  (if intern-map-ready
    (let
      [hash : i64 (intern-hash name)]
      (intern-generated-canonical-name-existing-at
        name
        hash
        (intern-bucket hash intern-generated-map-capacity)
        0))
    -1))

;: Canonicalize a generated qualified symbol by both its display spelling and
;: structural module/base identities. The kind bit keeps an opaque generated
;: name with the same display text in a distinct canonical domain.
(define (intern-generated-canonical-qualified-name
  [name : String]
  [module-id : i64]
  [base-id : i64]) : i64
  (begin
    (if (or (< module-id 0) (< base-id 0))
      (tl_oob_abort)
      unit)
    (if intern-map-ready
      unit
      (intern-reset!))
    (let
      [hash : i64
        (bit-xor
          (intern-hash name)
          (bit-xor
            4611686018427387904
            (bit-xor (shl module-id 1) (shl base-id 18))))]
      (intern-generated-canonical-name-at
        name
        hash
        (intern-bucket hash intern-generated-map-capacity)
        0
        true
        module-id
        base-id
        false
        -1
        -1
        -1))))

(define (intern-generated-canonical-dotted-name
  [name : String]
  [leading-dot-id : i64]
  [dotted-prefix-id : i64]
  [dotted-tail-id : i64]) : i64
  (begin
    (if (or
      (< (intern-private-first-dot name) 0)
      (< leading-dot-id 0)
      (< dotted-prefix-id 0)
      (< dotted-tail-id 0))
      (tl_oob_abort)
      unit)
    (if intern-map-ready
      unit
      (intern-reset!))
    (let
      [hash : i64 (intern-hash name)]
      (intern-generated-canonical-name-at
        name
        hash
        (intern-bucket hash intern-generated-map-capacity)
        0
        false
        -1
        -1
        true
        leading-dot-id
        dotted-prefix-id
        dotted-tail-id))))

(define (intern-generated-canonical-lookup-at
  [name : String]
  [hash : i64]
  [cursor : i64]
  [steps : i64]) : InternLookup
  (if (>= steps intern-generated-map-capacity)
    (InternLookupMissing)
    (let
      [stored-id : InternSlotId
        (array-ref intern-generated-map-id-slots cursor)]
      (if (intern-id-slot-empty? stored-id)
        (InternLookupMissing)
        (let
          [slot-id : i64 (intern-id-slot-decode stored-id)]
          (if (and
            (= (array-ref intern-generated-map-hash-slots cursor) hash)
            (intern-private-string-eq-places
              (array-ref intern-pool-slots slot-id)
              name))
            (InternLookupFound slot-id)
            (intern-generated-canonical-lookup-at
              name
              hash
              (intern-bucket (+ cursor 1) intern-generated-map-capacity)
              (+ steps 1))))))))

(define (intern-generated-canonical-lookup [name : String]) : InternLookup
  (if intern-map-ready
    (let
      [hash : i64 (intern-hash name)]
      (intern-generated-canonical-lookup-at
        name
        hash
        (intern-bucket hash intern-generated-map-capacity)
        0))
    (InternLookupMissing)))

(define (intern-string-slice-eq?
  [name : (& name str)]
  [text : (& text str)]
  [start : i64]
  [len : i64]) : bool
  (if (= (__tl_string_length name) len)
    (let
      [name-ptr : (Ptr u8)
        (unsafe
          (string-data name))]
      [text-ptr : (Ptr u8)
        (unsafe
          (string-data text))]
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

(define (intern-record-qualified-metadata [id : i64] [name : (& name str)]) : unit
  (let
    [i : i64 0]
    [n : i64 (__tl_string_length name)]
    [slash : i64 -1]
    [dot : i64 -1]
    [last-dot : i64 -1]
    (begin
      (while (< i n)
        (let
          [c : char (__tl_string_ref name i)]
          (begin
            (if (= c '/')
              (set! slash i)
              unit)
            (if (= c '.')
              (begin
                (if (< dot 0)
                  (set! dot i)
                  unit)
                (set! last-dot i))
              unit)
            (set! i (+ i 1)))))
      (set! (array-ref intern-pool-last-slash-slots id) (cast slash : i32))
      (set! (array-ref intern-pool-first-dot-slots id) (cast dot : i32))
      (set!
        (array-ref intern-pool-macro-prefix-class-slots id)
        (intern-private-macro-prefix-class name))
      (set!
        (array-ref intern-pool-leading-dot-id-slots id)
        (intern-id-slot-encode
          (if (< dot 0)
            -1
            (intern-slice name 0 dot))))
      (set!
        (array-ref intern-pool-dotted-prefix-id-slots id)
        (intern-id-slot-encode
          (if (>= last-dot 0)
            (intern-slice name 0 last-dot)
            -1)))
      (if (< slash 0)
        (begin
          (set! (array-ref intern-pool-qualified-slots id) false)
          (set!
            (array-ref intern-pool-module-id-slots id)
            (intern-id-slot-encode -1))
          (set!
            (array-ref intern-pool-base-id-slots id)
            (intern-id-slot-encode
              (if (< dot 0)
                id
                (intern-slice name (+ dot 1) (- n (+ dot 1)))))))
        (let
          [base-start : i64 (+ slash 1)]
          (begin
            (set! (array-ref intern-pool-qualified-slots id) true)
            (set!
              (array-ref intern-pool-module-id-slots id)
              (intern-id-slot-encode (intern-slice name 0 slash)))
            (set!
              (array-ref intern-pool-base-id-slots id)
              (intern-id-slot-encode
                (intern-slice name base-start (- n base-start))))))))))

;: Clear bucket identities; stale hashes are ignored while the ID lane is zero.
(define (intern-fill-empty [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref intern-map-id-slots index) (intern-id-slot-empty))
      (intern-fill-empty (+ index 1) count))))

(define (intern-generated-map-clear! [index : i64]) : unit
  (if (>= index intern-generated-map-capacity)
    unit
    (begin
      (set!
        (array-ref intern-generated-map-id-slots index)
        (intern-id-slot-empty))
      (intern-generated-map-clear! (+ index 1)))))

(define (intern-reset-name-cache!) : unit
  (set! intern-name-cache-ready false))

(define (intern-name-cache-record [id : i64]) : unit
  (begin
    (set! intern-name-cache-id id)
    (set! intern-name-cache-ready true)))

(define (intern-map-insert-existing-from
  [id : i64]
  [hash : i64]
  [cursor : i64]
  [steps : i64]
  [capacity : i64]) : unit
  (let
    [slot : i64 cursor]
    [probes : i64 steps]
    (while (< probes capacity)
      (if (intern-id-slot-empty? (array-ref intern-map-id-slots slot))
        (begin
          (set! (array-ref intern-map-id-slots slot) (intern-id-slot-encode id))
          (set! (array-ref intern-map-hash-slots slot) hash)
          (return unit))
        (begin
          (set! slot (intern-bucket (+ slot 1) capacity))
          (set! probes (+ probes 1)))))))

(define (intern-map-insert-existing! [id : i64]) : unit
  (let
    [hash : i64 (intern-hash (& (array-ref intern-pool-slots id)))]
    [capacity : i64 (array-length intern-map-id-slots)]
    (intern-map-insert-existing-from
      id
      hash
      (intern-bucket hash capacity)
      0
      capacity)))

(define (intern-map-rebuild-prefix [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (intern-map-insert-existing! index)
      (intern-map-rebuild-prefix (+ index 1) count))))

;: Reset the intern table for a fresh compile.
(define (intern-reset!) : unit
  (begin
    (set! intern-pool-count 0)
    (intern-reset-name-cache!)
    (set! intern-generated-next-id (- (intern-capacity) 1))
    (intern-fill-empty 0 (array-length intern-map-id-slots))
    (intern-generated-map-clear! 0)
    (intern-structural-session-reset! (&mut intern-structural-table-cell))
    (intern-active-structural-sync! (& intern-structural-table-cell))
    (set! intern-reset-generation (intern-generation-allocate!))
    (set! intern-map-ready true)))

(define (intern-reset-to! [mark : i64]) : unit
  (begin
    (set! intern-pool-count mark)
    (set! intern-generated-next-id (- (intern-capacity) 1))
    (intern-fill-empty 0 (array-length intern-map-id-slots))
    (intern-generated-map-clear! 0)
    (intern-structural-session-reset! (&mut intern-structural-table-cell))
    (intern-active-structural-sync! (& intern-structural-table-cell))
    (intern-map-rebuild-prefix 0 mark)
    (intern-reset-name-cache!)
    (set! intern-reset-generation (intern-generation-allocate!))
    (set! intern-map-ready true)))

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
        (intern-private-string-eq
          (& (array-ref intern-pool-slots intern-name-cache-id))
          (& name)))
      (return intern-name-cache-id))
    (cfg compile-profile (intern-profile-note-intern))
    (let
      [capacity : i64 (array-length intern-map-id-slots)]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : i64 -1]
      [done : bool false]
      (begin
        (while (if done
          false
          (< steps capacity))
          (let
            [stored-id : InternSlotId (array-ref intern-map-id-slots cursor)]
            (if (intern-id-slot-empty? stored-id)
              (let
                [persistent-name : String (intern-persistent-copy (& name))]
                [id : i64 (intern-source-id-allocate!)]
                (begin
                  (set! (array-ref intern-pool-slots id) persistent-name)
                  (intern-record-qualified-metadata id persistent-name)
                  (intern-map-insert-existing-from id hash cursor 0 capacity)
                  (intern-name-cache-record id)
                  (set! out id)
                  (set! done true)))
              (let
                [source-id : i64 (intern-id-slot-decode stored-id)]
                [slot-hash : i64 (array-ref intern-map-hash-slots cursor)]
                (if (and
                  (= slot-hash hash)
                  (intern-private-string-eq
                    (& (array-ref intern-pool-slots source-id))
                    (& name)))
                  (begin
                    (intern-name-cache-record source-id)
                    (set! out source-id)
                    (set! done true))
                  (begin
                    (set! cursor (intern-bucket (+ cursor 1) capacity))
                    (set! steps (+ steps 1))))))))
        out))))

;: Intern a source slice without allocating unless the slice is a new name.
(define (intern-slice [text : (& text str)] [start : i64] [len : i64]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (cfg compile-profile (intern-profile-note-slice len))
    (let
      [capacity : i64 (array-length intern-map-id-slots)]
      [hash : i64 (intern-hash-slice text start len)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : i64 -1]
      [done : bool false]
      (begin
        (while (if done
          false
          (< steps capacity))
          (let
            [stored-id : InternSlotId (array-ref intern-map-id-slots cursor)]
            (if (intern-id-slot-empty? stored-id)
              (let
                [name : String (intern-persistent-substring text start len)]
                [id : i64 (intern-source-id-allocate!)]
                (begin
                  (cfg
                    compile-profile
                    (set!
                      intern-profile-slice-miss-count
                      (+ intern-profile-slice-miss-count 1)))
                  (set! (array-ref intern-pool-slots id) name)
                  (intern-record-qualified-metadata id name)
                  (intern-map-insert-existing-from id hash cursor 0 capacity)
                  (set! out id)
                  (set! done true)))
              (let
                [source-id : i64 (intern-id-slot-decode stored-id)]
                [slot-hash : i64 (array-ref intern-map-hash-slots cursor)]
                (if (and
                  (= slot-hash hash)
                  (intern-string-slice-eq?
                    (& (array-ref intern-pool-slots source-id))
                    (& text)
                    start
                    len))
                  (begin
                    (cfg
                      compile-profile
                      (set!
                        intern-profile-slice-hit-count
                        (+ intern-profile-slice-hit-count 1)))
                    (set! out source-id)
                    (set! done true))
                  (begin
                    (set! cursor (intern-bucket (+ cursor 1) capacity))
                    (set! steps (+ steps 1))))))))
        out))))

;: Lexer-only entry point. Keeping source-token volume separate from internal
;: metadata slices makes the expected parse-time intern count measurable.
(define (intern-source-slice [text : (& text str)] [start : i64] [len : i64]) : i64
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

;; Typed lexer boundary. Parser tokens can carry only renderable source names;
;; structural identities and missing sentinels remain raw in their own later
;; compiler domains until those boundaries are migrated.
(define (intern-source-slice-id [text : (& text str)] [start : i64] [len : i64]) : InternId
  (intern-id-from-renderable (intern-source-slice text start len)))

;: Look up an already-interned name without mutating the table. This lets later
;: compiler phases use id-keyed indexes without interning backend-generated
;: probe strings as a side effect.
(define (intern-lookup-content [name : String]) : InternLookup
  (begin
    (cfg compile-profile (intern-profile-note-lookup))
    (if intern-map-ready
      (let
        [capacity : i64 (array-length intern-map-id-slots)]
        [hash : i64 (intern-hash name)]
        [mask : i64 (- capacity 1)]
        [cursor : i64 (bit-and hash mask)]
        [steps : i64 0]
        [ids : (Ptr InternSlotId)
          (unsafe
            (ptr-cast
              (__tl_array-data intern-map-id-slots)
              : (Ptr InternSlotId)))]
        [hashes : (Ptr i64)
          (unsafe
            (ptr-cast (__tl_array-data intern-map-hash-slots) : (Ptr i64)))]
        (begin
          (while (< steps capacity)
            (let
              [stored : InternSlotId
                (unsafe
                  (ptr-read (ptr-offset ids cursor)))]
              (if (intern-id-slot-empty? stored)
                (return (InternLookupMissing))
                (let
                  [slot-id : i64 (intern-id-slot-decode stored)]
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
      (InternLookupMissing))))

(define (intern-lookup [name : String]) : InternLookup
  (if intern-map-ready
    (intern-lookup-content name)
    (InternLookupMissing)))

;; Capture the source-name boundary from an explicitly owned intern state. The
;; caller chooses when parsing is complete, so generated strings can resolve
;; only against names that existed at that boundary.
(define (intern-source-name-session-from-state
  [state : (& state InternCompatState)]) : InternSourceNameSession
  (InternSourceNameSession
    (owned_view.compiler-owned-shared-view state.table-id)
    (owned_view.compiler-owned-shared-view state.reset-generation)
    (owned_view.compiler-owned-shared-view state.pool-slots)
    (owned_view.compiler-owned-shared-view state.map-id-slots)
    (owned_view.compiler-owned-shared-view state.map-hash-slots)
    (owned_view.compiler-owned-shared-view state.map-ready)
    (owned_view.compiler-owned-shared-view state.persistent-arena)
    (owned_view.compiler-owned-shared-view state.structural-table-cell)
    (intern-compat-state-table-id state)
    (intern-compat-state-generation state)
    (intern-compat-state-pool-len state)
    (__tl-project-field (array-ref state.structural-table-cell 0) owner)))

;; Compatibility adapter for standalone compiler APIs. Production driver jobs
;; pass `intern-source-name-session-from-state` explicitly.
(define (intern-source-name-session-capture-active) : InternSourceNameSession
  (let
    [state : InternCompatState (intern-compat-state-capture-active)]
    (intern-source-name-session-from-state state)))

(define (intern-source-name-session-handle [session : InternSourceNameSession]) : InternSourceNameSessionHandle
  (in-arena
    (arena.Arena intern-persistent-arena)
    (let
      [cell : (__tl_dyn-array InternSourceNameSession)
        (__tl_make-array InternSourceNameSession 1)]
      (begin
        (set! (array-ref cell 0) session)
        (InternSourceNameSessionHandle
          (cast
            (unsafe
              (ptr->int
                (ptr-cast
                  (__tl_array-data cell)
                  : (Ptr InternSourceNameSession))))
            : i64))))))

(define (intern-source-name-session-handle-from-state
  [state : (& state InternCompatState)]) : InternSourceNameSessionHandle
  ;; The owner-local CTFE view must keep its handle cell in the caller's
  ;; current arena; unlike the active compatibility handle it must not retain
  ;; a persistent-arena allocation for every explicit compile job.
  (let
    [cell : (__tl_dyn-array InternSourceNameSession)
      (__tl_make-array InternSourceNameSession 1)]
    (begin
      (set! (array-ref cell 0) (intern-source-name-session-from-state state))
      (InternSourceNameSessionHandle
        (cast
          (unsafe
            (ptr->int
              (ptr-cast (__tl_array-data cell) : (Ptr InternSourceNameSession))))
          : i64)))))

(define (intern-source-name-session-handle-session
  [handle : InternSourceNameSessionHandle]) : InternSourceNameSession
  (unsafe
    (ptr-read
      (int->ptr (cast handle.address : u64) : (Ptr InternSourceNameSession)))))

;; Hot provenance checks need only these scalar identity fields. Reading them
;; through focused accessors avoids copying the full combined session.
(define (intern-source-name-session-handle-table-id
  [handle : InternSourceNameSessionHandle]) : i64
  (unsafe
    (__tl-project-field
      (ptr-read
        (int->ptr (cast handle.address : u64) : (Ptr InternSourceNameSession)))
      table-id)))

(define (intern-source-name-session-handle-reset-generation
  [handle : InternSourceNameSessionHandle]) : i64
  (unsafe
    (__tl-project-field
      (ptr-read
        (int->ptr (cast handle.address : u64) : (Ptr InternSourceNameSession)))
      reset-generation)))

(define (intern-source-name-session-capture-active-handle) : InternSourceNameSessionHandle
  (intern-source-name-session-handle
    (intern-source-name-session-capture-active)))

(define (intern-source-name-session-identity
  [session : (& session InternSourceNameSession)]
  [id : i64]) : InternSyntaxTextIdentity
  (InternSyntaxTextIdentity session.table-id session.reset-generation id))

(define (intern-source-name-session-lookup
  [session : (& session InternSourceNameSession)]
  [name : (& name str)]) : InternLookup
  (if (array-ref session.map-ready-cell 0)
    (let
      [ids : (__tl_dyn-array InternSlotId) session.map-id-slots]
      [hashes : (__tl_dyn-array i64) session.map-hash-slots]
      [pool : (__tl_dyn-array String) session.pool-slots]
      [capacity : i64 (array-length ids)]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      (begin
        (while (< steps capacity)
          (let
            [stored : InternSlotId (array-ref ids cursor)]
            (if (intern-id-slot-empty? stored)
              (return (InternLookupMissing))
              (let
                [slot-id : i64 (intern-id-slot-decode stored)]
                (if (and
                  (= (array-ref hashes cursor) hash)
                  (intern-private-string-eq (array-ref pool slot-id) name))
                  (if (< slot-id session.source-count)
                    (return (InternLookupFound slot-id))
                    (return (InternLookupMissing)))
                  (begin
                    (set! cursor (intern-bucket (+ cursor 1) capacity))
                    (set! steps (+ steps 1))))))))
        (InternLookupMissing)))
    (InternLookupMissing)))

(define (intern-source-name-session-resolve
  [session : (& session InternSourceNameSession)]
  [identity : InternSyntaxTextIdentity]
  [text : String]) : InternSourceNameResolution
  (cond
    [(not (= identity.table-id session.table-id))
      (InternSourceNameResolution.WrongOwner)]
    [(not (= (array-ref session.table-id-cell 0) session.table-id))
      (InternSourceNameResolution.WrongOwner)]
    [(not (= identity.reset-generation session.reset-generation))
      (InternSourceNameResolution.StaleGeneration)]
    [(not
        (= (array-ref session.reset-generation-cell 0) session.reset-generation))
      (InternSourceNameResolution.StaleGeneration)]
    [(or (< identity.id 0) (>= identity.id (array-length session.pool-slots)))
      (InternSourceNameResolution.InvalidIdentity)]
    [(< identity.id session.source-count)
      (InternSourceNameResolution.ParsedIdentity identity.id)]
    [else
      (InternSourceNameResolution.GeneratedIdentity
        identity.id
        (intern-source-name-session-lookup session text))]))

;; Interned strings live in the persistent intern arena and are immutable after
;; publication. This is the zero-copy shared-view boundary for the public
;; String-shaped compatibility API.
(define (intern-pool-string-shared-view [id : i64]) : String
  (unsafe
    (ptr-read
      (ptr-offset
        (ptr-cast (__tl_array-data intern-pool-slots) : (Ptr String))
        id))))

;: Recover the original String for an interned id.
(define (intern-str [id : i64]) : String
  (cfg
    compile-profile
    (if (or (< id 0) (>= id (intern-capacity)))
      (begin
        (set!
          intern-profile-invalid-str-count
          (+ intern-profile-invalid-str-count 1))
        (set! intern-profile-invalid-str-last-id id)
        "<invalid-intern-id>")
      (begin
        (set! intern-profile-render-count (+ intern-profile-render-count 1))
        (intern-pool-string-shared-view id)))
    (intern-pool-string-shared-view id)))

;; Typed render boundary. Callers with a structural key or a missing i64 cannot
;; call this API without an explicit, checked domain conversion.
(define (intern-id-str [id : InternId]) : String
  (intern-str (intern-id-value id)))

(define (intern-generation) : i64
  intern-reset-generation)

;: Identity of the currently installed intern pool. Compat states may have the
;: same generation, so generation-aware side caches must include this value.
(define (intern-qualified? [id : i64]) : bool
  (array-ref intern-pool-qualified-slots id))

;: Macro-hygiene prefix classification of a pool id, recorded when the entry
;: was stored. Equivalent to testing the recorded spelling against the matching
;: `intern-macro-*-prefix`, without rendering the string on every visit.
(define (intern-macro-global-name-id? [id : i64]) : bool
  (=
    (array-ref intern-pool-macro-prefix-class-slots id)
    (cast (intern-macro-prefix-class-global) : u8)))

(define (intern-macro-local-name-id? [id : i64]) : bool
  (=
    (array-ref intern-pool-macro-prefix-class-slots id)
    (cast (intern-macro-prefix-class-local) : u8)))

(define (intern-macro-template-name-id? [id : i64]) : bool
  (=
    (array-ref intern-pool-macro-prefix-class-slots id)
    (cast (intern-macro-prefix-class-template) : u8)))

(define (intern-qualified-last-slash [id : i64]) : i64
  (cast (array-ref intern-pool-last-slash-slots id) : i64))

(define (intern-first-dot [id : i64]) : i64
  (cast (array-ref intern-pool-first-dot-slots id) : i64))

(define (intern-leading-dot-id [id : i64]) : i64
  (intern-id-slot-decode (array-ref intern-pool-leading-dot-id-slots id)))

(define (intern-dotted-prefix-id [id : i64]) : i64
  (intern-id-slot-decode (array-ref intern-pool-dotted-prefix-id-slots id)))

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
        [tail-id : i64
          (intern-id-slot-decode (array-ref intern-pool-base-id-slots base-id))]
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
  (intern-id-slot-decode (array-ref intern-pool-module-id-slots id)))

(define (intern-qualified-base-id [id : i64]) : i64
  (intern-id-slot-decode (array-ref intern-pool-base-id-slots id)))

(define (intern-qualified-module [id : i64]) : String
  (let
    [module-id : i64 (intern-qualified-module-id id)]
    (if (< module-id 0)
      ""
      (intern-str module-id))))

(define (intern-qualified-base [id : i64]) : String
  (intern-str (intern-qualified-base-id id)))

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

(define (intern-syntax-id-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [source : InternId (intern-source-slice-id "pkg/name" 0 8)]
      [source-raw : i64 (intern-id-value source)]
      [source-syntax : InternSyntaxId (intern-syntax-id-from-renderable source)]
      [generated : InternId
        (intern-id-from-renderable
          (intern-generated-canonical-name "generated-name"))]
      [template : InternSyntaxId
        (intern-syntax-id-from-raw (intern-template-source-id source-raw))]
      [local : InternSyntaxId
        (intern-syntax-id-from-raw (intern-structural-local-id 7 source-raw))]
      [ok : bool
        (and
          (= (intern-syntax-id-value source-syntax) source-raw)
          (intern-private-string-eq
            (intern-syntax-id-text source-syntax)
            "pkg/name")
          (intern-private-string-eq
            (intern-syntax-id-text (intern-syntax-id-from-renderable generated))
            "generated-name")
          (intern-private-string-eq (intern-syntax-id-text template) "pkg/name")
          (intern-private-string-eq (intern-syntax-id-text local) "pkg/name"))]
      (begin
        (intern-reset!)
        ok))))

;; The capacity is not just the pool length: every structural symbol range is
;; keyed off it, so moving it moves those ranges too. A range that overflows or
;; overlaps fails SILENTLY -- ids decode into the wrong lane rather than abort.
;; The quasiquoted-source and structural-local bases are capacity^3 multiples,
;; so both overflow signed i64 the first time the capacity passes 2^17. These
;; are the relations the capacity is free to move within, checked here so that a
;; capacity change fails as a named self-test rather than as a bare
;; `tl: array index out of bounds` in a later bootstrap stage. Refs #6258.
(define (intern-id-space-capacity-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [capacity : i64 (intern-capacity)]
      [template-base : i64 (intern-template-source-base)]
      [local-base : i64 (intern-structural-local-base)]
      [ok : bool true]
      (begin
        ;; A power of two, so `intern-bucket` masks instead of dividing.
        (unless (> capacity 0) (set! ok false))
        (unless (= (bit-and capacity (- capacity 1)) 0) (set! ok false))
        ;; Each dedup map has to outsize the lane it indexes. A map smaller than
        ;; its lane cannot hold a full lane, and the overflow is an abort inside
        ;; the probe loop, not a resize.
        (unless
          (>= (array-length intern-map-id-slots) capacity)
          (set! ok false))
        (unless (>= intern-generated-map-capacity capacity) (set! ok false))
        ;; No base overflowed into a negative i64 ...
        (unless (> local-base 0) (set! ok false))
        (unless (> template-base 0) (set! ok false))
        ;; ... the arithmetic syntax ranges stay ordered ...
        (unless (< local-base template-base) (set! ok false))
        ;; ... the quasiquoted range stays below the first composite structural
        ;; key, whose owner ids start at one ...
        (unless
          (<=
            (+ template-base capacity)
            (+
              (intern-structural-key-base)
              (intern-structural-key-owner-stride)))
          (set! ok false))
        ;; ... and each base stays a multiple of the capacity, which is what lets
        ;; the remainder-based decoders recover a source name id.
        (unless (= (% template-base capacity) 0) (set! ok false))
        (unless (= (% local-base capacity) 0) (set! ok false))
        ;; The range predicates hold at both edges and reject one past each.
        (unless (intern-template-source-id? template-base) (set! ok false))
        (unless
          (intern-template-source-id? (+ template-base (- capacity 1)))
          (set! ok false))
        (unless
          (not (intern-template-source-id? (- template-base 1)))
          (set! ok false))
        (unless
          (not (intern-template-source-id? (+ template-base capacity)))
          (set! ok false))
        ;; A source name id survives every structural encoding round trip.
        (unless
          (= (intern-template-source-name-id (intern-template-source-id 0)) 0)
          (set! ok false))
        (unless
          (=
            (intern-template-source-name-id
              (intern-template-source-id (- capacity 1)))
            (- capacity 1))
          (set! ok false))
        (unless
          (=
            (intern-structural-local-source-name-id
              (intern-structural-local-id 0 (- capacity 1)))
            (- capacity 1))
          (set! ok false))
        (unless
          (=
            (intern-structural-local-source-name-id
              (intern-structural-local-id 7 3))
            3)
          (set! ok false))
        (unless
          (intern-structural-local-id? (intern-structural-local-id 7 3))
          (set! ok false))
        ;; A renderable id is a pool id and nothing else.
        (unless (intern-renderable-id? (- capacity 1)) (set! ok false))
        (unless (not (intern-renderable-id? capacity)) (set! ok false))
        (unless (not (intern-renderable-id? local-base)) (set! ok false))
        (unless (not (intern-renderable-id? template-base)) (set! ok false))
        ;; Both lanes address the one pool: source ids grow up from zero and
        ;; generated ids grow down from capacity-1, so the capacity is the sum
        ;; the two lanes must fit in, and they meet only when it is exhausted.
        (unless (= (intern-pool-len) 0) (set! ok false))
        (unless (= (intern-generated-count) 0) (set! ok false))
        (unless (= (intern "id-space-lane-probe") 0) (set! ok false))
        (unless
          (=
            (intern-syntax-source-name-id-or (intern-template-source-id 0) -1)
            0)
          (set! ok false))
        (unless
          (=
            (intern-syntax-source-name-id-or
              (intern-structural-local-id 7 0)
              -1)
            0)
          (set! ok false))
        (unless
          (intern-private-string-eq
            (intern-syntax-name-text-or capacity "missing")
            "missing")
          (set! ok false))
        (unless
          (= (intern-generated-name "id-space-lane-probe") (- capacity 1))
          (set! ok false))
        (unless
          (= (intern-generated-id-at-allocation-index 0) (- capacity 1))
          (set! ok false))
        (unless (= (intern-pool-len) 1) (set! ok false))
        (unless (= (intern-generated-count) 1) (set! ok false))
        (intern-reset!)
        ok))))

(define (intern-generated-name-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [source-id : i64 (intern "generated-source-anchor")]
      [module-id : i64 (intern "generated-module")]
      [base-id : i64 (intern "generated-base")]
      [dotted-prefix-id : i64 (intern "generated-base.Variant")]
      [dotted-tail-id : i64 (intern "Variant.Item")]
      [source-len : i64 (intern-pool-len)]
      [structural-local-id : i64 (intern-structural-local-id 7 source-id)]
      [structural-local-again-id : i64 (intern-structural-local-id 8 source-id)]
      [opaque-id : i64
        (with-scratch
          (let
            [temporary : String (intern-substring "xxhygiene/localyy" 2 13)]
            (intern-generated-name temporary)))]
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
        (intern-generated-dotted-name
          "generated-base.Variant.Item"
          base-id
          dotted-prefix-id
          dotted-tail-id)]
      [ok : bool true]
      (begin
        (unless (= (intern-pool-len) source-len) (set! ok false))
        (unless
          (intern-structural-local-id? structural-local-id)
          (set! ok false))
        (unless
          (not (= structural-local-id structural-local-again-id))
          (set! ok false))
        (unless
          (=
            (intern-structural-local-source-name-id structural-local-id)
            source-id)
          (set! ok false))
        (unless
          (intern-private-string-eq
            (intern-str
              (intern-structural-local-source-name-id structural-local-id))
            "generated-source-anchor")
          (set! ok false))
        (unless (= opaque-id (- (intern-capacity) 1)) (set! ok false))
        (unless (= opaque-again-id (- (intern-capacity) 2)) (set! ok false))
        (unless
          (= duplicate-display-id (- (intern-capacity) 3))
          (set! ok false))
        (unless (= qualified-id (- (intern-capacity) 4)) (set! ok false))
        (unless (= dotted-id (- (intern-capacity) 5)) (set! ok false))
        (unless (= (intern-generated-count) 5) (set! ok false))
        (unless
          (= (intern-generated-id-at-allocation-index 0) opaque-id)
          (set! ok false))
        (unless
          (= (intern-generated-id-at-allocation-index 4) dotted-id)
          (set! ok false))
        (unless
          (= (intern-generated-id-at-allocation-index -1) -1)
          (set! ok false))
        (unless
          (= (intern-generated-id-at-allocation-index 5) -1)
          (set! ok false))
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
        (unless
          (= (intern-dotted-prefix-id dotted-id) dotted-prefix-id)
          (set! ok false))
        (unless
          (= (intern-dotted-tail-id dotted-id) dotted-tail-id)
          (set! ok false))
        (unless (intern-dotted? dotted-id) (set! ok false))
        (unless (not (intern-qualified? dotted-id)) (set! ok false))
        (match (intern-lookup "hygiene/local")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (match (intern-lookup "generated-module/generated-base")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (unless (= (intern-pool-len) source-len) (set! ok false))
        (match (intern-lookup "generated-base.Variant.Item")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (match (intern-lookup "generated-source-anchor")
          [(InternLookupFound found-id)
            (unless (= found-id source-id) (set! ok false))]
          [(InternLookupMissing) (set! ok false)])
        (let
          [canonical-id : i64 (intern-generated-canonical-name "computed-name")]
          [canonical-again-id : i64
            (intern-generated-canonical-name
              (intern-substring "xxcomputed-nameyy" 2 13))]
          [canonical-dotted-id : i64
            (intern-generated-canonical-dotted-name
              "generated-base.Variant.Item"
              base-id
              dotted-prefix-id
              dotted-tail-id)]
          [canonical-dotted-again-id : i64
            (intern-generated-canonical-dotted-name
              "generated-base.Variant.Item"
              base-id
              dotted-prefix-id
              dotted-tail-id)]
          [canonical-qualified-id : i64
            (intern-generated-canonical-qualified-name
              "computed-name"
              module-id
              base-id)]
          [canonical-qualified-again-id : i64
            (intern-generated-canonical-qualified-name
              "computed-name"
              module-id
              base-id)]
          (begin
            (unless (= canonical-id canonical-again-id) (set! ok false))
            (unless (= (intern-generated-count) 8) (set! ok false))
            (unless
              (intern-generated-canonical-id? canonical-id)
              (set! ok false))
            (unless
              (intern-generated-canonical-id? canonical-dotted-id)
              (set! ok false))
            (unless
              (intern-generated-canonical-id? canonical-qualified-id)
              (set! ok false))
            (unless
              (not (intern-generated-canonical-id? opaque-id))
              (set! ok false))
            (unless
              (= canonical-dotted-id canonical-dotted-again-id)
              (set! ok false))
            (unless
              (= (intern-leading-dot-id canonical-dotted-id) base-id)
              (set! ok false))
            (unless
              (= (intern-dotted-prefix-id canonical-dotted-id) dotted-prefix-id)
              (set! ok false))
            (unless
              (= canonical-qualified-id canonical-qualified-again-id)
              (set! ok false))
            (unless
              (not (= canonical-qualified-id canonical-id))
              (set! ok false))
            (unless
              (intern-qualified-metadata-case-ok?
                canonical-qualified-id
                true
                -1
                "generated-module"
                "generated-base")
              (set! ok false))
            (match (intern-generated-canonical-lookup "computed-name")
              [(InternLookupFound found-id)
                (unless (= found-id canonical-id) (set! ok false))]
              [(InternLookupMissing) (set! ok false)])
            (match (intern-lookup-content "computed-name")
              [(InternLookupFound _) (set! ok false)]
              [(InternLookupMissing) unit])
            (let
              [source-observed-id : i64 (intern "computed-name")]
              (begin
                (unless
                  (= canonical-id (- (intern-capacity) 6))
                  (set! ok false))
                (unless (= source-observed-id source-len) (set! ok false))
                (unless
                  (not (= source-observed-id canonical-id))
                  (set! ok false))
                (match (intern-lookup-content "computed-name")
                  [(InternLookupFound found-id)
                    (unless (= found-id source-observed-id) (set! ok false))]
                  [(InternLookupMissing) (set! ok false)])))))
        (intern-reset-to! source-len)
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
            unit))
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
            unit))
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

(define (intern-persistent-arena-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [id : i64
        (with-scratch
          (let
            [name : String (intern-substring "persist/entry" 0 13)]
            (intern name)))]
      [again : i64 (intern "persist/entry")]
      [ok : bool
        (and
          (= id again)
          (intern-private-string-eq (intern-str id) "persist/entry")
          (intern-qualified-metadata-case-ok? id true 7 "persist" "entry"))]
      (begin
        (intern-reset!)
        ok))))

(define (intern-state-arena-growth-source
  [chunk-size : i64]
  [max-iterations : i64]) : String
  (let
    [source-length : i64 (+ chunk-size max-iterations)]
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 source-length)]
    [i : i64 0]
    (begin
      (while (< i source-length)
        (begin
          (set! (array-ref buf i) (cast (bit-and i 255) : u8))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes
          (ptr-cast (__tl_array-data buf) : (Ptr u8))
          source-length)))))

(define (intern-compat-state-persistent-arena-growth-tests-ok?) : bool
  (let
    [home : i64 (tl_arena_current)]
    ;; Keep this raw extent: `state` and `source` deliberately stay live across
    ;; many helper calls, and their APIs cannot express that the independent
    ;; persistent arena inside `state` outlives this scratch owner. The safe
    ;; checker therefore rejects the test's intentional ownership proof.
    [scratch : i64 (tl_arena_make)]
    [state : InternCompatState
      (begin
        (unsafe
          (tl_arena_set scratch))
        (let
          [created : InternCompatState (intern-compat-state-new)]
          (begin
            (unsafe
              (tl_arena_set home))
            created)))]
    [initial-arena : i64 (intern-compat-state-persistent-arena state)]
    [initial-head : i64
      (intern-compat-state-persistent-arena-current-head state)]
    [chunk-size : i64 4194304]
    [max-iterations : i64 24]
    [source : String
      (begin
        (unsafe
          (tl_arena_set scratch))
        (let
          [built : String
            (intern-state-arena-growth-source chunk-size max-iterations)]
          (begin
            (unsafe
              (tl_arena_set home))
            built)))]
    [before-id : i64
      (intern-compat-state-intern (&mut state) "state/pre-growth")]
    [before-text : String (intern-compat-state-str state before-id)]
    [iterations : i64 0]
    [grew? : bool false]
    (begin
      (while (and (not grew?) (< iterations max-iterations))
        (let
          [_copied : String
            (intern-compat-state-persistent-substring
              (&mut state)
              source
              iterations
              chunk-size)]
          (begin
            (set!
              grew?
              (not
                (=
                  (intern-compat-state-persistent-arena-current-head state)
                  initial-head)))
            (set! iterations (+ iterations 1)))))
      (let
        [grown-arena : i64 (intern-compat-state-persistent-arena state)]
        [grown-head : i64
          (intern-compat-state-persistent-arena-current-head state)]
        [post-copy : String
          (intern-compat-state-persistent-substring (&mut state) source 0 64)]
        [post-copy-restored? : bool (= (tl_arena_current) home)]
        [post-id : i64
          (intern-compat-state-intern (&mut state) "state/post-growth")]
        [generated-id : i64
          (intern-compat-state-generated-name
            (&mut state)
            "state/generated-after-growth")]
        [structural-id : i64
          (intern-compat-state-composite-pair-id (&mut state) before-id post-id)]
        [rendered-name : String
          (intern-compat-state-composite-rendered-name-record!
            (&mut state)
            structural-id
            "state/pre-growth+state/post-growth")]
        [structural-grow-index : i64 0]
        [equal-branch-head : i64 -1]
        [equal-copy : String
          (begin
            (unsafe
              (tl_arena_set (intern-compat-state-persistent-arena state)))
            (let
              [copied : String
                (intern-compat-state-persistent-substring
                  (&mut state)
                  source
                  1
                  64)]
              (begin
                (set!
                  equal-branch-head
                  (intern-compat-state-persistent-arena-current-head state))
                (unsafe
                  (tl_arena_set home))
                copied)))]
        [ok : bool true]
        (begin
          ;; Force both retained structural arrays and the open-addressing map
          ;; through their checker-visible target-arena growth extents.
          (while (< structural-grow-index 600)
            (begin
              (intern-structural-table-intern
                (&mut state.structural-table-cell)
                grown-arena
                (intern-structural-kind-pair)
                (+ 1000000 structural-grow-index)
                0
                (+ 2000000 structural-grow-index))
              (set! structural-grow-index (+ structural-grow-index 1))))
          (unless grew? (set! ok false))
          (unless (= grown-arena initial-arena) (set! ok false))
          (unless (not (= grown-head initial-head)) (set! ok false))
          (unless
            (intern-private-string-eq before-text "state/pre-growth")
            (set! ok false))
          (unless
            (intern-private-string-eq
              (intern-compat-state-str state before-id)
              "state/pre-growth")
            (set! ok false))
          (unless
            (intern-private-string-eq
              (intern-compat-state-str state post-id)
              "state/post-growth")
            (set! ok false))
          (unless
            (intern-private-string-eq
              (intern-compat-state-str state generated-id)
              "state/generated-after-growth")
            (set! ok false))
          (unless
            (intern-private-string-eq
              rendered-name
              "state/pre-growth+state/post-growth")
            (set! ok false))
          (unless
            (= (intern-private-string-length post-copy) 64)
            (set! ok false))
          (unless
            (=
              (intern-private-string-ref post-copy 0)
              (intern-private-string-ref source 0))
            (set! ok false))
          (unless post-copy-restored? (set! ok false))
          (unless (= (tl_arena_current) home) (set! ok false))
          (let
            [grown-structural-table : InternStructuralTable
              (intern-array-shared-view state.structural-table-cell 0)]
            (begin
              (unless
                (>= (array-length grown-structural-table.kinds) 512)
                (set! ok false))
              (unless
                (>= (array-length grown-structural-table.map-slots) 1024)
                (set! ok false))))
          (unless
            (=
              equal-branch-head
              (intern-compat-state-persistent-arena-current-head state))
            (set! ok false))
          (unless
            (= (intern-private-string-length equal-copy) 64)
            (set! ok false))
          (unless
            (=
              (intern-private-string-ref equal-copy 0)
              (intern-private-string-ref source 1))
            (set! ok false))
          (unless (= (tl_arena_current) home) (set! ok false))
          (intern-compat-state-reset! (&mut state))
          (let
            [state-arena : i64 (intern-compat-state-persistent-arena state)]
            (begin
              (unsafe
                (tl_arena_set home)
                (tl_arena_destroy state-arena)
                (tl_arena_destroy scratch))
              ok)))))))

(define (intern-reset-to-tests-ok?) : bool
  (begin
    (intern-reset!)
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
        ok))))

(define (intern-persistent-floor-reset-tests-ok?) : bool
  (begin
    (intern-reset!)
    (intern-persistent-arena-reset!)
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
            (intern-persistent-arena-reset!)
            ok))))))

(define (intern-source-name-session-tests-ok?) : bool
  (let
    [home : i64 (tl_arena_current)]
    [state-a : InternCompatState (intern-compat-state-new)]
    [state-b : InternCompatState (intern-compat-state-new)]
    [equal-id : i64 (intern-compat-state-intern (&mut state-a) "equal")]
    [empty-id : i64 (intern-compat-state-intern (&mut state-a) "")]
    [qualified-id : i64
      (intern-compat-state-intern (&mut state-a) "pkg/module.name")]
    [slice-mark : i64 (intern-compat-state-pool-len state-a)]
    [qualified-slice-id : InternId
      (intern-compat-state-source-slice-id
        (&mut state-a)
        "xxpkg/module.nameyy"
        2
        15)]
    [slice-mark-after : i64 (intern-compat-state-pool-len state-a)]
    [hygiene-id : i64
      (intern-compat-state-intern (&mut state-a) "local#hygiene")]
    [source-mark : i64 (intern-compat-state-pool-len state-a)]
    [session-a : InternSourceNameSession
      (intern-source-name-session-from-state state-a)]
    [session-b : InternSourceNameSession
      (begin
        (intern-compat-state-intern (&mut state-b) "equal")
        (intern-source-name-session-from-state state-b))]
    [persistent-handle : InternSourceNameSessionHandle
      (intern-source-name-session-handle (intern-global-shared-view session-a))]
    [persistent-handle-session : InternSourceNameSession
      (intern-source-name-session-handle-session persistent-handle)]
    [persistent-handle-restored? : bool (= (tl_arena_current) home)]
    [generated-id : i64 (- (intern-capacity) 1)]
    [generated-a : InternSyntaxTextIdentity
      (intern-source-name-session-identity session-a generated-id)]
    [parsed-a : InternSyntaxTextIdentity
      (intern-source-name-session-identity session-a equal-id)]
    [_late-source-id : i64
      (intern-compat-state-intern (&mut state-a) "after-boundary")]
    [ok : bool true]
    (begin
      (unless persistent-handle-restored? (set! ok false))
      (unless
        (= persistent-handle-session.table-id session-a.table-id)
        (set! ok false))
      (unless
        (=
          persistent-handle-session.reset-generation
          session-a.reset-generation)
        (set! ok false))
      (match (intern-compat-state-lookup state-a "equal")
        [(InternLookupFound id) (unless (= id equal-id) (set! ok false))]
        [(InternLookupMissing) (set! ok false)])
      (unless
        (intern-private-string-eq
          (intern-compat-state-str state-a equal-id)
          "equal")
        (set! ok false))
      (unless
        (intern-compat-state-qualified? state-a qualified-id)
        (set! ok false))
      (unless
        (= (intern-id-value qualified-slice-id) qualified-id)
        (set! ok false))
      (unless (= slice-mark-after slice-mark) (set! ok false))
      (unless
        (= (intern-compat-state-qualified-last-slash state-a qualified-id) 3)
        (set! ok false))
      (unless
        (= (intern-compat-state-first-dot state-a qualified-id) 10)
        (set! ok false))
      (unless
        (intern-compat-state-dotted? state-a qualified-id)
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-str
            state-a
            (intern-compat-state-qualified-module-id state-a qualified-id))
          "pkg")
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-str
            state-a
            (intern-compat-state-qualified-base-id state-a qualified-id))
          "module.name")
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-str
            state-a
            (intern-compat-state-dotted-prefix-id state-a qualified-id))
          "pkg/module")
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-str
            state-a
            (intern-compat-state-dotted-tail-id state-a qualified-id))
          "name")
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-str
            state-a
            (intern-compat-state-dotted-final-id state-a qualified-id))
          "name")
        (set! ok false))
      (match (intern-source-name-session-resolve session-a parsed-a "different")
        [(InternSourceNameResolution.ParsedIdentity id)
          (unless (= id equal-id) (set! ok false))]
        [_ (set! ok false)])
      (match (intern-source-name-session-resolve session-a generated-a "equal")
        [(InternSourceNameResolution.GeneratedIdentity id lookup)
          (begin
            (unless (= id generated-id) (set! ok false))
            (match lookup
              [(InternLookupFound source-id)
                (unless (= source-id equal-id) (set! ok false))]
              [(InternLookupMissing) (set! ok false)]))]
        [_ (set! ok false)])
      (match (intern-source-name-session-resolve
        session-a
        generated-a
        "missing")
        [(InternSourceNameResolution.GeneratedIdentity id lookup)
          (begin
            (unless (= id generated-id) (set! ok false))
            (match lookup
              [(InternLookupMissing) unit]
              [(InternLookupFound _) (set! ok false)]))]
        [_ (set! ok false)])
      (match (intern-source-name-session-resolve
        session-a
        generated-a
        "after-boundary")
        [(InternSourceNameResolution.GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupMissing) unit]
            [(InternLookupFound _) (set! ok false)])]
        [_ (set! ok false)])
      (match (intern-source-name-session-resolve session-a generated-a "")
        [(InternSourceNameResolution.GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id) (unless (= id empty-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (intern-source-name-session-resolve
        session-a
        generated-a
        "pkg/module.name")
        [(InternSourceNameResolution.GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id)
              (unless (= id qualified-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (intern-source-name-session-resolve
        session-a
        generated-a
        "local#hygiene")
        [(InternSourceNameResolution.GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id) (unless (= id hygiene-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (intern-source-name-session-resolve session-b parsed-a "equal")
        [(InternSourceNameResolution.WrongOwner) unit]
        [_ (set! ok false)])
      (match (intern-source-name-session-resolve
        session-a
        (InternSyntaxTextIdentity
          session-a.table-id
          session-a.reset-generation
          -1)
        "equal")
        [(InternSourceNameResolution.InvalidIdentity) unit]
        [_ (set! ok false)])
      (intern-compat-state-reset-to! (&mut state-a) source-mark)
      (match (intern-source-name-session-resolve session-a generated-a "equal")
        [(InternSourceNameResolution.StaleGeneration) unit]
        [_ (set! ok false)])
      (let
        [next-session : InternSourceNameSession
          (intern-source-name-session-from-state state-a)]
        [next-generated : InternSyntaxTextIdentity
          (intern-source-name-session-identity next-session generated-id)]
        (match (intern-source-name-session-resolve
          next-session
          next-generated
          "equal")
          [(InternSourceNameResolution.GeneratedIdentity _ lookup)
            (match lookup
              [(InternLookupFound id) (unless (= id equal-id) (set! ok false))]
              [(InternLookupMissing) (set! ok false)])]
          [_ (set! ok false)]))
      ok)))

(define (intern-generated-role-symbol-tests-ok?) : bool
  (let
    [state-a : InternCompatState (intern-compat-state-new)]
    [state-b : InternCompatState (intern-compat-state-new)]
    [component-a : i64 (intern-compat-state-intern (&mut state-a) "component")]
    [component-b : i64 (intern-compat-state-intern (&mut state-b) "component")]
    [source-collision-a : i64
      (intern-compat-state-intern (&mut state-a) "__tl_lambda_component_0")]
    [lambda-a : i64
      (intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (intern-generated-symbol-role-lambda)
        component-a)]
    [lambda-a-again : i64
      (intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (intern-generated-symbol-role-lambda)
        component-a)]
    [clone-a : i64
      (intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (intern-generated-symbol-role-clone-helper)
        component-a)]
    [lambda-b : i64
      (intern-compat-state-generated-role-symbol-id
        (&mut state-b)
        (intern-generated-symbol-role-lambda)
        component-b)]
    [module-a : i64 (intern-compat-state-intern (&mut state-a) "pkg")]
    [base-a : i64 (intern-compat-state-intern (&mut state-a) "cleanup")]
    [qualified-a : i64
      (intern-compat-state-generated-role-qualified-symbol-id
        (&mut state-a)
        (intern-generated-symbol-role-cleanup-helper)
        component-a
        module-a
        base-a)]
    [enum-boundary-a-left : i64
      (intern-compat-state-intern (&mut state-a) "A_B")]
    [enum-boundary-a-right : i64
      (intern-compat-state-intern (&mut state-a) "C")]
    [enum-boundary-a-components : i64
      (intern-compat-state-composite-pair-id
        (&mut state-a)
        enum-boundary-a-left
        enum-boundary-a-right)]
    [enum-boundary-a : i64
      (intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (intern-generated-symbol-role-nullary-enum-object)
        enum-boundary-a-components)]
    [enum-boundary-b-left : i64 (intern-compat-state-intern (&mut state-a) "A")]
    [enum-boundary-b-right : i64
      (intern-compat-state-intern (&mut state-a) "B_C")]
    [enum-boundary-b-components : i64
      (intern-compat-state-composite-pair-id
        (&mut state-a)
        enum-boundary-b-left
        enum-boundary-b-right)]
    [enum-boundary-b : i64
      (intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (intern-generated-symbol-role-nullary-enum-object)
        enum-boundary-b-components)]
    [ok : bool true]
    (begin
      (unless (= lambda-a lambda-a-again) (set! ok false))
      (unless (not (= lambda-a clone-a)) (set! ok false))
      (unless (not (= lambda-a source-collision-a)) (set! ok false))
      (unless
        (intern-compat-state-generated-role-symbol?
          state-a
          lambda-a
          (intern-generated-symbol-role-lambda))
        (set! ok false))
      (when
        (intern-compat-state-generated-role-symbol?
          state-a
          lambda-a
          (intern-generated-symbol-role-clone-helper))
        (set! ok false))
      (when
        (intern-compat-state-generated-role-symbol?
          state-a
          source-collision-a
          (intern-generated-symbol-role-lambda))
        (set! ok false))
      ;; Both recipes render as `__enum_obj_A_B_C`; component boundaries stay
      ;; structural so they cannot silently alias before the output boundary.
      (unless (not (= enum-boundary-a enum-boundary-b)) (set! ok false))
      (unless
        (=
          (intern-private-string-length
            (intern-compat-state-str state-a lambda-a))
          0)
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-generated-role-symbol-materialize!
            (&mut state-a)
            (intern-generated-symbol-role-lambda)
            lambda-a
            "__tl_lambda_component_0")
          "__tl_lambda_component_0")
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-generated-role-symbol-materialize!
            (&mut state-b)
            (intern-generated-symbol-role-lambda)
            lambda-b
            "state_b_lambda")
          "state_b_lambda")
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-str state-a lambda-a)
          "__tl_lambda_component_0")
        (set! ok false))
      (unless
        (intern-private-string-eq
          (intern-compat-state-str state-b lambda-b)
          "state_b_lambda")
        (set! ok false))
      (intern-compat-state-generated-role-symbol-materialize!
        (&mut state-a)
        (intern-generated-symbol-role-cleanup-helper)
        qualified-a
        "pkg/__tl_cleanup_cleanup")
      (unless
        (intern-compat-state-qualified? state-a qualified-a)
        (set! ok false))
      (unless
        (=
          (intern-compat-state-qualified-module-id state-a qualified-a)
          module-a)
        (set! ok false))
      (unless
        (= (intern-compat-state-qualified-base-id state-a qualified-a) base-a)
        (set! ok false))
      (unless
        (= (intern-compat-state-qualified-last-slash state-a qualified-a) 3)
        (set! ok false))
      (let
        [growth-first : i64
          (intern-compat-state-generated-role-symbol-id
            (&mut state-a)
            (intern-generated-symbol-role-global-initializer)
            1000)]
        ;; The initial structural map has 512 slots; components differing by
        ;; 512 deliberately share the role triple's first bucket.
        [hash-collision : i64
          (intern-compat-state-generated-role-symbol-id
            (&mut state-a)
            (intern-generated-symbol-role-global-initializer)
            1512)]
        [index : i64 0]
        (begin
          (unless (not (= growth-first hash-collision)) (set! ok false))
          (while (< index 300)
            (begin
              (intern-compat-state-generated-role-symbol-id
                (&mut state-a)
                (intern-generated-symbol-role-global-initializer)
                (+ 2000 index))
              (set! index (+ index 1))))
          (unless
            (=
              growth-first
              (intern-compat-state-generated-role-symbol-id
                (&mut state-a)
                (intern-generated-symbol-role-global-initializer)
                1000))
            (set! ok false))))
      (let
        [mark-b : i64 (intern-compat-state-pool-len state-b)]
        (begin
          (intern-compat-state-reset-to! (&mut state-b) mark-b)
          (unless
            (not (intern-compat-state-generated-id-active? state-b lambda-b))
            (set! ok false))))
      (intern-compat-state-reset! (&mut state-a))
      (unless
        (not (intern-compat-state-generated-id-active? state-a lambda-a))
        (set! ok false))
      (let
        [next-component : i64
          (intern-compat-state-intern (&mut state-a) "next-component")]
        [next-lambda : i64
          (intern-compat-state-generated-role-symbol-id
            (&mut state-a)
            (intern-generated-symbol-role-lambda)
            next-component)]
        (begin
          (unless
            (=
              (intern-private-string-length
                (intern-compat-state-str state-a next-lambda))
              0)
            (set! ok false))
          (intern-compat-state-generated-role-symbol-materialize!
            (&mut state-a)
            (intern-generated-symbol-role-lambda)
            next-lambda
            "after_reset")))
      ;; Compatibility macro/typecheck callers may advance the active global
      ;; generated lane after a driver snapshots its explicit state. The next
      ;; structural allocation refreshes that frontier and cannot reuse the
      ;; live compatibility ID.
      (intern-reset!)
      (let
        [active-state : InternCompatState (intern-compat-state-capture-active)]
        [compat-id : i64 (intern-generated-name "compat-generated")]
        [role-id : i64
          (intern-compat-state-generated-role-symbol-id
            (&mut active-state)
            (intern-generated-symbol-role-lambda)
            99)]
        (begin
          (unless (not (= compat-id role-id)) (set! ok false))
          (unless
            (intern-private-string-eq (intern-str compat-id) "compat-generated")
            (set! ok false))))
      ;; Reusing a role first published by the active compatibility view also
      ;; refreshes the explicit state's generated frontier. This is distinct
      ;; from the new-role allocation case above: the structural record and
      ;; handle already exist before the state-side lookup.
      (intern-reset!)
      (let
        [component : i64 (intern "shared-role-component")]
        [active-state : InternCompatState (intern-compat-state-capture-active)]
        [role : i64 (intern-generated-symbol-role-clone-helper)]
        [compat-role-id : i64 (intern-generated-role-symbol-id role component)]
        [state-role-id : i64
          (intern-compat-state-generated-role-symbol-id
            (&mut active-state)
            role
            component)]
        (begin
          (unless (= state-role-id compat-role-id) (set! ok false))
          (unless
            (intern-compat-state-generated-role-symbol?
              active-state
              state-role-id
              role)
            (set! ok false))
          (unless
            (intern-private-string-eq
              (intern-compat-state-generated-role-symbol-materialize!
                (&mut active-state)
                role
                state-role-id
                "clone$SharedRole")
              "clone$SharedRole")
            (set! ok false))))
      ok)))

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
          (= (intern-dotted-prefix-id dotted) (intern "point"))
          (set! ok false))
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
            (intern-str (intern-dotted-prefix-id nested-dotted))
            "point.inner")
          (set! ok false))
        (unless
          (intern-private-string-eq
            (intern-str
              (intern-dotted-prefix-id (intern-dotted-prefix-id nested-dotted)))
            "point")
          (set! ok false))
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
        (unless (intern-dotted? dotted) (set! ok false))
        (unless (= (intern-first-dot dotted) 5) (set! ok false))
        (unless (intern-slice-tests-ok?) (set! ok false))
        (unless (intern-generated-name-tests-ok?) (set! ok false))
        (unless (intern-persistent-arena-tests-ok?) (set! ok false))
        (unless
          (intern-compat-state-persistent-arena-growth-tests-ok?)
          (set! ok false))
        (unless (intern-reset-to-tests-ok?) (set! ok false))
        (unless (intern-persistent-floor-reset-tests-ok?) (set! ok false))
        (unless (intern-source-name-session-tests-ok?) (set! ok false))
        (unless (intern-generated-role-symbol-tests-ok?) (set! ok false))
        (intern-reset!)
        ok))))