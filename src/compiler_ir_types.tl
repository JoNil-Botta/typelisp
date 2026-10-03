;; compiler_ir_types.tl - Self-hosted compiler IR model.
;;
;; Functions contain blocks, blocks contain typed instructions, and
;; instructions use explicit vars/values.
(import stdlib.string)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_builtin_ids as cbi)
(import compiler_ast_types as ast)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.text_buf)
(import stdlib.hash)
(import stdlib.hashmap)
(import stdlib.arena)
(import stdlib.comptime)
(import compiler_owned_view as owned_view)
(import (hashmap.hashmap String i64) as ir_label_map)
(import (hashmap.hashmap i64 i64) as ir_i64_i64_map)

(defmacro (compiler-ir-global-shared-view [place : Expr]) : Expr
  `(owned_view.compiler-owned-shared-view ,place))

(defmacro (compiler-ir-array-shared-view [items : Expr] [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

(defmacro (compiler-ir-box-shared-view [value : Expr]) : Expr
  (let
    [inner-ty : comptime.Expr
      (comptime.box-element-type (comptime.expr-type value))]
    `(compiler-ir-typed-box-shared-view ,value ,inner-ty)))

(defmacro (compiler-ir-box-field-shared-view [value : Expr] [field : Expr]) : Expr
  `(let
    [payload (compiler-ir-box-shared-view ,value)]
    (compiler-ir-global-shared-view (__tl-project-field payload ,field))))

(defmacro (compiler-ir-typed-box-shared-view
  [value : Expr]
  ;; Spliced into the generated pointer element type.
  ;; lint-allow: unused-variable
  [inner-ty : Expr]) : Expr
  `(let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of ,value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr ,inner-ty))))))

(defenum CompilerIrBinOp
  (Add)
  (Sub)
  (Mul)
  (Div)
  (Mod)
  (SafeDiv)
  (SafeMod)
  (Eq)
  (Ne)
  (Lt)
  (Le)
  (Gt)
  (Ge)
  ;; IR-only masked-zero comparisons. These are introduced after use-count
  ;; analysis proves that an integer BitAnd feeds only a zero comparison, so
  ;; the backend can lower the operation directly with `test` without
  ;; materializing the BitAnd result.
  (BitTestEq)
  (BitTestNe)
  (And)
  (Or)
  (BitAnd)
  (BitOr)
  (BitXor)
  ;; Scalar shifts carry the independently typed RHS count.  The BinOp
  ;; instruction's type field remains the lhs/result type; this payload is
  ;; metadata used by lowering, optimization, and backend guard emission.
  (Shl ast.AstType)
  (Shr ast.AstType))

;; Return the RHS operand type carried by a shift.  All non-shift operations
;; use the instruction operand type for both operands.
(define (compiler-ir-binop-rhs-type
  [op : CompilerIrBinOp]
  [operand-ty : ast.AstType]) : ast.AstType
  (match op
    [(Shl rhs-ty) rhs-ty]
    [(Shr rhs-ty) rhs-ty]
    [_ operand-ty]))

;; Scalar comparison instructions carry their operand type in the `BinOp`
;; type field. Their destination is always `bool`; every other binary op uses
;; the field as both operand and result type.
(define (compiler-ir-binop-compare? [op : CompilerIrBinOp]) : bool
  (match op
    [(Eq) true]
    [(Ne) true]
    [(Lt) true]
    [(Le) true]
    [(Gt) true]
    [(Ge) true]
    [(BitTestEq) true]
    [(BitTestNe) true]
    [_ false]))

(define (compiler-ir-binop-result-type
  [op : CompilerIrBinOp]
  [instruction-ty : ast.AstType]) : ast.AstType
  (if (compiler-ir-binop-compare? op)
    (Bool)
    instruction-ty))

(defenum CompilerIrUnOp
  (Neg)
  (Not)
  (BitNot)
  (Sqrt)
  ;; Number of significant bits of a 64-bit integer: floor(log2 x) + 1 for
  ;; x > 0 (signed operand) or x != 0 (unsigned operand), and 0 otherwise.
  ;; Introduced only by the optimizer's bit-length loop idiom (BITLEN).
  (BitLength))

(defenum CompilerIrMaskBinOp
  (And)
  (Or))

(defenum CompilerIrVectorReduceOp
  (Sum)
  (Min)
  (Max))

(defenum CompilerIrVectorPrefixOp
  (Sum)
  (Min)
  (Max)
  (All)
  (Any))

(defenum CompilerIrMaskReduceOp
  (All)
  (Any))

;; Parsed symbols use their parser ID directly; synthesized/structural symbols
;; receive one generated ID whose pool entry owns the display spelling. Most IR
;; still stores that raw i64, avoiding a heap object for every name occurrence.
;; Typed boundaries use this one-word handle so packed structural keys and
;; missing-value sentinels cannot be rendered accidentally.
;;
;; The one-word representation is pinned by
;; `compiler-backend-source-span-symbol-provenance-ok?` in
;; `compiler_backend_tests.tl`, not here: `size-of` needs a `(type T)`
;; literal. Layout assertions for compiler types still belong in the
;; test-only modules outside `main.tl`'s closure: a literal anywhere in the
;; compiled program forces the tens-of-MB CTFE reflection/layout metadata
;; build for the whole compile (#5872, #5875).
(defstruct CompilerIrSymbolId
  (value i64))

(define (compiler-ir-symbol-id-size) : i64
  (comptime (size-of (type CompilerIrSymbolId))))

(define (compiler-ir-symbol-typed-id [symbol : i64]) : CompilerIrSymbolId
  (CompilerIrSymbolId symbol))

(define (compiler-ir-symbol-id-value [symbol : CompilerIrSymbolId]) : i64
  symbol.value)

(define (compiler-ir-symbol-id-eq?
  [left : CompilerIrSymbolId]
  [right : CompilerIrSymbolId]) : bool
  (= (compiler-ir-symbol-id-value left) (compiler-ir-symbol-id-value right)))

(define (compiler-ir-symbol-id-text [symbol : CompilerIrSymbolId]) : String
  (compiler-ir-symbol-text (compiler-ir-symbol-id-value symbol)))

(define (compiler-ir-symbol-id [symbol : i64]) : i64
  symbol)

;: Render a symbol id. This is the one choke point every emission and
;: diagnostic path goes through, so it is where the two symbol id spaces meet:
;: ids the IR's own derived-symbol table minted (see `compiler-ir-symbol` below)
;: render from that table, while only active renderable ids reach the front-end
;: pool. Ids outside both -- future compact handles the current pool has not
;: allocated, other tagged compiler identities, negative sentinels, and the
;: unallocated tail of the IR domain -- render as the empty string rather than
;: aborting, matching
;: `compiler-ir-label-text`: diagnostics reach this path with whatever the IR
;: happens to hold.
(define (compiler-ir-symbol-text [symbol : i64]) : String
  (cond
    [(< symbol 0) ""]
    [(compiler-ir-symbol-owned? symbol)
      (compiler-ir-array-shared-view
        compiler-ir-symbol-slots
        (compiler-ir-symbol-slot-unchecked symbol))]
    [(ci.intern-renderable-id? symbol) (ci.intern-str symbol)]
    [else ""]))

(define (compiler-ir-symbol-eq? [left : i64] [right : i64]) : bool
  (= left right))

(define (compiler-ir-symbol-clone [symbol : i64]) : i64
  symbol)

(define (compiler-ir-test-symbol [name : String]) : i64
  (compiler-ir-symbol name))

;; Block labels are interned, but into a table the IR owns rather than into the
;; front end's `intern` pool. That pool is fixed-size, sized for source
;; identifiers, and aborts when generated names exhaust it; a whole-program
;; self-compile creates far more block labels than that. This table grows, so
;; the id space is bounded by the labels actually created (refs #5718).
;;
;; The IR stores the id, not the spelling: identity is an integer compare and a
;; CFG map is integer-keyed, which is what the optimizer, register allocator and
;; backend want. Only emission and diagnostics ask for the text back. `-1` is
;; the absent label, matching the symbol family's negative-id contract.
;;
;; Storage (#8409). Each spelling is copied once, into the label arena below,
;; which is never released: `compiler-ir-label-text` hands out its descriptors.
;; Everything that grows lives in one generation arena instead: `slots`, the
;; descriptor of every id, and `index`, an open-addressing table of ids keyed by
;; the spelling's hash and compared against `slots`. Growing both builds the
;; replacement in a fresh arena, publishes it, then destroys the previous
;; generation, so only the current one is live. Nothing holds a generation's
;; arrays across a call: readers load the globals on every access.
(define compiler-ir-label-slots : (__tl_dyn-array String)
  (__tl_make-array String 0))

;; Twice the capacity of `slots`, so it is at most half full; -1 is empty.
(define compiler-ir-label-index : (__tl_dyn-array i64)
  (__tl_make-array i64 0))
(define compiler-ir-label-count : i64
  0)
(define compiler-ir-label-seeded : bool
  false)
(define compiler-ir-label-generation-arena-handle : i64
  0)

(define (compiler-ir-label-generation-arena-handle-value) : i64
  compiler-ir-label-generation-arena-handle)

;; A generation in its own arena: `capacity` slots holding the current ids'
;; descriptors, and an index over them.
(define (compiler-ir-label-generation-install! [capacity : i64]) : unit
  (let
    [retired : i64 compiler-ir-label-generation-arena-handle]
    [generation : i64 (arena.tl_arena_make)]
    (in-arena
      (arena.Arena generation)
      (let
        [slots : (__tl_dyn-array String) (__tl_make-array String capacity)]
        [index : (__tl_dyn-array i64) (__tl_make-array i64 (* 2 capacity))]
        [position : i64 0]
        [id : i64 0]
        (while (< position (array-length index))
          (set! (array-ref index position) -1)
          (set! position (+ position 1)))
        (while (< id compiler-ir-label-count)
          (let
            [text : String
              (compiler-ir-array-shared-view compiler-ir-label-slots id)]
            (set! (array-ref slots id) text)
            ;; Spellings are distinct, so each id takes the first empty
            ;; position of its probe sequence.
            (set! position (compiler-ir-label-home (& text) (& index)))
            (while (>= (array-ref index position) 0)
              (set!
                position
                (bit-and (+ position 1) (- (array-length index) 1))))
            (set! (array-ref index position) id)
            (set! id (+ id 1))))
        (set! compiler-ir-label-slots slots)
        (set! compiler-ir-label-index index)))
    (set! compiler-ir-label-generation-arena-handle generation)
    (if (= retired 0)
      unit
      (unsafe
        (arena.tl_arena_destroy retired)))))

;; `name`'s first probe position in `index`, whose length is a power of two.
(define (compiler-ir-label-home
  [name : (& name str)]
  [index : (& index (__tl_dyn-array i64))]) : i64
  (let
    [hash : i64 (hash.string-key name)]
    (bit-and (bit-xor hash (shr hash 15)) (- (array-length index) 1))))

;; The index position holding `name`'s id, or the empty position where it
;; would go.
(define (compiler-ir-label-position [name : (& name str)]) : i64
  (let
    [mask : i64 (- (array-length compiler-ir-label-index) 1)]
    [position : i64 (compiler-ir-label-home name (& compiler-ir-label-index))]
    [found : bool false]
    (while (not found)
      (let
        [id : i64 (array-ref compiler-ir-label-index position)]
        (if (< id 0)
          (set! found true)
          (let
            [text : String
              (compiler-ir-array-shared-view compiler-ir-label-slots id)]
            (if (string.eq (& text) name)
              (set! found true)
              (set! position (bit-and (+ position 1) mask)))))))
    position))

;; The spellings outlive every lowering/optimizer scratch arena and every intern
;; floor reset -- an id handed to the backend must still render -- so they are
;; bound in a dedicated arena that is created once and only grows. This follows
;; CONTRIBUTING.md's full-lifetime compiler arena ownership rule.
(define compiler-ir-label-arena-handle : i64
  0)

(define (compiler-ir-label-arena-handle-value) : i64
  compiler-ir-label-arena-handle)

(define (compiler-ir-label-arena) : i64
  (if (= compiler-ir-label-arena-handle 0)
    (set! compiler-ir-label-arena-handle (arena.tl_arena_make))
    unit)
  compiler-ir-label-arena-handle)

(define (compiler-ir-label-seed!) : unit
  (unless
    compiler-ir-label-seeded
    (set! compiler-ir-label-count 0)
    (compiler-ir-label-generation-install! 1024)
    (set! compiler-ir-label-seeded true)))

(define (compiler-ir-label [name : String]) : i64
  (compiler-ir-label-seed!)
  (compiler-ir-label-lookup name))

(define (compiler-ir-label-lookup [name : String]) : i64
  (let
    [position : i64 (compiler-ir-label-position (& name))]
    [existing : i64 (array-ref compiler-ir-label-index position)]
    (if (>= existing 0)
      existing
      (let
        [id : i64 compiler-ir-label-count]
        (unless
          (< id (array-length compiler-ir-label-slots))
          (compiler-ir-label-generation-install!
            (* 2 (array-length compiler-ir-label-slots)))
          (set! position (compiler-ir-label-position (& name))))
        (set!
          (array-ref compiler-ir-label-slots id)
          (in-arena
            (arena.Arena (compiler-ir-label-arena))
            (string.copy (& name))))
        (set! (array-ref compiler-ir-label-index position) id)
        (set! compiler-ir-label-count (+ id 1))
        id))))

;: The id `name` already has, or -1 when it was never interned. Unlike
;: `compiler-ir-label` this never creates an id: a query that asks about a
;: spelling the program may not contain must not grow the table, because ids
;: are dense in [0, count) and side tables are sized from
;: `compiler-ir-label-count-value` before the query runs.
(define (compiler-ir-label-existing [name : String]) : i64
  (if (not compiler-ir-label-seeded)
    -1
    (array-ref compiler-ir-label-index (compiler-ir-label-position (& name)))))

;: Number of distinct labels interned so far. Ids are dense in [0, count),
;: so a side table indexed by label id needs exactly this many slots.
(define (compiler-ir-label-count-value) : i64
  compiler-ir-label-count)

(define (compiler-ir-label-text [label : i64]) : String
  (if (or (< label 0) (>= label compiler-ir-label-count))
    ""
    (compiler-ir-array-shared-view compiler-ir-label-slots label)))

(define (compiler-ir-label-none) : i64
  -1)

(define (compiler-ir-label-some? [label : i64]) : bool
  (>= label 0))

;; Derived symbols -- the `<module>/<name>` and `<path>::<module>/<name>`
;; logical spellings lowering mints for every function, global and call target
;; whose identity is not a parsed source symbol -- are interned into a table the
;; IR owns rather than into the front end's `intern` pool, for exactly the reason
;; block labels are (above): derived spellings are the bulk of a whole-program
;; self-compile's generated names. This table grows, so the id space is bounded
;; by the symbols actually created (refs #6293).
;;
;; Ids are `compiler-ir-symbol-base + dense-index`, placed in the fixed positive
;; domain [2*2^32, 3*2^32). This stays disjoint from the complete compact
;; `InternId(u32)` space rather than merely today's intern capacity, from the
;; cfg-key domain reserved by compiler_intern, from negative sentinels, and from
;; session structural records beginning at 2^62. The dense 32-bit payload
;; remains a single word, is independent of every pool resize, and leaves
;; headroom for optimizer-local small-field packing of a symbol identity.
;;
;; Two invariants this table owns:
;;
;; * Sole spelling authority. This table owns the spelling of every symbol it
;;   mints. The first-writer-wins `intern-composite-rendered-name` cache is
;;   neither consulted nor written on this path; that cache stays exclusively
;;   `ast-nominal-name-id-display`'s.
;; * Definition and call sites agree by construction. The key is the full
;;   display string, exactly as `intern-generated-canonical-name` keyed it, so
;;   two renders of one spelling return the same id no matter which call site
;;   produced it or how its components were split -- which is why emitted
;;   spellings stay byte-identical.
;;
;; What the table does not own is a spelling the intern pool's canonical
;; generated namespace already holds. That namespace is shared: a runtime name
;; like `tl_arena_current` is minted there at parse start and the backend then
;; decides "the runtime provides this" by comparing ids, so a derived symbol
;; spelled the same has to *be* that id. `compiler-ir-symbol-lookup` therefore
;; defers to an existing canonical generated id before minting one of its own.
(define (compiler-ir-symbol-base) : i64
  (ci.intern-ir-symbol-domain-base))

(define (compiler-ir-symbol-domain? [symbol : i64]) : bool
  (and
    (>= symbol (compiler-ir-symbol-base))
    (< symbol (ci.intern-ir-symbol-domain-limit))))

;; Capacity-independent raw encoding used by the table's mint path and by
;; namespace boundary tests. Encoding an index does not confer table ownership;
;; only the live dense prefix accepted by `compiler-ir-symbol-owned?` may index
;; the spelling table.
(define (compiler-ir-symbol-domain-id-for-index [index : i64]) : i64
  (if (or (< index 0) (>= index (ci.intern-compiler-identity-domain-width)))
    (ci.intern-compiler-identity-domain-overflow-abort)
    (+ (compiler-ir-symbol-base) index)))

(defmacro (compiler-ir-symbol-slot-unchecked [symbol : Expr]) : i64
  `(- ,symbol (compiler-ir-symbol-base)))

(define compiler-ir-symbol-slots : (__tl_dyn-array String)
  (__tl_make-array String 1024))
(define compiler-ir-symbol-count : i64
  0)
(define compiler-ir-symbol-ids : ir_label_map.Map
  (ir_label_map.with-capacity 2048))
(define compiler-ir-symbol-seeded : bool
  false)

(define (compiler-ir-symbol-grow!) : unit
  (let
    [old-len : i64 (array-length compiler-ir-symbol-slots)]
    [next : (__tl_dyn-array String) (__tl_make-array String (* old-len 2))]
    [index : i64 0]
    (while (< index old-len)
      (set! (array-ref next index) (array-ref compiler-ir-symbol-slots index))
      (set! index (+ index 1)))
    (set! compiler-ir-symbol-slots next)))

;; Same arena rationale as the label table above: a symbol id handed to the
;; backend must still render after every lowering/optimizer scratch arena is
;; dropped and after every intern floor reset, so the slots, the map and the
;; copies of the spellings live in a dedicated arena created once that only
;; grows.
(define compiler-ir-symbol-arena-handle : i64
  0)

(define (compiler-ir-symbol-arena-handle-value) : i64
  compiler-ir-symbol-arena-handle)

(define (compiler-ir-symbol-arena) : i64
  (if (= compiler-ir-symbol-arena-handle 0)
    (set! compiler-ir-symbol-arena-handle (arena.tl_arena_make))
    unit)
  compiler-ir-symbol-arena-handle)

(define (compiler-ir-symbol-seed!) : unit
  (if compiler-ir-symbol-seeded
    unit
    (let
      [previous-arena : i64 (arena.tl_arena_current)]
      (unsafe
        (arena.tl_arena_set (compiler-ir-symbol-arena)))
      (set! compiler-ir-symbol-slots (__tl_make-array String 1024))
      (set! compiler-ir-symbol-ids (ir_label_map.with-capacity 2048))
      (set! compiler-ir-symbol-count 0)
      (set! compiler-ir-symbol-seeded true)
      (unsafe
        (arena.tl_arena_set previous-arena)))))

(define (compiler-ir-symbol [name : String]) : i64
  (compiler-ir-symbol-seed!)
  (compiler-ir-symbol-lookup name))

;; Resolution order, and the reason for it: this table's own answer first, so a
;; spelling it has already answered for never changes id; then the intern pool's
;; canonical generated namespace, so a spelling that namespace already owns --
;; every runtime and builtin name, minted at parse start, and every string
;; literal -- keeps the id the rest of the compiler compares against; only then
;; a fresh id of this table's own. Deferring is not memoized: the pool is
;; re-seeded on every intern reset, and the probe re-reads whatever the live
;; pool says.
(define (compiler-ir-symbol-lookup [name : String]) : i64
  (match (ir_label_map.get
    (& compiler-ir-symbol-ids)
    (compiler-ir-global-shared-view name))
    [(LookupFound id) id]
    [(LookupMissing)
      (let
        [pooled : i64
          (ci.intern-generated-canonical-name-existing
            (compiler-ir-global-shared-view name))]
        (if (>= pooled 0)
          pooled
          (compiler-ir-symbol-mint! name)))]))

(define (compiler-ir-symbol-mint! [name : String]) : i64
  (let
    [index : i64 compiler-ir-symbol-count]
    [id : i64 (compiler-ir-symbol-domain-id-for-index index)]
    [previous-arena : i64 (arena.tl_arena_current)]
    (unsafe
      (arena.tl_arena_set (compiler-ir-symbol-arena)))
    (if (< index (array-length compiler-ir-symbol-slots))
      unit
      (compiler-ir-symbol-grow!))
    (let
      [owned : String (string.copy (& name))]
      (set! (array-ref compiler-ir-symbol-slots index) owned)
      (ir_label_map.insert-ref!
        (&mut compiler-ir-symbol-ids)
        (string.copy (& (array-ref compiler-ir-symbol-slots index)))
        id))
    (set! compiler-ir-symbol-count (+ index 1))
    (unsafe
      (arena.tl_arena_set previous-arena))
    id))

;: Number of distinct derived symbols interned so far. Dense indices cover
;: [0, count), so a side table indexed by derived symbol needs this many slots.
(define (compiler-ir-symbol-count-value) : i64
  compiler-ir-symbol-count)

;: True for the ids this table minted, and only those. Domain membership alone
;: is insufficient: the unallocated payload tail must never index the table.
(define (compiler-ir-symbol-owned? [symbol : i64]) : bool
  (and
    (compiler-ir-symbol-domain? symbol)
    (< (compiler-ir-symbol-slot-unchecked symbol) compiler-ir-symbol-count)))

(defenum CompilerIrValue
  (Var i64)
  (Global i64)
  (GlobalAddr i64)
  (Function i64)
  (I64 i64)
  (F64 u64)
  (Bool bool)
  (Char char)
  (String String)
  (Bytes String)
  ;; Runtime-initialized globals name their hidden initializer explicitly.
  (RuntimeGlobal i64)
  (Unit)
  ;; A global initializer only: a fixed array of constant scalars as its exact
  ;; little-endian element bytes, laid out as `array-ref` addresses them. The
  ;; global's cell points at its own writable copy of the bytes; the element
  ;; type and count are the global's declared `(Array T N)` (#8369).
  (StaticArray String))

(defenum CompilerIrMaybeValue
  (No)
  (Some CompilerIrValue))

(defstruct CompilerIrValueSeq
  (slots (__tl_dyn-array CompilerIrValue))
  (len i64))

(defenum CompilerIrCallArgs
  (Nil)
  (One CompilerIrValue)
  (Two CompilerIrValue CompilerIrValue)
  (Array (__tl_dyn-array CompilerIrValue))
  ;; The indexed argument is a call-scoped output borrow, not an escaping
  ;; ordinary pointer. Its storage is also aliased by the call result.
  (Sret (__tl_dyn-array CompilerIrValue) i64))

(defenum CompilerIrSpmdBackend
  (Scalar)
  (Avx2)
  (Avx512))

(defenum CompilerIrSpmdValueClass
  (Uniform)
  (Varying)
  (Mask))

(defenum CompilerIrSpmdCallArg
  (Arg CompilerIrSpmdValueClass CompilerIrValue ast.AstType))

(defstruct CompilerIrSpmdCallArgSeq
  (slots (__tl_dyn-array CompilerIrSpmdCallArg))
  (len i64))

(defstruct CompilerIrSpmdCallArgBuilder
  (slots (__tl_dyn-array CompilerIrSpmdCallArg))
  (len i64))

;; Storage and sequence constructors for the macro templates in this file. A
;; template names nothing of this module by type: a module-qualified type
;; (`compiler_ir_types.CompilerIrValueSeq`) does not resolve when this module
;; is the compilation root, and an unqualified one does not resolve where the
;; macro expands in another module.
(define (compiler-ir-value-storage [count : i64]) : (__tl_dyn-array
    CompilerIrValue)
  (__tl_make-array CompilerIrValue count))

(define (compiler-ir-spmd-call-arg-storage [count : i64]) : (__tl_dyn-array
    CompilerIrSpmdCallArg)
  (__tl_make-array CompilerIrSpmdCallArg count))

(define (compiler-ir-phi-input-storage [count : i64]) : (__tl_dyn-array
    CompilerIrPhiInput)
  (__tl_make-array CompilerIrPhiInput count))

(define (compiler-ir-switch-case-storage [count : i64]) : (__tl_dyn-array
    CompilerIrSwitchCase)
  (__tl_make-array CompilerIrSwitchCase count))

(define (compiler-ir-c-abi-return-slot-storage [count : i64]) : (__tl_dyn-array
    CompilerIrCAbiReturnSlot)
  (__tl_make-array CompilerIrCAbiReturnSlot count))

(define (compiler-ir-value-seq-of
  [slots : (__tl_dyn-array CompilerIrValue)]
  [len : i64]) : CompilerIrValueSeq
  (CompilerIrValueSeq slots len))

(define (compiler-ir-spmd-call-arg-seq-of
  [slots : (__tl_dyn-array CompilerIrSpmdCallArg)]
  [len : i64]) : CompilerIrSpmdCallArgSeq
  (CompilerIrSpmdCallArgSeq slots len))

(define (compiler-ir-switch-case-seq-of
  [slots : (__tl_dyn-array CompilerIrSwitchCase)]
  [len : i64]) : CompilerIrSwitchCaseSeq
  (CompilerIrSwitchCaseSeq slots len))

(define (compiler-ir-c-abi-return-slot-seq-of
  [slots : (__tl_dyn-array CompilerIrCAbiReturnSlot)]
  [len : i64]) : CompilerIrCAbiReturnSlotSeq
  (CompilerIrCAbiReturnSlotSeq slots len))

(define (compiler-ir-phi-input-seq-of
  [slots : (__tl_dyn-array CompilerIrPhiInput)]
  [start : i64]
  [len : i64]) : CompilerIrPhiInputSeq
  (CompilerIrPhiInputSeq slots start len))

(define (compiler-ir-phi-input-of [value : CompilerIrValue] [label : i64]) : CompilerIrPhiInput
  (CompilerIrPhiInput value label))

;; Shape-preserving call-operand traversal belongs to the IR representation.
;; These macros emit direct calls to a pass-owned value mapper/visitor, avoiding
;; a capturing closure or an indirect call per operand. Extra context
;; expressions are passed before the visited value. Compact call-argument
;; forms remain compact; Array and Sret allocate only replacement storage.
;; Sret mapping preserves the call-scoped hidden return argument index.
;; Representation-sensitive operations intentionally stay explicit: positional
;; lookup/ABI indexing, lockstep comparison, first-error or first-hit traversal,
;; shape conversion, and folds that thread persistent owners. Using this visit
;; boundary for those would discard an index/early exit or need a separate
;; contract for transferring the accumulator owner between callbacks.
(defmacro (compiler-ir-value-seq-map
  [values : Expr]
  [mapper : Expr]
  [contexts : Expr ...]) : CompilerIrValueSeq
  `(let
    [value-seq ,values]
    [count : i64 value-seq.len]
    [source value-seq.slots]
    [out (compiler-ir-value-storage count)]
    [index : i64 0]
    (while (< index count)
      (set!
        (array-ref out index)
        (,mapper
          ,@contexts
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data source) index)))))
      (set! index (+ index 1)))
    (compiler-ir-value-seq-of out count)))

(defmacro (compiler-ir-value-seq-visit
  [values : Expr]
  [visitor : Expr]
  [contexts : Expr ...]) : unit
  `(let
    [value-seq ,values]
    [count : i64 value-seq.len]
    [source value-seq.slots]
    [index : i64 0]
    (while (< index count)
      (,visitor
        ,@contexts
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data source) index))))
      (set! index (+ index 1)))))

(defmacro (compiler-ir-call-args-map
  [args : Expr]
  [mapper : Expr]
  [contexts : Expr ...]) : CompilerIrCallArgs
  `(let
    [call-args ,args]
    (match call-args
      [(compiler_ir_types.CompilerIrCallArgs.Nil)
        (compiler_ir_types.CompilerIrCallArgs.Nil)]
      [(compiler_ir_types.CompilerIrCallArgs.One value)
        (compiler_ir_types.CompilerIrCallArgs.One (,mapper ,@contexts value))]
      [(compiler_ir_types.CompilerIrCallArgs.Two a b)
        (compiler_ir_types.CompilerIrCallArgs.Two
          (,mapper ,@contexts a)
          (,mapper ,@contexts b))]
      [(compiler_ir_types.CompilerIrCallArgs.Array values)
        (let
          [count : i64 (array-length values)]
          [out (compiler-ir-value-storage count)]
          [index : i64 0]
          (while (< index count)
            (set!
              (array-ref out index)
              (,mapper
                ,@contexts
                (unsafe
                  (ptr-read (ptr-offset (__tl_array-data values) index)))))
            (set! index (+ index 1)))
          (compiler_ir_types.CompilerIrCallArgs.Array out))]
      [(compiler_ir_types.CompilerIrCallArgs.Sret values sret-index)
        (let
          [count : i64 (array-length values)]
          [out (compiler-ir-value-storage count)]
          [index : i64 0]
          (while (< index count)
            (set!
              (array-ref out index)
              (,mapper
                ,@contexts
                (unsafe
                  (ptr-read (ptr-offset (__tl_array-data values) index)))))
            (set! index (+ index 1)))
          (compiler_ir_types.CompilerIrCallArgs.Sret out sret-index))])))

(defmacro (compiler-ir-call-args-visit
  [args : Expr]
  [visitor : Expr]
  [contexts : Expr ...]) : unit
  `(let
    [call-args ,args]
    (match call-args
      [(compiler_ir_types.CompilerIrCallArgs.Nil) unit]
      [(compiler_ir_types.CompilerIrCallArgs.One value)
        (,visitor ,@contexts value)]
      [(compiler_ir_types.CompilerIrCallArgs.Two a b)
        (,visitor ,@contexts a)
        (,visitor ,@contexts b)]
      [(compiler_ir_types.CompilerIrCallArgs.Array values)
        (let
          [count : i64 (array-length values)]
          [index : i64 0]
          (while (< index count)
            (,visitor
              ,@contexts
              (unsafe
                (ptr-read (ptr-offset (__tl_array-data values) index))))
            (set! index (+ index 1))))]
      [(compiler_ir_types.CompilerIrCallArgs.Sret values _)
        (let
          [count : i64 (array-length values)]
          [index : i64 0]
          (while (< index count)
            (,visitor
              ,@contexts
              (unsafe
                (ptr-read (ptr-offset (__tl_array-data values) index))))
            (set! index (+ index 1))))])))

;; SPMD mapping changes only each value. The IR-owned mechanics preserve the
;; value class and type metadata, visit exactly logical [0, len), and allocate
;; one exact-size result array. The mapper and visitor receive extra contexts
;; followed by class and value.
(defmacro (compiler-ir-spmd-call-args-map
  [args : Expr]
  [mapper : Expr]
  [contexts : Expr ...]) : CompilerIrSpmdCallArgSeq
  `(let
    [spmd-args ,args]
    [count : i64 spmd-args.len]
    [source spmd-args.slots]
    [out (compiler-ir-spmd-call-arg-storage count)]
    [index : i64 0]
    (while (< index count)
      (match (unsafe
        (ptr-read (ptr-offset (__tl_array-data source) index)))
        [(compiler_ir_types.CompilerIrSpmdCallArg.Arg class value ty)
          (set!
            (array-ref out index)
            (compiler_ir_types.CompilerIrSpmdCallArg.Arg
              class
              (,mapper ,@contexts class value)
              ty))])
      (set! index (+ index 1)))
    (compiler-ir-spmd-call-arg-seq-of out count)))

(defmacro (compiler-ir-spmd-call-args-visit
  [args : Expr]
  [visitor : Expr]
  [contexts : Expr ...]) : unit
  `(let
    [spmd-args ,args]
    [count : i64 spmd-args.len]
    [source spmd-args.slots]
    [index : i64 0]
    (while (< index count)
      (match (unsafe
        (ptr-read (ptr-offset (__tl_array-data source) index)))
        [(compiler_ir_types.CompilerIrSpmdCallArg.Arg class value _)
          (,visitor ,@contexts class value)])
      (set! index (+ index 1)))))

(defenum CompilerIrSpmdCallResult
  (Unit)
  (Value i64 CompilerIrSpmdValueClass ast.AstType))

(defenum CompilerIrCAbiReturnSlot
  (Slot ast.AstType i64))

(defstruct CompilerIrCAbiReturnSlotSeq
  (slots (__tl_dyn-array CompilerIrCAbiReturnSlot))
  (len i64))

(defstruct CompilerIrPhiInput
  (value CompilerIrValue)
  (label i64))

(defstruct CompilerIrPhiInputSeq
  (slots (__tl_dyn-array CompilerIrPhiInput))
  (start i64)
  (len i64))

(defenum CompilerIrSwitchCase
  (Case i64 i64))

(defstruct CompilerIrSwitchCaseSeq
  (slots (__tl_dyn-array CompilerIrSwitchCase))
  (len i64))

(defstruct CompilerIrSwitchCaseBuilder
  (slots (__tl_dyn-array CompilerIrSwitchCase))
  (len i64))

(defstruct CompilerIrInstrVectorBinOpPayload
  (dst i64)
  (op CompilerIrBinOp)
  (lhs CompilerIrValue)
  (rhs CompilerIrValue)
  (lanes i64)
  (ty ast.AstType))

(defstruct CompilerIrInstrVectorPrefixPayload
  (dst i64)
  (op CompilerIrVectorPrefixOp)
  (src CompilerIrValue)
  (carry CompilerIrValue)
  (lanes i64)
  (ty ast.AstType))

(defstruct CompilerIrInstrVectorComparePayload
  (dst i64)
  (op CompilerIrBinOp)
  (lhs CompilerIrValue)
  (rhs CompilerIrValue)
  (lanes i64)
  (ty ast.AstType))

(defstruct CompilerIrInstrSelectPayload
  (dst i64)
  (mask CompilerIrValue)
  (on-true CompilerIrValue)
  (on-false CompilerIrValue)
  (lanes i64)
  (ty ast.AstType))

(defstruct CompilerIrInstrVectorStorePayload
  (base CompilerIrValue)
  (index CompilerIrValue)
  (value CompilerIrValue)
  (lanes i64)
  (ty ast.AstType))

(defstruct CompilerIrInstrPredicatedStorePayload
  (base CompilerIrValue)
  (index CompilerIrValue)
  (value CompilerIrValue)
  (mask CompilerIrValue)
  (lanes i64)
  (ty ast.AstType))

(defstruct CompilerIrInstrPredicatedLoadPayload
  (dst i64)
  (base CompilerIrValue)
  (index CompilerIrValue)
  (mask CompilerIrValue)
  (lanes i64)
  (ty ast.AstType))

;; A checked SPMD gather. The lowering has already validated every logical
;; index, in lane order, before this instruction is emitted. Direct indexes
;; load a contiguous i64 vector from `index-base` starting at `index`. When
;; `lane-offset` is true, the loaded values are offsets and the backend adds
;; the logical foreach lanes starting at `index`. `base` is the gathered
;; element data pointer.
(defstruct CompilerIrInstrGatherLoadPayload
  (dst i64)
  (base CompilerIrValue)
  (index-base CompilerIrValue)
  (index CompilerIrValue)
  (lane-offset bool)
  (lanes i64)
  (ty ast.AstType))

;; A checked intra-gang permutation. `selector-low` contains the first
;; min(lanes, selector vector width) i64 source-lane indexes and
;; `selector-high` contains the remaining indexes for 32-bit lane shapes.
;; The backend validates selectors for active destination lanes in logical
;; lane order before issuing the native permutation. `active-lanes` is the
;; current gang size, which is less than `lanes` for a tail gang.
(defstruct CompilerIrInstrVectorShufflePayload
  (dst i64)
  (source CompilerIrValue)
  (selector-low CompilerIrValue)
  (selector-high CompilerIrMaybeValue)
  (active-lanes CompilerIrValue)
  (lanes i64)
  (ty ast.AstType))

(defstruct CompilerIrInstrCallCAbiStoreResultPayload
  (base CompilerIrValue)
  (name i64)
  (args CompilerIrCallArgs)
  (slots CompilerIrCAbiReturnSlotSeq))

(defstruct CompilerIrInstrCallIndirectCAbiStoreResultPayload
  (base CompilerIrValue)
  (callee CompilerIrValue)
  (args CompilerIrCallArgs)
  (slots CompilerIrCAbiReturnSlotSeq))

;; The imported descriptor owns a snapshot of the selected, checked TLCI row;
;; none of its fields is a mapped-image address or loader registry handle.
(defstruct CompilerIrImportedSpmdCall
  (package-owner String)
  (package-version String)
  (canonical-helper String)
  (signature String)
  (abi String)
  (backend String)
  (lanes i64)
  (args String)
  (result String)
  (index-param i64)
  (link-symbol String))

;; Same-program private SPMD helper ABI (#7405). Lowering records these facts
;; once, when it builds a generated scalar, AVX2, or AVX-512 helper, and attaches
;; one structurally equal copy to the helper (`CompilerIrFunctionAbi.SpmdPrivate`)
;; and one to every same-program `SpmdCall` that targets it
;; (`CompilerIrSpmdCallOrigin.Private`). The record is immutable facts only: no
;; per-call values, source AST, loader or TLCI state, or backend placement. It
;; is versioned separately from the imported catalog's serialized
;; `spmd-call-v1` row, and consumers read roles from it instead of from
;; generated helper or parameter spellings.
(defenum CompilerIrSpmdPrivateAbiSchema
  (V1))

;; Role of one physical helper parameter. `Source` is declared source parameter
;; `ordinal`, with the value class and source type the caller's argument has;
;; the physical (register storage) type is recorded beside the role.
;; `IndexBase` is the hidden uniform i64 logical-index base appended when the
;; helper cannot recover the index from one of its varying source parameters.
(defenum CompilerIrSpmdPrivateParamRole
  (ActiveMask)
  (Source i64 CompilerIrSpmdValueClass ast.AstType)
  (IndexBase))

;; One physical parameter: its ordinal in the helper signature, role, and
;; physical type. A descriptor lists every physical parameter in signature
;; order, so the ordinal of slot `i` is `i`; it is stored so that order is
;; checked rather than assumed.
(defenum CompilerIrSpmdPrivateParam
  (Param i64 CompilerIrSpmdPrivateParamRole ast.AstType))

(defstruct CompilerIrSpmdPrivateParamSeq
  (slots (__tl_dyn-array CompilerIrSpmdPrivateParam))
  (len i64))

;; How the helper recovers its logical lane indexes. `ReuseSource` names the
;; varying source parameter (by source ordinal) whose lanes already are the
;; indexes; `Appended` names the physical ordinal of the `IndexBase`
;; parameter. Scalar helpers run one lane and never recover an index.
(defenum CompilerIrSpmdPrivateIndex
  (None)
  (ReuseSource i64)
  (Appended i64))

;; The helper result: its class and source type. `Mask` is a varying bool; a
;; uniform result is returned once, not per lane.
(defenum CompilerIrSpmdPrivateResult
  (Unit)
  (Value CompilerIrSpmdValueClass ast.AstType))

(defstruct CompilerIrSpmdPrivateAbi
  (schema CompilerIrSpmdPrivateAbiSchema)
  (callee i64)
  (backend CompilerIrSpmdBackend)
  (lanes i64)
  (params CompilerIrSpmdPrivateParamSeq)
  (index CompilerIrSpmdPrivateIndex)
  (result CompilerIrSpmdPrivateResult))

;; Every function states its calling convention. Only generated same-program
;; SPMD helpers use the private ABI; everything else is `Ordinary`.
(defenum CompilerIrFunctionAbi
  (Ordinary)
  (SpmdPrivate (Box CompilerIrSpmdPrivateAbi)))

(defenum CompilerIrSpmdCallOrigin
  (Private (Box CompilerIrSpmdPrivateAbi))
  (Imported (Box CompilerIrImportedSpmdCall)))

(defstruct CompilerIrInstrSpmdCallPayload
  (callee i64)
  (backend CompilerIrSpmdBackend)
  (lanes i64)
  (active-mask CompilerIrValue)
  (args CompilerIrSpmdCallArgSeq)
  (result CompilerIrSpmdCallResult)
  (origin CompilerIrSpmdCallOrigin))

;; Internal scalarized view of a source descriptor handle. This is deliberately
;; NOT an AstType: String and compatibility DynArray values remain one-word
;; pointers everywhere source types, layouts, and ABIs are classified. A value
;; created through this kind is instead seeded structurally by Pack/Word as a
;; two-GP-word register group: word0 is data_ptr and word1 is the nonnegative
;; length. Callers must materialize those words into descriptor storage before
;; crossing a source storage or ABI boundary.
(defenum CompilerIrDescriptorPairKind
  (OwnedString)
  (DynamicArray i64))

(defenum CompilerIrInstr
  (Mov i64 CompilerIrValue ast.AstType)
  (Alloc i64 ast.AstType)
  (AddrOf i64 i64)
  (Gep i64 CompilerIrValue CompilerIrValue ast.AstType)
  (Load i64 CompilerIrValue ast.AstType)
  ;; Checked non-Copy move into an owned aggregate field/path. This is the
  ;; actual typed store, not a second proof-only record; raw/unsafe writes use
  ;; StorePtr and cannot establish an ownership edge.
  (StoreOwned CompilerIrValue CompilerIrValue ast.AstType)
  (StorePtr CompilerIrValue CompilerIrValue ast.AstType)
  (CopyBytes CompilerIrValue CompilerIrValue i64)
  (BoundsCheck CompilerIrValue CompilerIrValue i64)
  (Cast i64 CompilerIrValue ast.AstType ast.AstType)
  (Bitcast i64 CompilerIrValue ast.AstType ast.AstType)
  (BinOp i64 CompilerIrBinOp CompilerIrValue CompilerIrValue ast.AstType)
  (UnOp i64 CompilerIrUnOp CompilerIrValue ast.AstType)
  (LaneId i64 i64 ast.AstType)
  (Splat i64 CompilerIrValue i64 ast.AstType)
  (VectorBinOp (Box CompilerIrInstrVectorBinOpPayload))
  ;; Inclusive, carry-seeded lane prefix. For associative `op`, the result
  ;; lanes are `out[0] = op(carry, src[0])` and
  ;; `out[i] = op(out[i - 1], src[i])`.
  (VectorPrefix (Box CompilerIrInstrVectorPrefixPayload))
  (VectorReduce i64 CompilerIrVectorReduceOp CompilerIrValue i64 ast.AstType)
  (VectorCompare (Box CompilerIrInstrVectorComparePayload))
  (MaskBinOp i64 CompilerIrMaskBinOp CompilerIrValue CompilerIrValue i64)
  (MaskNot i64 CompilerIrValue i64)
  (MaskReduce i64 CompilerIrMaskReduceOp CompilerIrValue i64)
  (Select (Box CompilerIrInstrSelectPayload))
  (VectorLoad i64 CompilerIrValue CompilerIrValue i64 ast.AstType)
  (VectorStore (Box CompilerIrInstrVectorStorePayload))
  (PredicatedStore (Box CompilerIrInstrPredicatedStorePayload))
  (PredicatedLoad (Box CompilerIrInstrPredicatedLoadPayload))
  (GatherLoad (Box CompilerIrInstrGatherLoadPayload))
  (VectorShuffle (Box CompilerIrInstrVectorShufflePayload))
  (TailMask i64 CompilerIrValue CompilerIrValue i64)
  (EntryArgc i64)
  (EntryArgv i64)
  (EntryEnvp i64)
  (CpuId i64 CompilerIrValue CompilerIrValue i64)
  (Xgetbv i64 CompilerIrValue)
  ;; Raw Linux x86_64 syscall: dst var plus the operands (number then up to six
  ;; arguments) carried as call-args. Lowers to a `syscall` instruction.
  (Syscall i64 CompilerIrCallArgs)
  (Call i64 i64 CompilerIrCallArgs ast.AstType)
  (CallIndirect i64 CompilerIrValue CompilerIrCallArgs ast.AstType)
  (CallIndirectC i64 CompilerIrValue CompilerIrCallArgs ast.AstType)
  ;; System V C aggregate returns can arrive in two ABI result registers. These
  ;; instructions emit the call and immediately store those result slots into the
  ;; provided aggregate buffer, preserving the classifier's slot offsets.
  (CallCAbiStoreResult (Box CompilerIrInstrCallCAbiStoreResultPayload))
  (CallIndirectCAbiStoreResult
    (Box CompilerIrInstrCallIndirectCAbiStoreResultPayload))
  (SpmdCall (Box CompilerIrInstrSpmdCallPayload))
  (TailCall i64 CompilerIrCallArgs ast.AstType)
  (Store i64 CompilerIrValue ast.AstType)
  (Jump i64)
  (Branch CompilerIrValue i64 i64)
  ;; A compare-chain edge produced only for an exhaustive enum match that is
  ;; eligible for dense switch formation.  It renders and executes exactly
  ;; like Branch; the distinct variant is the proof carried into the switch
  ;; former without recovering semantics from a label spelling.
  (TotalEnumBranch CompilerIrValue i64 i64)
  (Return CompilerIrMaybeValue)
  (Phi i64 CompilerIrPhiInputSeq ast.AstType)
  ;; Multi-word register groups. A small (<=16 B) inline struct/enum whose fields
  ;; are all word-class can live in N general-purpose registers (N =
  ;; ceil(size/8)). The internal descriptor-pair capability above also uses a
  ;; two-word group while retaining its source handle type solely as provenance;
  ;; structural Pack/Word use, not source-type classification, marks that value
  ;; as a group. Pack forms `dst` from low word first and Word extracts `index`.
  ;; The allocator gives a group N adjacent homes (or an N*8-byte spill slot),
  ;; and the backend lowers the operations as register/slot word moves.
  (Pack i64 CompilerIrValueSeq ast.AstType)
  (Word i64 CompilerIrValue i64 ast.AstType)
  (TailCallIndirect CompilerIrValue CompilerIrCallArgs ast.AstType)
  (Switch CompilerIrValue i64 CompilerIrSwitchCaseSeq i64)
  ;; `trap-label = compiler-ir-label-none` is the optimizer's pending
  ;; exhaustive-enum proof.  The late total-switch pass materializes the final
  ;; enum case and abort block, then stores that block's explicit label here.
  ;; The ordinary default edge may subsequently point through a jump-only
  ;; preheader; backends never infer this proof from rendered label text.
  (TotalEnumSwitch CompilerIrValue i64 CompilerIrSwitchCaseSeq i64 i64))

(define (compiler-ir-descriptor-pair-handle-type
  [kind : CompilerIrDescriptorPairKind]) : ast.AstType
  (match kind
    [(OwnedString) (String)]
    [(DynamicArray elem) (DynArray elem)]))

(define (ir-instr-descriptor-pair-pack
  [dst : i64]
  [data : CompilerIrValue]
  [length : CompilerIrValue]
  [kind : CompilerIrDescriptorPairKind]) : CompilerIrInstr
  (Pack
    dst
    (compiler-ir-value-seq2 data length)
    (compiler-ir-descriptor-pair-handle-type kind)))

(define (ir-instr-descriptor-pair-data [dst : i64] [pair : CompilerIrValue]) : CompilerIrInstr
  (Word dst pair 0 (U64)))

(define (ir-instr-descriptor-pair-length [dst : i64] [pair : CompilerIrValue]) : CompilerIrInstr
  (Word dst pair 1 (I64)))

(define (ir-instr-vector-bin-op
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (VectorBinOp
    (box (CompilerIrInstrVectorBinOpPayload dst op lhs rhs lanes ty))))

(define (ir-instr-vector-prefix
  [dst : i64]
  [op : CompilerIrVectorPrefixOp]
  [src : CompilerIrValue]
  [carry : CompilerIrValue]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (VectorPrefix
    (box (CompilerIrInstrVectorPrefixPayload dst op src carry lanes ty))))

(define (ir-instr-vector-compare
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (VectorCompare
    (box (CompilerIrInstrVectorComparePayload dst op lhs rhs lanes ty))))

(define (ir-instr-select
  [dst : i64]
  [mask : CompilerIrValue]
  [on-true : CompilerIrValue]
  [on-false : CompilerIrValue]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (Select
    (box (CompilerIrInstrSelectPayload dst mask on-true on-false lanes ty))))

(define (ir-instr-vector-store
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (VectorStore
    (box (CompilerIrInstrVectorStorePayload base index value lanes ty))))

(define (ir-instr-predicated-store
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (PredicatedStore
    (box (CompilerIrInstrPredicatedStorePayload base index value mask lanes ty))))

(define (ir-instr-predicated-load
  [dst : i64]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (PredicatedLoad
    (box (CompilerIrInstrPredicatedLoadPayload dst base index mask lanes ty))))

(define (ir-instr-gather-load
  [dst : i64]
  [base : CompilerIrValue]
  [index-base : CompilerIrValue]
  [index : CompilerIrValue]
  [lane-offset : bool]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (GatherLoad
    (box
      (CompilerIrInstrGatherLoadPayload
        dst
        base
        index-base
        index
        lane-offset
        lanes
        ty))))

(define (ir-instr-vector-shuffle
  [dst : i64]
  [source : CompilerIrValue]
  [selector-low : CompilerIrValue]
  [selector-high : CompilerIrMaybeValue]
  [active-lanes : CompilerIrValue]
  [lanes : i64]
  [ty : ast.AstType]) : CompilerIrInstr
  (VectorShuffle
    (box
      (CompilerIrInstrVectorShufflePayload
        dst
        source
        selector-low
        selector-high
        active-lanes
        lanes
        ty))))

(define (ir-instr-call-cabi-store-result
  [base : CompilerIrValue]
  [name : i64]
  [args : CompilerIrCallArgs]
  [slots : CompilerIrCAbiReturnSlotSeq]) : CompilerIrInstr
  (CallCAbiStoreResult
    (box (CompilerIrInstrCallCAbiStoreResultPayload base name args slots))))

(define (ir-instr-call-indirect-cabi-store-result
  [base : CompilerIrValue]
  [callee : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [slots : CompilerIrCAbiReturnSlotSeq]) : CompilerIrInstr
  (CallIndirectCAbiStoreResult
    (box
      (CompilerIrInstrCallIndirectCAbiStoreResultPayload base callee args slots))))

(define (compiler-ir-spmd-call-arg-seq-empty) : CompilerIrSpmdCallArgSeq
  (CompilerIrSpmdCallArgSeq (__tl_make-array CompilerIrSpmdCallArg 0) 0))

(define (compiler-ir-spmd-call-arg-seq2
  [a : CompilerIrSpmdCallArg]
  [b : CompilerIrSpmdCallArg]) : CompilerIrSpmdCallArgSeq
  (let
    [slots : (__tl_dyn-array CompilerIrSpmdCallArg)
      (__tl_make-array CompilerIrSpmdCallArg 2)]
    (set! (array-ref slots 0) a)
    (set! (array-ref slots 1) b)
    (CompilerIrSpmdCallArgSeq slots 2)))

;; The growable `{slots, len}` builders behind the IR sequences share one
;; implementation. `(compiler-ir-dense-builder T Builder Seq prefix to-seq
;; snapshot)` declares, for a builder struct over element type `T`:
;;   prefix-with-capacity  at least one slot (compiler-ir-builder-capacity)
;;   prefix-copy-range!    copy the first `count` slots
;;   prefix-grow!          double the storage, one slot from empty
;;   prefix-push!          append one element
;; and, by the bare-name options:
;;   to-seq    `share`: prefix-to-seq hands the builder's storage to `Seq`;
;;             `exact`: it reuses the storage only when full and otherwise
;;             copies into exact-size storage; `exact-offset` is `exact` for a
;;             `Seq` with a `start` field (set to 0); `_` declares none.
;;   snapshot  `snapshot` or `snapshot-seq` declares prefix-<name>, an
;;             exact-size copy of the live prefix that leaves the builder
;;             usable; `_` declares none.
;; Reads through the resulting sequences stay the unchecked
;; compiler-ir-array-shared-view accessors each family defines.
(defmacro (compiler-ir-dense-builder
  [T : type (:kind struct enum)]
  [builder-type : type (:kind struct)]
  [seq-type : type (:kind struct)]
  [prefix : Expr]
  [to-seq : Expr]
  [snapshot : Expr]) : Decls
  (let
    [prefix-text : String
      (match prefix
        [(Expr.Var value) value]
        [_
          (comptime-error
            "compiler-ir-dense-builder: prefix must be a bare name")])]
    [to-seq-shape : String
      (match to-seq
        [(Expr.Var value) value]
        [_
          (comptime-error
            "compiler-ir-dense-builder: to-seq must be a bare name")])]
    [snapshot-suffix : String
      (match snapshot
        [(Expr.Var value) value]
        [_
          (comptime-error
            "compiler-ir-dense-builder: snapshot must be a bare name")])]
    [builder : Expr (comptime.expr-var (type-nominal-name builder-type))]
    [seq : Expr (comptime.expr-var (type-nominal-name seq-type))]
    [with-capacity-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-with-capacity"))]
    [copy-range-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-copy-range!"))]
    [grow-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-grow!"))]
    [push-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-push!"))]
    [to-seq-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-to-seq"))]
    [snapshot-name : Expr
      (comptime.expr-var
        (comptime.string-append
          (comptime.string-append prefix-text "-")
          snapshot-suffix))]
    [offset? : bool
      (match to-seq-shape
        ["exact-offset" true]
        [_ false])]
    [seq-of-builder : Expr
      (if offset?
        `(,seq builder.slots 0 builder.len)
        `(,seq builder.slots builder.len))]
    [seq-of-slots : Expr
      (if offset?
        `(,seq slots 0 builder.len)
        `(,seq slots builder.len))]
    [exact-copy : Expr
      `(let
        [slots : (__tl_dyn-array ,T) (__tl_make-array ,T builder.len)]
        (,copy-range-name (&mut slots) (& builder.slots) builder.len)
        ,seq-of-slots)]
    [to-seq-decls : ExprList
      (match to-seq-shape
        ["share"
          (match `(begin
            (define (,to-seq-name [builder : ,builder-type]) : ,seq-type
              ,seq-of-builder))
            [(Expr.Begin decls) decls]
            [_ (expr-list-empty)])]
        ["_" (expr-list-empty)]
        [_
          (match `(begin
            (define (,to-seq-name [builder : ,builder-type]) : ,seq-type
              (if (= builder.len (array-length builder.slots))
                ,seq-of-builder
                ,exact-copy)))
            [(Expr.Begin decls) decls]
            [_ (expr-list-empty)])])]
    [snapshot-decls : ExprList
      (match snapshot-suffix
        ["_" (expr-list-empty)]
        [_
          (match `(begin
            (define (,snapshot-name [builder : (& builder ,builder-type)]) : ,seq-type
              ,exact-copy))
            [(Expr.Begin decls) decls]
            [_ (expr-list-empty)])])]
    `(begin
      (define (,with-capacity-name [capacity : i64]) : ,builder-type
        (,builder
          (__tl_make-array ,T (compiler-ir-builder-capacity capacity))
          0))
      (define (,copy-range-name
        [dst : (&mut dst (__tl_dyn-array ,T))]
        [src : (& src (__tl_dyn-array ,T))]
        [count : i64]) : unit
        (let
          [index : i64 0]
          (while (< index count)
            (set! (array-ref dst index) (array-ref src index))
            (set! index (+ index 1)))))
      (define (,grow-name [builder : (&mut builder ,builder-type)]) : unit
        (let
          [old-cap : i64 (array-length builder.slots)]
          [new-cap : i64
            (if (< old-cap 1)
              1
              (* old-cap 2))]
          [bigger : (__tl_dyn-array ,T) (__tl_make-array ,T new-cap)]
          (,copy-range-name (&mut bigger) (& builder.slots) builder.len)
          (set! builder.slots bigger)))
      (define (,push-name [builder : (&mut builder ,builder-type)] [item : ,T]) : unit
        (if (< builder.len (array-length builder.slots))
          unit
          (,grow-name builder))
        (let
          [index : i64 builder.len]
          (set! (array-ref builder.slots index) item)
          (set! builder.len (+ index 1))))
      ,@to-seq-decls
      ,@snapshot-decls)))

(compiler-ir-dense-builder
  CompilerIrSpmdCallArg
  CompilerIrSpmdCallArgBuilder
  CompilerIrSpmdCallArgSeq
  compiler-ir-spmd-call-arg-builder
  exact
  snapshot)

(define (compiler-ir-spmd-call-arg-seq-append
  [args : CompilerIrSpmdCallArgSeq]
  [extra : CompilerIrSpmdCallArg]) : CompilerIrSpmdCallArgSeq
  (let
    [slots : (__tl_dyn-array CompilerIrSpmdCallArg)
      (__tl_make-array CompilerIrSpmdCallArg (+ args.len 1))]
    (compiler-ir-spmd-call-arg-builder-copy-range!
      (&mut slots)
      (& args.slots)
      args.len)
    (set! (array-ref slots args.len) extra)
    (CompilerIrSpmdCallArgSeq slots (+ args.len 1))))

(define (ir-instr-spmd-call-with-origin
  [callee : i64]
  [backend : CompilerIrSpmdBackend]
  [lanes : i64]
  [active-mask : CompilerIrValue]
  [args : CompilerIrSpmdCallArgSeq]
  [result : CompilerIrSpmdCallResult]
  [origin : CompilerIrSpmdCallOrigin]) : CompilerIrInstr
  (SpmdCall
    (box
      (CompilerIrInstrSpmdCallPayload
        callee
        backend
        lanes
        active-mask
        args
        result
        origin))))

;; --- instruction operand API ------------------------------------------------
;;
;; One classification of every CompilerIrInstr operand, shared by the passes
;; that walk instructions generically. Each operand has one kind:
;;
;;   def    the var the instruction defines (`compiler-ir-instr-dst`); the
;;          SPMD call result var included.
;;   use    a CompilerIrValue operand, reported with a CompilerIrOperandRole.
;;          Call arguments, Pack words, SPMD call arguments, Return and
;;          VectorShuffle maybe-values and phi inputs are uses, visited in
;;          constructor order.
;;   type   an ast.AstType field: instruction types, SPMD argument/result types
;;          and C-ABI return-slot types.
;;   label  a block label: jump, branch and switch targets, a present
;;          TotalEnumSwitch trap label, the BoundsCheck success label and phi
;;          predecessor labels.
;;   slot   a raw var id that is neither a def nor a value use: AddrOf's
;;          storage var. No operand macro reads or rewrites a slot; a pass
;;          that treats one as a read (liveness) or renames it (var
;;          renumbering) matches AddrOf first.
;;   fixed  everything else is copied unchanged: ops, lane counts, sizes,
;;          symbols (callees, Store names), switch bases, the SPMD backend and
;;          origin descriptor.
;;
;; Pack words are uses: the backend reads every word of a register group, and
;; liveness already counts them. Most of the optimizer's program-summary
;; scanners skip them today, a possible gap in their address-taken facts that
;; adopting this classification closes.
;;
;; A pass that sees phi inputs as edge uses, reads a lanes-0 Select as scalar,
;; or otherwise departs from this table matches the variants it treats
;; specially first and falls through to a macro; the macros themselves have no
;; wildcard arm, so a new instruction does not compile until it is classified
;; here.
;;
;; The macros follow compiler-ir-call-args-map/visit: each expands at the call
;; site to one match with direct calls of a pass-owned mapper/visitor symbol,
;; extra context expressions first:
;;   (visitor ctx... role value)          (folder ctx... role acc value) -> acc
;;   (use-mapper ctx... role value) -> value
;;   (def-mapper ctx... dst) -> dst       (type-mapper ctx... ty) -> ty
;;   (label-mapper ctx... label) -> label (successor-visitor ctx... label)
;;   (value-eq ctx... a b) -> bool        (type-eq ctx... a b) -> bool
(defenum CompilerIrOperandRole
  ;; A one-lane value (stored values, indexes, carries, Pack words, returns).
  (Scalar)
  ;; An address the instruction reads, writes or calls through.
  (Address)
  ;; A lane vector. Select keeps its vector roles when `lanes` is 0.
  (Vector)
  ;; A lane mask, including an SPMD call's active mask.
  (Mask)
  ;; A call, syscall or uniform SPMD argument.
  (CallArg)
  ;; A phi input; it is read on the edge from its predecessor label.
  (PhiInput)
  ;; A branch condition or switch index.
  (Condition))

;; The macro templates below name roles through these functions. A
;; module-qualified nullary variant written in a template,
;; `(compiler_ir_types.CompilerIrOperandRole.Scalar)`, misresolves when this
;; module is the compilation root: the checker takes the first enum of the
;; module with a variant of that name (CompilerIrSpmdBackend.Scalar).
(define (compiler-ir-role-scalar) : CompilerIrOperandRole
  (Scalar))

(define (compiler-ir-role-address) : CompilerIrOperandRole
  (Address))

(define (compiler-ir-role-vector) : CompilerIrOperandRole
  (Vector))

(define (compiler-ir-role-mask) : CompilerIrOperandRole
  (Mask))

(define (compiler-ir-role-call-arg) : CompilerIrOperandRole
  (CallArg))

(define (compiler-ir-role-phi-input) : CompilerIrOperandRole
  (PhiInput))

(define (compiler-ir-role-condition) : CompilerIrOperandRole
  (Condition))

(define (compiler-ir-spmd-call-result-unit) : CompilerIrSpmdCallResult
  (Unit))

(define (compiler-ir-spmd-value-class-role [class : CompilerIrSpmdValueClass]) : CompilerIrOperandRole
  (match class
    [(Uniform) (CallArg)]
    [(Varying) (Vector)]
    [(Mask) (Mask)]))

;: The var `instr` defines, or -1. Var ids are nonnegative.
(define (compiler-ir-instr-dst [instr : (& instr CompilerIrInstr)]) : i64
  (match instr
    [(Mov dst _ _) (deref dst)]
    [(Alloc dst _) (deref dst)]
    [(AddrOf dst _) (deref dst)]
    [(Gep dst _ _ _) (deref dst)]
    [(Load dst _ _) (deref dst)]
    [(StoreOwned _ _ _) -1]
    [(StorePtr _ _ _) -1]
    [(CopyBytes _ _ _) -1]
    [(BoundsCheck _ _ _) -1]
    [(Cast dst _ _ _) (deref dst)]
    [(Bitcast dst _ _ _) (deref dst)]
    [(BinOp dst _ _ _ _) (deref dst)]
    [(UnOp dst _ _ _) (deref dst)]
    [(LaneId dst _ _) (deref dst)]
    [(Splat dst _ _ _) (deref dst)]
    [(VectorBinOp payload-box)
      (let
        [payload-box
          (owned_view.compiler-owned-reference-shared-view payload-box)]
        (compiler-ir-box-field-shared-view payload-box dst))]
    [(VectorPrefix payload-box)
      (let
        [payload-box
          (owned_view.compiler-owned-reference-shared-view payload-box)]
        (compiler-ir-box-field-shared-view payload-box dst))]
    [(VectorReduce dst _ _ _ _) (deref dst)]
    [(VectorCompare payload-box)
      (let
        [payload-box
          (owned_view.compiler-owned-reference-shared-view payload-box)]
        (compiler-ir-box-field-shared-view payload-box dst))]
    [(MaskBinOp dst _ _ _ _) (deref dst)]
    [(MaskNot dst _ _) (deref dst)]
    [(MaskReduce dst _ _ _) (deref dst)]
    [(Select payload-box)
      (let
        [payload-box
          (owned_view.compiler-owned-reference-shared-view payload-box)]
        (compiler-ir-box-field-shared-view payload-box dst))]
    [(VectorLoad dst _ _ _ _) (deref dst)]
    [(VectorStore _) -1]
    [(PredicatedStore _) -1]
    [(PredicatedLoad payload-box)
      (let
        [payload-box
          (owned_view.compiler-owned-reference-shared-view payload-box)]
        (compiler-ir-box-field-shared-view payload-box dst))]
    [(GatherLoad payload-box)
      (let
        [payload-box
          (owned_view.compiler-owned-reference-shared-view payload-box)]
        (compiler-ir-box-field-shared-view payload-box dst))]
    [(VectorShuffle payload-box)
      (let
        [payload-box
          (owned_view.compiler-owned-reference-shared-view payload-box)]
        (compiler-ir-box-field-shared-view payload-box dst))]
    [(TailMask dst _ _ _) (deref dst)]
    [(EntryArgc dst) (deref dst)]
    [(EntryArgv dst) (deref dst)]
    [(EntryEnvp dst) (deref dst)]
    [(CpuId dst _ _ _) (deref dst)]
    [(Xgetbv dst _) (deref dst)]
    [(Syscall dst _) (deref dst)]
    [(Call dst _ _ _) (deref dst)]
    [(CallIndirect dst _ _ _) (deref dst)]
    [(CallIndirectC dst _ _ _) (deref dst)]
    [(CallCAbiStoreResult _) -1]
    [(CallIndirectCAbiStoreResult _) -1]
    [(SpmdCall payload-box)
      (match (let
        [payload-box
          (owned_view.compiler-owned-reference-shared-view payload-box)]
        (compiler-ir-box-field-shared-view payload-box result))
        [(Unit) -1]
        [(Value dst _ _) dst])]
    [(TailCall _ _ _) -1]
    [(Store _ _ _) -1]
    [(Jump _) -1]
    [(Branch _ _ _) -1]
    [(TotalEnumBranch _ _ _) -1]
    [(Return _) -1]
    [(Phi dst _ _) (deref dst)]
    [(Pack dst _ _) (deref dst)]
    [(Word dst _ _ _) (deref dst)]
    [(TailCallIndirect _ _ _) -1]
    [(Switch _ _ _ _) -1]
    [(TotalEnumSwitch _ _ _ _ _) -1]))

;: The value type the instruction states for its destination: the type field
;: of a scalar result (a Cast's target, a comparison's `bool`, an SPMD call's
;: result type, a lanes-0 Select's type). `No` for instructions without a
;: destination and for destinations that are addresses (Alloc, AddrOf, Gep),
;: lane vectors or masks, or untyped machine results (Entry*, CpuId, Xgetbv,
;: Syscall).
(define (compiler-ir-instr-dst-type [instr : CompilerIrInstr]) : ast.AstMaybeType
  (match instr
    [(Mov _ _ ty) (Some ty)]
    [(Alloc _ _) (No)]
    [(AddrOf _ _) (No)]
    [(Gep _ _ _ _) (No)]
    [(Load _ _ ty) (Some ty)]
    [(StoreOwned _ _ _) (No)]
    [(StorePtr _ _ _) (No)]
    [(CopyBytes _ _ _) (No)]
    [(BoundsCheck _ _ _) (No)]
    [(Cast _ _ _ to-ty) (Some to-ty)]
    [(Bitcast _ _ _ to-ty) (Some to-ty)]
    [(BinOp _ op _ _ ty) (Some (compiler-ir-binop-result-type op ty))]
    [(UnOp _ _ _ ty) (Some ty)]
    [(LaneId _ _ _) (No)]
    [(Splat _ _ _ _) (No)]
    [(VectorBinOp _) (No)]
    [(VectorPrefix _) (No)]
    [(VectorReduce _ _ _ _ ty) (Some ty)]
    [(VectorCompare _) (No)]
    [(MaskBinOp _ _ _ _ _) (No)]
    [(MaskNot _ _ _) (No)]
    [(MaskReduce _ _ _ _) (Some (Bool))]
    [(Select payload-box)
      (let
        [payload : CompilerIrInstrSelectPayload
          (compiler-ir-box-shared-view payload-box)]
        (if (= payload.lanes 0)
          (Some payload.ty)
          (No)))]
    [(VectorLoad _ _ _ _ _) (No)]
    [(VectorStore _) (No)]
    [(PredicatedStore _) (No)]
    [(PredicatedLoad _) (No)]
    [(GatherLoad _) (No)]
    [(VectorShuffle _) (No)]
    [(TailMask _ _ _ _) (No)]
    [(EntryArgc _) (No)]
    [(EntryArgv _) (No)]
    [(EntryEnvp _) (No)]
    [(CpuId _ _ _ _) (No)]
    [(Xgetbv _ _) (No)]
    [(Syscall _ _) (No)]
    [(Call _ _ _ ty) (Some ty)]
    [(CallIndirect _ _ _ ty) (Some ty)]
    [(CallIndirectC _ _ _ ty) (Some ty)]
    [(CallCAbiStoreResult _) (No)]
    [(CallIndirectCAbiStoreResult _) (No)]
    [(SpmdCall payload-box)
      (match (compiler-ir-box-field-shared-view payload-box result)
        [(Unit) (No)]
        [(Value _ _ ty) (Some ty)])]
    [(TailCall _ _ _) (No)]
    [(Store _ _ _) (No)]
    [(Jump _) (No)]
    [(Branch _ _ _) (No)]
    [(TotalEnumBranch _ _ _) (No)]
    [(Return _) (No)]
    [(Phi _ _ ty) (Some ty)]
    [(Pack _ _ ty) (Some ty)]
    [(Word _ _ _ ty) (Some ty)]
    [(TailCallIndirect _ _ _) (No)]
    [(Switch _ _ _ _) (No)]
    [(TotalEnumSwitch _ _ _ _ _) (No)]))

;; Folds beside compiler-ir-value-seq-visit and compiler-ir-call-args-visit:
;; `(folder ctx... acc value)` returns the next accumulator.
(defmacro (compiler-ir-value-seq-fold
  [values : Expr]
  [acc : Expr]
  [folder : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [fold-acc ,acc]
    [value-seq ,values]
    [source value-seq.slots]
    [index : i64 0]
    (while (< index value-seq.len)
      (set!
        fold-acc
        (,folder
          ,@contexts
          fold-acc
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data source) index)))))
      (set! index (+ index 1)))
    fold-acc))

(defmacro (compiler-ir-call-args-fold
  [args : Expr]
  [acc : Expr]
  [folder : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [fold-acc ,acc]
    (match ,args
      [(compiler_ir_types.CompilerIrCallArgs.Nil) unit]
      [(compiler_ir_types.CompilerIrCallArgs.One value)
        (set! fold-acc (,folder ,@contexts fold-acc value))]
      [(compiler_ir_types.CompilerIrCallArgs.Two a b)
        (set! fold-acc (,folder ,@contexts fold-acc a))
        (set! fold-acc (,folder ,@contexts fold-acc b))]
      [(compiler_ir_types.CompilerIrCallArgs.Array values)
        (set!
          fold-acc
          (compiler-ir-value-array-fold values fold-acc ,folder ,@contexts))]
      [(compiler_ir_types.CompilerIrCallArgs.Sret values _)
        (set!
          fold-acc
          (compiler-ir-value-array-fold values fold-acc ,folder ,@contexts))])
    fold-acc))

(defmacro (compiler-ir-value-array-fold
  [values : Expr]
  [acc : Expr]
  [folder : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [fold-acc ,acc]
    [source ,values]
    [count : i64 (array-length source)]
    [index : i64 0]
    (while (< index count)
      (set!
        fold-acc
        (,folder
          ,@contexts
          fold-acc
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data source) index)))))
      (set! index (+ index 1)))
    fold-acc))

;; Shared loop of the phi-input visit and fold. `acc` is `_` to visit, or the
;; accumulator variable to fold. With `role` `_` the callback receives the
;; value and label; with a role it receives the role and value (the operand
;; walk of compiler-ir-instr-fold-uses).
(defmacro (compiler-ir-phi-inputs-walk
  [inputs : Expr]
  [acc : Expr]
  [role : Expr]
  [f : Expr]
  [contexts : Expr ...]) : unit
  (let
    [visit? : bool
      (match acc
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [no-role? : bool
      (match role
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [step : Expr
      (if visit?
        (if no-role?
          `(,f ,@contexts input.value input.label)
          `(,f ,@contexts ,role input.value))
        (if no-role?
          `(set! ,acc (,f ,@contexts ,acc input.value input.label))
          `(set! ,acc (,f ,@contexts ,role ,acc input.value))))]
    `(let
      [phi-inputs ,inputs]
      [phi-slots phi-inputs.slots]
      [phi-index : i64 0]
      (while (< phi-index phi-inputs.len)
        (let
          [input
            (unsafe
              (ptr-read
                (ptr-offset
                  (__tl_array-data phi-slots)
                  (+ phi-inputs.start phi-index))))]
          ,step
          (set! phi-index (+ phi-index 1)))))))

;; phi-inputs-map with an optional operand role passed to the value mapper
;; before the value (`_` passes none).
(defmacro (compiler-ir-phi-inputs-rebuild
  [inputs : Expr]
  [value-mapper : Expr]
  [value-role : Expr]
  [label-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrPhiInputSeq
  (let
    [keep-values? : bool
      (match value-mapper
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [keep-labels? : bool
      (match label-mapper
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [no-role? : bool
      (match value-role
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [value-out : Expr
      (if keep-values?
        'input.value
        (if no-role?
          `(,value-mapper ,@contexts input.value)
          `(,value-mapper ,@contexts ,value-role input.value)))]
    [label-out : Expr
      (if keep-labels?
        'input.label
        `(,label-mapper ,@contexts input.label))]
    (if (if keep-values?
      keep-labels?
      false)
      inputs
      `(let
        [phi-inputs ,inputs]
        [phi-slots phi-inputs.slots]
        [phi-out (compiler-ir-phi-input-storage phi-inputs.len)]
        [phi-index : i64 0]
        (while (< phi-index phi-inputs.len)
          (let
            [input
              (unsafe
                (ptr-read
                  (ptr-offset
                    (__tl_array-data phi-slots)
                    (+ phi-inputs.start phi-index))))]
            (set!
              (array-ref phi-out phi-index)
              (compiler-ir-phi-input-of ,value-out ,label-out))
            (set! phi-index (+ phi-index 1))))
        (compiler-ir-phi-input-seq-of phi-out 0 phi-inputs.len)))))

;; Switch case target labels in case order: (visitor ctx... label).
(defmacro (compiler-ir-switch-cases-visit
  [cases : Expr]
  [visitor : Expr]
  [contexts : Expr ...]) : unit
  `(let
    [switch-cases ,cases]
    [case-slots switch-cases.slots]
    [case-index : i64 0]
    (while (< case-index switch-cases.len)
      (match (unsafe
        (ptr-read (ptr-offset (__tl_array-data case-slots) case-index)))
        [(compiler_ir_types.CompilerIrSwitchCase.Case _ case-label)
          (,visitor ,@contexts case-label)])
      (set! case-index (+ case-index 1)))))

;; Per-operand steps of the instruction macros below. `shape` is a bare name:
;; `value`, `maybe` (a CompilerIrMaybeValue), `values` (a CompilerIrValueSeq),
;; `args` (CompilerIrCallArgs), `spmd-args` or `phi-inputs` (whose roles come
;; from the SPMD value class and PhiInput; pass `_` as their role).
;; A use step visits `(f ctx... role value)`, or with an accumulator variable
;; `acc` (not `_`) folds `(set! acc (f ctx... role acc value))`.
(defmacro (compiler-ir-use-step
  [shape : Expr]
  [role : Expr]
  [operand : Expr]
  [acc : Expr]
  [f : Expr]
  [contexts : Expr ...]) : unit
  (let
    [visit? : bool
      (match acc
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [shape-name : String
      (match shape
        [(Expr.Var name) name]
        [_ (comptime-error "compiler-ir-use-step: shape must be a bare name")])]
    [value-step : Expr
      (if visit?
        `(,f ,@contexts ,role use-value)
        `(set! ,acc (,f ,@contexts ,role ,acc use-value)))]
    [spmd-step : Expr
      (if visit?
        `(,f ,@contexts (compiler-ir-spmd-value-class-role use-class) use-value)
        `(set!
          ,acc
          (,f
            ,@contexts
            (compiler-ir-spmd-value-class-role use-class)
            ,acc
            use-value)))]
    (match shape-name
      ["value"
        `(let
          [use-value ,operand]
          ,value-step)]
      ["maybe"
        `(match ,operand
          [(compiler_ir_types.CompilerIrMaybeValue.No) unit]
          [(compiler_ir_types.CompilerIrMaybeValue.Some use-value) ,value-step])]
      ["values"
        (if visit?
          `(compiler-ir-value-seq-visit ,operand ,f ,@contexts ,role)
          `(set!
            ,acc
            (compiler-ir-value-seq-fold ,operand ,acc ,f ,@contexts ,role)))]
      ["args"
        (if visit?
          `(compiler-ir-call-args-visit ,operand ,f ,@contexts ,role)
          `(set!
            ,acc
            (compiler-ir-call-args-fold ,operand ,acc ,f ,@contexts ,role)))]
      ["spmd-args"
        `(let
          [spmd-args ,operand]
          [spmd-slots spmd-args.slots]
          [spmd-index : i64 0]
          (while (< spmd-index spmd-args.len)
            (match (unsafe
              (ptr-read (ptr-offset (__tl_array-data spmd-slots) spmd-index)))
              [(compiler_ir_types.CompilerIrSpmdCallArg.Arg
                  use-class
                  use-value
                  _)
                ,spmd-step])
            (set! spmd-index (+ spmd-index 1))))]
      ["phi-inputs"
        `(compiler-ir-phi-inputs-walk
          ,operand
          ,acc
          (compiler-ir-role-phi-input)
          ,f
          ,@contexts)]
      [_ 'compiler-ir-unknown-operand-shape])))

;; A mapped use: `(mapper ctx... role value)` per value of the shape (`value`,
;; `maybe`, `values` or `args`); `_` keeps the operand as is.
(defmacro (compiler-ir-map-use
  [shape : Expr]
  [role : Expr]
  [operand : Expr]
  [mapper : Expr]
  [contexts : Expr ...]) : Expr
  (let
    [keep? : bool
      (match mapper
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [shape-name : String
      (match shape
        [(Expr.Var name) name]
        [_ (comptime-error "compiler-ir-map-use: shape must be a bare name")])]
    (if keep?
      operand
      (match shape-name
        ["value" `(,mapper ,@contexts ,role ,operand)]
        ["maybe"
          `(match ,operand
            [(compiler_ir_types.CompilerIrMaybeValue.No)
              (compiler_ir_types.CompilerIrMaybeValue.No)]
            [(compiler_ir_types.CompilerIrMaybeValue.Some use-value)
              (compiler_ir_types.CompilerIrMaybeValue.Some
                (,mapper ,@contexts ,role use-value))])]
        ["values"
          `(compiler-ir-value-seq-map ,operand ,mapper ,@contexts ,role)]
        ["args" `(compiler-ir-call-args-map ,operand ,mapper ,@contexts ,role)]
        [_ 'compiler-ir-unknown-operand-shape]))))

;; A mapped def, type or label: `(mapper ctx... operand)`; `_` keeps it.
(defmacro (compiler-ir-map-field
  [operand : Expr]
  [mapper : Expr]
  [contexts : Expr ...]) : Expr
  (match mapper
    [(Expr.Var name)
      (match name
        ["_" operand]
        [_ `(,mapper ,@contexts ,operand)])]
    [_ `(,mapper ,@contexts ,operand)]))

;; An absent trap label (`compiler-ir-label-none`) stays absent.
(defmacro (compiler-ir-map-trap-label
  [label : Expr]
  [mapper : Expr]
  [contexts : Expr ...]) : i64
  (match mapper
    [(Expr.Var name)
      (match name
        ["_" label]
        [_
          `(let
            [trap-label : i64 ,label]
            (if (= trap-label (compiler-ir-label-none))
              trap-label
              (,mapper ,@contexts trap-label)))])]
    [_
      `(let
        [trap-label : i64 ,label]
        (if (= trap-label (compiler-ir-label-none))
          trap-label
          (,mapper ,@contexts trap-label)))]))

(defmacro (compiler-ir-map-spmd-args
  [args : Expr]
  [use-mapper : Expr]
  [type-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrSpmdCallArgSeq
  (let
    [keep-uses? : bool
      (match use-mapper
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [keep-types? : bool
      (match type-mapper
        [(Expr.Var name)
          (match name
            ["_" true]
            [_ false])]
        [_ false])]
    [value-out : Expr
      (if keep-uses?
        'arg-value
        `(,use-mapper
          ,@contexts
          (compiler-ir-spmd-value-class-role arg-class)
          arg-value))]
    [type-out : Expr
      (if keep-types?
        'arg-ty
        `(,type-mapper ,@contexts arg-ty))]
    (if (if keep-uses?
      keep-types?
      false)
      args
      `(let
        [spmd-args ,args]
        [spmd-slots spmd-args.slots]
        [spmd-out (compiler-ir-spmd-call-arg-storage spmd-args.len)]
        [spmd-index : i64 0]
        (while (< spmd-index spmd-args.len)
          (match (unsafe
            (ptr-read (ptr-offset (__tl_array-data spmd-slots) spmd-index)))
            [(compiler_ir_types.CompilerIrSpmdCallArg.Arg
                arg-class
                arg-value
                arg-ty)
              (set!
                (array-ref spmd-out spmd-index)
                (compiler_ir_types.CompilerIrSpmdCallArg.Arg
                  arg-class
                  ,value-out
                  ,type-out))])
          (set! spmd-index (+ spmd-index 1)))
        (compiler-ir-spmd-call-arg-seq-of spmd-out spmd-args.len)))))

(defmacro (compiler-ir-map-spmd-result
  [result : Expr]
  [def-mapper : Expr]
  [type-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrSpmdCallResult
  `(match ,result
    [(compiler_ir_types.CompilerIrSpmdCallResult.Unit)
      (compiler-ir-spmd-call-result-unit)]
    [(compiler_ir_types.CompilerIrSpmdCallResult.Value
        result-dst
        class
        result-ty)
      (compiler_ir_types.CompilerIrSpmdCallResult.Value
        (compiler-ir-map-field result-dst ,def-mapper ,@contexts)
        class
        (compiler-ir-map-field result-ty ,type-mapper ,@contexts))]))

(defmacro (compiler-ir-map-switch-cases
  [cases : Expr]
  [label-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrSwitchCaseSeq
  (match label-mapper
    [(Expr.Var name)
      (match name
        ["_" cases]
        [_ `(compiler-ir-switch-cases-relabel ,cases ,label-mapper ,@contexts)])]
    [_ `(compiler-ir-switch-cases-relabel ,cases ,label-mapper ,@contexts)]))

(defmacro (compiler-ir-switch-cases-relabel
  [cases : Expr]
  [label-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrSwitchCaseSeq
  `(let
    [switch-cases ,cases]
    [case-slots switch-cases.slots]
    [case-out (compiler-ir-switch-case-storage switch-cases.len)]
    [case-index : i64 0]
    (while (< case-index switch-cases.len)
      (match (unsafe
        (ptr-read (ptr-offset (__tl_array-data case-slots) case-index)))
        [(compiler_ir_types.CompilerIrSwitchCase.Case tag case-label)
          (set!
            (array-ref case-out case-index)
            (compiler_ir_types.CompilerIrSwitchCase.Case
              tag
              (,label-mapper ,@contexts case-label)))])
      (set! case-index (+ case-index 1)))
    (compiler-ir-switch-case-seq-of case-out switch-cases.len)))

(defmacro (compiler-ir-map-c-abi-slots
  [slots : Expr]
  [type-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrCAbiReturnSlotSeq
  (match type-mapper
    [(Expr.Var name)
      (match name
        ["_" slots]
        [_ `(compiler-ir-c-abi-slots-retype ,slots ,type-mapper ,@contexts)])]
    [_ `(compiler-ir-c-abi-slots-retype ,slots ,type-mapper ,@contexts)]))

(defmacro (compiler-ir-c-abi-slots-retype
  [slots : Expr]
  [type-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrCAbiReturnSlotSeq
  `(let
    [return-slots ,slots]
    [slot-items return-slots.slots]
    [slot-out (compiler-ir-c-abi-return-slot-storage return-slots.len)]
    [slot-index : i64 0]
    (while (< slot-index return-slots.len)
      (match (unsafe
        (ptr-read (ptr-offset (__tl_array-data slot-items) slot-index)))
        [(compiler_ir_types.CompilerIrCAbiReturnSlot.Slot slot-ty offset)
          (set!
            (array-ref slot-out slot-index)
            (compiler_ir_types.CompilerIrCAbiReturnSlot.Slot
              (,type-mapper ,@contexts slot-ty)
              offset))])
      (set! slot-index (+ slot-index 1)))
    (compiler-ir-c-abi-return-slot-seq-of slot-out return-slots.len)))

;; Shared body of visit-uses and fold-uses; `acc` is `_` to visit.
(defmacro (compiler-ir-instr-walk-uses
  [instr : Expr]
  [acc : Expr]
  [f : Expr]
  [contexts : Expr ...]) : unit
  (let
    [tail : ExprList
      (match `(begin
        ,acc
        ,f
        ,@contexts)
        [(Expr.Begin items) items]
        [_ (expr-list-empty)])]
    [scalar : Expr '(compiler-ir-role-scalar)]
    [address : Expr '(compiler-ir-role-address)]
    [vector : Expr '(compiler-ir-role-vector)]
    [mask : Expr '(compiler-ir-role-mask)]
    [call-arg : Expr '(compiler-ir-role-call-arg)]
    [condition : Expr '(compiler-ir-role-condition)]
    `(match ,instr
      [(compiler_ir_types.CompilerIrInstr.Mov _ src _)
        (compiler-ir-use-step value ,scalar src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Alloc _ _) unit]
      [(compiler_ir_types.CompilerIrInstr.AddrOf _ _) unit]
      [(compiler_ir_types.CompilerIrInstr.Gep _ base offset _)
        (compiler-ir-use-step value ,address base ,@tail)
        (compiler-ir-use-step value ,scalar offset ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Load _ src _)
        (compiler-ir-use-step value ,address src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.StoreOwned ptr value _)
        (compiler-ir-use-step value ,address ptr ,@tail)
        (compiler-ir-use-step value ,scalar value ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.StorePtr ptr value _)
        (compiler-ir-use-step value ,address ptr ,@tail)
        (compiler-ir-use-step value ,scalar value ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.CopyBytes ptr src _)
        (compiler-ir-use-step value ,address ptr ,@tail)
        (compiler-ir-use-step value ,address src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.BoundsCheck index length _)
        (compiler-ir-use-step value ,scalar index ,@tail)
        (compiler-ir-use-step value ,scalar length ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Cast _ src _ _)
        (compiler-ir-use-step value ,scalar src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Bitcast _ src _ _)
        (compiler-ir-use-step value ,scalar src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.BinOp _ _ lhs rhs _)
        (compiler-ir-use-step value ,scalar lhs ,@tail)
        (compiler-ir-use-step value ,scalar rhs ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.UnOp _ _ src _)
        (compiler-ir-use-step value ,scalar src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.LaneId _ _ _) unit]
      [(compiler_ir_types.CompilerIrInstr.Splat _ value _ _)
        (compiler-ir-use-step value ,scalar value ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.VectorBinOp payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,vector payload.lhs ,@tail)
          (compiler-ir-use-step value ,vector payload.rhs ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.VectorPrefix payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,vector payload.src ,@tail)
          (compiler-ir-use-step value ,scalar payload.carry ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.VectorReduce _ _ src _ _)
        (compiler-ir-use-step value ,vector src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.VectorCompare payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,vector payload.lhs ,@tail)
          (compiler-ir-use-step value ,vector payload.rhs ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.MaskBinOp _ _ lhs rhs _)
        (compiler-ir-use-step value ,mask lhs ,@tail)
        (compiler-ir-use-step value ,mask rhs ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.MaskNot _ src _)
        (compiler-ir-use-step value ,mask src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.MaskReduce _ _ src _)
        (compiler-ir-use-step value ,mask src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Select payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,mask payload.mask ,@tail)
          (compiler-ir-use-step value ,vector payload.on-true ,@tail)
          (compiler-ir-use-step value ,vector payload.on-false ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.VectorLoad _ base index _ _)
        (compiler-ir-use-step value ,address base ,@tail)
        (compiler-ir-use-step value ,scalar index ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.VectorStore payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,address payload.base ,@tail)
          (compiler-ir-use-step value ,scalar payload.index ,@tail)
          (compiler-ir-use-step value ,vector payload.value ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.PredicatedStore payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,address payload.base ,@tail)
          (compiler-ir-use-step value ,scalar payload.index ,@tail)
          (compiler-ir-use-step value ,vector payload.value ,@tail)
          (compiler-ir-use-step value ,mask payload.mask ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.PredicatedLoad payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,address payload.base ,@tail)
          (compiler-ir-use-step value ,scalar payload.index ,@tail)
          (compiler-ir-use-step value ,mask payload.mask ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.GatherLoad payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,address payload.base ,@tail)
          (compiler-ir-use-step value ,address payload.index-base ,@tail)
          (compiler-ir-use-step value ,scalar payload.index ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.VectorShuffle payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,vector payload.source ,@tail)
          (compiler-ir-use-step value ,vector payload.selector-low ,@tail)
          (compiler-ir-use-step maybe ,vector payload.selector-high ,@tail)
          (compiler-ir-use-step value ,scalar payload.active-lanes ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.TailMask _ index len _)
        (compiler-ir-use-step value ,scalar index ,@tail)
        (compiler-ir-use-step value ,scalar len ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.EntryArgc _) unit]
      [(compiler_ir_types.CompilerIrInstr.EntryArgv _) unit]
      [(compiler_ir_types.CompilerIrInstr.EntryEnvp _) unit]
      [(compiler_ir_types.CompilerIrInstr.CpuId _ leaf subleaf _)
        (compiler-ir-use-step value ,scalar leaf ,@tail)
        (compiler-ir-use-step value ,scalar subleaf ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Xgetbv _ index)
        (compiler-ir-use-step value ,scalar index ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Syscall _ args)
        (compiler-ir-use-step args ,call-arg args ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Call _ _ args _)
        (compiler-ir-use-step args ,call-arg args ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.CallIndirect _ callee args _)
        (compiler-ir-use-step value ,address callee ,@tail)
        (compiler-ir-use-step args ,call-arg args ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.CallIndirectC _ callee args _)
        (compiler-ir-use-step value ,address callee ,@tail)
        (compiler-ir-use-step args ,call-arg args ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,address payload.base ,@tail)
          (compiler-ir-use-step args ,call-arg payload.args ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.CallIndirectCAbiStoreResult
          payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,address payload.base ,@tail)
          (compiler-ir-use-step value ,address payload.callee ,@tail)
          (compiler-ir-use-step args ,call-arg payload.args ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (compiler-ir-use-step value ,mask payload.active-mask ,@tail)
          (compiler-ir-use-step spmd-args _ payload.args ,@tail))]
      [(compiler_ir_types.CompilerIrInstr.TailCall _ args _)
        (compiler-ir-use-step args ,call-arg args ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Store _ value _)
        (compiler-ir-use-step value ,scalar value ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Jump _) unit]
      [(compiler_ir_types.CompilerIrInstr.Branch cond _ _)
        (compiler-ir-use-step value ,condition cond ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch cond _ _)
        (compiler-ir-use-step value ,condition cond ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Return value)
        (compiler-ir-use-step maybe ,scalar value ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Phi _ inputs _)
        (compiler-ir-use-step phi-inputs _ inputs ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Pack _ words _)
        (compiler-ir-use-step values ,scalar words ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Word _ src _ _)
        (compiler-ir-use-step value ,scalar src ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.TailCallIndirect callee args _)
        (compiler-ir-use-step value ,address callee ,@tail)
        (compiler-ir-use-step args ,call-arg args ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.Switch index _ _ _)
        (compiler-ir-use-step value ,condition index ,@tail)]
      [(compiler_ir_types.CompilerIrInstr.TotalEnumSwitch index _ _ _ _)
        (compiler-ir-use-step value ,condition index ,@tail)])))

;: Every use of `instr` in operand order: `(visitor ctx... role value)`.
(defmacro (compiler-ir-instr-visit-uses
  [instr : Expr]
  [visitor : Expr]
  [contexts : Expr ...]) : unit
  `(compiler-ir-instr-walk-uses ,instr _ ,visitor ,@contexts))

;: Fold every use of `instr` in operand order:
;: `(folder ctx... role acc value)` returns the next accumulator.
(defmacro (compiler-ir-instr-fold-uses
  [instr : Expr]
  [acc : Expr]
  [folder : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [fold-acc ,acc]
    (compiler-ir-instr-walk-uses ,instr fold-acc ,folder ,@contexts)
    fold-acc))

;: Rebuild `instr` with each use, def, type and label passed through its
;: mapper; slots and fixed fields are copied. A mapper given as `_` is the
;: identity and generates no call; the containers that kind owns (call
;: arguments, Pack words, SPMD arguments, phi inputs, switch cases, C-ABI
;: return slots) are then shared with `instr` rather than copied, so a deep
;: clone that must own fresh storage passes a real identity mapper. The SPMD
;: origin descriptor is copied with `clone` and its types are not mapped: a
;: pass that must re-home them matches SpmdCall first.
(defmacro (compiler-ir-instr-map
  [instr : Expr]
  [use-mapper : Expr]
  [def-mapper : Expr]
  [type-mapper : Expr]
  [label-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrInstr
  (let
    [use-tail : ExprList
      (match `(begin
        ,use-mapper
        ,@contexts)
        [(Expr.Begin items) items]
        [_ (expr-list-empty)])]
    [def-tail : ExprList
      (match `(begin
        ,def-mapper
        ,@contexts)
        [(Expr.Begin items) items]
        [_ (expr-list-empty)])]
    [type-tail : ExprList
      (match `(begin
        ,type-mapper
        ,@contexts)
        [(Expr.Begin items) items]
        [_ (expr-list-empty)])]
    [label-tail : ExprList
      (match `(begin
        ,label-mapper
        ,@contexts)
        [(Expr.Begin items) items]
        [_ (expr-list-empty)])]
    [scalar : Expr '(compiler-ir-role-scalar)]
    [address : Expr '(compiler-ir-role-address)]
    [vector : Expr '(compiler-ir-role-vector)]
    [mask : Expr '(compiler-ir-role-mask)]
    [call-arg : Expr '(compiler-ir-role-call-arg)]
    [condition : Expr '(compiler-ir-role-condition)]
    [phi-input : Expr '(compiler-ir-role-phi-input)]
    `(match ,instr
      [(compiler_ir_types.CompilerIrInstr.Mov dst src ty)
        (compiler_ir_types.CompilerIrInstr.Mov
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,scalar src ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Alloc dst ty)
        (compiler_ir_types.CompilerIrInstr.Alloc
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.AddrOf dst src)
        (compiler_ir_types.CompilerIrInstr.AddrOf
          (compiler-ir-map-field dst ,@def-tail)
          src)]
      [(compiler_ir_types.CompilerIrInstr.Gep dst base offset ty)
        (compiler_ir_types.CompilerIrInstr.Gep
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,address base ,@use-tail)
          (compiler-ir-map-use value ,scalar offset ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Load dst src ty)
        (compiler_ir_types.CompilerIrInstr.Load
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,address src ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.StoreOwned ptr value ty)
        (compiler_ir_types.CompilerIrInstr.StoreOwned
          (compiler-ir-map-use value ,address ptr ,@use-tail)
          (compiler-ir-map-use value ,scalar value ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.StorePtr ptr value ty)
        (compiler_ir_types.CompilerIrInstr.StorePtr
          (compiler-ir-map-use value ,address ptr ,@use-tail)
          (compiler-ir-map-use value ,scalar value ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.CopyBytes ptr src size)
        (compiler_ir_types.CompilerIrInstr.CopyBytes
          (compiler-ir-map-use value ,address ptr ,@use-tail)
          (compiler-ir-map-use value ,address src ,@use-tail)
          size)]
      [(compiler_ir_types.CompilerIrInstr.BoundsCheck index length ok-label)
        (compiler_ir_types.CompilerIrInstr.BoundsCheck
          (compiler-ir-map-use value ,scalar index ,@use-tail)
          (compiler-ir-map-use value ,scalar length ,@use-tail)
          (compiler-ir-map-field ok-label ,@label-tail))]
      [(compiler_ir_types.CompilerIrInstr.Cast dst src from-ty to-ty)
        (compiler_ir_types.CompilerIrInstr.Cast
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,scalar src ,@use-tail)
          (compiler-ir-map-field from-ty ,@type-tail)
          (compiler-ir-map-field to-ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Bitcast dst src from-ty to-ty)
        (compiler_ir_types.CompilerIrInstr.Bitcast
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,scalar src ,@use-tail)
          (compiler-ir-map-field from-ty ,@type-tail)
          (compiler-ir-map-field to-ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.BinOp dst op lhs rhs ty)
        (compiler_ir_types.CompilerIrInstr.BinOp
          (compiler-ir-map-field dst ,@def-tail)
          op
          (compiler-ir-map-use value ,scalar lhs ,@use-tail)
          (compiler-ir-map-use value ,scalar rhs ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.UnOp dst op src ty)
        (compiler_ir_types.CompilerIrInstr.UnOp
          (compiler-ir-map-field dst ,@def-tail)
          op
          (compiler-ir-map-use value ,scalar src ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.LaneId dst lanes ty)
        (compiler_ir_types.CompilerIrInstr.LaneId
          (compiler-ir-map-field dst ,@def-tail)
          lanes
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Splat dst value lanes ty)
        (compiler_ir_types.CompilerIrInstr.Splat
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,scalar value ,@use-tail)
          lanes
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.VectorBinOp payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-vector-bin-op
            (compiler-ir-map-field payload.dst ,@def-tail)
            payload.op
            (compiler-ir-map-use value ,vector payload.lhs ,@use-tail)
            (compiler-ir-map-use value ,vector payload.rhs ,@use-tail)
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.VectorPrefix payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-vector-prefix
            (compiler-ir-map-field payload.dst ,@def-tail)
            payload.op
            (compiler-ir-map-use value ,vector payload.src ,@use-tail)
            (compiler-ir-map-use value ,scalar payload.carry ,@use-tail)
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.VectorReduce dst op src lanes ty)
        (compiler_ir_types.CompilerIrInstr.VectorReduce
          (compiler-ir-map-field dst ,@def-tail)
          op
          (compiler-ir-map-use value ,vector src ,@use-tail)
          lanes
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.VectorCompare payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-vector-compare
            (compiler-ir-map-field payload.dst ,@def-tail)
            payload.op
            (compiler-ir-map-use value ,vector payload.lhs ,@use-tail)
            (compiler-ir-map-use value ,vector payload.rhs ,@use-tail)
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.MaskBinOp dst op lhs rhs lanes)
        (compiler_ir_types.CompilerIrInstr.MaskBinOp
          (compiler-ir-map-field dst ,@def-tail)
          op
          (compiler-ir-map-use value ,mask lhs ,@use-tail)
          (compiler-ir-map-use value ,mask rhs ,@use-tail)
          lanes)]
      [(compiler_ir_types.CompilerIrInstr.MaskNot dst src lanes)
        (compiler_ir_types.CompilerIrInstr.MaskNot
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,mask src ,@use-tail)
          lanes)]
      [(compiler_ir_types.CompilerIrInstr.MaskReduce dst op src lanes)
        (compiler_ir_types.CompilerIrInstr.MaskReduce
          (compiler-ir-map-field dst ,@def-tail)
          op
          (compiler-ir-map-use value ,mask src ,@use-tail)
          lanes)]
      [(compiler_ir_types.CompilerIrInstr.Select payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-select
            (compiler-ir-map-field payload.dst ,@def-tail)
            (compiler-ir-map-use value ,mask payload.mask ,@use-tail)
            (compiler-ir-map-use value ,vector payload.on-true ,@use-tail)
            (compiler-ir-map-use value ,vector payload.on-false ,@use-tail)
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.VectorLoad dst base index lanes ty)
        (compiler_ir_types.CompilerIrInstr.VectorLoad
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,address base ,@use-tail)
          (compiler-ir-map-use value ,scalar index ,@use-tail)
          lanes
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.VectorStore payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-vector-store
            (compiler-ir-map-use value ,address payload.base ,@use-tail)
            (compiler-ir-map-use value ,scalar payload.index ,@use-tail)
            (compiler-ir-map-use value ,vector payload.value ,@use-tail)
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.PredicatedStore payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-predicated-store
            (compiler-ir-map-use value ,address payload.base ,@use-tail)
            (compiler-ir-map-use value ,scalar payload.index ,@use-tail)
            (compiler-ir-map-use value ,vector payload.value ,@use-tail)
            (compiler-ir-map-use value ,mask payload.mask ,@use-tail)
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.PredicatedLoad payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-predicated-load
            (compiler-ir-map-field payload.dst ,@def-tail)
            (compiler-ir-map-use value ,address payload.base ,@use-tail)
            (compiler-ir-map-use value ,scalar payload.index ,@use-tail)
            (compiler-ir-map-use value ,mask payload.mask ,@use-tail)
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.GatherLoad payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-gather-load
            (compiler-ir-map-field payload.dst ,@def-tail)
            (compiler-ir-map-use value ,address payload.base ,@use-tail)
            (compiler-ir-map-use value ,address payload.index-base ,@use-tail)
            (compiler-ir-map-use value ,scalar payload.index ,@use-tail)
            payload.lane-offset
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.VectorShuffle payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-vector-shuffle
            (compiler-ir-map-field payload.dst ,@def-tail)
            (compiler-ir-map-use value ,vector payload.source ,@use-tail)
            (compiler-ir-map-use value ,vector payload.selector-low ,@use-tail)
            (compiler-ir-map-use maybe ,vector payload.selector-high ,@use-tail)
            (compiler-ir-map-use value ,scalar payload.active-lanes ,@use-tail)
            payload.lanes
            (compiler-ir-map-field payload.ty ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.TailMask dst index len lanes)
        (compiler_ir_types.CompilerIrInstr.TailMask
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,scalar index ,@use-tail)
          (compiler-ir-map-use value ,scalar len ,@use-tail)
          lanes)]
      [(compiler_ir_types.CompilerIrInstr.EntryArgc dst)
        (compiler_ir_types.CompilerIrInstr.EntryArgc
          (compiler-ir-map-field dst ,@def-tail))]
      [(compiler_ir_types.CompilerIrInstr.EntryArgv dst)
        (compiler_ir_types.CompilerIrInstr.EntryArgv
          (compiler-ir-map-field dst ,@def-tail))]
      [(compiler_ir_types.CompilerIrInstr.EntryEnvp dst)
        (compiler_ir_types.CompilerIrInstr.EntryEnvp
          (compiler-ir-map-field dst ,@def-tail))]
      [(compiler_ir_types.CompilerIrInstr.CpuId dst leaf subleaf reg-index)
        (compiler_ir_types.CompilerIrInstr.CpuId
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,scalar leaf ,@use-tail)
          (compiler-ir-map-use value ,scalar subleaf ,@use-tail)
          reg-index)]
      [(compiler_ir_types.CompilerIrInstr.Xgetbv dst index)
        (compiler_ir_types.CompilerIrInstr.Xgetbv
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,scalar index ,@use-tail))]
      [(compiler_ir_types.CompilerIrInstr.Syscall dst args)
        (compiler_ir_types.CompilerIrInstr.Syscall
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use args ,call-arg args ,@use-tail))]
      [(compiler_ir_types.CompilerIrInstr.Call dst name args ty)
        (compiler_ir_types.CompilerIrInstr.Call
          (compiler-ir-map-field dst ,@def-tail)
          name
          (compiler-ir-map-use args ,call-arg args ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.CallIndirect dst callee args ty)
        (compiler_ir_types.CompilerIrInstr.CallIndirect
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,address callee ,@use-tail)
          (compiler-ir-map-use args ,call-arg args ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.CallIndirectC dst callee args ty)
        (compiler_ir_types.CompilerIrInstr.CallIndirectC
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,address callee ,@use-tail)
          (compiler-ir-map-use args ,call-arg args ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-call-cabi-store-result
            (compiler-ir-map-use value ,address payload.base ,@use-tail)
            payload.name
            (compiler-ir-map-use args ,call-arg payload.args ,@use-tail)
            (compiler-ir-map-c-abi-slots payload.slots ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.CallIndirectCAbiStoreResult
          payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-call-indirect-cabi-store-result
            (compiler-ir-map-use value ,address payload.base ,@use-tail)
            (compiler-ir-map-use value ,address payload.callee ,@use-tail)
            (compiler-ir-map-use args ,call-arg payload.args ,@use-tail)
            (compiler-ir-map-c-abi-slots payload.slots ,@type-tail)))]
      [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
        (let
          [payload (compiler-ir-box-shared-view payload-box)]
          (ir-instr-spmd-call-with-origin
            payload.callee
            payload.backend
            payload.lanes
            (compiler-ir-map-use value ,mask payload.active-mask ,@use-tail)
            (compiler-ir-map-spmd-args
              payload.args
              ,use-mapper
              ,type-mapper
              ,@contexts)
            (compiler-ir-map-spmd-result
              payload.result
              ,def-mapper
              ,type-mapper
              ,@contexts)
            (clone payload.origin)))]
      [(compiler_ir_types.CompilerIrInstr.TailCall name args ty)
        (compiler_ir_types.CompilerIrInstr.TailCall
          name
          (compiler-ir-map-use args ,call-arg args ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Store name value ty)
        (compiler_ir_types.CompilerIrInstr.Store
          name
          (compiler-ir-map-use value ,scalar value ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Jump label)
        (compiler_ir_types.CompilerIrInstr.Jump
          (compiler-ir-map-field label ,@label-tail))]
      [(compiler_ir_types.CompilerIrInstr.Branch cond true-label false-label)
        (compiler_ir_types.CompilerIrInstr.Branch
          (compiler-ir-map-use value ,condition cond ,@use-tail)
          (compiler-ir-map-field true-label ,@label-tail)
          (compiler-ir-map-field false-label ,@label-tail))]
      [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch
          cond
          true-label
          false-label)
        (compiler_ir_types.CompilerIrInstr.TotalEnumBranch
          (compiler-ir-map-use value ,condition cond ,@use-tail)
          (compiler-ir-map-field true-label ,@label-tail)
          (compiler-ir-map-field false-label ,@label-tail))]
      [(compiler_ir_types.CompilerIrInstr.Return value)
        (compiler_ir_types.CompilerIrInstr.Return
          (compiler-ir-map-use maybe ,scalar value ,@use-tail))]
      [(compiler_ir_types.CompilerIrInstr.Phi dst inputs ty)
        (compiler_ir_types.CompilerIrInstr.Phi
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-phi-inputs-rebuild
            inputs
            ,use-mapper
            ,phi-input
            ,label-mapper
            ,@contexts)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Pack dst words ty)
        (compiler_ir_types.CompilerIrInstr.Pack
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use values ,scalar words ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Word dst src index ty)
        (compiler_ir_types.CompilerIrInstr.Word
          (compiler-ir-map-field dst ,@def-tail)
          (compiler-ir-map-use value ,scalar src ,@use-tail)
          index
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.TailCallIndirect callee args ty)
        (compiler_ir_types.CompilerIrInstr.TailCallIndirect
          (compiler-ir-map-use value ,address callee ,@use-tail)
          (compiler-ir-map-use args ,call-arg args ,@use-tail)
          (compiler-ir-map-field ty ,@type-tail))]
      [(compiler_ir_types.CompilerIrInstr.Switch index base cases default-label)
        (compiler_ir_types.CompilerIrInstr.Switch
          (compiler-ir-map-use value ,condition index ,@use-tail)
          base
          (compiler-ir-map-switch-cases cases ,@label-tail)
          (compiler-ir-map-field default-label ,@label-tail))]
      [(compiler_ir_types.CompilerIrInstr.TotalEnumSwitch
          index
          base
          cases
          default-label
          trap-label)
        (compiler_ir_types.CompilerIrInstr.TotalEnumSwitch
          (compiler-ir-map-use value ,condition index ,@use-tail)
          base
          (compiler-ir-map-switch-cases cases ,@label-tail)
          (compiler-ir-map-field default-label ,@label-tail)
          (compiler-ir-map-trap-label trap-label ,@label-tail))])))

;: `compiler-ir-instr-map` with only a use mapper.
(defmacro (compiler-ir-instr-map-uses
  [instr : Expr]
  [use-mapper : Expr]
  [contexts : Expr ...]) : CompilerIrInstr
  `(compiler-ir-instr-map ,instr ,use-mapper _ _ _ ,@contexts))

(define (compiler-ir-dst-replace [dst : i64] [_old : i64]) : i64
  dst)

;: `instr` with its destination var replaced; an instruction without one is
;: returned unchanged.
(define (compiler-ir-instr-with-dst [instr : CompilerIrInstr] [dst : i64]) : CompilerIrInstr
  (compiler-ir-instr-map instr _ compiler-ir-dst-replace _ _ dst))

;: The control-flow successor labels of a terminator: a Jump target, a branch's
;: true then false label, a switch's default label, then a present
;: TotalEnumSwitch trap label, then the case labels in order. Labels are not
;: deduplicated. A BoundsCheck success label is not an edge.
(defmacro (compiler-ir-instr-visit-successors
  [instr : Expr]
  [visitor : Expr]
  [contexts : Expr ...]) : unit
  `(match ,instr
    [(compiler_ir_types.CompilerIrInstr.Mov _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Alloc _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.AddrOf _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Gep _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Load _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.StoreOwned _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.StorePtr _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.CopyBytes _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.BoundsCheck _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Cast _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Bitcast _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.BinOp _ _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.UnOp _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.LaneId _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Splat _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.VectorBinOp _) unit]
    [(compiler_ir_types.CompilerIrInstr.VectorPrefix _) unit]
    [(compiler_ir_types.CompilerIrInstr.VectorReduce _ _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.VectorCompare _) unit]
    [(compiler_ir_types.CompilerIrInstr.MaskBinOp _ _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.MaskNot _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.MaskReduce _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Select _) unit]
    [(compiler_ir_types.CompilerIrInstr.VectorLoad _ _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.VectorStore _) unit]
    [(compiler_ir_types.CompilerIrInstr.PredicatedStore _) unit]
    [(compiler_ir_types.CompilerIrInstr.PredicatedLoad _) unit]
    [(compiler_ir_types.CompilerIrInstr.GatherLoad _) unit]
    [(compiler_ir_types.CompilerIrInstr.VectorShuffle _) unit]
    [(compiler_ir_types.CompilerIrInstr.TailMask _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.EntryArgc _) unit]
    [(compiler_ir_types.CompilerIrInstr.EntryArgv _) unit]
    [(compiler_ir_types.CompilerIrInstr.EntryEnvp _) unit]
    [(compiler_ir_types.CompilerIrInstr.CpuId _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Xgetbv _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Syscall _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Call _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.CallIndirect _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.CallIndirectC _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult _) unit]
    [(compiler_ir_types.CompilerIrInstr.CallIndirectCAbiStoreResult _) unit]
    [(compiler_ir_types.CompilerIrInstr.SpmdCall _) unit]
    [(compiler_ir_types.CompilerIrInstr.TailCall _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Store _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Jump label) (,visitor ,@contexts label)]
    [(compiler_ir_types.CompilerIrInstr.Branch _ true-label false-label)
      (,visitor ,@contexts true-label)
      (,visitor ,@contexts false-label)]
    [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch
      _
      true-label
      false-label)
      (,visitor ,@contexts true-label)
      (,visitor ,@contexts false-label)]
    [(compiler_ir_types.CompilerIrInstr.Return _) unit]
    [(compiler_ir_types.CompilerIrInstr.Phi _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Pack _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Word _ _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.TailCallIndirect _ _ _) unit]
    [(compiler_ir_types.CompilerIrInstr.Switch _ _ cases default-label)
      (,visitor ,@contexts default-label)
      (compiler-ir-switch-cases-visit cases ,visitor ,@contexts)]
    [(compiler_ir_types.CompilerIrInstr.TotalEnumSwitch
      _
      _
      cases
      default-label
      trap-label)
      (,visitor ,@contexts default-label)
      (if (= trap-label (compiler_ir_types.compiler-ir-label-none))
        unit
        (,visitor ,@contexts trap-label))
      (compiler-ir-switch-cases-visit cases ,visitor ,@contexts)]))

;; Op equality for compiler-ir-instr-zip-eq; a shift's count types compare
;; with `(type-eq ctx... a b)`.
(defmacro (compiler-ir-bin-op-zip-eq
  [a : Expr]
  [b : Expr]
  [type-eq : Expr]
  [contexts : Expr ...]) : bool
  `(let
    [zip-op-a ,a]
    [zip-op-b ,b]
    (match zip-op-a
      [(compiler_ir_types.CompilerIrBinOp.Add)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Add) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Sub)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Sub) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Mul)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Mul) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Div)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Div) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Mod)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Mod) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.SafeDiv)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.SafeDiv) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.SafeMod)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.SafeMod) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Eq)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Eq) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Ne)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Ne) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Lt)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Lt) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Le)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Le) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Gt)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Gt) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Ge)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Ge) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.BitTestEq)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.BitTestEq) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.BitTestNe)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.BitTestNe) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.And)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.And) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Or)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Or) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.BitAnd)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.BitAnd) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.BitOr)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.BitOr) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.BitXor)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.BitXor) true]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Shl a-count-ty)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Shl b-count-ty)
            (,type-eq ,@contexts a-count-ty b-count-ty)]
          [_ false])]
      [(compiler_ir_types.CompilerIrBinOp.Shr a-count-ty)
        (match zip-op-b
          [(compiler_ir_types.CompilerIrBinOp.Shr b-count-ty)
            (,type-eq ,@contexts a-count-ty b-count-ty)]
          [_ false])])))

(define (compiler-ir-switch-case-seq-eq?
  [a : CompilerIrSwitchCaseSeq]
  [b : CompilerIrSwitchCaseSeq]) : bool
  (let
    [same : bool (= a.len b.len)]
    [index : i64 0]
    (while (and same (< index a.len))
      (match (compiler-ir-switch-case-seq-ref a index)
        [(Case a-tag a-label)
          (match (compiler-ir-switch-case-seq-ref b index)
            [(Case b-tag b-label)
              (set! same (and (= a-tag b-tag) (= a-label b-label)))])])
      (set! index (+ index 1)))
    same))

;; Pairwise use equality for compiler-ir-instr-zip-eq: `(value-eq ctx... a b)`
;; per value pair of the shape (`value`, `maybe`, `values`, `args` or
;; `phi-inputs`, whose labels must also match), after the shapes agree.
(defmacro (compiler-ir-zip-use
  [shape : Expr]
  [a : Expr]
  [b : Expr]
  [value-eq : Expr]
  [contexts : Expr ...]) : bool
  (match shape
    [(Expr.Var shape-name)
      (match shape-name
        ["value" `(,value-eq ,@contexts ,a ,b)]
        ["maybe"
          `(match ,a
            [(compiler_ir_types.CompilerIrMaybeValue.No)
              (match ,b
                [(compiler_ir_types.CompilerIrMaybeValue.No) true]
                [_ false])]
            [(compiler_ir_types.CompilerIrMaybeValue.Some a-value)
              (match ,b
                [(compiler_ir_types.CompilerIrMaybeValue.Some b-value)
                  (,value-eq ,@contexts a-value b-value)]
                [_ false])])]
        ["values"
          `(let
            [a-values ,a]
            [b-values ,b]
            (and
              (= a-values.len b-values.len)
              (compiler-ir-zip-value-slots
                a-values.slots
                b-values.slots
                a-values.len
                ,value-eq
                ,@contexts)))]
        ["args"
          `(match ,a
            [(compiler_ir_types.CompilerIrCallArgs.Nil)
              (match ,b
                [(compiler_ir_types.CompilerIrCallArgs.Nil) true]
                [_ false])]
            [(compiler_ir_types.CompilerIrCallArgs.One a-value)
              (match ,b
                [(compiler_ir_types.CompilerIrCallArgs.One b-value)
                  (,value-eq ,@contexts a-value b-value)]
                [_ false])]
            [(compiler_ir_types.CompilerIrCallArgs.Two a-first a-second)
              (match ,b
                [(compiler_ir_types.CompilerIrCallArgs.Two b-first b-second)
                  (and
                    (,value-eq ,@contexts a-first b-first)
                    (,value-eq ,@contexts a-second b-second))]
                [_ false])]
            [(compiler_ir_types.CompilerIrCallArgs.Array a-values)
              (match ,b
                [(compiler_ir_types.CompilerIrCallArgs.Array b-values)
                  (and
                    (= (array-length a-values) (array-length b-values))
                    (compiler-ir-zip-value-slots
                      a-values
                      b-values
                      (array-length a-values)
                      ,value-eq
                      ,@contexts))]
                [_ false])]
            [(compiler_ir_types.CompilerIrCallArgs.Sret a-values a-index)
              (match ,b
                [(compiler_ir_types.CompilerIrCallArgs.Sret b-values b-index)
                  (and
                    (= a-index b-index)
                    (= (array-length a-values) (array-length b-values))
                    (compiler-ir-zip-value-slots
                      a-values
                      b-values
                      (array-length a-values)
                      ,value-eq
                      ,@contexts))]
                [_ false])])]
        ["phi-inputs"
          `(let
            [a-inputs ,a]
            [b-inputs ,b]
            [same : bool (= a-inputs.len b-inputs.len)]
            [index : i64 0]
            (while (and same (< index a-inputs.len))
              (let
                [a-input (compiler-ir-phi-input-seq-ref a-inputs index)]
                [b-input (compiler-ir-phi-input-seq-ref b-inputs index)]
                (set!
                  same
                  (and
                    (= a-input.label b-input.label)
                    (,value-eq ,@contexts a-input.value b-input.value)))
                (set! index (+ index 1))))
            same)]
        [_ 'compiler-ir-unknown-operand-shape])]
    [_ 'compiler-ir-unknown-operand-shape]))

(defmacro (compiler-ir-zip-value-slots
  [a : Expr]
  [b : Expr]
  [count : Expr]
  [value-eq : Expr]
  [contexts : Expr ...]) : bool
  `(let
    [slot-count : i64 ,count]
    [a-slots ,a]
    [b-slots ,b]
    [same : bool true]
    [index : i64 0]
    (while (and same (< index slot-count))
      (set!
        same
        (,value-eq
          ,@contexts
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data a-slots) index)))
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data b-slots) index)))))
      (set! index (+ index 1)))
    same))

(defmacro (compiler-ir-zip-type
  [a : Expr]
  [b : Expr]
  [type-eq : Expr]
  [contexts : Expr ...]) : bool
  `(,type-eq ,@contexts ,a ,b))

(defmacro (compiler-ir-zip-c-abi-slots
  [a : Expr]
  [b : Expr]
  [type-eq : Expr]
  [contexts : Expr ...]) : bool
  `(let
    [a-slots ,a]
    [b-slots ,b]
    [a-items a-slots.slots]
    [b-items b-slots.slots]
    [same : bool (= a-slots.len b-slots.len)]
    [index : i64 0]
    (while (and same (< index a-slots.len))
      (match (unsafe
        (ptr-read (ptr-offset (__tl_array-data a-items) index)))
        [(compiler_ir_types.CompilerIrCAbiReturnSlot.Slot a-ty a-offset)
          (match (unsafe
            (ptr-read (ptr-offset (__tl_array-data b-items) index)))
            [(compiler_ir_types.CompilerIrCAbiReturnSlot.Slot b-ty b-offset)
              (set!
                same
                (and (= a-offset b-offset) (,type-eq ,@contexts a-ty b-ty)))])])
      (set! index (+ index 1)))
    same))

;: Structural instruction equality: the same variant and fixed fields, with
;: `(value-eq ctx... a b)` for every use pair and `(type-eq ctx... a b)` for
;: every type pair (shift count types included). Defs, slots, labels and
;: symbols compare as ids. SpmdCall is never equal: its origin descriptor has
;: no structural equality here.
(defmacro (compiler-ir-instr-zip-eq
  [a : Expr]
  [b : Expr]
  [value-eq : Expr]
  [type-eq : Expr]
  [contexts : Expr ...]) : bool
  (let
    [value-tail : ExprList
      (match `(begin
        ,value-eq
        ,@contexts)
        [(Expr.Begin items) items]
        [_ (expr-list-empty)])]
    [type-tail : ExprList
      (match `(begin
        ,type-eq
        ,@contexts)
        [(Expr.Begin items) items]
        [_ (expr-list-empty)])]
    `(let
      [zip-a ,a]
      [zip-b ,b]
      (match zip-a
        [(compiler_ir_types.CompilerIrInstr.Mov a-dst a-src a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Mov b-dst b-src b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Alloc a-dst a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Alloc b-dst b-ty)
              (and (= a-dst b-dst) (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.AddrOf a-dst a-src)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.AddrOf b-dst b-src)
              (and (= a-dst b-dst) (= a-src b-src))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Gep a-dst a-base a-offset a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Gep b-dst b-base b-offset b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-base b-base ,@value-tail)
                (compiler-ir-zip-use value a-offset b-offset ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Load a-dst a-src a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Load b-dst b-src b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.StoreOwned a-ptr a-value a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.StoreOwned b-ptr b-value b-ty)
              (and
                (compiler-ir-zip-use value a-ptr b-ptr ,@value-tail)
                (compiler-ir-zip-use value a-value b-value ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.StorePtr a-ptr a-value a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.StorePtr b-ptr b-value b-ty)
              (and
                (compiler-ir-zip-use value a-ptr b-ptr ,@value-tail)
                (compiler-ir-zip-use value a-value b-value ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.CopyBytes a-ptr a-src a-size)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.CopyBytes b-ptr b-src b-size)
              (and
                (compiler-ir-zip-use value a-ptr b-ptr ,@value-tail)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (= a-size b-size))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.BoundsCheck
            a-index
            a-length
            a-ok-label)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.BoundsCheck
                b-index
                b-length
                b-ok-label)
              (and
                (compiler-ir-zip-use value a-index b-index ,@value-tail)
                (compiler-ir-zip-use value a-length b-length ,@value-tail)
                (= a-ok-label b-ok-label))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Cast a-dst a-src a-from-ty a-to-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Cast
                b-dst
                b-src
                b-from-ty
                b-to-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (compiler-ir-zip-type a-from-ty b-from-ty ,@type-tail)
                (compiler-ir-zip-type a-to-ty b-to-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Bitcast
            a-dst
            a-src
            a-from-ty
            a-to-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Bitcast
                b-dst
                b-src
                b-from-ty
                b-to-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (compiler-ir-zip-type a-from-ty b-from-ty ,@type-tail)
                (compiler-ir-zip-type a-to-ty b-to-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.BinOp a-dst a-op a-lhs a-rhs a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.BinOp
                b-dst
                b-op
                b-lhs
                b-rhs
                b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-bin-op-zip-eq a-op b-op ,@type-tail)
                (compiler-ir-zip-use value a-lhs b-lhs ,@value-tail)
                (compiler-ir-zip-use value a-rhs b-rhs ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.UnOp a-dst a-op a-src a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.UnOp b-dst b-op b-src b-ty)
              (and
                (= a-dst b-dst)
                (= a-op b-op)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.LaneId a-dst a-lanes a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.LaneId b-dst b-lanes b-ty)
              (and
                (= a-dst b-dst)
                (= a-lanes b-lanes)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Splat a-dst a-value a-lanes a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Splat
                b-dst
                b-value
                b-lanes
                b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-value b-value ,@value-tail)
                (= a-lanes b-lanes)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.VectorBinOp a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.VectorBinOp b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (= a.dst b.dst)
                  (compiler-ir-bin-op-zip-eq a.op b.op ,@type-tail)
                  (compiler-ir-zip-use value a.lhs b.lhs ,@value-tail)
                  (compiler-ir-zip-use value a.rhs b.rhs ,@value-tail)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.VectorPrefix a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.VectorPrefix b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (= a.dst b.dst)
                  (= a.op b.op)
                  (compiler-ir-zip-use value a.src b.src ,@value-tail)
                  (compiler-ir-zip-use value a.carry b.carry ,@value-tail)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.VectorReduce
            a-dst
            a-op
            a-src
            a-lanes
            a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.VectorReduce
                b-dst
                b-op
                b-src
                b-lanes
                b-ty)
              (and
                (= a-dst b-dst)
                (= a-op b-op)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (= a-lanes b-lanes)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.VectorCompare a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.VectorCompare b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (= a.dst b.dst)
                  (compiler-ir-bin-op-zip-eq a.op b.op ,@type-tail)
                  (compiler-ir-zip-use value a.lhs b.lhs ,@value-tail)
                  (compiler-ir-zip-use value a.rhs b.rhs ,@value-tail)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.MaskBinOp
            a-dst
            a-op
            a-lhs
            a-rhs
            a-lanes)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.MaskBinOp
                b-dst
                b-op
                b-lhs
                b-rhs
                b-lanes)
              (and
                (= a-dst b-dst)
                (= a-op b-op)
                (compiler-ir-zip-use value a-lhs b-lhs ,@value-tail)
                (compiler-ir-zip-use value a-rhs b-rhs ,@value-tail)
                (= a-lanes b-lanes))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.MaskNot a-dst a-src a-lanes)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.MaskNot b-dst b-src b-lanes)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (= a-lanes b-lanes))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.MaskReduce a-dst a-op a-src a-lanes)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.MaskReduce
                b-dst
                b-op
                b-src
                b-lanes)
              (and
                (= a-dst b-dst)
                (= a-op b-op)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (= a-lanes b-lanes))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Select a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Select b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (= a.dst b.dst)
                  (compiler-ir-zip-use value a.mask b.mask ,@value-tail)
                  (compiler-ir-zip-use value a.on-true b.on-true ,@value-tail)
                  (compiler-ir-zip-use value a.on-false b.on-false ,@value-tail)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.VectorLoad
            a-dst
            a-base
            a-index
            a-lanes
            a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.VectorLoad
                b-dst
                b-base
                b-index
                b-lanes
                b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-base b-base ,@value-tail)
                (compiler-ir-zip-use value a-index b-index ,@value-tail)
                (= a-lanes b-lanes)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.VectorStore a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.VectorStore b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (compiler-ir-zip-use value a.base b.base ,@value-tail)
                  (compiler-ir-zip-use value a.index b.index ,@value-tail)
                  (compiler-ir-zip-use value a.value b.value ,@value-tail)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.PredicatedStore a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.PredicatedStore b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (compiler-ir-zip-use value a.base b.base ,@value-tail)
                  (compiler-ir-zip-use value a.index b.index ,@value-tail)
                  (compiler-ir-zip-use value a.value b.value ,@value-tail)
                  (compiler-ir-zip-use value a.mask b.mask ,@value-tail)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.PredicatedLoad a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.PredicatedLoad b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (= a.dst b.dst)
                  (compiler-ir-zip-use value a.base b.base ,@value-tail)
                  (compiler-ir-zip-use value a.index b.index ,@value-tail)
                  (compiler-ir-zip-use value a.mask b.mask ,@value-tail)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.GatherLoad a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.GatherLoad b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (= a.dst b.dst)
                  (compiler-ir-zip-use value a.base b.base ,@value-tail)
                  (compiler-ir-zip-use
                    value
                    a.index-base
                    b.index-base
                    ,@value-tail)
                  (compiler-ir-zip-use value a.index b.index ,@value-tail)
                  (= a.lane-offset b.lane-offset)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.VectorShuffle a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.VectorShuffle b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (= a.dst b.dst)
                  (compiler-ir-zip-use value a.source b.source ,@value-tail)
                  (compiler-ir-zip-use
                    value
                    a.selector-low
                    b.selector-low
                    ,@value-tail)
                  (compiler-ir-zip-use
                    maybe
                    a.selector-high
                    b.selector-high
                    ,@value-tail)
                  (compiler-ir-zip-use
                    value
                    a.active-lanes
                    b.active-lanes
                    ,@value-tail)
                  (= a.lanes b.lanes)
                  (compiler-ir-zip-type a.ty b.ty ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.TailMask
            a-dst
            a-index
            a-len
            a-lanes)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.TailMask
                b-dst
                b-index
                b-len
                b-lanes)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-index b-index ,@value-tail)
                (compiler-ir-zip-use value a-len b-len ,@value-tail)
                (= a-lanes b-lanes))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.EntryArgc a-dst)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.EntryArgc b-dst)
              (= a-dst b-dst)]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.EntryArgv a-dst)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.EntryArgv b-dst)
              (= a-dst b-dst)]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.EntryEnvp a-dst)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.EntryEnvp b-dst)
              (= a-dst b-dst)]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.CpuId
            a-dst
            a-leaf
            a-subleaf
            a-reg-index)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.CpuId
                b-dst
                b-leaf
                b-subleaf
                b-reg-index)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-leaf b-leaf ,@value-tail)
                (compiler-ir-zip-use value a-subleaf b-subleaf ,@value-tail)
                (= a-reg-index b-reg-index))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Xgetbv a-dst a-index)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Xgetbv b-dst b-index)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-index b-index ,@value-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Syscall a-dst a-args)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Syscall b-dst b-args)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use args a-args b-args ,@value-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Call a-dst a-name a-args a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Call b-dst b-name b-args b-ty)
              (and
                (= a-dst b-dst)
                (= a-name b-name)
                (compiler-ir-zip-use args a-args b-args ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.CallIndirect
            a-dst
            a-callee
            a-args
            a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.CallIndirect
                b-dst
                b-callee
                b-args
                b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-callee b-callee ,@value-tail)
                (compiler-ir-zip-use args a-args b-args ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.CallIndirectC
            a-dst
            a-callee
            a-args
            a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.CallIndirectC
                b-dst
                b-callee
                b-args
                b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-callee b-callee ,@value-tail)
                (compiler-ir-zip-use args a-args b-args ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (compiler-ir-zip-use value a.base b.base ,@value-tail)
                  (= a.name b.name)
                  (compiler-ir-zip-use args a.args b.args ,@value-tail)
                  (compiler-ir-zip-c-abi-slots a.slots b.slots ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.CallIndirectCAbiStoreResult a-box)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.CallIndirectCAbiStoreResult
                b-box)
              (let
                [a (compiler-ir-box-shared-view a-box)]
                [b (compiler-ir-box-shared-view b-box)]
                (and
                  (compiler-ir-zip-use value a.base b.base ,@value-tail)
                  (compiler-ir-zip-use value a.callee b.callee ,@value-tail)
                  (compiler-ir-zip-use args a.args b.args ,@value-tail)
                  (compiler-ir-zip-c-abi-slots a.slots b.slots ,@type-tail)))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.SpmdCall _) false]
        [(compiler_ir_types.CompilerIrInstr.TailCall a-name a-args a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.TailCall b-name b-args b-ty)
              (and
                (= a-name b-name)
                (compiler-ir-zip-use args a-args b-args ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Store a-name a-value a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Store b-name b-value b-ty)
              (and
                (= a-name b-name)
                (compiler-ir-zip-use value a-value b-value ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Jump a-label)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Jump b-label)
              (= a-label b-label)]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Branch
            a-cond
            a-true-label
            a-false-label)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Branch
                b-cond
                b-true-label
                b-false-label)
              (and
                (compiler-ir-zip-use value a-cond b-cond ,@value-tail)
                (= a-true-label b-true-label)
                (= a-false-label b-false-label))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch
            a-cond
            a-true-label
            a-false-label)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch
                b-cond
                b-true-label
                b-false-label)
              (and
                (compiler-ir-zip-use value a-cond b-cond ,@value-tail)
                (= a-true-label b-true-label)
                (= a-false-label b-false-label))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Return a-value)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Return b-value)
              (compiler-ir-zip-use maybe a-value b-value ,@value-tail)]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Phi a-dst a-inputs a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Phi b-dst b-inputs b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use phi-inputs a-inputs b-inputs ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Pack a-dst a-words a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Pack b-dst b-words b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use values a-words b-words ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Word a-dst a-src a-index a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Word b-dst b-src b-index b-ty)
              (and
                (= a-dst b-dst)
                (compiler-ir-zip-use value a-src b-src ,@value-tail)
                (= a-index b-index)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.TailCallIndirect
            a-callee
            a-args
            a-ty)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.TailCallIndirect
                b-callee
                b-args
                b-ty)
              (and
                (compiler-ir-zip-use value a-callee b-callee ,@value-tail)
                (compiler-ir-zip-use args a-args b-args ,@value-tail)
                (compiler-ir-zip-type a-ty b-ty ,@type-tail))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.Switch
            a-index
            a-base
            a-cases
            a-default-label)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.Switch
                b-index
                b-base
                b-cases
                b-default-label)
              (and
                (compiler-ir-zip-use value a-index b-index ,@value-tail)
                (= a-base b-base)
                (compiler-ir-switch-case-seq-eq? a-cases b-cases)
                (= a-default-label b-default-label))]
            [_ false])]
        [(compiler_ir_types.CompilerIrInstr.TotalEnumSwitch
            a-index
            a-base
            a-cases
            a-default-label
            a-trap-label)
          (match zip-b
            [(compiler_ir_types.CompilerIrInstr.TotalEnumSwitch
                b-index
                b-base
                b-cases
                b-default-label
                b-trap-label)
              (and
                (compiler-ir-zip-use value a-index b-index ,@value-tail)
                (= a-base b-base)
                (compiler-ir-switch-case-seq-eq? a-cases b-cases)
                (= a-default-label b-default-label)
                (= a-trap-label b-trap-label))]
            [_ false])]))))

;; --- Same-program private SPMD ABI (#7405) ------------------------------------
;;
;; Construction, clone, equality, rendering, and integrity checks for
;; `CompilerIrSpmdPrivateAbi`. The checks run in three places:
;; `compiler-ir-spmd-private-abi-shape-error` on one descriptor alone,
;; `compiler-ir-spmd-private-abi-signature-error` against the helper's own
;; signature, and `compiler-ir-spmd-private-call-error` against one call's
;; payload. `compiler-ir-spmd-private-abi-program-error` composes them over a
;; whole program and also requires each same-program call to carry exactly its
;; callee's descriptor. Every message names the function or call it is about and
;; one mismatched field; none renders IR.
(compiler-ir-dense-builder
  CompilerIrSpmdPrivateParam
  CompilerIrSpmdPrivateParamSeq
  CompilerIrSpmdPrivateParamSeq
  compiler-ir-spmd-private-param-seq
  _
  _)

(define (compiler-ir-spmd-private-param-seq-ref
  [seq : (& CompilerIrSpmdPrivateParamSeq)]
  [index : i64]) : CompilerIrSpmdPrivateParam
  (compiler-ir-array-shared-view seq.slots index))

(define (compiler-ir-function-abi-private [abi : CompilerIrSpmdPrivateAbi]) : CompilerIrFunctionAbi
  (SpmdPrivate (box abi)))

(define (compiler-ir-spmd-call-origin-private [abi : CompilerIrSpmdPrivateAbi]) : CompilerIrSpmdCallOrigin
  (Private (box abi)))

(define (compiler-ir-function-abi-ordinary? [abi : CompilerIrFunctionAbi]) : bool
  (match abi
    [(Ordinary) true]
    [(SpmdPrivate _) false]))

;; The number of `Source` parameters, which is also the source parameter count.
(define (compiler-ir-spmd-private-abi-source-count
  [abi : CompilerIrSpmdPrivateAbi]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    (while (< index abi.params.len)
      (match (compiler-ir-spmd-private-param-seq-ref abi.params index)
        [(Param _ (Source _ _ _) _) (set! count (+ count 1))]
        [_ unit])
      (set! index (+ index 1)))
    count))

;; --- clone ---
(define (compiler-ir-clone-spmd-private-param
  [pools : ast.AstNodePoolContext]
  [param : CompilerIrSpmdPrivateParam]) : CompilerIrSpmdPrivateParam
  (match param
    [(Param ordinal role ty)
      (Param
        ordinal
        (match role
          [(ActiveMask) (ActiveMask)]
          [(Source source class source-ty)
            (Source
              source
              (compiler-ir-clone-spmd-value-class class)
              (compiler-ir-clone-type pools source-ty))]
          [(IndexBase) (IndexBase)])
        (compiler-ir-clone-type pools ty))]))

(define (compiler-ir-clone-spmd-private-abi
  [pools : ast.AstNodePoolContext]
  [abi : CompilerIrSpmdPrivateAbi]) : CompilerIrSpmdPrivateAbi
  (let
    [params : CompilerIrSpmdPrivateParamSeq
      (compiler-ir-spmd-private-param-seq-with-capacity abi.params.len)]
    [index : i64 0]
    (while (< index abi.params.len)
      (compiler-ir-spmd-private-param-seq-push!
        (&mut params)
        (compiler-ir-clone-spmd-private-param
          pools
          (compiler-ir-spmd-private-param-seq-ref abi.params index)))
      (set! index (+ index 1)))
    (CompilerIrSpmdPrivateAbi
      (match abi.schema
        [(V1) (V1)])
      (compiler-ir-symbol-clone abi.callee)
      (compiler-ir-clone-spmd-backend abi.backend)
      abi.lanes
      params
      (match abi.index
        [(None) (None)]
        [(ReuseSource source) (ReuseSource source)]
        [(Appended ordinal) (Appended ordinal)])
      (match abi.result
        [(Unit) (Unit)]
        [(Value class ty)
          (Value
            (compiler-ir-clone-spmd-value-class class)
            (compiler-ir-clone-type pools ty))]))))

(define (compiler-ir-clone-function-abi
  [pools : ast.AstNodePoolContext]
  [abi : CompilerIrFunctionAbi]) : CompilerIrFunctionAbi
  (match abi
    [(Ordinary) (Ordinary)]
    [(SpmdPrivate private-box)
      (compiler-ir-function-abi-private
        (compiler-ir-clone-spmd-private-abi pools (deref private-box)))]))

(define (compiler-ir-clone-spmd-call-origin
  [pools : ast.AstNodePoolContext]
  [origin : CompilerIrSpmdCallOrigin]) : CompilerIrSpmdCallOrigin
  (match origin
    [(Private private-box)
      (compiler-ir-spmd-call-origin-private
        (compiler-ir-clone-spmd-private-abi pools (deref private-box)))]
    [(Imported selected-box) (Imported (clone selected-box))]))

;; --- equality ---
(define (compiler-ir-spmd-backend-eq?
  [left : CompilerIrSpmdBackend]
  [right : CompilerIrSpmdBackend]) : bool
  (match left
    [(Scalar)
      (match right
        [(Scalar) true]
        [_ false])]
    [(Avx2)
      (match right
        [(Avx2) true]
        [_ false])]
    [(Avx512)
      (match right
        [(Avx512) true]
        [_ false])]))

(define (compiler-ir-spmd-value-class-eq?
  [left : CompilerIrSpmdValueClass]
  [right : CompilerIrSpmdValueClass]) : bool
  (match left
    [(Uniform)
      (match right
        [(Uniform) true]
        [_ false])]
    [(Varying)
      (match right
        [(Varying) true]
        [_ false])]
    [(Mask)
      (match right
        [(Mask) true]
        [_ false])]))

(define (compiler-ir-spmd-private-param-eq?
  [bases : i64]
  [left : CompilerIrSpmdPrivateParam]
  [right : CompilerIrSpmdPrivateParam]) : bool
  (match left
    [(Param left-ordinal left-role left-ty)
      (match right
        [(Param right-ordinal right-role right-ty)
          (and
            (= left-ordinal right-ordinal)
            (ast.ast-type-eq-with-seg-bases? bases left-ty right-ty)
            (match left-role
              [(ActiveMask)
                (match right-role
                  [(ActiveMask) true]
                  [_ false])]
              [(IndexBase)
                (match right-role
                  [(IndexBase) true]
                  [_ false])]
              [(Source left-source left-class left-source-ty)
                (match right-role
                  [(Source right-source right-class right-source-ty)
                    (and
                      (= left-source right-source)
                      (compiler-ir-spmd-value-class-eq? left-class right-class)
                      (ast.ast-type-eq-with-seg-bases?
                        bases
                        left-source-ty
                        right-source-ty))]
                  [_ false])]))])]))

(define (compiler-ir-spmd-private-index-eq?
  [left : CompilerIrSpmdPrivateIndex]
  [right : CompilerIrSpmdPrivateIndex]) : bool
  (match left
    [(None)
      (match right
        [(None) true]
        [_ false])]
    [(ReuseSource left-source)
      (match right
        [(ReuseSource right-source) (= left-source right-source)]
        [_ false])]
    [(Appended left-ordinal)
      (match right
        [(Appended right-ordinal) (= left-ordinal right-ordinal)]
        [_ false])]))

(define (compiler-ir-spmd-private-result-eq?
  [bases : i64]
  [left : CompilerIrSpmdPrivateResult]
  [right : CompilerIrSpmdPrivateResult]) : bool
  (match left
    [(Unit)
      (match right
        [(Unit) true]
        [_ false])]
    [(Value left-class left-ty)
      (match right
        [(Value right-class right-ty)
          (and
            (compiler-ir-spmd-value-class-eq? left-class right-class)
            (ast.ast-type-eq-with-seg-bases? bases left-ty right-ty))]
        [_ false])]))

;; Structural equality of two descriptors, field by field. Types compare
;; structurally, not by spelling.
(define (compiler-ir-spmd-private-abi-eq?
  [bases : i64]
  [left : CompilerIrSpmdPrivateAbi]
  [right : CompilerIrSpmdPrivateAbi]) : bool
  (and
    (match left.schema
      [(V1)
        (match right.schema
          [(V1) true])])
    (compiler-ir-symbol-eq? left.callee right.callee)
    (compiler-ir-spmd-backend-eq? left.backend right.backend)
    (= left.lanes right.lanes)
    (= left.params.len right.params.len)
    (let
      [same : bool true]
      [index : i64 0]
      (while (and same (< index left.params.len))
        (set!
          same
          (compiler-ir-spmd-private-param-eq?
            bases
            (compiler-ir-spmd-private-param-seq-ref left.params index)
            (compiler-ir-spmd-private-param-seq-ref right.params index)))
        (set! index (+ index 1)))
      same)
    (compiler-ir-spmd-private-index-eq? left.index right.index)
    (compiler-ir-spmd-private-result-eq? bases left.result right.result)))

;; --- rendering ---
(define (compiler-ir-spmd-private-param-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [param : CompilerIrSpmdPrivateParam]) : String
  (match param
    [(Param ordinal role ty)
      (str_cat.str-cat
        (string.int->string ordinal)
        " "
        (match role
          [(ActiveMask) "active-mask"]
          [(IndexBase) "index-base"]
          [(Source source class source-ty)
            (str_cat.str-cat
              "source "
              (string.int->string source)
              " "
              (compiler-ir-spmd-value-class-render class)
              " "
              (compiler-ir-type-render
                structural-session
                type-segment-bases
                source-ty))])
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]))

;; One stable line of text per descriptor, shared by the function header and
;; the call. Two descriptors render identically exactly when they are equal.
(define (compiler-ir-spmd-private-abi-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [abi : CompilerIrSpmdPrivateAbi]) : String
  (let
    [buf : text_buf.TextBuf
      (text_buf.append
        (text_buf.empty)
        (str_cat.str-cat
          (match abi.schema
            [(V1) "spmd-private-v1"])
          " @"
          (compiler-ir-symbol-text abi.callee)
          " "
          (compiler-ir-spmd-backend-render abi.backend)
          " lanes "
          (string.int->string abi.lanes)
          " ["))]
    [index : i64 0]
    (while (< index abi.params.len)
      (if (> index 0)
        (set! buf (text_buf.append buf ", "))
        unit)
      (set!
        buf
        (text_buf.append
          buf
          (compiler-ir-spmd-private-param-render
            structural-session
            type-segment-bases
            (compiler-ir-spmd-private-param-seq-ref abi.params index))))
      (set! index (+ index 1)))
    (text_buf.render
      (text_buf.append
        buf
        (str_cat.str-cat
          "] index "
          (match abi.index
            [(None) "none"]
            [(ReuseSource source)
              (str_cat.str-cat "source " (string.int->string source))]
            [(Appended ordinal)
              (str_cat.str-cat "appended " (string.int->string ordinal))])
          " result "
          (match abi.result
            [(Unit) "unit"]
            [(Value class ty)
              (str_cat.str-cat
                (compiler-ir-spmd-value-class-render class)
                " "
                (compiler-ir-type-render
                  structural-session
                  type-segment-bases
                  ty))]))))))

;; --- integrity ---
(define (compiler-ir-spmd-type-bool? [ty : ast.AstType]) : bool
  (match ty
    [(Bool) true]
    [_ false]))

(define (compiler-ir-spmd-type-unit? [ty : ast.AstType]) : bool
  (match ty
    [(Unit) true]
    [_ false]))

(define (compiler-ir-spmd-type-i64? [ty : ast.AstType]) : bool
  (match ty
    [(I64) true]
    [_ false]))

(define (compiler-ir-spmd-lanes-error
  [backend : CompilerIrSpmdBackend]
  [lanes : i64]) : String
  (match backend
    [(Scalar)
      (if (= lanes 1)
        ""
        (str_cat.str-cat
          "scalar descriptor has "
          (string.int->string lanes)
          " lanes, not 1"))]
    [_
      (if (and (>= lanes 2) (<= lanes 64) (= (bit-and lanes (- lanes 1)) 0))
        ""
        (str_cat.str-cat
          (compiler-ir-spmd-backend-render backend)
          " descriptor has "
          (string.int->string lanes)
          " lanes, not a power of two from 2 to 64"))]))

(define (compiler-ir-spmd-private-param-shape-error
  [abi : CompilerIrSpmdPrivateAbi]
  [index : i64]) : String
  (match (compiler-ir-spmd-private-param-seq-ref abi.params index)
    [(Param ordinal role ty)
      (cond
        [(not (= ordinal index))
          (str_cat.str-cat
            "physical parameter "
            (string.int->string index)
            " records ordinal "
            (string.int->string ordinal))]
        [else
          (match role
            [(ActiveMask)
              (cond
                [(not (= index 0))
                  (str_cat.str-cat
                    "active mask at physical parameter "
                    (string.int->string index)
                    ", not 0")]
                [(not (compiler-ir-spmd-type-bool? ty))
                  "active mask parameter is not bool"]
                [else ""])]
            [(Source source class source-ty)
              (cond
                [(= index 0) "physical parameter 0 is not the active mask"]
                [(not (= source (- index 1)))
                  (str_cat.str-cat
                    "physical parameter "
                    (string.int->string index)
                    " maps source parameter "
                    (string.int->string source)
                    ", not "
                    (string.int->string (- index 1)))]
                [(and
                    (compiler-ir-spmd-value-class-eq? class (Mask))
                    (not
                      (compiler-ir-spmd-type-bool?
                        (compiler-ir-global-shared-view source-ty))))
                  (str_cat.str-cat
                    "mask source parameter "
                    (string.int->string source)
                    " is not bool")]
                [(and
                    (compiler-ir-spmd-value-class-eq? class (Varying))
                    (compiler-ir-spmd-type-bool? source-ty))
                  (str_cat.str-cat
                    "varying source parameter "
                    (string.int->string source)
                    " is bool; a varying bool is a mask")]
                [else ""])]
            [(IndexBase)
              (cond
                [(= index 0) "physical parameter 0 is not the active mask"]
                [(not (= index (- abi.params.len 1)))
                  (str_cat.str-cat
                    "index base at physical parameter "
                    (string.int->string index)
                    " is not the last parameter")]
                [(not (compiler-ir-spmd-type-i64? ty))
                  "index base parameter is not i64"]
                [else ""])])])]))

(define (compiler-ir-spmd-private-index-error [abi : CompilerIrSpmdPrivateAbi]) : String
  (let
    [last-index-base? : bool
      (and
        (> abi.params.len 1)
        (match (compiler-ir-spmd-private-param-seq-ref
          abi.params
          (- abi.params.len 1))
          [(Param _ (IndexBase) _) true]
          [_ false]))]
    [scalar? : bool (compiler-ir-spmd-backend-eq? abi.backend (Scalar))]
    (match abi.index
      [(None)
        (if last-index-base?
          "index base parameter without an appended index mapping"
          "")]
      [(ReuseSource source)
        (cond
          [scalar? "scalar descriptor maps a logical index"]
          [last-index-base? "index base parameter with a reused source index"]
          [(or
              (< source 0)
              (>=
                source
                (compiler-ir-spmd-private-abi-source-count
                  (compiler-ir-global-shared-view abi))))
            (str_cat.str-cat
              "reused index source parameter "
              (string.int->string source)
              " is out of range")]
          [else
            (match (compiler-ir-spmd-private-param-seq-ref
              abi.params
              (+ source 1))
              [(Param _ (Source _ class _) _)
                (if (compiler-ir-spmd-value-class-eq? class (Varying))
                  ""
                  (str_cat.str-cat
                    "reused index source parameter "
                    (string.int->string source)
                    " is not varying"))]
              [_
                (str_cat.str-cat
                  "reused index source parameter "
                  (string.int->string source)
                  " is not a source parameter")])])]
      [(Appended ordinal)
        (cond
          [scalar? "scalar descriptor maps a logical index"]
          [(not (= ordinal (- abi.params.len 1)))
            (str_cat.str-cat
              "appended index maps physical parameter "
              (string.int->string ordinal)
              ", not the last")]
          [(not last-index-base?)
            "appended index mapping without an index base parameter"]
          [else ""])])))

(define (compiler-ir-spmd-private-result-shape-error
  [result : CompilerIrSpmdPrivateResult]) : String
  (match result
    [(Unit) ""]
    [(Value class ty)
      (cond
        [(compiler-ir-spmd-type-unit? (compiler-ir-global-shared-view ty))
          "valued result has type unit"]
        [(and
            (compiler-ir-spmd-value-class-eq? class (Mask))
            (not
              (compiler-ir-spmd-type-bool? (compiler-ir-global-shared-view ty))))
          "mask result is not bool"]
        [(and
            (compiler-ir-spmd-value-class-eq? class (Varying))
            (compiler-ir-spmd-type-bool? ty))
          "varying result is bool; a varying bool is a mask"]
        [else ""])]))

;; A descriptor's own consistency, independent of any function or call: lane
;; count for the backend, the active mask first, source parameters contiguous
;; and in source order, an index base only as the last parameter and only with
;; an appended index mapping, and a result whose class fits its type.
(define (compiler-ir-spmd-private-abi-shape-error
  [abi : CompilerIrSpmdPrivateAbi]) : String
  (let
    [lanes-error : String (compiler-ir-spmd-lanes-error abi.backend abi.lanes)]
    [param-error : String ""]
    [index : i64 0]
    (cond
      [(> (string.string-length lanes-error) 0) lanes-error]
      [(< abi.params.len 1) "descriptor has no active mask parameter"]
      [else
        (while (and
          (= (string.string-length param-error) 0)
          (< index abi.params.len))
          (set!
            param-error
            (compiler-ir-spmd-private-param-shape-error
              (compiler-ir-global-shared-view abi)
              index))
          (set! index (+ index 1)))
        (if (> (string.string-length param-error) 0)
          param-error
          (let
            [index-error : String
              (compiler-ir-spmd-private-index-error
                (compiler-ir-global-shared-view abi))]
            (if (> (string.string-length index-error) 0)
              index-error
              (compiler-ir-spmd-private-result-shape-error abi.result))))])))

;; The helper side: the descriptor must be well formed, name this function, and
;; agree with the actual signature parameter by parameter and on the return type.
(define (compiler-ir-spmd-private-abi-signature-error
  [name : i64]
  [params : CompilerIrParamSeq]
  [ret : ast.AstType]
  [abi : CompilerIrSpmdPrivateAbi]) : String
  (let
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    [shape-error : String
      (compiler-ir-spmd-private-abi-shape-error
        (compiler-ir-global-shared-view abi))]
    [problem : String ""]
    [index : i64 0]
    (cond
      [(> (string.string-length shape-error) 0) (set! problem shape-error)]
      [(not (compiler-ir-symbol-eq? abi.callee name))
        (set!
          problem
          (str_cat.str-cat
            "descriptor names callee @"
            (compiler-ir-symbol-text abi.callee)))]
      [(not (= params.len abi.params.len))
        (set!
          problem
          (str_cat.str-cat
            "descriptor has "
            (string.int->string abi.params.len)
            " physical parameters, the signature has "
            (string.int->string params.len)))]
      [else
        (while (and (= (string.string-length problem) 0) (< index params.len))
          (match (compiler-ir-param-seq-ref params index)
            [(Param _ param-ty _)
              (match (compiler-ir-spmd-private-param-seq-ref abi.params index)
                [(Param _ _ abi-ty)
                  (if (ast.ast-type-eq-with-seg-bases? bases param-ty abi-ty)
                    unit
                    (set!
                      problem
                      (str_cat.str-cat
                        "physical parameter "
                        (string.int->string index)
                        " type differs from the signature")))])])
          (set! index (+ index 1)))
        (if (> (string.string-length problem) 0)
          unit
          (match abi.result
            [(Unit)
              (if (compiler-ir-spmd-type-unit? ret)
                unit
                (set! problem "unit result but the signature returns a value"))]
            [(Value _ ty)
              (if (ast.ast-type-eq-with-seg-bases? bases ret ty)
                unit
                (set! problem "result type differs from the signature"))]))])
    (if (= (string.string-length problem) 0)
      ""
      (str_cat.str-cat
        "private SPMD ABI of @"
        (compiler-ir-symbol-text name)
        ": "
        problem))))

(define (compiler-ir-spmd-private-call-arg-error
  [bases : i64]
  [abi : CompilerIrSpmdPrivateAbi]
  [args : CompilerIrSpmdCallArgSeq]
  [index : i64]) : String
  (match (array-ref args.slots index)
    [(Arg arg-class _ arg-ty)
      (match (compiler-ir-spmd-private-param-seq-ref abi.params (+ index 1))
        [(Param _ role _)
          (match role
            [(Source _ class source-ty)
              (cond
                [(not (compiler-ir-spmd-value-class-eq? arg-class class))
                  (str_cat.str-cat
                    "argument "
                    (string.int->string index)
                    " is "
                    (compiler-ir-spmd-value-class-render arg-class)
                    ", the descriptor says "
                    (compiler-ir-spmd-value-class-render class))]
                [(not (ast.ast-type-eq-with-seg-bases? bases arg-ty source-ty))
                  (str_cat.str-cat
                    "argument "
                    (string.int->string index)
                    " type differs from the descriptor")]
                [else ""])]
            [(IndexBase)
              (if (and
                (compiler-ir-spmd-value-class-eq? arg-class (Uniform))
                (compiler-ir-spmd-type-i64? arg-ty))
                ""
                (str_cat.str-cat
                  "argument "
                  (string.int->string index)
                  " is not the uniform i64 index base"))]
            [(ActiveMask)
              (str_cat.str-cat
                "argument "
                (string.int->string index)
                " maps the active mask")])])]))

;; The call side: a same-program call's payload against the descriptor it
;; carries. Arguments follow the physical parameters after the active mask, in
;; order; the active mask travels separately in the payload.
(define (compiler-ir-spmd-private-call-error
  [payload : CompilerIrInstrSpmdCallPayload]
  [abi : CompilerIrSpmdPrivateAbi]) : String
  (let
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    [shape-error : String
      (compiler-ir-spmd-private-abi-shape-error
        (compiler-ir-global-shared-view abi))]
    [problem : String ""]
    [index : i64 0]
    (cond
      [(> (string.string-length shape-error) 0) (set! problem shape-error)]
      [(not (compiler-ir-symbol-eq? payload.callee abi.callee))
        (set!
          problem
          (str_cat.str-cat
            "the descriptor names callee @"
            (compiler-ir-symbol-text abi.callee)))]
      [(not (compiler-ir-spmd-backend-eq? payload.backend abi.backend))
        (set!
          problem
          (str_cat.str-cat
            "call backend "
            (compiler-ir-spmd-backend-render payload.backend)
            ", the descriptor says "
            (compiler-ir-spmd-backend-render abi.backend)))]
      [(not (= payload.lanes abi.lanes))
        (set!
          problem
          (str_cat.str-cat
            "call has "
            (string.int->string payload.lanes)
            " lanes, the descriptor "
            (string.int->string abi.lanes)))]
      [(not
          (match payload.active-mask
            [(Var _) true]
            [(Bool _) true]
            [_ false]))
        (set! problem "active mask is not a bool value")]
      [(not (= payload.args.len (- abi.params.len 1)))
        (set!
          problem
          (str_cat.str-cat
            "call has "
            (string.int->string payload.args.len)
            " arguments, the descriptor "
            (string.int->string (- abi.params.len 1))))]
      [else
        (while (and
          (= (string.string-length problem) 0)
          (< index payload.args.len))
          (set!
            problem
            (compiler-ir-spmd-private-call-arg-error
              bases
              (compiler-ir-global-shared-view abi)
              payload.args
              index))
          (set! index (+ index 1)))
        (if (> (string.string-length problem) 0)
          unit
          (match payload.result
            [(Unit)
              (match abi.result
                [(Unit) unit]
                [_ (set! problem "unit call of a valued helper")])]
            [(Value _ class ty)
              (match abi.result
                [(Unit) (set! problem "valued call of a unit helper")]
                [(Value abi-class abi-ty)
                  (cond
                    [(not (compiler-ir-spmd-value-class-eq? class abi-class))
                      (set!
                        problem
                        (str_cat.str-cat
                          "result is "
                          (compiler-ir-spmd-value-class-render class)
                          ", the descriptor says "
                          (compiler-ir-spmd-value-class-render abi-class)))]
                    [(not (ast.ast-type-eq-with-seg-bases? bases ty abi-ty))
                      (set! problem "result type differs from the descriptor")]
                    [else unit])])]))])
    (if (= (string.string-length problem) 0)
      ""
      (str_cat.str-cat
        "private SPMD call to @"
        (compiler-ir-symbol-text payload.callee)
        ": "
        problem))))

;; --- whole program ---
;; Whether any function in `functions` has symbol `name`. Only failed private
;; call lookups ask, so a valid program never pays for the scan.
(define (compiler-ir-function-seq-names?
  [functions : (& CompilerIrFunctionSeq)]
  [name : i64]) : bool
  (let
    [found : bool false]
    [index : i64 0]
    (while (and (not found) (< index functions.len))
      (match (compiler-ir-array-shared-view functions.slots index)
        [(Function function-name _ _ _ _ _)
          (set! found (compiler-ir-symbol-eq? function-name name))])
      (set! index (+ index 1)))
    found))

(define (compiler-ir-spmd-private-call-callee-error
  [functions : (& CompilerIrFunctionSeq)]
  [private-index : (& private-index ir_i64_i64_map.Map)]
  [caller : i64]
  [payload : CompilerIrInstrSpmdCallPayload]) : String
  (let
    [slot : i64
      (match (ir_i64_i64_map.get
        (& private-index)
        (compiler-ir-symbol-id payload.callee))
        [(LookupFound found) found]
        [(LookupMissing) -1])]
    [problem : String
      (match payload.origin
        [(Imported _)
          (if (>= slot 0)
            "imported call targets a same-program private helper"
            "")]
        [(Private private-box)
          (let
            [call-error : String
              (compiler-ir-spmd-private-call-error
                (compiler-ir-global-shared-view payload)
                (compiler-ir-box-shared-view private-box))]
            (cond
              [(> (string.string-length call-error) 0) call-error]
              [(< slot 0)
                (str_cat.str-cat
                  "private SPMD call to @"
                  (compiler-ir-symbol-text payload.callee)
                  (if (compiler-ir-function-seq-names? functions payload.callee)
                    ": the callee has the ordinary ABI"
                    ": no same-program private helper has that name"))]
              [else
                (match (compiler-ir-array-shared-view functions.slots slot)
                  [(Function _ _ _ _ _ function-abi)
                    (match function-abi
                      [(SpmdPrivate helper-box)
                        (if (compiler-ir-spmd-private-abi-eq?
                          (ast.ast-node-pool-reader-type-segment-bases)
                          (deref private-box)
                          (deref helper-box))
                          ""
                          (str_cat.str-cat
                            "private SPMD call to @"
                            (compiler-ir-symbol-text payload.callee)
                            ": the call's descriptor differs from the helper's"))]
                      [(Ordinary)
                        (str_cat.str-cat
                          "private SPMD call to @"
                          (compiler-ir-symbol-text payload.callee)
                          ": the callee has the ordinary ABI")])])]))])]
    (if (= (string.string-length problem) 0)
      ""
      (str_cat.str-cat "in @" (compiler-ir-symbol-text caller) ": " problem))))

(define (compiler-ir-spmd-private-instr-seq-error
  [functions : (& CompilerIrFunctionSeq)]
  [private-index : (& private-index ir_i64_i64_map.Map)]
  [caller : i64]
  [instrs : CompilerIrInstrSeq]) : String
  (let
    [problem : String ""]
    [index : i64 0]
    (while (and (= (string.string-length problem) 0) (< index instrs.len))
      (match (compiler-ir-array-shared-view instrs.slots index)
        [(SpmdCall payload-box)
          (set!
            problem
            (compiler-ir-spmd-private-call-callee-error
              functions
              private-index
              caller
              (deref payload-box)))]
        [_ unit])
      (set! index (+ index 1)))
    problem))

(define (compiler-ir-spmd-private-block-list-error
  [functions : (& CompilerIrFunctionSeq)]
  [private-index : (& private-index ir_i64_i64_map.Map)]
  [caller : i64]
  [blocks : CompilerIrBlockList]) : String
  (match blocks
    [(Array seq)
      (let
        [problem : String ""]
        [index : i64 0]
        (while (and (= (string.string-length problem) 0) (< index seq.len))
          (match (compiler-ir-array-shared-view seq.slots index)
            [(Block _ instrs)
              (set!
                problem
                (compiler-ir-spmd-private-instr-seq-error
                  functions
                  private-index
                  caller
                  instrs))])
          (set! index (+ index 1)))
        problem)]))

;; Whole-program private SPMD ABI admission. Every private helper's descriptor
;; must match its own signature; every same-program call must pass its payload
;; check and carry a descriptor structurally equal to its callee's; an imported
;; call may not target a same-program private helper. Returns "" or the first
;; problem, prefixed with the function it was found in.
(define (compiler-ir-spmd-private-abi-program-error
  [functions : (& CompilerIrFunctionSeq)]) : String
  (let
    [private-index : ir_i64_i64_map.Map (ir_i64_i64_map.with-capacity 8)]
    [problem : String ""]
    [index : i64 0]
    (while (and (= (string.string-length problem) 0) (< index functions.len))
      (match (compiler-ir-array-shared-view functions.slots index)
        [(Function name params ret _ _ function-abi)
          (match function-abi
            [(Ordinary) unit]
            [(SpmdPrivate private-box)
              (set!
                problem
                (compiler-ir-spmd-private-abi-signature-error
                  name
                  params
                  ret
                  (deref private-box)))
              (ir_i64_i64_map.insert-ref!
                (&mut private-index)
                (compiler-ir-symbol-id name)
                index)])])
      (set! index (+ index 1)))
    (set! index 0)
    (while (and (= (string.string-length problem) 0) (< index functions.len))
      (match (compiler-ir-array-shared-view functions.slots index)
        [(Function name _ _ _ blocks _)
          (set!
            problem
            (compiler-ir-spmd-private-block-list-error
              functions
              private-index
              name
              blocks))])
      (set! index (+ index 1)))
    problem))

;; Compare segments without assembling temporary strings on every optimizer
;; integrity pass. The imported catalog is immutable; successful verification
;; should not change the optimizer's allocation schedule or generated assembly.
(define (compiler-ir-spmd-call-segment-eq-at?
  [text : (& text str)]
  [start : i64]
  [segment : String]) : bool
  (let
    [length : i64 (string.string-length segment)]
    [text-length : i64 (string.string-length text)]
    [index : i64 0]
    (if (or (< start 0) (> (+ start length) text-length))
      false
      (begin
        (while (and
          (< index length)
          (=
            (string.string-ref text (+ start index))
            (string.string-ref segment index)))
          (set! index (+ index 1)))
        (= index length)))))

(define (compiler-ir-spmd-call-signature-args-end
  [signature : (& signature str)]
  [args : (& args CompilerIrSpmdCallArgSeq)]
  [bases : i64]
  [index : i64]
  [position : i64]) : i64
  (if (>= index args.len)
    position
    (match (array-ref args.slots index)
      [(Arg _ _ ty)
        (let
          [type-name : String (compiler-ir-type-name bases (clone ty))]
          [next : i64 (+ position 1 (string.string-length type-name))]
          (if (and
            (compiler-ir-spmd-call-segment-eq-at? signature position " ")
            (compiler-ir-spmd-call-segment-eq-at?
              signature
              (+ position 1)
              type-name))
            (compiler-ir-spmd-call-signature-args-end
              signature
              args
              bases
              (+ index 1)
              next)
            -1))])))

(define (compiler-ir-spmd-call-signature-valid?
  [signature : (& signature str)]
  [payload : (& payload CompilerIrInstrSpmdCallPayload)]) : bool
  (let
    [bases : i64 (ast.ast-node-pool-reader-type-segment-bases)]
    [end : i64
      (compiler-ir-spmd-call-signature-args-end
        signature
        (& payload.args)
        bases
        0
        3)]
    [result-type : String
      (match payload.result
        [(Unit) "unit"]
        [(Value _ _ ty) (compiler-ir-type-name bases (clone ty))])]
    (and
      (compiler-ir-spmd-call-segment-eq-at? signature 0 "(->")
      (compiler-ir-spmd-call-segment-eq-at? signature end " ")
      (compiler-ir-spmd-call-segment-eq-at?
        signature
        (+ end 1)
        (compiler-ir-global-shared-view result-type))
      (compiler-ir-spmd-call-segment-eq-at?
        signature
        (+ end 1 (string.string-length result-type))
        ")")
      (=
        (string.string-length signature)
        (+ end 2 (string.string-length result-type))))))

(define (compiler-ir-spmd-call-args-code-valid-from?
  [code : String]
  [args : (& args CompilerIrSpmdCallArgSeq)]
  [index : i64]) : bool
  (if (>= index args.len)
    true
    (match (array-ref args.slots index)
      [(Arg class _ _)
        (and
          (=
            (string.string-ref code index)
            (match class
              [(Uniform) 'u']
              [_ 'v']))
          (compiler-ir-spmd-call-args-code-valid-from? code args (+ index 1)))])))

;; Return an empty error when the call payload agrees with the descriptor its
;; origin carries: a same-program call's private ABI, or an imported call's
;; selected catalog row. This deliberately uses only the owned IR descriptor
;; and call payload, never loader/TLCI state. Whether a private call's
;; descriptor is its callee's is a whole-program question, answered by
;; `compiler-ir-spmd-private-abi-program-error`.
(define (compiler-ir-spmd-call-descriptor-error
  [payload : CompilerIrInstrSpmdCallPayload]) : String
  (match payload.origin
    [(Private private-box)
      (compiler-ir-spmd-private-call-error payload (deref private-box))]
    [(Imported selected-box)
      (let
        [selected : CompilerIrImportedSpmdCall (deref selected-box)]
        [backend : String
          (match payload.backend
            [(Scalar) "scalar"]
            [(Avx2) "avx2"]
            [(Avx512) "avx512"])]
        (if (and
          (> (string.string-length selected.package-owner) 0)
          (> (string.string-length selected.package-version) 0)
          (> (string.string-length selected.canonical-helper) 0)
          (compiler-ir-spmd-call-signature-valid?
            selected.signature
            (& payload))
          (string.eq selected.abi "spmd-call-v1")
          (string.eq selected.backend backend)
          (or
            (and (string.eq backend "scalar") (= payload.lanes 1))
            (and
              (string.eq backend "avx512")
              (or
                (= payload.lanes 8)
                (= payload.lanes 16)
                (= payload.lanes 32)
                (= payload.lanes 64))))
          (= selected.lanes payload.lanes)
          (= (string.string-length selected.args) payload.args.len)
          (compiler-ir-spmd-call-args-code-valid-from?
            selected.args
            (& payload.args)
            0)
          (string.eq
            selected.result
            (match payload.result
              [(Unit) "unit"]
              [(Value _ class _)
                (match class
                  [(Uniform) "u"]
                  [_ "v"])]))
          (or
            (= selected.index-param -1)
            (and
              (>= selected.index-param 0)
              (< selected.index-param payload.args.len)
              (match (array-ref payload.args.slots selected.index-param)
                [(Arg class _ ty)
                  (and
                    (match class
                      [(Varying) true]
                      [_ false])
                    (match ty
                      [(I64) true]
                      [_ false]))])))
          (=
            (string.string-length selected.link-symbol)
            (+
              4
              (string.string-length (compiler-ir-symbol-text payload.callee))))
          (compiler-ir-spmd-call-segment-eq-at? selected.link-symbol 0 "_tl_")
          (compiler-ir-spmd-call-segment-eq-at?
            selected.link-symbol
            4
            (compiler-ir-symbol-text payload.callee)))
          ""
          (str_cat.str-cat
            "IR SPMD catalog descriptor mismatch for package "
            selected.package-owner
            "@"
            selected.package-version
            " helper "
            selected.canonical-helper)))]))

(defstruct CompilerIrInstrSeq
  (slots (__tl_dyn-array CompilerIrInstr))
  (len i64))

(defenum CompilerIrBlock
  (Block i64 CompilerIrInstrSeq))

(defstruct CompilerIrBlockSeq
  (slots (__tl_dyn-array CompilerIrBlock))
  (len i64))

;; A function body's blocks in order, as one dense sequence. Recursive walkers
;; match `compiler-ir-block-list-view` with slice patterns; builders push into a
;; `CompilerIrBlockBuilder`.
(defenum CompilerIrBlockList
  (Array CompilerIrBlockSeq))

(defenum CompilerIrParam
  (Param String ast.AstType i64))

;; The control-byte prefix cannot occur in a source identifier. Keep hidden
;; ABI parameters distinct from user parameters even when users name one
;; `__sret`; optimizer ownership proofs must not rely on a spellable name.
(define (compiler-ir-hidden-sret-param-name) : String
  "\x01__sret")

(defstruct CompilerIrParamSeq
  (slots (__tl_dyn-array CompilerIrParam))
  (len i64))

(defenum CompilerIrFunction
  (Function
    i64
    CompilerIrParamSeq
    ast.AstType
    i64
    CompilerIrBlockList
    CompilerIrFunctionAbi))

(defstruct CompilerIrFunctionSeq
  (slots (__tl_dyn-array CompilerIrFunction))
  (len i64))

(defenum CompilerIrGlobal
  (Global i64 ast.AstType CompilerIrValue))

(defstruct CompilerIrGlobalSeq
  (slots (__tl_dyn-array CompilerIrGlobal))
  (len i64))

(defenum CompilerIrExtern
  ;; `name-id` is the resolved language-level identity and `source-name-id` is
  ;; its parser identity. `symbol-id` is the exact ABI/linker spelling interned
  ;; by the parser or generated-symbol owner.
  (Extern
    i64
    i64
    String
    ast.AstType
    ast.AstExternAbi
    i64
    ast.AstExternLinkInputList
    bool))

(defstruct CompilerIrExternSeq
  (slots (__tl_dyn-array CompilerIrExtern))
  (len i64))

(defenum CompilerIrProgram
  (Program CompilerIrGlobalSeq CompilerIrFunctionSeq CompilerIrExternSeq))

;; Immutable, job-owned nominal representation facts captured from lowered
;; whole-program IR before optimization. The count map uses 0 for conflicting
;; evidence, 1 for a positively known one-word nominal handle, and >=2 for a
;; register group. Absence is intentionally distinct from KnownOneWord: both an
;; absent entry and an explicit conflict query as Unknown.
(defstruct CompilerIrRepresentationIndex
  (word-counts ir_i64_i64_map.Map)
  (class-masks ir_i64_i64_map.Map))

(defenum CompilerIrRepresentationKind
  (KnownOneWord)
  (RegisterGroup i64 i64)
  (Unknown))

(define (compiler-ir-representation-index-empty) : CompilerIrRepresentationIndex
  (CompilerIrRepresentationIndex
    (ir_i64_i64_map.with-capacity 1)
    (ir_i64_i64_map.with-capacity 1)))

(define (compiler-ir-representation-index-kind-for-key
  [index : (& index CompilerIrRepresentationIndex)]
  [key : i64]) : CompilerIrRepresentationKind
  (match (ir_i64_i64_map.get (& index.word-counts) key)
    [(LookupMissing) Unknown]
    [(LookupFound count)
      (if (= count 1)
        KnownOneWord
        (if (> count 1)
          (match (ir_i64_i64_map.get (& index.class-masks) key)
            [(LookupFound mask) (RegisterGroup count mask)]
            [(LookupMissing) (RegisterGroup count 0)])
          Unknown))]))

(define (compiler-ir-representation-index-kind
  [type-segment-bases : i64]
  [index : (& index CompilerIrRepresentationIndex)]
  [ty : ast.AstType]) : CompilerIrRepresentationKind
  (match (ast.ast-aggregate-type-key type-segment-bases ty)
    [(Some key) (compiler-ir-representation-index-kind-for-key index key)]
    [(None) Unknown]))

(define (compiler-ir-value-seq-empty) : CompilerIrValueSeq
  (CompilerIrValueSeq (__tl_make-array CompilerIrValue 0) 0))

(define (compiler-ir-value-seq1 [a : CompilerIrValue]) : CompilerIrValueSeq
  (let
    [slots : (__tl_dyn-array CompilerIrValue)
      (__tl_make-array CompilerIrValue 1)]
    (set! (array-ref slots 0) a)
    (CompilerIrValueSeq slots 1)))

(define (compiler-ir-value-seq2 [a : CompilerIrValue] [b : CompilerIrValue]) : CompilerIrValueSeq
  (let
    [slots : (__tl_dyn-array CompilerIrValue)
      (__tl_make-array CompilerIrValue 2)]
    (set! (array-ref slots 0) a)
    (set! (array-ref slots 1) b)
    (CompilerIrValueSeq slots 2)))

(define (compiler-ir-value-seq3
  [a : CompilerIrValue]
  [b : CompilerIrValue]
  [c : CompilerIrValue]) : CompilerIrValueSeq
  (let
    [slots : (__tl_dyn-array CompilerIrValue)
      (__tl_make-array CompilerIrValue 3)]
    (set! (array-ref slots 0) a)
    (set! (array-ref slots 1) b)
    (set! (array-ref slots 2) c)
    (CompilerIrValueSeq slots 3)))

(define (compiler-ir-value-seq4
  [a : CompilerIrValue]
  [b : CompilerIrValue]
  [c : CompilerIrValue]
  [d : CompilerIrValue]) : CompilerIrValueSeq
  (let
    [slots : (__tl_dyn-array CompilerIrValue)
      (__tl_make-array CompilerIrValue 4)]
    (set! (array-ref slots 0) a)
    (set! (array-ref slots 1) b)
    (set! (array-ref slots 2) c)
    (set! (array-ref slots 3) d)
    (CompilerIrValueSeq slots 4)))

(define (compiler-ir-value-seq-count [values : (& values CompilerIrValueSeq)]) : i64
  values.len)

(define (compiler-ir-value-seq-ref
  [values : (& values CompilerIrValueSeq)]
  [index : i64]) : CompilerIrValue
  (compiler-ir-array-shared-view values.slots index))

(define (compiler-ir-phi-input-seq-empty) : CompilerIrPhiInputSeq
  (CompilerIrPhiInputSeq (__tl_make-array CompilerIrPhiInput 0) 0 0))

(define (compiler-ir-phi-input-seq-prepend
  [value : CompilerIrValue]
  [label : i64]
  [rest : CompilerIrPhiInputSeq]) : CompilerIrPhiInputSeq
  (let
    [count : i64 (+ rest.len 1)]
    [slots : (__tl_dyn-array CompilerIrPhiInput)
      (__tl_make-array CompilerIrPhiInput count)]
    [index : i64 0]
    (set! (array-ref slots 0) (CompilerIrPhiInput value label))
    (while (< index rest.len)
      (set!
        (array-ref slots (+ index 1))
        (compiler-ir-phi-input-seq-ref rest index))
      (set! index (+ index 1)))
    (CompilerIrPhiInputSeq slots 0 count)))

(define (compiler-ir-phi-input-seq-count
  [inputs : (& inputs CompilerIrPhiInputSeq)]) : i64
  inputs.len)

(define (compiler-ir-phi-input-seq-ref
  [inputs : (& inputs CompilerIrPhiInputSeq)]
  [index : i64]) : CompilerIrPhiInput
  (compiler-ir-array-shared-view inputs.slots (+ inputs.start index)))

;; Copy the visible inputs, preserving values and order while moving one edge.
;; A single allocation avoids the quadratic copying of recursive prepend.
(define (compiler-ir-phi-input-seq-relabel
  [inputs : CompilerIrPhiInputSeq]
  [from-label : i64]
  [to-label : i64]) : CompilerIrPhiInputSeq
  (if (<= inputs.len 0)
    (compiler-ir-phi-input-seq-empty)
    (let
      [slots : (__tl_dyn-array CompilerIrPhiInput)
        (__tl_make-array CompilerIrPhiInput inputs.len)]
      [index : i64 0]
      (while (< index inputs.len)
        (let
          [input : CompilerIrPhiInput
            (compiler-ir-phi-input-seq-ref inputs index)]
          (set!
            (array-ref slots index)
            (CompilerIrPhiInput
              input.value
              (if (= input.label from-label)
                to-label
                input.label)))
          (set! index (+ index 1))))
      (CompilerIrPhiInputSeq slots 0 inputs.len))))

(define (compiler-ir-switch-case-seq1 [a : CompilerIrSwitchCase]) : CompilerIrSwitchCaseSeq
  (let
    [slots : (__tl_dyn-array CompilerIrSwitchCase)
      (__tl_make-array CompilerIrSwitchCase 1)]
    (set! (array-ref slots 0) a)
    (CompilerIrSwitchCaseSeq slots 1)))

(define (compiler-ir-switch-case-seq2
  [a : CompilerIrSwitchCase]
  [b : CompilerIrSwitchCase]) : CompilerIrSwitchCaseSeq
  (let
    [slots : (__tl_dyn-array CompilerIrSwitchCase)
      (__tl_make-array CompilerIrSwitchCase 2)]
    (set! (array-ref slots 0) a)
    (set! (array-ref slots 1) b)
    (CompilerIrSwitchCaseSeq slots 2)))

(define (compiler-ir-switch-case-seq3
  [a : CompilerIrSwitchCase]
  [b : CompilerIrSwitchCase]
  [c : CompilerIrSwitchCase]) : CompilerIrSwitchCaseSeq
  (let
    [slots : (__tl_dyn-array CompilerIrSwitchCase)
      (__tl_make-array CompilerIrSwitchCase 3)]
    (set! (array-ref slots 0) a)
    (set! (array-ref slots 1) b)
    (set! (array-ref slots 2) c)
    (CompilerIrSwitchCaseSeq slots 3)))

(define (compiler-ir-switch-case-seq-count
  [cases : (& cases CompilerIrSwitchCaseSeq)]) : i64
  cases.len)

(define (compiler-ir-switch-case-seq-ref
  [cases : (& cases CompilerIrSwitchCaseSeq)]
  [index : i64]) : CompilerIrSwitchCase
  (compiler-ir-array-shared-view cases.slots index))

(compiler-ir-dense-builder
  CompilerIrSwitchCase
  CompilerIrSwitchCaseBuilder
  CompilerIrSwitchCaseSeq
  compiler-ir-switch-case-builder
  exact
  _)

(define (compiler-ir-instr-seq-empty) : CompilerIrInstrSeq
  (CompilerIrInstrSeq (__tl_make-array CompilerIrInstr 0) 0))

(define (compiler-ir-instr-seq1 [first : CompilerIrInstr]) : CompilerIrInstrSeq
  (let
    [slots : (__tl_dyn-array CompilerIrInstr)
      (__tl_make-array CompilerIrInstr 1)]
    (set! (array-ref slots 0) first)
    (CompilerIrInstrSeq slots 1)))

(define (compiler-ir-instr-seq2
  [first : CompilerIrInstr]
  [second : CompilerIrInstr]) : CompilerIrInstrSeq
  (let
    [slots : (__tl_dyn-array CompilerIrInstr)
      (__tl_make-array CompilerIrInstr 2)]
    (set! (array-ref slots 0) first)
    (set! (array-ref slots 1) second)
    (CompilerIrInstrSeq slots 2)))

(define (compiler-ir-instr-seq3
  [first : CompilerIrInstr]
  [second : CompilerIrInstr]
  [third : CompilerIrInstr]) : CompilerIrInstrSeq
  (let
    [slots : (__tl_dyn-array CompilerIrInstr)
      (__tl_make-array CompilerIrInstr 3)]
    (set! (array-ref slots 0) first)
    (set! (array-ref slots 1) second)
    (set! (array-ref slots 2) third)
    (CompilerIrInstrSeq slots 3)))

(define (compiler-ir-instr-seq4
  [first : CompilerIrInstr]
  [second : CompilerIrInstr]
  [third : CompilerIrInstr]
  [fourth : CompilerIrInstr]) : CompilerIrInstrSeq
  (let
    [slots : (__tl_dyn-array CompilerIrInstr)
      (__tl_make-array CompilerIrInstr 4)]
    (set! (array-ref slots 0) first)
    (set! (array-ref slots 1) second)
    (set! (array-ref slots 2) third)
    (set! (array-ref slots 3) fourth)
    (CompilerIrInstrSeq slots 4)))

(define (compiler-ir-instr-seq5
  [first : CompilerIrInstr]
  [second : CompilerIrInstr]
  [third : CompilerIrInstr]
  [fourth : CompilerIrInstr]
  [fifth : CompilerIrInstr]) : CompilerIrInstrSeq
  (let
    [slots : (__tl_dyn-array CompilerIrInstr)
      (__tl_make-array CompilerIrInstr 5)]
    (set! (array-ref slots 0) first)
    (set! (array-ref slots 1) second)
    (set! (array-ref slots 2) third)
    (set! (array-ref slots 3) fourth)
    (set! (array-ref slots 4) fifth)
    (CompilerIrInstrSeq slots 5)))

(defmacro (compiler-ir-instr-seq-count [instrs : Expr]) : Expr
  `(__tl-project-field-name ,instrs "len"))

(defmacro (compiler-ir-instr-seq-empty? [instrs : Expr]) : Expr
  `(= (__tl-project-field-name ,instrs "len") 0))

;; Internal shallow read: callers prove valid storage and index < logical len.
;; compiler-ir-array-shared-view does not perform a bounds check. Preserve its
;; inferred inline-enum element type/stride rather than rebuilding pointer casts
;; at each consumer.
(defmacro (compiler-ir-instr-seq-ref [instrs : Expr] [index : i64]) : CompilerIrInstr
  `(compiler-ir-array-shared-view
    (__tl-project-field-name ,instrs "slots")
    ,index))

(define (compiler-ir-instr-loop-dst-or
  [instr : CompilerIrInstr]
  [fallback : i64]) : i64
  (match instr
    [(Mov dst _ _) dst]
    [(Gep dst _ _ _) dst]
    [(Load dst _ _) dst]
    [(Cast dst _ _ _) dst]
    [(Bitcast dst _ _ _) dst]
    [(BinOp dst _ _ _ _) dst]
    [(UnOp dst _ _ _) dst]
    [(Phi dst _ _) dst]
    [_ fallback]))

(define (compiler-ir-instr-array-loop-dst-or
  [slots : (__tl_dyn-array CompilerIrInstr)]
  [index : i64]
  [fallback : i64]) : i64
  (compiler-ir-instr-loop-dst-or
    (compiler-ir-array-shared-view slots index)
    fallback))

(define (compiler-ir-instr-seq-loop-dst-or
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [fallback : i64]) : i64
  (compiler-ir-instr-loop-dst-or
    (compiler-ir-instr-seq-ref instrs index)
    fallback))

(define (compiler-ir-instr-return? [instr : CompilerIrInstr]) : bool
  (match instr
    [(Return _) true]
    [_ false]))

(define (compiler-ir-instr-bounds-check? [instr : CompilerIrInstr]) : bool
  (match instr
    [(BoundsCheck _ _ _) true]
    [_ false]))

(define (compiler-ir-instr-seq-phi?
  [instrs : (& instrs CompilerIrInstrSeq)]
  [index : i64]) : bool
  (match (& (array-ref instrs.slots index))
    [(Phi _ _ _) true]
    [_ false]))

(define (compiler-ir-instr-seq-bounds-check?
  [instrs : (& instrs CompilerIrInstrSeq)]
  [index : i64]) : bool
  (match (& (array-ref instrs.slots index))
    [(BoundsCheck _ _ _) true]
    [_ false]))

(defenum CompilerIrInstrScalarFact
  (Other)
  (BinOp i64 CompilerIrBinOp CompilerIrValue CompilerIrValue ast.AstType)
  (Jump i64)
  (Branch CompilerIrValue i64 i64)
  (Phi i64 CompilerIrPhiInputSeq ast.AstType))

(define (compiler-ir-instr-scalar-fact [instr : CompilerIrInstr]) : CompilerIrInstrScalarFact
  (match instr
    [(BinOp dst op lhs rhs ty) (BinOp dst op lhs rhs ty)]
    [(Jump target) (Jump target)]
    [(Branch cond yes no) (Branch cond yes no)]
    [(TotalEnumBranch cond yes no) (Branch cond yes no)]
    [(Phi dst inputs ty) (Phi dst inputs ty)]
    [_ (Other)]))

(define (compiler-ir-instr-seq-set!
  [instrs : (&mut instrs CompilerIrInstrSeq)]
  [index : i64]
  [instr : CompilerIrInstr]) : unit
  (set! (array-ref instrs.slots index) instr))

(define (compiler-ir-block [label : i64] [instrs : CompilerIrInstrSeq]) : CompilerIrBlock
  (Block label instrs))

(defmacro (compiler-ir-block-seq-count [blocks : Expr]) : Expr
  `(__tl-project-field-name ,blocks "len"))

;; Same shallow-read and logical-len precondition as compiler-ir-instr-seq-ref.
(defmacro (compiler-ir-block-seq-ref [blocks : Expr] [index : Expr]) : Expr
  `(compiler-ir-array-shared-view
    (__tl-project-field-name ,blocks "slots")
    ,index))

(define (compiler-ir-block-list-empty) : CompilerIrBlockList
  (Array (CompilerIrBlockSeq (__tl_make-array CompilerIrBlock 0) 0)))

(define (compiler-ir-block-list-seq [blocks : CompilerIrBlockList]) : CompilerIrBlockSeq
  (match blocks
    [(Array seq) seq]))

;; The live blocks as a borrowed slice, for slice-pattern walkers.
(define (compiler-ir-block-list-view [list : (& list CompilerIrBlockList)]) : (&
    list
    (Slice CompilerIrBlock))
  (match list
    [(Array seq) (slice-view seq.slots 0 seq.len)]))

(define (compiler-ir-param-seq-empty) : CompilerIrParamSeq
  (CompilerIrParamSeq (__tl_make-array CompilerIrParam 0) 0))

(define (compiler-ir-param-seq-prepend
  [param : CompilerIrParam]
  [rest : CompilerIrParamSeq]) : CompilerIrParamSeq
  (let
    [count : i64 (+ 1 rest.len)]
    [slots : (__tl_dyn-array CompilerIrParam)
      (__tl_make-array CompilerIrParam count)]
    [index : i64 0]
    (set! (array-ref slots 0) param)
    (while (< index rest.len)
      (set! (array-ref slots (+ index 1)) (array-ref rest.slots index))
      (set! index (+ index 1)))
    (CompilerIrParamSeq slots count)))

(define (compiler-ir-param-seq-append-one
  [params : CompilerIrParamSeq]
  [param : CompilerIrParam]) : CompilerIrParamSeq
  (let
    [count : i64 (+ params.len 1)]
    [slots : (__tl_dyn-array CompilerIrParam)
      (__tl_make-array CompilerIrParam count)]
    [index : i64 0]
    (while (< index params.len)
      (set! (array-ref slots index) (array-ref params.slots index))
      (set! index (+ index 1)))
    (set! (array-ref slots params.len) param)
    (CompilerIrParamSeq slots count)))

(define (compiler-ir-param-seq-count [params : (& params CompilerIrParamSeq)]) : i64
  params.len)

;; Keep the checked aggregate-array path used by the other dense IR families.
(define (compiler-ir-param-seq-ref
  [params : (& params CompilerIrParamSeq)]
  [index : i64]) : CompilerIrParam
  (compiler-ir-array-shared-view params.slots index))

(define (compiler-ir-function-seq-empty) : CompilerIrFunctionSeq
  (CompilerIrFunctionSeq (__tl_make-array CompilerIrFunction 0) 0))

(define (compiler-ir-function-seq-count
  [functions : (& functions CompilerIrFunctionSeq)]) : i64
  functions.len)

;; Keep the checked array-ref path; aggregate enum array elements need the array macro,
;; as with instruction and block sequences.
(define (compiler-ir-function-seq-ref
  [functions : (& functions CompilerIrFunctionSeq)]
  [index : i64]) : CompilerIrFunction
  (compiler-ir-array-shared-view functions.slots index))

(defstruct CompilerIrInstrBuilder
  (slots (__tl_dyn-array CompilerIrInstr))
  (len i64))

(defstruct CompilerIrValueBuilder
  (slots (__tl_dyn-array CompilerIrValue))
  (len i64))

(defstruct CompilerIrPhiInputBuilder
  (slots (__tl_dyn-array CompilerIrPhiInput))
  (len i64))

(defstruct CompilerIrBlockBuilder
  (slots (__tl_dyn-array CompilerIrBlock))
  (len i64))

(defstruct CompilerIrParamBuilder
  (slots (__tl_dyn-array CompilerIrParam))
  (len i64))

(defstruct CompilerIrFunctionBuilder
  (slots (__tl_dyn-array CompilerIrFunction))
  (len i64))

(defstruct CompilerIrGlobalBuilder
  (slots (__tl_dyn-array CompilerIrGlobal))
  (len i64))

(defstruct CompilerIrExternBuilder
  (slots (__tl_dyn-array CompilerIrExtern))
  (len i64))

(define (compiler-ir-builder-capacity [capacity : i64]) : i64
  (if (< capacity 1)
    1
    capacity))

(compiler-ir-dense-builder
  CompilerIrValue
  CompilerIrValueBuilder
  CompilerIrValueSeq
  compiler-ir-value-builder
  exact
  snapshot)

(define (compiler-ir-value-builder-append-seq!
  [builder : (&mut builder CompilerIrValueBuilder)]
  [values : CompilerIrValueSeq]) : unit
  (let
    [index : i64 0]
    (while (< index values.len)
      (compiler-ir-value-builder-push!
        builder
        (compiler-ir-value-seq-ref values index))
      (set! index (+ index 1)))))

(define (compiler-ir-value-seq-prepend
  [value : CompilerIrValue]
  [values : CompilerIrValueSeq]) : CompilerIrValueSeq
  (let
    [builder : CompilerIrValueBuilder
      (compiler-ir-value-builder-with-capacity (+ values.len 1))]
    (compiler-ir-value-builder-push! (&mut builder) value)
    (compiler-ir-value-builder-append-seq! (&mut builder) values)
    (compiler-ir-value-builder-to-seq builder)))

(define (compiler-ir-value-seq-append-one
  [values : CompilerIrValueSeq]
  [value : CompilerIrValue]) : CompilerIrValueSeq
  (let
    [builder : CompilerIrValueBuilder
      (compiler-ir-value-builder-with-capacity (+ values.len 1))]
    (compiler-ir-value-builder-append-seq! (&mut builder) values)
    (compiler-ir-value-builder-push! (&mut builder) value)
    (compiler-ir-value-builder-to-seq builder)))

(define (compiler-ir-value-seq-append
  [head : CompilerIrValueSeq]
  [tail : CompilerIrValueSeq]) : CompilerIrValueSeq
  (let
    [builder : CompilerIrValueBuilder
      (compiler-ir-value-builder-with-capacity (+ head.len tail.len))]
    (compiler-ir-value-builder-append-seq! (&mut builder) head)
    (compiler-ir-value-builder-append-seq! (&mut builder) tail)
    (compiler-ir-value-builder-to-seq builder)))

(compiler-ir-dense-builder
  CompilerIrPhiInput
  CompilerIrPhiInputBuilder
  CompilerIrPhiInputSeq
  compiler-ir-phi-input-builder
  exact-offset
  _)

(define (compiler-ir-phi-input-builder-append-seq!
  [builder : (&mut builder CompilerIrPhiInputBuilder)]
  [inputs : CompilerIrPhiInputSeq]) : unit
  (let
    [index : i64 0]
    (while (< index inputs.len)
      (compiler-ir-phi-input-builder-push!
        builder
        (compiler-ir-phi-input-seq-ref inputs index))
      (set! index (+ index 1)))))

(compiler-ir-dense-builder
  CompilerIrInstr
  CompilerIrInstrBuilder
  CompilerIrInstrSeq
  compiler-ir-instr-builder
  share
  _)

(define (compiler-ir-instr-builder-new) : CompilerIrInstrBuilder
  ;; Seed for the common small block: optimizer IR blocks are short
  ;; (entry/guard/branch fragments), so 8 covers most without a grow and
  ;; keeps the transient padding small. Capacity is invisible to the final IR
  ;; (the escape clone right-sizes every seq).
  (compiler-ir-instr-builder-with-capacity 8))

(define (compiler-ir-instr-builder-append-seq-range!
  [builder : (&mut builder CompilerIrInstrBuilder)]
  [instrs : (& instrs CompilerIrInstrSeq)]
  [start : i64]
  [end : i64]) : unit
  (let
    [index : i64 start]
    (while (< index end)
      (compiler-ir-instr-builder-push!
        builder
        (compiler-ir-instr-seq-ref instrs index))
      (set! index (+ index 1)))))

(compiler-ir-dense-builder
  CompilerIrBlock
  CompilerIrBlockBuilder
  CompilerIrBlockSeq
  compiler-ir-block-builder
  _
  _)

(define (compiler-ir-block-builder-new) : CompilerIrBlockBuilder
  ;; Seed for the common small function: most lowered functions have four
  ;; or fewer blocks, so 4 covers them without a grow and keeps the transient
  ;; padding small. Capacity is invisible to the final IR (the escape clone
  ;; right-sizes every seq).
  (compiler-ir-block-builder-with-capacity 4))

(define (compiler-ir-block-builder-append-list!
  [builder : (&mut builder CompilerIrBlockBuilder)]
  [blocks : CompilerIrBlockList]) : unit
  (match blocks
    [(Array seq)
      (let
        [index : i64 0]
        [count : i64 seq.len]
        [src : (__tl_dyn-array CompilerIrBlock) seq.slots]
        (while (< index count)
          (compiler-ir-block-builder-push!
            builder
            (compiler-ir-array-shared-view src index))
          (set! index (+ index 1))))]))

(define (compiler-ir-block-builder-append-slice!
  [builder : (&mut builder CompilerIrBlockBuilder)]
  [blocks : (& blocks (Slice CompilerIrBlock))]) : unit
  (match blocks
    [(slice) unit]
    [(slice block & rest)
      (compiler-ir-block-builder-push!
        builder
        (owned_view.compiler-owned-reference-shared-view block))
      (compiler-ir-block-builder-append-slice! builder rest)]))

(define (compiler-ir-block-builder-to-list [builder : CompilerIrBlockBuilder]) : CompilerIrBlockList
  (Array (CompilerIrBlockSeq builder.slots builder.len)))

;; Block-list literals expand to one builder and forward pushes, so each
;; expansion owns its storage. `carrier` is an unevaluated call whose arguments
;; are the blocks.
(defmacro (compiler-ir-blocks-push!
  [builder : Expr]
  [carrier : Expr]
  [index : Expr]) : unit
  (match index
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ blocks)
          (if (>= i (comptime.expr-list-length blocks))
            `unit
            `(begin
              (compiler-ir-block-builder-push!
                ,builder
                ,(comptime.expr-list-nth blocks i))
              (compiler-ir-blocks-push!
                ,builder
                ,carrier
                ,(comptime.expr-int (+ i 1)))))]
        [_ `unit])]
    [_ `unit]))

(defmacro (compiler-ir-blocks [blocks : CompilerIrBlock ...]) : CompilerIrBlockList
  `(let
    [blocks-builder
      (compiler-ir-block-builder-with-capacity
        ,(comptime.expr-int (comptime.expr-list-length blocks)))]
    (compiler-ir-blocks-push!
      (&mut blocks-builder)
      (__compiler-ir-blocks ,@blocks)
      0)
    (compiler-ir-block-builder-to-list blocks-builder)))

;; The blocks, in order, followed by every block of `tail`. The blocks are
;; evaluated first, in source order, then `tail` once.
(defmacro (compiler-ir-blocks-with-tail
  [tail : CompilerIrBlockList]
  [blocks : CompilerIrBlock ...]) : CompilerIrBlockList
  `(let
    [blocks-builder
      (compiler-ir-block-builder-with-capacity
        ,(comptime.expr-int (comptime.expr-list-length blocks)))]
    (compiler-ir-blocks-push!
      (&mut blocks-builder)
      (__compiler-ir-blocks ,@blocks)
      0)
    (compiler-ir-block-builder-append-list! (&mut blocks-builder) ,tail)
    (compiler-ir-block-builder-to-list blocks-builder)))

(compiler-ir-dense-builder
  CompilerIrParam
  CompilerIrParamBuilder
  CompilerIrParamSeq
  compiler-ir-param-builder
  share
  snapshot)

(compiler-ir-dense-builder
  CompilerIrFunction
  CompilerIrFunctionBuilder
  CompilerIrFunctionSeq
  compiler-ir-function-builder
  share
  snapshot)

(define (compiler-ir-function-builder-new) : CompilerIrFunctionBuilder
  (compiler-ir-function-builder-with-capacity 8))

(define (compiler-ir-function-builder-append-seq!
  [builder : (&mut builder CompilerIrFunctionBuilder)]
  [functions : CompilerIrFunctionSeq]) : unit
  (let
    [index : i64 0]
    (while (< index functions.len)
      (compiler-ir-function-builder-push!
        builder
        (compiler-ir-array-shared-view functions.slots index))
      (set! index (+ index 1)))))

(define (compiler-ir-function-builder-from-seq
  [functions : CompilerIrFunctionSeq]) : CompilerIrFunctionBuilder
  (let
    [builder : CompilerIrFunctionBuilder
      (compiler-ir-function-builder-with-capacity functions.len)]
    (compiler-ir-function-builder-append-seq! (&mut builder) functions)
    builder))

(define (compiler-ir-function-seq1 [func : CompilerIrFunction]) : CompilerIrFunctionSeq
  (let
    [builder : CompilerIrFunctionBuilder
      (compiler-ir-function-builder-with-capacity 1)]
    (compiler-ir-function-builder-push! (&mut builder) func)
    (compiler-ir-function-builder-to-seq builder)))

(define (compiler-ir-function-seq-prepend
  [func : CompilerIrFunction]
  [functions : CompilerIrFunctionSeq]) : CompilerIrFunctionSeq
  (let
    [builder : CompilerIrFunctionBuilder
      (compiler-ir-function-builder-with-capacity (+ functions.len 1))]
    (compiler-ir-function-builder-push! (&mut builder) func)
    (compiler-ir-function-builder-append-seq! (&mut builder) functions)
    (compiler-ir-function-builder-to-seq builder)))

(define (compiler-ir-global-seq-empty) : CompilerIrGlobalSeq
  (CompilerIrGlobalSeq (__tl_make-array CompilerIrGlobal 0) 0))

(compiler-ir-dense-builder
  CompilerIrGlobal
  CompilerIrGlobalBuilder
  CompilerIrGlobalSeq
  compiler-ir-global-builder
  share
  snapshot-seq)

(define (compiler-ir-global-builder-from-seq [globals : CompilerIrGlobalSeq]) : CompilerIrGlobalBuilder
  (let
    [builder : CompilerIrGlobalBuilder
      (compiler-ir-global-builder-with-capacity globals.len)]
    (compiler-ir-global-builder-copy-range!
      (&mut builder.slots)
      (& globals.slots)
      globals.len)
    (set! builder.len globals.len)
    builder))

(define (compiler-ir-extern-seq-empty) : CompilerIrExternSeq
  (CompilerIrExternSeq (__tl_make-array CompilerIrExtern 0) 0))

(define (compiler-ir-extern-seq1 [a : CompilerIrExtern]) : CompilerIrExternSeq
  (let
    [slots (__tl_make-array CompilerIrExtern 1)]
    (set! (array-ref slots 0) a)
    (CompilerIrExternSeq slots 1)))

(define (compiler-ir-extern-seq2 [a : CompilerIrExtern] [b : CompilerIrExtern]) : CompilerIrExternSeq
  (let
    [slots (__tl_make-array CompilerIrExtern 2)]
    (set! (array-ref slots 0) a)
    (set! (array-ref slots 1) b)
    (CompilerIrExternSeq slots 2)))

(define (compiler-ir-extern-seq4
  [a : CompilerIrExtern]
  [b : CompilerIrExtern]
  [c : CompilerIrExtern]
  [d : CompilerIrExtern]) : CompilerIrExternSeq
  (let
    [slots (__tl_make-array CompilerIrExtern 4)]
    (set! (array-ref slots 0) a)
    (set! (array-ref slots 1) b)
    (set! (array-ref slots 2) c)
    (set! (array-ref slots 3) d)
    (CompilerIrExternSeq slots 4)))

(define (compiler-ir-global-seq-count
  [globals : (& globals CompilerIrGlobalSeq)]) : i64
  globals.len)

(define (compiler-ir-global-seq-ref
  [globals : (& globals CompilerIrGlobalSeq)]
  [index : i64]) : CompilerIrGlobal
  (compiler-ir-array-shared-view globals.slots index))

(compiler-ir-dense-builder
  CompilerIrExtern
  CompilerIrExternBuilder
  CompilerIrExternSeq
  compiler-ir-extern-builder
  _
  snapshot-seq)

(define (compiler-ir-extern-builder-from-seq [externs : CompilerIrExternSeq]) : CompilerIrExternBuilder
  (let
    [builder : CompilerIrExternBuilder
      (compiler-ir-extern-builder-with-capacity externs.len)]
    (compiler-ir-extern-builder-copy-range!
      (&mut builder.slots)
      (& externs.slots)
      externs.len)
    (set! builder.len externs.len)
    builder))

(define (compiler-ir-extern-seq-count
  [externs : (& externs CompilerIrExternSeq)]) : i64
  externs.len)

(define (compiler-ir-extern-seq-ref
  [externs : (& externs CompilerIrExternSeq)]
  [index : i64]) : CompilerIrExtern
  (compiler-ir-array-shared-view externs.slots index))

(define (compiler-ir-extern-default-id
  [name-id : i64]
  [name : String]
  [ty : ast.AstType]) : CompilerIrExtern
  (Extern
    name-id
    name-id
    name
    ty
    (C)
    name-id
    (ast.ast-extern-link-input-list-new)
    false))

(define (compiler-ir-clone-value [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(Var id) (Var id)]
    [(Global name) (Global (compiler-ir-symbol-clone name))]
    [(GlobalAddr name) (GlobalAddr (compiler-ir-symbol-clone name))]
    [(Function name) (Function (compiler-ir-symbol-clone name))]
    [(I64 n) (I64 n)]
    [(F64 n) (F64 n)]
    [(Bool b) (Bool b)]
    [(Char c) (Char c)]
    [(String s) (String (string.copy s))]
    [(Bytes s) (Bytes (string.copy s))]
    [(StaticArray s) (StaticArray (string.copy s))]
    [(RuntimeGlobal init) (RuntimeGlobal (compiler-ir-symbol-clone init))]
    [(Unit) (Unit)]))

(define (compiler-ir-clone-spmd-backend [backend : CompilerIrSpmdBackend]) : CompilerIrSpmdBackend
  (match backend
    [(Scalar) (Scalar)]
    [(Avx2) (Avx2)]
    [(Avx512) (Avx512)]))

(define (compiler-ir-clone-spmd-value-class [class : CompilerIrSpmdValueClass]) : CompilerIrSpmdValueClass
  (match class
    [(Uniform) (Uniform)]
    [(Varying) (Varying)]
    [(Mask) (Mask)]))

(define (compiler-ir-clone-spmd-call-arg
  [pools : ast.AstNodePoolContext]
  [arg : CompilerIrSpmdCallArg]) : CompilerIrSpmdCallArg
  (match arg
    [(Arg class value ty)
      (Arg
        (compiler-ir-clone-spmd-value-class class)
        (compiler-ir-clone-value value)
        (compiler-ir-clone-type pools ty))]))

(define (compiler-ir-clone-spmd-call-arg-seq-fill
  [pools : ast.AstNodePoolContext]
  [src : (__tl_dyn-array CompilerIrSpmdCallArg)]
  [dst : (&mut dst (__tl_dyn-array CompilerIrSpmdCallArg))]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (set!
      (array-ref dst index)
      (compiler-ir-clone-spmd-call-arg
        pools
        (compiler-ir-array-shared-view src index)))
    (compiler-ir-clone-spmd-call-arg-seq-fill pools src dst (+ index 1) count)))

(define (compiler-ir-clone-spmd-call-arg-seq
  [pools : ast.AstNodePoolContext]
  [seq : CompilerIrSpmdCallArgSeq]) : CompilerIrSpmdCallArgSeq
  ;; A full IR clone must also deep-clone AstType. Keep this representation
  ;; traversal explicit instead of pretending the value-only SPMD mapper can
  ;; preserve metadata here.
  (let
    [count : i64 seq.len]
    [src : (__tl_dyn-array CompilerIrSpmdCallArg) seq.slots]
    [dst : (__tl_dyn-array CompilerIrSpmdCallArg)
      (__tl_make-array CompilerIrSpmdCallArg count)]
    (compiler-ir-clone-spmd-call-arg-seq-fill pools src (&mut dst) 0 count)
    (CompilerIrSpmdCallArgSeq dst count)))

(define (compiler-ir-clone-spmd-call-result
  [pools : ast.AstNodePoolContext]
  [result : CompilerIrSpmdCallResult]) : CompilerIrSpmdCallResult
  (match result
    [(Unit) (Unit)]
    [(Value dst class ty)
      (Value
        dst
        (compiler-ir-clone-spmd-value-class class)
        (compiler-ir-clone-type pools ty))]))

(define (compiler-ir-phi-input-seq-reverse-onto
  [inputs : CompilerIrPhiInputSeq]
  [acc : CompilerIrPhiInputSeq]) : CompilerIrPhiInputSeq
  (let
    [builder : CompilerIrPhiInputBuilder
      (compiler-ir-phi-input-builder-with-capacity (+ inputs.len acc.len))]
    [index : i64 (- inputs.len 1)]
    (while (>= index 0)
      (compiler-ir-phi-input-builder-push!
        (&mut builder)
        (compiler-ir-phi-input-seq-ref inputs index))
      (set! index (- index 1)))
    (compiler-ir-phi-input-builder-append-seq! (&mut builder) acc)
    (compiler-ir-phi-input-builder-to-seq builder)))

;; Deep-clone a (flattened) AstType into the CURRENT arena. The builtin
;; clone$AstType copies the i64 ty-pool child ids verbatim, which only SHARES the
;; source's ty-pool nodes. That breaks the per-function optimizer arena
;; escape: a type pushed during optimization lives in the scratch arena, so a
;; shared id dangles once the scratch is rewound. Re-pushing each child here puts
;; the cloned subtree's nodes in the (enclosing) arena current during the escape
;; clone, so the escaped function owns valid type nodes after the rewind.
;; Variants without i64 children (nullary, and the String/lifetime-carrying named
;; types) have no ty-pool ids, so the builtin clone is correct for them.
(define (compiler-ir-clone-type
  [pools : ast.AstNodePoolContext]
  [ty : ast.AstType]) : ast.AstType
  (match (ast.ast-global-shared-view ty)
    [(Func args ret)
      (Func
        (box (compiler-ir-clone-type-list pools (deref args)))
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) ret))))]
    [(Tuple elems)
      (Tuple (box (compiler-ir-clone-type-list pools (deref elems))))]
    [(Array elem len)
      (Array
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) elem)))
        len)]
    [(DynArray elem)
      (DynArray
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) elem))))]
    [(Slice elem)
      (Slice
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) elem))))]
    [(Box elem)
      (Box
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) elem))))]
    [(Region region inner)
      (Region
        region
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) inner))))]
    [(Invalidate lifetime inner)
      (Invalidate
        lifetime
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) inner))))]
    [(Ref region inner)
      (Ref
        region
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) inner))))]
    [(MutRef region inner)
      (MutRef
        region
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) inner))))]
    [(Ptr elem)
      (Ptr
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) elem))))]
    [(MutPtr elem)
      (MutPtr
        (ast.ast-node-pool-context-type-push
          pools
          (compiler-ir-clone-type
            pools
            (ast.ast-node-pool-context-type-get (& pools) elem))))]
    [_ (clone ty)]))

(define (compiler-ir-clone-type-list-into
  [pools : ast.AstNodePoolContext]
  [tys : (& tys ast.AstTypeList)]
  [out : (&mut out ast.AstTypeList)]
  [index : i64]) : unit
  (unless
    (>= index (ast.ast-type-list-len tys))
    (ast.ast-type-list-push
      out
      (ast.ast-node-pool-context-type-push
        pools
        (compiler-ir-clone-type
          pools
          (ast.ast-node-pool-context-type-get
            (& pools)
            (ast.ast-type-list-get tys index (ast.ast-type-id-fallback))))))
    (compiler-ir-clone-type-list-into pools tys out (+ index 1))))

(define (compiler-ir-clone-type-list
  [pools : ast.AstNodePoolContext]
  [tys : ast.AstTypeList]) : ast.AstTypeList
  (let
    [out : ast.AstTypeList
      (ast.ast-type-list-with-capacity (ast.ast-type-list-len (& tys)))]
    (compiler-ir-clone-type-list-into pools (& tys) (&mut out) 0)
    out))

(define (compiler-ir-clone-operand
  [_pools : ast.AstNodePoolContext]
  [_role : CompilerIrOperandRole]
  [value : CompilerIrValue]) : CompilerIrValue
  (compiler-ir-clone-value value))

;; Labels are ids; mapping them through a real function still rebuilds every
;; label container, which the clone must own.
(define (compiler-ir-clone-label
  [_pools : ast.AstNodePoolContext]
  [label : i64]) : i64
  label)

;; Deep-clone an instruction into the current arena: every value, type and
;; container is rebuilt. The SPMD origin descriptor carries its own types, so
;; SpmdCall is cloned field by field.
(define (compiler-ir-clone-instr
  [pools : ast.AstNodePoolContext]
  [instr : CompilerIrInstr]) : CompilerIrInstr
  (match (compiler-ir-global-shared-view instr)
    [(SpmdCall payload-box)
      (let
        [callee (compiler-ir-box-field-shared-view payload-box callee)]
        [backend (compiler-ir-box-field-shared-view payload-box backend)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [active-mask
          (compiler-ir-box-field-shared-view payload-box active-mask)]
        [args (compiler-ir-box-field-shared-view payload-box args)]
        [result (compiler-ir-box-field-shared-view payload-box result)]
        [origin (compiler-ir-box-field-shared-view payload-box origin)]
        (ir-instr-spmd-call-with-origin
          (compiler-ir-symbol-clone callee)
          (compiler-ir-clone-spmd-backend backend)
          lanes
          (compiler-ir-clone-value active-mask)
          (compiler-ir-clone-spmd-call-arg-seq pools args)
          (compiler-ir-clone-spmd-call-result pools result)
          (compiler-ir-clone-spmd-call-origin pools origin)))]
    [_
      (compiler-ir-instr-map
        instr
        compiler-ir-clone-operand
        _
        compiler-ir-clone-type
        compiler-ir-clone-label
        pools)]))

(define (compiler-ir-clone-instr-seq-fill
  [pools : ast.AstNodePoolContext]
  [src : (__tl_dyn-array CompilerIrInstr)]
  [dst : (&mut dst (__tl_dyn-array CompilerIrInstr))]
  [index : i64]
  [count : i64]) : unit
  (let
    [cursor : i64 index]
    (while (< cursor count)
      (set!
        (array-ref dst cursor)
        (compiler-ir-clone-instr
          pools
          (compiler-ir-array-shared-view src cursor)))
      (set! cursor (+ cursor 1)))
    unit))

(define (compiler-ir-clone-instr-seq
  [pools : ast.AstNodePoolContext]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrSeq
  (let
    [count : i64 instrs.len]
    [src : (__tl_dyn-array CompilerIrInstr) instrs.slots]
    [dst : (__tl_dyn-array CompilerIrInstr)
      (__tl_make-array CompilerIrInstr count)]
    (compiler-ir-clone-instr-seq-fill pools src (&mut dst) 0 count)
    (CompilerIrInstrSeq dst count)))

(define (compiler-ir-clone-block
  [pools : ast.AstNodePoolContext]
  [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(Block label instrs)
      (Block label (compiler-ir-clone-instr-seq pools instrs))]))

(define (compiler-ir-clone-block-list
  [pools : ast.AstNodePoolContext]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(Array seq)
      (let
        [count : i64 (compiler-ir-block-seq-count seq)]
        [out : CompilerIrBlockBuilder
          (compiler-ir-block-builder-with-capacity count)]
        [index : i64 0]
        (while (< index count)
          (compiler-ir-block-builder-push!
            (&mut out)
            (compiler-ir-clone-block
              pools
              (compiler-ir-block-seq-ref seq index)))
          (set! index (+ index 1)))
        (compiler-ir-block-builder-to-list out))]))

(define (compiler-ir-clone-param
  [pools : ast.AstNodePoolContext]
  [param : CompilerIrParam]) : CompilerIrParam
  (match param
    [(Param name ty id)
      (Param (string.copy name) (compiler-ir-clone-type pools ty) id)]))

(define (compiler-ir-clone-param-seq
  [pools : ast.AstNodePoolContext]
  [params : CompilerIrParamSeq]) : CompilerIrParamSeq
  (let
    [builder : CompilerIrParamBuilder
      (compiler-ir-param-builder-with-capacity params.len)]
    [index : i64 0]
    (while (< index params.len)
      (compiler-ir-param-builder-push!
        (&mut builder)
        (compiler-ir-clone-param pools (compiler-ir-param-seq-ref params index)))
      (set! index (+ index 1)))
    (compiler-ir-param-builder-to-seq builder)))

(define (compiler-ir-clone-function
  [pools : ast.AstNodePoolContext]
  [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(Function name params ret vars blocks function-abi)
      (Function
        (compiler-ir-symbol-clone name)
        (compiler-ir-clone-param-seq pools params)
        (compiler-ir-clone-type pools ret)
        vars
        (compiler-ir-clone-block-list pools blocks)
        (compiler-ir-clone-function-abi pools function-abi))]))

(define (compiler-ir-clone-function-seq
  [pools : ast.AstNodePoolContext]
  [functions : CompilerIrFunctionSeq]) : CompilerIrFunctionSeq
  (let
    [slots : (__tl_dyn-array CompilerIrFunction)
      (__tl_make-array CompilerIrFunction functions.len)]
    [index : i64 0]
    (while (< index functions.len)
      (set!
        (array-ref slots index)
        (compiler-ir-clone-function
          pools
          (compiler-ir-array-shared-view functions.slots index)))
      (set! index (+ index 1)))
    (CompilerIrFunctionSeq slots functions.len)))

(define (compiler-ir-clone-global
  [pools : ast.AstNodePoolContext]
  [global : CompilerIrGlobal]) : CompilerIrGlobal
  (match global
    [(Global name ty value)
      (Global
        (compiler-ir-symbol-clone name)
        (compiler-ir-clone-type pools ty)
        (compiler-ir-clone-value value))]))

(define (compiler-ir-clone-global-seq
  [pools : ast.AstNodePoolContext]
  [globals : CompilerIrGlobalSeq]) : CompilerIrGlobalSeq
  (let
    [slots : (__tl_dyn-array CompilerIrGlobal)
      (__tl_make-array CompilerIrGlobal globals.len)]
    [index : i64 0]
    (while (< index globals.len)
      (set!
        (array-ref slots index)
        (compiler-ir-clone-global
          pools
          (compiler-ir-global-seq-ref globals index)))
      (set! index (+ index 1)))
    (CompilerIrGlobalSeq slots globals.len)))

(define (compiler-ir-clone-extern
  [pools : ast.AstNodePoolContext]
  [extern : CompilerIrExtern]) : CompilerIrExtern
  (match extern
    [(Extern name-id source-name-id name ty abi symbol-id links provided)
      (Extern
        name-id
        source-name-id
        (string.copy name)
        (compiler-ir-clone-type pools ty)
        (clone abi)
        symbol-id
        (clone links)
        provided)]))

(define (compiler-ir-clone-extern-seq
  [pools : ast.AstNodePoolContext]
  [externs : CompilerIrExternSeq]) : CompilerIrExternSeq
  (let
    [slots : (__tl_dyn-array CompilerIrExtern)
      (__tl_make-array CompilerIrExtern externs.len)]
    [index : i64 0]
    (while (< index externs.len)
      (set!
        (array-ref slots index)
        (compiler-ir-clone-extern
          pools
          (compiler-ir-extern-seq-ref externs index)))
      (set! index (+ index 1)))
    (CompilerIrExternSeq slots externs.len)))

;; Relocate only the program shell whose lists are allocated by the enclosing
;; lowerer arena. Function payloads already live in lower-ir-arena and remain
;; valid until the optimizer's normal post-clone release.
(define (compiler-ir-clone-function-seq-shell [seq : CompilerIrFunctionSeq]) : CompilerIrFunctionSeq
  (let
    [count : i64 seq.len]
    [source : (__tl_dyn-array CompilerIrFunction) seq.slots]
    [dest : (__tl_dyn-array CompilerIrFunction)
      (__tl_make-array CompilerIrFunction count)]
    [i : i64 0]
    (while (< i count)
      (set! (array-ref dest i) (array-ref source i))
      (set! i (+ i 1)))
    (CompilerIrFunctionSeq dest count)))

(define (compiler-ir-clone-program-shell
  [pools : ast.AstNodePoolContext]
  [program : CompilerIrProgram]) : CompilerIrProgram
  (match program
    [(Program globals functions externs)
      (Program
        (compiler-ir-clone-global-seq pools globals)
        (compiler-ir-clone-function-seq-shell functions)
        (compiler-ir-clone-extern-seq pools externs))]))

(define (compiler-ir-type-list-render-at
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [types : (& types ast.AstTypeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-type-list-len types))
    ""
    (str_cat.str-cat
      (compiler-ir-type-render
        structural-session
        type-segment-bases
        (ast.ast-type-segment-bases-get
          type-segment-bases
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback))))
      (if (>= (+ index 1) (ast.ast-type-list-len types))
        ""
        (str_cat.str-cat
          " "
          (compiler-ir-type-list-render-at
            structural-session
            type-segment-bases
            types
            (+ index 1)))))))

(define (compiler-ir-type-list-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [types : ast.AstTypeList]) : String
  (compiler-ir-type-list-render-at
    structural-session
    type-segment-bases
    (& types)
    0))

(define (compiler-ir-lifetime-list-render-at
  [structural-session : cis.InternStructuralSessionHandle]
  [lifetimes : (& lifetimes ast.AstLifetimeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-lifetime-list-len lifetimes))
    ""
    (str_cat.str-cat
      (compiler-ir-lifetime-render
        structural-session
        (ast.ast-lifetime-list-get lifetimes index (ast.ast-lifetime-fallback)))
      (if (>= (+ index 1) (ast.ast-lifetime-list-len lifetimes))
        ""
        (str_cat.str-cat
          " "
          (compiler-ir-lifetime-list-render-at
            structural-session
            lifetimes
            (+ index 1)))))))

(define (compiler-ir-lifetime-list-render
  [structural-session : cis.InternStructuralSessionHandle]
  [lifetimes : ast.AstLifetimeList]) : String
  (compiler-ir-lifetime-list-render-at structural-session (& lifetimes) 0))

(define (compiler-ir-nominal-lifetime-render
  [structural-session : cis.InternStructuralSessionHandle]
  [name : String]
  [lifetimes : ast.AstLifetimeList]) : String
  (str_cat.str-cat
    "("
    name
    " "
    (compiler-ir-lifetime-list-render structural-session lifetimes)
    ")"))

(define (compiler-ir-lifetime-render
  [structural-session : cis.InternStructuralSessionHandle]
  [region : i64]) : String
  (if (ci.intern-renderable-id? region)
    (ci.intern-str region)
    (let
      [source-id : i64
        (cis.intern-structural-session-syntax-source-name-id-or
          structural-session
          region
          -1)]
      (if (>= source-id 0)
        (ci.intern-str source-id)
        (str_cat.str-cat "<id:" (string.int->string region) ">")))))

(define (compiler-ir-type-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [ty : ast.AstType]) : String
  (match ty
    [(I64) "i64"]
    [(I32) "i32"]
    [(I16) "i16"]
    [(I8) "i8"]
    [(U64) "u64"]
    [(U32) "u32"]
    [(U16) "u16"]
    [(U8) "u8"]
    [(F64) "f64"]
    [(F32) "f32"]
    [(Bool) "bool"]
    [(Char) "char"]
    [(String) "String"]
    [(Str) "str"]
    [(Bytes) "bytes"]
    [(Unit) "unit"]
    [(Never) "never"]
    [(Expr) "Expr"]
    [(ExprList) "ExprList"]
    [(Func args ret)
      (str_cat.str-cat
        "(-> "
        (compiler-ir-type-list-render
          structural-session
          type-segment-bases
          (deref args))
        " "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases ret))
        ")")]
    [(CFunc signature mode)
      (str_cat.str-cat
        "(CFunc "
        (ast.ast-c-function-mode-name mode)
        " "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases signature))
        ")")]
    [(Tuple elems)
      (str_cat.str-cat
        "(Tuple "
        (compiler-ir-type-list-render
          structural-session
          type-segment-bases
          (deref elems))
        ")")]
    [(Array elem count)
      (str_cat.str-cat
        "(Array "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        " "
        (string.int->string count)
        ")")]
    [(DynArray elem)
      (str_cat.str-cat
        "(__tl_dyn-array "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]
    [(Slice elem)
      (str_cat.str-cat
        "(Slice "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]
    [(Box elem)
      (str_cat.str-cat
        "(Box "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]
    [(Region region inner)
      (str_cat.str-cat
        "(Region "
        (compiler-ir-lifetime-render structural-session region)
        " "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases inner))
        ")")]
    [(Invalidate lifetime inner)
      (str_cat.str-cat
        "(Invalidate "
        (compiler-ir-lifetime-render structural-session lifetime)
        " "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases inner))
        ")")]
    [(Ref region inner)
      (str_cat.str-cat
        "(& "
        (compiler-ir-lifetime-render structural-session region)
        " "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases inner))
        ")")]
    [(MutRef region inner)
      (str_cat.str-cat
        "(&mut "
        (compiler-ir-lifetime-render structural-session region)
        " "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases inner))
        ")")]
    [(Enum name) (ast.ast-nominal-name-id-display name)]
    [(EnumArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        structural-session
        (ast.ast-nominal-name-id-display name)
        (deref lifetimes))]
    [(Struct name) (ast.ast-nominal-name-id-display name)]
    [(StructArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        structural-session
        (ast.ast-nominal-name-id-display name)
        (deref lifetimes))]
    [(Var name) (ci.intern-str name)]
    [(VarArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        structural-session
        (ci.intern-str name)
        (deref lifetimes))]
    [(Ptr elem)
      (str_cat.str-cat
        "(Ptr "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]
    [(MutPtr elem)
      (str_cat.str-cat
        "(MutPtr "
        (compiler-ir-type-render
          structural-session
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]))

(define (compiler-ir-u64-payload-render [value : u64]) : String
  (string.int->string (cast value : i64)))

(define (compiler-ir-value-render [value : CompilerIrValue]) : String
  (match value
    [(Var id) (str_cat.str-cat "%" (string.int->string id))]
    [(Global name) (str_cat.str-cat "@" (compiler-ir-symbol-text name))]
    [(GlobalAddr name) (str_cat.str-cat "&@" (compiler-ir-symbol-text name))]
    [(Function name) (str_cat.str-cat "fn@" (compiler-ir-symbol-text name))]
    [(I64 value) (string.int->string value)]
    [(F64 value)
      (str_cat.str-cat "float-bits:" (compiler-ir-u64-payload-render value))]
    [(Bool value)
      (if value
        "true"
        "false")]
    [(Char value) (string.int->string (cast value : i64))]
    [(String value) value]
    [(Bytes value)
      (str_cat.str-cat
        "<bytes:"
        (string.int->string (string.string-length value))
        ">")]
    [(RuntimeGlobal init)
      (str_cat.str-cat "runtime-init@" (compiler-ir-symbol-text init))]
    [(Unit) "unit"]
    [(StaticArray _) "<static-array>"]))

(define (compiler-ir-value-seq-render-from
  [values : CompilerIrValueSeq]
  [index : i64]) : String
  (if (>= index values.len)
    ""
    (str_cat.str-cat
      (if (= index 0)
        ""
        ", ")
      (compiler-ir-value-render (compiler-ir-value-seq-ref values index))
      (compiler-ir-value-seq-render-from values (+ index 1)))))

(define (compiler-ir-value-seq-render [values : CompilerIrValueSeq]) : String
  (compiler-ir-value-seq-render-from values 0))

(define (compiler-ir-switch-case-render [case : CompilerIrSwitchCase]) : String
  (match case
    [(Case tag label)
      (str_cat.str-cat
        (string.int->string tag)
        ":"
        (compiler-ir-label-text label))]))

(define (compiler-ir-switch-case-seq-render-from
  [cases : (& cases CompilerIrSwitchCaseSeq)]
  [index : i64]) : String
  (if (>= index cases.len)
    ""
    (str_cat.str-cat
      (if (= index 0)
        ""
        ", ")
      (compiler-ir-switch-case-render
        (compiler-ir-switch-case-seq-ref cases index))
      (compiler-ir-switch-case-seq-render-from cases (+ index 1)))))

(define (compiler-ir-switch-case-seq-render
  [cases : (& cases CompilerIrSwitchCaseSeq)]) : String
  (compiler-ir-switch-case-seq-render-from cases 0))

(define (compiler-ir-call-args-array [values : CompilerIrValueSeq]) : CompilerIrCallArgs
  (let
    [count : i64 values.len]
    [out : (__tl_dyn-array CompilerIrValue)
      (__tl_make-array CompilerIrValue count)]
    (compiler-ir-value-builder-copy-range! (&mut out) (& values.slots) count)
    (Array out)))

(define (compiler-ir-call-args-from-seq [values : CompilerIrValueSeq]) : CompilerIrCallArgs
  (cond
    [(= values.len 0) (Nil)]
    [(= values.len 1) (One (compiler-ir-value-seq-ref values 0))]
    [(= values.len 2)
      (Two
        (compiler-ir-value-seq-ref values 0)
        (compiler-ir-value-seq-ref values 1))]
    [else (compiler-ir-call-args-array values)]))

(define (compiler-ir-call-args-sret-from-seq
  [values : CompilerIrValueSeq]
  [index : i64]) : CompilerIrCallArgs
  (let
    [count : i64 values.len]
    [out : (__tl_dyn-array CompilerIrValue)
      (__tl_make-array CompilerIrValue count)]
    (compiler-ir-value-builder-copy-range! (&mut out) (& values.slots) count)
    (Sret out index)))

(define (compiler-ir-call-args-array-render
  [values : (__tl_dyn-array CompilerIrValue)]
  [index : i64]) : String
  (if (>= index (array-length values))
    ""
    (str_cat.str-cat
      (compiler-ir-value-render (compiler-ir-array-shared-view values index))
      (if (= (+ index 1) (array-length values))
        ""
        (str_cat.str-cat
          ", "
          (compiler-ir-call-args-array-render values (+ index 1)))))))

(define (compiler-ir-call-args-render [args : CompilerIrCallArgs]) : String
  (match args
    [(Nil) ""]
    [(One a) (compiler-ir-value-render a)]
    [(Two a b)
      (str_cat.str-cat
        (compiler-ir-value-render a)
        ", "
        (compiler-ir-value-render b))]
    [(Array values) (compiler-ir-call-args-array-render values 0)]
    [(Sret values index)
      (str_cat.str-cat
        "[sret arg "
        (string.int->string index)
        "] "
        (compiler-ir-call-args-array-render values 0))]))

(define (compiler-ir-call-args-count [args : CompilerIrCallArgs]) : i64
  (match args
    [(Nil) 0]
    [(One _) 1]
    [(Two _ _) 2]
    [(Array values) (array-length values)]
    [(Sret values _) (array-length values)]))

(define (compiler-ir-spmd-backend-render [backend : CompilerIrSpmdBackend]) : String
  (match backend
    [(Scalar) "scalar"]
    [(Avx2) "avx2"]
    [(Avx512) "avx512"]))

(define (compiler-ir-spmd-value-class-render [class : CompilerIrSpmdValueClass]) : String
  (match class
    [(Uniform) "uniform"]
    [(Varying) "varying"]
    [(Mask) "mask"]))

(define (compiler-ir-spmd-call-arg-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [arg : CompilerIrSpmdCallArg]) : String
  (match arg
    [(Arg class value ty)
      (str_cat.str-cat
        (compiler-ir-spmd-value-class-render class)
        " "
        (compiler-ir-value-render value)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]))

(define (compiler-ir-spmd-call-arg-seq-render-from
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [seq : CompilerIrSpmdCallArgSeq]
  [index : i64]) : String
  (let
    [count : i64 seq.len]
    [slots : (__tl_dyn-array CompilerIrSpmdCallArg)
      (compiler-ir-global-shared-view seq.slots)]
    (if (>= index count)
      ""
      (str_cat.str-cat
        (compiler-ir-spmd-call-arg-render
          structural-session
          type-segment-bases
          (compiler-ir-array-shared-view slots index))
        (if (= (+ index 1) count)
          ""
          (str_cat.str-cat
            ", "
            (compiler-ir-spmd-call-arg-seq-render-from
              structural-session
              type-segment-bases
              seq
              (+ index 1))))))))

(define (compiler-ir-spmd-call-args-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [args : CompilerIrSpmdCallArgSeq]) : String
  (compiler-ir-spmd-call-arg-seq-render-from
    structural-session
    type-segment-bases
    args
    0))

(define (compiler-ir-spmd-call-arg-seq-count
  [args : (& CompilerIrSpmdCallArgSeq)]) : i64
  args.len)

(define (compiler-ir-spmd-result-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [result : CompilerIrSpmdCallResult]) : String
  (match result
    [(Unit) "unit"]
    [(Value _ class ty)
      (str_cat.str-cat
        (compiler-ir-spmd-value-class-render class)
        " "
        (compiler-ir-type-render structural-session type-segment-bases ty))]))

(define (compiler-ir-tail-call-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [name : i64]
  [args : CompilerIrCallArgs]
  [ty : ast.AstType]) : String
  (str_cat.str-cat
    "  tailcall "
    (compiler-ir-symbol-text name)
    "("
    (compiler-ir-call-args-render args)
    ") : "
    (compiler-ir-type-render structural-session type-segment-bases ty)))

;; Origin suffix of a rendered `spmd_call`: the full private descriptor, or the
;; selected imported helper and the symbol it links to.
(define (compiler-ir-spmd-call-origin-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [origin : CompilerIrSpmdCallOrigin]) : String
  (match origin
    [(Private private-box)
      (str_cat.str-cat
        " private "
        (compiler-ir-spmd-private-abi-render
          structural-session
          type-segment-bases
          (deref private-box)))]
    [(Imported selected-box)
      (let
        [selected : CompilerIrImportedSpmdCall (deref selected-box)]
        (str_cat.str-cat
          " imported "
          selected.package-owner
          "/"
          selected.canonical-helper
          " "
          selected.abi
          " "
          selected.link-symbol))]))

(define (compiler-ir-spmd-call-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [callee : i64]
  [backend : CompilerIrSpmdBackend]
  [lanes : i64]
  [active-mask : CompilerIrValue]
  [args : CompilerIrSpmdCallArgSeq]
  [result : CompilerIrSpmdCallResult]
  [origin : CompilerIrSpmdCallOrigin]) : String
  (str_cat.str-cat
    "  spmd_call "
    (compiler-ir-symbol-text callee)
    " backend "
    (compiler-ir-spmd-backend-render backend)
    " lanes "
    (string.int->string lanes)
    " mask "
    (compiler-ir-value-render active-mask)
    "("
    (compiler-ir-spmd-call-args-render
      structural-session
      type-segment-bases
      args)
    ") : "
    (compiler-ir-spmd-result-render
      structural-session
      type-segment-bases
      result)
    (compiler-ir-spmd-call-origin-render
      structural-session
      type-segment-bases
      origin)))

(define (compiler-ir-tail-call-indirect-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [callee : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [ty : ast.AstType]) : String
  (str_cat.str-cat
    "  tailcall* "
    (compiler-ir-value-render callee)
    "("
    (compiler-ir-call-args-render args)
    ") : "
    (compiler-ir-type-render structural-session type-segment-bases ty)))

(define (compiler-ir-bin-op-render [op : CompilerIrBinOp]) : String
  (match (compiler-ir-global-shared-view op)
    [(BitAnd) "bit_and"]
    [(BitOr) "bit_or"]
    [(BitXor) "bit_xor"]
    [_ (compiler-ir-binop-name op)]))

(define (compiler-ir-un-op-render [op : CompilerIrUnOp]) : String
  (match op
    [(Neg) "neg"]
    [(Not) "not"]
    [(BitNot) "bit_not"]
    [(Sqrt) "sqrt"]
    [(BitLength) "bit_length"]))

(define (compiler-ir-mask-bin-op-render [op : CompilerIrMaskBinOp]) : String
  (match op
    [(And) "and"]
    [(Or) "or"]))

(define (compiler-ir-vector-reduce-op-render [op : CompilerIrVectorReduceOp]) : String
  (match op
    [(Sum) "sum"]
    [(Min) "min"]
    [(Max) "max"]))

(define (compiler-ir-vector-prefix-op-render [op : CompilerIrVectorPrefixOp]) : String
  (match op
    [(Sum) "sum"]
    [(Min) "min"]
    [(Max) "max"]
    [(All) "all"]
    [(Any) "any"]))

(define (compiler-ir-mask-reduce-op-render [op : CompilerIrMaskReduceOp]) : String
  (match op
    [(All) "all"]
    [(Any) "any"]))

(define (compiler-ir-dst-render [dst : i64]) : String
  (str_cat.str-cat "  %" (string.int->string dst) " = "))

(define (compiler-ir-typed-value-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [value : CompilerIrValue]
  [ty : ast.AstType]) : String
  (str_cat.str-cat
    (compiler-ir-value-render value)
    " : "
    (compiler-ir-type-render structural-session type-segment-bases ty)))

(define (compiler-ir-maybe-value-render [value : CompilerIrMaybeValue]) : String
  (match value
    [(No) ""]
    [(Some inner) (compiler-ir-value-render inner)]))

(define (compiler-ir-phi-input-seq-render-from
  [inputs : CompilerIrPhiInputSeq]
  [index : i64]) : String
  (if (>= index inputs.len)
    ""
    (let
      [input : CompilerIrPhiInput (compiler-ir-phi-input-seq-ref inputs index)]
      (str_cat.str-cat
        (if (= index 0)
          ""
          ", ")
        "["
        (compiler-ir-value-render input.value)
        ", "
        (compiler-ir-label-text input.label)
        "]"
        (compiler-ir-phi-input-seq-render-from inputs (+ index 1))))))

(define (compiler-ir-phi-input-seq-render [inputs : CompilerIrPhiInputSeq]) : String
  (compiler-ir-phi-input-seq-render-from inputs 0))

(define (compiler-ir-c-abi-return-slot-seq-render-from
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [slots : (__tl_dyn-array CompilerIrCAbiReturnSlot)]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (match (compiler-ir-array-shared-view slots index)
      [(Slot ty offset)
        (str_cat.str-cat
          (compiler-ir-type-render structural-session type-segment-bases ty)
          "@"
          (string.int->string offset)
          (if (= (+ index 1) count)
            ""
            (str_cat.str-cat
              ", "
              (compiler-ir-c-abi-return-slot-seq-render-from
                structural-session
                type-segment-bases
                slots
                (+ index 1)
                count))))])))

(define (compiler-ir-c-abi-return-slot-seq-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [slots : CompilerIrCAbiReturnSlotSeq]) : String
  (compiler-ir-c-abi-return-slot-seq-render-from
    structural-session
    type-segment-bases
    slots.slots
    0
    slots.len))

(define (compiler-ir-instr-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [instr : CompilerIrInstr]) : String
  (match instr
    [(Mov dst value ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "mov "
        (compiler-ir-typed-value-render
          structural-session
          type-segment-bases
          value
          ty))]
    [(Alloc dst ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "alloc "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(AddrOf dst src)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "addr_of %"
        (string.int->string src))]
    [(Gep dst base offset ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "gep "
        (compiler-ir-value-render base)
        ", "
        (compiler-ir-typed-value-render
          structural-session
          type-segment-bases
          offset
          ty))]
    [(Load dst source ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "load "
        (compiler-ir-typed-value-render
          structural-session
          type-segment-bases
          source
          ty))]
    [(StoreOwned ptr value ty)
      (str_cat.str-cat
        "  store_owned "
        (compiler-ir-value-render value)
        " -> "
        (compiler-ir-value-render ptr)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(StorePtr ptr value ty)
      (str_cat.str-cat
        "  store_ptr "
        (compiler-ir-value-render ptr)
        ", "
        (compiler-ir-typed-value-render
          structural-session
          type-segment-bases
          value
          ty))]
    [(CopyBytes dst src count)
      (str_cat.str-cat
        "  copy_bytes "
        (compiler-ir-value-render dst)
        ", "
        (compiler-ir-value-render src)
        ", "
        (string.int->string count))]
    [(BoundsCheck index length message)
      (str_cat.str-cat
        "  bounds_check "
        (compiler-ir-value-render index)
        ", "
        (compiler-ir-value-render length)
        " message \""
        (compiler-ir-label-text message)
        "\"")]
    [(Cast dst value from to)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "cast "
        (compiler-ir-value-render value)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases from)
        " to "
        (compiler-ir-type-render structural-session type-segment-bases to))]
    [(Bitcast dst value from to)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "bitcast "
        (compiler-ir-value-render value)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases from)
        " to "
        (compiler-ir-type-render structural-session type-segment-bases to))]
    [(BinOp dst op lhs rhs ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        (compiler-ir-bin-op-render op)
        " "
        (compiler-ir-value-render lhs)
        ", "
        (compiler-ir-typed-value-render
          structural-session
          type-segment-bases
          rhs
          ty))]
    [(UnOp dst op value ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        (compiler-ir-un-op-render op)
        " "
        (compiler-ir-typed-value-render
          structural-session
          type-segment-bases
          value
          ty))]
    [(LaneId dst lanes ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "lane_id "
        (string.int->string lanes)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(Splat dst value lanes ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "splat "
        (compiler-ir-value-render value)
        " lanes "
        (string.int->string lanes)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(VectorBinOp payload-box)
      (let
        [dst (compiler-ir-box-field-shared-view payload-box dst)]
        [op (compiler-ir-box-field-shared-view payload-box op)]
        [lhs (compiler-ir-box-field-shared-view payload-box lhs)]
        [rhs (compiler-ir-box-field-shared-view payload-box rhs)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          (compiler-ir-dst-render dst)
          "vector_"
          (compiler-ir-bin-op-render op)
          " "
          (compiler-ir-value-render lhs)
          ", "
          (compiler-ir-value-render rhs)
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(VectorPrefix payload-box)
      (let
        [dst (compiler-ir-box-field-shared-view payload-box dst)]
        [op (compiler-ir-box-field-shared-view payload-box op)]
        [src (compiler-ir-box-field-shared-view payload-box src)]
        [carry (compiler-ir-box-field-shared-view payload-box carry)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          (compiler-ir-dst-render dst)
          "vector_prefix_"
          (compiler-ir-vector-prefix-op-render op)
          " "
          (compiler-ir-value-render src)
          ", carry "
          (compiler-ir-value-render carry)
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(VectorReduce dst op value lanes ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "vector_reduce_"
        (compiler-ir-vector-reduce-op-render op)
        " "
        (compiler-ir-value-render value)
        " lanes "
        (string.int->string lanes)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(VectorCompare payload-box)
      (let
        [dst (compiler-ir-box-field-shared-view payload-box dst)]
        [op (compiler-ir-box-field-shared-view payload-box op)]
        [lhs (compiler-ir-box-field-shared-view payload-box lhs)]
        [rhs (compiler-ir-box-field-shared-view payload-box rhs)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          (compiler-ir-dst-render dst)
          "vector_compare_"
          (compiler-ir-bin-op-render op)
          " "
          (compiler-ir-value-render lhs)
          ", "
          (compiler-ir-value-render rhs)
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(MaskBinOp dst op lhs rhs lanes)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "mask_"
        (compiler-ir-mask-bin-op-render op)
        " "
        (compiler-ir-value-render lhs)
        ", "
        (compiler-ir-value-render rhs)
        " lanes "
        (string.int->string lanes))]
    [(MaskNot dst value lanes)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "mask_not "
        (compiler-ir-value-render value)
        " lanes "
        (string.int->string lanes))]
    [(MaskReduce dst op value lanes)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "mask_reduce_"
        (compiler-ir-mask-reduce-op-render op)
        " "
        (compiler-ir-value-render value)
        " lanes "
        (string.int->string lanes))]
    [(Select payload-box)
      (let
        [dst (compiler-ir-box-field-shared-view payload-box dst)]
        [mask (compiler-ir-box-field-shared-view payload-box mask)]
        [on-true (compiler-ir-box-field-shared-view payload-box on-true)]
        [on-false (compiler-ir-box-field-shared-view payload-box on-false)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          (compiler-ir-dst-render dst)
          "select "
          (compiler-ir-value-render mask)
          ", "
          (compiler-ir-value-render on-true)
          ", "
          (compiler-ir-value-render on-false)
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(VectorLoad dst base index lanes ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "vector_load "
        (compiler-ir-value-render base)
        ", "
        (compiler-ir-value-render index)
        " lanes "
        (string.int->string lanes)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(VectorStore payload-box)
      (let
        [base (compiler-ir-box-field-shared-view payload-box base)]
        [index (compiler-ir-box-field-shared-view payload-box index)]
        [value (compiler-ir-box-field-shared-view payload-box value)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          "  vector_store "
          (compiler-ir-value-render base)
          ", "
          (compiler-ir-value-render index)
          ", "
          (compiler-ir-value-render value)
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(PredicatedStore payload-box)
      (let
        [base (compiler-ir-box-field-shared-view payload-box base)]
        [index (compiler-ir-box-field-shared-view payload-box index)]
        [value (compiler-ir-box-field-shared-view payload-box value)]
        [mask (compiler-ir-box-field-shared-view payload-box mask)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          "  predicated_store "
          (compiler-ir-value-render base)
          ", "
          (compiler-ir-value-render index)
          ", "
          (compiler-ir-value-render value)
          " mask "
          (compiler-ir-value-render mask)
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(PredicatedLoad payload-box)
      (let
        [dst (compiler-ir-box-field-shared-view payload-box dst)]
        [base (compiler-ir-box-field-shared-view payload-box base)]
        [index (compiler-ir-box-field-shared-view payload-box index)]
        [mask (compiler-ir-box-field-shared-view payload-box mask)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          (compiler-ir-dst-render dst)
          "predicated_load "
          (compiler-ir-value-render base)
          ", "
          (compiler-ir-value-render index)
          " mask "
          (compiler-ir-value-render mask)
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(GatherLoad payload-box)
      (let
        [dst (compiler-ir-box-field-shared-view payload-box dst)]
        [base (compiler-ir-box-field-shared-view payload-box base)]
        [index-base (compiler-ir-box-field-shared-view payload-box index-base)]
        [index (compiler-ir-box-field-shared-view payload-box index)]
        [lane-offset
          (compiler-ir-box-field-shared-view payload-box lane-offset)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          (compiler-ir-dst-render dst)
          "gather_load "
          (compiler-ir-value-render base)
          ", "
          (compiler-ir-value-render index-base)
          ", "
          (compiler-ir-value-render index)
          " lane_offset "
          (if lane-offset
            "true"
            "false")
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(VectorShuffle payload-box)
      (let
        [dst (compiler-ir-box-field-shared-view payload-box dst)]
        [source (compiler-ir-box-field-shared-view payload-box source)]
        [selector-low
          (compiler-ir-box-field-shared-view payload-box selector-low)]
        [selector-high
          (compiler-ir-box-field-shared-view payload-box selector-high)]
        [active-lanes
          (compiler-ir-box-field-shared-view payload-box active-lanes)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [ty (compiler-ir-box-field-shared-view payload-box ty)]
        (str_cat.str-cat
          (compiler-ir-dst-render dst)
          "vector_shuffle "
          (compiler-ir-value-render source)
          ", "
          (compiler-ir-value-render selector-low)
          ", "
          (compiler-ir-maybe-value-render selector-high)
          " active "
          (compiler-ir-value-render active-lanes)
          " lanes "
          (string.int->string lanes)
          " : "
          (compiler-ir-type-render structural-session type-segment-bases ty)))]
    [(TailMask dst index length lanes)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "tail_mask "
        (compiler-ir-value-render index)
        ", "
        (compiler-ir-value-render length)
        " lanes "
        (string.int->string lanes))]
    [(EntryArgc dst)
      (str_cat.str-cat (compiler-ir-dst-render dst) "entry_argc")]
    [(EntryArgv dst)
      (str_cat.str-cat (compiler-ir-dst-render dst) "entry_argv")]
    [(EntryEnvp dst)
      (str_cat.str-cat (compiler-ir-dst-render dst) "entry_envp")]
    [(CpuId dst leaf subleaf word)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "cpuid "
        (compiler-ir-value-render leaf)
        ", "
        (compiler-ir-value-render subleaf)
        " word "
        (string.int->string word))]
    [(Xgetbv dst index)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "xgetbv "
        (compiler-ir-value-render index))]
    [(Syscall dst args)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "syscall("
        (compiler-ir-call-args-render args)
        ")")]
    [(Call dst name args ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "call "
        (compiler-ir-symbol-text name)
        "("
        (compiler-ir-call-args-render args)
        ") : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(CallIndirect dst callee args ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "call* "
        (compiler-ir-value-render callee)
        "("
        (compiler-ir-call-args-render args)
        ") : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(CallIndirectC dst callee args ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "call_c* "
        (compiler-ir-value-render callee)
        "("
        (compiler-ir-call-args-render args)
        ") : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(CallCAbiStoreResult payload-box)
      (let
        [base (compiler-ir-box-field-shared-view payload-box base)]
        [name (compiler-ir-box-field-shared-view payload-box name)]
        [args (compiler-ir-box-field-shared-view payload-box args)]
        [slots (compiler-ir-box-field-shared-view payload-box slots)]
        (str_cat.str-cat
          "  call_c_store "
          (compiler-ir-symbol-text name)
          "("
          (compiler-ir-call-args-render args)
          ") -> "
          (compiler-ir-value-render base)
          " ["
          (compiler-ir-c-abi-return-slot-seq-render
            structural-session
            type-segment-bases
            slots)
          "]"))]
    [(CallIndirectCAbiStoreResult payload-box)
      (let
        [base (compiler-ir-box-field-shared-view payload-box base)]
        [callee (compiler-ir-box-field-shared-view payload-box callee)]
        [args (compiler-ir-box-field-shared-view payload-box args)]
        [slots (compiler-ir-box-field-shared-view payload-box slots)]
        (str_cat.str-cat
          "  call_c_store* "
          (compiler-ir-value-render callee)
          "("
          (compiler-ir-call-args-render args)
          ") -> "
          (compiler-ir-value-render base)
          " ["
          (compiler-ir-c-abi-return-slot-seq-render
            structural-session
            type-segment-bases
            slots)
          "]"))]
    [(TailCall name args ty)
      (compiler-ir-tail-call-render
        structural-session
        type-segment-bases
        name
        args
        ty)]
    [(TailCallIndirect callee args ty)
      (compiler-ir-tail-call-indirect-render
        structural-session
        type-segment-bases
        callee
        args
        ty)]
    [(SpmdCall payload-box)
      (let
        [callee (compiler-ir-box-field-shared-view payload-box callee)]
        [backend (compiler-ir-box-field-shared-view payload-box backend)]
        [lanes (compiler-ir-box-field-shared-view payload-box lanes)]
        [active-mask
          (compiler-ir-box-field-shared-view payload-box active-mask)]
        [args (compiler-ir-box-field-shared-view payload-box args)]
        [result (compiler-ir-box-field-shared-view payload-box result)]
        [origin (compiler-ir-box-field-shared-view payload-box origin)]
        (compiler-ir-spmd-call-render
          structural-session
          type-segment-bases
          callee
          backend
          lanes
          active-mask
          args
          result
          origin))]
    [(Store global value ty)
      (str_cat.str-cat
        "  store @"
        (compiler-ir-symbol-text global)
        ", "
        (compiler-ir-typed-value-render
          structural-session
          type-segment-bases
          value
          ty))]
    [(Jump label) (str_cat.str-cat "  jump " (compiler-ir-label-text label))]
    [(Branch test on-true on-false)
      (str_cat.str-cat
        "  branch "
        (compiler-ir-value-render test)
        ", "
        (compiler-ir-label-text on-true)
        ", "
        (compiler-ir-label-text on-false))]
    [(TotalEnumBranch test on-true on-false)
      (str_cat.str-cat
        "  branch "
        (compiler-ir-value-render test)
        ", "
        (compiler-ir-label-text on-true)
        ", "
        (compiler-ir-label-text on-false))]
    [(Return value)
      (str_cat.str-cat "  return " (compiler-ir-maybe-value-render value))]
    [(Phi dst inputs ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "phi "
        (compiler-ir-phi-input-seq-render inputs)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(Pack dst values ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "pack ["
        (compiler-ir-value-seq-render values)
        "] : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(Word dst value index ty)
      (str_cat.str-cat
        (compiler-ir-dst-render dst)
        "word "
        (compiler-ir-value-render value)
        ", "
        (string.int->string index)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(Switch index base cases default-label)
      (str_cat.str-cat
        "  switch "
        (compiler-ir-value-render index)
        " base "
        (string.int->string base)
        " ["
        (compiler-ir-switch-case-seq-render cases)
        "] default "
        (compiler-ir-label-text default-label))]
    [(TotalEnumSwitch index base cases default-label _)
      (str_cat.str-cat
        "  switch "
        (compiler-ir-value-render index)
        " base "
        (string.int->string base)
        " ["
        (compiler-ir-switch-case-seq-render cases)
        "] default "
        (compiler-ir-label-text default-label))]))

;; Render into a segmented text buffer: appending one instruction is O(its
;; rendered size), so a full program render is linear in output bytes rather
;; than copying the remaining text once per element.
(define (compiler-ir-instr-seq-render-into
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [buf : text_buf.TextBuf]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : text_buf.TextBuf
  (if (>= index (compiler-ir-instr-seq-count instrs))
    buf
    (compiler-ir-instr-seq-render-into
      structural-session
      type-segment-bases
      (text_buf.append
        (text_buf.append
          buf
          (compiler-ir-instr-render
            structural-session
            type-segment-bases
            (compiler-ir-instr-seq-ref instrs index)))
        "\n")
      instrs
      (+ index 1))))

(define (compiler-ir-instr-seq-render-from
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : String
  (text_buf.render
    (compiler-ir-instr-seq-render-into
      structural-session
      type-segment-bases
      (text_buf.empty)
      instrs
      index)))

(define (compiler-ir-block-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [block : CompilerIrBlock]) : String
  (match block
    [(Block label instrs)
      (str_cat.str-cat
        (compiler-ir-label-text label)
        ":
"
        (compiler-ir-instr-seq-render-from
          structural-session
          type-segment-bases
          instrs
          0))]))

(define (compiler-ir-block-list-render-into
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [buf : text_buf.TextBuf]
  [blocks : (& blocks (Slice CompilerIrBlock))]) : text_buf.TextBuf
  (match blocks
    [(slice) buf]
    [(slice block)
      (text_buf.append
        buf
        (compiler-ir-block-render
          structural-session
          type-segment-bases
          (owned_view.compiler-owned-reference-shared-view block)))]
    [(slice block & rest)
      (compiler-ir-block-list-render-into
        structural-session
        type-segment-bases
        (text_buf.append
          (text_buf.append
            buf
            (compiler-ir-block-render
              structural-session
              type-segment-bases
              (owned_view.compiler-owned-reference-shared-view block)))
          "\n")
        rest)]))

(define (compiler-ir-block-list-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [blocks : CompilerIrBlockList]) : String
  (text_buf.render
    (compiler-ir-block-list-render-into
      structural-session
      type-segment-bases
      (text_buf.empty)
      (compiler-ir-block-list-view blocks))))

(define (compiler-ir-param-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [param : CompilerIrParam]) : String
  (match param
    [(Param name ty var)
      (str_cat.str-cat
        name
        "=%"
        (string.int->string var)
        ":"
        (compiler-ir-type-render structural-session type-segment-bases ty))]))

(define (compiler-ir-param-seq-render-from
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [params : CompilerIrParamSeq]
  [index : i64]) : String
  (if (>= index params.len)
    ""
    (let
      [param : CompilerIrParam (compiler-ir-param-seq-ref params index)]
      (str_cat.str-cat
        (compiler-ir-param-render structural-session type-segment-bases param)
        (if (= (+ index 1) params.len)
          ""
          (str_cat.str-cat
            ", "
            (compiler-ir-param-seq-render-from
              structural-session
              type-segment-bases
              params
              (+ index 1))))))))

(define (compiler-ir-param-seq-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [params : CompilerIrParamSeq]) : String
  (compiler-ir-param-seq-render-from
    structural-session
    type-segment-bases
    params
    0))

(define (compiler-ir-function-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [func : CompilerIrFunction]) : String
  (match func
    [(Function name params ret vars blocks function-abi)
      (str_cat.str-cat
        "function @"
        (compiler-ir-symbol-text name)
        "("
        (compiler-ir-param-seq-render
          structural-session
          type-segment-bases
          params)
        ") -> "
        (compiler-ir-type-render structural-session type-segment-bases ret)
        " vars "
        (string.int->string vars)
        (match function-abi
          [(Ordinary) ""]
          [(SpmdPrivate private-box)
            (str_cat.str-cat
              " abi "
              (compiler-ir-spmd-private-abi-render
                structural-session
                type-segment-bases
                (deref private-box)))])
        " {\n"
        (compiler-ir-block-list-render
          structural-session
          type-segment-bases
          blocks)
        "}\n")]))

(define (compiler-ir-function-seq-render-into-from
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [buf : text_buf.TextBuf]
  [functions : CompilerIrFunctionSeq]
  [index : i64]) : text_buf.TextBuf
  (if (>= index functions.len)
    buf
    (compiler-ir-function-seq-render-into-from
      structural-session
      type-segment-bases
      (let
        [rendered : text_buf.TextBuf
          (text_buf.append
            buf
            (compiler-ir-function-render
              structural-session
              type-segment-bases
              (compiler-ir-array-shared-view functions.slots index)))]
        (if (= (+ index 1) functions.len)
          rendered
          (text_buf.append rendered "\n")))
      functions
      (+ index 1))))

(define (compiler-ir-function-seq-render-into
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [buf : text_buf.TextBuf]
  [functions : CompilerIrFunctionSeq]) : text_buf.TextBuf
  (compiler-ir-function-seq-render-into-from
    structural-session
    type-segment-bases
    buf
    functions
    0))

(define (compiler-ir-global-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [global : CompilerIrGlobal]) : String
  (match global
    [(Global name ty value)
      (str_cat.str-cat
        "global @"
        (compiler-ir-symbol-text name)
        " : "
        (compiler-ir-type-render structural-session type-segment-bases ty)
        " = "
        (compiler-ir-value-render value)
        "\n")]))

(define (compiler-ir-global-seq-render-into
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [buf : text_buf.TextBuf]
  [globals : CompilerIrGlobalSeq]) : text_buf.TextBuf
  (let
    [index : i64 0]
    [out : text_buf.TextBuf buf]
    (while (< index globals.len)
      (set!
        out
        (text_buf.append
          out
          (compiler-ir-global-render
            structural-session
            type-segment-bases
            (compiler-ir-global-seq-ref globals index))))
      (set! index (+ index 1)))
    out))

(define (compiler-ir-extern-abi-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [abi : ast.AstExternAbi]) : String
  (match abi
    [(C) "c"]
    [(CVarargsOpen) "c-varargs"]
    [(CVarargsTyped ty)
      (str_cat.str-cat
        "c-varargs:"
        (compiler-ir-type-render structural-session type-segment-bases ty))]
    [(TypeLisp) "typelisp"]))

(define (compiler-ir-extern-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [extern : CompilerIrExtern]) : String
  (match extern
    [(Extern name _ symbol ty abi _ _ weak)
      (str_cat.str-cat
        "extern @"
        (compiler-ir-symbol-text name)
        " symbol \""
        symbol
        "\" : "
        (compiler-ir-type-render structural-session type-segment-bases ty)
        " abi "
        (compiler-ir-extern-abi-render
          structural-session
          type-segment-bases
          abi)
        (if weak
          " weak"
          "")
        "\n")]))

(define (compiler-ir-extern-seq-render-into
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [buf : text_buf.TextBuf]
  [externs : CompilerIrExternSeq]) : text_buf.TextBuf
  (let
    [index : i64 0]
    [out : text_buf.TextBuf buf]
    (while (< index externs.len)
      (set!
        out
        (text_buf.append
          out
          (compiler-ir-extern-render
            structural-session
            type-segment-bases
            (compiler-ir-extern-seq-ref externs index))))
      (set! index (+ index 1)))
    out))

(define (compiler-ir-program-render
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [program : CompilerIrProgram]) : String
  (match program
    [(Program globals functions externs)
      (let
        [globals-buf : text_buf.TextBuf
          (compiler-ir-global-seq-render-into
            structural-session
            type-segment-bases
            (text_buf.append (text_buf.empty) "typelisp-ir v1\n")
            (compiler-ir-global-shared-view globals))]
        [globals-sep-buf : text_buf.TextBuf
          (if (= (compiler-ir-global-seq-count globals) 0)
            globals-buf
            (text_buf.append globals-buf "\n"))]
        [externs-buf : text_buf.TextBuf
          (compiler-ir-extern-seq-render-into
            structural-session
            type-segment-bases
            globals-sep-buf
            (compiler-ir-global-shared-view externs))]
        [externs-sep-buf : text_buf.TextBuf
          (if (= (compiler-ir-extern-seq-count externs) 0)
            externs-buf
            (text_buf.append externs-buf "\n"))]
        (text_buf.render
          (compiler-ir-function-seq-render-into
            structural-session
            type-segment-bases
            externs-sep-buf
            functions)))]))

(defenum CompilerIrEffect
  (Pure)
  (MemoryRead)
  (CpuProbe)
  (MemoryWrite)
  (ControlFlow)
  (Unknown))

(define (compiler-ir-effect-eq? [a : CompilerIrEffect] [b : CompilerIrEffect]) : bool
  (match a
    [(Pure)
      (match b
        [(Pure) true]
        [_ false])]
    [(MemoryRead)
      (match b
        [(MemoryRead) true]
        [_ false])]
    [(CpuProbe)
      (match b
        [(CpuProbe) true]
        [_ false])]
    [(MemoryWrite)
      (match b
        [(MemoryWrite) true]
        [_ false])]
    [(ControlFlow)
      (match b
        [(ControlFlow) true]
        [_ false])]
    [(Unknown)
      (match b
        [(Unknown) true]
        [_ false])]))

(define (compiler-ir-effect-has-side-effect? [effect : CompilerIrEffect]) : bool
  (match effect
    [(Pure) false]
    [(MemoryRead) false]
    [(CpuProbe) true]
    [(MemoryWrite) true]
    [(ControlFlow) true]
    [(Unknown) true]))

(define (compiler-ir-effect-invalidates-cse? [effect : CompilerIrEffect]) : bool
  (match effect
    [(Pure) false]
    [_ true]))

;; Runtime call semantics are keyed by the source-symbol identities installed
;; alongside the active interner. Generated or hygienic symbols with identical
;; display text are ordinary unknown calls.
(define (compiler-ir-runtime-memory-read-id? [name : i64]) : bool
  (and
    (>= name 0)
    (or
      (= name cbi.compiler-builtin-id-tl-region-mark)
      (= name cbi.compiler-builtin-id-tl-stdin-eof-label))))

(define (compiler-ir-runtime-memory-write-id? [name : i64]) : bool
  (and
    (>= name 0)
    (or
      (compiler-ir-symbol-eq? name cbi.compiler-builtin-id-tl-alloc)
      (= name cbi.compiler-builtin-id-tl-int-to-string)
      (= name cbi.compiler-builtin-id-tl-substring)
      (= name cbi.compiler-builtin-id-tl-string-concat)
      (= name cbi.compiler-builtin-id-tl-string-concat3)
      (= name cbi.compiler-builtin-id-tl-string-concat4)
      (= name cbi.compiler-builtin-id-tl-string-concat5)
      (= name cbi.compiler-builtin-id-tl-region-reset)
      (= name cbi.compiler-builtin-id-tl-array-fill8)
      (= name cbi.compiler-builtin-id-tl-array-zero)
      (= name cbi.compiler-builtin-id-tl-mem-fill8)
      (= name cbi.compiler-builtin-id-tl-flush-stdout-label))))

(define (compiler-ir-runtime-control-flow-id? [name : i64]) : bool
  (and
    (>= name 0)
    (or
      (= name cbi.compiler-builtin-id-tl-abort-label)
      (= name cbi.compiler-builtin-id-tl-oob-abort)
      (= name cbi.compiler-builtin-id-tl-div-abort)
      (= name cbi.compiler-builtin-id-tl-shift-abort))))

(define (compiler-ir-direct-call-effect-id [name : i64]) : CompilerIrEffect
  (cond
    [(compiler-ir-runtime-memory-read-id? name) MemoryRead]
    [(compiler-ir-runtime-memory-write-id? name) MemoryWrite]
    [(compiler-ir-runtime-control-flow-id? name) ControlFlow]
    [else Unknown]))

(define (compiler-ir-instr-effect [instr : CompilerIrInstr]) : CompilerIrEffect
  (match instr
    [(Mov _ _ _) Pure]
    [(AddrOf _ _) Pure]
    [(Gep _ _ _ _) Pure]
    [(Cast _ _ _ _) Pure]
    [(Bitcast _ _ _ _) Pure]
    [(BinOp _ _ _ _ _) Pure]
    [(UnOp _ _ _ _) Pure]
    [(Phi _ _ _) Pure]
    [(LaneId _ _ _) Pure]
    [(Splat _ _ _ _) Pure]
    [(VectorBinOp _) Pure]
    [(VectorPrefix _) Pure]
    [(VectorReduce _ _ _ _ _) Pure]
    [(VectorCompare _) Pure]
    [(MaskBinOp _ _ _ _ _) Pure]
    [(MaskNot _ _ _) Pure]
    [(MaskReduce _ _ _ _) Pure]
    [(Select _) Pure]
    [(TailMask _ _ _ _) Pure]
    [(Load _ _ _) MemoryRead]
    [(StoreOwned _ _ _) MemoryWrite]
    [(VectorLoad _ _ _ _ _) MemoryRead]
    [(PredicatedLoad _) MemoryRead]
    [(GatherLoad _) MemoryRead]
    ;; Selector validation may call the standard nonreturning OOB abort path,
    ;; but the valid path falls through like an ordinary instruction. Unknown
    ;; keeps it effectful without classifying it as a CFG terminator.
    [(VectorShuffle _) Unknown]
    [(EntryArgc _) MemoryRead]
    [(EntryArgv _) MemoryRead]
    [(EntryEnvp _) MemoryRead]
    [(CpuId _ _ _ _) CpuProbe]
    [(Xgetbv _ _) CpuProbe]
    [(Syscall _ _) Unknown]
    [(Alloc _ _) MemoryWrite]
    [(StorePtr _ _ _) MemoryWrite]
    [(CopyBytes _ _ _) MemoryWrite]
    [(Store _ _ _) MemoryWrite]
    [(VectorStore _) MemoryWrite]
    [(PredicatedStore _) MemoryWrite]
    [(Call _ name _ _) (compiler-ir-direct-call-effect-id name)]
    [(CallIndirect _ _ _ _) Unknown]
    [(CallIndirectC _ _ _ _) Unknown]
    [(CallCAbiStoreResult _) Unknown]
    [(CallIndirectCAbiStoreResult payload-box) Unknown]
    [(SpmdCall _) Unknown]
    [(BoundsCheck _ _ _) ControlFlow]
    [(TailCall _ _ _) ControlFlow]
    [(Jump _) ControlFlow]
    [(Branch _ _ _) ControlFlow]
    [(TotalEnumBranch _ _ _) ControlFlow]
    [(Return _) ControlFlow]
    [(Pack _ _ _) Pure]
    [(Word _ _ _ _) Pure]
    [(TailCallIndirect _ _ _) ControlFlow]
    [(Switch _ _ _ _) ControlFlow]
    [(TotalEnumSwitch _ _ _ _ _) ControlFlow]))

;; Safe-language faults an instruction can raise. A pass that deletes, skips,
;; duplicates, reorders or runs an instruction once has to preserve them. This
;; is orthogonal to `CompilerIrEffect`: a division is effect-free but can fault.
;; Resource exhaustion is not a preserved fault, so `Alloc` is `None` and a dead
;; allocation may be deleted. Both matches below are exhaustive on purpose: a
;; new instruction or operator does not compile until it has a fault row.
(defenum CompilerIrFault
  ;; Cannot fault.
  (None)
  ;; Faults for some operand values: a zero or MIN / -1 divisor, or a shift
  ;; count outside the shifted width. A pass may prove particular operands safe.
  (Operands)
  ;; A checked failure site, which faults exactly when its check fails.
  (Check)
  ;; May fault, or not return, inside a callee.
  (Call))

(define (compiler-ir-binop-fault [op : CompilerIrBinOp]) : CompilerIrFault
  (match op
    [(Add) None]
    [(Sub) None]
    [(Mul) None]
    [(Div) Operands]
    [(Mod) Operands]
    ;; Emitted only once the divisor is proven neither zero nor MIN / -1.
    [(SafeDiv) None]
    [(SafeMod) None]
    [(Eq) None]
    [(Ne) None]
    [(Lt) None]
    [(Le) None]
    [(Gt) None]
    [(Ge) None]
    [(BitTestEq) None]
    [(BitTestNe) None]
    [(And) None]
    [(Or) None]
    [(BitAnd) None]
    [(BitOr) None]
    [(BitXor) None]
    [(Shl _) Operands]
    [(Shr _) Operands]))

;; Whether some operands make OP fault. This is the operator-level answer every
;; pass shares; a pass that proves the operands safe may still admit it.
(define (compiler-ir-binop-may-fault? [op : CompilerIrBinOp]) : bool
  (match (compiler-ir-binop-fault op)
    [(None) false]
    [_ true]))

(define (compiler-ir-instr-fault [instr : CompilerIrInstr]) : CompilerIrFault
  (match instr
    [(Mov _ _ _) None]
    [(AddrOf _ _) None]
    [(Gep _ _ _ _) None]
    [(Cast _ _ _ _) None]
    [(Bitcast _ _ _ _) None]
    [(BinOp _ op _ _ _) (compiler-ir-binop-fault op)]
    [(UnOp _ _ _ _) None]
    [(Phi _ _ _) None]
    [(LaneId _ _ _) None]
    [(Splat _ _ _ _) None]
    [(VectorBinOp payload-box)
      (compiler-ir-binop-fault
        (compiler-ir-box-field-shared-view payload-box op))]
    [(VectorPrefix _) None]
    [(VectorReduce _ _ _ _ _) None]
    [(VectorCompare _) None]
    [(MaskBinOp _ _ _ _ _) None]
    [(MaskNot _ _ _) None]
    [(MaskReduce _ _ _ _) None]
    [(Select _) None]
    [(TailMask _ _ _ _) None]
    ;; Safe code reaches a memory access only through its explicit checks.
    [(Load _ _ _) None]
    [(StoreOwned _ _ _) None]
    [(VectorLoad _ _ _ _ _) None]
    [(PredicatedLoad _) None]
    [(GatherLoad _) None]
    ;; Selector validation takes the out-of-bounds abort path.
    [(VectorShuffle _) Check]
    [(EntryArgc _) None]
    [(EntryArgv _) None]
    [(EntryEnvp _) None]
    [(CpuId _ _ _ _) None]
    [(Xgetbv _ _) None]
    [(Syscall _ _) Call]
    [(Alloc _ _) None]
    [(StorePtr _ _ _) None]
    [(CopyBytes _ _ _) None]
    [(Store _ _ _) None]
    [(VectorStore _) None]
    [(PredicatedStore _) None]
    [(Call _ _ _ _) Call]
    [(CallIndirect _ _ _ _) Call]
    [(CallIndirectC _ _ _ _) Call]
    [(CallCAbiStoreResult _) Call]
    [(CallIndirectCAbiStoreResult _) Call]
    [(SpmdCall _) Call]
    [(BoundsCheck _ _ _) Check]
    [(TailCall _ _ _) Call]
    [(Jump _) None]
    [(Branch _ _ _) None]
    [(TotalEnumBranch _ _ _) None]
    [(Return _) None]
    [(Pack _ _ _) None]
    [(Word _ _ _ _) None]
    [(TailCallIndirect _ _ _) Call]
    [(Switch _ _ _ _) None]
    [(TotalEnumSwitch _ _ _ _ _) None]))

;; Source provenance side table for the lowered IR. Kept OUTSIDE
;; `CompilerIrProgram` so the optimizer and liveness data model stay unchanged.
;; It maps an IR function's name (including generated global-init functions) to
;; the source path id and `AstSourceSpan` of the source construct that produced
;; it, so backend diagnostics can report a real line/column instead of falling
;; back to `path:1:1`.
;;
;; The table is a deterministic dense sequence keyed by function symbol ID;
;; rendering is reserved for diagnostics. Entries are appended in lowering order
;; and lookup scans newest-to-oldest.
(define compiler-debug-info-enabled : bool
  false)
(define compiler-debug-path-remap-from : String
  "")
(define compiler-debug-path-remap-to : String
  "")

(define (compiler-debug-info-set-enabled! [enabled : bool]) : unit
  (set! compiler-debug-info-enabled enabled))

(define (compiler-debug-info-enabled?) : bool
  compiler-debug-info-enabled)

;; Set with debug info under `--verify-ir`: lowering then checks every debug
;; type graph layout against the typechecker and fails on a mismatch.
(define compiler-debug-type-graph-verify : bool
  false)

(define (compiler-debug-type-graph-verify-set! [enabled : bool]) : unit
  (set! compiler-debug-type-graph-verify enabled))

(define (compiler-debug-type-graph-verify?) : bool
  compiler-debug-type-graph-verify)

(define (compiler-debug-path-remap-clear!) : unit
  (set! compiler-debug-path-remap-from "")
  (set! compiler-debug-path-remap-to ""))

;; Configure the reproducible-build mapping spelled FROM=TO. The first equals
;; sign is the separator so replacement prefixes may themselves contain `=`.
(define (compiler-debug-path-remap-set! [spec : String]) : bool
  (let
    [length : i64 (string.string-length spec)]
    [index : i64 0]
    (while (and (< index length) (not (= (string.string-ref spec index) '=')))
      (set! index (+ index 1)))
    (if (or (= index 0) (>= index length))
      false
      (begin
        (set! compiler-debug-path-remap-from (string.substring spec 0 index))
        (set!
          compiler-debug-path-remap-to
          (string.substring spec (+ index 1) (- length (+ index 1))))
        true))))

(define (compiler-debug-path-remap-enabled?) : bool
  (> (string.string-length compiler-debug-path-remap-from) 0))

(define (compiler-debug-path-remap [path : String]) : String
  (let
    [from-length : i64 (string.string-length compiler-debug-path-remap-from)]
    [path-length : i64 (string.string-length path)]
    (if (and
      (> from-length 0)
      (>= path-length from-length)
      (string.eq
        (string.substring path 0 from-length)
        compiler-debug-path-remap-from))
      (str_cat.str-cat
        (string.copy (& compiler-debug-path-remap-to))
        (string.substring path from-length (- path-length from-length))
        "")
      path)))

(defstruct CompilerSourceLocation
  (path-id i64)
  (span ast.AstSourceSpan))

(defenum CompilerMaybeSourceLocation
  (No)
  (Some CompilerSourceLocation))

;; A function's span: its symbol, the source path id and the span. Entries are
;; plain inline records, so a slot costs exactly its fields.
(defstruct CompilerSourceSpansEntry
  (name CompilerIrSymbolId)
  (path-id i64)
  (span ast.AstSourceSpan))

(defstruct CompilerSourceSpansEntryList
  (slots (__tl_dyn-array CompilerSourceSpansEntry))
  (len i64))

;; Instruction spans are keyed by typed function symbols instead of rendered
;; strings: a value entry is (function symbol id, function-local destination
;; var id), and a store entry is (function symbol id, function-local stored
;; name id). Bounds success labels are likewise function-local. The wrapper
;; keeps the function identity out of the raw structural/sentinel lane while
;; preserving the three-word enum layout. Building and comparing these keys
;; costs a couple of integer moves where the string keys cost an int->string,
;; three appends, an allocation, and byte-wise equality per probed entry.
;; Refs #5142 and #5139.
(defenum CompilerSourceSpansInstrKey
  (Value CompilerIrSymbolId i64)
  (Store CompilerIrSymbolId i64)
  ;; Bounds checks have no destination value; their fresh success label is
  ;; unique within the function and remains stable through optimization.
  (Bounds CompilerIrSymbolId i64))

(define (compiler-source-spans-instr-key-size) : i64
  (comptime (size-of (type CompilerSourceSpansInstrKey))))

;; An instruction's span. The key is stored flat -- its function, its value,
;; name or label id, and its variant as `kind` -- so the record's 44 bytes of
;; fields fill a 48-byte slot instead of a 24-byte tagged key plus the rest.
(defstruct CompilerSourceSpansInstrEntry
  (function CompilerIrSymbolId)
  (id i64)
  (path-id i64)
  (span ast.AstSourceSpan)
  (kind i32))

;; `kind` values of the key variants.
(define (compiler-source-spans-instr-kind-value) : i32
  (cast 0 : i32))

(define (compiler-source-spans-instr-kind-store) : i32
  (cast 1 : i32))

(define (compiler-source-spans-instr-kind-bounds) : i32
  (cast 2 : i32))

(define (compiler-source-spans-instr-entry
  [key : CompilerSourceSpansInstrKey]
  [path-id : i64]
  [span : ast.AstSourceSpan]) : CompilerSourceSpansInstrEntry
  (match key
    [(Value function id)
      (CompilerSourceSpansInstrEntry
        function
        id
        path-id
        span
        (compiler-source-spans-instr-kind-value))]
    [(Store function id)
      (CompilerSourceSpansInstrEntry
        function
        id
        path-id
        span
        (compiler-source-spans-instr-kind-store))]
    [(Bounds function id)
      (CompilerSourceSpansInstrEntry
        function
        id
        path-id
        span
        (compiler-source-spans-instr-kind-bounds))]))

(define (compiler-source-spans-instr-entry-key
  [entry : (& entry CompilerSourceSpansInstrEntry)]) : CompilerSourceSpansInstrKey
  (cond
    [(= entry.kind (compiler-source-spans-instr-kind-value))
      (Value (CompilerIrSymbolId entry.function.value) entry.id)]
    [(= entry.kind (compiler-source-spans-instr-kind-store))
      (Store (CompilerIrSymbolId entry.function.value) entry.id)]
    [else (Bounds (CompilerIrSymbolId entry.function.value) entry.id)]))

(defstruct CompilerSourceSpansInstrEntryList
  (slots (__tl_dyn-array CompilerSourceSpansInstrEntry))
  (len i64))

(defenum CompilerSourceSpans
  (Spans CompilerSourceSpansEntryList CompilerSourceSpansInstrEntryList i64))

(defenum CompilerMaybeSourceSpan
  (No)
  (Some ast.AstSourceSpan))

(define (compiler-maybe-source-location-span
  [location : CompilerMaybeSourceLocation]) : CompilerMaybeSourceSpan
  (match location
    [(No) (No)]
    [(Some found) (Some found.span)]))

(define (compiler-source-spans-entry-list-empty) : CompilerSourceSpansEntryList
  (CompilerSourceSpansEntryList (__tl_make-array CompilerSourceSpansEntry 0) 0))

(define (compiler-source-spans-instr-entry-list-empty) : CompilerSourceSpansInstrEntryList
  (CompilerSourceSpansInstrEntryList
    (__tl_make-array CompilerSourceSpansInstrEntry 0)
    0))

(define (compiler-source-spans-empty) : CompilerSourceSpans
  (Spans
    (compiler-source-spans-entry-list-empty)
    (compiler-source-spans-instr-entry-list-empty)
    0))

(define (compiler-source-spans-clear-instrs [spans : CompilerSourceSpans]) : CompilerSourceSpans
  (match spans
    [(Spans entries _ _)
      (Spans entries (compiler-source-spans-instr-entry-list-empty) 0)]))

(define (compiler-source-spans-entry-list-count
  [entries : (& entries CompilerSourceSpansEntryList)]) : i64
  entries.len)

(define (compiler-source-spans-entry-list-copy-array-range!
  [dst : (&mut dst (__tl_dyn-array CompilerSourceSpansEntry))]
  [src : (& src (__tl_dyn-array CompilerSourceSpansEntry))]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (while (< i count)
      (set! (array-ref dst i) (array-ref src i))
      (set! i (+ i 1)))))

(define (compiler-source-spans-entry-list-capacity-for [count : i64]) : i64
  (let
    [min-cap : i64
      (if (< count 4)
        4
        count)]
    [cap : i64 4]
    (while (< cap min-cap)
      (set! cap (* cap 2)))
    cap))

(define (compiler-source-spans-entry-list-append
  [entries : CompilerSourceSpansEntryList]
  [entry : CompilerSourceSpansEntry]) : CompilerSourceSpansEntryList
  (let
    [slots : (__tl_dyn-array CompilerSourceSpansEntry) entries.slots]
    [len : i64 entries.len]
    [cap : i64 (array-length slots)]
    (if (< len cap)
      (begin
        (set! (array-ref slots len) entry)
        (CompilerSourceSpansEntryList slots (+ len 1)))
      (let
        [new-cap : i64
          (compiler-source-spans-entry-list-capacity-for (+ len 1))]
        [bigger : (__tl_dyn-array CompilerSourceSpansEntry)
          (__tl_make-array CompilerSourceSpansEntry new-cap)]
        (compiler-source-spans-entry-list-copy-array-range!
          (&mut bigger)
          (& slots)
          0
          len)
        (set! (array-ref bigger len) entry)
        (CompilerSourceSpansEntryList bigger (+ len 1))))))

(define (compiler-source-spans-instr-entry-list-copy-array-range!
  [dst : (&mut dst (__tl_dyn-array CompilerSourceSpansInstrEntry))]
  [src : (& src (__tl_dyn-array CompilerSourceSpansInstrEntry))]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (while (< i count)
      (set! (array-ref dst i) (array-ref src i))
      (set! i (+ i 1)))))

(define (compiler-source-spans-instr-entry-list-append
  [entries : CompilerSourceSpansInstrEntryList]
  [entry : CompilerSourceSpansInstrEntry]) : CompilerSourceSpansInstrEntryList
  (let
    [slots : (__tl_dyn-array CompilerSourceSpansInstrEntry) entries.slots]
    [len : i64 entries.len]
    [cap : i64 (array-length slots)]
    (if (< len cap)
      (begin
        (set! (array-ref slots len) entry)
        (CompilerSourceSpansInstrEntryList slots (+ len 1)))
      (let
        [new-cap : i64
          (compiler-source-spans-entry-list-capacity-for (+ len 1))]
        [bigger : (__tl_dyn-array CompilerSourceSpansInstrEntry)
          (__tl_make-array CompilerSourceSpansInstrEntry new-cap)]
        (compiler-source-spans-instr-entry-list-copy-array-range!
          (&mut bigger)
          (& slots)
          0
          len)
        (set! (array-ref bigger len) entry)
        (CompilerSourceSpansInstrEntryList bigger (+ len 1))))))

;; --- spans escape -----------------------------------------------------------
;;
;; Copy a spans table into whichever arena is current at the call so it can
;; outlive the arena that produced it. Both entry kinds are flat inline
;; records over POD fields -- an interned symbol id or instruction key, a path
;; id, and the four i32 line/column words of `AstSourceSpan` -- in the default
;; inline layout, so duplicating the two slot arrays leaves no pointer
;; back into the source arena. Only the live prefix is copied: an escaped table
;; is handed to consumers that clear or rebuild the instruction side, never to
;; one that appends onto the retained spare capacity.
(define (compiler-source-spans-entry-list-escape
  [entries : CompilerSourceSpansEntryList]) : CompilerSourceSpansEntryList
  (let
    [slots : (__tl_dyn-array CompilerSourceSpansEntry) entries.slots]
    [len : i64 entries.len]
    [copy : (__tl_dyn-array CompilerSourceSpansEntry)
      (__tl_make-array CompilerSourceSpansEntry len)]
    (compiler-source-spans-entry-list-copy-array-range!
      (&mut copy)
      (& slots)
      0
      len)
    (CompilerSourceSpansEntryList copy len)))

(define (compiler-source-spans-instr-entry-list-escape
  [entries : CompilerSourceSpansInstrEntryList]) : CompilerSourceSpansInstrEntryList
  (let
    [slots : (__tl_dyn-array CompilerSourceSpansInstrEntry) entries.slots]
    [len : i64 entries.len]
    [copy : (__tl_dyn-array CompilerSourceSpansInstrEntry)
      (__tl_make-array CompilerSourceSpansInstrEntry len)]
    (compiler-source-spans-instr-entry-list-copy-array-range!
      (&mut copy)
      (& slots)
      0
      len)
    (CompilerSourceSpansInstrEntryList copy len)))

(define (compiler-source-spans-escape [spans : CompilerSourceSpans]) : CompilerSourceSpans
  (match spans
    [(Spans entries instr-entries instr-count)
      (Spans
        (compiler-source-spans-entry-list-escape entries)
        (compiler-source-spans-instr-entry-list-escape instr-entries)
        instr-count)]))

;; The newest entry in `slots[0, index]` whose flat key is `function`, `id`
;; and `kind`.
(define (compiler-source-spans-instr-entry-array-lookup-location
  [slots : (__tl_dyn-array CompilerSourceSpansInstrEntry)]
  [index : i64]
  [function : i64]
  [id : i64]
  [kind : i32]) : CompilerMaybeSourceLocation
  (if (< index 0)
    (No)
    (let
      [span-entry : CompilerSourceSpansInstrEntry (array-ref slots index)]
      (if (and
        (= span-entry.id id)
        (= span-entry.function.value function)
        (= span-entry.kind kind))
        (Some (CompilerSourceLocation span-entry.path-id span-entry.span))
        (compiler-source-spans-instr-entry-array-lookup-location
          slots
          (- index 1)
          function
          id
          kind)))))

(define (compiler-source-spans-instr-entry-list-lookup
  [entries : CompilerSourceSpansInstrEntryList]
  [key : CompilerSourceSpansInstrKey]) : CompilerMaybeSourceLocation
  ;; Flatten the key once; the scan compares scalars.
  (let
    [probe : CompilerSourceSpansInstrEntry
      (compiler-source-spans-instr-entry key 0 (ast.ast-source-span 0 0 0 0))]
    (compiler-source-spans-instr-entry-array-lookup-location
      entries.slots
      (- entries.len 1)
      probe.function.value
      probe.id
      probe.kind)))

;; Record `name -> span`. Function names are unique in lowered programs. The
;; dense list stores new entries at the end, and lookup scans newest-to-oldest,
;; so the most recently recorded binding wins without O(n^2) appends.
(define (compiler-source-spans-insert
  [spans : CompilerSourceSpans]
  [name : CompilerIrSymbolId]
  [span : ast.AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(Spans entries instr-entries instr-count)
      (Spans
        (compiler-source-spans-entry-list-append
          entries
          (CompilerSourceSpansEntry name 0 span))
        instr-entries
        instr-count)]))

(define (compiler-source-spans-insert-located
  [spans : CompilerSourceSpans]
  [name : CompilerIrSymbolId]
  [path-id : i64]
  [span : ast.AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(Spans entries instr-entries instr-count)
      (Spans
        (compiler-source-spans-entry-list-append
          entries
          (CompilerSourceSpansEntry name path-id span))
        instr-entries
        instr-count)]))

(define (compiler-source-spans-entry-array-lookup
  [slots : (__tl_dyn-array CompilerSourceSpansEntry)]
  [index : i64]
  [name : CompilerIrSymbolId]) : CompilerMaybeSourceSpan
  (if (< index 0)
    (No)
    (let
      [span-entry : CompilerSourceSpansEntry (array-ref slots index)]
      [entry-name : CompilerIrSymbolId span-entry.name]
      [span : ast.AstSourceSpan span-entry.span]
      (if (compiler-ir-symbol-id-eq? entry-name name)
        (Some span)
        (compiler-source-spans-entry-array-lookup slots (- index 1) name)))))

(define (compiler-source-spans-entry-array-lookup-location
  [slots : (__tl_dyn-array CompilerSourceSpansEntry)]
  [index : i64]
  [name : CompilerIrSymbolId]) : CompilerMaybeSourceLocation
  (if (< index 0)
    (No)
    (let
      [span-entry : CompilerSourceSpansEntry (array-ref slots index)]
      [entry-name : CompilerIrSymbolId span-entry.name]
      [path-id : i64 span-entry.path-id]
      [span : ast.AstSourceSpan span-entry.span]
      (if (compiler-ir-symbol-id-eq? entry-name name)
        (Some (CompilerSourceLocation path-id span))
        (compiler-source-spans-entry-array-lookup-location
          slots
          (- index 1)
          name)))))

(define (compiler-source-spans-entry-list-lookup
  [entries : CompilerSourceSpansEntryList]
  [name : CompilerIrSymbolId]) : CompilerMaybeSourceSpan
  (compiler-source-spans-entry-array-lookup
    entries.slots
    (- entries.len 1)
    name))

(define (compiler-source-spans-lookup-location
  [spans : CompilerSourceSpans]
  [name : CompilerIrSymbolId]) : CompilerMaybeSourceLocation
  (match spans
    [(Spans entries _ _)
      (compiler-source-spans-entry-array-lookup-location
        entries.slots
        (- entries.len 1)
        name)]))

(define (compiler-source-spans-lookup
  [spans : CompilerSourceSpans]
  [name : CompilerIrSymbolId]) : CompilerMaybeSourceSpan
  (match spans
    [(Spans entries _ _) (compiler-source-spans-entry-list-lookup entries name)]))

(define (compiler-source-spans-insert-instr-entry
  [spans : CompilerSourceSpans]
  [key : CompilerSourceSpansInstrKey]
  [span : ast.AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(Spans entries instr-entries instr-count)
      (Spans
        entries
        (compiler-source-spans-instr-entry-list-append
          instr-entries
          (compiler-source-spans-instr-entry key 0 span))
        (+ instr-count 1))]))

(define (compiler-source-spans-insert-instr-entry-located
  [spans : CompilerSourceSpans]
  [key : CompilerSourceSpansInstrKey]
  [path-id : i64]
  [span : ast.AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(Spans entries instr-entries instr-count)
      (Spans
        entries
        (compiler-source-spans-instr-entry-list-append
          instr-entries
          (compiler-source-spans-instr-entry key path-id span))
        (+ instr-count 1))]))

(define (compiler-source-spans-insert-instr
  [spans : CompilerSourceSpans]
  [function : CompilerIrSymbolId]
  [instr : CompilerIrInstr]
  [span : ast.AstSourceSpan]) : CompilerSourceSpans
  (compiler-source-spans-insert-instr-unlocated spans function instr span))

(defenum CompilerSourceSpansMaybeInstrKey
  (No)
  (Some CompilerSourceSpansInstrKey))

;; An instruction's span key: its destination value, the name a Store writes, or
;; a BoundsCheck's success label. Other stores, control flow and C-ABI result
;; stores have none.
(define (compiler-source-spans-instr-key
  [function : CompilerIrSymbolId]
  [instr : CompilerIrInstr]) : CompilerSourceSpansMaybeInstrKey
  (match (compiler-ir-global-shared-view instr)
    [(Store name _ _) (Some (Store function name))]
    [(BoundsCheck _ _ ok-label) (Some (Bounds function ok-label))]
    [_
      (let
        [dst : i64 (compiler-ir-instr-dst instr)]
        (if (< dst 0)
          (No)
          (Some (Value function dst))))]))

(define (compiler-source-spans-insert-instr-unlocated
  [spans : CompilerSourceSpans]
  [function : CompilerIrSymbolId]
  [instr : CompilerIrInstr]
  [span : ast.AstSourceSpan]) : CompilerSourceSpans
  (match (compiler-source-spans-instr-key function instr)
    [(No) spans]
    [(Some key) (compiler-source-spans-insert-instr-entry spans key span)]))

(define (compiler-source-spans-insert-instr-located
  [spans : CompilerSourceSpans]
  [function : CompilerIrSymbolId]
  [instr : CompilerIrInstr]
  [path-id : i64]
  [span : ast.AstSourceSpan]) : CompilerSourceSpans
  (match (compiler-source-spans-instr-key function instr)
    [(No) spans]
    [(Some key)
      (compiler-source-spans-insert-instr-entry-located spans key path-id span)]))

;; --- bounds-check clone-suffix fallback -----------------------------------
;; A BoundsCheck carries no destination value, so its span is keyed by its
;; fresh ok-label. Every clone family in the optimizer that copies a KEPT
;; check must uniquify that label -- two blocks may not define the same
;; assembly symbol -- by APPENDING a suffix to the original spelling:
;;   `__bce_fast`    opt-bce-mb-fast-label / opt-bce-mb-clone-instr (the
;;                   multi-block bounds-check versioner's fast clone)
;;   `__licm_false`  opt-licm-unswitch-clone-label (the unswitched false clone)
;;   `__u<digits>`   opt-unroll-copy-suffix (unroll trip copies; the
;;                   single-block versioner clones its kept checks through the
;;                   same helper with copy 0, spelling `__u0`)
;; The copy then misses the span table and the backend silently degrades
;; `tl_oob_abort_at` (file:line:col plus index/length) to the bare
;; `tl_oob_abort`. A clone's kept check traps at exactly the source check its
;; original was lowered from, so stripping the suffix and retrying yields the
;; right span. The passes stack (a versioned clone can be unrolled), hence the
;; loop; a bounded fuel keeps a pathological user label from spinning.
(define (compiler-source-spans-label-suffix-len
  [text : (& text str)]
  [suffix : String]) : i64
  (let
    [n : i64 (string.string-length text)]
    [m : i64 (string.string-length (& suffix))]
    (if (and (> n m) (string.is-string-prefix-at text (& suffix) (- n m)))
      m
      0)))

(define (compiler-source-spans-label-digit-at?
  [text : (& text str)]
  [index : i64]) : bool
  (let
    [c : char (string.string-ref text index)]
    (and (>= c '0') (<= c '9'))))

;; Length of a trailing `__u<digits>` unroll-copy suffix, or 0.
(define (compiler-source-spans-label-unroll-suffix-len [text : (& text str)]) : i64
  (let
    [marker : String "__u"]
    [n : i64 (string.string-length text)]
    [digits : i64 n]
    (while (and
      (> digits 0)
      (compiler-source-spans-label-digit-at? text (- digits 1)))
      (set! digits (- digits 1)))
    (if (or (= digits n) (< digits 4))
      0
      (if (string.is-string-prefix-at text (& marker) (- digits 3))
        (- n (- digits 3))
        0))))

;; Length of the one trailing clone suffix `text` carries, or 0.
(define (compiler-source-spans-bounds-clone-suffix-len [text : (& text str)]) : i64
  (let
    [fast : String "__bce_fast"]
    [fast-len : i64 (compiler-source-spans-label-suffix-len text fast)]
    (if (> fast-len 0)
      fast-len
      (let
        [unswitch : String "__licm_false"]
        [unswitch-len : i64
          (compiler-source-spans-label-suffix-len text unswitch)]
        (if (> unswitch-len 0)
          unswitch-len
          (compiler-source-spans-label-unroll-suffix-len text))))))

(define (compiler-source-spans-lookup-bounds-with-fuel
  [instr-entries : CompilerSourceSpansInstrEntryList]
  [function : CompilerIrSymbolId]
  [ok-label : i64]
  [fuel : i64]) : CompilerMaybeSourceLocation
  (match (compiler-source-spans-instr-entry-list-lookup
    (compiler-ir-global-shared-view instr-entries)
    (Bounds function ok-label))
    [(Some found) (Some found)]
    [(No)
      (if (<= fuel 0)
        (No)
        (let
          [text : String (compiler-ir-label-text ok-label)]
          [drop : i64 (compiler-source-spans-bounds-clone-suffix-len text)]
          (if (= drop 0)
            (No)
            (let
              [base : i64
                (compiler-ir-label-existing
                  (string.substring
                    (& text)
                    0
                    (- (string.string-length (& text)) drop)))]
              (if (< base 0)
                (No)
                (compiler-source-spans-lookup-bounds-with-fuel
                  instr-entries
                  function
                  base
                  (- fuel 1)))))))]))

(define (compiler-source-spans-lookup-bounds
  [instr-entries : CompilerSourceSpansInstrEntryList]
  [function : CompilerIrSymbolId]
  [ok-label : i64]) : CompilerMaybeSourceLocation
  ;; An empty table can never answer, and the abort-site probe runs on every
  ;; bounds check of a self-build whose instruction spans were dropped
  ;; wholesale (`opt-remap-spans-fast-path?`); short-circuit before any label
  ;; text is touched.
  (if (= instr-entries.len 0)
    (No)
    (compiler-source-spans-lookup-bounds-with-fuel
      instr-entries
      function
      ok-label
      8)))

(define (compiler-source-spans-lookup-instr-location
  [spans : CompilerSourceSpans]
  [function : CompilerIrSymbolId]
  [instr : CompilerIrInstr]) : CompilerMaybeSourceLocation
  (match spans
    [(Spans _ instr-entries _)
      (match (compiler-source-spans-instr-key function instr)
        [(No) (No)]
        [(Some key)
          (match (compiler-ir-global-shared-view key)
            [(Bounds key-function ok-label)
              (compiler-source-spans-lookup-bounds
                instr-entries
                key-function
                ok-label)]
            [_
              (compiler-source-spans-instr-entry-list-lookup instr-entries key)])])]))

(define (compiler-source-spans-lookup-instr
  [spans : CompilerSourceSpans]
  [function : CompilerIrSymbolId]
  [instr : CompilerIrInstr]) : CompilerMaybeSourceSpan
  (compiler-maybe-source-location-span
    (compiler-source-spans-lookup-instr-location spans function instr)))

(define (compiler-source-spans-count [spans : CompilerSourceSpans]) : i64
  (match spans
    [(Spans entries _ _) (compiler-source-spans-entry-list-count entries)]))

(define (compiler-source-spans-instr-count [spans : CompilerSourceSpans]) : i64
  (match spans
    [(Spans _ _ instr-count) instr-count]))

(define (compiler-source-spans-instr-count-at-least?
  [spans : CompilerSourceSpans]
  [minimum : i64]) : bool
  (match spans
    [(Spans _ _ instr-count) (>= instr-count minimum)]))

(define (compiler-source-spans-append-new
  [base : CompilerSourceSpans]
  [complete : CompilerSourceSpans]) : CompilerSourceSpans
  (match (compiler-ir-global-shared-view base)
    [(Spans base-entries base-instr-entries _)
      (match complete
        [(Spans complete-entries complete-instr-entries _)
          (let
            [entry-index : i64 base-entries.len]
            [instr-index : i64 base-instr-entries.len]
            [out : CompilerSourceSpans base]
            [complete-entry-slots : (__tl_dyn-array CompilerSourceSpansEntry)
              complete-entries.slots]
            [complete-instr-slots : (__tl_dyn-array
              CompilerSourceSpansInstrEntry)
              complete-instr-entries.slots]
            (while (< entry-index complete-entries.len)
              (let
                [span-entry : CompilerSourceSpansEntry
                  (array-ref complete-entry-slots entry-index)]
                [name : CompilerIrSymbolId span-entry.name]
                [path-id : i64 span-entry.path-id]
                [span : ast.AstSourceSpan span-entry.span]
                (set!
                  out
                  (if (> path-id 0)
                    (compiler-source-spans-insert-located out name path-id span)
                    (compiler-source-spans-insert out name span)))
                (set! entry-index (+ entry-index 1))))
            (while (< instr-index complete-instr-entries.len)
              (let
                [span-entry : CompilerSourceSpansInstrEntry
                  (array-ref complete-instr-slots instr-index)]
                [key : CompilerSourceSpansInstrKey
                  (compiler-source-spans-instr-entry-key (& span-entry))]
                [path-id : i64 span-entry.path-id]
                [span : ast.AstSourceSpan span-entry.span]
                (set!
                  out
                  (if (> path-id 0)
                    (compiler-source-spans-insert-instr-entry-located
                      out
                      key
                      path-id
                      span)
                    (compiler-source-spans-insert-instr-entry out key span)))
                (set! instr-index (+ instr-index 1))))
            out)])]))

(defenum CompilerIrSummary
  (Summary i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64))

(define (compiler-ir-summary-globals [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary globals _ _ _ _ _ _ _ _ _ _) globals]))

(define (compiler-ir-summary-functions [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ functions _ _ _ _ _ _ _ _ _) functions]))

(define (compiler-ir-summary-externs [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ externs _ _ _ _ _ _ _ _) externs]))

(define (compiler-ir-summary-blocks [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ _ blocks _ _ _ _ _ _ _) blocks]))

(define (compiler-ir-summary-instructions [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ _ _ instructions _ _ _ _ _ _) instructions]))

(define (compiler-ir-summary-vars [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ _ _ _ vars _ _ _ _ _) vars]))

(define (compiler-ir-summary-empty-blocks [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ _ _ _ _ empty-blocks _ _ _ _) empty-blocks]))

(define (compiler-ir-summary-max-instructions-function
  [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ _ _ _ _ _ max-instructions-function _ _ _)
      max-instructions-function]))

(define (compiler-ir-summary-max-instructions-block
  [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ _ _ _ _ _ _ max-instructions-block _ _)
      max-instructions-block]))

(define (compiler-ir-summary-call-arg-entries [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ _ _ _ _ _ _ _ call-arg-entries _) call-arg-entries]))

(define (compiler-ir-summary-phi-input-entries [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary _ _ _ _ _ _ _ _ _ _ phi-input-entries) phi-input-entries]))

(define (compiler-ir-summary-score [summary : CompilerIrSummary]) : i64
  (match summary
    [(Summary globals functions externs blocks instructions vars _ _ _ _ _)
      (+
        globals
        (+
          (* functions 10)
          (+
            (* externs 100)
            (+ (* blocks 1000) (+ (* instructions 10000) (* vars 100000))))))]))

(define (compiler-ir-max-i64 [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

(define (compiler-ir-instr-call-arg-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(Call _ _ args _) (compiler-ir-call-args-count args)]
    [(CallIndirect _ _ args _) (compiler-ir-call-args-count args)]
    [(CallIndirectC _ _ args _) (compiler-ir-call-args-count args)]
    [(CallCAbiStoreResult payload-box)
      (let
        [args (compiler-ir-box-field-shared-view payload-box args)]
        (compiler-ir-call-args-count args))]
    [(CallIndirectCAbiStoreResult payload-box)
      (let
        [args (compiler-ir-box-field-shared-view payload-box args)]
        (compiler-ir-call-args-count args))]
    [(SpmdCall payload-box)
      (let
        [args (compiler-ir-box-field-shared-view payload-box args)]
        (compiler-ir-spmd-call-arg-seq-count args))]
    [(TailCall _ args _) (compiler-ir-call-args-count args)]
    [(TailCallIndirect _ args _) (compiler-ir-call-args-count args)]
    [_ 0]))

(define (compiler-ir-instr-phi-input-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(Phi _ inputs _) (compiler-ir-phi-input-seq-count inputs)]
    [_ 0]))

(define (compiler-ir-instr-seq-call-arg-count-from
  [slots : (__tl_dyn-array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (compiler-ir-instr-seq-call-arg-count-from
      (compiler-ir-global-shared-view slots)
      (+ index 1)
      count
      (+
        acc
        (compiler-ir-instr-call-arg-count
          (compiler-ir-array-shared-view slots index))))))

(define (compiler-ir-instr-seq-call-arg-count [instrs : CompilerIrInstrSeq]) : i64
  (compiler-ir-instr-seq-call-arg-count-from instrs.slots 0 instrs.len 0))

(define (compiler-ir-instr-seq-phi-input-count-from
  [slots : (__tl_dyn-array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (compiler-ir-instr-seq-phi-input-count-from
      (compiler-ir-global-shared-view slots)
      (+ index 1)
      count
      (+
        acc
        (compiler-ir-instr-phi-input-count
          (compiler-ir-array-shared-view slots index))))))

(define (compiler-ir-instr-seq-phi-input-count [instrs : CompilerIrInstrSeq]) : i64
  (compiler-ir-instr-seq-phi-input-count-from instrs.slots 0 instrs.len 0))

(define (compiler-ir-block-list-count [blocks : (& blocks CompilerIrBlockList)]) : i64
  (match blocks
    [(Array seq) seq.len]))

(define (compiler-ir-block-list-empty-count
  [blocks : (& blocks (Slice CompilerIrBlock))]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (if (= (compiler-ir-instr-seq-count instrs) 0)
              1
              0)
            (compiler-ir-block-list-empty-count rest))])]))

(define (compiler-ir-block-list-max-instruction-count
  [blocks : (& blocks (Slice CompilerIrBlock))]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (compiler-ir-max-i64
            (compiler-ir-instr-seq-count instrs)
            (compiler-ir-block-list-max-instruction-count rest))])]))

(define (compiler-ir-block-list-call-arg-count
  [blocks : (& blocks (Slice CompilerIrBlock))]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (compiler-ir-instr-seq-call-arg-count instrs)
            (compiler-ir-block-list-call-arg-count rest))])]))

(define (compiler-ir-block-list-phi-input-count
  [blocks : (& blocks (Slice CompilerIrBlock))]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (compiler-ir-instr-seq-phi-input-count instrs)
            (compiler-ir-block-list-phi-input-count rest))])]))

(define (compiler-ir-block-list-instruction-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(Array seq)
      (let
        [count : i64 (compiler-ir-block-seq-count seq)]
        [total : i64 0]
        [index : i64 0]
        (while (< index count)
          (match (compiler-ir-block-seq-ref seq index)
            [(Block _ instrs)
              (set! total (+ total (compiler-ir-instr-seq-count instrs)))])
          (set! index (+ index 1)))
        total)]))

(define (compiler-ir-function-block-count [func : CompilerIrFunction]) : i64
  (match func
    [(Function _ _ _ _ blocks _) (compiler-ir-block-list-count blocks)]))

(define (compiler-ir-function-instruction-count [func : CompilerIrFunction]) : i64
  (match func
    [(Function _ _ _ _ blocks _)
      (compiler-ir-block-list-instruction-count blocks)]))

(define (compiler-ir-function-empty-block-count [func : CompilerIrFunction]) : i64
  (match func
    [(Function _ _ _ _ blocks _)
      (compiler-ir-block-list-empty-count (compiler-ir-block-list-view blocks))]))

(define (compiler-ir-function-max-instruction-count [func : CompilerIrFunction]) : i64
  (match func
    [(Function _ _ _ _ blocks _)
      (compiler-ir-block-list-instruction-count blocks)]))

(define (compiler-ir-function-max-block-instruction-count
  [func : CompilerIrFunction]) : i64
  (match func
    [(Function _ _ _ _ blocks _)
      (compiler-ir-block-list-max-instruction-count
        (compiler-ir-block-list-view blocks))]))

(define (compiler-ir-function-call-arg-count [func : CompilerIrFunction]) : i64
  (match func
    [(Function _ _ _ _ blocks _)
      (compiler-ir-block-list-call-arg-count
        (compiler-ir-block-list-view blocks))]))

(define (compiler-ir-function-phi-input-count [func : CompilerIrFunction]) : i64
  (match func
    [(Function _ _ _ _ blocks _)
      (compiler-ir-block-list-phi-input-count
        (compiler-ir-block-list-view blocks))]))

(define (compiler-ir-function-var-count [func : CompilerIrFunction]) : i64
  (match func
    [(Function _ _ _ vars _ _) vars]))

(define (compiler-ir-function-seq-block-count
  [functions : (& CompilerIrFunctionSeq)]) : i64
  (let
    [count : i64 functions.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (compiler-ir-function-block-count
            (compiler-ir-array-shared-view functions.slots index))))
      (set! index (+ index 1)))
    acc))

(define (compiler-ir-function-seq-instruction-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (__tl_dyn-array CompilerIrFunction) functions.slots]
    [count : i64 functions.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (compiler-ir-function-instruction-count
            (compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (compiler-ir-function-seq-empty-block-count
  [functions : (& functions CompilerIrFunctionSeq)]) : i64
  (let
    [slots : (__tl_dyn-array CompilerIrFunction) functions.slots]
    [count : i64 functions.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (compiler-ir-function-empty-block-count
            (compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (compiler-ir-function-seq-max-instruction-count
  [functions : (& functions CompilerIrFunctionSeq)]) : i64
  (let
    [slots : (__tl_dyn-array CompilerIrFunction) functions.slots]
    [count : i64 functions.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (compiler-ir-max-i64
          acc
          (compiler-ir-function-max-instruction-count
            (compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (compiler-ir-function-seq-max-block-instruction-count
  [functions : (& functions CompilerIrFunctionSeq)]) : i64
  (let
    [slots : (__tl_dyn-array CompilerIrFunction) functions.slots]
    [count : i64 functions.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (compiler-ir-max-i64
          acc
          (compiler-ir-function-max-block-instruction-count
            (compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (compiler-ir-function-seq-call-arg-count
  [functions : (& functions CompilerIrFunctionSeq)]) : i64
  (let
    [slots : (__tl_dyn-array CompilerIrFunction) functions.slots]
    [count : i64 functions.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (compiler-ir-function-call-arg-count
            (compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (compiler-ir-function-seq-phi-input-count
  [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (__tl_dyn-array CompilerIrFunction) functions.slots]
    [count : i64 functions.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (compiler-ir-function-phi-input-count
            (compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (compiler-ir-function-seq-var-count [functions : CompilerIrFunctionSeq]) : i64
  (let
    [slots : (__tl_dyn-array CompilerIrFunction) functions.slots]
    [count : i64 functions.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (compiler-ir-function-var-count
            (compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (compiler-ir-program-summary [program : CompilerIrProgram]) : CompilerIrSummary
  (match program
    [(Program globals functions externs)
      (Summary
        (compiler-ir-global-seq-count globals)
        (compiler-ir-function-seq-count functions)
        (compiler-ir-extern-seq-count externs)
        (compiler-ir-function-seq-block-count functions)
        (compiler-ir-function-seq-instruction-count
          (compiler-ir-global-shared-view functions))
        (compiler-ir-function-seq-var-count
          (compiler-ir-global-shared-view functions))
        (compiler-ir-function-seq-empty-block-count functions)
        (compiler-ir-function-seq-max-instruction-count functions)
        (compiler-ir-function-seq-max-block-instruction-count functions)
        (compiler-ir-function-seq-call-arg-count functions)
        (compiler-ir-function-seq-phi-input-count functions))]))

(define (compiler-ir-type-list-name-at
  [type-segment-bases : i64]
  [types : (& types ast.AstTypeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-type-list-len types))
    ""
    (str_cat.str-cat
      " "
      (compiler-ir-type-name
        type-segment-bases
        (ast.ast-type-segment-bases-get
          type-segment-bases
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback))))
      (compiler-ir-type-list-name-at type-segment-bases types (+ index 1)))))

(define (compiler-ir-type-list-name
  [type-segment-bases : i64]
  [types : ast.AstTypeList]) : String
  (compiler-ir-type-list-name-at type-segment-bases (& types) 0))

(define (compiler-ir-type-name [type-segment-bases : i64] [ty : ast.AstType]) : String
  (match ty
    [(I64) "i64"]
    [(I32) "i32"]
    [(I16) "i16"]
    [(I8) "i8"]
    [(U64) "u64"]
    [(U32) "u32"]
    [(U16) "u16"]
    [(U8) "u8"]
    [(F64) "f64"]
    [(F32) "f32"]
    [(Bool) "bool"]
    [(Char) "char"]
    [(String) "String"]
    [(Str) "str"]
    [(Bytes) "bytes"]
    [(Unit) "unit"]
    [(Never) "never"]
    [(Expr) "Expr"]
    [(ExprList) "ExprList"]
    [(Func args ret)
      (str_cat.str-cat
        "(->"
        (compiler-ir-type-list-name type-segment-bases (deref args))
        " "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases ret))
        ")")]
    [(CFunc signature mode)
      (str_cat.str-cat
        "(CFunc "
        (ast.ast-c-function-mode-name mode)
        " "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases signature))
        ")")]
    [(Tuple elems)
      (str_cat.str-cat
        "(Tuple"
        (compiler-ir-type-list-name type-segment-bases (deref elems))
        ")")]
    [(Array elem count)
      (str_cat.str-cat
        "(Array "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        " "
        (string.int->string count)
        ")")]
    [(DynArray elem)
      (str_cat.str-cat
        "(__tl_dyn-array "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]
    [(Slice elem)
      (str_cat.str-cat
        "(Slice "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]
    [(Box elem)
      (str_cat.str-cat
        "(Box "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]
    [(Region region inner)
      (str_cat.str-cat
        "(in "
        (compiler-ir-lifetime-render
          (cis.InternStructuralSessionHandle 0)
          region)
        " "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases inner))
        ")")]
    [(Invalidate lifetime inner)
      (str_cat.str-cat
        "(:invalidate "
        (compiler-ir-lifetime-render
          (cis.InternStructuralSessionHandle 0)
          lifetime)
        " "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases inner))
        ")")]
    [(Ref region inner)
      (str_cat.str-cat
        "(& "
        (compiler-ir-lifetime-render
          (cis.InternStructuralSessionHandle 0)
          region)
        " "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases inner))
        ")")]
    [(MutRef region inner)
      (str_cat.str-cat
        "(&mut "
        (compiler-ir-lifetime-render
          (cis.InternStructuralSessionHandle 0)
          region)
        " "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases inner))
        ")")]
    [(Enum name) (ast.ast-nominal-name-id-display name)]
    [(EnumArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (cis.InternStructuralSessionHandle 0)
        (ast.ast-nominal-name-id-display name)
        (deref lifetimes))]
    [(Struct name) (ast.ast-nominal-name-id-display name)]
    [(StructArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (cis.InternStructuralSessionHandle 0)
        (ast.ast-nominal-name-id-display name)
        (deref lifetimes))]
    [(Var name) (str_cat.str-cat "'" (ci.intern-str name) "'")]
    [(VarArgs name lifetimes)
      (compiler-ir-nominal-lifetime-render
        (cis.InternStructuralSessionHandle 0)
        (ci.intern-str name)
        (deref lifetimes))]
    [(Ptr elem)
      (str_cat.str-cat
        "(Ptr "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]
    [(MutPtr elem)
      (str_cat.str-cat
        "(MutPtr "
        (compiler-ir-type-name
          type-segment-bases
          (ast.ast-type-segment-bases-get type-segment-bases elem))
        ")")]))

(define (compiler-ir-binop-name [op : CompilerIrBinOp]) : String
  (match op
    [(Add) "add"]
    [(Sub) "sub"]
    [(Mul) "mul"]
    [(Div) "div"]
    [(Mod) "mod"]
    [(SafeDiv) "safe_div"]
    [(SafeMod) "safe_mod"]
    [(Eq) "eq"]
    [(Ne) "ne"]
    [(Lt) "lt"]
    [(Le) "le"]
    [(Gt) "gt"]
    [(Ge) "ge"]
    [(BitTestEq) "bit_test_eq"]
    [(BitTestNe) "bit_test_ne"]
    [(And) "and"]
    [(Or) "or"]
    [(BitAnd) "bitand"]
    [(BitOr) "bitor"]
    [(BitXor) "bitxor"]
    [(Shl _) "shl"]
    [(Shr _) "shr"]))

(defstruct CompilerIrRepresentationVarTypes
  (present (__tl_dyn-array i64))
  (items (__tl_dyn-array ast.AstType)))

(define (compiler-ir-representation-name-prefix?
  [name : String]
  [prefix : String]) : bool
  (let
    [prefix-len : i64 (string.string-length prefix)]
    (and
      (>= (string.string-length name) prefix-len)
      (string.eq (string.substring name 0 prefix-len) prefix))))

;; The physical group spelling is an IR-owned capability produced by lowering,
;; never a user-name convention. The encoded mask is two bits because all
;; currently lowered nominal register groups contain exactly two machine words.
(define (compiler-ir-representation-abi-group-mask-from-name [name : String]) : i64
  (let
    [prefix : String "__tl_internal_abi_group_m"]
    [prefix-len : i64 (string.string-length prefix)]
    (if (not
      (compiler-ir-representation-name-prefix?
        (compiler-ir-global-shared-view name)
        prefix))
      -1
      (let
        [n : i64 (string.string-length name)]
        [delimiter : i64 (+ prefix-len 2)]
        (if (or
          (>= (+ prefix-len 2) n)
          (not (= (cast (string.string-ref name (+ prefix-len 1)) : i64) 95))
          (not (= (cast (string.string-ref name delimiter) : i64) 95))
          (>= (+ delimiter 1) n))
          -1
          (let
            [digit : i64 (cast (string.string-ref name prefix-len) : i64)]
            (if (and (>= digit 48) (<= digit 51))
              (- digit 48)
              -1)))))))

(define (compiler-ir-representation-owned-aggregate-name
  [type-segment-bases : i64]
  [ty : ast.AstType]) : i64
  (match ty
    [(Struct name)
      (if (compiler-ir-symbol-owned? name)
        name
        -1)]
    [(StructArgs name _)
      (if (compiler-ir-symbol-owned? name)
        name
        -1)]
    [(Region _ inner)
      (compiler-ir-representation-owned-aggregate-name
        type-segment-bases
        (ast.ast-type-segment-bases-get type-segment-bases inner))]
    [(Invalidate _ inner)
      (compiler-ir-representation-owned-aggregate-name
        type-segment-bases
        (ast.ast-type-segment-bases-get type-segment-bases inner))]
    [_ -1]))

(define (compiler-ir-representation-abi-group-mask
  [type-segment-bases : i64]
  [ty : ast.AstType]) : i64
  (let
    [name : i64
      (compiler-ir-representation-owned-aggregate-name type-segment-bases ty)]
    (if (< name 0)
      -1
      (compiler-ir-representation-abi-group-mask-from-name
        (compiler-ir-symbol-text name)))))

(define (compiler-ir-representation-internal-transport?
  [type-segment-bases : i64]
  [ty : ast.AstType]) : bool
  (let
    [name : i64
      (compiler-ir-representation-owned-aggregate-name type-segment-bases ty)]
    (and
      (>= name 0)
      (compiler-ir-representation-name-prefix?
        (compiler-ir-symbol-text name)
        "__tl_internal_abi_"))))

(define (compiler-ir-representation-index-merge-group
  [index : CompilerIrRepresentationIndex]
  [key : i64]
  [word-count : i64]
  [class-mask : i64]) : CompilerIrRepresentationIndex
  (let
    [counts : ir_i64_i64_map.Map index.word-counts]
    [masks : ir_i64_i64_map.Map index.class-masks]
    (if (< word-count 2)
      (begin
        ;; A malformed group is explicit unresolved evidence, not a one-word
        ;; proof. Preserve any prior conflict and fail closed deterministically.
        (ir_i64_i64_map.insert-ref! (&mut counts) key 0)
        (ir_i64_i64_map.insert-ref! (&mut masks) key 0)
        (CompilerIrRepresentationIndex counts masks))
      (match (ir_i64_i64_map.get (& counts) key)
        [(LookupMissing)
          (ir_i64_i64_map.insert-ref! (&mut counts) key word-count)
          (ir_i64_i64_map.insert-ref! (&mut masks) key class-mask)
          (CompilerIrRepresentationIndex counts masks)]
        [(LookupFound found-count)
          (match (ir_i64_i64_map.get (& masks) key)
            [(LookupFound found-mask)
              (if (and (= found-count word-count) (= found-mask class-mask))
                index
                (begin
                  (ir_i64_i64_map.insert-ref! (&mut counts) key 0)
                  (ir_i64_i64_map.insert-ref! (&mut masks) key 0)
                  (CompilerIrRepresentationIndex counts masks)))]
            [(LookupMissing)
              (ir_i64_i64_map.insert-ref! (&mut counts) key 0)
              (ir_i64_i64_map.insert-ref! (&mut masks) key 0)
              (CompilerIrRepresentationIndex counts masks)])]))))

(define (compiler-ir-representation-index-merge-one-word
  [index : CompilerIrRepresentationIndex]
  [key : i64]) : CompilerIrRepresentationIndex
  (if (ir_i64_i64_map.contains? (& index.word-counts) key)
    index
    (let
      [counts : ir_i64_i64_map.Map index.word-counts]
      (ir_i64_i64_map.insert-ref! (&mut counts) key 1)
      (CompilerIrRepresentationIndex counts index.class-masks))))

(define (compiler-ir-representation-var-type-set!
  [types : (& types CompilerIrRepresentationVarTypes)]
  [var : i64]
  [ty : ast.AstType]) : unit
  (unless
    (or (< var 0) (>= var (array-length types.present)))
    (set! (array-ref types.present var) 1)
    (set! (array-ref types.items var) ty)))

(define (compiler-ir-representation-param-types!
  [params : CompilerIrParamSeq]
  [types : (& types CompilerIrRepresentationVarTypes)]) : unit
  (let
    [position : i64 0]
    (while (< position params.len)
      (match (compiler-ir-param-seq-ref params position)
        [(Param _ ty var)
          (compiler-ir-representation-var-type-set! types var ty)])
      (set! position (+ position 1)))))

(define (compiler-ir-representation-instr-def-type!
  [instr : CompilerIrInstr]
  [types : (& types CompilerIrRepresentationVarTypes)]) : unit
  (match (compiler-ir-global-shared-view instr)
    ;; The index does not type indirect-call results or a scalar Select.
    [(CallIndirect _ _ _ _) unit]
    [(CallIndirectC _ _ _ _) unit]
    [(Select _) unit]
    [_
      (match (compiler-ir-instr-dst-type (compiler-ir-global-shared-view instr))
        [(No) unit]
        [(Some ty)
          (compiler-ir-representation-var-type-set!
            types
            (compiler-ir-instr-dst instr)
            ty)])]))

(define (compiler-ir-representation-instr-types!
  [instrs : CompilerIrInstrSeq]
  [types : (& types CompilerIrRepresentationVarTypes)]) : unit
  (let
    [i : i64 0]
    (while (< i (compiler-ir-instr-seq-count instrs))
      (compiler-ir-representation-instr-def-type!
        (compiler-ir-instr-seq-ref instrs i)
        types)
      (set! i (+ i 1)))))

(define (compiler-ir-representation-block-types!
  [blocks : CompilerIrBlockList]
  [types : (& types CompilerIrRepresentationVarTypes)]) : unit
  (match blocks
    [(Array seq)
      (let
        [i : i64 0]
        (while (< i (compiler-ir-block-seq-count seq))
          (match (compiler-ir-block-seq-ref seq i)
            [(Block _ instrs)
              (compiler-ir-representation-instr-types! instrs types)])
          (set! i (+ i 1))))]))

(define (compiler-ir-representation-function-var-types
  [func : CompilerIrFunction]) : CompilerIrRepresentationVarTypes
  (match func
    [(Function _ params _ vars blocks _)
      (let
        [types : CompilerIrRepresentationVarTypes
          (CompilerIrRepresentationVarTypes
            (__tl_make-array i64 vars)
            (__tl_make-array ast.AstType vars))]
        (compiler-ir-representation-param-types! params types)
        (compiler-ir-representation-block-types! blocks types)
        types)]))

(define (compiler-ir-representation-float-type? [ty : ast.AstType]) : bool
  (match ty
    [(F64) true]
    [(F32) true]
    [_ false]))

(define (compiler-ir-representation-pack-word-sse?
  [types : CompilerIrRepresentationVarTypes]
  [value : CompilerIrValue]) : bool
  (match value
    [(F64 _) true]
    [(Var var)
      (and
        (>= var 0)
        (< var (array-length types.present))
        (not (= (array-ref types.present var) 0))
        (compiler-ir-representation-float-type?
          (compiler-ir-array-shared-view types.items var)))]
    [_ false]))

(define (compiler-ir-representation-pack-class-mask
  [types : CompilerIrRepresentationVarTypes]
  [words : CompilerIrValueSeq]
  [position : i64]
  [mask : i64]) : i64
  (if (>= position words.len)
    mask
    (compiler-ir-representation-pack-class-mask
      (compiler-ir-global-shared-view types)
      (compiler-ir-global-shared-view words)
      (+ position 1)
      (if (compiler-ir-representation-pack-word-sse?
        types
        (compiler-ir-value-seq-ref words position))
        (bit-or
          mask
          (if (= position 0)
            1
            2))
        mask))))

(define (compiler-ir-representation-merge-group-type
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [ty : ast.AstType]
  [word-count : i64]
  [class-mask : i64]) : CompilerIrRepresentationIndex
  (match (ast.ast-aggregate-type-key type-segment-bases ty)
    [(Some key)
      (compiler-ir-representation-index-merge-group
        index
        key
        word-count
        class-mask)]
    [(None) index]))

(define (compiler-ir-representation-collect-signature-type
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [ty : ast.AstType]) : CompilerIrRepresentationIndex
  (let
    [mask : i64
      (compiler-ir-representation-abi-group-mask
        type-segment-bases
        (compiler-ir-global-shared-view ty))]
    (if (< mask 0)
      index
      (compiler-ir-representation-merge-group-type
        type-segment-bases
        index
        ty
        2
        mask))))

(define (compiler-ir-representation-collect-signature-params-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [params : CompilerIrParamSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position params.len)
    index
    (match (compiler-ir-param-seq-ref params position)
      [(Param _ ty _)
        (compiler-ir-representation-collect-signature-params-from
          type-segment-bases
          (compiler-ir-representation-collect-signature-type
            type-segment-bases
            index
            ty)
          params
          (+ position 1))])))

(define (compiler-ir-representation-collect-signature-params
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [params : CompilerIrParamSeq]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-signature-params-from
    type-segment-bases
    index
    params
    0))

(define (compiler-ir-representation-collect-group-instrs-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [types : CompilerIrRepresentationVarTypes]
  [instrs : CompilerIrInstrSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position (compiler-ir-instr-seq-count instrs))
    index
    (match (compiler-ir-instr-seq-ref instrs position)
      [(Pack _ words ty)
        (compiler-ir-representation-collect-group-instrs-from
          type-segment-bases
          (compiler-ir-representation-merge-group-type
            type-segment-bases
            index
            ty
            (compiler-ir-value-seq-count words)
            (compiler-ir-representation-pack-class-mask
              (compiler-ir-global-shared-view types)
              words
              0
              0))
          types
          instrs
          (+ position 1))]
      [_
        (compiler-ir-representation-collect-group-instrs-from
          type-segment-bases
          index
          types
          instrs
          (+ position 1))])))

(define (compiler-ir-representation-collect-group-instrs
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [types : CompilerIrRepresentationVarTypes]
  [instrs : CompilerIrInstrSeq]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-group-instrs-from
    type-segment-bases
    index
    types
    instrs
    0))

(define (compiler-ir-representation-collect-group-block-seq-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [types : CompilerIrRepresentationVarTypes]
  [blocks : CompilerIrBlockSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position (compiler-ir-block-seq-count blocks))
    index
    (match (compiler-ir-block-seq-ref blocks position)
      [(Block _ instrs)
        (compiler-ir-representation-collect-group-block-seq-from
          type-segment-bases
          (compiler-ir-representation-collect-group-instrs
            type-segment-bases
            index
            (compiler-ir-global-shared-view types)
            instrs)
          types
          blocks
          (+ position 1))])))

(define (compiler-ir-representation-collect-group-blocks
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [types : CompilerIrRepresentationVarTypes]
  [blocks : CompilerIrBlockList]) : CompilerIrRepresentationIndex
  (match blocks
    [(Array seq)
      (compiler-ir-representation-collect-group-block-seq-from
        type-segment-bases
        index
        types
        seq
        0)]))

(define (compiler-ir-representation-collect-group-function
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [func : CompilerIrFunction]) : CompilerIrRepresentationIndex
  (match (compiler-ir-global-shared-view func)
    [(Function _ params ret-ty _ blocks _)
      (let
        [types : CompilerIrRepresentationVarTypes
          (compiler-ir-representation-function-var-types func)]
        (compiler-ir-representation-collect-group-blocks
          type-segment-bases
          (compiler-ir-representation-collect-signature-type
            type-segment-bases
            (compiler-ir-representation-collect-signature-params
              type-segment-bases
              index
              params)
            ret-ty)
          types
          blocks))]))

(define (compiler-ir-representation-collect-group-function-seq-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [functions : CompilerIrFunctionSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position (compiler-ir-function-seq-count functions))
    index
    (compiler-ir-representation-collect-group-function-seq-from
      type-segment-bases
      (compiler-ir-representation-collect-group-function
        type-segment-bases
        index
        (compiler-ir-array-shared-view functions.slots position))
      functions
      (+ position 1))))

(define (compiler-ir-representation-collect-group-functions
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [functions : CompilerIrFunctionSeq]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-group-function-seq-from
    type-segment-bases
    index
    functions
    0))

(define (compiler-ir-representation-collect-one-type-list-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [types : ast.AstTypeList]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position types.len)
    index
    (compiler-ir-representation-collect-one-type-list-from
      type-segment-bases
      (compiler-ir-representation-collect-one-type
        type-segment-bases
        index
        (ast.ast-type-segment-bases-get
          type-segment-bases
          (array-ref types.slots position)))
      types
      (+ position 1))))

(define (compiler-ir-representation-collect-one-type-list
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [types : ast.AstTypeList]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-one-type-list-from
    type-segment-bases
    index
    types
    0))

(define (compiler-ir-representation-collect-one-type
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [ty : ast.AstType]) : CompilerIrRepresentationIndex
  (let
    [with-nominal : CompilerIrRepresentationIndex
      (match (ast.ast-aggregate-type-key
        type-segment-bases
        (compiler-ir-global-shared-view ty))
        [(Some key)
          (if (compiler-ir-representation-internal-transport?
            type-segment-bases
            (compiler-ir-global-shared-view ty))
            index
            (compiler-ir-representation-index-merge-one-word index key))]
        [(None) index])]
    (match ty
      [(Func args ret)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          (compiler-ir-representation-collect-one-type-list
            type-segment-bases
            with-nominal
            (deref args))
          (ast.ast-type-segment-bases-get type-segment-bases ret))]
      [(Tuple items)
        (compiler-ir-representation-collect-one-type-list
          type-segment-bases
          with-nominal
          (deref items))]
      [(Array elem _)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases elem))]
      [(DynArray elem)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases elem))]
      [(Box inner)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases inner))]
      [(Ref _ inner)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases inner))]
      [(MutRef _ inner)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases inner))]
      [(Ptr inner)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases inner))]
      [(MutPtr inner)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases inner))]
      ;; Region was already transparently classified by the canonical-key
      ;; query; recurse only to discover nested container types.
      [(Region _ inner)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases inner))]
      [(Invalidate _ inner)
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          with-nominal
          (ast.ast-type-segment-bases-get type-segment-bases inner))]
      [_ with-nominal])))

(define (compiler-ir-representation-collect-one-param-seq-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [params : CompilerIrParamSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position params.len)
    index
    (match (compiler-ir-param-seq-ref params position)
      [(Param _ ty _)
        (compiler-ir-representation-collect-one-param-seq-from
          type-segment-bases
          (compiler-ir-representation-collect-one-type
            type-segment-bases
            index
            ty)
          params
          (+ position 1))])))

(define (compiler-ir-representation-collect-one-param-seq
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [params : CompilerIrParamSeq]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-one-param-seq-from
    type-segment-bases
    index
    params
    0))

(define (compiler-ir-representation-collect-one-instr
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [instr : CompilerIrInstr]) : CompilerIrRepresentationIndex
  (match instr
    [(Mov _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Alloc _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Gep _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Load _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(StoreOwned _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(StorePtr _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Cast _ _ from-ty to-ty)
      (compiler-ir-representation-collect-one-type
        type-segment-bases
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          index
          from-ty)
        to-ty)]
    [(Bitcast _ _ from-ty to-ty)
      (compiler-ir-representation-collect-one-type
        type-segment-bases
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          index
          from-ty)
        to-ty)]
    [(BinOp _ _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(UnOp _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Splat _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(VectorReduce _ _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(VectorLoad _ _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Call _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(CallIndirect _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(CallIndirectC _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(TailCall _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Store _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Phi _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Pack _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(Word _ _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [(TailCallIndirect _ _ ty)
      (compiler-ir-representation-collect-one-type type-segment-bases index ty)]
    [_ index]))

(define (compiler-ir-representation-collect-one-instrs-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [instrs : CompilerIrInstrSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position (compiler-ir-instr-seq-count instrs))
    index
    (compiler-ir-representation-collect-one-instrs-from
      type-segment-bases
      (compiler-ir-representation-collect-one-instr
        type-segment-bases
        index
        (compiler-ir-instr-seq-ref instrs position))
      instrs
      (+ position 1))))

(define (compiler-ir-representation-collect-one-instrs
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [instrs : CompilerIrInstrSeq]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-one-instrs-from
    type-segment-bases
    index
    instrs
    0))

(define (compiler-ir-representation-collect-one-block-seq-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [blocks : CompilerIrBlockSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position (compiler-ir-block-seq-count blocks))
    index
    (match (compiler-ir-block-seq-ref blocks position)
      [(Block _ instrs)
        (compiler-ir-representation-collect-one-block-seq-from
          type-segment-bases
          (compiler-ir-representation-collect-one-instrs
            type-segment-bases
            index
            instrs)
          blocks
          (+ position 1))])))

(define (compiler-ir-representation-collect-one-blocks
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [blocks : CompilerIrBlockList]) : CompilerIrRepresentationIndex
  (match blocks
    [(Array seq)
      (compiler-ir-representation-collect-one-block-seq-from
        type-segment-bases
        index
        seq
        0)]))

(define (compiler-ir-representation-collect-one-function
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [func : CompilerIrFunction]) : CompilerIrRepresentationIndex
  (match func
    [(Function _ params ret-ty _ blocks _)
      (compiler-ir-representation-collect-one-blocks
        type-segment-bases
        (compiler-ir-representation-collect-one-type
          type-segment-bases
          (compiler-ir-representation-collect-one-param-seq
            type-segment-bases
            index
            params)
          ret-ty)
        blocks)]))

(define (compiler-ir-representation-collect-one-function-seq-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [functions : CompilerIrFunctionSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position (compiler-ir-function-seq-count functions))
    index
    (compiler-ir-representation-collect-one-function-seq-from
      type-segment-bases
      (compiler-ir-representation-collect-one-function
        type-segment-bases
        index
        (compiler-ir-array-shared-view functions.slots position))
      functions
      (+ position 1))))

(define (compiler-ir-representation-collect-one-functions
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [functions : CompilerIrFunctionSeq]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-one-function-seq-from
    type-segment-bases
    index
    functions
    0))

(define (compiler-ir-representation-collect-one-globals-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [globals : CompilerIrGlobalSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position (compiler-ir-global-seq-count globals))
    index
    (match (compiler-ir-global-seq-ref globals position)
      [(Global _ ty _)
        (compiler-ir-representation-collect-one-globals-from
          type-segment-bases
          (compiler-ir-representation-collect-one-type
            type-segment-bases
            index
            ty)
          globals
          (+ position 1))])))

(define (compiler-ir-representation-collect-one-globals
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [globals : CompilerIrGlobalSeq]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-one-globals-from
    type-segment-bases
    index
    globals
    0))

(define (compiler-ir-representation-collect-one-externs-from
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [externs : CompilerIrExternSeq]
  [position : i64]) : CompilerIrRepresentationIndex
  (if (>= position externs.len)
    index
    (match (compiler-ir-extern-seq-ref externs position)
      [(Extern _ _ _ ty _ _ _ _)
        (compiler-ir-representation-collect-one-externs-from
          type-segment-bases
          (compiler-ir-representation-collect-one-type
            type-segment-bases
            index
            ty)
          externs
          (+ position 1))])))

(define (compiler-ir-representation-collect-one-externs
  [type-segment-bases : i64]
  [index : CompilerIrRepresentationIndex]
  [externs : CompilerIrExternSeq]) : CompilerIrRepresentationIndex
  (compiler-ir-representation-collect-one-externs-from
    type-segment-bases
    index
    externs
    0))

(define (compiler-ir-representation-index-build
  [type-segment-bases : i64]
  [program : CompilerIrProgram]) : CompilerIrRepresentationIndex
  (match program
    [(Program globals functions externs)
      (let
        ;; Group evidence is complete before positive one-word evidence is
        ;; admitted. Thus an ordinary occurrence of a real group can never
        ;; conflict with its Pack/signature, while genuinely contradictory
        ;; group observations remain explicit Unknown.
        [groups : CompilerIrRepresentationIndex
          (compiler-ir-representation-collect-group-functions
            type-segment-bases
            (compiler-ir-representation-index-empty)
            (compiler-ir-global-shared-view functions))]
        (compiler-ir-representation-collect-one-externs
          type-segment-bases
          (compiler-ir-representation-collect-one-functions
            type-segment-bases
            (compiler-ir-representation-collect-one-globals
              type-segment-bases
              groups
              globals)
            functions)
          externs))]))

;; Test support: a descriptor's rendering without its generated callee name,
;; the one part a test cannot spell: "<backend> lanes N [...] index ... result".
(define (compiler-ir-test-spmd-private-abi-shape
  [abi : CompilerIrSpmdPrivateAbi]) : String
  (let
    [text : String
      (compiler-ir-spmd-private-abi-render
        (cis.InternStructuralSessionHandle 0)
        (ast.ast-node-pool-reader-type-segment-bases)
        abi)]
    [length : i64 (string.string-length text)]
    [index : i64 0]
    [spaces : i64 0]
    (while (and (< spaces 2) (< index length))
      (if (= (string.string-ref text index) ' ')
        (set! spaces (+ spaces 1))
        unit)
      (set! index (+ index 1)))
    (string.substring text index (- length index))))

;; Test support: the shapes of every private helper in `functions`, in function order,
;; separated by " | ".
(define (compiler-ir-test-spmd-private-abi-shapes
  [functions : CompilerIrFunctionSeq]) : String
  (let
    [out : String ""]
    [index : i64 0]
    (while (< index functions.len)
      (match (compiler-ir-function-seq-ref functions index)
        [(Function _ _ _ _ _ function-abi)
          (match function-abi
            [(Ordinary) unit]
            [(SpmdPrivate private-box)
              (let
                [separator : String
                  (if (= (string.string-length out) 0)
                    ""
                    " | ")]
                (set!
                  out
                  (str_cat.str-cat
                    out
                    separator
                    (compiler-ir-test-spmd-private-abi-shape
                      (deref private-box)))))])])
      (set! index (+ index 1)))
    out))

;; Test support: the private SPMD ABI a helper called with exactly `args` and
;; `result` would have, with each physical parameter typed as its source type
;; and no index mapping.
(define (compiler-ir-test-spmd-private-abi
  [callee : i64]
  [backend : CompilerIrSpmdBackend]
  [lanes : i64]
  [args : CompilerIrSpmdCallArgSeq]
  [result : CompilerIrSpmdCallResult]) : CompilerIrSpmdPrivateAbi
  (let
    [params : CompilerIrSpmdPrivateParamSeq
      (compiler-ir-spmd-private-param-seq-with-capacity (+ args.len 1))]
    [index : i64 0]
    (compiler-ir-spmd-private-param-seq-push!
      (&mut params)
      (CompilerIrSpmdPrivateParam.Param 0 (ActiveMask) (Bool)))
    (while (< index args.len)
      (match (array-ref args.slots index)
        [(Arg class _ ty)
          (compiler-ir-spmd-private-param-seq-push!
            (&mut params)
            (CompilerIrSpmdPrivateParam.Param
              (+ index 1)
              (Source
                index
                (compiler-ir-clone-spmd-value-class class)
                (clone ty))
              (clone ty)))])
      (set! index (+ index 1)))
    (CompilerIrSpmdPrivateAbi
      (V1)
      callee
      backend
      lanes
      params
      (None)
      (match result
        [(Unit) (Unit)]
        [(Value _ class ty)
          (Value (compiler-ir-clone-spmd-value-class class) (clone ty))]))))

;; Test support: a same-program SPMD call carrying the descriptor
;; `compiler-ir-test-spmd-private-abi` derives from its own payload.
(define (compiler-ir-test-spmd-private-call
  [callee : i64]
  [backend : CompilerIrSpmdBackend]
  [lanes : i64]
  [active-mask : CompilerIrValue]
  [args : CompilerIrSpmdCallArgSeq]
  [result : CompilerIrSpmdCallResult]) : CompilerIrInstr
  (let
    [abi : CompilerIrSpmdPrivateAbi
      (compiler-ir-test-spmd-private-abi
        callee
        (compiler-ir-clone-spmd-backend backend)
        lanes
        (compiler-ir-global-shared-view args)
        (compiler-ir-global-shared-view result))]
    (ir-instr-spmd-call-with-origin
      callee
      backend
      lanes
      active-mask
      args
      result
      (compiler-ir-spmd-call-origin-private abi))))

;; --- debug type graph (#8237) ----------------------------------------------
;; Under debug info, lowering records one target-independent graph of the
;; types a debug binding can have, with every layout the DWARF and CodeView
;; emitters need, so neither reconstructs a layout or asks the typechecker.
;; Node ids are dense, in first-reach order from the roots, and a parent always
;; precedes its children. A nominal type reached again while its own layout is
;; still being built is referenced through a `forward` node, so the graph has
;; no cycle. A node's members are contiguous: a struct or tuple lists its
;; fields; an enum lists each variant as a header (type -1, variant = its tag,
;; offset -1) followed by that variant's payload fields.
;;
;; Kinds and what `target`/`count` mean:
;; - scalar: an integer, float, bool, char or zero-sized unit/never.
;; - struct, tuple: inline fields; `register-words` is 1 or 2 when the value
;;   travels in one register or a register pair.
;; - enum: an i64 tag at offset 0 (`target` is its node), `count` variants;
;;   a variant's tag value is its declaration index.
;; - array: `count` inline elements of `target`.
;; - pointer: 8 bytes addressing a `target` value (Box, Ptr, and references
;;   other than the views and handles below).
;; - view: 16 bytes {data@0, len@8} over `target` elements: `(& (Slice T))`
;;   and `(& bytes)`.
;; - handle: 8 bytes addressing a {data@0, len@8} header over `target`
;;   elements: String, str, DynArray, and borrows of str or DynArray, which
;;   reuse the referent's handle.
;; - function: an 8-byte code pointer; forward: the nominal `target`;
;;   opaque: a type with no runtime layout.
(define compiler-debug-type-scalar : i64
  0)
(define compiler-debug-type-struct : i64
  1)
(define compiler-debug-type-tuple : i64
  2)
(define compiler-debug-type-enum : i64
  3)
(define compiler-debug-type-array : i64
  4)
(define compiler-debug-type-pointer : i64
  5)
(define compiler-debug-type-view : i64
  6)
(define compiler-debug-type-handle : i64
  7)
(define compiler-debug-type-function : i64
  8)
(define compiler-debug-type-forward : i64
  9)
(define compiler-debug-type-opaque : i64
  10)

(defstruct CompilerDebugTypeNode
  (kind i64)
  (name String)
  (size i64)
  (align i64)
  (target i64)
  (count i64)
  (register-words i64)
  (first-member i64)
  (member-count i64))

(defstruct CompilerDebugTypeMember
  (variant i64)
  (name String)
  (name-id i64)
  (type i64)
  (offset i64))

(defstruct CompilerDebugTypeGraph
  (nodes (__tl_dyn-array CompilerDebugTypeNode))
  (node-count i64)
  (members (__tl_dyn-array CompilerDebugTypeMember))
  (member-count i64))

(define (compiler-debug-type-graph-empty) : CompilerDebugTypeGraph
  (CompilerDebugTypeGraph
    (__tl_make-array CompilerDebugTypeNode 0)
    0
    (__tl_make-array CompilerDebugTypeMember 0)
    0))

;; Append NODE and return its id.
(define (compiler-debug-type-graph-push-node!
  [graph : (&mut graph CompilerDebugTypeGraph)]
  [node : CompilerDebugTypeNode]) : i64
  (let
    [id : i64 graph.node-count]
    (begin
      (when
        (>= id (array-length graph.nodes))
        (let
          [grown : (__tl_dyn-array CompilerDebugTypeNode)
            (__tl_make-array CompilerDebugTypeNode (+ 16 (* 2 id)))]
          [index : i64 0]
          (begin
            (while (< index id)
              (begin
                (set!
                  (array-ref grown index)
                  (owned_view.compiler-owned-array-element-shared-view
                    graph.nodes
                    index))
                (set! index (+ index 1))))
            (set! graph.nodes grown))))
      (set! (array-ref graph.nodes id) node)
      (set! graph.node-count (+ id 1))
      id)))

(define (compiler-debug-type-graph-set-node!
  [graph : (&mut graph CompilerDebugTypeGraph)]
  [id : i64]
  [node : CompilerDebugTypeNode]) : unit
  (set! (array-ref graph.nodes id) node))

(define (compiler-debug-type-graph-push-member!
  [graph : (&mut graph CompilerDebugTypeGraph)]
  [member : CompilerDebugTypeMember]) : unit
  (let
    [index : i64 graph.member-count]
    (begin
      (when
        (>= index (array-length graph.members))
        (let
          [grown : (__tl_dyn-array CompilerDebugTypeMember)
            (__tl_make-array CompilerDebugTypeMember (+ 16 (* 2 index)))]
          [copy : i64 0]
          (begin
            (while (< copy index)
              (begin
                (set!
                  (array-ref grown copy)
                  (owned_view.compiler-owned-array-element-shared-view
                    graph.members
                    copy))
                (set! copy (+ copy 1))))
            (set! graph.members grown))))
      (set! (array-ref graph.members index) member)
      (set! graph.member-count (+ index 1)))))

(define (compiler-debug-type-kind-name [kind : i64]) : String
  (cond
    [(= kind compiler-debug-type-scalar) "scalar"]
    [(= kind compiler-debug-type-struct) "struct"]
    [(= kind compiler-debug-type-tuple) "tuple"]
    [(= kind compiler-debug-type-enum) "enum"]
    [(= kind compiler-debug-type-array) "array"]
    [(= kind compiler-debug-type-pointer) "pointer"]
    [(= kind compiler-debug-type-view) "view"]
    [(= kind compiler-debug-type-handle) "handle"]
    [(= kind compiler-debug-type-function) "function"]
    [(= kind compiler-debug-type-forward) "forward"]
    [else "opaque"]))

;; One line per node and per member, deterministic for golden tests:
;; `tN kind name size=S align=A [target=tM] [count=C] [regs=R]`, then
;; `  .field tM @offset` or `  variant name =tag` / `    .index tM @offset`.
(define (compiler-debug-type-graph-render
  [graph : (& graph CompilerDebugTypeGraph)]) : String
  (let
    [buf : text_buf.TextBuf
      (text_buf.append
        (text_buf.empty)
        (str_cat.str-cat
          "debug-types v1 nodes="
          (string.int->string graph.node-count)
          "\n"))]
    [id : i64 0]
    (begin
      (while (< id graph.node-count)
        (let
          [node : CompilerDebugTypeNode
            (owned_view.compiler-owned-array-element-shared-view graph.nodes id)]
          [member : i64 node.first-member]
          (begin
            (set!
              buf
              (text_buf.append
                buf
                (str_cat.str-cat
                  "t"
                  (string.int->string id)
                  " "
                  (compiler-debug-type-kind-name node.kind)
                  " "
                  node.name
                  " size="
                  (string.int->string node.size)
                  " align="
                  (string.int->string node.align)
                  (if (>= node.target 0)
                    (str_cat.str-cat
                      " target=t"
                      (string.int->string node.target))
                    "")
                  (if (>= node.count 0)
                    (str_cat.str-cat " count=" (string.int->string node.count))
                    "")
                  (if (> node.register-words 0)
                    (str_cat.str-cat
                      " regs="
                      (string.int->string node.register-words))
                    "")
                  "\n")))
            (while (< member (+ node.first-member node.member-count))
              (let
                [row : CompilerDebugTypeMember
                  (owned_view.compiler-owned-array-element-shared-view
                    graph.members
                    member)]
                (begin
                  (set!
                    buf
                    (text_buf.append
                      buf
                      (if (< row.type 0)
                        (str_cat.str-cat
                          "  variant "
                          row.name
                          " ="
                          (string.int->string row.variant)
                          "\n")
                        (str_cat.str-cat
                          (if (< row.variant 0)
                            "  ."
                            "    .")
                          row.name
                          " t"
                          (string.int->string row.type)
                          " @"
                          (string.int->string row.offset)
                          "\n"))))
                  (set! member (+ member 1)))))
            (set! id (+ id 1)))))
      (text_buf.render buf))))