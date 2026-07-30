;; compiler_intern.tl - process-global string interning table for identifiers.
;;
;; SELF-CONTAINED (no imports): every programmer-written identifier is interned
;; to a stable u32-backed id, so name comparisons become integer `=`, id-keyed lookups
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

(unsafe
  (extern (intern-runtime-copy-bytes!
    [dst : (MutPtr u8)]
    [src : (Ptr u8)]
    [count : i64]) : unit (:symbol "tl_memcpy")))

(defmacro (intern-i64-array-address [items : Expr]) : u64
  `(unsafe
    (ptr->int (ptr-cast (array-data ,items) : (Ptr u8)))))

(defmacro (intern-active-i64-ref [address : Expr] [index : Expr]) : i64
  `(unsafe
    (ptr-read (ptr-offset (int->ptr ,address : (Ptr i64)) ,index))))

(defmacro (intern-active-i64-set!
  [address : Expr]
  [index : Expr]
  [value : Expr]) : unit
  `(unsafe
    (ptr-write! (ptr-offset (int->ptr ,address : (MutPtr i64)) ,index) ,value)))

(define (intern-private-string-length [text : String]) : i64
  (__tl_string_length text))

(define (intern-private-string-ref [text : String] [index : i64]) : char
  (__tl_string_ref text index))

(define (intern-private-string-eq [left : String] [right : String]) : bool
  (let
    [left-len : i64 (__tl_string_length left)]
    [right-len : i64 (__tl_string_length right)]
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
(define (intern-capacity) : i64
  131072)

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
            intern-structural-table-cell
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
            (struct-get (array-ref intern-structural-table-cell 0) len))
          raw)))))

(defmacro (intern-composite-pair-id? [id : Expr]) : bool
  `(let
    [structural-id : i64 ,id]
    (and
      (> structural-id intern-active-structural-prefix)
      (<=
        structural-id
        (+ intern-active-structural-prefix intern-active-structural-len)))))

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
            intern-structural-table-cell
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
            (struct-get (array-ref intern-structural-table-cell 0) len))
          raw)))))

(defmacro (intern-composite-triple-id? [id : Expr]) : bool
  `(let
    [structural-id : i64 ,id]
    [triple-prefix : i64
      (+ intern-active-structural-prefix (intern-structural-key-kind-stride))]
    (and
      (> structural-id triple-prefix)
      (<= structural-id (+ triple-prefix intern-active-structural-len)))))

(defmacro (intern-renderable-id? [id : Expr]) : bool
  `(let
    [name-id : i64 ,id]
    (and (>= name-id 0) (< name-id (intern-capacity)))))

;; Quasiquoted source symbols keep their parsed identity without allocating a
;; second intern entry. This range sits above the compiler's other structural
;; symbol ranges and remains within signed i64 at the fixed intern capacity.
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
;; allocating another string-pool entry. This range is above every macro-local
;; identity and below the quasiquoted-source range.
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

;; Macro-captured globals are structural symbol identities, not entries in the
;; string interner. Keep their range and source-id decoder beside the interner's
;; other structural symbol ranges so downstream consumers can cross the AST
;; boundary without attempting to interpret a structural id as an intern id.
(define (intern-macro-global-structural-base) : i64
  (let
    [stride : i64 (intern-capacity)]
    [stride2 : i64 (* stride stride)]
    (+ (+ (+ stride stride2) (* stride2 stride)) (* 4 stride2))))

(define (intern-macro-global-structural-id? [id : i64]) : bool
  (let
    [stride : i64 (intern-capacity)]
    [base : i64 (intern-macro-global-structural-base)]
    (and (>= id base) (< id (+ base (* 2 (* stride stride)))))))

(define (intern-macro-global-source-name-id [id : i64]) : i64
  (% (- id (intern-macro-global-structural-base)) (intern-capacity)))

(define (intern-macro-global-source-name-id-or [id : i64] [fallback : i64]) : i64
  (if (intern-macro-global-structural-id? id)
    (intern-macro-global-source-name-id id)
    fallback))

(defstruct InternId
  (value u32))

(defmacro (intern-id-value [id : Expr]) : i64
  `(cast (struct-get ,id value) : i64))

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
  `(cast (struct-get ,id encoded) : i64))

;; Compact lanes reserve zero for an empty/missing slot and store id+1.
(define (intern-id-slot-empty) : InternSlotId
  (InternSlotId (cast 0 : u32)))

(define (intern-id-slot-empty? [id : InternSlotId]) : bool
  (= (struct-get id encoded) (cast 0 : u32)))

(define (intern-id-slot-encode [id : i64]) : InternSlotId
  (InternSlotId (cast (+ id 1) : u32)))

(defmacro (intern-id-slot-decode [encoded : Expr]) : i64
  `(- (intern-slot-id-value ,encoded) 1))

(defenum InternLookup
  (InternLookupMissing)
  (InternLookupFound i64))

(define intern-pool-slots : (__tl_dyn-array String)
  (make-array String (intern-capacity)))
(define intern-pool-qualified-slots : (__tl_dyn-array bool)
  (make-array bool (intern-capacity)))
(define intern-pool-last-slash-slots : (__tl_dyn-array i32)
  (make-array i32 (intern-capacity)))
(define intern-pool-first-dot-slots : (__tl_dyn-array i32)
  (make-array i32 (intern-capacity)))
(define intern-pool-leading-dot-id-slots : (__tl_dyn-array InternSlotId)
  (make-array InternSlotId (intern-capacity)))
(define intern-pool-dotted-prefix-id-slots : (__tl_dyn-array InternSlotId)
  (make-array InternSlotId (intern-capacity)))
(define intern-pool-module-id-slots : (__tl_dyn-array InternSlotId)
  (make-array InternSlotId (intern-capacity)))
(define intern-pool-base-id-slots : (__tl_dyn-array InternSlotId)
  (make-array InternSlotId (intern-capacity)))
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
  (map-slots (__tl_dyn-array i64))
  (structural-cache-raws (__tl_dyn-array i64))
  (len i64))

(define (intern-structural-key-base) : i64
  4611686018427387904)

(define (intern-structural-key-owner-stride) : i64
  2147483648)

(define (intern-structural-key-kind-stride) : i64
  1073741824)

(define (intern-structural-key-index-mask) : i64
  1073741823)

(define (intern-structural-kind-pair) : i64
  1)

(define (intern-structural-kind-triple) : i64
  2)

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
    (make-array u8 256)
    (make-array i64 256)
    (make-array i64 256)
    (make-array i64 256)
    (make-array i64 512)
    (make-array i64 (intern-structural-cache-capacity))
    0))

(define (intern-structural-table-cell-new-in-arena [arena : i64]) : (__tl_dyn-array
    InternStructuralTable)
  (let
    [previous-arena : i64 (tl_arena_current)]
    (begin
      (unsafe
        (tl_arena_set arena))
      (let
        [table : InternStructuralTable (intern-structural-table-new)]
        (begin
          (unsafe
            (tl_arena_set previous-arena))
          (make-array table))))))

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
      (struct-get (array-ref intern-structural-table-cell 0) owner)
      (intern-structural-key-owner-stride))))
(define intern-active-structural-owner : i64
  (struct-get (array-ref intern-structural-table-cell 0) owner))
(define intern-active-structural-len : i64
  0)
(define intern-active-structural-lefts-address : u64
  (intern-i64-array-address
    (struct-get (array-ref intern-structural-table-cell 0) lefts)))
(define intern-active-structural-middles-address : u64
  (intern-i64-array-address
    (struct-get (array-ref intern-structural-table-cell 0) middles)))
(define intern-active-structural-rights-address : u64
  (intern-i64-array-address
    (struct-get (array-ref intern-structural-table-cell 0) rights)))
(define intern-active-structural-cache-raws-address : u64
  (intern-i64-array-address
    (struct-get
      (array-ref intern-structural-table-cell 0)
      structural-cache-raws)))

(define (intern-active-structural-sync!
  [cell : (__tl_dyn-array InternStructuralTable)]) : unit
  (let
    [table : InternStructuralTable (array-ref cell 0)]
    (begin
      (set!
        intern-active-structural-prefix
        (+
          (intern-structural-key-base)
          (* (struct-get table owner) (intern-structural-key-owner-stride))))
      (set! intern-active-structural-owner (struct-get table owner))
      (set! intern-active-structural-len (struct-get table len))
      (set!
        intern-active-structural-lefts-address
        (intern-i64-array-address (struct-get table lefts)))
      (set!
        intern-active-structural-middles-address
        (intern-i64-array-address (struct-get table middles)))
      (set!
        intern-active-structural-rights-address
        (intern-i64-array-address (struct-get table rights)))
      (set!
        intern-active-structural-cache-raws-address
        (intern-i64-array-address (struct-get table structural-cache-raws))))))

(defmacro (intern-structural-raw-for-index
  [owner : Expr]
  [kind : Expr]
  [index : Expr]) : i64
  `(+
    (intern-structural-key-base)
    (+
      (* ,owner (intern-structural-key-owner-stride))
      (+ (* (- ,kind 1) (intern-structural-key-kind-stride)) (+ ,index 1)))))

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
    (- (array-length (struct-get ,table map-slots)) 1)))

(defmacro (intern-structural-table-record-matches?
  [table : Expr]
  [index : Expr]
  [kind : Expr]
  [left : Expr]
  [middle : Expr]
  [right : Expr]) : bool
  `(and
    (= (cast (array-ref (struct-get ,table kinds) ,index) : i64) ,kind)
    (= (array-ref (struct-get ,table lefts) ,index) ,left)
    (= (array-ref (struct-get ,table middles) ,index) ,middle)
    (= (array-ref (struct-get ,table rights) ,index) ,right)))

(define (intern-structural-table-map-put-index!
  [table : InternStructuralTable]
  [index : i64]) : unit
  (let
    [kind : i64 (cast (array-ref (struct-get table kinds) index) : i64)]
    [left : i64 (array-ref (struct-get table lefts) index)]
    [middle : i64 (array-ref (struct-get table middles) index)]
    [right : i64 (array-ref (struct-get table rights) index)]
    [slots : (__tl_dyn-array i64) (struct-get table map-slots)]
    [slots-address : u64 (intern-i64-array-address slots)]
    [mask : i64 (- (array-length slots) 1)]
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
      (ptr-cast (array-data ,to) : (MutPtr u8))
      (ptr-cast (array-data ,from) : (Ptr u8))
      ,bytes)))

(define (intern-structural-table-grow-records!
  [cell : (__tl_dyn-array InternStructuralTable)]
  [arena : i64]) : unit
  (let
    [table : InternStructuralTable (array-ref cell 0)]
    [count : i64 (struct-get table len)]
    [old-capacity : i64 (array-length (struct-get table kinds))]
    [new-capacity : i64 (* old-capacity 2)]
    [previous-arena : i64 (tl_arena_current)]
    (begin
      (unsafe
        (tl_arena_set arena))
      (let
        [next-kinds : (__tl_dyn-array u8) (make-array u8 new-capacity)]
        [next-lefts : (__tl_dyn-array i64) (make-array i64 new-capacity)]
        [next-middles : (__tl_dyn-array i64) (make-array i64 new-capacity)]
        [next-rights : (__tl_dyn-array i64) (make-array i64 new-capacity)]
        (begin
          (unsafe
            (tl_arena_set previous-arena))
          (intern-structural-copy-array!
            (struct-get table kinds)
            next-kinds
            count)
          (intern-structural-copy-array!
            (struct-get table lefts)
            next-lefts
            (* count 8))
          (intern-structural-copy-array!
            (struct-get table middles)
            next-middles
            (* count 8))
          (intern-structural-copy-array!
            (struct-get table rights)
            next-rights
            (* count 8))
          (set! (struct-get table kinds) next-kinds)
          (set! (struct-get table lefts) next-lefts)
          (set! (struct-get table middles) next-middles)
          (set! (struct-get table rights) next-rights)
          (if (= (struct-get table owner) intern-active-structural-owner)
            (begin
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
          (array-set! cell 0 table))))))

(define (intern-structural-table-grow-map!
  [cell : (__tl_dyn-array InternStructuralTable)]
  [arena : i64]) : unit
  (let
    [table : InternStructuralTable (array-ref cell 0)]
    [new-capacity : i64 (* (array-length (struct-get table map-slots)) 2)]
    [previous-arena : i64 (tl_arena_current)]
    (begin
      (unsafe
        (tl_arena_set arena))
      (let
        [next-slots : (__tl_dyn-array i64) (make-array i64 new-capacity)]
        (begin
          (unsafe
            (tl_arena_set previous-arena))
          (set! (struct-get table map-slots) next-slots)
          (let
            [index : i64 0]
            (while (< index (struct-get table len))
              (begin
                (intern-structural-table-map-put-index! table index)
                (set! index (+ index 1)))))
          (array-set! cell 0 table))))))

(define (intern-structural-table-intern
  [cell : (__tl_dyn-array InternStructuralTable)]
  [arena : i64]
  [kind : i64]
  [left : i64]
  [middle : i64]
  [right : i64]) : i64
  (let
    [table : InternStructuralTable (array-ref cell 0)]
    [slots : (__tl_dyn-array i64) (struct-get table map-slots)]
    [slots-address : u64 (intern-i64-array-address slots)]
    [mask : i64 (- (array-length slots) 1)]
    [slot : i64
      (intern-structural-table-first-slot table kind left middle right)]
    [searching? : bool true]
    [found : i64 -1]
    (begin
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
      (if (>= found 0)
        (intern-structural-raw-for-index (struct-get table owner) kind found)
        (begin
          (if (>=
            (struct-get table len)
            (array-length (struct-get table kinds)))
            (intern-structural-table-grow-records! cell arena)
            unit)
          (if (>=
            (* (+ (struct-get table len) 1) 4)
            (* (array-length (struct-get table map-slots)) 3))
            (intern-structural-table-grow-map! cell arena)
            unit)
          (let
            [next-table : InternStructuralTable (array-ref cell 0)]
            [index : i64 (struct-get next-table len)]
            (begin
              (if (>= index (intern-structural-key-index-mask))
                (tl_oob_abort)
                unit)
              (array-set! (struct-get next-table kinds) index (cast kind : u8))
              (array-set! (struct-get next-table lefts) index left)
              (array-set! (struct-get next-table middles) index middle)
              (array-set! (struct-get next-table rights) index right)
              (set! (struct-get next-table len) (+ index 1))
              (intern-structural-table-map-put-index! next-table index)
              (array-set! cell 0 next-table)
              (intern-structural-raw-for-index
                (struct-get next-table owner)
                kind
                index))))))))

(define (intern-structural-table-reset!
  [cell : (__tl_dyn-array InternStructuralTable)]) : unit
  (let
    [table : InternStructuralTable (array-ref cell 0)]
    [slots : (__tl_dyn-array i64) (struct-get table map-slots)]
    [structural-cache-raws : (__tl_dyn-array i64)
      (struct-get table structural-cache-raws)]
    [index : i64 0]
    (begin
      (while (< index (array-length slots))
        (begin
          (array-set! slots index 0)
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index (array-length structural-cache-raws))
        (begin
          (array-set! structural-cache-raws index 0)
          (set! index (+ index 1))))
      (set! (struct-get table owner) (intern-structural-owner-allocate!))
      (set! (struct-get table len) 0)
      (array-set! cell 0 table))))

(define (intern-structural-table-reinitialize-in-arena!
  [cell : (__tl_dyn-array InternStructuralTable)]
  [arena : i64]) : unit
  (let
    [previous-arena : i64 (tl_arena_current)]
    (begin
      (unsafe
        (tl_arena_set arena))
      (let
        [next : InternStructuralTable (intern-structural-table-new)]
        (begin
          (unsafe
            (tl_arena_set previous-arena))
          (array-set! cell 0 next))))))

(define (intern-structural-session-reset!
  [table-cell : (__tl_dyn-array InternStructuralTable)]) : unit
  (intern-structural-table-reset! table-cell))

;; Bucket IDs use the compact encoded `InternSlotId` representation. The pool owns
;; each spelling, so the hash table needs only identity and hash lanes rather
;; than a second String-bearing enum table.
(define intern-map-id-slots : (__tl_dyn-array InternSlotId)
  (make-array InternSlotId (intern-capacity)))
(define intern-map-hash-slots : (__tl_dyn-array i64)
  (make-array i64 (intern-capacity)))
(define intern-generated-map-capacity : i64
  32768)
(define intern-generated-map-id-slots : (__tl_dyn-array InternSlotId)
  (make-array InternSlotId intern-generated-map-capacity))
(define intern-generated-map-hash-slots : (__tl_dyn-array i64)
  (make-array i64 intern-generated-map-capacity))
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

;; Capability for rendering an id retained across an intern-state boundary.
;; It is captured by the few consumers that outlive the currently installed
;; table rather than adding ownership metadata to every AST name.
(defstruct InternIdProvenance
  (table-id i64)
  (generation i64))

(defenum InternIdRender
  (Ok String)
  (WrongOwner)
  (StaleGeneration)
  (InvalidId))

(define (intern-id-provenance-capture) : InternIdProvenance
  (InternIdProvenance (intern-active-table-id) intern-reset-generation))

(define (intern-id-render [owner : InternIdProvenance] [id : i64]) : InternIdRender
  (cond
    [(not (= (struct-get owner table-id) (intern-active-table-id)))
      (InternIdRender.WrongOwner)]
    [(not (= (struct-get owner generation) intern-reset-generation))
      (InternIdRender.StaleGeneration)]
    [(or (< id 0) (>= id intern-pool-count)) (InternIdRender.InvalidId)]
    [else (InternIdRender.Ok (array-ref intern-pool-slots id))]))

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

;; An immutable source-name lookup capability. The arrays are owned by one
;; intern state; the cells let resolution reject a capability after that state
;; is reset without consulting whichever compatibility table is active.
(defstruct InternSourceNameSession
  (table-id-cell (__tl_dyn-array i64))
  (reset-generation-cell (__tl_dyn-array i64))
  (pool-slots (__tl_dyn-array String))
  (map-id-slots (__tl_dyn-array InternSlotId))
  (map-hash-slots (__tl_dyn-array i64))
  (map-ready-cell (__tl_dyn-array bool))
  (table-id i64)
  (reset-generation i64)
  (source-count i64))

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
    [table-id : (__tl_dyn-array i64) (make-array i64 1)]
    [pool-count : (__tl_dyn-array i64) (make-array i64 1)]
    [generated-next-id : (__tl_dyn-array i64) (make-array i64 1)]
    [map-ready : (__tl_dyn-array bool) (make-array bool 1)]
    [reset-generation : (__tl_dyn-array i64) (make-array i64 1)]
    [persistent-arena-handle : i64 (tl_arena_make)]
    [persistent-arena : (__tl_dyn-array i64) (make-array i64 1)]
    [persistent-arena-floor-mark : (__tl_dyn-array i64) (make-array i64 1)]
    [structural-table-cell : (__tl_dyn-array InternStructuralTable)
      (intern-structural-table-cell-new-in-arena persistent-arena-handle)]
    (begin
      (array-set! table-id 0 (intern-table-id-allocate!))
      (array-set! pool-count 0 0)
      (array-set! generated-next-id 0 (- (intern-capacity) 1))
      (array-set! map-ready 0 false)
      (array-set! reset-generation 0 (intern-generation-allocate!))
      (array-set! persistent-arena 0 persistent-arena-handle)
      (array-set! persistent-arena-floor-mark 0 0)
      (InternCompatState
        table-id
        (make-array String (intern-capacity))
        (make-array bool (intern-capacity))
        (make-array i32 (intern-capacity))
        (make-array i32 (intern-capacity))
        (make-array InternSlotId (intern-capacity))
        (make-array InternSlotId (intern-capacity))
        (make-array InternSlotId (intern-capacity))
        (make-array InternSlotId (intern-capacity))
        pool-count
        generated-next-id
        (make-array InternSlotId (intern-capacity))
        (make-array i64 (intern-capacity))
        (make-array InternSlotId intern-generated-map-capacity)
        (make-array i64 intern-generated-map-capacity)
        map-ready
        reset-generation
        persistent-arena
        persistent-arena-floor-mark
        structural-table-cell))))

(define (intern-compat-state-pool-len [state : InternCompatState]) : i64
  (array-ref (struct-get state pool-count) 0))

(define (intern-compat-state-generation [state : InternCompatState]) : i64
  (array-ref (struct-get state reset-generation) 0))

(define (intern-compat-state-table-id [state : InternCompatState]) : i64
  (array-ref (struct-get state table-id) 0))

(define (intern-compat-state-persistent-arena [state : InternCompatState]) : i64
  (array-ref (struct-get state persistent-arena) 0))

(define (intern-compat-state-persistent-arena-floor-mark
  [state : InternCompatState]) : i64
  (array-ref (struct-get state persistent-arena-floor-mark) 0))

;; State-owned arena operations do not install an inactive `state` into the
;; compatibility globals. When the state is already active, keep its global
;; arena handles synchronized so they never retain destroyed storage.
(define (intern-compat-state-persistent-arena-floor-refresh!
  [state : InternCompatState]) : unit
  (let
    [prev-arena : i64 (tl_arena_current)]
    (begin
      (unsafe
        (tl_arena_set (intern-compat-state-persistent-arena state)))
      (array-set!
        (struct-get state persistent-arena-floor-mark)
        0
        (tl_region_mark))
      (if (= (intern-active-table-id) (intern-compat-state-table-id state))
        (set!
          intern-persistent-arena-floor-mark
          (intern-compat-state-persistent-arena-floor-mark state))
        unit)
      (unsafe
        (tl_arena_set prev-arena)))))

(define (intern-compat-state-persistent-arena-floor-ensure!
  [state : InternCompatState]) : unit
  (if (= (intern-compat-state-persistent-arena-floor-mark state) 0)
    (intern-compat-state-persistent-arena-floor-refresh! state)
    unit))

(define (intern-compat-state-persistent-arena-reset-to-floor!
  [state : InternCompatState]) : unit
  (let
    [prev-arena : i64 (tl_arena_current)]
    (begin
      (intern-compat-state-persistent-arena-floor-ensure! state)
      (unsafe
        (tl_arena_set (intern-compat-state-persistent-arena state))
        (tl_region_reset
          (intern-compat-state-persistent-arena-floor-mark state)))
      (intern-structural-table-reinitialize-in-arena!
        (struct-get state structural-table-cell)
        (intern-compat-state-persistent-arena state))
      (if (= (intern-active-table-id) (intern-compat-state-table-id state))
        (intern-active-structural-sync!
          (struct-get state structural-table-cell))
        unit)
      (unsafe
        (tl_arena_set prev-arena)))))

(define (intern-compat-state-persistent-arena-reset!
  [state : InternCompatState]) : unit
  (let
    [old-arena : i64 (intern-compat-state-persistent-arena state)]
    [new-arena : i64 (tl_arena_make)]
    [prev-arena : i64 (tl_arena_current)]
    [active? : bool
      (= (intern-active-table-id) (intern-compat-state-table-id state))]
    (begin
      (array-set! (struct-get state persistent-arena) 0 new-arena)
      (array-set! (struct-get state persistent-arena-floor-mark) 0 0)
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
        (struct-get state structural-table-cell)
        new-arena)
      (if active?
        (intern-active-structural-sync!
          (struct-get state structural-table-cell))
        unit)
      (unsafe
        (tl_arena_destroy old-arena))
      (intern-compat-state-persistent-arena-floor-refresh! state))))

(define (intern-compat-state-fill-empty!
  [state : InternCompatState]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! (struct-get state map-id-slots) index (intern-id-slot-empty))
      (intern-compat-state-fill-empty! state (+ index 1) count))))

(define (intern-compat-state-generated-map-clear! [state : InternCompatState]) : unit
  (let
    [slots : (__tl_dyn-array InternSlotId)
      (struct-get state generated-map-id-slots)]
    [index : i64 0]
    [count : i64 (array-length slots)]
    (while (< index count)
      (begin
        (array-set! slots index (intern-id-slot-empty))
        (set! index (+ index 1))))))

(define (intern-compat-state-map-insert-existing-from!
  [state : InternCompatState]
  [id : i64]
  [hash : i64]
  [cursor : i64]
  [steps : i64]
  [capacity : i64]) : unit
  (let
    [slot : i64 cursor]
    [probes : i64 steps]
    (while (< probes capacity)
      (if (intern-id-slot-empty?
        (array-ref (struct-get state map-id-slots) slot))
        (begin
          (array-set!
            (struct-get state map-id-slots)
            slot
            (intern-id-slot-encode id))
          (array-set! (struct-get state map-hash-slots) slot hash)
          (return unit))
        (begin
          (set! slot (intern-bucket (+ slot 1) capacity))
          (set! probes (+ probes 1)))))))

(define (intern-compat-state-map-insert-existing!
  [state : InternCompatState]
  [id : i64]) : unit
  (let
    [name : String (array-ref (struct-get state pool-slots) id)]
    [hash : i64 (intern-hash name)]
    [capacity : i64 (array-length (struct-get state map-id-slots))]
    (intern-compat-state-map-insert-existing-from!
      state
      id
      hash
      (intern-bucket hash capacity)
      0
      capacity)))

(define (intern-compat-state-map-rebuild-prefix!
  [state : InternCompatState]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (intern-compat-state-map-insert-existing! state index)
      (intern-compat-state-map-rebuild-prefix! state (+ index 1) count))))

(define (intern-compat-state-reset! [state : InternCompatState]) : unit
  (begin
    (array-set! (struct-get state pool-count) 0 0)
    (array-set! (struct-get state generated-next-id) 0 (- (intern-capacity) 1))
    (intern-compat-state-fill-empty!
      state
      0
      (array-length (struct-get state map-id-slots)))
    (intern-compat-state-generated-map-clear! state)
    (intern-structural-session-reset! (struct-get state structural-table-cell))
    (if (= (intern-active-table-id) (intern-compat-state-table-id state))
      (intern-active-structural-sync! (struct-get state structural-table-cell))
      unit)
    (array-set!
      (struct-get state reset-generation)
      0
      (intern-generation-allocate!))
    (array-set! (struct-get state map-ready) 0 true)))

(define (intern-compat-state-reset-to! [state : InternCompatState] [mark : i64]) : unit
  (begin
    (array-set! (struct-get state pool-count) 0 mark)
    (array-set! (struct-get state generated-next-id) 0 (- (intern-capacity) 1))
    (intern-compat-state-fill-empty!
      state
      0
      (array-length (struct-get state map-id-slots)))
    (intern-compat-state-generated-map-clear! state)
    (intern-structural-session-reset! (struct-get state structural-table-cell))
    (if (= (intern-active-table-id) (intern-compat-state-table-id state))
      (intern-active-structural-sync! (struct-get state structural-table-cell))
      unit)
    (intern-compat-state-map-rebuild-prefix! state 0 mark)
    (array-set!
      (struct-get state reset-generation)
      0
      (intern-generation-allocate!))
    (array-set! (struct-get state map-ready) 0 true)))

(define (intern-compat-state-persistent-substring
  [state : InternCompatState]
  [text : String]
  [start : i64]
  [len : i64]) : String
  (let
    [prev-arena : i64 (tl_arena_current)]
    (if (= prev-arena (intern-compat-state-persistent-arena state))
      (intern-substring text start len)
      (let
        [out : String
          (begin
            (unsafe
              (tl_arena_set (intern-compat-state-persistent-arena state)))
            (let
              [copied : String (intern-substring text start len)]
              (begin
                (unsafe
                  (tl_arena_set prev-arena))
                copied)))]
        out))))

(define (intern-compat-state-persistent-copy
  [state : InternCompatState]
  [text : String]) : String
  (if (= (tl_arena_current) (intern-compat-state-persistent-arena state))
    text
    (intern-compat-state-persistent-substring
      state
      text
      0
      (intern-private-string-length text))))

(define (intern-compat-state-record-qualified-metadata!
  [state : InternCompatState]
  [id : i64]
  [name : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (intern-private-string-length name)]
    [slash : i64 -1]
    [dot : i64 -1]
    (begin
      (while (< i n)
        (let
          [c : char (intern-private-string-ref name i)]
          (begin
            (if (= c '/')
              (set! slash i)
              unit)
            (if (and (< dot 0) (= c '.'))
              (set! dot i)
              unit)
            (set! i (+ i 1)))))
      (array-set!
        (struct-get state pool-last-slash-slots)
        id
        (cast slash : i32))
      (array-set! (struct-get state pool-first-dot-slots) id (cast dot : i32))
      (array-set!
        (struct-get state pool-leading-dot-id-slots)
        id
        (intern-id-slot-encode
          (if (< dot 0)
            -1
            (intern-compat-state-intern state (intern-substring name 0 dot)))))
      (if (< slash 0)
        (begin
          (array-set! (struct-get state pool-qualified-slots) id false)
          (array-set!
            (struct-get state pool-module-id-slots)
            id
            (intern-id-slot-encode -1))
          (array-set!
            (struct-get state pool-base-id-slots)
            id
            (intern-id-slot-encode id)))
        (let
          [base-start : i64 (+ slash 1)]
          (begin
            (array-set! (struct-get state pool-qualified-slots) id true)
            (array-set!
              (struct-get state pool-module-id-slots)
              id
              (intern-id-slot-encode
                (intern-compat-state-intern
                  state
                  (intern-substring name 0 slash))))
            (array-set!
              (struct-get state pool-base-id-slots)
              id
              (intern-id-slot-encode
                (intern-compat-state-intern
                  state
                  (intern-substring name base-start (- n base-start)))))))))))

;; State-owned interning mirrors the compatibility table without installing it
;; into process globals. Compile-job setup and reset paths use this API while
;; the legacy parser/typecheck/lower call graph is migrated incrementally.
(define (intern-compat-state-intern [state : InternCompatState] [name : String]) : i64
  (begin
    (if (array-ref (struct-get state map-ready) 0)
      unit
      (intern-compat-state-reset! state))
    (let
      [capacity : i64 (array-length (struct-get state map-id-slots))]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : i64 -1]
      [done : bool false]
      (begin
        (while (and (not done) (< steps capacity))
          (let
            [stored-id : InternSlotId
              (array-ref (struct-get state map-id-slots) cursor)]
            (if (intern-id-slot-empty? stored-id)
              (let
                [persistent-name : String
                  (intern-compat-state-persistent-copy state name)]
                [id : i64 (intern-compat-state-pool-len state)]
                (begin
                  (array-set! (struct-get state pool-slots) id persistent-name)
                  (array-set!
                    (struct-get state map-id-slots)
                    cursor
                    (intern-id-slot-encode id))
                  (array-set! (struct-get state map-hash-slots) cursor hash)
                  (array-set! (struct-get state pool-count) 0 (+ id 1))
                  (intern-compat-state-record-qualified-metadata!
                    state
                    id
                    persistent-name)
                  (set! out id)
                  (set! done true)))
              (let
                [slot-id : i64 (intern-id-slot-decode stored-id)]
                [slot-hash : i64
                  (array-ref (struct-get state map-hash-slots) cursor)]
                [slot-key : String
                  (array-ref (struct-get state pool-slots) slot-id)]
                (if (and
                  (= slot-hash hash)
                  (intern-private-string-eq slot-key name))
                  (begin
                    (set! out slot-id)
                    (set! done true))
                  (begin
                    (set! cursor (intern-bucket (+ cursor 1) capacity))
                    (set! steps (+ steps 1))))))))
        out))))

(define (intern-compat-state-lookup [state : InternCompatState] [name : String]) : InternLookup
  (if (array-ref (struct-get state map-ready) 0)
    (let
      [capacity : i64 (array-length (struct-get state map-id-slots))]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : InternLookup InternLookupMissing]
      [done : bool false]
      (begin
        (while (and (not done) (< steps capacity))
          (let
            [stored-id : InternSlotId
              (array-ref (struct-get state map-id-slots) cursor)]
            (if (intern-id-slot-empty? stored-id)
              (set! done true)
              (let
                [slot-id : i64 (intern-id-slot-decode stored-id)]
                [slot-hash : i64
                  (array-ref (struct-get state map-hash-slots) cursor)]
                [slot-key : String
                  (array-ref (struct-get state pool-slots) slot-id)]
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

(define (intern-compat-state-str [state : InternCompatState] [id : i64]) : String
  (array-ref (struct-get state pool-slots) id))

(define (intern-compat-state-qualified? [state : InternCompatState] [id : i64]) : bool
  (array-ref (struct-get state pool-qualified-slots) id))

(define (intern-compat-state-qualified-last-slash
  [state : InternCompatState]
  [id : i64]) : i64
  (cast (array-ref (struct-get state pool-last-slash-slots) id) : i64))

(define (intern-compat-state-first-dot [state : InternCompatState] [id : i64]) : i64
  (cast (array-ref (struct-get state pool-first-dot-slots) id) : i64))

(define (intern-compat-state-leading-dot-id
  [state : InternCompatState]
  [id : i64]) : i64
  (intern-id-slot-decode
    (array-ref (struct-get state pool-leading-dot-id-slots) id)))

(define (intern-compat-state-qualified-module-id
  [state : InternCompatState]
  [id : i64]) : i64
  (intern-id-slot-decode (array-ref (struct-get state pool-module-id-slots) id)))

(define (intern-compat-state-qualified-base-id
  [state : InternCompatState]
  [id : i64]) : i64
  (intern-id-slot-decode (array-ref (struct-get state pool-base-id-slots) id)))

(define (intern-compat-state-install! [state : InternCompatState]) : unit
  (let
    [next-table-id : i64 (intern-compat-state-table-id state)]
    (begin
      (set! intern-active-table-id-value next-table-id)
      (set! intern-pool-slots (struct-get state pool-slots))
      (set! intern-pool-qualified-slots (struct-get state pool-qualified-slots))
      (set!
        intern-pool-last-slash-slots
        (struct-get state pool-last-slash-slots))
      (set! intern-pool-first-dot-slots (struct-get state pool-first-dot-slots))
      (set!
        intern-pool-leading-dot-id-slots
        (struct-get state pool-leading-dot-id-slots))
      (set!
        intern-pool-dotted-prefix-id-slots
        (struct-get state pool-dotted-prefix-id-slots))
      (set! intern-pool-module-id-slots (struct-get state pool-module-id-slots))
      (set! intern-pool-base-id-slots (struct-get state pool-base-id-slots))
      (set! intern-pool-count (array-ref (struct-get state pool-count) 0))
      (set!
        intern-generated-next-id
        (array-ref (struct-get state generated-next-id) 0))
      (set! intern-map-id-slots (struct-get state map-id-slots))
      (set! intern-map-hash-slots (struct-get state map-hash-slots))
      (set!
        intern-generated-map-id-slots
        (struct-get state generated-map-id-slots))
      (set!
        intern-generated-map-hash-slots
        (struct-get state generated-map-hash-slots))
      (set! intern-map-ready (array-ref (struct-get state map-ready) 0))
      (set!
        intern-reset-generation
        (array-ref (struct-get state reset-generation) 0))
      (set! intern-name-cache-ready false)
      (set!
        intern-persistent-arena
        (array-ref (struct-get state persistent-arena) 0))
      (set!
        intern-persistent-arena-floor-mark
        (array-ref (struct-get state persistent-arena-floor-mark) 0))
      (set!
        intern-structural-table-cell
        (struct-get state structural-table-cell))
      (intern-active-structural-sync! intern-structural-table-cell))))

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
        intern-structural-table-cell
        new-arena)
      (intern-active-structural-sync! intern-structural-table-cell)
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
        (tl_region_reset intern-persistent-arena-floor-mark))
      (intern-structural-table-reinitialize-in-arena!
        intern-structural-table-cell
        intern-persistent-arena)
      (intern-active-structural-sync! intern-structural-table-cell)
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
;; `compiler_intern` is import-free, so it only exposes reset and value
;; accessors; the driver (which owns `io`) prints them at compile end.
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
      (set! intern-profile-slice-miss-count 0))))

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
  (define (intern-profile-invalid-str-last-id-value) : i64
    intern-profile-invalid-str-last-id))

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
    (__tl_string_length s)))

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

(define (intern-substring [text : String] [start : i64] [len : i64]) : String
  (let
    [buf : (__tl_dyn-array u8) (make-array u8 len)]
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

(define (intern-persistent-copy [text : String]) : String
  (intern-persistent-substring text 0 (__tl_string_length text)))

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

;; Snapshot producers enumerate generated identities in allocation order. The
;; high-end numeric representation is deliberately kept behind these helpers:
;; serialized consumers must rebuild process-local identities instead of
;; treating an id from the producing generation as portable.
(define (intern-generated-count) : i64
  (- (- (intern-capacity) 1) intern-generated-next-id))

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
        (array-set! intern-pool-qualified-slots id qualified)
        (array-set!
          intern-pool-last-slash-slots
          id
          (if qualified
            (cast (intern-private-last-slash persistent-name) : i32)
            (cast -1 : i32)))
        (array-set! intern-pool-first-dot-slots id (cast -1 : i32))
        (array-set!
          intern-pool-leading-dot-id-slots
          id
          (intern-id-slot-encode -1))
        (array-set!
          intern-pool-dotted-prefix-id-slots
          id
          (intern-id-slot-encode -1))
        (array-set!
          intern-pool-module-id-slots
          id
          (intern-id-slot-encode module-id))
        (array-set!
          intern-pool-base-id-slots
          id
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
          (array-set! intern-pool-first-dot-slots id (cast first-dot : i32))
          (array-set!
            intern-pool-leading-dot-id-slots
            id
            (intern-id-slot-encode leading-dot-id))
          (array-set!
            intern-pool-dotted-prefix-id-slots
            id
            (intern-id-slot-encode dotted-prefix-id))
          (array-set!
            intern-pool-base-id-slots
            id
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
          [stored : String (array-ref intern-pool-slots id)]
          (begin
            (if dotted
              (begin
                (array-set!
                  intern-pool-first-dot-slots
                  id
                  (cast (intern-private-first-dot stored) : i32))
                (array-set!
                  intern-pool-leading-dot-id-slots
                  id
                  (intern-id-slot-encode leading-dot-id))
                (array-set!
                  intern-pool-dotted-prefix-id-slots
                  id
                  (intern-id-slot-encode dotted-prefix-id))
                (array-set!
                  intern-pool-base-id-slots
                  id
                  (intern-id-slot-encode dotted-tail-id)))
              unit)
            (array-set!
              intern-generated-map-id-slots
              cursor
              (intern-id-slot-encode id))
            (array-set! intern-generated-map-hash-slots cursor hash)
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
  [name : String]
  [text : String]
  [start : i64]
  [len : i64]) : bool
  (if (= (__tl_string_length name) len)
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
      (array-set! intern-pool-last-slash-slots id (cast slash : i32))
      (array-set! intern-pool-first-dot-slots id (cast dot : i32))
      (array-set!
        intern-pool-leading-dot-id-slots
        id
        (intern-id-slot-encode
          (if (< dot 0)
            -1
            (intern-slice name 0 dot))))
      (array-set!
        intern-pool-dotted-prefix-id-slots
        id
        (intern-id-slot-encode
          (if (>= last-dot 0)
            (intern-slice name 0 last-dot)
            -1)))
      (if (< slash 0)
        (begin
          (array-set! intern-pool-qualified-slots id false)
          (array-set! intern-pool-module-id-slots id (intern-id-slot-encode -1))
          (array-set!
            intern-pool-base-id-slots
            id
            (intern-id-slot-encode
              (if (< dot 0)
                id
                (intern-slice name (+ dot 1) (- n (+ dot 1)))))))
        (let
          [base-start : i64 (+ slash 1)]
          (begin
            (array-set! intern-pool-qualified-slots id true)
            (array-set!
              intern-pool-module-id-slots
              id
              (intern-id-slot-encode (intern-slice name 0 slash)))
            (array-set!
              intern-pool-base-id-slots
              id
              (intern-id-slot-encode
                (intern-slice name base-start (- n base-start))))))))))

;: Clear bucket identities; stale hashes are ignored while the ID lane is zero.
(define (intern-fill-empty [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! intern-map-id-slots index (intern-id-slot-empty))
      (intern-fill-empty (+ index 1) count))))

(define (intern-generated-map-clear! [index : i64]) : unit
  (if (>= index intern-generated-map-capacity)
    unit
    (begin
      (array-set! intern-generated-map-id-slots index (intern-id-slot-empty))
      (intern-generated-map-clear! (+ index 1)))))

(define (intern-reset-name-cache!) : unit
  (set! intern-name-cache-ready false))

(define (intern-name-cache-record [name : String] [id : i64]) : unit
  (begin
    (set! intern-name-cache-name name)
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
          (array-set! intern-map-id-slots slot (intern-id-slot-encode id))
          (array-set! intern-map-hash-slots slot hash)
          (return unit))
        (begin
          (set! slot (intern-bucket (+ slot 1) capacity))
          (set! probes (+ probes 1)))))))

(define (intern-map-insert-existing! [id : i64]) : unit
  (let
    [name : String (array-ref intern-pool-slots id)]
    [hash : i64 (intern-hash name)]
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
    (intern-structural-session-reset! intern-structural-table-cell)
    (intern-active-structural-sync! intern-structural-table-cell)
    (set! intern-reset-generation (intern-generation-allocate!))
    (set! intern-map-ready true)))

(define (intern-reset-to! [mark : i64]) : unit
  (begin
    (set! intern-pool-count mark)
    (set! intern-generated-next-id (- (intern-capacity) 1))
    (intern-fill-empty 0 (array-length intern-map-id-slots))
    (intern-generated-map-clear! 0)
    (intern-structural-session-reset! intern-structural-table-cell)
    (intern-active-structural-sync! intern-structural-table-cell)
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
        (intern-private-string-eq-places intern-name-cache-name name))
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
                [persistent-name : String (intern-persistent-copy name)]
                [id : i64 (intern-source-id-allocate!)]
                (begin
                  (array-set! intern-pool-slots id persistent-name)
                  (intern-record-qualified-metadata id persistent-name)
                  (intern-map-insert-existing-from id hash cursor 0 capacity)
                  (intern-name-cache-record persistent-name id)
                  (set! out id)
                  (set! done true)))
              (let
                [source-id : i64 (intern-id-slot-decode stored-id)]
                [slot-key : String (array-ref intern-pool-slots source-id)]
                [slot-hash : i64 (array-ref intern-map-hash-slots cursor)]
                (if (and
                  (= slot-hash hash)
                  (intern-private-string-eq-places slot-key name))
                  (begin
                    (intern-name-cache-record slot-key source-id)
                    (set! out source-id)
                    (set! done true))
                  (begin
                    (set! cursor (intern-bucket (+ cursor 1) capacity))
                    (set! steps (+ steps 1))))))))
        out))))

;: Intern a source slice without allocating unless the slice is a new name.
(define (intern-slice [text : String] [start : i64] [len : i64]) : i64
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
                  (array-set! intern-pool-slots id name)
                  (intern-record-qualified-metadata id name)
                  (intern-map-insert-existing-from id hash cursor 0 capacity)
                  (set! out id)
                  (set! done true)))
              (let
                [source-id : i64 (intern-id-slot-decode stored-id)]
                [slot-key : String (array-ref intern-pool-slots source-id)]
                [slot-hash : i64 (array-ref intern-map-hash-slots cursor)]
                (if (and
                  (= slot-hash hash)
                  (intern-string-slice-eq? slot-key text start len))
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

;; Typed lexer boundary. Parser tokens can carry only renderable source names;
;; structural identities and missing sentinels remain raw in their own later
;; compiler domains until those boundaries are migrated.
(define (intern-source-slice-id [text : String] [start : i64] [len : i64]) : InternId
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
            (ptr-cast (array-data intern-map-id-slots) : (Ptr InternSlotId)))]
        [hashes : (Ptr i64)
          (unsafe
            (ptr-cast (array-data intern-map-hash-slots) : (Ptr i64)))]
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
(define (intern-source-name-session-from-state [state : InternCompatState]) : InternSourceNameSession
  (InternSourceNameSession
    (struct-get state table-id)
    (struct-get state reset-generation)
    (struct-get state pool-slots)
    (struct-get state map-id-slots)
    (struct-get state map-hash-slots)
    (struct-get state map-ready)
    (intern-compat-state-table-id state)
    (intern-compat-state-generation state)
    (intern-compat-state-pool-len state)))

;; Compatibility adapter for standalone compiler APIs. Production driver jobs
;; pass `intern-source-name-session-from-state` explicitly.
(define (intern-source-name-session-capture-active) : InternSourceNameSession
  (let
    [table-id-cell : (__tl_dyn-array i64) (make-array i64 1)]
    [generation-cell : (__tl_dyn-array i64) (make-array i64 1)]
    [map-ready-cell : (__tl_dyn-array bool) (make-array bool 1)]
    (begin
      (array-set! table-id-cell 0 (intern-active-table-id))
      (array-set! generation-cell 0 intern-reset-generation)
      (array-set! map-ready-cell 0 intern-map-ready)
      (InternSourceNameSession
        table-id-cell
        generation-cell
        intern-pool-slots
        intern-map-id-slots
        intern-map-hash-slots
        map-ready-cell
        (intern-active-table-id)
        intern-reset-generation
        intern-pool-count))))

(define (intern-source-name-session-handle [session : InternSourceNameSession]) : InternSourceNameSessionHandle
  (let
    [previous-arena : i64 (tl_arena_current)]
    (begin
      (unsafe
        (tl_arena_set intern-persistent-arena))
      (let
        [cell : (__tl_dyn-array InternSourceNameSession)
          (make-array InternSourceNameSession 1)]
        (begin
          (array-set! cell 0 session)
          (unsafe
            (tl_arena_set previous-arena))
          (InternSourceNameSessionHandle
            (cast
              (unsafe
                (ptr->int
                  (ptr-cast (array-data cell) : (Ptr InternSourceNameSession))))
              : i64)))))))

(define (intern-source-name-session-handle-session
  [handle : InternSourceNameSessionHandle]) : InternSourceNameSession
  (unsafe
    (ptr-read
      (int->ptr
        (cast (struct-get handle address) : u64)
        : (Ptr InternSourceNameSession)))))

(define (intern-source-name-session-capture-active-handle) : InternSourceNameSessionHandle
  (intern-source-name-session-handle
    (intern-source-name-session-capture-active)))

(define (intern-source-name-session-identity
  [session : InternSourceNameSession]
  [id : i64]) : InternSyntaxTextIdentity
  (InternSyntaxTextIdentity
    (struct-get session table-id)
    (struct-get session reset-generation)
    id))

(define (intern-source-name-session-lookup
  [session : InternSourceNameSession]
  [name : String]) : InternLookup
  (if (array-ref (struct-get session map-ready-cell) 0)
    (let
      [ids : (__tl_dyn-array InternSlotId) (struct-get session map-id-slots)]
      [hashes : (__tl_dyn-array i64) (struct-get session map-hash-slots)]
      [pool : (__tl_dyn-array String) (struct-get session pool-slots)]
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
                  (if (< slot-id (struct-get session source-count))
                    (return (InternLookupFound slot-id))
                    (return (InternLookupMissing)))
                  (begin
                    (set! cursor (intern-bucket (+ cursor 1) capacity))
                    (set! steps (+ steps 1))))))))
        (InternLookupMissing)))
    (InternLookupMissing)))

(define (intern-source-name-session-resolve
  [session : InternSourceNameSession]
  [identity : InternSyntaxTextIdentity]
  [text : String]) : InternSourceNameResolution
  (cond
    [(not (= (struct-get identity table-id) (struct-get session table-id)))
      (InternSourceNameResolution.WrongOwner)]
    [(not
        (=
          (array-ref (struct-get session table-id-cell) 0)
          (struct-get session table-id)))
      (InternSourceNameResolution.WrongOwner)]
    [(not
        (=
          (struct-get identity reset-generation)
          (struct-get session reset-generation)))
      (InternSourceNameResolution.StaleGeneration)]
    [(not
        (=
          (array-ref (struct-get session reset-generation-cell) 0)
          (struct-get session reset-generation)))
      (InternSourceNameResolution.StaleGeneration)]
    [(or
        (< (struct-get identity id) 0)
        (>=
          (struct-get identity id)
          (array-length (struct-get session pool-slots))))
      (InternSourceNameResolution.InvalidIdentity)]
    [(< (struct-get identity id) (struct-get session source-count))
      (InternSourceNameResolution.ParsedIdentity (struct-get identity id))]
    [else
      (InternSourceNameResolution.GeneratedIdentity
        (struct-get identity id)
        (intern-source-name-session-lookup session text))]))

;: Recover the original String for an interned id.
(define (intern-str [id : i64]) : String
  (cfg
    compile-profile
    (if (or (< id 0) (>= id (array-length intern-pool-slots)))
      (begin
        (set!
          intern-profile-invalid-str-count
          (+ intern-profile-invalid-str-count 1))
        (set! intern-profile-invalid-str-last-id id)
        "<invalid-intern-id>")
      (begin
        (set! intern-profile-render-count (+ intern-profile-render-count 1))
        (array-ref intern-pool-slots id)))
    (array-ref intern-pool-slots id)))

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
          (intern-private-string-eq (intern-str id) "persist/entry")
          (intern-qualified-metadata-case-ok? id true 7 "persist" "entry"))]
      (begin
        (intern-reset!)
        ok))))

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
    [state-a : InternCompatState (intern-compat-state-new)]
    [state-b : InternCompatState (intern-compat-state-new)]
    [equal-id : i64 (intern-compat-state-intern state-a "equal")]
    [empty-id : i64 (intern-compat-state-intern state-a "")]
    [qualified-id : i64 (intern-compat-state-intern state-a "pkg/module.name")]
    [hygiene-id : i64 (intern-compat-state-intern state-a "local#hygiene")]
    [source-mark : i64 (intern-compat-state-pool-len state-a)]
    [session-a : InternSourceNameSession
      (intern-source-name-session-from-state state-a)]
    [session-b : InternSourceNameSession
      (begin
        (intern-compat-state-intern state-b "equal")
        (intern-source-name-session-from-state state-b))]
    [generated-id : i64 (- (intern-capacity) 1)]
    [generated-a : InternSyntaxTextIdentity
      (intern-source-name-session-identity session-a generated-id)]
    [parsed-a : InternSyntaxTextIdentity
      (intern-source-name-session-identity session-a equal-id)]
    [_late-source-id : i64
      (intern-compat-state-intern state-a "after-boundary")]
    [ok : bool true]
    (begin
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
          (struct-get session-a table-id)
          (struct-get session-a reset-generation)
          -1)
        "equal")
        [(InternSourceNameResolution.InvalidIdentity) unit]
        [_ (set! ok false)])
      (intern-compat-state-reset-to! state-a source-mark)
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
        (unless (intern-reset-to-tests-ok?) (set! ok false))
        (unless (intern-persistent-floor-reset-tests-ok?) (set! ok false))
        (unless (intern-source-name-session-tests-ok?) (set! ok false))
        (intern-reset!)
        ok))))