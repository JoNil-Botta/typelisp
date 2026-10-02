;; compiler_ast_types.tl - Self-hosted model of the real TypeLisp AST.
;;
;; Parser result/error wrappers, typechecker registries, inferred types, and
;; lowered IR metadata live elsewhere.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_intern as ci)
(import compiler_builtin_ids as cbi)
(import stdlib.dense_list)
(import compiler_owned_view as owned_view)

;; Arena access for the node-pool grow paths -- a regrown pool array must
;; be allocated in the persistent program arena, never a transient scratch arena
;; (which gets destroyed, leaving the global pool dangling). arena.tl has no
;; imports, so this adds no cycle.
(import stdlib.arena)

(defmacro (ast-global-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defmacro (ast-array-shared-view [items : Expr] [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

;; Recover the address of the complete place through a fixed-array reference
;; cell. During the owned-value bootstrap, taking `ptr-addr-of` on an aggregate
;; parameter directly can instead expose one projected payload field.
(defmacro (ast-place-address [place : Expr]) : Expr
  `(let
    [shared-ref (& ,place)]
    (unsafe
      (ptr-read (ptr-cast (__tl_array-data (array shared-ref)) : (Ptr u64))))))

;; An explicit shallow read of a local aggregate place. Use it only for a place
;; whose arena-backed owner remains live for the duration of the copied view.
(defmacro (ast-place-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(define (ast-decl-box-shared-view [value : (Box AstDecl)]) : AstDecl
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstDecl))))))

(cfg
  compiler-arena-debug
  (extern (tl_arena_debug_protect_never_reset [handle : i64]) : unit (:symbol "tl_arena_debug_protect_never_reset")))
(cfg
  compiler-arena-debug
  (extern (tl_arena_debug_assert_pool_install [handle : i64]) : unit (:symbol "tl_arena_debug_assert_pool_install")))

(define (compiler-arena-debug-protect-never-reset! [_handle : i64]) : unit
  (cfg compiler-arena-debug (tl_arena_debug_protect_never_reset _handle) unit))

(cfg
  compiler-arena-debug
  (extern (tl_arena_debug_retire_protected [handle : i64]) : unit (:symbol "tl_arena_debug_retire_protected")))

;; Only an explicit terminal owner boundary may call this after unpublishing
;; every retained view. Ordinary destroy/reset remains forbidden in debug mode.
(define (compiler-arena-retire-protected-owner! [handle : i64]) : unit
  (cfg
    compiler-arena-debug
    (tl_arena_debug_retire_protected handle)
    (unsafe
      (arena.tl_arena_destroy handle))))

(define (compiler-arena-debug-assert-pool-install! [_handle : i64]) : unit
  (cfg compiler-arena-debug (tl_arena_debug_assert_pool_install _handle) unit))

;; Compiler AST pool storage starts with 16 MiB instead of a general arena's
;; 64 MiB. Larger inputs append general chunks that pack multiple segments.
(define (ast-node-pool-arena-make) : i64
  (arena.tl_arena_make_small))

;; Hash/equality helpers for the ty-node hash-consing table below.
(import stdlib.hash)
(import stdlib.string)

;; Canonical nominal identity shared by symbols, type equality, backend ABI
;; metadata, and regalloc. Qualified names retain their structural owner, while
;; a root-qualified spelling collapses to the same key as its plain base. Opaque
;; generated and IR-owned ids are non-renderable and therefore remain distinct
;; even when their display text matches a qualified source name.
(define (ast-nominal-name-id-key [name-id : i64]) : i64
  (if (not (ci.intern-renderable-id? name-id))
    name-id
    (if (ci.intern-qualified? name-id)
      (let
        [module-id : i64 (ci.intern-qualified-module-id name-id)]
        [base-id : i64 (ci.intern-qualified-base-id name-id)]
        (if (or (< module-id 0) (= module-id cbi.compiler-builtin-id-fix-empty))
          base-id
          (ci.intern-composite-pair-id module-id base-id)))
      name-id)))

;; Nominal AST nodes carry either a parser intern id or a structural module/name
;; id. Rendering must decode the latter instead of indexing the intern pool with
;; the composite value.
(define (ast-nominal-name-id-part-display [name-id : i64]) : String
  (ci.intern-syntax-name-text-or name-id "<structural-nominal>"))

(define (ast-nominal-name-id-display [name-id : i64]) : String
  (if (or
    (ci.intern-composite-pair-id? name-id)
    (ci.intern-composite-triple-id? name-id))
    (let
      [cached : String (ci.intern-composite-rendered-name name-id)]
      (if (> (string.string-length cached) 0)
        cached
        (ci.intern-composite-rendered-name-record!
          name-id
          (if (ci.intern-composite-triple-id? name-id)
            (str_cat.str-cat
              (ast-nominal-name-id-part-display
                (ci.intern-composite-left-id-unchecked name-id))
              "/"
              (ast-nominal-name-id-part-display
                (ci.intern-composite-middle-id-unchecked name-id))
              "."
              (ast-nominal-name-id-part-display
                (ci.intern-composite-right-id-unchecked name-id)))
            (str_cat.str-cat
              (ast-nominal-name-id-part-display
                (ci.intern-composite-left-id-unchecked name-id))
              "/"
              (ast-nominal-name-id-part-display
                (ci.intern-composite-right-id-unchecked name-id)))))))
    (ast-nominal-name-id-part-display name-id)))

;; Explicit display boundary for specialization/normalization.  Unlike the
;; legacy helper above, every source/generated/structural lookup is resolved
;; through the supplied intern owner and therefore remains valid while another
;; compatibility table is installed by a caller or test harness.
(define (ast-nominal-name-id-display-with-intern-state
  [state : ci.InternCompatState]
  [name-id : i64]) : String
  (let
    [mutable-state : ci.InternCompatState (ast-place-shared-view state)]
    (if (or
      (ci.intern-compat-state-composite-pair-id? state name-id)
      (ci.intern-compat-state-composite-triple-id? state name-id))
      (let
        [cached : String
          (ci.intern-compat-state-composite-rendered-name state name-id)]
        (if (> (string.string-length cached) 0)
          cached
          (ci.intern-compat-state-composite-rendered-name-record!
            (&mut mutable-state)
            name-id
            (if (ci.intern-compat-state-composite-triple-id? state name-id)
              (str_cat.str-cat
                (ci.intern-compat-state-str
                  state
                  (ci.intern-compat-state-composite-left-id-unchecked
                    state
                    name-id))
                "/"
                (ci.intern-compat-state-str
                  state
                  (ci.intern-compat-state-composite-middle-id-unchecked
                    state
                    name-id))
                "."
                (ci.intern-compat-state-str
                  state
                  (ci.intern-compat-state-composite-right-id-unchecked
                    state
                    name-id)))
              (str_cat.str-cat
                (ci.intern-compat-state-str
                  state
                  (ci.intern-compat-state-composite-left-id-unchecked
                    state
                    name-id))
                "/"
                (ci.intern-compat-state-str
                  state
                  (ci.intern-compat-state-composite-right-id-unchecked
                    state
                    name-id)))))))
      (if (ci.intern-renderable-id? name-id)
        (ci.intern-compat-state-str state name-id)
        "<structural-nominal>"))))

(defstruct AstSourceSpan
  (start-line i32)
  (start-col i32)
  (end-line i32)
  (end-col i32))

(define (ast-source-span-box-shared-view [value : (Box AstSourceSpan)]) : AstSourceSpan
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstSourceSpan))))))

(define (ast-source-span
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : AstSourceSpan
  (AstSourceSpan
    (cast start-line : i32)
    (cast start-col : i32)
    (cast end-line : i32)
    (cast end-col : i32)))

(define (ast-source-span-start-line [span : AstSourceSpan]) : i64
  (cast span.start-line : i64))

(define (ast-source-span-start-col [span : AstSourceSpan]) : i64
  (cast span.start-col : i64))

(define (ast-source-span-end-line [span : AstSourceSpan]) : i64
  (cast span.end-line : i64))

(define (ast-source-span-end-col [span : AstSourceSpan]) : i64
  (cast span.end-col : i64))

(defenum AstLiteral
  (Int i64 String)
  (Float String)
  (Bool bool)
  (Char char)
  (String i64)
  (Unit))

(define (ast-lit-string-id [string-id : i64]) : AstLiteral
  (AstLiteral.String string-id))

(define (ast-lit-generated-string [text : String]) : AstLiteral
  (AstLiteral.String (ci.intern-generated-canonical-name text)))

(define (ast-lit-int [value : i64]) : AstLiteral
  (AstLiteral.Int value ""))

(define (ast-lit-int-value [lit : AstLiteral]) : i64
  (match lit
    [(AstLiteral.Int value _) value]
    [_ 0]))

(define (ast-lit-int-text [lit : AstLiteral]) : String
  (match lit
    [(AstLiteral.Int value text)
      (if (> (string.string-length text) 0)
        text
        (string.int->string value))]
    [_ ""]))

(define (ast-int-literal-negative? [text : (& text str)]) : bool
  (and (> (string.string-length text) 0) (= (string.string-ref text 0) '-')))

(define (ast-int-literal-digits-start [text : (& text str)]) : i64
  (if (ast-int-literal-negative? text)
    1
    0))

(define (ast-int-literal-base [text : (& text str)]) : i64
  (let
    [start : i64 (ast-int-literal-digits-start text)]
    [n : i64 (string.string-length text)]
    (if (< (+ start 1) n)
      (if (= (string.string-ref text start) '0')
        (let
          [prefix : char (string.string-ref text (+ start 1))]
          (cond
            [(or (= prefix 'x') (= prefix 'X')) 16]
            [(or (= prefix 'b') (= prefix 'B')) 2]
            [else 10]))
        10)
      10)))

(define (ast-int-literal-value-start [text : (& text str)]) : i64
  (let
    [start : i64 (ast-int-literal-digits-start text)]
    [base : i64 (ast-int-literal-base text)]
    (if (= base 10)
      start
      (+ start 2))))

(define (ast-int-literal-digit-value [c : char]) : i64
  (cond
    [(and (>= c '0') (<= c '9')) (- (cast c : i64) (cast '0' : i64))]
    [(and (>= c 'a') (<= c 'f')) (+ 10 (- (cast c : i64) (cast 'a' : i64)))]
    [(and (>= c 'A') (<= c 'F')) (+ 10 (- (cast c : i64) (cast 'A' : i64)))]
    [else 0]))

(define (ast-int-literal-skip-leading-zeroes
  [text : (& text str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    (begin
      (while (and (< i end) (= (string.string-ref text i) '0'))
        (set! i (+ i 1)))
      i)))

(define (ast-int-literal-magnitude-leq-limit?
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [limit : (& limit str)]) : bool
  (let
    [mag-start : i64 (ast-int-literal-skip-leading-zeroes text start end)]
    [mag-len : i64 (- end mag-start)]
    [limit-len : i64 (string.string-length limit)]
    (cond
      [(= mag-len 0) true]
      [(< mag-len limit-len) true]
      [(> mag-len limit-len) false]
      [else
        (let
          [i : i64 0]
          [result : i64 0]
          (begin
            (while (and (< i mag-len) (= result 0))
              (let
                [actual : i64
                  (ast-int-literal-digit-value
                    (string.string-ref text (+ mag-start i)))]
                [want : i64
                  (ast-int-literal-digit-value (string.string-ref limit i))]
                (begin
                  (if (< actual want)
                    (set! result -1)
                    (if (> actual want)
                      (set! result 1)
                      unit))
                  (set! i (+ i 1)))))
            (<= result 0)))])))

(define (ast-int-literal-magnitude-fits-limit?
  [text : (& text str)]
  [limit-dec : (& limit-dec str)]
  [limit-hex : (& limit-hex str)]
  [limit-bin : (& limit-bin str)]) : bool
  (let
    [base : i64 (ast-int-literal-base text)]
    [start : i64 (ast-int-literal-value-start text)]
    [end : i64 (string.string-length text)]
    (cond
      [(= base 16)
        (ast-int-literal-magnitude-leq-limit? text start end limit-hex)]
      [(= base 2)
        (ast-int-literal-magnitude-leq-limit? text start end limit-bin)]
      [else (ast-int-literal-magnitude-leq-limit? text start end limit-dec)])))

;; Rebuild the checked source magnitude as unsigned bits. The lexer payload is
;; only an i64 compatibility field and may already have crossed a signed
;; boundary before contextual typing selects the literal's actual type.
(define (ast-int-literal-u64-magnitude [text : (& text str)]) : u64
  (let
    [base : u64 (cast (ast-int-literal-base text) : u64)]
    [i : i64 (ast-int-literal-value-start text)]
    [n : i64 (string.string-length text)]
    [value : u64 (cast 0 : u64)]
    (begin
      (while (< i n)
        (begin
          (set!
            value
            (+
              (* value base)
              (cast
                (ast-int-literal-digit-value (string.string-ref text i))
                : u64)))
          (set! i (+ i 1))))
      value)))

(define (ast-int-literal-i64-bits [text : (& text str)]) : i64
  (let
    [magnitude : u64 (ast-int-literal-u64-magnitude text)]
    (if (ast-int-literal-negative? text)
      (cast (- (cast 0 : u64) magnitude) : i64)
      (cast magnitude : i64))))

;; Return the exact low 64 bits selected by checked literal source text, or the
;; compatibility payload for compiler-generated literals that have no text.
(define (ast-int-literal-value-or-payload [payload : i64] [text : (& text str)]) : i64
  (if (> (string.string-length text) 0)
    (ast-int-literal-i64-bits text)
    payload))

(defenum AstBinOp
  (Add)
  (Sub)
  (Mul)
  (Div)
  (Mod)
  (Eq)
  (Ne)
  (Lt)
  (Le)
  (Gt)
  (Ge)
  (And)
  (Or)
  (BitAnd)
  (BitOr)
  (BitXor)
  (Shl)
  (Shr))

(defenum AstUnOp
  (Neg)
  (Not)
  (BitNot))

(defenum AstReduceOp
  (Sum)
  (Min)
  (Max)
  (All)
  (Any))

;; C ABI, call effect and nullability belong to the canonical value type.
;; A nullable value can be stored, but only a checked non-null value is callable.
(defenum AstCFunctionMode
  (Nullable)
  (NonNull)
  (UnsafeNullable)
  (UnsafeNonNull))

(define (ast-c-function-mode-key [mode : AstCFunctionMode]) : i64
  (match mode
    [(AstCFunctionMode.Nullable) 0]
    [(AstCFunctionMode.NonNull) 1]
    [(AstCFunctionMode.UnsafeNullable) 2]
    [(AstCFunctionMode.UnsafeNonNull) 3]))

(define (ast-c-function-mode-nullable? [mode : AstCFunctionMode]) : bool
  (match mode
    [(AstCFunctionMode.Nullable) true]
    [(AstCFunctionMode.UnsafeNullable) true]
    [_ false]))

(define (ast-c-function-mode-unsafe? [mode : AstCFunctionMode]) : bool
  (match mode
    [(AstCFunctionMode.UnsafeNullable) true]
    [(AstCFunctionMode.UnsafeNonNull) true]
    [_ false]))

(define (ast-c-function-mode-name [mode : AstCFunctionMode]) : String
  (match mode
    [(AstCFunctionMode.Nullable) "nullable"]
    [(AstCFunctionMode.NonNull) "non-null"]
    [(AstCFunctionMode.UnsafeNullable) "unsafe-nullable"]
    [(AstCFunctionMode.UnsafeNonNull) "unsafe-non-null"]))

(define (ast-c-function-mode-eq? [a : AstCFunctionMode] [b : AstCFunctionMode]) : bool
  (= (ast-c-function-mode-key a) (ast-c-function-mode-key b)))

(defenum AstType
  (I64)
  (I32)
  (I16)
  (I8)
  (U64)
  (U32)
  (U16)
  (U8)
  (F64)
  (F32)
  (Bool)
  (Char)
  (String)
  (Str)
  (Bytes)
  (Unit)
  (Never)
  ;; User-facing macro code-as-data type. This is a single concrete
  ;; compile-time-only type; the produced runtime type is tracked internally by
  ;; CTFE values, not as a source-level type parameter.
  (Expr)
  (ExprList)
  (Func (Box AstTypeList) i64)
  (Tuple (Box AstTypeList))
  (Array i64 i64)
  (DynArray i64)
  (Box i64)
  (Region i64 i64)
  (Ref i64 i64)
  (MutRef i64 i64)
  (Enum i64)
  (EnumArgs i64 (Box AstLifetimeList))
  (Struct i64)
  (StructArgs i64 (Box AstLifetimeList))
  (Var i64)
  (VarArgs i64 (Box AstLifetimeList))
  (Ptr i64)
  (MutPtr i64)
  ;; Borrowed, unsized contiguous view. Source syntax and runtime semantics are
  ;; intentionally added in a later packet; this node is kept internal here.
  (Slice i64)
  ;; The signature id names a Func node used only for its parameter/result
  ;; structure. The wrapper is never equivalent to an ordinary Func value.
  ;; Keeping two scalar operands preserves the existing AstType node footprint.
  (CFunc i64 AstCFunctionMode)
  ;; `(:invalidate r T)`: a callable parameter of type T whose call destroys
  ;; the owner of lifetime `r` (#6670). The first operand is the lifetime name,
  ;; the second the inner type id. It is part of the callable's identity but
  ;; lowers exactly as T. Appended so every established AstType tag is stable.
  (Invalidate i64 i64))

(defstruct AstTypeList
  (slots (__tl_dyn-array i64))
  (len i64))

(defstruct AstLifetimeList
  (slots (__tl_dyn-array i64))
  (len i64))

(defenum AstMaybeType
  (No)
  (Some AstType))

(defenum AstMaybeNominalKey
  (None)
  (Some i64))

(defenum AstBorrowLifetime
  (Inferred)
  (Named i64))

(defenum AstParam
  (Param i64 AstType bool))

(defstruct AstParamList
  (slots (__tl_dyn-array AstParam))
  (len i64))

(defstruct AstMacroTypeKindList
  (slots (__tl_dyn-array i64))
  (len i64))

(defenum AstMacroParam
  (Param i64 AstType bool AstMacroTypeKindList))

(defstruct AstMacroParamList
  (slots (__tl_dyn-array AstMacroParam))
  (len i64))

(defenum AstFieldCleanup
  (No)
  (Fn ci.InternSyntaxId)
  (Owned))

(defenum AstFieldDef
  (Def ci.InternSyntaxId AstType AstFieldCleanup))

(defstruct AstFieldDefList
  (slots (__tl_dyn-array AstFieldDef))
  (len i64))

;; The declared `(:align N)` values of a `(:repr c)` struct's fields, by field
;; index (0 for a field that declares none). The array ends at the last field
;; that declares one, so a struct without field alignment shares one empty
;; array and the metadata costs nothing per field.
(defstruct AstFieldAligns
  (slots (__tl_dyn-array i64)))

;; `(:repr c)` carries the struct's declared `(:align N)` value (0 when absent)
;; and its fields' declared values. Explicit alignment is C-layout metadata
;; only.
(defenum AstStructRepr
  (Default)
  (C i64 AstFieldAligns))

;; How an extern is called. `C` and the C varargs forms are user externs.
;; `TypeLisp` is a package dependency's TypeLisp function as its consumer sees
;; it (#8485). It is called exactly like `C` today; it is the fact a
;; TypeLisp-to-TypeLisp calling convention will select on.
(defenum AstExternAbi
  (C)
  (CVarargsOpen)
  (CVarargsTyped AstType)
  (TypeLisp))

(defenum AstExternKind
  (Value)
  (Function))

(defenum AstExternLinkInput
  (Lib String)
  (Search String)
  (Arg String))

(defstruct AstExternLinkInputList
  (slots (__tl_dyn-array AstExternLinkInput))
  (len i64))

;; Linker-facing spellings are always ordinary renderable intern names. Syntax
;; identities must be reduced explicitly, so structural keys and missing raw
;; sentinels cannot reach render or surface-serialization paths.
(defenum AstFnExport
  (No)
  (Export ci.InternId))

(defenum AstSpmdParamClass
  (Uniform)
  (Varying))

(defstruct AstSpmdParamClassList
  (slots (__tl_dyn-array AstSpmdParamClass))
  (len i64))

(defenum AstSpmdResultClass
  (Unit)
  (Uniform)
  (Varying))

;; `index-param` is -1 for `none`, otherwise it is the zero-based source
;; parameter index named by the declaration.
(defstruct AstSpmdSpecialization
  (lanes i64)
  (args (Box AstSpmdParamClassList))
  (result AstSpmdResultClass)
  (index-param i64))

(defstruct AstSpmdSpecializationList
  (slots (__tl_dyn-array AstSpmdSpecialization))
  (len i64))

(defenum AstSpmdCallable
  (No)
  (Callable AstSpmdSpecializationList))

;; Package imports remain ordinary scalar externs outside SPMD regions.  The
;; loader copies just the TLCI selection fields into this AST-owned form so the
;; metadata has the same compile-job lifetime as the synthetic extern and the
;; lowerer does not depend on loader/TLCI global state. Every copied text field
;; is renderable linker/interface metadata, so keep it in the same nominal lane
;; as export symbols instead of reopening raw i64 identity boundaries.
(defstruct AstImportedSpmdSpecialization
  (abi ci.InternId)
  (backend ci.InternId)
  (lanes i64)
  (args ci.InternId)
  (result ci.InternId)
  (index-param i64)
  (symbol ci.InternId))

(defstruct AstImportedSpmdSpecializationList
  (slots (__tl_dyn-array AstImportedSpmdSpecialization))
  (len i64))

(defstruct AstImportedSpmdCallable
  (signature ci.InternId)
  (specializations AstImportedSpmdSpecializationList))

(defstruct AstImportedSpmdCallableList
  (slots (__tl_dyn-array AstImportedSpmdCallable))
  (len i64))

(defenum AstImportedSpmdMetadata
  (No)
  ;; Validated dependency identity, canonical helper name, and every TLCI
  ;; callable record having that name. Keep identity as owned strings rather
  ;; than adding otherwise-unused names to the package surface identity table.
  ;; An empty list marks a package-owned extern for which no record exists.
  (Package String String ci.InternId (Box AstImportedSpmdCallableList)))

;; Export and callable metadata are mutually exclusive. Keep the common `No`
;; and export cases inline at the old `AstFnExport` footprint, while boxing the
;; rare specialization list so every ordinary function remains allocation-free.
(defenum AstFnMetadata
  (No)
  (Export ci.InternId)
  (SpmdCallable (Box AstSpmdSpecializationList)))

(defenum AstExternMetadata
  ;; The final word packs whether the ABI was explicit and whether the
  ;; link-symbol spelling is the declaration's source spelling. The latter is
  ;; established at the parser/loader boundary so lowering never has to render
  ;; two ids and compare their bytes to recover that identity fact. Packing the
  ;; bits preserves the compact boxed metadata layout.
  (Metadata
    AstExternAbi
    ci.InternId
    AstExternLinkInputList
    i64
    AstImportedSpmdMetadata))

(define (ast-extern-metadata-flags
  [explicit-abi : bool]
  [symbol-matches-source : bool]) : i64
  (+
    (if explicit-abi
      1
      0)
    (if symbol-matches-source
      2
      0)))

(define (ast-extern-metadata-flags-explicit-abi? [flags : i64]) : bool
  (not (= (bit-and flags 1) 0)))

(define (ast-extern-metadata-flags-symbol-matches-source? [flags : i64]) : bool
  (not (= (bit-and flags 2) 0)))

(defenum AstStructCleanup
  (No)
  (Fn ci.InternSyntaxId))

(defenum AstEnumCleanup
  (No)
  (Fn ci.InternSyntaxId))

(defenum AstVariantPayloadCleanup
  (No)
  (Fn ci.InternSyntaxId)
  (Owned))

(defstruct AstVariantPayloadCleanupList
  (slots (__tl_dyn-array AstVariantPayloadCleanup))
  (len i64))

(defenum AstVariantDef
  (Def i64 AstTypeList AstVariantPayloadCleanupList))

(defstruct AstVariantDefList
  (slots (__tl_dyn-array AstVariantDef))
  (len i64))

(defenum AstPattern
  (Var i64 AstMaybeType)
  (Tuple (Box AstPatternList))
  (Wildcard)
  (Binding i64)
  (Variant i64 (Box AstPatternList))
  (Literal AstLiteral)
  (Array (Box AstPatternList))
  ;; `(slice p1 ... pk)` or `(slice p1 ... pk & rest)` over a borrowed Slice.
  ;; With `true`, the last item is the rest pattern (a binding or `_`) and the
  ;; items before it are the k element patterns.
  (Slice (Box AstPatternList) bool))

(defstruct AstPatternList
  (slots (__tl_dyn-array AstPattern))
  (len i64))

;; A Box owns its payload, so by-value ownership correctly forbids extracting an
;; owner-bearing list with `__tl-box-place`. These read-only walkers need the
;; same shallow handle view used by arena-backed AST nodes, not ownership of the
;; boxed allocation itself.
(define (ast-type-list-box-shared-view [value : (Box AstTypeList)]) : AstTypeList
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstTypeList))))))

(define (ast-lifetime-list-box-shared-view [value : (Box AstLifetimeList)]) : AstLifetimeList
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstLifetimeList))))))

(define (ast-pattern-list-box-shared-view [value : (Box AstPatternList)]) : AstPatternList
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstPatternList))))))

(define (ast-imported-spmd-callable-list-box-shared-view
  [value : (Box AstImportedSpmdCallableList)]) : AstImportedSpmdCallableList
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read
        (int->ptr (cast address : u64) : (Ptr AstImportedSpmdCallableList))))))

(define (ast-extern-metadata-box-shared-view [value : (Box AstExternMetadata)]) : AstExternMetadata
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstExternMetadata))))))

(defenum AstLetBinding
  (Binding i64 AstMaybeType i64))

(defstruct AstLetBindingList
  (slots (__tl_dyn-array AstLetBinding))
  (len i64))

(defenum AstResourceBinding
  (Binding i64 i64 i64 bool))

(defstruct AstResourceBindingList
  (slots (__tl_dyn-array AstResourceBinding))
  (len i64))

(defenum AstMatchArm
  (Arm AstPattern i64))

(defstruct AstMatchArmList
  (slots (__tl_dyn-array AstMatchArm))
  (len i64))

;; Boxed payload for `AstExpr.Lambda`. Lambdas are rare in the AST, but their
;; inline payload (an AstParamList plus an AstMaybeType) would make
;; `AstExpr.Lambda` the largest `AstExpr` variant -- and because a defenum is
;; laid out as `tag + max(variant)`, every node in the flat node pool would pay
;; for it. Boxing the payload collapses the variant to one word, shrinking every
;; node (pool footprint and the per-node `ast-node-get` copy) without slowing
;; the common small variants.
(defenum AstLambda
  (Lambda AstParamList AstMaybeType i64))

(define (ast-lambda-box-shared-view [value : (Box AstLambda)]) : AstLambda
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstLambda))))))

(define (ast-param-list-shallow-copy [value : (& value AstParamList)]) : AstParamList
  (let
    [count : i64 value.len]
    [slots : (__tl_dyn-array AstParam) (__tl_make-array AstParam count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast-array-shared-view value.slots index))
          (set! index (+ index 1))))
      (AstParamList slots count))))

(define (ast-lambda-box-owned-copy [value : (Box AstLambda)]) : AstLambda
  (match (deref value)
    [(AstLambda.Lambda params maybe-ret body-box)
      (AstLambda.Lambda
        (ast-param-list-shallow-copy (& params))
        maybe-ret
        body-box)]))

;; Boxed payload for `AstExpr.SpmdScan`. With ten fields including two
;; inline `AstType`s, the variant would be the largest `AstExpr` variant,
;; which sets the size of every node in the flat pool. spmd-scan is rare, so
;; boxing its payload collapses the variant to one word and shrinks every node.
(defenum AstSpmdScan
  (Scan AstReduceOp i64 AstType i64 i64 i64 AstType i64 i64 i64))

(define (ast-spmd-scan-box-shared-view [value : (Box AstSpmdScan)]) : AstSpmdScan
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstSpmdScan))))))

;; Boxed payload for `AstExpr.SpmdCompact`. The compact surface carries the
;; logical range binding, the selected-output slot binding, its uniform initial
;; cursor, the predicate, and the selected-only body.
(defenum AstSpmdCompact
  (Compact i64 AstType i64 i64 i64 AstType i64 i64 i64))

(define (ast-spmd-compact-box-shared-view [value : (Box AstSpmdCompact)]) : AstSpmdCompact
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstSpmdCompact))))))

;; Boxed payloads for wide AstExpr variants.
;; AstExpr.Let inlines AstLetBindingList; AstExpr.SpmdReduce has
;; an inline AstType plus six scalars. Boxing both keeps them off the row size.
(defenum AstLet
  (Let AstLetBindingList i64))

(define (ast-let-box-shared-view [value : (Box AstLet)]) : AstLet
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstLet))))))

(defenum AstSpmdReduce
  (Reduce AstReduceOp i64 AstType i64 i64 i64 i64))

(define (ast-spmd-reduce-box-shared-view [value : (Box AstSpmdReduce)]) : AstSpmdReduce
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstSpmdReduce))))))

;; Boxed payloads for wide AstExpr variants.
;; AstExpr.Foreach inlines an AstType plus four scalars;
;; AstExpr.WithResource inlines two list heads. Boxing both keeps them off the
;; row size.
(defenum AstForeach
  (Foreach i64 AstType i64 i64 i64))

(define (ast-foreach-box-shared-view [value : (Box AstForeach)]) : AstForeach
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstForeach))))))

(defenum AstWithResource
  (WithResource AstResourceBindingList AstExprList))

(define (ast-with-resource-box-shared-view [value : (Box AstWithResource)]) : AstWithResource
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstWithResource))))))

;; Boxed payload for `AstExpr.Match`. `AstExpr.Match i64 AstMatchArmList` would
;; be one of the largest variants (its arm list inlines AstMatchArm ->
;; AstPattern -> AstMaybeType -> AstType). Boxing it collapses the variant to
;; one word.
(defenum AstMatch
  (Match i64 AstMatchArmList))

(define (ast-match-box-shared-view [value : (Box AstMatch)]) : AstMatch
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstMatch))))))

(defenum AstExpr
  (Spanned i64 AstSourceSpan)
  (Literal AstLiteral)
  (Var i64)
  (Binary AstBinOp i64 i64)
  (Unary AstUnOp i64)
  (Call i64 AstExprList)
  (If i64 i64 i64)
  (Let (Box AstLet))
  (Lambda (Box AstLambda))
  (Tuple AstExprList)
  (TupleRef i64 i64)
  ;; Expression variant named `Array`; this is not unsized array type syntax.
  (Array AstExprList)
  (DynArray AstExprList)
  ;; Public `(make-array T N)`: unlike the private runtime-sized MakeArray,
  ;; `N` must fold to a non-negative compile-time integer and the result is
  ;; `(Array T N)`.
  (FixedMakeArray i64 i64)
  (MakeArray i64 i64)
  (ArrayRef i64 i64)
  (ArraySet i64 i64 i64)
  ;; Private checked move-out from private dynamic-buffer storage. The
  ;; second operand is a parallel bool liveness bitmap; the result is `(Tuple
  ;; bool T)` whose payload is meaningful only when its leading flag is true.
  (ArrayTake i64 i64 i64)
  (ArrayPush i64 i64)
  (StringRef i64 i64)
  (While i64 i64)
  (Begin AstExprList)
  ;; `(unsafe expr+)`: a `begin`-like block that additionally marks an
  ;; unsafe context (same runtime/type behavior as `begin`; the
  ;; unsafe-context flag is consumed by later raw-pointer ops).
  (Unsafe AstExprList)
  (Set i64 i64)
  ;; Move-safe replacement of an initialized mutable place. The place remains
  ;; an expression so lowering can evaluate every projection exactly once.
  (Replace i64 i64)
  (Ann i64 i64)
  (Cast i64 i64)
  (Borrow bool i64 i64)
  (Match (Box AstMatch))
  (Foreach (Box AstForeach))
  (SpmdReduce (Box AstSpmdReduce))
  (SpmdScan (Box AstSpmdScan))
  (SpmdCompact (Box AstSpmdCompact))
  (SpmdBroadcast i64 i64)
  (SpmdShuffle i64 i64)
  (SpmdProgramIndex)
  (SpmdProgramCount)
  (StructGet i64 i64)
  (StructSet i64 i64 i64)
  (WithRegion i64 AstExprList)
  (WithEscape i64 AstExprList)
  (WithScratch AstExprList)
  (InArena i64 AstExprList)
  (WithResource (Box AstWithResource))
  (Box i64)
  (BoxGet i64)
  (BoxTake i64)
  (BoxSet i64 i64)
  ;; Compile-time-only type value literal: `(type T)`.
  (TypeLiteral i64)
  ;; Zero/identity initialization. `(init : T)` carries `AstMaybeType.Some T`;
  ;; contextual `(init)` carries `AstMaybeType.No` until type checking/lowering sees
  ;; an expected type.
  (Init i64)
  ;; Compile-time evaluation form `(comptime expr)`. Parsed and
  ;; type-checked (as the inner expression's type); evaluated by CTFE.
  (Comptime i64)
  ;; Macro quote syntax. The reader desugars prefix quote tokens into
  ;; these list-headed forms before parsing:
  ;;   'x       -> (quote x)
  ;;   `x       -> (quasiquote x)
  ;;   ,x       -> (unquote x)
  ;;   ,@xs     -> (unquote-splicing xs)
  (Quote i64)
  (Quasiquote i64)
  (Unquote i64)
  (UnquoteSplicing i64)
  ;; Macro-only call operand syntax: `[expr expr]` bracket clauses are parsed
  ;; only inside call argument lists. Ordinary typechecking rejects this node;
  ;; macro binding consumes it for `ExprClause` operands.
  (BracketClause AstExprList)
  ;; Narrow Result-like propagation form `(try expr)`. The
  ;; convention recognizes concrete enums with one `Ok*` and one `Err*`
  ;; variant, each carrying exactly one payload.
  (Try i64)
  ;; General function-local early exit: `(return expr)` checks `expr` against
  ;; the enclosing function's return type and has the internal `never` type.
  (Return i64)
  ;; Loop-local early exits for scalar `while` loops. Both are zero-operand
  ;; forms and have the internal `never` type.
  (Break)
  (Continue)
  ;; Null raw-pointer construction `(ptr-null : T)` where `T` is `(Ptr U)` or
  ;; `(MutPtr U)`. Lowers to a pointer-sized zero; type is `T`.
  ;; The operand is an AstTypeId into the owning context's type pool, not an
  ;; inline AstType, which would widen the AstExpr row. Resolve it with the
  ;; reader that matches the pool the node came from.
  (PtrNull i64)
  ;; Null check `(ptr-null? p)` on a raw pointer. Result is `bool`.
  (PtrNullCheck i64)
  ;; Unsafe raw-pointer operations. The typechecker admits these only
  ;; inside `(unsafe ...)`; lowering maps them to existing pointer IR.
  (PtrAddrOf i64)
  (PtrRead i64)
  (PtrWrite i64 i64)
  (PtrOffset i64 i64)
  (PtrCast i64 i64)
  (PtrToInt i64)
  (IntToPtr i64 i64)
  ;; Low-level FFI bridge operations used by stdlib. These expose raw backing
  ;; storage and process entry state without synthesizing runtime wrapper calls.
  (StringData i64)
  (StringFromBytes i64 i64)
  (ArrayData i64)
  ;; Loader-generated payload for `(include-bin name "path")`. This is not a
  ;; source expression; it typechecks as `(__tl_dyn-array u8)` and lowers to
  ;; static data.
  (BinaryData String)
  (ProgramArgc)
  (ProgramArgv)
  (ProgramEnvp)
  ;; Inline CPU feature instructions. These lower directly to x86_64 `cpuid`
  ;; and `xgetbv` instructions, avoiding emitted forwarding helpers.
  (CpuIdEax i64 i64)
  (CpuIdEbx i64 i64)
  (CpuIdEcx i64 i64)
  (CpuIdEdx i64 i64)
  (Xgetbv i64)
  ;; Raw Linux x86_64 syscall. `(unsafe (syscall number a0 .. a5))` lowers
  ;; directly to a `syscall` instruction: the number plus up to six arguments.
  ;; Returns the raw kernel result in an i64 (negative is `-errno`); callers
  ;; translate errno.
  (Syscall AstExprList)
  ;; Private scalar-`for` planners stay append-only so self-hosted enum tag
  ;; ordinals for every established surface expression remain stable.
  ;; Every name operand is an expression so quasiquote can substitute a fresh
  ;; hygienic variable before the checker validates the final shape. Step's
  ;; optional item annotation is a type-syntax expression id; -1 means inferred.
  ;; Keep these payloads in the already-established AstExprList family. Four or
  ;; six inline i64 fields would exceed the pool's pinned 32-byte AstExpr stride,
  ;; while adding compiler-private nominal payload types to the public AST's
  ;; clone graph makes surface pruning retain unrelated helper families during
  ;; self-hosting.
  (ForOwnedState AstExprList)
  (ForOwnedStep AstExprList)
  ;; Sparse diagnostic provenance retained across macro expansion. The wrapper
  ;; is transparent to language semantics: `inner` is the produced expression,
  ;; while the provenance intern ID packs the caller path (-1 means inherit)
  ;; and primary-origin path, followed by the user-facing macro name. A negative
  ;; macro name marks caller-origin syntax without adding an expansion label.
  ;; The enclosing `Spanned` node supplies the invocation span. Keeping this
  ;; append-only preserves every established AstExpr tag and costs one node only
  ;; at an actual expansion boundary.
  (MacroExpansion i64 i64 i64)
  ;; `(foreach-active [lane : i64] body...)`: inside a foreach gang, run BODY
  ;; once per active lane in increasing lane order, with the lane-number
  ;; binding LANE (interned name) uniform. The body is one expression id; the
  ;; parser wraps several body forms in a `Begin`. Appended so every
  ;; established AstExpr tag ordinal stays stable.
  (ForeachActive i64 i64)
  ;; `(lane-value expr)`: inside a foreach-active body, the current lane's
  ;; value of the varying EXPR, as a uniform value.
  (LaneValue i64))

;; Tuple-place writes reuse `StructSet` internally so the public place syntax
;; can land without changing the serialized AstExpr ABI. Interned struct field
;; IDs are non-negative; negative field IDs are therefore an unambiguous private
;; encoding for literal tuple indexes.
(define (ast-tuple-set-field-id-from-index [index : i64]) : i64
  (- 0 (+ index 1)))

(define (ast-tuple-set-field-id? [field-id : i64]) : bool
  (< field-id 0))

(define (ast-tuple-set-index-from-field-id [field-id : i64]) : i64
  (- 0 (+ field-id 1)))

;; --- segmented AST node pool ---
;; AstExpr nodes live in fixed-size segments, referenced by AstNodeId (a flat
;; logical index) instead of i64. Parsing appends nodes without per-node boxes,
;; traversal resolves a segment and offset, and growth never relocates nodes,
;; and the loader needs no per-file deep clone (nodes already persist in the pool).
;; The pool is process-global and reset per compile (see ast-node-pool-reset!),
;; reusing its allocated segments; AstNodeId values stay valid because the pool only
;; grows within a compile (callers truncate via ast-node-pool-len and
;; ast-node-pool-reset-to! on parse error). The process-global pool is only the
;; compatibility fallback: compiler and lint drivers install state-owned pools
;; sized for their workloads before parsing. Keep enough room for direct
;; parser/typechecker smoke users without permanently paying for a second
;; selfhost-sized backing array. The fallback
;; retains the proven grow path for larger legacy callers.
;; Plain mutable globals keep the hot compatibility path simple and avoid the
;; global-struct reassignment that previously tripped an opt2 miscompile.
(define ast-expr-node-pool-segment-size : i64
  65536)
(define ast-type-node-pool-segment-size : i64
  1024)

;; Source provenance is owned by the expression pool, but deliberately does not
;; add another AstSourceSpan-sized column to every 32-byte AstExpr row.  A small
;; aligned i32 slot accompanies each expression segment.  Zero means no source
;; provenance, a positive value indexes the sparse canonical-span records, and
;; a negative value indexes the sparse ReSpan records used by an exceptional
;; view of an already-owned semantic node (principally quasiquote splices).
;;
;; `owner-node` is the Spanned wrapper whose push first established a canonical
;; span.  It makes suffix rollback deterministic: records are appended in node
;; push order and can be retired when their owner/view id is at or above a mark.
(defstruct AstExprCanonicalSpanRecord
  (semantic-node i32)
  (owner-node i32)
  (span AstSourceSpan))

(defstruct AstExprReSpan
  (view-node i32)
  (semantic-node i32)
  (span AstSourceSpan))

(defenum AstMaybeSourceSpan
  (No)
  (Some AstSourceSpan))

(defenum AstExprSpanOracleResult
  (NotSpanned)
  (CanonicalMatch)
  (ReSpanMatch)
  (MissingSidecar)
  (UnexpectedDifference))

(define ast-expr-span-record-initial-capacity : i64
  64)
(define ast-expr-span-slot-bytes : i64
  4)
(define ast-expr-semantic-wrapper-fuel-limit : i64
  ;; Keep a generous fixed guard so malformed/cyclic in-place rewrites fail closed
  ;; without walking a multi-million-node pool before every span write.
  256)
(define ast-expr-spanned-storage-tag : i64
  ;; AstExpr is append-only and Spanned is its first inline enum variant.
  0)
(define ast-expr-macro-expansion-storage-tag : i64
  ;; Keep synchronized with AstExpr's append-only inline variant order.
  83)
(define ast-expr-span-slot-segment-bytes : i64
  (* ast-expr-node-pool-segment-size ast-expr-span-slot-bytes))

(define (ast-source-span-eq? [a : AstSourceSpan] [b : AstSourceSpan]) : bool
  (and
    (= a.start-line b.start-line)
    (= a.start-col b.start-col)
    (= a.end-line b.end-line)
    (= a.end-col b.end-col)))

(define (ast-expr-span-slot-biased-segment-base
  [segment : (__tl_dyn-array i32)]
  [segment-index : i64]) : i64
  (-
    (cast
      (unsafe
        (ptr->int (ptr-cast (__tl_array-data segment) : (Ptr u8))))
      : i64)
    (* segment-index ast-expr-span-slot-segment-bytes)))

(define (ast-expr-span-slot-get-from-bases [segment-bases : i64] [id : i64]) : i64
  (let
    [biased-base : i64
      (unsafe
        (ptr-read (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 16))))]
    (cast
      (unsafe
        (ptr-read
          (int->ptr (+ biased-base (* id ast-expr-span-slot-bytes)) : (Ptr i32))))
      : i64)))

(define (ast-expr-span-slot-set-in-bases!
  [segment-bases : i64]
  [id : i64]
  [value : i64]) : unit
  (let
    [biased-base : i64
      (unsafe
        (ptr-read (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 16))))]
    (unsafe
      (ptr-write!
        (int->ptr
          (+ biased-base (* id ast-expr-span-slot-bytes))
          : (MutPtr i32))
        (cast value : i32)))))

;; --- node row strides: the single source of truth ---
;; `size-of` on an enum type value reports the handle width, not the compiler's
;; inline enum representation, so the inline row stride has to be stated here
;; and kept aligned with the compiler's own layout. These two numbers are
;; load-bearing POINTER ARITHMETIC, not bookkeeping: every unchecked pool load
;; and store multiplies an id by them, and the biased-base tables subtract a
;; segment multiple of them from each segment's real data pointer. A value that
;; disagrees with the compiler's layout produces wrong addresses silently --
;; memory corruption, not a type error. `ast-node-stride-pinned?` cross-checks
;; both against the layout the compiler actually gives an array slot.
;;
;; These are zero-argument FUNCTIONS, not globals, and that is deliberate.
;; Two other spellings have been investigated:
;;
;;   * A literal-initialised global folds to the same immediate, but naming the
;;     stride that way perturbs the SEED compiler's inliner: the stage0
;;     compiler then inlines `ty-node-get` into `ty-node-shallow-eq?`, and the
;;     resulting stage1 segfaults in `tc-move-check-expr`.
;;   * A `defmacro` was blocked because the macro expander did not descend into
;;     `(int->ptr x : (Ptr T))` operands. That traversal gap is fixed; changing
;;     this performance-sensitive representation still requires its own
;;     bootstrap check rather than riding that fix.
;;
;; A zero-arg function inlines and folds to the same immediate the literal
;; produced.
(define (ast-expr-node-bytes) : i64
  32)

(define (ast-type-node-bytes) : i64
  24)

(define ast-expr-node-pool-segment-bytes : i64
  ;; Arena allocation per segment, plus the array's separately profiled
  ;; 16-byte header.
  (* ast-expr-node-pool-segment-size (ast-expr-node-bytes)))
(define ast-type-node-pool-segment-bytes : i64
  (* ast-type-node-pool-segment-size (ast-type-node-bytes)))
(define ast-node-pool-max-segments : i64
  ;; Preserve the former type pool's practical four-million-node ceiling while
  ;; keeping the fixed base table small (32 KiB per pool).
  4096)

;; --- sentinel encodings for the AstExpr row ---
;; `AstExpr.Init` and `AstExpr.Borrow` carry a single i64 instead of an inline
;; `AstMaybeType` or `AstBorrowLifetime`, which would widen the row, with -1 as
;; the "absent" encoding, which is safe in both cases: an AstTypeId is a pool
;; index (>= 0) and a borrow lifetime name is an intern id (>= 0).
;;
;; The AstMaybeType twins are pool-aware because the payload is a type; the
;; borrow-lifetime twins are not, because the payload is a name id that
;; needs no pool.
(define ast-maybe-type-id-absent : i64
  -1)

(define (ast-borrow-lifetime-to-id [lifetime : AstBorrowLifetime]) : i64
  (match lifetime
    [(AstBorrowLifetime.Inferred) ast-maybe-type-id-absent]
    [(AstBorrowLifetime.Named name) name]))

(define (ast-borrow-lifetime-from-id [id : i64]) : AstBorrowLifetime
  (if (< id 0)
    (AstBorrowLifetime.Inferred)
    (AstBorrowLifetime.Named id)))

(define (ast-node-pool-segment-base-table-new) : (__tl_dyn-array i64)
  (__tl_make-array i64 ast-node-pool-max-segments))

(define (ast-expr-node-pool-biased-segment-base
  [segment : (__tl_dyn-array AstExpr)]
  [segment-index : i64]) : i64
  (-
    (cast
      (unsafe
        (ptr->int (ptr-cast (__tl_array-data segment) : (Ptr u8))))
      : i64)
    (* segment-index ast-expr-node-pool-segment-bytes)))

(define ast-node-pool-first-segment : (__tl_dyn-array AstExpr)
  (__tl_make-array AstExpr ast-expr-node-pool-segment-size))
(define ast-node-pool-segment-bases : i64
  (let
    [bases : (__tl_dyn-array i64) (ast-node-pool-segment-base-table-new)]
    (begin
      (set!
        (array-ref bases 0)
        (ast-expr-node-pool-biased-segment-base
          (ast-global-shared-view ast-node-pool-first-segment)
          0))
      (cast
        (unsafe
          (ptr->int (ptr-cast (__tl_array-data bases) : (Ptr u8))))
        : i64))))
(define ast-node-pool-segment-count : i64
  1)

;; The compatibility pool mirrors every expression segment with a provenance
;; slot segment.  Sparse record payloads live in the pool's base arena and grow
;; independently of the dense slot index.
(define ast-node-span-slot-first-segment : (__tl_dyn-array i32)
  (__tl_make-array i32 ast-expr-node-pool-segment-size))
(define ast-node-span-slot-segment-bases : i64
  (let
    [bases : (__tl_dyn-array i64) (ast-node-pool-segment-base-table-new)]
    (begin
      (set!
        (array-ref bases 0)
        (ast-expr-span-slot-biased-segment-base
          (ast-global-shared-view ast-node-span-slot-first-segment)
          0))
      (cast
        (unsafe
          (ptr->int (ptr-cast (__tl_array-data bases) : (Ptr u8))))
        : i64))))
(define ast-node-canonical-span-records : (__tl_dyn-array
    AstExprCanonicalSpanRecord)
  (__tl_make-array
    AstExprCanonicalSpanRecord
    ast-expr-span-record-initial-capacity))
(define ast-node-canonical-span-count : i64
  0)
(define ast-node-respan-records : (__tl_dyn-array AstExprReSpan)
  (__tl_make-array AstExprReSpan ast-expr-span-record-initial-capacity))
(define ast-node-respan-count : i64
  0)
(define ast-node-span-records-monotonic? : bool
  true)

;; The program (base) arena, captured at global-init while it is the
;; active arena (the seed make-array above proves an allocation has happened, so
;; this is the real base handle, not the pre-allocation 0 sentinel). The node
;; pools live here for the whole program; a grow MUST allocate the new backing
;; array here too, otherwise -- if the grow fires while a transient scratch arena
;; is active (lowering/optimize) -- the regrown global array is freed when that
;; scratch arena is destroyed, leaving the pool dangling (a non-deterministic
;; use-after-free).
(define node-pool-base-arena : i64
  (arena.tl_arena_current))

;; Stable identity of the installed pool arena. Unlike `node-pool-base-arena`,
;; this does not advance when payload persistence grows the arena chain.
(define node-pool-owner-arena : i64
  node-pool-base-arena)
(define ast-node-pool-storage-arena : i64
  0)
(define ty-node-pool-storage-arena : i64
  0)
(define ast-node-pool-count : i64
  0)

(define (node-pool-segment-count-for-capacity
  [capacity : i64]
  [segment-size : i64]) : i64
  (let
    [normalized : i64
      (if (< capacity 1)
        1
        capacity)]
    [segments : i64 (/ (+ normalized (- segment-size 1)) segment-size)]
    (if (> segments ast-node-pool-max-segments)
      ast-node-pool-max-segments
      segments)))

;: Current node count (also the next AstNodeId that ast-node-push will assign).
(define (ast-node-pool-len) : i64
  ast-node-pool-count)

;: Add one fixed-size backing segment without relocating earlier nodes.
(define (ast-node-pool-grow!) : unit
  (let
    [segment-index : i64 ast-node-pool-segment-count]
    [old-storage-arena : i64 ast-node-pool-storage-arena]
    [storage-root : i64
      (if (= old-storage-arena 0)
        (arena.tl_arena_make)
        old-storage-arena)]
    [new-segment : (__tl_dyn-array AstExpr)
      (in-arena
        (arena.Arena storage-root)
        (__tl_make-array AstExpr ast-expr-node-pool-segment-size))]
    [new-span-slots : (__tl_dyn-array i32)
      (in-arena
        (arena.Arena storage-root)
        (__tl_make-array i32 ast-expr-node-pool-segment-size))]
    (begin
      (unsafe
        (ptr-write!
          (ptr-offset
            (int->ptr ast-node-pool-segment-bases : (MutPtr i64))
            segment-index)
          (ast-expr-node-pool-biased-segment-base new-segment segment-index)))
      (unsafe
        (ptr-write!
          (ptr-offset
            (int->ptr ast-node-span-slot-segment-bases : (MutPtr i64))
            segment-index)
          (ast-expr-span-slot-biased-segment-base new-span-slots segment-index)))
      (set! ast-node-pool-storage-arena storage-root)
      (set! ast-node-pool-segment-count (+ segment-index 1)))))

(define (ast-expr-semantic-node-from-bases-fuel
  [expr-segment-bases : i64]
  [count : i64]
  [id : i64]
  [fuel : i64]) : i64
  ;; Loaded rows are normally backward-pointing, but ownership-preserving
  ;; in-place rewrites may legally copy a wrapper whose child has a later id.
  ;; Bounds plus finite fuel admit that case while cycles still fail closed.
  (if (or (< id 0) (>= id count) (<= fuel 0))
    -1
    ;; The row view is consumed by this match before recursion. This walker
    ;; never installs, resets, grows, or rewrites an expression pool, so no
    ;; view survives a generation or exact-row mutation boundary.
    (match (ast-expr-segment-bases-shared-view expr-segment-bases id)
      [(AstExpr.Spanned inner _)
        (if (or (< inner 0) (>= inner count) (= inner id))
          -1
          (ast-expr-semantic-node-from-bases-fuel
            expr-segment-bases
            count
            inner
            (- fuel 1)))]
      [(AstExpr.MacroExpansion inner _ _)
        (if (or (< inner 0) (>= inner count) (= inner id))
          -1
          (ast-expr-semantic-node-from-bases-fuel
            expr-segment-bases
            count
            inner
            (- fuel 1)))]
      [_ id])))

(define (ast-expr-semantic-node-from-bases
  [expr-segment-bases : i64]
  [count : i64]
  [id : i64]) : i64
  (ast-expr-semantic-node-from-bases-fuel
    expr-segment-bases
    count
    id
    (if (< count ast-expr-semantic-wrapper-fuel-limit)
      count
      ast-expr-semantic-wrapper-fuel-limit)))

(define (ast-node-canonical-span-records-grow!) : unit
  (let
    [old : (__tl_dyn-array AstExprCanonicalSpanRecord)
      (ast-global-shared-view ast-node-canonical-span-records)]
    [old-capacity : i64 (array-length old)]
    [new-capacity : i64 (* old-capacity 2)]
    [next : (__tl_dyn-array AstExprCanonicalSpanRecord)
      (in-arena
        (arena.Arena node-pool-base-arena)
        (__tl_make-array AstExprCanonicalSpanRecord new-capacity))]
    [i : i64 0]
    (begin
      (while (< i ast-node-canonical-span-count)
        (begin
          (set! (array-ref next i) (array-ref old i))
          (set! i (+ i 1))))
      (set! ast-node-canonical-span-records next))))

(define (ast-node-respan-records-grow!) : unit
  (let
    [old : (__tl_dyn-array AstExprReSpan)
      (ast-global-shared-view ast-node-respan-records)]
    [old-capacity : i64 (array-length old)]
    [new-capacity : i64 (* old-capacity 2)]
    [next : (__tl_dyn-array AstExprReSpan)
      (in-arena
        (arena.Arena node-pool-base-arena)
        (__tl_make-array AstExprReSpan new-capacity))]
    [i : i64 0]
    (begin
      (while (< i ast-node-respan-count)
        (begin
          (set! (array-ref next i) (array-ref old i))
          (set! i (+ i 1))))
      (set! ast-node-respan-records next))))

(define (ast-expr-semantic-node-from-span-slot
  [slot : i64]
  [canonical-records : (__tl_dyn-array AstExprCanonicalSpanRecord)]
  [canonical-count : i64]
  [respans : (__tl_dyn-array AstExprReSpan)]
  [respan-count : i64]) : i64
  (if (> slot 0)
    (let
      [index : i64 (- slot 1)]
      (if (>= index canonical-count)
        -1
        (cast
          (__tl-project-field (array-ref canonical-records index) semantic-node)
          : i64)))
    (if (< slot 0)
      (let
        [index : i64 (- (- 0 slot) 1)]
        (if (>= index respan-count)
          -1
          (cast
            (__tl-project-field (array-ref respans index) semantic-node)
            : i64)))
      -1)))

(define (ast-expr-span-record-direct-active! [id : i64] [span : AstSourceSpan]) : unit
  (begin
    (if (>=
      ast-node-canonical-span-count
      (array-length ast-node-canonical-span-records))
      (ast-node-canonical-span-records-grow!)
      unit)
    (let
      [index : i64 ast-node-canonical-span-count]
      (begin
        (set!
          (array-ref ast-node-canonical-span-records index)
          (AstExprCanonicalSpanRecord (cast id : i32) (cast id : i32) span))
        (set! ast-node-canonical-span-count (+ index 1))
        (ast-expr-span-slot-set-in-bases!
          ast-node-span-slot-segment-bases
          id
          (+ index 1))))))

(define (ast-expr-span-note-active! [id : i64] [node : AstExpr]) : unit
  (match node
    [(AstExpr.Spanned inner span)
      (let
        [inner-slot : i64
          (if (or (< inner 0) (>= inner ast-node-pool-count))
            0
            (ast-expr-span-slot-get-from-bases
              ast-node-span-slot-segment-bases
              inner))]
        [stored-semantic : i64
          (ast-expr-semantic-node-from-span-slot
            inner-slot
            (ast-global-shared-view ast-node-canonical-span-records)
            ast-node-canonical-span-count
            (ast-global-shared-view ast-node-respan-records)
            ast-node-respan-count)]
        [semantic : i64
          (if (>= stored-semantic 0)
            stored-semantic
            (ast-expr-semantic-node-from-bases
              ast-node-pool-segment-bases
              ast-node-pool-count
              inner))]
        (if (< semantic 0)
          unit
          (let
            [slot : i64
              (ast-expr-span-slot-get-from-bases
                ast-node-span-slot-segment-bases
                semantic)]
            ;; Pool snapshots share the dense slot sidecar. Restoring a snapshot
            ;; taken before canonical-record growth can therefore expose a slot
            ;; written by the newer generation while retaining the older record
            ;; count. Treat that out-of-generation slot as missing provenance and
            ;; establish a canonical record in the restored generation.
            (if (or (<= slot 0) (> slot ast-node-canonical-span-count))
              (begin
                (if (>=
                  ast-node-canonical-span-count
                  (array-length ast-node-canonical-span-records))
                  (ast-node-canonical-span-records-grow!)
                  unit)
                (let
                  [index : i64 ast-node-canonical-span-count]
                  (begin
                    (set!
                      (array-ref ast-node-canonical-span-records index)
                      (AstExprCanonicalSpanRecord
                        (cast semantic : i32)
                        (cast id : i32)
                        span))
                    (set! ast-node-canonical-span-count (+ index 1))
                    (ast-expr-span-slot-set-in-bases!
                      ast-node-span-slot-segment-bases
                      semantic
                      (+ index 1))
                    (ast-expr-span-slot-set-in-bases!
                      ast-node-span-slot-segment-bases
                      id
                      (+ index 1)))))
              (let
                [canonical-index : i64 (- slot 1)]
                [canonical : AstExprCanonicalSpanRecord
                  (array-ref ast-node-canonical-span-records canonical-index)]
                (if (ast-source-span-eq? canonical.span span)
                  (ast-expr-span-slot-set-in-bases!
                    ast-node-span-slot-segment-bases
                    id
                    slot)
                  (begin
                    (if (>=
                      ast-node-respan-count
                      (array-length ast-node-respan-records))
                      (ast-node-respan-records-grow!)
                      unit)
                    (let
                      [index : i64 ast-node-respan-count]
                      (begin
                        (set!
                          (array-ref ast-node-respan-records index)
                          (AstExprReSpan
                            (cast id : i32)
                            (cast semantic : i32)
                            span))
                        (set! ast-node-respan-count (+ index 1))
                        (ast-expr-span-slot-set-in-bases!
                          ast-node-span-slot-segment-bases
                          id
                          (- 0 (+ index 1))))))))))))]
    [(AstExpr.MacroExpansion inner _ _)
      (let
        [inner-slot : i64
          (if (or (< inner 0) (>= inner ast-node-pool-count))
            0
            (ast-expr-span-slot-get-from-bases
              ast-node-span-slot-segment-bases
              inner))]
        [semantic : i64
          (ast-expr-semantic-node-from-span-slot
            inner-slot
            (ast-global-shared-view ast-node-canonical-span-records)
            ast-node-canonical-span-count
            (ast-global-shared-view ast-node-respan-records)
            ast-node-respan-count)]
        (ast-expr-span-slot-set-in-bases!
          ast-node-span-slot-segment-bases
          id
          (if (< semantic 0)
            0
            inner-slot)))]
    [_ unit]))

;: Append `node` to the active pool and return its AstNodeId.
(define (ast-node-push-active [node : AstExpr]) : i64
  (begin
    (if (>=
      ast-node-pool-count
      (* ast-node-pool-segment-count ast-expr-node-pool-segment-size))
      (ast-node-pool-grow!)
      unit)
    (let
      [id : i64 ast-node-pool-count]
      [biased-base : i64
        (unsafe
          (ptr-read
            (ptr-offset
              (int->ptr ast-node-pool-segment-bases : (Ptr i64))
              (shr id 16))))]
      [dest : (MutPtr i64)
        (unsafe
          (int->ptr (+ biased-base (* id (ast-expr-node-bytes))) : (MutPtr i64)))]
      [source : (Ptr i64)
        (unsafe
          (int->ptr (ast-place-address node) : (Ptr i64)))]
      [storage-tag : i64
        (unsafe
          (ptr-read source))]
      (begin
        (unsafe
          (begin
            (ptr-write! dest (ptr-read source))
            (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
            (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))
            (ptr-write! (ptr-offset dest 3) (ptr-read (ptr-offset source 3)))))
        (set! ast-node-pool-count (+ id 1))
        ;; A truncated slot can still contain its prior generation's index.
        (ast-expr-span-slot-set-in-bases! ast-node-span-slot-segment-bases id 0)
        ;; Avoid a full AstExpr variant dispatch on the overwhelmingly common
        ;; non-wrapper push path. The inline tag is already in the source row
        ;; copied above; only the two provenance-bearing variants need work.
        (if (or
          (= storage-tag ast-expr-spanned-storage-tag)
          (= storage-tag ast-expr-macro-expansion-storage-tag))
          (ast-expr-span-note-active! id node)
          unit)
        (ast-node-pool-active-context-capture-expr!)
        id))))

;: Append `node` to the selected AST pool and return its AstNodeId.
(define (ast-node-push [node : AstExpr]) : i64
  (if ast-node-pool-compat-context-explicit?
    (ast-node-pool-context-expr-push
      (array-ref ast-node-pool-compat-context-cell 0)
      node)
    (ast-node-push-active node)))

;: Read the node at `id` from the installed AST pool.
;;
;; IDs below `count` prove both indices valid. Avoid two redundant bounds checks
;; in this hottest compiler operation, but cast through bytes so pointer offset
;; uses AstExpr's real inline stride (`ast-expr-node-bytes`) rather than
;; pointer-word stride.
;; Compatibility contexts install their backing state at the context boundary,
;; keeping the path branch-free.
(define (ast-node-get [id : i64]) : AstExpr
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset
            (int->ptr ast-node-pool-segment-bases : (Ptr i64))
            (shr id 16))))]
    (unsafe
      (ptr-read
        (int->ptr (+ biased-base (* id (ast-expr-node-bytes))) : (Ptr AstExpr))))))

;: Overwrite the node at `id` in the selected AST pool (used when a node is
;; rewritten in place).
(define (ast-node-set! [id : i64] [node : AstExpr]) : unit
  (if ast-node-pool-compat-context-explicit?
    (ast-node-pool-context-expr-set!
      (array-ref ast-node-pool-compat-context-cell 0)
      id
      node)
    (let
      [biased-base : i64
        (unsafe
          (ptr-read
            (ptr-offset
              (int->ptr ast-node-pool-segment-bases : (Ptr i64))
              (shr id 16))))]
      [dest : (MutPtr i64)
        (unsafe
          (int->ptr (+ biased-base (* id (ast-expr-node-bytes))) : (MutPtr i64)))]
      [source : (Ptr i64)
        (unsafe
          (int->ptr (ast-place-address node) : (Ptr i64)))]
      [prior-slot : i64
        (ast-expr-span-slot-get-from-bases ast-node-span-slot-segment-bases id)]
      (begin
        (unsafe
          (begin
            (ptr-write! dest (ptr-read source))
            (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
            (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))
            (ptr-write! (ptr-offset dest 3) (ptr-read (ptr-offset source 3)))))
        ;; In-place semantic rewrites retain the identity's canonical slot.  A
        ;; copied wrapper additionally establishes its per-use view immediately;
        ;; prefix rollback later rebuilds records in id order.
        (match (ast-global-shared-view node)
          [(AstExpr.Spanned _ _)
            (let
              [canonical-before : i64 ast-node-canonical-span-count]
              [respan-before : i64 ast-node-respan-count]
              (begin
                (ast-expr-span-slot-set-in-bases!
                  ast-node-span-slot-segment-bases
                  id
                  0)
                (ast-expr-span-note-active! id node)
                (if (or
                  (> ast-node-canonical-span-count canonical-before)
                  (> ast-node-respan-count respan-before))
                  (set! ast-node-span-records-monotonic? false)
                  unit)
                (ast-node-pool-active-context-capture-expr!)))]
          [(AstExpr.MacroExpansion _ _ _)
            ;; Expansion frames delegate source ownership to their child.
            (begin
              (ast-expr-span-slot-set-in-bases!
                ast-node-span-slot-segment-bases
                id
                0)
              (ast-expr-span-note-active! id node)
              (ast-node-pool-active-context-capture-expr!))]
          [_
            (if (< prior-slot 0)
              (let
                [index : i64 (- (- 0 prior-slot) 1)]
                (if (or (< index 0) (>= index ast-node-respan-count))
                  (begin
                    (ast-expr-span-slot-set-in-bases!
                      ast-node-span-slot-segment-bases
                      id
                      0)
                    (ast-node-pool-active-context-capture-expr!))
                  (begin
                    ;; The per-use wrapper became a new semantic identity. Its
                    ;; prior view is now that identity's original provenance.
                    (set! ast-node-span-records-monotonic? false)
                    (ast-expr-span-record-direct-active!
                      id
                      (__tl-project-field
                        (array-ref ast-node-respan-records index)
                        span))
                    (ast-node-pool-active-context-capture-expr!))))
              unit)])))))

;: Truncate the pool back to `mark` nodes (used to discard nodes from a failed
;: parse). Reset to 0 between compiles so a fresh compile reuses its segments.
(define (ast-expr-span-reset-active-to! [mark : i64]) : unit
  (if (= mark 0)
    (begin
      ;; Reused ids clear their own slots on push, so the common whole-compile
      ;; reset is O(1) even for a million-node pool.
      (set! ast-node-canonical-span-count 0)
      (set! ast-node-respan-count 0)
      (set! ast-node-span-records-monotonic? true))
    (if ast-node-span-records-monotonic?
      (let
        [id : i64 mark]
        [canonical-count : i64 ast-node-canonical-span-count]
        [respan-count : i64 ast-node-respan-count]
        (begin
          ;; The common transactional rollback touches only the discarded
          ;; suffix and the records whose owner/view lies in that suffix.
          (while (< id ast-node-pool-count)
            (begin
              (ast-expr-span-slot-set-in-bases!
                ast-node-span-slot-segment-bases
                id
                0)
              (set! id (+ id 1))))
          (while (and
            (> canonical-count 0)
            (>=
              (cast
                (__tl-project-field
                  (array-ref
                    ast-node-canonical-span-records
                    (- canonical-count 1))
                  owner-node)
                : i64)
              mark))
            (let
              [record : AstExprCanonicalSpanRecord
                (array-ref
                  ast-node-canonical-span-records
                  (- canonical-count 1))]
              [semantic : i64 (cast record.semantic-node : i64)]
              (begin
                (if (and
                  (< semantic mark)
                  (=
                    (ast-expr-span-slot-get-from-bases
                      ast-node-span-slot-segment-bases
                      semantic)
                    canonical-count))
                  (ast-expr-span-slot-set-in-bases!
                    ast-node-span-slot-segment-bases
                    semantic
                    0)
                  unit)
                (set! canonical-count (- canonical-count 1)))))
          (while (and
            (> respan-count 0)
            (>=
              (cast
                (__tl-project-field
                  (array-ref ast-node-respan-records (- respan-count 1))
                  view-node)
                : i64)
              mark))
            (set! respan-count (- respan-count 1)))
          (set! ast-node-canonical-span-count canonical-count)
          (set! ast-node-respan-count respan-count)))
      (let
        [id : i64 mark]
        (while (< id ast-node-pool-count)
          (let
            [slot : i64
              (ast-expr-span-slot-get-from-bases
                ast-node-span-slot-segment-bases
                id)]
            (begin
              (if (and (> slot 0) (<= slot ast-node-canonical-span-count))
                (let
                  [record : AstExprCanonicalSpanRecord
                    (array-ref ast-node-canonical-span-records (- slot 1))]
                  [semantic : i64 (cast record.semantic-node : i64)]
                  (if (and
                    (= (cast record.owner-node : i64) id)
                    (< semantic mark)
                    (=
                      (ast-expr-span-slot-get-from-bases
                        ast-node-span-slot-segment-bases
                        semantic)
                      slot))
                    (ast-expr-span-slot-set-in-bases!
                      ast-node-span-slot-segment-bases
                      semantic
                      0)
                    unit))
                unit)
              (ast-expr-span-slot-set-in-bases!
                ast-node-span-slot-segment-bases
                id
                0)
              (set! id (+ id 1)))))))))

(define (ast-node-pool-truncate! [mark : i64]) : unit
  (begin
    (ast-expr-span-reset-active-to! mark)
    (set! ast-node-pool-count mark)
    (ast-node-pool-active-context-capture-expr!)))

(define (ast-node-pool-reset-to! [mark : i64]) : unit
  (ast-node-pool-truncate! mark))

(define (ast-node-pool-reset!) : unit
  (ast-node-pool-truncate! 0))

;; State-owned expression node pools are the migration substrate for compiler
;; workers. The current compiler hot path still uses the process-global wrappers
;; above until parser/typechecker/driver state is threaded through every call.
(defstruct AstExprNodePoolState
  (segment-bases i64)
  (count i64)
  (base-arena i64)
  (storage-arena i64)
  (segment-count i64)
  (span-slot-segment-bases i64)
  (canonical-span-records (__tl_dyn-array AstExprCanonicalSpanRecord))
  (canonical-span-count i64)
  (respan-records (__tl_dyn-array AstExprReSpan))
  (respan-count i64)
  (span-records-monotonic? bool))

(define (ast-expr-node-pool-state-with-base-arena
  [pool : AstExprNodePoolState]
  [base-arena : i64]) : AstExprNodePoolState
  (AstExprNodePoolState
    pool.segment-bases
    pool.count
    base-arena
    pool.storage-arena
    pool.segment-count
    pool.span-slot-segment-bases
    pool.canonical-span-records
    pool.canonical-span-count
    pool.respan-records
    pool.respan-count
    pool.span-records-monotonic?))

(defenum AstExprNodePoolPushResult
  (AstExprNodePoolPushOk AstExprNodePoolState i64))

(define (node-pool-state-normalize-capacity [capacity : i64]) : i64
  (if (< capacity 1)
    1
    capacity))

(define (ast-expr-node-pool-state-init [capacity : i64] [base-arena : i64]) : AstExprNodePoolState
  (let
    [segment-count : i64
      (node-pool-segment-count-for-capacity
        capacity
        ast-expr-node-pool-segment-size)]
    [segment-bases : (__tl_dyn-array i64)
      (in-arena (arena.Arena base-arena) (ast-node-pool-segment-base-table-new))]
    [span-slot-segment-bases : (__tl_dyn-array i64)
      (in-arena (arena.Arena base-arena) (ast-node-pool-segment-base-table-new))]
    [canonical-span-records : (__tl_dyn-array AstExprCanonicalSpanRecord)
      (in-arena
        (arena.Arena base-arena)
        (__tl_make-array
          AstExprCanonicalSpanRecord
          ast-expr-span-record-initial-capacity))]
    [respan-records : (__tl_dyn-array AstExprReSpan)
      (in-arena
        (arena.Arena base-arena)
        (__tl_make-array AstExprReSpan ast-expr-span-record-initial-capacity))]
    [storage-root : i64 (ast-node-pool-arena-make)]
    [segment-index : i64 0]
    (begin
      (while (< segment-index segment-count)
        (let
          [segment : (__tl_dyn-array AstExpr)
            (in-arena
              (arena.Arena storage-root)
              (__tl_make-array AstExpr ast-expr-node-pool-segment-size))]
          [span-slots : (__tl_dyn-array i32)
            (in-arena
              (arena.Arena storage-root)
              (__tl_make-array i32 ast-expr-node-pool-segment-size))]
          (begin
            (set!
              (array-ref segment-bases segment-index)
              (ast-expr-node-pool-biased-segment-base segment segment-index))
            (set!
              (array-ref span-slot-segment-bases segment-index)
              (ast-expr-span-slot-biased-segment-base span-slots segment-index))
            (set! segment-index (+ segment-index 1)))))
      (AstExprNodePoolState
        (cast
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data segment-bases) : (Ptr u8))))
          : i64)
        0
        base-arena
        storage-root
        segment-count
        (cast
          (unsafe
            (ptr->int
              (ptr-cast (__tl_array-data span-slot-segment-bases) : (Ptr u8))))
          : i64)
        canonical-span-records
        0
        respan-records
        0
        true))))

(define (ast-expr-node-pool-state-create [capacity : i64]) : AstExprNodePoolState
  (ast-expr-node-pool-state-init capacity (arena.tl_arena_current)))

(define (ast-expr-node-pool-state-len [pool : (& pool AstExprNodePoolState)]) : i64
  pool.count)

(define (ast-expr-node-pool-state-capacity
  [pool : (& pool AstExprNodePoolState)]) : i64
  (* pool.segment-count ast-expr-node-pool-segment-size))

(define (ast-expr-node-pool-state-with-canonical-spans
  [pool : AstExprNodePoolState]
  [records : (__tl_dyn-array AstExprCanonicalSpanRecord)]
  [count : i64]) : AstExprNodePoolState
  (AstExprNodePoolState
    pool.segment-bases
    pool.count
    pool.base-arena
    pool.storage-arena
    pool.segment-count
    pool.span-slot-segment-bases
    records
    count
    pool.respan-records
    pool.respan-count
    pool.span-records-monotonic?))

(define (ast-expr-node-pool-state-with-span-record-order
  [pool : AstExprNodePoolState]
  [monotonic? : bool]) : AstExprNodePoolState
  (AstExprNodePoolState
    pool.segment-bases
    pool.count
    pool.base-arena
    pool.storage-arena
    pool.segment-count
    pool.span-slot-segment-bases
    pool.canonical-span-records
    pool.canonical-span-count
    pool.respan-records
    pool.respan-count
    monotonic?))

(define (ast-expr-node-pool-state-canonical-records-grow
  [pool : AstExprNodePoolState]) : AstExprNodePoolState
  (let
    [old : (__tl_dyn-array AstExprCanonicalSpanRecord)
      (ast-global-shared-view pool.canonical-span-records)]
    [next-capacity : i64 (* (array-length old) 2)]
    [next : (__tl_dyn-array AstExprCanonicalSpanRecord)
      (in-arena
        (arena.Arena pool.base-arena)
        (__tl_make-array AstExprCanonicalSpanRecord next-capacity))]
    [count : i64 pool.canonical-span-count]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref next i) (array-ref old i))
          (set! i (+ i 1))))
      (ast-expr-node-pool-state-with-canonical-spans pool next count))))

(define (ast-expr-node-pool-state-record-direct-span
  [pool : AstExprNodePoolState]
  [id : i64]
  [span : AstSourceSpan]) : AstExprNodePoolState
  (let
    [ready : AstExprNodePoolState
      (if (>=
        pool.canonical-span-count
        (array-length pool.canonical-span-records))
        (ast-expr-node-pool-state-canonical-records-grow pool)
        pool)]
    [index : i64 ready.canonical-span-count]
    [records : (__tl_dyn-array AstExprCanonicalSpanRecord)
      (ast-global-shared-view ready.canonical-span-records)]
    (begin
      (set!
        (array-ref records index)
        (AstExprCanonicalSpanRecord (cast id : i32) (cast id : i32) span))
      (ast-expr-span-slot-set-in-bases!
        ready.span-slot-segment-bases
        id
        (+ index 1))
      (ast-expr-node-pool-state-with-canonical-spans ready records (+ index 1)))))

(define (ast-expr-node-pool-state-note-span
  [pool : AstExprNodePoolState]
  [id : i64]
  [node : AstExpr]) : AstExprNodePoolState
  (let
    [next : AstExprNodePoolState pool]
    (begin
      (ast-expr-node-pool-state-note-span-in-place! (&mut next) id node)
      next)))

(define (ast-expr-node-pool-state-span-reset-to
  [pool : AstExprNodePoolState]
  [mark : i64]) : AstExprNodePoolState
  (if (= mark 0)
    (AstExprNodePoolState
      pool.segment-bases
      mark
      pool.base-arena
      pool.storage-arena
      pool.segment-count
      pool.span-slot-segment-bases
      pool.canonical-span-records
      0
      pool.respan-records
      0
      true)
    (if pool.span-records-monotonic?
      (let
        [id : i64 mark]
        [canonical-count : i64 pool.canonical-span-count]
        [respan-count : i64 pool.respan-count]
        (begin
          (while (< id pool.count)
            (begin
              (ast-expr-span-slot-set-in-bases!
                pool.span-slot-segment-bases
                id
                0)
              (set! id (+ id 1))))
          (while (and
            (> canonical-count 0)
            (>=
              (cast
                (__tl-project-field
                  (array-ref pool.canonical-span-records (- canonical-count 1))
                  owner-node)
                : i64)
              mark))
            (let
              [record : AstExprCanonicalSpanRecord
                (array-ref pool.canonical-span-records (- canonical-count 1))]
              [semantic : i64 (cast record.semantic-node : i64)]
              (begin
                (if (and
                  (< semantic mark)
                  (=
                    (ast-expr-span-slot-get-from-bases
                      pool.span-slot-segment-bases
                      semantic)
                    canonical-count))
                  (ast-expr-span-slot-set-in-bases!
                    pool.span-slot-segment-bases
                    semantic
                    0)
                  unit)
                (set! canonical-count (- canonical-count 1)))))
          (while (and
            (> respan-count 0)
            (>=
              (cast
                (__tl-project-field
                  (array-ref pool.respan-records (- respan-count 1))
                  view-node)
                : i64)
              mark))
            (set! respan-count (- respan-count 1)))
          (AstExprNodePoolState
            pool.segment-bases
            mark
            pool.base-arena
            pool.storage-arena
            pool.segment-count
            pool.span-slot-segment-bases
            pool.canonical-span-records
            canonical-count
            pool.respan-records
            respan-count
            true)))
      (let
        [id : i64 mark]
        (begin
          ;; A rare in-place rewrite can append an older record after newer
          ;; suffix records. Retire the suffix by its dense owner slots instead
          ;; of replaying every retained AST node. Sparse record storage may
          ;; keep unreachable entries until the next whole-generation reset.
          (while (< id pool.count)
            (let
              [slot : i64
                (ast-expr-span-slot-get-from-bases
                  pool.span-slot-segment-bases
                  id)]
              (begin
                (if (and (> slot 0) (<= slot pool.canonical-span-count))
                  (let
                    [record : AstExprCanonicalSpanRecord
                      (array-ref pool.canonical-span-records (- slot 1))]
                    [semantic : i64 (cast record.semantic-node : i64)]
                    (if (and
                      (= (cast record.owner-node : i64) id)
                      (< semantic mark)
                      (=
                        (ast-expr-span-slot-get-from-bases
                          pool.span-slot-segment-bases
                          semantic)
                        slot))
                      (ast-expr-span-slot-set-in-bases!
                        pool.span-slot-segment-bases
                        semantic
                        0)
                      unit))
                  unit)
                (ast-expr-span-slot-set-in-bases!
                  pool.span-slot-segment-bases
                  id
                  0)
                (set! id (+ id 1)))))
          (AstExprNodePoolState
            pool.segment-bases
            mark
            pool.base-arena
            pool.storage-arena
            pool.segment-count
            pool.span-slot-segment-bases
            pool.canonical-span-records
            pool.canonical-span-count
            pool.respan-records
            pool.respan-count
            false))))))

(define (ast-expr-node-pool-state-reset-to
  [pool : AstExprNodePoolState]
  [mark : i64]) : AstExprNodePoolState
  (ast-expr-node-pool-state-span-reset-to pool mark))

;; Hot explicit-owner pushes mutate the one-element pool cell directly. The
;; segment table is stable for the owner's lifetime: growth installs a fresh
;; segment before `id` is resolved, and no node reference is kept across that
;; growth or a later reset. This avoids rebuilding and returning the 11-field
;; state value for every expression while retaining the value API below for
;; snapshot-oriented callers and tests.
(define (ast-expr-node-pool-state-grow-in-place!
  [pool : (&mut pool AstExprNodePoolState)]) : unit
  (let
    [segment-index : i64 pool.segment-count]
    [storage-arena : i64 pool.storage-arena]
    [new-segment : (__tl_dyn-array AstExpr)
      (in-arena
        (arena.Arena storage-arena)
        (__tl_make-array AstExpr ast-expr-node-pool-segment-size))]
    [new-span-slots : (__tl_dyn-array i32)
      (in-arena
        (arena.Arena storage-arena)
        (__tl_make-array i32 ast-expr-node-pool-segment-size))]
    (begin
      (unsafe
        (ptr-write!
          (ptr-offset
            (int->ptr pool.segment-bases : (MutPtr i64))
            segment-index)
          (ast-expr-node-pool-biased-segment-base new-segment segment-index)))
      (unsafe
        (ptr-write!
          (ptr-offset
            (int->ptr pool.span-slot-segment-bases : (MutPtr i64))
            segment-index)
          (ast-expr-span-slot-biased-segment-base new-span-slots segment-index)))
      (set! pool.segment-count (+ segment-index 1)))))

(define (ast-expr-node-pool-state-canonical-records-reserve-in-place!
  [pool : (&mut pool AstExprNodePoolState)]
  [capacity : i64]) : unit
  (if (<= capacity (array-length pool.canonical-span-records))
    unit
    (let
      [next : (__tl_dyn-array AstExprCanonicalSpanRecord)
        (in-arena
          (arena.Arena pool.base-arena)
          (__tl_make-array AstExprCanonicalSpanRecord capacity))]
      [count : i64 pool.canonical-span-count]
      [i : i64 0]
      (begin
        ;; Records contain only scalar ids/spans. The exclusive pool borrow
        ;; keeps both arena-backed arrays alive for this copy, and no element
        ;; pointer is retained when the new backing array is installed. The old
        ;; array stays in the base arena: snapshots of this pool may still
        ;; read it.
        (while (< i count)
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset (__tl_array-data next) i)
                (ptr-read
                  (ptr-offset (__tl_array-data pool.canonical-span-records) i))))
            (set! i (+ i 1))))
        (set! pool.canonical-span-records next)))))

(define (ast-expr-node-pool-state-canonical-records-grow-in-place!
  [pool : (&mut pool AstExprNodePoolState)]) : unit
  (ast-expr-node-pool-state-canonical-records-reserve-in-place!
    pool
    (* (array-length pool.canonical-span-records) 2)))

(define (ast-expr-node-pool-state-respan-records-grow-in-place!
  [pool : (&mut pool AstExprNodePoolState)]) : unit
  (let
    [next-capacity : i64 (* (array-length pool.respan-records) 2)]
    [next : (__tl_dyn-array AstExprReSpan)
      (in-arena
        (arena.Arena pool.base-arena)
        (__tl_make-array AstExprReSpan next-capacity))]
    [count : i64 pool.respan-count]
    [i : i64 0]
    (begin
      ;; ReSpan rows are scalar-only too; the raw copy is scoped entirely before
      ;; replacing the array descriptor and cannot cross reset or compaction.
      (while (< i count)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset (__tl_array-data next) i)
              (ptr-read (ptr-offset (__tl_array-data pool.respan-records) i))))
          (set! i (+ i 1))))
      (set! pool.respan-records next))))

(define (ast-expr-node-pool-state-note-span-in-place!
  [pool : (&mut pool AstExprNodePoolState)]
  [id : i64]
  [node : AstExpr]) : unit
  (match node
    [(AstExpr.Spanned inner span)
      (let
        [inner-slot : i64
          (if (or (< inner 0) (>= inner pool.count))
            0
            (ast-expr-span-slot-get-from-bases
              pool.span-slot-segment-bases
              inner))]
        [stored-semantic : i64
          (ast-expr-semantic-node-from-span-slot
            inner-slot
            (unsafe
              (ptr-read
                (ptr-cast
                  (__tl_array-data (array (& pool.canonical-span-records)))
                  : (Ptr (__tl_dyn-array AstExprCanonicalSpanRecord)))))
            pool.canonical-span-count
            (unsafe
              (ptr-read
                (ptr-cast
                  (__tl_array-data (array (& pool.respan-records)))
                  : (Ptr (__tl_dyn-array AstExprReSpan)))))
            pool.respan-count)]
        [semantic : i64
          (if (>= stored-semantic 0)
            stored-semantic
            (ast-expr-semantic-node-from-bases
              pool.segment-bases
              pool.count
              inner))]
        (if (< semantic 0)
          unit
          (let
            [slot : i64
              (ast-expr-span-slot-get-from-bases
                pool.span-slot-segment-bases
                semantic)]
            ;; Snapshot generations share the dense slot sidecar. As in the
            ;; value path, an out-of-generation slot establishes a new record.
            (if (or (<= slot 0) (> slot pool.canonical-span-count))
              (begin
                (if (>=
                  pool.canonical-span-count
                  (array-length pool.canonical-span-records))
                  (ast-expr-node-pool-state-canonical-records-grow-in-place!
                    pool)
                  unit)
                (let
                  [index : i64 pool.canonical-span-count]
                  (begin
                    (set!
                      (array-ref pool.canonical-span-records index)
                      (AstExprCanonicalSpanRecord
                        (cast semantic : i32)
                        (cast id : i32)
                        span))
                    (set! pool.canonical-span-count (+ index 1))
                    (ast-expr-span-slot-set-in-bases!
                      pool.span-slot-segment-bases
                      semantic
                      (+ index 1))
                    (ast-expr-span-slot-set-in-bases!
                      pool.span-slot-segment-bases
                      id
                      (+ index 1)))))
              (let
                [canonical-index : i64 (- slot 1)]
                [canonical : AstExprCanonicalSpanRecord
                  (array-ref pool.canonical-span-records canonical-index)]
                (if (and
                  (= canonical.span.start-line span.start-line)
                  (= canonical.span.start-col span.start-col)
                  (= canonical.span.end-line span.end-line)
                  (= canonical.span.end-col span.end-col))
                  (ast-expr-span-slot-set-in-bases!
                    pool.span-slot-segment-bases
                    id
                    slot)
                  (begin
                    (if (>=
                      pool.respan-count
                      (array-length pool.respan-records))
                      (ast-expr-node-pool-state-respan-records-grow-in-place!
                        pool)
                      unit)
                    (let
                      [index : i64 pool.respan-count]
                      (begin
                        (set!
                          (array-ref pool.respan-records index)
                          (AstExprReSpan
                            (cast id : i32)
                            (cast semantic : i32)
                            span))
                        (set! pool.respan-count (+ index 1))
                        (ast-expr-span-slot-set-in-bases!
                          pool.span-slot-segment-bases
                          id
                          (- 0 (+ index 1))))))))))))]
    [(AstExpr.MacroExpansion inner _ _)
      (let
        [inner-slot : i64
          (if (or (< inner 0) (>= inner pool.count))
            0
            (ast-expr-span-slot-get-from-bases
              pool.span-slot-segment-bases
              inner))]
        [semantic : i64
          (ast-expr-semantic-node-from-span-slot
            inner-slot
            (unsafe
              (ptr-read
                (ptr-cast
                  (__tl_array-data (array (& pool.canonical-span-records)))
                  : (Ptr (__tl_dyn-array AstExprCanonicalSpanRecord)))))
            pool.canonical-span-count
            (unsafe
              (ptr-read
                (ptr-cast
                  (__tl_array-data (array (& pool.respan-records)))
                  : (Ptr (__tl_dyn-array AstExprReSpan)))))
            pool.respan-count)]
        (ast-expr-span-slot-set-in-bases!
          pool.span-slot-segment-bases
          id
          (if (< semantic 0)
            0
            inner-slot)))]
    [_ unit]))

(define (ast-expr-node-pool-state-push-in-place!
  [pool : (&mut pool AstExprNodePoolState)]
  [node : AstExpr]) : i64
  (begin
    (if (>=
      (ast-expr-node-pool-state-len pool)
      (ast-expr-node-pool-state-capacity pool))
      (ast-expr-node-pool-state-grow-in-place! pool)
      unit)
    (let
      [segment-bases : i64 pool.segment-bases]
      [id : i64 pool.count]
      [biased-base : i64
        (unsafe
          (ptr-read
            (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 16))))]
      [dest : (MutPtr i64)
        (unsafe
          (int->ptr (+ biased-base (* id (ast-expr-node-bytes))) : (MutPtr i64)))]
      [source : (Ptr i64)
        (unsafe
          (int->ptr (ast-place-address node) : (Ptr i64)))]
      [storage-tag : i64
        (unsafe
          (ptr-read source))]
      (begin
        (unsafe
          (begin
            (ptr-write! dest (ptr-read source))
            (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
            (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))
            (ptr-write! (ptr-offset dest 3) (ptr-read (ptr-offset source 3)))))
        (set! pool.count (+ id 1))
        (ast-expr-span-slot-set-in-bases! pool.span-slot-segment-bases id 0)
        (if (or
          (= storage-tag ast-expr-spanned-storage-tag)
          (= storage-tag ast-expr-macro-expansion-storage-tag))
          (ast-expr-node-pool-state-note-span-in-place! pool id node)
          unit)
        id))))

(define (ast-expr-node-pool-state-push
  [pool : AstExprNodePoolState]
  [node : AstExpr]) : AstExprNodePoolPushResult
  (let
    [next : AstExprNodePoolState pool]
    [id : i64 (ast-expr-node-pool-state-push-in-place! (&mut next) node)]
    (AstExprNodePoolPushOk next id)))

(define (ast-expr-node-pool-state-get
  [pool : (& pool AstExprNodePoolState)]
  [id : i64]) : AstExpr
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset (int->ptr pool.segment-bases : (Ptr i64)) (shr id 16))))]
    (unsafe
      (ptr-read
        (int->ptr (+ biased-base (* id (ast-expr-node-bytes))) : (Ptr AstExpr))))))

(define (ast-expr-span-from-slot
  [slot : i64]
  [canonical-records
    : (& canonical-records (__tl_dyn-array AstExprCanonicalSpanRecord))]
  [canonical-count : i64]
  [respans : (& respans (__tl_dyn-array AstExprReSpan))]
  [respan-count : i64]) : AstMaybeSourceSpan
  (if (> slot 0)
    (let
      [index : i64 (- slot 1)]
      (if (or (< index 0) (>= index canonical-count))
        (AstMaybeSourceSpan.No)
        (AstMaybeSourceSpan.Some
          (__tl-project-field (array-ref canonical-records index) span))))
    (if (< slot 0)
      (let
        [index : i64 (- (- 0 slot) 1)]
        (if (or (< index 0) (>= index respan-count))
          (AstMaybeSourceSpan.No)
          (AstMaybeSourceSpan.Some
            (__tl-project-field (array-ref respans index) span))))
      (AstMaybeSourceSpan.No))))

(define (ast-expr-canonical-span-from-store
  [expr-segment-bases : i64]
  [span-slot-segment-bases : i64]
  [count : i64]
  [canonical-records
    : (& canonical-records (__tl_dyn-array AstExprCanonicalSpanRecord))]
  [canonical-count : i64]
  [id : i64]) : AstMaybeSourceSpan
  (let
    [semantic : i64
      (ast-expr-semantic-node-from-bases expr-segment-bases count id)]
    (if (< semantic 0)
      (AstMaybeSourceSpan.No)
      (let
        [slot : i64
          (ast-expr-span-slot-get-from-bases span-slot-segment-bases semantic)]
        (if (or (<= slot 0) (> slot canonical-count))
          (AstMaybeSourceSpan.No)
          (AstMaybeSourceSpan.Some
            (__tl-project-field (array-ref canonical-records (- slot 1)) span)))))))

(define (ast-expr-node-pool-state-canonical-span
  [pool : (& pool AstExprNodePoolState)]
  [id : i64]) : AstMaybeSourceSpan
  (ast-expr-canonical-span-from-store
    pool.segment-bases
    pool.span-slot-segment-bases
    pool.count
    pool.canonical-span-records
    pool.canonical-span-count
    id))

(define (ast-expr-node-pool-state-view-span
  [pool : (& pool AstExprNodePoolState)]
  [id : i64]) : AstMaybeSourceSpan
  (if (or (< id 0) (>= id pool.count))
    (AstMaybeSourceSpan.No)
    (let
      [slot : i64
        (ast-expr-span-slot-get-from-bases pool.span-slot-segment-bases id)]
      (if (= slot 0)
        (ast-expr-node-pool-state-canonical-span pool id)
        (ast-expr-span-from-slot
          slot
          pool.canonical-span-records
          pool.canonical-span-count
          pool.respan-records
          pool.respan-count)))))

(define (ast-expr-node-pool-state-canonical-span-count
  [pool : AstExprNodePoolState]) : i64
  pool.canonical-span-count)

(define (ast-expr-node-pool-state-respan-count [pool : AstExprNodePoolState]) : i64
  pool.respan-count)

(define (ast-expr-node-pool-state-span-oracle
  [pool : AstExprNodePoolState]
  [id : i64]) : AstExprSpanOracleResult
  (if (or (< id 0) (>= id pool.count))
    (AstExprSpanOracleResult.NotSpanned)
    (match (ast-expr-node-pool-state-get pool id)
      [(AstExpr.Spanned _ legacy-span)
        (match (ast-expr-node-pool-state-view-span pool id)
          [(AstMaybeSourceSpan.No) (AstExprSpanOracleResult.MissingSidecar)]
          [(AstMaybeSourceSpan.Some view-span)
            (if (not (ast-source-span-eq? legacy-span view-span))
              (AstExprSpanOracleResult.UnexpectedDifference)
              (match (ast-expr-node-pool-state-canonical-span pool id)
                [(AstMaybeSourceSpan.No)
                  (AstExprSpanOracleResult.MissingSidecar)]
                [(AstMaybeSourceSpan.Some canonical-span)
                  (if (ast-source-span-eq? canonical-span view-span)
                    (AstExprSpanOracleResult.CanonicalMatch)
                    (AstExprSpanOracleResult.ReSpanMatch))]))])]
      [_ (AstExprSpanOracleResult.NotSpanned)])))

(define (ast-expr-node-pool-state-span-oracle-ok? [pool : AstExprNodePoolState]) : bool
  (let
    [id : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< id pool.count))
        (begin
          (match (ast-expr-node-pool-state-span-oracle
            (ast-global-shared-view pool)
            id)
            [(AstExprSpanOracleResult.MissingSidecar) (set! ok false)]
            [(AstExprSpanOracleResult.UnexpectedDifference) (set! ok false)]
            [_ unit])
          (set! id (+ id 1))))
      ok)))

(define (ast-expr-canonical-span [id : i64]) : AstMaybeSourceSpan
  (ast-expr-canonical-span-from-store
    ast-node-pool-segment-bases
    ast-node-span-slot-segment-bases
    ast-node-pool-count
    ast-node-canonical-span-records
    ast-node-canonical-span-count
    id))

(define (ast-expr-view-span [id : i64]) : AstMaybeSourceSpan
  (if (or (< id 0) (>= id ast-node-pool-count))
    (AstMaybeSourceSpan.No)
    (let
      [slot : i64
        (ast-expr-span-slot-get-from-bases ast-node-span-slot-segment-bases id)]
      (if (= slot 0)
        (ast-expr-canonical-span id)
        (ast-expr-span-from-slot
          slot
          ast-node-canonical-span-records
          ast-node-canonical-span-count
          ast-node-respan-records
          ast-node-respan-count)))))

(define (ast-expr-node-pool-state-set!
  [pool : AstExprNodePoolState]
  [id : i64]
  [node : AstExpr]) : AstExprNodePoolState
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset (int->ptr pool.segment-bases : (Ptr i64)) (shr id 16))))]
    [dest : (MutPtr i64)
      (unsafe
        (int->ptr (+ biased-base (* id (ast-expr-node-bytes))) : (MutPtr i64)))]
    [source : (Ptr i64)
      (unsafe
        (int->ptr (ast-place-address node) : (Ptr i64)))]
    [prior-slot : i64
      (ast-expr-span-slot-get-from-bases pool.span-slot-segment-bases id)]
    (begin
      (unsafe
        (begin
          (ptr-write! dest (ptr-read source))
          (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
          (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))
          (ptr-write! (ptr-offset dest 3) (ptr-read (ptr-offset source 3)))))
      (match (ast-global-shared-view node)
        [(AstExpr.Spanned _ _)
          (let
            [canonical-before : i64 pool.canonical-span-count]
            [respan-before : i64 pool.respan-count]
            (begin
              (ast-expr-span-slot-set-in-bases!
                pool.span-slot-segment-bases
                id
                0)
              (let
                [next : AstExprNodePoolState
                  (ast-expr-node-pool-state-note-span pool id node)]
                (if (or
                  (> next.canonical-span-count canonical-before)
                  (> next.respan-count respan-before))
                  (ast-expr-node-pool-state-with-span-record-order next false)
                  next))))]
        [(AstExpr.MacroExpansion _ _ _)
          (begin
            (ast-expr-span-slot-set-in-bases! pool.span-slot-segment-bases id 0)
            (ast-expr-node-pool-state-note-span pool id node))]
        [_
          (if (< prior-slot 0)
            (let
              [index : i64 (- (- 0 prior-slot) 1)]
              (if (or (< index 0) (>= index pool.respan-count))
                (begin
                  (ast-expr-span-slot-set-in-bases!
                    pool.span-slot-segment-bases
                    id
                    0)
                  pool)
                (let
                  [span : AstSourceSpan
                    (__tl-project-field
                      (array-ref pool.respan-records index)
                      span)]
                  (ast-expr-node-pool-state-record-direct-span
                    (ast-expr-node-pool-state-with-span-record-order pool false)
                    id
                    span))))
            pool)]))))

(define (ast-node-pool-state-capture) : AstExprNodePoolState
  (AstExprNodePoolState
    ast-node-pool-segment-bases
    ast-node-pool-count
    node-pool-base-arena
    ast-node-pool-storage-arena
    ast-node-pool-segment-count
    ast-node-span-slot-segment-bases
    (ast-global-shared-view ast-node-canonical-span-records)
    ast-node-canonical-span-count
    (ast-global-shared-view ast-node-respan-records)
    ast-node-respan-count
    ast-node-span-records-monotonic?))

;; --- AstType node pool (segmented flat ty ids) ---
;; AstType's recursive children are stored as i64 ids into this pool instead of
;; (Box AstType), mirroring the AstExpr pool above. The pool is PERSISTENT for a
;; compile (types live for the whole compile, never per-form like the spanned
;; pool); ty-node-pool-reset! clears it between compiles (REPL/LSP). The
;; process-global compatibility fallback is deliberately modest: normal compile
;; and lint entry points install state-owned pools before parsing. With
;; hash-consed pushes (below), a 1K-node first segment covers direct smoke
;; callers while additional segments grow on demand.
(define (ast-type-node-pool-biased-segment-base
  [segment : (__tl_dyn-array AstType)]
  [segment-index : i64]) : i64
  (-
    (cast
      (unsafe
        (ptr->int (ptr-cast (__tl_array-data segment) : (Ptr u8))))
      : i64)
    (* segment-index ast-type-node-pool-segment-bytes)))

(define ty-node-pool-first-segment : (__tl_dyn-array AstType)
  (__tl_make-array AstType ast-type-node-pool-segment-size))
(define ty-node-pool-segment-bases : i64
  (let
    [bases : (__tl_dyn-array i64) (ast-node-pool-segment-base-table-new)]
    (begin
      (set!
        (array-ref bases 0)
        (ast-type-node-pool-biased-segment-base
          (ast-global-shared-view ty-node-pool-first-segment)
          0))
      (cast
        (unsafe
          (ptr->int (ptr-cast (__tl_array-data bases) : (Ptr u8))))
        : i64))))
(define ty-node-pool-segment-count : i64
  1)
(define ty-node-pool-count : i64
  0)
(define ty-node-pool-exhausted : bool
  false)

;: Current type-node count (also the next ty id ty-node-push will assign).
(define (ty-node-pool-len) : i64
  ty-node-pool-count)

(define (ty-node-pool-exhausted?) : bool
  ty-node-pool-exhausted)

(define (ty-node-pool-exhausted-message) : String
  "compiler: AstType node pool exhausted")

;: Add one fixed-size backing segment without relocating earlier nodes.
;;
;; Type IDs use the same stable segment/offset mapping as expression IDs. The
;; smaller segment size reflects the much smaller hash-consed type population.
(define (ty-node-pool-grow!) : unit
  (let
    [segment-index : i64 ty-node-pool-segment-count]
    [old-storage-arena : i64 ty-node-pool-storage-arena]
    [storage-root : i64
      (if (= old-storage-arena 0)
        (arena.tl_arena_make)
        old-storage-arena)]
    [new-segment : (__tl_dyn-array AstType)
      (in-arena
        (arena.Arena storage-root)
        (__tl_make-array AstType ast-type-node-pool-segment-size))]
    (begin
      (unsafe
        (ptr-write!
          (ptr-offset
            (int->ptr ty-node-pool-segment-bases : (MutPtr i64))
            segment-index)
          (ast-type-node-pool-biased-segment-base new-segment segment-index)))
      (set! ty-node-pool-storage-arena storage-root)
      (set! ty-node-pool-segment-count (+ segment-index 1)))))

(define (ty-node-persist-lifetimes-into
  [items : (& items AstLifetimeList)]
  [out : (&mut out AstLifetimeList)]
  [index : i64]) : unit
  (if (>= index (ast-lifetime-list-len items))
    unit
    (begin
      (ast-lifetime-list-push
        out
        (ast-lifetime-list-get items index (ast-lifetime-fallback)))
      (ty-node-persist-lifetimes-into items out (+ index 1)))))

(define (ty-node-persist-lifetimes [items : AstLifetimeList]) : AstLifetimeList
  (let
    [out : AstLifetimeList
      (ast-lifetime-list-with-capacity (ast-lifetime-list-len (& items)))]
    (begin
      (ty-node-persist-lifetimes-into (& items) (&mut out) 0)
      out)))

(define (ty-node-persist-type-list-into
  [items : (& items AstTypeList)]
  [out : (&mut out AstTypeList)]
  [index : i64]) : unit
  (if (>= index (ast-type-list-len items))
    unit
    (begin
      (ast-type-list-push
        out
        (ast-type-list-get items index (ast-type-id-fallback)))
      (ty-node-persist-type-list-into items out (+ index 1)))))

(define (ty-node-persist-type-list [items : AstTypeList]) : AstTypeList
  (let
    [out : AstTypeList
      (ast-type-list-with-capacity (ast-type-list-len (& items)))]
    (begin
      (ty-node-persist-type-list-into (& items) (&mut out) 0)
      out)))

(define (ty-node-persist [node : AstType]) : AstType
  (let
    [fallback : AstType (ast-global-shared-view node)]
    (match node
      [(AstType.Func args ret)
        (AstType.Func (box (ty-node-persist-type-list (deref args))) ret)]
      [(AstType.Tuple args)
        (AstType.Tuple (box (ty-node-persist-type-list (deref args))))]
      [(AstType.Region name inner) (AstType.Region name inner)]
      [(AstType.Ref name inner) (AstType.Ref name inner)]
      [(AstType.MutRef name inner) (AstType.MutRef name inner)]
      [(AstType.Invalidate name inner) (AstType.Invalidate name inner)]
      [(AstType.EnumArgs name lifetimes)
        (AstType.EnumArgs
          name
          (box (ty-node-persist-lifetimes (deref lifetimes))))]
      [(AstType.StructArgs name lifetimes)
        (AstType.StructArgs
          name
          (box (ty-node-persist-lifetimes (deref lifetimes))))]
      [(AstType.VarArgs name lifetimes)
        (AstType.VarArgs
          name
          (box (ty-node-persist-lifetimes (deref lifetimes))))]
      [(AstType.Slice elem) (AstType.Slice elem)]
      [_ fallback])))

;; State-owned type node pools mirror the global type-node backing store while
;; keeping each worker's ids, reset marks, and hash-consing table independent.
;; The compiler hot path still uses the process-global compatibility wrappers
;; until parser/typechecker/driver state is threaded through every call.
(defstruct AstTypeNodePoolState
  (segment-bases i64)
  (count i64)
  (base-arena i64)
  (exhausted bool)
  (dedup-slots (__tl_dyn-array i64))
  (dedup-count i64)
  (storage-arena i64)
  (segment-count i64))

(define (ast-type-node-pool-state-with-base-arena
  [pool : AstTypeNodePoolState]
  [base-arena : i64]) : AstTypeNodePoolState
  (AstTypeNodePoolState
    pool.segment-bases
    pool.count
    base-arena
    pool.exhausted
    pool.dedup-slots
    pool.dedup-count
    pool.storage-arena
    pool.segment-count))

(defenum AstTypeNodePoolPushResult
  (AstTypeNodePoolPushOk AstTypeNodePoolState i64))

(define (ast-type-node-pool-state-dedup-capacity [capacity : i64]) : i64
  (let
    [want
      : i64
      ;; Large ordinary transformer bodies (the scalar `for` source port, for
      ;; one) need a large uniqueness budget in a self-host check; retain
      ;; headroom instead of falling back to millions of duplicate raw type
      ;; nodes.
      (if (< capacity 131072)
        131072
        capacity)]
    [cap : i64 1]
    (begin
      (while (< cap want)
        (set! cap (* cap 2)))
      cap)))

(define (ast-type-node-pool-state-init [capacity : i64] [base-arena : i64]) : AstTypeNodePoolState
  (let
    [cap : i64 (node-pool-state-normalize-capacity capacity)]
    [segment-count : i64
      (node-pool-segment-count-for-capacity cap ast-type-node-pool-segment-size)]
    [dedup-cap : i64 (ast-type-node-pool-state-dedup-capacity cap)]
    [segment-bases : (__tl_dyn-array i64)
      (in-arena (arena.Arena base-arena) (ast-node-pool-segment-base-table-new))]
    [dedup-slots : (__tl_dyn-array i64)
      (in-arena (arena.Arena base-arena) (__tl_make-array i64 dedup-cap))]
    [storage-root : i64 (ast-node-pool-arena-make)]
    [segment-index : i64 0]
    (begin
      (while (< segment-index segment-count)
        (let
          [segment : (__tl_dyn-array AstType)
            (in-arena
              (arena.Arena storage-root)
              (__tl_make-array AstType ast-type-node-pool-segment-size))]
          (begin
            (set!
              (array-ref segment-bases segment-index)
              (ast-type-node-pool-biased-segment-base segment segment-index))
            (set! segment-index (+ segment-index 1)))))
      (AstTypeNodePoolState
        (cast
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data segment-bases) : (Ptr u8))))
          : i64)
        0
        base-arena
        false
        dedup-slots
        0
        storage-root
        segment-count))))

(define (ast-type-node-pool-state-create [capacity : i64]) : AstTypeNodePoolState
  (ast-type-node-pool-state-init capacity (arena.tl_arena_current)))

(define (ast-type-node-pool-state-len [pool : (& pool AstTypeNodePoolState)]) : i64
  pool.count)

(define (ast-type-node-pool-state-capacity
  [pool : (& pool AstTypeNodePoolState)]) : i64
  (* pool.segment-count ast-type-node-pool-segment-size))

(define (ast-type-node-pool-state-dedup-clear [pool : AstTypeNodePoolState]) : AstTypeNodePoolState
  (let
    [slots : (__tl_dyn-array i64) pool.dedup-slots]
    [cap : i64 (array-length slots)]
    [i : i64 0]
    (begin
      (while (< i cap)
        (begin
          (set! (array-ref slots i) 0)
          (set! i (+ i 1))))
      (AstTypeNodePoolState
        pool.segment-bases
        pool.count
        pool.base-arena
        pool.exhausted
        slots
        0
        pool.storage-arena
        pool.segment-count))))

(define (ast-type-node-pool-state-reset-to
  [pool : AstTypeNodePoolState]
  [mark : i64]) : AstTypeNodePoolState
  ;; Reset truncates the node prefix. Clear, rather than rebuild, the dedup
  ;; table so no entry can point at an id >= mark; later pushes repopulate it.
  (ast-type-node-pool-state-dedup-clear
    (AstTypeNodePoolState
      pool.segment-bases
      mark
      pool.base-arena
      false
      pool.dedup-slots
      pool.dedup-count
      pool.storage-arena
      pool.segment-count)))

(define (ast-type-node-pool-state-grow [pool : AstTypeNodePoolState]) : AstTypeNodePoolState
  (let
    [segment-bases : i64 pool.segment-bases]
    [segment-index : i64 pool.segment-count]
    [base-arena : i64 pool.base-arena]
    [storage-arena : i64 pool.storage-arena]
    [new-segment : (__tl_dyn-array AstType)
      (in-arena
        (arena.Arena storage-arena)
        (__tl_make-array AstType ast-type-node-pool-segment-size))]
    [len : i64 pool.count]
    (begin
      (unsafe
        (ptr-write!
          (ptr-offset (int->ptr segment-bases : (MutPtr i64)) segment-index)
          (ast-type-node-pool-biased-segment-base new-segment segment-index)))
      (AstTypeNodePoolState
        segment-bases
        len
        base-arena
        pool.exhausted
        pool.dedup-slots
        pool.dedup-count
        storage-arena
        (+ segment-index 1)))))

(define (ast-type-node-pool-state-push-raw
  [pool : AstTypeNodePoolState]
  [node : AstType]) : AstTypeNodePoolPushResult
  (let
    [ready : AstTypeNodePoolState
      (if (>=
        (ast-type-node-pool-state-len pool)
        (ast-type-node-pool-state-capacity pool))
        (ast-type-node-pool-state-grow pool)
        pool)]
    [segment-bases : i64 ready.segment-bases]
    [id : i64 ready.count]
    [biased-base : i64
      (unsafe
        (ptr-read (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 10))))]
    [base-arena : i64 ready.base-arena]
    [persistent : AstType
      (in-arena (arena.Arena base-arena) (ty-node-persist node))]
    [dest : (MutPtr i64)
      (unsafe
        (int->ptr (+ biased-base (* id (ast-type-node-bytes))) : (MutPtr i64)))]
    [source : (Ptr i64)
      (unsafe
        (ptr-cast (ptr-addr-of persistent) : (Ptr i64)))]
    (begin
      (unsafe
        (begin
          (ptr-write! dest (ptr-read source))
          (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
          (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))))
      (AstTypeNodePoolPushOk
        (AstTypeNodePoolState
          segment-bases
          (+ id 1)
          base-arena
          ready.exhausted
          ready.dedup-slots
          ready.dedup-count
          ready.storage-arena
          ready.segment-count)
        id))))

(define (ast-type-node-pool-state-push-dedup
  [pool : AstTypeNodePoolState]
  [node : AstType]
  [dedup-slots : (__tl_dyn-array i64)]
  [dedup-count : i64]
  [idx : i64]
  [mask : i64]) : AstTypeNodePoolPushResult
  (let
    [slot : i64 (array-ref dedup-slots idx)]
    (if (= slot 0)
      (match (ast-type-node-pool-state-push-raw pool node)
        [(AstTypeNodePoolPushOk next id)
          (begin
            (set! (array-ref dedup-slots idx) (+ id 1))
            (AstTypeNodePoolPushOk
              (AstTypeNodePoolState
                next.segment-bases
                next.count
                next.base-arena
                next.exhausted
                dedup-slots
                (+ dedup-count 1)
                next.storage-arena
                next.segment-count)
              id))])
      (if (ty-node-shallow-value-eq?
        (ast-type-node-pool-state-get pool (- slot 1))
        (ast-global-shared-view node))
        (AstTypeNodePoolPushOk pool (- slot 1))
        (ast-type-node-pool-state-push-dedup
          pool
          node
          dedup-slots
          dedup-count
          (bit-and (+ idx 1) mask)
          mask)))))

(define (ast-type-node-pool-state-push
  [pool : AstTypeNodePoolState]
  [node : AstType]) : AstTypeNodePoolPushResult
  (let
    [dedup-slots : (__tl_dyn-array i64)
      (ast-place-shared-view pool.dedup-slots)]
    [dedup-cap : i64 (array-length dedup-slots)]
    [dedup-count : i64 pool.dedup-count]
    (if (>= (* dedup-count 2) dedup-cap)
      (ast-type-node-pool-state-push-raw pool node)
      (let
        [mask : i64 (- dedup-cap 1)]
        [idx : i64
          (ty-node-dedup-slot-index
            (ty-node-hash-value (ast-global-shared-view node))
            mask)]
        (ast-type-node-pool-state-push-dedup
          pool
          node
          dedup-slots
          dedup-count
          idx
          mask)))))

(define (ast-type-node-pool-state-get
  [pool : (& pool AstTypeNodePoolState)]
  [id : i64]) : AstType
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset (int->ptr pool.segment-bases : (Ptr i64)) (shr id 10))))]
    (unsafe
      (ptr-read
        (int->ptr (+ biased-base (* id (ast-type-node-bytes))) : (Ptr AstType))))))

;: Append `node` to the pool unconditionally and return its ty id.
(define (ty-node-push-raw [node : AstType]) : i64
  (begin
    (if (>=
      ty-node-pool-count
      (* ty-node-pool-segment-count ast-type-node-pool-segment-size))
      (ty-node-pool-grow!)
      unit)
    (let
      [id : i64 ty-node-pool-count]
      [biased-base : i64
        (unsafe
          (ptr-read
            (ptr-offset
              (int->ptr ty-node-pool-segment-bases : (Ptr i64))
              (shr id 10))))]
      [base-arena : i64 node-pool-base-arena]
      [persistent : AstType
        (in-arena (arena.Arena base-arena) (ty-node-persist node))]
      [dest : (MutPtr i64)
        (unsafe
          (int->ptr (+ biased-base (* id (ast-type-node-bytes))) : (MutPtr i64)))]
      [source : (Ptr i64)
        (unsafe
          (ptr-cast (ptr-addr-of persistent) : (Ptr i64)))]
      (begin
        (unsafe
          (begin
            (ptr-write! dest (ptr-read source))
            (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
            (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))))
        (set! ty-node-pool-count (+ id 1))
        (ast-node-pool-active-context-capture-type!)
        id))))

;; --- ty-node hash-consing ----------------------------------------------------
;; Type nodes are immutable and constructed
;; bottom-up, so identical subtrees can share one id: children are already
;; deduplicated when their parent is pushed, which makes shallow field
;; equality (child ids included) exact structural equality. Without it a
;; compile pushes millions of nodes for a few thousand distinct types;
;; hash-consing collapses the pool by orders of magnitude, shrinking both the
;; node-slot footprint and the pre-sized pool itself. The dedup table is a
;; growable open-addressing map from node hash to id (+1; 0 = empty), cleared
;; on pool truncate/reset. Passing half load doubles the table and rehashes
;; (`ty-node-dedup-grow!`) instead of degrading: a table that stopped indexing
;; left equal types with distinct ids, which both balloons the pool and busts
;; every id-keyed downstream cache.
;;
;; Equality is explicit field-wise matching, NOT a byte compare of the slots:
;; enum slot tails beyond a variant's payload are uninitialized, so a byte
;; compare would dedup nondeterministically and break the stage2 == stage3
;; fixpoint. String payloads (lifetime names) compare by content.
(define ty-node-dedup-capacity : i64
  131072)
(define ty-node-dedup-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 131072))
(define ty-node-dedup-slots-data-address : u64
  (unsafe
    (ptr->int (__tl_array-data ty-node-dedup-slots))))
(define ty-node-dedup-count : i64
  0)

;; Upper bound on the doubling above: 2^24 slots indexes 8.4M distinct type
;; nodes for 128 MiB of table. No self-host workload comes within an order of
;; magnitude of it; it exists so a pathological input degrades to
;; plain-append behaviour rather than to an unbounded table.
(define ty-node-dedup-max-capacity : i64
  16777216)

;; Clearing empties the index but KEEPS whatever capacity the table has grown
;; to: the workload that forced the growth is about to be re-indexed, so
;; shrinking would only re-pay the rehash. Read the extent off the array rather
;; than the capacity global so a grown table can never be half-cleared.
(define (ty-node-dedup-clear!) : unit
  (let
    [capacity : i64 (array-length ty-node-dedup-slots)]
    [i : i64 0]
    (begin
      (while (< i capacity)
        (begin
          (set! (array-ref ty-node-dedup-slots i) 0)
          (set! i (+ i 1))))
      (set! ty-node-dedup-count 0))))

(define (ty-lifetime-list-hash-at
  [items : (& items AstLifetimeList)]
  [len : i64]
  [seed : i64]
  [index : i64]) : i64
  (if (>= index len)
    (hash.combine seed 11)
    (let
      [name : i64 (array-ref items.slots index)]
      (ty-lifetime-list-hash-at items len (hash.combine seed name) (+ index 1)))))

(define (ty-lifetime-list-hash [items : (& items AstLifetimeList)] [seed : i64]) : i64
  (ty-lifetime-list-hash-at items (ast-lifetime-list-len items) seed 0))

(define (ty-type-list-hash-at
  [items : (& items AstTypeList)]
  [len : i64]
  [seed : i64]
  [index : i64]) : i64
  (if (>= index len)
    (hash.combine seed 13)
    (ty-type-list-hash-at
      items
      len
      (hash.combine seed (array-ref items.slots index))
      (+ index 1))))

(define (ty-type-list-hash [items : (& items AstTypeList)] [seed : i64]) : i64
  (ty-type-list-hash-at items (ast-type-list-len items) seed 0))

;; Map a node hash onto a dedup slot. `ty-node-hash-value` is deliberately left
;; alone (its values are also the file's documented, test-pinned hash contract);
;; what it is NOT is a table index. Whole families of nodes hash to
;; `constant + id` -- `(AstType.Var name)` is `4062 + name`, `(AstType.Box
;; inner)` is `3014 + inner`, and so on for Struct/Enum/DynArray/Ptr/MutPtr/
;; Consume -- so masking the raw hash piles every one of them into the same few
;; thousand low slots while the rest of the table stays empty, and probe chains
;; grow long at that high local load.
;;
;; A Fibonacci/Knuth multiply spreads them: consecutive ids step through the
;; table by a fixed odd stride instead of landing next to each other, and two
;; families whose hashes differ by a constant get pseudo-random relative
;; offsets. `ty-node-hash-value` is normalized below 2^31 and the multiplier is
;; below 2^32, so the product stays under 2^63 and never overflows i64.
;;
;; This cannot change which id a node gets. Slot choice only affects the ORDER
;; slots are visited; dedup equality is exact structural equality and probing
;; stops only at an empty slot, so a node still resolves to the id of its first
;; structurally-equal predecessor, or is appended. Ids -- and therefore the
;; generated assembly -- are identical either way.
(define (ty-node-dedup-slot-index [hash : i64] [mask : i64]) : i64
  (bit-and (* hash 2654435761) mask))

(define (ty-node-hash-value [node : AstType]) : i64
  (match node
    [(AstType.I64) 1]
    [(AstType.I32) 2]
    [(AstType.I16) 3]
    [(AstType.I8) 4]
    [(AstType.U64) 5]
    [(AstType.U32) 6]
    [(AstType.U16) 7]
    [(AstType.U8) 8]
    [(AstType.F64) 9]
    [(AstType.F32) 10]
    [(AstType.Bool) 11]
    [(AstType.Char) 12]
    [(AstType.String) 13]
    [(AstType.Str) 14]
    [(AstType.Bytes) 35]
    [(AstType.Unit) 15]
    [(AstType.Never) 16]
    [(AstType.Expr) 17]
    [(AstType.ExprList) 18]
    [(AstType.Func args ret)
      (hash.combine (ty-type-list-hash (& (deref args)) 19) ret)]
    [(AstType.Tuple elems) (ty-type-list-hash (& (deref elems)) 20)]
    [(AstType.Array elem count) (hash.combine (hash.combine 21 elem) count)]
    [(AstType.DynArray elem) (hash.combine 22 elem)]
    [(AstType.Box inner) (hash.combine 23 inner)]
    [(AstType.Region name inner) (hash.combine (hash.combine 24 name) inner)]
    [(AstType.Ref name inner) (hash.combine (hash.combine 25 name) inner)]
    [(AstType.MutRef name inner) (hash.combine (hash.combine 26 name) inner)]
    [(AstType.Enum name) (hash.combine 27 name)]
    [(AstType.EnumArgs name lifetimes)
      (ty-lifetime-list-hash (& (deref lifetimes)) (hash.combine 28 name))]
    [(AstType.Struct name) (hash.combine 29 name)]
    [(AstType.StructArgs name lifetimes)
      (ty-lifetime-list-hash (& (deref lifetimes)) (hash.combine 30 name))]
    [(AstType.Var name) (hash.combine 31 name)]
    [(AstType.VarArgs name lifetimes)
      (ty-lifetime-list-hash (& (deref lifetimes)) (hash.combine 32 name))]
    [(AstType.CFunc signature mode)
      (hash.combine (hash.combine 38 signature) (ast-c-function-mode-key mode))]
    [(AstType.Ptr inner) (hash.combine 33 inner)]
    [(AstType.MutPtr inner) (hash.combine 34 inner)]
    [(AstType.Slice elem) (hash.combine 37 elem)]
    [(AstType.Invalidate name inner)
      (hash.combine (hash.combine 39 name) inner)]))

;; Shallow structural equality between a stored node and a candidate node. Child
;; ids compare as plain integers because children are themselves deduplicated.
(define (ty-node-shallow-value-eq? [a : AstType] [b : AstType]) : bool
  (ast-type-children-eq? a b ast-type-id-same?))

(define (ty-node-shallow-eq? [a-id : i64] [b : AstType]) : bool
  (ty-node-shallow-value-eq? (ty-node-get a-id) b))

;; Double the dedup table and reinsert every live entry, keeping the index
;; effective for the whole compile instead of switching itself off at half load.
;;
;; ARENA OWNERSHIP: the slots array is POOL STATE -- `ty-node-pool-state-capture`
;; hands it to every `AstTypeNodePoolState` and an install points the globals
;; straight back at it -- so it lives in the arena that owns the pool
;; (`node-pool-base-arena`), exactly like the segment tables and the persisted
;; node payloads (see `ty-node-push-raw`). Allocating it in "whatever arena is
;; current" would put a table that outlives every transient scratch arena inside
;; one of them: a grow that fired during lowering or macro expansion would be
;; freed under the pool. Arena handles are stable roots, so allocating through
;; `in-arena` needs no post-allocation head recapture or republication.
;;
;; The reinsert needs no equality check: every entry already survived an
;; equality probe when it was inserted, so the entries are pairwise distinct and
;; the first free slot on the new probe path is the right one. Growth is decided
;; purely by count against capacity, so it fires at the same push on every run.
(define (ty-node-dedup-grow!) : unit
  (let
    [old-capacity : i64 (array-length ty-node-dedup-slots)]
    [new-capacity : i64 (* old-capacity 2)]
    [base-arena : i64 node-pool-base-arena]
    [new-slots : (__tl_dyn-array i64)
      (in-arena (arena.Arena base-arena) (__tl_make-array i64 new-capacity))]
    [mask : i64 (- new-capacity 1)]
    [i : i64 0]
    (begin
      (while (< i old-capacity)
        (let
          [slot : i64 (array-ref ty-node-dedup-slots i)]
          (begin
            (if (= slot 0)
              unit
              (let
                [idx : i64
                  (ty-node-dedup-slot-index
                    (ty-node-hash-value (ty-node-get (- slot 1)))
                    mask)]
                (begin
                  (while (not (= (array-ref new-slots idx) 0))
                    (set! idx (bit-and (+ idx 1) mask)))
                  (set! (array-ref new-slots idx) slot))))
            (set! i (+ i 1)))))
      (set! ty-node-dedup-slots new-slots)
      ;; The probe keeps only this raw backing address. The replacement table
      ;; lives in the pool's stable base arena and never grows in place; publish
      ;; its new address before any following probe can run.
      (set!
        ty-node-dedup-slots-data-address
        (unsafe
          (ptr->int (__tl_array-data ty-node-dedup-slots))))
      (set! ty-node-dedup-capacity new-capacity)
      ;; The pool state carries the slots array by reference, so the context
      ;; cell has to learn about the replacement here: the push that follows may
      ;; resolve to an existing id and never reach `ty-node-push-raw`'s capture.
      (ast-node-pool-active-context-capture-type!))))

;; Probe the dedup table for `node`, appending it only on a miss. Split out of
;; `ty-node-push-active` so the loaded-table check there stays a single compare
;; on the hot path.
(define (ty-node-dedup-probe-push [node : AstType]) : i64
  (let
    [mask : i64 (- ty-node-dedup-capacity 1)]
    ;; Stable for the whole probe: this function cannot replace the table;
    ;; grow/install boundaries republish it, while reset only clears in place.
    ;; Using the pointer also removes a descriptor reload and a redundant
    ;; bounds check for every collision step; `idx` is masked by capacity - 1.
    [slots : (MutPtr i64)
      (unsafe
        (int->ptr ty-node-dedup-slots-data-address : (MutPtr i64)))]
    [idx : i64
      (ty-node-dedup-slot-index
        (ty-node-hash-value (ast-global-shared-view node))
        mask)]
    [result : i64 (- 0 1)]
    (begin
      (while (< result 0)
        (let
          [slot : i64
            (unsafe
              (ptr-read (ptr-offset slots idx)))]
          (if (= slot 0)
            (let
              [id : i64 (ty-node-push-raw (ast-global-shared-view node))]
              (begin
                (unsafe
                  (ptr-write! (ptr-offset slots idx) (+ id 1)))
                (set! ty-node-dedup-count (+ ty-node-dedup-count 1))
                (set! result id)))
            (if (ty-node-shallow-eq? (- slot 1) (ast-global-shared-view node))
              (set! result (- slot 1))
              (set! idx (bit-and (+ idx 1) mask))))))
      result)))

;; Half load reached: grow and keep deduplicating. Only a table already at the
;; 2^24-slot bound falls back to a plain append.
(define (ty-node-push-loaded [node : AstType]) : i64
  (if (>= ty-node-dedup-capacity ty-node-dedup-max-capacity)
    (ty-node-push-raw node)
    (begin
      (ty-node-dedup-grow!)
      (ty-node-dedup-probe-push node))))

;: Append `node` to the active pool, returning an existing id when an identical node
;: was already pushed. The table is probed before appending so the common
;: duplicate path does not churn the pool count or temporarily force growth.
(define (ty-node-push-active [node : AstType]) : i64
  (if (>= (* ty-node-dedup-count 2) ty-node-dedup-capacity)
    (ty-node-push-loaded node)
    (ty-node-dedup-probe-push node)))

;: Append `node` to the selected type pool.
(define (ty-node-push [node : AstType]) : i64
  (if ast-node-pool-compat-context-explicit?
    (ast-node-pool-context-type-push
      (array-ref ast-node-pool-compat-context-cell 0)
      node)
    (ty-node-push-active node)))

;: Read the type node at `id` from the installed type pool.
;;
;; As with `ast-node-get`, cast the inner backing store through bytes so the
;; unchecked load uses AstType's real inline stride (`ast-type-node-bytes`).
(define (ty-node-get [id : i64]) : AstType
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset
            (int->ptr ty-node-pool-segment-bases : (Ptr i64))
            (shr id 10))))]
    (unsafe
      (ptr-read
        (int->ptr (+ biased-base (* id (ast-type-node-bytes))) : (Ptr AstType))))))

;; Identity of the current type-node id space: bumped whenever ids may change
;; meaning (truncation discards ids; a pool-state install swaps the whole
;; space), so id-keyed side caches can guard on it. Immutable hash-consed
;; nodes make a stable generation sufficient for cache validity.
(define ty-node-pool-generation : i64
  0)

(define (ty-node-pool-generation-value) : i64
  ty-node-pool-generation)

;: Truncate the pool back to `mark` nodes (discard from a failed parse).
;; Dedup entries above `mark` would dangle, so the table is cleared; truncation
;; happens at most a few times per compile (parse rollback, per-compile reset).
(define (ty-node-pool-truncate! [mark : i64]) : unit
  (begin
    (set! ty-node-pool-count mark)
    (set! ty-node-pool-generation (+ ty-node-pool-generation 1))
    (ty-node-dedup-clear!)
    (ast-node-pool-active-context-capture-type!)))

(define (ty-node-pool-reset-to! [mark : i64]) : unit
  (begin
    (ty-node-pool-truncate! mark)
    (set! ty-node-pool-exhausted false)))

(define (ty-node-pool-reset!) : unit
  (begin
    (ty-node-pool-truncate! 0)
    (set! ty-node-pool-exhausted false)))

(define (ty-node-pool-state-capture) : AstTypeNodePoolState
  (AstTypeNodePoolState
    ty-node-pool-segment-bases
    ty-node-pool-count
    node-pool-base-arena
    ty-node-pool-exhausted
    (unsafe
      (ptr-read
        (ptr-cast
          (__tl_array-data (array (& ty-node-dedup-slots)))
          : (Ptr (__tl_dyn-array i64)))))
    ty-node-dedup-count
    ty-node-pool-storage-arena
    ty-node-pool-segment-count))

;; Capturing through an owned aggregate return can materialize the nested
;; `dedup-slots` descriptor in the caller's transient arena. These raw cell
;; writers preserve the already-owned descriptor address and copy only scalar
;; state, so retained contexts never acquire an intermediate aggregate owner.
(define (ast-node-pool-state-capture-to-cell! [cell-address : u64]) : unit
  (let
    [cell : (MutPtr i64)
      (unsafe
        (int->ptr cell-address : (MutPtr i64)))]
    (unsafe
      (begin
        (ptr-write! cell ast-node-pool-segment-bases)
        (ptr-write! (ptr-offset cell 1) ast-node-pool-count)
        (ptr-write! (ptr-offset cell 2) node-pool-base-arena)
        (ptr-write! (ptr-offset cell 3) ast-node-pool-storage-arena)
        (ptr-write! (ptr-offset cell 4) ast-node-pool-segment-count)))))

(define (ty-node-pool-state-capture-to-cell! [cell-address : u64]) : unit
  (let
    [cell : (MutPtr i64)
      (unsafe
        (int->ptr cell-address : (MutPtr i64)))]
    [dedup-descriptor : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of ty-node-dedup-slots) : (Ptr i64))))]
    (unsafe
      (begin
        (ptr-write! cell ty-node-pool-segment-bases)
        (ptr-write! (ptr-offset cell 1) ty-node-pool-count)
        (ptr-write! (ptr-offset cell 2) node-pool-base-arena)
        (ptr-write!
          (ptr-offset cell 3)
          (if ty-node-pool-exhausted
            1
            0))
        (ptr-write! (ptr-offset cell 4) dedup-descriptor)
        (ptr-write! (ptr-offset cell 5) ty-node-dedup-count)
        (ptr-write! (ptr-offset cell 6) ty-node-pool-storage-arena)
        (ptr-write! (ptr-offset cell 7) ty-node-pool-segment-count)))))

(define (ast-node-pools-state-install!
  [expr-pool : (& expr-pool AstExprNodePoolState)]
  [type-pool : (& type-pool AstTypeNodePoolState)]
  [owner-arena : i64]) : unit
  (begin
    (set! ast-node-pool-segment-bases expr-pool.segment-bases)
    (set! ast-node-pool-count expr-pool.count)
    (set! ast-node-pool-storage-arena expr-pool.storage-arena)
    (set! ast-node-pool-segment-count expr-pool.segment-count)
    (set! ast-node-span-slot-segment-bases expr-pool.span-slot-segment-bases)
    (set!
      ast-node-canonical-span-records
      (unsafe
        (ptr-read
          (ptr-cast
            (__tl_array-data (array expr-pool.canonical-span-records))
            : (Ptr (__tl_dyn-array AstExprCanonicalSpanRecord))))))
    (set! ast-node-canonical-span-count expr-pool.canonical-span-count)
    (set!
      ast-node-respan-records
      (unsafe
        (ptr-read
          (ptr-cast
            (__tl_array-data (array expr-pool.respan-records))
            : (Ptr (__tl_dyn-array AstExprReSpan))))))
    (set! ast-node-respan-count expr-pool.respan-count)
    (set! ast-node-span-records-monotonic? expr-pool.span-records-monotonic?)
    (set! ty-node-pool-segment-bases type-pool.segment-bases)
    (set! ty-node-pool-count type-pool.count)
    (set! ty-node-pool-storage-arena type-pool.storage-arena)
    (set! ty-node-pool-segment-count type-pool.segment-count)
    (set! ty-node-pool-generation (+ ty-node-pool-generation 1))
    (set! ty-node-pool-exhausted type-pool.exhausted)
    (set! ty-node-dedup-capacity (array-length type-pool.dedup-slots))
    (set!
      ty-node-dedup-slots
      (unsafe
        (ptr-read
          (ptr-cast
            (__tl_array-data (array type-pool.dedup-slots))
            : (Ptr (__tl_dyn-array i64))))))
    ;; A context install is the only generation boundary that can replace the
    ;; table outside `ty-node-dedup-grow!`; derive the hot pointer from the
    ;; newly installed descriptor while its base arena is still owned here.
    (set!
      ty-node-dedup-slots-data-address
      (unsafe
        (ptr->int (__tl_array-data ty-node-dedup-slots))))
    (set! ty-node-dedup-count type-pool.dedup-count)
    ;; Driver-created states allocate both pools in one persistent arena. Keep
    ;; the shared compatibility grow/persist target there after both installs.
    (set! node-pool-base-arena expr-pool.base-arena)
    (set! node-pool-owner-arena owner-arena)))

;; A pool context names a pair of shared state cells; it does not own them.
;; Each cell is a one-element dynamic array allocated in the pool's owner arena
;; (see `ast-node-pool-context-new-with-pool-owner`), and the context keeps the
;; bits of that array's descriptor, so the context is a Copy handle with the
;; memory layout it had when it held the descriptors themselves.
(defstruct AstNodePoolContext
  (expr-pool u64)
  (type-pool u64)
  (owner-arena i64))

;; Address of the state record in a cell, from the cell's descriptor bits: the
;; descriptor's first word is its data pointer. The cell macros below expand in
;; other modules too, so their templates name no module-local types.
(defmacro (ast-pool-cell-data [descriptor : Expr]) : Expr
  `(unsafe
    (ptr-read (int->ptr ,descriptor : (Ptr u64)))))

(define (ast-expr-pool-cell-ptr [descriptor : u64]) : (MutPtr
    AstExprNodePoolState)
  (unsafe
    (int->ptr (ast-pool-cell-data descriptor) : (MutPtr AstExprNodePoolState))))

(define (ast-type-pool-cell-ptr [descriptor : u64]) : (MutPtr
    AstTypeNodePoolState)
  (unsafe
    (int->ptr (ast-pool-cell-data descriptor) : (MutPtr AstTypeNodePoolState))))

(defmacro (ast-expr-pool-cell-read [descriptor : Expr]) : Expr
  `(unsafe
    (ptr-read (ast-expr-pool-cell-ptr ,descriptor))))

(defmacro (ast-type-pool-cell-read [descriptor : Expr]) : Expr
  `(unsafe
    (ptr-read (ast-type-pool-cell-ptr ,descriptor))))

(defmacro (ast-expr-pool-cell-write! [descriptor : Expr] [state : Expr]) : Expr
  `(unsafe
    (ptr-write! (ast-expr-pool-cell-ptr ,descriptor) ,state)))

(defmacro (ast-type-pool-cell-write! [descriptor : Expr] [state : Expr]) : Expr
  `(unsafe
    (ptr-write! (ast-type-pool-cell-ptr ,descriptor) ,state)))

;; The cell itself, for in-place updates through `(&mut (array-ref cell 0))`.
(defmacro (ast-expr-pool-cell [descriptor : Expr]) : Expr
  `(let
    [cell-bits : u64 ,descriptor]
    (unsafe
      (ptr-read
        (ptr-cast
          (ptr-addr-of cell-bits)
          : (Ptr (__tl_dyn-array AstExprNodePoolState)))))))

;; Descriptor bits of a cell held in a local or parameter.
(defmacro (ast-pool-cell-descriptor [cell : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-cast (ptr-addr-of ,cell) : (Ptr u64)))))

(define (ast-node-pools-cells-install!
  [expr-cell : u64]
  [type-cell : u64]
  [owner-arena : i64]) : unit
  (let
    [expr-pool : AstExprNodePoolState (ast-expr-pool-cell-read expr-cell)]
    [type-pool : AstTypeNodePoolState (ast-type-pool-cell-read type-cell)]
    (ast-node-pools-state-install! expr-pool type-pool owner-arena)))

(define (ast-node-pool-context-shared-view
  [pools : (& pools AstNodePoolContext)]) : AstNodePoolContext
  (AstNodePoolContext pools.expr-pool pools.type-pool pools.owner-arena))

;; Independent state cells holding deep copies of both states: what `clone`
;; of a context produced while the context held its cells as dynamic arrays.
(define (ast-node-pool-context-clone [pools : AstNodePoolContext]) : AstNodePoolContext
  (let
    [expr-cell : (__tl_dyn-array AstExprNodePoolState)
      (__tl_make-array (clone (ast-expr-pool-cell-read pools.expr-pool)))]
    [type-cell : (__tl_dyn-array AstTypeNodePoolState)
      (__tl_make-array (clone (ast-type-pool-cell-read pools.type-pool)))]
    (AstNodePoolContext
      (ast-pool-cell-descriptor expr-cell)
      (ast-pool-cell-descriptor type-cell)
      pools.owner-arena)))

;; Pool snapshots can retain different state cells while sharing the same
;; stable segmented storage. Publish the newer cursor/dedup state between those
;; cells without changing either context's stable arena root.
(define (ast-node-pool-context-adopt-newer-cells!
  [target-expr-cell-address : u64]
  [target-type-cell-address : u64]
  [source-expr-cell-address : u64]
  [source-type-cell-address : u64]) : unit
  (let
    [target-expr-cell : (MutPtr AstExprNodePoolState)
      (unsafe
        (int->ptr target-expr-cell-address : (MutPtr AstExprNodePoolState)))]
    [target-type-cell : (MutPtr AstTypeNodePoolState)
      (unsafe
        (int->ptr target-type-cell-address : (MutPtr AstTypeNodePoolState)))]
    [source-expr-cell : (Ptr AstExprNodePoolState)
      (unsafe
        (int->ptr source-expr-cell-address : (Ptr AstExprNodePoolState)))]
    [source-type-cell : (Ptr AstTypeNodePoolState)
      (unsafe
        (int->ptr source-type-cell-address : (Ptr AstTypeNodePoolState)))]
    [target-expr : AstExprNodePoolState
      (unsafe
        (ptr-read target-expr-cell))]
    [source-expr : AstExprNodePoolState
      (unsafe
        (ptr-read source-expr-cell))]
    [target-type : AstTypeNodePoolState
      (unsafe
        (ptr-read target-type-cell))]
    [source-type : AstTypeNodePoolState
      (unsafe
        (ptr-read source-type-cell))]
    [target-dedup : (__tl_dyn-array i64) target-type.dedup-slots]
    [source-dedup : (__tl_dyn-array i64) source-type.dedup-slots]
    (begin
      (if (and
        (= target-expr.segment-bases source-expr.segment-bases)
        (> source-expr.count target-expr.count))
        (unsafe
          (ptr-write! target-expr-cell source-expr))
        unit)
      (if (and
        (= target-type.segment-bases source-type.segment-bases)
        (> source-type.count target-type.count))
        (unsafe
          (ptr-write!
            target-type-cell
            (AstTypeNodePoolState
              source-type.segment-bases
              source-type.count
              source-type.base-arena
              source-type.exhausted
              (if (> (array-length source-dedup) (array-length target-dedup))
                source-dedup
                target-dedup)
              source-type.dedup-count
              source-type.storage-arena
              source-type.segment-count)))
        unit)
      (ast-node-pool-compat-context-sync-installed!))))

(define (ast-node-pool-context-adopt-newer!
  [target : AstNodePoolContext]
  [source : AstNodePoolContext]) : unit
  (ast-node-pool-context-adopt-newer-cells!
    (ast-pool-cell-data target.expr-pool)
    (ast-pool-cell-data target.type-pool)
    (ast-pool-cell-data source.expr-pool)
    (ast-pool-cell-data source.type-pool)))

(define (ast-node-pool-context-from-cells
  [expr-pool : (__tl_dyn-array AstExprNodePoolState)]
  [type-pool : (__tl_dyn-array AstTypeNodePoolState)]
  [owner-arena : i64]) : AstNodePoolContext
  (AstNodePoolContext
    (ast-pool-cell-descriptor expr-pool)
    (ast-pool-cell-descriptor type-pool)
    owner-arena))

;; R3-P2b: these two cells are POOL STATE, not caller state. Any context that is
;; later installed hands them to `ast-node-pool-context-install!`, which points
;; the process-global `ast-node-pool-active-context` straight at them; from then
;; on every push, every `ast-node-pool-context-capture-active!` and every
;; `ast-node-pool-context-active-live` reader writes THROUGH these arrays. They
;; therefore have to outlive every transient arena that can be current while a
;; context is built -- the same invariant `node-pool-base-arena` above states
;; for the pool backing arrays, one level up.
;;
;; A transient arena that is only REWOUND hides a violation; one that is
;; DESTROYED turns it into a hard use-after-free, and macro expansion runs under
;; a per-declaration generation that is `tl_arena_destroy`d: an
;; import-placeholder expansion rebases the active pools onto captured CTFE
;; syntax pools, the context it installs owns cells in that declaration's
;; generation, and the next `capture-active!` -- two splices later, after the
;; generation is gone -- writes into freed pages. The class is pinned by
;; `tests/integration/arena_pool_context_escape.tl`.
;;
;; THE RULE, stated once so every constructor below can be checked against it:
;;
;;   the cells of an `AstNodePoolContext` must be allocated in the arena that
;;   owns the POOL they describe -- never in "whatever arena is current".
;;
;; Every constructor names that owner explicitly:
;;
;;   * `ast-node-pool-context-new-with-capacities-in-arena` describes a FRESH
;;     pool, so the owner is that pool's own `shared-arena` ("the context cells
;;     are part of the pool's retained ownership graph").
;;   * `ast-node-pool-context-capture-active-raw` describes the ACTIVE pool, so
;;     the owner is `node-pool-base-arena` -- the arena that same file already
;;     requires the pool's backing arrays to live in.
;;   * `ast-node-pool-context-new` takes the owner as an argument and has no
;;     default, so a new call site cannot silently inherit the current arena.
;;
;; R3-P2c: an earlier form of this fix gated a redirect INSIDE
;; `ast-node-pool-context-new` on a global flag set while a macro-walk
;; generation was live. That was wrong in both directions:
;;
;;   * it OVERRODE a caller that had already chosen a deliberate owner.
;;     `-new-with-capacities-in-arena` sets the arena to the new pool's
;;     `shared-arena` and then calls this constructor; with the flag on, the
;;     cells were redirected to the GLOBAL base arena instead, so a pool built
;;     during an expansion described itself with cells owned by a different
;;     arena's lifetime. On an `embedded-stdlib-tlci` build the default native
;;     stdlib route re-hydrates the surface through exactly that constructor
;;     from inside macro expansion.
;;   * it was BYPASSABLE. Any future constructor that built cells without
;;     consulting the flag was silently outside the rule.
;;
;; Taking the owner as a parameter fixes both: there is no ambient default to
;; get wrong, and adding a constructor forces the author to name an owner.
;;
;; Arena handles identify stable roots, so targeting the named owner does not
;; require recapturing or republishing a physical chain head afterwards.
;; Pool contexts built by `ast-node-pool-context-new-with-pool-owner`, each two
;; fresh cells; the macro walk reports how many each fired declaration builds.
(cfg
  compile-profile
  (define ast-node-pool-context-profile-allocations : i64
    0))

(define (ast-node-pool-context-new-with-pool-owner
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]
  [allocation-owner-arena : i64]
  [pool-owner-arena : i64]) : AstNodePoolContext
  (let
    [expr-cell : (__tl_dyn-array AstExprNodePoolState)
      (if (= allocation-owner-arena 0)
        (__tl_make-array AstExprNodePoolState 1)
        (in-arena
          (arena.Arena allocation-owner-arena)
          (__tl_make-array AstExprNodePoolState 1)))]
    [type-cell : (__tl_dyn-array AstTypeNodePoolState)
      (if (= allocation-owner-arena 0)
        (__tl_make-array AstTypeNodePoolState 1)
        (in-arena
          (arena.Arena allocation-owner-arena)
          (__tl_make-array AstTypeNodePoolState 1)))]
    (begin
      (cfg
        compile-profile
        (set!
          ast-node-pool-context-profile-allocations
          (+ ast-node-pool-context-profile-allocations 1))
        unit)
      ;; The cells and the state records already have their intended owners.
      ;; Publish the records shallowly: an aggregate assignment would create a
      ;; fresh nested dynamic-array descriptor for `dedup-slots` in whatever
      ;; arena happens to be current.
      (unsafe
        (begin
          (ptr-write!
            (ptr-cast
              (__tl_array-data expr-cell)
              : (MutPtr AstExprNodePoolState))
            expr-pool)
          (ptr-write!
            (ptr-cast
              (__tl_array-data type-cell)
              : (MutPtr AstTypeNodePoolState))
            type-pool)))
      (AstNodePoolContext
        (ast-pool-cell-descriptor expr-cell)
        (ast-pool-cell-descriptor type-cell)
        pool-owner-arena))))

(define (ast-node-pool-context-new
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]
  [owner-arena : i64]) : AstNodePoolContext
  (ast-node-pool-context-new-with-pool-owner
    expr-pool
    type-pool
    owner-arena
    owner-arena))

;: The context that describes the ACTIVE pool. Its owner is the pool's own base
;: arena, unconditionally -- this is the context `ast-node-pool-context-install!`
;: publishes into the process-global, and a global has no reset cadence to align
;: a generation's destroy to, so ownership is the only thing that can make it
;: safe.
(define (ast-node-pool-context-capture-active-raw) : AstNodePoolContext
  (let
    [captured : AstNodePoolContext
      (ast-node-pool-context-new-with-pool-owner
        (ast-node-pool-state-capture)
        (ty-node-pool-state-capture)
        node-pool-base-arena
        node-pool-owner-arena)]
    (begin
      (ast-node-pool-state-capture-to-cell!
        (ast-pool-cell-data captured.expr-pool))
      (ty-node-pool-state-capture-to-cell!
        (ast-pool-cell-data captured.type-pool))
      captured)))

;; R3-P2c: THE BACKSTOP, and the answer to "what prevents the next one".
;;
;; Naming an owner at every constructor (above) is a rule a NEW call site can
;; still get wrong, typically from a producer nobody had enumerated. So the
;; guard is moved off the producers and onto the one place every escape of this
;; class must pass: the moment a transient generation is destroyed.
;;
;; `ast-node-pool-context-transient-witness` is the generation handle that is
;; live right now, published by the macro walk around each expansion.
;; `install!` records it, so the process-global always knows whether the cells it
;; currently aliases belong to a transient arena and to WHICH one. Before a
;; generation is destroyed the walk asks
;; `ast-node-pool-active-context-owned-by?`, and if the answer is yes it
;; RESEATS: re-captures the identical pool state into base-arena-owned cells and
;; re-installs. The pool state is copied by value, so nothing is lost; only the
;; cells the global aliases change, and they change to storage that outlives
;; every generation.
;;
;; This is why no future producer has to be enumerated. It does not matter which
;; path built the context or whether its author knew the rule: if it published
;; into the global from inside a generation, the destroy repairs it first.
(define ast-node-pool-context-transient-witness : i64
  0)
(define ast-node-pool-active-context-owner : i64
  0)

(define (ast-node-pool-context-transient-witness! [generation : i64]) : unit
  (set! ast-node-pool-context-transient-witness generation))

(define (ast-node-pool-active-context-owned-by? [generation : i64]) : bool
  (and (not (= generation 0)) (= ast-node-pool-active-context-owner generation)))

(define (ast-node-pool-active-context-reseat!) : unit
  (if (not ast-node-pool-active-context-installed?)
    (set! ast-node-pool-active-context-owner 0)
    (let
      [saved-witness : i64 ast-node-pool-context-transient-witness]
      [_clear : unit (set! ast-node-pool-context-transient-witness 0)]
      [fresh : AstNodePoolContext (ast-node-pool-context-capture-active-raw)]
      [_install : unit (ast-node-pool-context-install! fresh)]
      (begin
        (set! ast-node-pool-context-transient-witness saved-witness)
        (set! ast-node-pool-active-context-owner 0)))))

(define ast-node-pool-compat-context-explicit? : bool
  false)
(define ast-node-pool-compat-context-cell : (__tl_dyn-array AstNodePoolContext)
  (__tl_make-array (ast-node-pool-context-capture-active-raw)))
(define ast-node-pool-compat-saved-context-cell : (__tl_dyn-array
    AstNodePoolContext)
  (__tl_make-array (ast-node-pool-context-capture-active-raw)))

(define (ast-node-pool-context-capture-active) : AstNodePoolContext
  (if ast-node-pool-compat-context-explicit?
    (let
      [compat : AstNodePoolContext
        (array-ref ast-node-pool-compat-context-cell 0)]
      (ast-node-pool-context-new-with-pool-owner
        (ast-expr-pool-cell-read compat.expr-pool)
        (ast-type-pool-cell-read compat.type-pool)
        ;; Describes the compat pool, so the compat pool's base arena owns it.
        (__tl-project-field
          (ast-expr-pool-cell-read compat.expr-pool)
          base-arena)
        compat.owner-arena))
    (ast-node-pool-context-capture-active-raw)))

(define ast-node-pool-active-context-installed? : bool
  false)
(define ast-node-pool-active-context : AstNodePoolContext
  (ast-node-pool-context-capture-active))

(define (ast-node-pool-active-context-capture-expr!) : unit
  (if ast-node-pool-active-context-installed?
    (ast-node-pool-state-capture-to-cell!
      (ast-pool-cell-data
        (__tl-project-field ast-node-pool-active-context expr-pool)))
    unit))

(define (ast-node-pool-active-context-capture-type!) : unit
  (if ast-node-pool-active-context-installed?
    (ty-node-pool-state-capture-to-cell!
      (ast-pool-cell-data
        (__tl-project-field ast-node-pool-active-context type-pool)))
    unit))

(define ast-node-pool-reader-explicit? : bool
  false)
(define ast-node-pool-reader-context : AstNodePoolContext
  (ast-node-pool-context-capture-active))

(define (ast-node-pool-reader-use! [pools : AstNodePoolContext]) : unit
  (begin
    (set! ast-node-pool-reader-context pools)
    (set! ast-node-pool-reader-explicit? true)))

(define (ast-node-pool-reader-clear!) : unit
  (set! ast-node-pool-reader-explicit? false))

(define (ast-node-pool-compat-context-use! [pools : AstNodePoolContext]) : unit
  (begin
    (set!
      (array-ref ast-node-pool-compat-saved-context-cell 0)
      (ast-node-pool-context-capture-active-raw))
    (set! (array-ref ast-node-pool-compat-context-cell 0) pools)
    (set! ast-node-pool-compat-context-explicit? true)
    (let
      [context : AstNodePoolContext
        (array-ref ast-node-pool-compat-context-cell 0)]
      (ast-node-pools-cells-install!
        context.expr-pool
        context.type-pool
        context.owner-arena))))

(define (ast-node-pool-compat-context-clear!) : unit
  (begin
    (let
      [context : AstNodePoolContext
        (array-ref ast-node-pool-compat-saved-context-cell 0)]
      (ast-node-pools-cells-install!
        context.expr-pool
        context.type-pool
        context.owner-arena))
    (set! ast-node-pool-compat-context-explicit? false)))

(define (ast-node-pool-compat-context-active?) : bool
  ast-node-pool-compat-context-explicit?)

(define (ast-node-pool-compat-context-current) : AstNodePoolContext
  (array-ref ast-node-pool-compat-context-cell 0))

(define (ast-node-pool-compat-context-sync-installed!) : unit
  (if ast-node-pool-compat-context-explicit?
    (let
      [context : AstNodePoolContext
        (array-ref ast-node-pool-compat-context-cell 0)]
      (ast-node-pools-cells-install!
        context.expr-pool
        context.type-pool
        context.owner-arena))
    unit))

(define (ast-node-pool-context-snapshot [pools : AstNodePoolContext]) : AstNodePoolContext
  (ast-node-pool-context-new-with-pool-owner
    (ast-expr-pool-cell-read pools.expr-pool)
    (ast-type-pool-cell-read pools.type-pool)
    ;; A snapshot describes the same pool, so it has the same owner.
    (ast-node-pool-context-base-arena pools)
    pools.owner-arena))

(define (ast-node-pool-context-capture-active! [pools : AstNodePoolContext]) : unit
  (if ast-node-pool-compat-context-explicit?
    unit
    (begin
      (ast-node-pool-state-capture-to-cell!
        (ast-pool-cell-data pools.expr-pool))
      (ty-node-pool-state-capture-to-cell! (ast-pool-cell-data pools.type-pool)))))

;; Publish whichever of `pools` and the installed globals is longer, per pool.
;; Explicit pushes through `pools` advance only its cells while global pushers
;; advance only the globals, so either side can be ahead. Capturing
;; unconditionally rolls back nodes pushed through the cells, and installing
;; unconditionally rolls back nodes pushed globally; either lets a later push
;; overwrite a live node behind its dedup entry.
(define (ast-node-pool-context-publish-newer! [pools : AstNodePoolContext]) : unit
  (if ast-node-pool-compat-context-explicit?
    unit
    (let
      [expr-state : AstExprNodePoolState
        (ast-expr-pool-cell-read pools.expr-pool)]
      [type-state : AstTypeNodePoolState
        (ast-type-pool-cell-read pools.type-pool)]
      (begin
        (if (and
          (= expr-state.segment-bases ast-node-pool-segment-bases)
          (< expr-state.count ast-node-pool-count))
          (ast-node-pool-state-capture-to-cell!
            (ast-pool-cell-data pools.expr-pool))
          unit)
        (if (and
          (= type-state.segment-bases ty-node-pool-segment-bases)
          (< type-state.count ty-node-pool-count))
          (ty-node-pool-state-capture-to-cell!
            (ast-pool-cell-data pools.type-pool))
          unit)
        (ast-node-pool-context-install! pools)))))

(define (ast-node-pool-active-context-clear!) : unit
  (set! ast-node-pool-active-context-installed? false))

;: Whether an explicit pool context is installed, i.e. whether
;: `ast-node-pool-context-active-live` shares cells with the pushers.
(define (ast-node-pool-has-active-context?) : bool
  ast-node-pool-active-context-installed?)

;: The installed pool context, SHARING its cells with the globals the pushers
;: read. `ast-node-pool-context-capture-active` snapshots into fresh cells, so a
;: push through it is invisible to the installed pool; a caller that must append
;: to the live pool and then hand the result back to the walk needs these cells.
;: Only meaningful while `ast-node-pool-has-active-context?` holds.
(define (ast-node-pool-context-active-live) : AstNodePoolContext
  ast-node-pool-active-context)

(define (ast-node-pool-active-context-expr-cell-address) : u64
  (ast-pool-cell-data
    (__tl-project-field-name ast-node-pool-active-context "expr-pool")))

(define (ast-node-pool-active-context-type-cell-address) : u64
  (ast-pool-cell-data
    (__tl-project-field-name ast-node-pool-active-context "type-pool")))

;; The newest segment of the active node-pool chain. The pool arena's live
;; chain is only reachable from this head (overflow segments link newest->root
;; by `prev`), so a reset/destroy that starts from the make() root handle leaks
;; every overflow segment. Callers releasing a grown pool arena must destroy
;; from this head.
(define (ast-node-pool-base-arena-handle) : i64
  node-pool-base-arena)

(define (ast-node-pool-owner-arena-handle) : i64
  node-pool-owner-arena)

(define (ast-node-pool-expr-storage-arena-handle) : i64
  ast-node-pool-storage-arena)

(define (ast-node-pool-type-storage-arena-handle) : i64
  ty-node-pool-storage-arena)

(define (ast-node-pool-context-install! [pools : AstNodePoolContext]) : unit
  (if ast-node-pool-compat-context-explicit?
    unit
    (in-arena
      (arena.Arena (ast-node-pool-context-base-arena pools))
      (begin
        (compiler-arena-debug-assert-pool-install!
          (__tl-project-field
            (ast-expr-pool-cell-read pools.expr-pool)
            base-arena))
        (ast-node-pools-cells-install!
          pools.expr-pool
          pools.type-pool
          pools.owner-arena)
        (let
          [stable : AstNodePoolContext pools]
          [source : (Ptr i64)
            (unsafe
              (int->ptr (ast-place-address stable) : (Ptr i64)))]
          [dest : (MutPtr i64)
            (unsafe
              (ptr-cast
                (ptr-addr-of ast-node-pool-active-context)
                : (MutPtr i64)))]
          (unsafe
            (begin
              (ptr-write! dest (ptr-read source))
              (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
              (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2))))))
        ;; R3-P2c: remember WHICH transient generation, if any, was live when
        ;; these cells were published. See `ast-node-pool-active-context-reseat!`.
        (set!
          ast-node-pool-active-context-owner
          ast-node-pool-context-transient-witness)
        (set! ast-node-pool-active-context-installed? true)))))

;; Commit a completed explicit-context phase back to the compatibility context
;; selected for the compile. CTFE syntax and hygiene can use distinct state
;; cells over the same pool storage; copying the final states preserves the
;; selected context owner while making every committed node visible to legacy
;; global readers. Outside compatibility mode, installing the context is the
;; equivalent publication boundary.
(define (ast-node-pool-context-publish-to-compat! [pools : AstNodePoolContext]) : unit
  (if ast-node-pool-compat-context-explicit?
    (let
      [selected : AstNodePoolContext
        (array-ref ast-node-pool-compat-context-cell 0)]
      (begin
        (ast-expr-pool-cell-write!
          selected.expr-pool
          (ast-expr-pool-cell-read pools.expr-pool))
        (ast-type-pool-cell-write!
          selected.type-pool
          (ast-type-pool-cell-read pools.type-pool))
        (ast-node-pool-compat-context-sync-installed!)))
    (ast-node-pool-context-install! pools)))

(defmacro (ast-node-pool-context-expr-len [pools : Expr]) : i64
  `(__tl-project-field
    (ast-expr-pool-cell-read (__tl-project-field-name ,pools "expr-pool"))
    count))

(defmacro (ast-node-pool-context-expr-capacity [pools : Expr]) : i64
  `(*
    (__tl-project-field
      (ast-expr-pool-cell-read (__tl-project-field-name ,pools "expr-pool"))
      segment-count)
    ast-expr-node-pool-segment-size))

(defmacro (ast-node-pool-context-expr-segment-count [pools : Expr]) : i64
  `(__tl-project-field
    (ast-expr-pool-cell-read (__tl-project-field-name ,pools "expr-pool"))
    segment-count))

(defmacro (ast-node-pool-context-expr-segment-bytes [pools : Expr]) : i64
  `(*
    (ast-node-pool-context-expr-segment-count ,pools)
    ast-expr-node-pool-segment-bytes))

(defmacro (ast-node-pool-context-type-len [pools : Expr]) : i64
  `(__tl-project-field
    (ast-type-pool-cell-read (__tl-project-field-name ,pools "type-pool"))
    count))

(defmacro (ast-node-pool-context-type-capacity [pools : Expr]) : i64
  `(*
    (__tl-project-field
      (ast-type-pool-cell-read (__tl-project-field-name ,pools "type-pool"))
      segment-count)
    ast-type-node-pool-segment-size))

(defmacro (ast-node-pool-context-type-segment-count [pools : Expr]) : i64
  `(__tl-project-field
    (ast-type-pool-cell-read (__tl-project-field-name ,pools "type-pool"))
    segment-count))

(defmacro (ast-node-pool-context-type-segment-bytes [pools : Expr]) : i64
  `(*
    (ast-node-pool-context-type-segment-count ,pools)
    ast-type-node-pool-segment-bytes))

(defmacro (ast-node-pool-context-expr-storage-arena [pools : Expr]) : i64
  `(__tl-project-field
    (ast-expr-pool-cell-read (__tl-project-field-name ,pools "expr-pool"))
    storage-arena))

(defmacro (ast-node-pool-context-type-storage-arena [pools : Expr]) : i64
  `(__tl-project-field
    (ast-type-pool-cell-read (__tl-project-field-name ,pools "type-pool"))
    storage-arena))

(defmacro (ast-node-pool-context-type-exhausted? [pools : Expr]) : bool
  `(__tl-project-field
    (ast-type-pool-cell-read (__tl-project-field-name ,pools "type-pool"))
    exhausted))

(defmacro (ast-node-pool-context-base-arena [pools : Expr]) : i64
  `(__tl-project-field
    (ast-expr-pool-cell-read (__tl-project-field-name ,pools "expr-pool"))
    base-arena))

(defmacro (ast-node-pool-context-owner-arena [pools : Expr]) : i64
  `(__tl-project-field-name ,pools "owner-arena"))

;; Segments have no interior pointers into their backing arenas, so adding one
;; never copies or relocates prior nodes. Expression and type segments use
;; separate small-root storage chains; payloads, dedup state, segment tables,
;; and context cells remain in `base-arena`.
(define (ast-node-pool-storage-arenas-destroy!
  [expr-storage : i64]
  [type-storage : i64]
  [base-arena : i64]) : unit
  (let
    [current-arena : i64 (arena.tl_arena_current)]
    (begin
      (if (or (= current-arena expr-storage) (= current-arena type-storage))
        (unsafe
          (arena.tl_arena_set base-arena))
        unit)
      (if (= expr-storage 0)
        unit
        (unsafe
          (arena.tl_arena_destroy expr-storage)))
      (if (or (= type-storage 0) (= type-storage expr-storage))
        unit
        (unsafe
          (arena.tl_arena_destroy type-storage))))))

(define (ast-node-pool-context-destroy-storage! [pools : AstNodePoolContext]) : unit
  (ast-node-pool-storage-arenas-destroy!
    (ast-node-pool-context-expr-storage-arena pools)
    (ast-node-pool-context-type-storage-arena pools)
    (ast-node-pool-context-base-arena pools)))

(define (ast-node-pool-context-new-with-capacities-in-arena
  [expr-capacity : i64]
  [type-capacity : i64]
  [base-arena : i64]) : AstNodePoolContext
  (let
    [expr-pool : AstExprNodePoolState
      (ast-expr-node-pool-state-init expr-capacity base-arena)]
    [type-pool : AstTypeNodePoolState
      (ast-type-node-pool-state-init type-capacity expr-pool.base-arena)]
    [shared-arena : i64 type-pool.base-arena]
    ;; The context cells are part of the pool's retained ownership graph. If
    ;; they land in the caller's active scratch arena, committing the pool and
    ;; releasing that scratch arena leaves every explicit pool access dangling.
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-pool-owner
        (ast-expr-node-pool-state-with-base-arena expr-pool shared-arena)
        (ast-type-node-pool-state-with-base-arena type-pool shared-arena)
        shared-arena
        shared-arena)]
    pools))

(define (ast-node-pool-context-new-with-capacities
  [expr-capacity : i64]
  [type-capacity : i64]) : AstNodePoolContext
  (ast-node-pool-context-new-with-capacities-in-arena
    expr-capacity
    type-capacity
    (arena.tl_arena_current)))

(define (ast-node-pool-context-reset-to!
  [pools : AstNodePoolContext]
  [expr-mark : i64]
  [type-mark : i64]) : unit
  (begin
    (ast-expr-pool-cell-write!
      pools.expr-pool
      (ast-expr-node-pool-state-reset-to
        (ast-expr-pool-cell-read pools.expr-pool)
        expr-mark))
    (ast-type-pool-cell-write!
      pools.type-pool
      (ast-type-node-pool-state-reset-to
        (ast-type-pool-cell-read pools.type-pool)
        type-mark))
    (ast-node-pool-compat-context-sync-installed!)))

;; Clear the type-node dedup index on a captured pool context without
;; truncating any live nodes. Pushes after this rebuild the index from the
;; current node prefix, so a stale dedup entry inherited from a prior batch
;; entry's pool snapshot can never resolve to an id whose slot now holds an
;; unrelated node.
(define (ast-node-pool-context-type-dedup-clear! [pools : AstNodePoolContext]) : unit
  (begin
    (ast-type-pool-cell-write!
      pools.type-pool
      (ast-type-node-pool-state-dedup-clear
        (ast-type-pool-cell-read pools.type-pool)))
    (ast-node-pool-compat-context-sync-installed!)))

(define (ast-node-pool-context-expr-installed? [pools : AstNodePoolContext]) : bool
  (if (ast-node-pool-compat-context-active?)
    (=
      (ast-node-pool-context-expr-cell-address pools)
      (ast-node-pool-context-expr-cell-address
        (ast-node-pool-compat-context-current)))
    (and
      (ast-node-pool-has-active-context?)
      (=
        (ast-node-pool-context-expr-cell-address pools)
        (ast-node-pool-context-expr-cell-address
          (ast-node-pool-context-active-live))))))

(define (ast-node-pool-context-expr-cell-address [pools : AstNodePoolContext]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (ast-expr-pool-cell-ptr pools.expr-pool) : (Ptr u8))))
    : i64))

;; Publish a completed explicit expression-pool transaction to transitional
;; global constructors when its cells belong to the installed owner. Callers
;; that build and then truncate temporary nodes must invoke this only after the
;; durable cursor is known; exposing each intermediate cursor lets a nested
;; legacy constructor observe replacement nodes that are about to be rewound.
(define (ast-node-pool-context-expr-sync-installed!
  [pools : AstNodePoolContext]) : unit
  (if (not (ast-node-pool-context-expr-installed? pools))
    unit
    (let
      [state : AstExprNodePoolState (ast-expr-pool-cell-read pools.expr-pool)]
      (begin
        (set! ast-node-pool-segment-bases state.segment-bases)
        (set! ast-node-pool-count state.count)
        (set! ast-node-pool-storage-arena state.storage-arena)
        (set! ast-node-pool-segment-count state.segment-count)
        (set! ast-node-span-slot-segment-bases state.span-slot-segment-bases)
        (set! ast-node-canonical-span-records state.canonical-span-records)
        (set! ast-node-canonical-span-count state.canonical-span-count)
        (set! ast-node-respan-records state.respan-records)
        (set! ast-node-respan-count state.respan-count)
        (set! ast-node-span-records-monotonic? state.span-records-monotonic?)
        (set! node-pool-base-arena state.base-arena)
        (set! node-pool-owner-arena pools.owner-arena)))))

(define (ast-node-pool-context-expr-push
  [pools : AstNodePoolContext]
  [node : AstExpr]) : i64
  (let
    [cell : (__tl_dyn-array AstExprNodePoolState)
      (ast-expr-pool-cell pools.expr-pool)]
    [id : i64
      (ast-expr-node-pool-state-push-in-place! (&mut (array-ref cell 0)) node)]
    (begin
      ;; Compatibility adapters historically require eager publication.
      ;; Ordinary explicit owners publish at their stable phase boundary.
      (ast-node-pool-compat-context-sync-installed!)
      id)))

;; Scalar cell-address entrypoint for an aggregate pool embedded in a borrowed
;; outer state object. This avoids materializing an owned AstNodePoolContext at
;; the boundary while retaining the same grow/base-arena synchronization.
(define (ast-node-pool-context-expr-push-cells
  [expr-cell-address : u64]
  [type-cell-address : u64]
  [node : AstExpr]) : i64
  (let
    [expr-cell : (MutPtr AstExprNodePoolState)
      (unsafe
        (int->ptr expr-cell-address : (MutPtr AstExprNodePoolState)))]
    [type-cell : (MutPtr AstTypeNodePoolState)
      (unsafe
        (int->ptr type-cell-address : (MutPtr AstTypeNodePoolState)))]
    [current : AstExprNodePoolState
      (unsafe
        (ptr-read expr-cell))]
    [current-base-arena : i64 current.base-arena]
    (match (ast-expr-node-pool-state-push current node)
      [(AstExprNodePoolPushOk next id)
        (let
          [next-base-arena : i64 next.base-arena]
          (begin
            (unsafe
              (ptr-write! expr-cell next))
            (if (not (= current-base-arena next-base-arena))
              (unsafe
                (ptr-write!
                  type-cell
                  (ast-type-node-pool-state-with-base-arena
                    (ptr-read type-cell)
                    next-base-arena)))
              unit)
            (ast-node-pool-compat-context-sync-installed!)
            id))])))

(define (ast-node-pool-context-expr-push-borrowed
  [pools : (& pools AstNodePoolContext)]
  [node : AstExpr]) : i64
  (ast-node-pool-context-expr-push-cells
    (ast-pool-cell-data pools.expr-pool)
    (ast-pool-cell-data pools.type-pool)
    node))

;; Raw expression-node read keyed by the pool's segment-bases pointer rather
;; than a pool value, mirroring `ast-type-segment-bases-get` on the type side.
;; Addressing is `ast-node-get`'s without its process-global load, so a
;; read-only walk that hoists the pointer once pays less per node than the
;; installed-pool fast path, and much less than a per-node
;; `AstNodePoolContext` read.
(define (ast-expr-segment-bases-get [segment-bases : i64] [id : i64]) : AstExpr
  (let
    [biased-base : i64
      (unsafe
        (ptr-read (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 16))))]
    (unsafe
      (ptr-read
        (int->ptr (+ biased-base (* id (ast-expr-node-bytes))) : (Ptr AstExpr))))))

;; Immediate representation-level view of one row in the current pool
;; generation. Segments never relocate, so appending or rewriting other rows
;; cannot invalidate the address; reset/generation handoff and rewriting this
;; exact row still end the view's lifetime. Keeping this as a macro lets
;; aggregate call lowering hand the stable row directly to the callee instead
;; of returning it through a second 32-byte value slot.
(defmacro (ast-expr-segment-bases-shared-view
  [segment-bases : Expr]
  [id : Expr]) : Expr
  `(let
    [bases-address : i64 ,segment-bases]
    [row-id : i64 ,id]
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset (int->ptr bases-address : (Ptr i64)) (shr row-id 16))))]
    (unsafe
      (ptr-read
        (int->ptr
          (+ biased-base (* row-id (ast-expr-node-bytes)))
          : (Ptr AstExpr))))))

;; Segment-bases pointer of the context's live expr-pool cell. A grow appends to
;; this table in place and never moves it, and a push rewrites the cell without
;; changing the pointer, so a walk may cache it across reads; only installing a
;; different pool context invalidates it.
(define (ast-node-pool-context-expr-segment-bases
  [pools : (& pools AstNodePoolContext)]) : i64
  (__tl-project-field
    (unsafe
      (ptr-read (ast-expr-pool-cell-ptr pools.expr-pool)))
    segment-bases))

;; Segment-bases pointer of the process-global (installed) expression pool, the
;; one `ast-node-get` reads.
(define (ast-node-pool-active-expr-segment-bases) : i64
  ast-node-pool-segment-bases)

(define (ast-node-pool-context-expr-get
  [pools : (& pools AstNodePoolContext)]
  [id : i64]) : AstExpr
  (ast-expr-segment-bases-get
    (ast-node-pool-context-expr-segment-bases pools)
    id))

(define (ast-node-pool-context-expr-view-span
  [pools : (& pools AstNodePoolContext)]
  [id : i64]) : AstMaybeSourceSpan
  (let
    [bound-2 (ast-expr-pool-cell-read pools.expr-pool)]
    (ast-expr-node-pool-state-view-span bound-2 id)))

(define (ast-node-pool-context-expr-canonical-span-count
  [pools : (& pools AstNodePoolContext)]) : i64
  (ast-expr-node-pool-state-canonical-span-count
    (ast-expr-pool-cell-read pools.expr-pool)))

(define (ast-node-pool-context-expr-respan-count
  [pools : (& pools AstNodePoolContext)]) : i64
  (ast-expr-node-pool-state-respan-count
    (ast-expr-pool-cell-read pools.expr-pool)))

(define (ast-node-pool-context-expr-span-oracle
  [pools : (& pools AstNodePoolContext)]
  [id : i64]) : AstExprSpanOracleResult
  (ast-expr-node-pool-state-span-oracle
    (ast-expr-pool-cell-read pools.expr-pool)
    id))

(define (ast-node-pool-context-expr-span-oracle-ok?
  [pools : (& pools AstNodePoolContext)]) : bool
  (ast-expr-node-pool-state-span-oracle-ok?
    (ast-expr-pool-cell-read pools.expr-pool)))

(define (ast-node-pool-context-expr-set!
  [pools : AstNodePoolContext]
  [id : i64]
  [node : AstExpr]) : unit
  (begin
    (ast-expr-pool-cell-write!
      pools.expr-pool
      (ast-expr-node-pool-state-set!
        (ast-expr-pool-cell-read pools.expr-pool)
        id
        node))
    (ast-node-pool-compat-context-sync-installed!)))

(define (ast-node-pool-context-expr-truncate!
  [pools : AstNodePoolContext]
  [mark : i64]) : unit
  (begin
    (ast-expr-pool-cell-write!
      pools.expr-pool
      (ast-expr-node-pool-state-reset-to
        (ast-expr-pool-cell-read pools.expr-pool)
        mark))
    (ast-node-pool-compat-context-sync-installed!)))

(define (ast-node-pool-context-type-push
  [pools : AstNodePoolContext]
  [node : AstType]) : i64
  (let
    [current : AstTypeNodePoolState (ast-type-pool-cell-read pools.type-pool)]
    (match (ast-type-node-pool-state-push current node)
      [(AstTypeNodePoolPushOk next id)
        (begin
          (ast-type-pool-cell-write! pools.type-pool next)
          (ast-node-pool-context-type-sync-installed! pools)
          id)])))

(define (ast-node-pool-context-type-push-cells
  [expr-cell-address : u64]
  [type-cell-address : u64]
  [node : AstType]) : i64
  (let
    [expr-cell : (MutPtr AstExprNodePoolState)
      (unsafe
        (int->ptr expr-cell-address : (MutPtr AstExprNodePoolState)))]
    [type-cell : (MutPtr AstTypeNodePoolState)
      (unsafe
        (int->ptr type-cell-address : (MutPtr AstTypeNodePoolState)))]
    [current : AstTypeNodePoolState
      (unsafe
        (ptr-read type-cell))]
    (match (ast-type-node-pool-state-push (ast-global-shared-view current) node)
      [(AstTypeNodePoolPushOk next id)
        (begin
          (unsafe
            (ptr-write! type-cell next))
          (if (not (= current.base-arena next.base-arena))
            (unsafe
              (ptr-write!
                expr-cell
                (ast-expr-node-pool-state-with-base-arena
                  (ptr-read expr-cell)
                  next.base-arena)))
            unit)
          (ast-node-pool-compat-context-sync-installed!)
          id)])))

;; Raw type-node read keyed by the pool's segment-bases pointer rather than a
;; pool value. Identical addressing to `ty-node-get`, so hot readers can hoist
;; the context lookup out of recursive walks and pay the same per-node cost as
;; the installed-pool fast path.
(define (ast-type-segment-bases-get [segment-bases : i64] [id : i64]) : AstType
  (let
    [biased-base : i64
      (unsafe
        (ptr-read (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 10))))]
    (unsafe
      (ptr-read
        (int->ptr (+ biased-base (* id (ast-type-node-bytes))) : (Ptr AstType))))))

;; A borrowed Slice or `bytes` is a fat reference: two integer-class words, the
;; data pointer and then the signed length, with no referent record in memory.
;; Every other reference is one pointer word. `referent` is the reference's
;; immediate referent with its Region wrappers already stripped.
(define (ast-type-fat-referent? [referent : AstType]) : bool
  (match referent
    [(AstType.Slice _) true]
    [(AstType.Bytes) true]
    [_ false]))

;; `ast-type-fat-referent?` for the referent node `inner` of the type pool at
;; `type-segment-bases`, peeling Region wrappers.
(define (ast-type-segment-bases-fat-referent?
  [type-segment-bases : i64]
  [inner : i64]) : bool
  (match (ast-type-segment-bases-get type-segment-bases inner)
    [(AstType.Region _ nested)
      (ast-type-segment-bases-fat-referent? type-segment-bases nested)]
    [(AstType.Slice _) true]
    [(AstType.Bytes) true]
    [_ false]))

;; Return the canonical nominal identity for aggregate metadata. Region is a
;; transparent ownership wrapper; every non-aggregate shape stays explicit as
;; None so callers never need an empty-string or integer sentinel.
(define (ast-aggregate-type-key [type-segment-bases : i64] [ty : AstType]) : AstMaybeNominalKey
  (match ty
    [(AstType.Struct name)
      (AstMaybeNominalKey.Some (ast-nominal-name-id-key name))]
    [(AstType.StructArgs name _)
      (AstMaybeNominalKey.Some (ast-nominal-name-id-key name))]
    [(AstType.Enum name)
      (AstMaybeNominalKey.Some (ast-nominal-name-id-key name))]
    [(AstType.EnumArgs name _)
      (AstMaybeNominalKey.Some (ast-nominal-name-id-key name))]
    [(AstType.Region _ inner)
      (ast-aggregate-type-key
        type-segment-bases
        (ast-type-segment-bases-get type-segment-bases inner))]
    [_ AstMaybeNominalKey.None]))

;; Segment-bases pointer of the context's live type-pool cell. The cell is
;; replaced on every push, so callers may only cache this across pure reads.
(define (ast-node-pool-context-type-segment-bases
  [pools : (& pools AstNodePoolContext)]) : i64
  (__tl-project-field (ast-type-pool-cell-read pools.type-pool) segment-bases))

(define (ast-node-pool-context-type-cell-address
  [pools : (& pools AstNodePoolContext)]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (ast-type-pool-cell-ptr pools.type-pool) : (Ptr u8))))
    : i64))

;; Cell identity, rather than a segment-bases comparison, distinguishes the
;; live installed owner from a snapshot that shares immutable prefix segments
;; but has an independent logical length.
(define (ast-node-pool-context-type-installed?
  [pools : (& pools AstNodePoolContext)]) : bool
  (if (ast-node-pool-compat-context-active?)
    (let
      [current : AstNodePoolContext (ast-node-pool-compat-context-current)]
      (=
        (ast-node-pool-context-type-cell-address pools)
        (ast-node-pool-context-type-cell-address (& current))))
    (and
      (ast-node-pool-has-active-context?)
      (let
        [current : AstNodePoolContext (ast-node-pool-context-active-live)]
        (=
          (ast-node-pool-context-type-cell-address pools)
          (ast-node-pool-context-type-cell-address (& current)))))))

;; An explicit push through the cells of the ordinary installed context must
;; publish its new count/dedup state to the transitional global pushers. This
;; is an append, so existing ids remain valid and the pool generation must not
;; change. This type-only publication also avoids treating every explicit
;; compatibility append as a pool swap and needlessly invalidating id memos.
(define (ast-node-pool-context-type-sync-installed!
  [pools : (& pools AstNodePoolContext)]) : unit
  (if (not (ast-node-pool-context-type-installed? pools))
    unit
    (let
      [state : AstTypeNodePoolState (ast-type-pool-cell-read pools.type-pool)]
      (begin
        (set! ty-node-pool-segment-bases state.segment-bases)
        (set! ty-node-pool-count state.count)
        (set! ty-node-pool-storage-arena state.storage-arena)
        (set! ty-node-pool-segment-count state.segment-count)
        (set! ty-node-pool-exhausted state.exhausted)
        (set! ty-node-dedup-capacity (array-length state.dedup-slots))
        (set! ty-node-dedup-slots state.dedup-slots)
        (set!
          ty-node-dedup-slots-data-address
          (unsafe
            (ptr->int (__tl_array-data ty-node-dedup-slots))))
        (set! ty-node-dedup-count state.dedup-count)
        (set! node-pool-base-arena state.base-arena)
        (set! node-pool-owner-arena pools.owner-arena)))))

(define (ast-node-pool-context-type-get
  [pools : (& pools AstNodePoolContext)]
  [id : i64]) : AstType
  (ast-type-segment-bases-get
    (ast-node-pool-context-type-segment-bases pools)
    id))

;; Lowered IR retains AstType ids but no AstExpr ids. Clone the small canonical
;; type pool in id order so a compile driver can retire the checked-expression
;; arena before optimize/backend without rewriting any IR types. Raw pushes
;; deep-persist owned payloads while retaining intentional duplicate ids; copy
;; the source dedup index verbatim because every indexed id stays unchanged.
(define (ast-node-pool-context-clone-types-only [source : AstNodePoolContext]) : AstNodePoolContext
  (let
    [source-state : AstTypeNodePoolState
      (ast-type-pool-cell-read source.type-pool)]
    [count : i64 (ast-type-node-pool-state-len source-state)]
    [previous-arena : i64 (arena.tl_arena_current)]
    [new-arena : i64 (ast-node-pool-arena-make)]
    [_set-new-arena : unit
      (unsafe
        (arena.tl_arena_set new-arena))]
    [dest : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        1
        (+ (* count 2) 1024)
        new-arena)]
    [i : i64 0]
    (begin
      (while (< i count)
        (match (ast-type-node-pool-state-push-raw
          (ast-type-pool-cell-read dest.type-pool)
          (ast-type-node-pool-state-get source-state i))
          [(AstTypeNodePoolPushOk next _)
            (begin
              (ast-type-pool-cell-write! dest.type-pool next)
              ;; Raw pushes append exactly once and therefore retain the
              ;; source's insertion-ordered id.
              (set! i (+ i 1)))]))
      (let
        [source-dedup : (__tl_dyn-array i64) source-state.dedup-slots]
        [dedup-cap : i64 (array-length source-dedup)]
        [dedup-copy : (__tl_dyn-array i64) (__tl_make-array i64 dedup-cap)]
        [dedup-i : i64 0]
        (begin
          (while (< dedup-i dedup-cap)
            (begin
              (set!
                (array-ref dedup-copy dedup-i)
                (array-ref source-dedup dedup-i))
              (set! dedup-i (+ dedup-i 1))))
          (let
            [cloned : AstTypeNodePoolState
              (ast-type-pool-cell-read dest.type-pool)]
            (ast-type-pool-cell-write!
              dest.type-pool
              (AstTypeNodePoolState
                cloned.segment-bases
                cloned.count
                cloned.base-arena
                source-state.exhausted
                dedup-copy
                source-state.dedup-count
                cloned.storage-arena
                cloned.segment-count)))))
      (unsafe
        (arena.tl_arena_set previous-arena))
      dest)))

;; Explicit reader used by compile-job phases. The pools value is intentionally
;; part of the call so interleaved jobs cannot observe whichever context a
;; compatibility caller most recently installed.
;; Legacy/test bridge for public adapters whose historical API has no pools
;; parameter. Explicit compile-job entry points never call this helper.
(define (ast-node-pool-reader-type-segment-bases) : i64
  (if ast-node-pool-reader-explicit?
    (ast-node-pool-context-type-segment-bases ast-node-pool-reader-context)
    ty-node-pool-segment-bases))

;; Legacy/test bridge for APIs that now require a pools value. Capturing the
;; compatibility globals is intentionally outside every compile-job path.
(define (ast-node-pool-reader-context-current) : AstNodePoolContext
  (if ast-node-pool-reader-explicit?
    ast-node-pool-reader-context
    (ast-node-pool-context-capture-active)))

;; Legacy/test adapter for callers that still run against the installed reader
;; context. Production lower/optimize/regalloc/backend paths use the explicit
;; twin above (or hoist its segment-bases pointer for hot recursive walks).
(define (ast-node-pool-reader-type-get [id : i64]) : AstType
  (if ast-node-pool-reader-explicit?
    (ast-node-pool-context-type-get ast-node-pool-reader-context id)
    (ty-node-get id)))

(define (ast-node-pool-reader-type-push [node : AstType]) : i64
  (if ast-node-pool-reader-explicit?
    (ast-node-pool-context-type-push ast-node-pool-reader-context node)
    (ty-node-push node)))

(define (ast-node-pool-reader-type-exhausted?) : bool
  (if ast-node-pool-reader-explicit?
    (ast-node-pool-context-type-exhausted? ast-node-pool-reader-context)
    (ty-node-pool-exhausted?)))

(defstruct AstExprList
  (slots (__tl_dyn-array i64))
  (len i64))

(defstruct AstExprClause
  (first i64)
  (second i64))

(defstruct AstExprClauseList
  (slots (__tl_dyn-array AstExprClause))
  (len i64))

(defstruct AstExprBindingClause
  ;; Macro binding names can carry renderable, generated, hygiene, or
  ;; structural syntax identities. Preserve that mixed domain nominally.
  (name ci.InternSyntaxId)
  (has-type bool)
  (ty i64)
  (init i64)
  ;; Produced-type metadata is populated lazily only for transformers that
  ;; call `expr-type`; ordinary syntax-only binding captures keep the untyped
  ;; sentinel and pay no caller typecheck cost.
  (init-produced AstType)
  (span AstSourceSpan))

(defstruct AstExprBindingClauseList
  (slots (__tl_dyn-array AstExprBindingClause))
  (len i64))

(defenum AstMaybeModuleName
  (No)
  (Some i64))

(defenum AstMaybeImportAlias
  (No)
  (Some i64))

(defenum AstImportKind
  (Module)
  ;; File-backed unqualified imports are classified by the loader after it
  ;; establishes the longest loadable dotted module prefix.
  (ModuleAll)
  (ModuleItem i64)
  (Macro i64 AstMaybeModuleName)
  (MacroDecls i64 AstMaybeModuleName))

(defenum AstImportSpec
  (Spec
    AstImportKind
    String
    AstMaybeModuleName
    AstMaybeImportAlias
    (Box AstSourceSpan)))

(defenum AstDispatchIsa
  (Scalar)
  (Avx2)
  (Avx512))

(defenum AstDispatchVariant
  (Variant AstDispatchIsa i64))

(defstruct AstDispatchVariantList
  (slots (__tl_dyn-array AstDispatchVariant))
  (len i64))

(defenum AstGeneratedDeclMeta
  (No)
  (Some String String AstExprList String))

(defenum AstDeclMetaValue
  (Runtime i64)
  (Comptime AstGeneratedDeclMeta i64))

;; Keep the per-declaration metadata field pointer-sized. An inline tagged
;; AstDeclMeta adds both a tag and a payload word to every AstDecl slot, while
;; only compile-time or marked declarations need their own tagged storage.
(defstruct AstDeclMeta
  (value (Box AstDeclMetaValue)))

(define ast-decl-meta-runtime : AstDeclMeta
  (AstDeclMeta (box (AstDeclMetaValue.Runtime 0))))

(define (ast-decl-meta-runtime-shared-view) : AstDeclMeta
  (ast-global-shared-view ast-decl-meta-runtime))

;; Parsing and surface hydration share the same allocation rule: the ordinary
;; unmarked runtime declaration uses the singleton metadata box.
(define (ast-decl-meta-runtime-with-aggregate-markers [markers : i64]) : AstDeclMeta
  (if (= markers 0)
    (ast-decl-meta-runtime-shared-view)
    (AstDeclMeta (box (AstDeclMetaValue.Runtime markers)))))

(defenum AstTestIgnoreReason
  (No)
  (Some String))

(defenum AstTestMetadataValue
  (None)
  (Metadata AstTestIgnoreReason bool))

;; Keep test metadata pointer-sized in `AstDecl`: ordinary declarations share
;; the allocation-free `None` value, while annotated tests own one boxed row.
;; Future execution metadata can extend `AstTestMetadataValue` without growing
;; every declaration slot again.
(defstruct AstTestMetadata
  (value (Box AstTestMetadataValue)))

(define ast-test-metadata-none : AstTestMetadata
  (AstTestMetadata (box AstTestMetadataValue.None)))

(define (ast-test-metadata-none-shared-view) : AstTestMetadata
  (ast-global-shared-view ast-test-metadata-none))

(define (ast-test-metadata-new
  [ignore-reason : AstTestIgnoreReason]
  [slow : bool]) : AstTestMetadata
  (match ignore-reason
    [(AstTestIgnoreReason.No)
      (if slow
        (AstTestMetadata
          (box (AstTestMetadataValue.Metadata AstTestIgnoreReason.No true)))
        (ast-test-metadata-none-shared-view))]
    [(AstTestIgnoreReason.Some reason)
      (AstTestMetadata
        (box
          (AstTestMetadataValue.Metadata (AstTestIgnoreReason.Some reason) slow)))]))

(define (ast-test-metadata-ignore-reason
  [metadata : (& metadata AstTestMetadata)]) : AstTestIgnoreReason
  (match (__tl-box-place metadata.value)
    [(AstTestMetadataValue.None) AstTestIgnoreReason.No]
    [(AstTestMetadataValue.Metadata reason _) reason]))

(define (ast-test-metadata-slow? [metadata : (& metadata AstTestMetadata)]) : bool
  (match (__tl-box-place metadata.value)
    [(AstTestMetadataValue.None) false]
    [(AstTestMetadataValue.Metadata _ slow) slow]))

;; `AstExternMetadata` is larger than the other `AstDecl.Extern` fields
;; combined. Keeping it inline made Extern the layout ceiling for every
;; declaration slot, including the whole-program vectors rebuilt around macro
;; splices. Extern declarations are rare, so box their metadata and keep the
;; common declaration vectors compact.
(defenum AstDecl
  (Module i64)
  (ModuleBody i64 (Box AstDeclList))
  (Def AstDeclMeta i64 AstMaybeType i64)
  (DefFn AstDeclMeta i64 AstParamList AstType i64 AstFnMetadata)
  (DefMacro AstDeclMeta i64 AstMacroParamList AstType i64)
  (Extern AstDeclMeta i64 AstExternKind (Box AstExternMetadata) AstType)
  (DefEnum AstDeclMeta i64 AstEnumCleanup AstVariantDefList)
  (DefEnumLifetimes
    AstDeclMeta
    i64
    AstLifetimeList
    AstEnumCleanup
    AstVariantDefList)
  (DefStruct AstDeclMeta i64 AstStructRepr AstStructCleanup AstFieldDefList)
  (DefStructLifetimes
    AstDeclMeta
    i64
    AstLifetimeList
    AstStructRepr
    AstStructCleanup
    AstFieldDefList)
  (Import AstDeclMeta AstImportSpec)
  (IncludeStr i64 String)
  (IncludeStrComptime i64 String)
  (IncludeStrLzss i64 String)
  (IncludeBin i64 String)
  (DefDispatch AstDeclMeta i64 AstDispatchVariantList)
  (Test i64 i64 AstTestMetadata AstSourceSpan)
  (Unsafe (Box AstDecl)))

(defstruct AstDeclList
  (slots (__tl_dyn-array AstDecl))
  (offset i64)
  (len i64)
  (prependable bool))

(define (ast-decl-list-box-shared-view [value : (Box AstDeclList)]) : AstDeclList
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast address : u64) : (Ptr AstDeclList))))))

(defenum AstDeclListStep
  (Nil)
  (Cons AstDecl AstDeclList))

(defstruct AstDeclPathList
  (slots (__tl_dyn-array String))
  ;; One allocation with two `slots`-capacity lanes: effective owner IDs,
  ;; followed by physical provenance IDs. This preserves the historical list
  ;; value width while keeping provenance attached to every path. Refs #5482.
  (owner-ids (__tl_dyn-array i64))
  (offset i64)
  (len i64)
  (prependable bool))

(defenum AstDeclPathListStep
  (Nil)
  (Cons String AstDeclPathList))

(defstruct AstDeclModuleList
  (slots (__tl_dyn-array i64))
  (offset i64)
  (len i64)
  (prependable bool))

(defenum AstProgram
  (Program (Box AstDeclList)))

(define (ast-type-id-fallback) : i64
  0)

;; Shared zero-length backing store for the empty i64-slot lists below.
;;
;; `(__tl_make-array i64 0)` is not free: it still runs `tl_alloc` and the
;; `tl_array_zero` call the make-array lowering emits for a non-literal length,
;; and the self-compile builds millions of empty lists (`ast-variant-def-fallback`
;; alone builds one type list and one cleanup list per call). A zero-length array
;; can never be indexed and never be written -- `push` only stores after `grow`
;; has replaced `slots` with private storage, because `len < array-length slots`
;; is false at capacity 0 -- so one program-lifetime array is safe to hand to
;; every empty list. Only the `slots` fat pointer is shared; the list struct
;; itself is a per-value copy, so a later `grow` rebinds that copy's field and
;; leaves this array untouched.
;;
;; This global is initialized at startup in the program arena, so it outlives
;; every per-phase arena that can hold a list pointing at it.
(define ast-empty-i64-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 0))

(define (ast-type-list-with-capacity [capacity : i64]) : AstTypeList
  (if (<= capacity 0)
    (AstTypeList (ast-global-shared-view ast-empty-i64-slots) 0)
    (AstTypeList (__tl_make-array i64 capacity) 0)))

(define (ast-type-list-new) : AstTypeList
  (ast-type-list-with-capacity 0))

(define (ast-type-list-len [v : (& v AstTypeList)]) : i64
  v.len)

(define (ast-type-list-empty? [v : (& v AstTypeList)]) : bool
  (= (ast-type-list-len v) 0))

(define (ast-type-list-get
  [v : (& v AstTypeList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-type-list-len v)))
    (array-ref v.slots index)
    fallback))

(define (ast-type-list-copy-range
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (ast-type-list-copy-range dst src (+ index 1) count))))

(define (ast-type-list-grow [v : (&mut v AstTypeList)]) : unit
  (let
    [n : i64 v.len]
    [old-cap : i64 (array-length v.slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
    (begin
      (ast-type-list-copy-range (&mut bigger) (& v.slots) 0 n)
      (set! v.slots bigger))))

(define (ast-type-list-push [v : (&mut v AstTypeList)] [value : i64]) : unit
  (begin
    (if (< v.len (array-length v.slots))
      unit
      (ast-type-list-grow v))
    (let
      [index : i64 v.len]
      (begin
        (set! (array-ref v.slots index) value)
        (set! v.len (+ index 1))))))

(define (ast-type-list-append-from
  [out : (&mut out AstTypeList)]
  [items : (& items AstTypeList)]
  [index : i64]) : unit
  (if (>= index (ast-type-list-len items))
    unit
    (begin
      (ast-type-list-push
        out
        (ast-type-list-get items index (ast-type-id-fallback)))
      (ast-type-list-append-from out items (+ index 1)))))

(define (ast-type-list-slice-into
  [out : (&mut out AstTypeList)]
  [items : (& items AstTypeList)]
  [start : i64]
  [index : i64]) : unit
  (if (>= index (ast-type-list-len items))
    unit
    (begin
      (if (>= index start)
        (ast-type-list-push
          out
          (ast-type-list-get items index (ast-type-id-fallback)))
        unit)
      (ast-type-list-slice-into out items start (+ index 1)))))

(define (ast-type-list-slice [items : (& items AstTypeList)] [start : i64]) : AstTypeList
  (let
    [len : i64 (ast-type-list-len items)]
    [out : AstTypeList
      (ast-type-list-with-capacity
        (if (< start len)
          (- len start)
          0))]
    (begin
      (ast-type-list-slice-into (&mut out) items start 0)
      out)))

(define (ast-type-list-cons-id [head : i64] [rest : AstTypeList]) : AstTypeList
  (let
    [out : AstTypeList
      (ast-type-list-with-capacity (+ 1 (ast-type-list-len (& rest))))]
    (begin
      (ast-type-list-push (&mut out) head)
      (ast-type-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-type-cons [head : AstType] [rest : AstTypeList]) : AstTypeList
  (ast-type-list-cons-id (ast-node-pool-reader-type-push head) rest))

(define (ast-ty-func [args : AstTypeList] [ret : AstType]) : AstType
  (AstType.Func (box args) (ast-node-pool-reader-type-push ret)))

;; Legacy/test adapter. Compile-job callers use the explicit-pools twin below.
(define (ast-ty-tuple [elems : AstTypeList]) : AstType
  (AstType.Tuple (box elems)))

(define (ast-ty-enum-args [name : i64] [lifetimes : AstLifetimeList]) : AstType
  (AstType.EnumArgs name (box lifetimes)))

(define (ast-ty-struct-args [name : i64] [lifetimes : AstLifetimeList]) : AstType
  (AstType.StructArgs name (box lifetimes)))

(define (ast-ty-var-args [name : i64] [lifetimes : AstLifetimeList]) : AstType
  (AstType.VarArgs name (box lifetimes)))

(define (ast-ty-array [elem : AstType] [count : i64]) : AstType
  (AstType.Array (ast-node-pool-reader-type-push elem) count))

(define (ast-ty-dyn-array [elem : AstType]) : AstType
  (AstType.DynArray (ast-node-pool-reader-type-push elem)))

(define (ast-ty-slice [elem : AstType]) : AstType
  (AstType.Slice (ast-node-pool-reader-type-push elem)))

(define (ast-ty-box [elem : AstType]) : AstType
  (AstType.Box (ast-node-pool-reader-type-push elem)))

(define (ast-ty-region [region : i64] [inner : AstType]) : AstType
  (AstType.Region region (ast-node-pool-reader-type-push inner)))

(define (ast-ty-ref [region : i64] [inner : AstType]) : AstType
  (AstType.Ref region (ast-node-pool-reader-type-push inner)))

;; How many `(:invalidate r T)` nodes this process has built or decoded (#6670).
;; Every such node starts at one of the constructors below; the rest are copies.
;; While it is zero no type carries the effect, so checkers skip its work.
(define ast-invalidate-type-count : i64
  0)

(define (ast-ty-invalidate-id [lifetime : i64] [inner : i64]) : AstType
  (begin
    (set! ast-invalidate-type-count (+ ast-invalidate-type-count 1))
    (AstType.Invalidate lifetime inner)))

(define (ast-ty-invalidate [lifetime : i64] [inner : AstType]) : AstType
  (ast-ty-invalidate-id lifetime (ast-node-pool-reader-type-push inner)))

(define (ast-ty-mut-ref [region : i64] [inner : AstType]) : AstType
  (AstType.MutRef region (ast-node-pool-reader-type-push inner)))

(define (ast-ty-ptr [elem : AstType]) : AstType
  (AstType.Ptr (ast-node-pool-reader-type-push elem)))

(define (ast-ty-mut-ptr [elem : AstType]) : AstType
  (AstType.MutPtr (ast-node-pool-reader-type-push elem)))

(define (ast-type-cons-with-pools
  [pools : AstNodePoolContext]
  [head : AstType]
  [rest : AstTypeList]) : AstTypeList
  (ast-type-list-cons-id (ast-node-pool-context-type-push pools head) rest))

(define (ast-ty-func-with-pools
  [pools : AstNodePoolContext]
  [args : AstTypeList]
  [ret : AstType]) : AstType
  (AstType.Func (box args) (ast-node-pool-context-type-push pools ret)))

(define (ast-ty-array-with-pools
  [pools : AstNodePoolContext]
  [elem : AstType]
  [count : i64]) : AstType
  (AstType.Array (ast-node-pool-context-type-push pools elem) count))

(define (ast-ty-dyn-array-with-pools
  [pools : AstNodePoolContext]
  [elem : AstType]) : AstType
  (AstType.DynArray (ast-node-pool-context-type-push pools elem)))

(define (ast-ty-slice-with-pools [pools : AstNodePoolContext] [elem : AstType]) : AstType
  (AstType.Slice (ast-node-pool-context-type-push pools elem)))

(define (ast-ty-box-with-pools [pools : AstNodePoolContext] [elem : AstType]) : AstType
  (AstType.Box (ast-node-pool-context-type-push pools elem)))

(define (ast-ty-region-with-pools
  [pools : AstNodePoolContext]
  [region : i64]
  [inner : AstType]) : AstType
  (AstType.Region region (ast-node-pool-context-type-push pools inner)))

(define (ast-ty-ref-with-pools
  [pools : AstNodePoolContext]
  [region : i64]
  [inner : AstType]) : AstType
  (AstType.Ref region (ast-node-pool-context-type-push pools inner)))

(define (ast-ty-invalidate-with-pools
  [pools : AstNodePoolContext]
  [lifetime : i64]
  [inner : AstType]) : AstType
  (ast-ty-invalidate-id lifetime (ast-node-pool-context-type-push pools inner)))

(define (ast-ty-mut-ref-with-pools
  [pools : AstNodePoolContext]
  [region : i64]
  [inner : AstType]) : AstType
  (AstType.MutRef region (ast-node-pool-context-type-push pools inner)))

(define (ast-ty-ptr-with-pools [pools : AstNodePoolContext] [elem : AstType]) : AstType
  (AstType.Ptr (ast-node-pool-context-type-push pools elem)))

(define (ast-ty-mut-ptr-with-pools
  [pools : AstNodePoolContext]
  [elem : AstType]) : AstType
  (AstType.MutPtr (ast-node-pool-context-type-push pools elem)))

(define (ast-lifetime-fallback) : i64
  cbi.compiler-builtin-id-fix-empty)

(define (ast-lifetime-list-with-capacity [capacity : i64]) : AstLifetimeList
  (if (<= capacity 0)
    (AstLifetimeList (ast-global-shared-view ast-empty-i64-slots) 0)
    (AstLifetimeList (__tl_make-array i64 capacity) 0)))

(define (ast-lifetime-list-new) : AstLifetimeList
  (ast-lifetime-list-with-capacity 0))

(define (ast-lifetime-list-len [v : (& v AstLifetimeList)]) : i64
  v.len)

(define (ast-lifetime-list-empty? [v : (& v AstLifetimeList)]) : bool
  (= (ast-lifetime-list-len v) 0))

(define (ast-lifetime-list-get
  [v : (& v AstLifetimeList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-lifetime-list-len v)))
    (array-ref v.slots index)
    fallback))

(define (ast-lifetime-list-copy-range
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (ast-lifetime-list-copy-range dst src (+ index 1) count))))

(define (ast-lifetime-list-grow [v : (&mut v AstLifetimeList)]) : unit
  (let
    [n : i64 v.len]
    [old-cap : i64 (array-length v.slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
    (begin
      (ast-lifetime-list-copy-range (&mut bigger) (& v.slots) 0 n)
      (set! v.slots bigger))))

(define (ast-lifetime-list-push [v : (&mut v AstLifetimeList)] [value : i64]) : unit
  (begin
    (if (< v.len (array-length v.slots))
      unit
      (ast-lifetime-list-grow v))
    (let
      [index : i64 v.len]
      (begin
        (set! (array-ref v.slots index) value)
        (set! v.len (+ index 1))))))

(define (ast-lifetime-list-append-from
  [out : (&mut out AstLifetimeList)]
  [items : (& items AstLifetimeList)]
  [index : i64]) : unit
  (if (>= index (ast-lifetime-list-len items))
    unit
    (begin
      (ast-lifetime-list-push
        out
        (ast-lifetime-list-get items index (ast-lifetime-fallback)))
      (ast-lifetime-list-append-from out items (+ index 1)))))

(define (ast-lifetime-cons [head : i64] [rest : AstLifetimeList]) : AstLifetimeList
  (let
    [out : AstLifetimeList
      (ast-lifetime-list-with-capacity (+ 1 (ast-lifetime-list-len (& rest))))]
    (begin
      (ast-lifetime-list-push (&mut out) head)
      (ast-lifetime-list-append-from (&mut out) (& rest) 0)
      out)))

;; How many comptime parameters this process has built (#8578). Every one
;; starts at `ast-comptime-param-id`; the rest are copies. While it is zero no
;; call can pass a comptime argument, so the checker skips that work.
(define ast-comptime-param-count : i64
  0)

(define (ast-param-id [name : i64] [ty : AstType] [is-comptime : bool]) : AstParam
  (AstParam.Param name ty is-comptime))

(define (ast-comptime-param-id [name : i64] [ty : AstType]) : AstParam
  (begin
    (set! ast-comptime-param-count (+ ast-comptime-param-count 1))
    (AstParam.Param name ty true)))

(define (ast-param-fallback) : AstParam
  (AstParam.Param 0 (AstType.Unit) false))

(dense_list.compiler-dense-list-operations
  AstParam
  AstParamList
  ast-param-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage
  len
  append-from)

(define (ast-param-cons [head : AstParam] [rest : AstParamList]) : AstParamList
  (let
    [out : AstParamList
      (ast-param-list-with-capacity (+ 1 (ast-param-list-len (& rest))))]
    (begin
      (ast-param-list-push (&mut out) head)
      (ast-param-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-macro-type-kind-list-empty) : AstMacroTypeKindList
  (AstMacroTypeKindList (__tl_make-array i64 0) 0))

(define (ast-macro-type-kind-list-with-length [len : i64]) : AstMacroTypeKindList
  (let
    [count : i64
      (if (< len 0)
        0
        len)]
    (AstMacroTypeKindList (__tl_make-array i64 count) count)))

(define (ast-macro-type-kind-list-len [kinds : (& kinds AstMacroTypeKindList)]) : i64
  kinds.len)

(define (ast-macro-type-kind-list-empty?
  [kinds : (& kinds AstMacroTypeKindList)]) : bool
  (= (ast-macro-type-kind-list-len kinds) 0))

(define (ast-macro-type-kind-list-get
  [kinds : (& kinds AstMacroTypeKindList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-macro-type-kind-list-len kinds)))
    (array-ref kinds.slots index)
    fallback))

(define (ast-macro-type-kind-list-set!
  [kinds : (&mut kinds AstMacroTypeKindList)]
  [index : i64]
  [kind : i64]) : unit
  (let
    [count : i64 kinds.len]
    (if (and (>= index 0) (< index count))
      (set! (array-ref kinds.slots index) kind)
      unit)))

(define (ast-macro-type-kind-list-eq-at?
  [a : (& a AstMacroTypeKindList)]
  [b : (& b AstMacroTypeKindList)]
  [index : i64]) : bool
  (if (not
    (= (ast-macro-type-kind-list-len a) (ast-macro-type-kind-list-len b)))
    false
    (if (>= index (ast-macro-type-kind-list-len a))
      true
      (and
        (=
          (ast-macro-type-kind-list-get a index 0)
          (ast-macro-type-kind-list-get b index 0))
        (ast-macro-type-kind-list-eq-at? a b (+ index 1))))))

(define (ast-macro-type-kind-list-eq?
  [a : (& a AstMacroTypeKindList)]
  [b : (& b AstMacroTypeKindList)]) : bool
  (ast-macro-type-kind-list-eq-at? a b 0))

(define (ast-macro-type-kind-list-copy-from
  [source : (& source AstMacroTypeKindList)]
  [out : (&mut out AstMacroTypeKindList)]
  [index : i64]) : unit
  (if (>= index (ast-macro-type-kind-list-len source))
    unit
    (begin
      (ast-macro-type-kind-list-set!
        out
        index
        (ast-macro-type-kind-list-get source index 0))
      (ast-macro-type-kind-list-copy-from source out (+ index 1)))))

(define (ast-macro-type-kind-list-copy
  [source : (& source AstMacroTypeKindList)]) : AstMacroTypeKindList
  (let
    [out : AstMacroTypeKindList
      (ast-macro-type-kind-list-with-length
        (ast-macro-type-kind-list-len source))]
    (begin
      (ast-macro-type-kind-list-copy-from source (&mut out) 0)
      out)))

(define (ast-macro-param-with-type-kinds
  [name : i64]
  [ty : AstType]
  [variadic : bool]
  [type-kinds : AstMacroTypeKindList]) : AstMacroParam
  (AstMacroParam.Param name ty variadic type-kinds))

(define (ast-macro-param [name : i64] [ty : AstType] [variadic : bool]) : AstMacroParam
  (ast-macro-param-with-type-kinds
    name
    ty
    variadic
    (ast-macro-type-kind-list-empty)))

(define (ast-macro-param-fallback) : AstMacroParam
  (AstMacroParam.Param 0 (AstType.Unit) false (ast-macro-type-kind-list-empty)))

(dense_list.compiler-dense-list-operations
  AstMacroParam
  AstMacroParamList
  ast-macro-param-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage
  len)

(define (ast-field-cleanup-fn-id [name : ci.InternSyntaxId]) : AstFieldCleanup
  (AstFieldCleanup.Fn name))

(define (ast-field-def-id
  [name : ci.InternSyntaxId]
  [ty : AstType]
  [cleanup : AstFieldCleanup]) : AstFieldDef
  (AstFieldDef.Def name ty cleanup))

(define (ast-field-def-fallback) : AstFieldDef
  (AstFieldDef.Def
    (ci.intern-syntax-id-from-raw 0)
    (AstType.Unit)
    AstFieldCleanup.No))

(dense_list.compiler-dense-list-operations
  AstFieldDef
  AstFieldDefList
  ast-field-def-list
  caller-provided-fallback
  minimum-one
  compiler-dense-list-unused-shared-zero-storage
  len
  empty?
  append-from)

(define (ast-field-def-cons [head : AstFieldDef] [rest : AstFieldDefList]) : AstFieldDefList
  (let
    [out : AstFieldDefList (ast-field-def-list-with-capacity (+ 1 rest.len))]
    (begin
      (ast-field-def-list-push (&mut out) head)
      (ast-field-def-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-extern-link-input-fallback) : AstExternLinkInput
  (AstExternLinkInput.Arg ""))

(dense_list.compiler-dense-list-operations
  AstExternLinkInput
  AstExternLinkInputList
  ast-extern-link-input-list
  caller-provided-fallback
  minimum-one
  compiler-dense-list-unused-shared-zero-storage
  len)

(define (ast-fn-export-id [name : ci.InternId]) : AstFnExport
  (AstFnExport.Export name))

(define (ast-spmd-param-class-list-with-capacity [capacity : i64]) : AstSpmdParamClassList
  (AstSpmdParamClassList
    (__tl_make-array
      AstSpmdParamClass
      (if (< capacity 1)
        1
        capacity))
    0))

(define (ast-spmd-param-class-list-new) : AstSpmdParamClassList
  (ast-spmd-param-class-list-with-capacity 4))

(define (ast-spmd-param-class-list-len
  [items : (& items AstSpmdParamClassList)]) : i64
  items.len)

(define (ast-spmd-param-class-list-get
  [items : (& items AstSpmdParamClassList)]
  [index : i64]
  [fallback : AstSpmdParamClass]) : AstSpmdParamClass
  (if (and (>= index 0) (< index items.len))
    (array-ref items.slots index)
    fallback))

(define (ast-spmd-param-class-list-copy-range
  [dst : (&mut dst (__tl_dyn-array AstSpmdParamClass))]
  [src : (& src (__tl_dyn-array AstSpmdParamClass))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (ast-spmd-param-class-list-copy-range dst src (+ index 1) count))))

(define (ast-spmd-param-class-list-grow
  [items : (&mut items AstSpmdParamClassList)]) : unit
  (let
    [len : i64 items.len]
    [old-cap : i64 (array-length items.slots)]
    [next : (__tl_dyn-array AstSpmdParamClass)
      (__tl_make-array
        AstSpmdParamClass
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (ast-spmd-param-class-list-copy-range (&mut next) (& items.slots) 0 len)
      (set! items.slots next))))

(define (ast-spmd-param-class-list-push
  [items : (&mut items AstSpmdParamClassList)]
  [value : AstSpmdParamClass]) : unit
  (begin
    (if (< items.len (array-length items.slots))
      unit
      (ast-spmd-param-class-list-grow items))
    (let
      [index : i64 items.len]
      (begin
        (set! (array-ref items.slots index) value)
        (set! items.len (+ index 1))))))

(define (ast-spmd-specialization-list-with-capacity [capacity : i64]) : AstSpmdSpecializationList
  (AstSpmdSpecializationList
    (__tl_make-array
      AstSpmdSpecialization
      (if (< capacity 1)
        1
        capacity))
    0))

(define (ast-spmd-specialization-list-new) : AstSpmdSpecializationList
  (ast-spmd-specialization-list-with-capacity 2))

(define (ast-spmd-specialization-list-len
  [items : (& items AstSpmdSpecializationList)]) : i64
  items.len)

(define (ast-spmd-specialization-list-get
  [items : (& items AstSpmdSpecializationList)]
  [index : i64]
  [fallback : AstSpmdSpecialization]) : AstSpmdSpecialization
  (if (and (>= index 0) (< index items.len))
    (array-ref items.slots index)
    fallback))

(define (ast-spmd-specialization-list-copy-range
  [dst : (&mut dst (__tl_dyn-array AstSpmdSpecialization))]
  [src : (& src (__tl_dyn-array AstSpmdSpecialization))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (ast-spmd-specialization-list-copy-range dst src (+ index 1) count))))

(define (ast-spmd-specialization-list-grow
  [items : (&mut items AstSpmdSpecializationList)]) : unit
  (let
    [len : i64 items.len]
    [old-cap : i64 (array-length items.slots)]
    [next : (__tl_dyn-array AstSpmdSpecialization)
      (__tl_make-array
        AstSpmdSpecialization
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (ast-spmd-specialization-list-copy-range
        (&mut next)
        (& items.slots)
        0
        len)
      (set! items.slots next))))

(define (ast-spmd-specialization-list-push
  [items : (&mut items AstSpmdSpecializationList)]
  [value : AstSpmdSpecialization]) : unit
  (begin
    (if (< items.len (array-length items.slots))
      unit
      (ast-spmd-specialization-list-grow items))
    (let
      [index : i64 items.len]
      (begin
        (set! (array-ref items.slots index) value)
        (set! items.len (+ index 1))))))

(define (ast-spmd-param-class-list-clone
  [items : (& items AstSpmdParamClassList)]) : AstSpmdParamClassList
  (let
    [count : i64 (ast-spmd-param-class-list-len items)]
    [out : AstSpmdParamClassList
      (ast-spmd-param-class-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast-spmd-param-class-list-push
            (&mut out)
            (ast-spmd-param-class-list-get
              items
              index
              AstSpmdParamClass.Uniform))
          (set! index (+ index 1))))
      out)))

(define (ast-spmd-specialization-clone [item : AstSpmdSpecialization]) : AstSpmdSpecialization
  (AstSpmdSpecialization
    item.lanes
    (box (ast-spmd-param-class-list-clone (& (deref item.args))))
    item.result
    item.index-param))

(define (ast-spmd-specialization-fallback) : AstSpmdSpecialization
  (AstSpmdSpecialization
    2
    (box (ast-spmd-param-class-list-new))
    AstSpmdResultClass.Unit
    -1))

(define (ast-spmd-specialization-list-clone
  [items : (& items AstSpmdSpecializationList)]) : AstSpmdSpecializationList
  (let
    [count : i64 (ast-spmd-specialization-list-len items)]
    [out : AstSpmdSpecializationList
      (ast-spmd-specialization-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast-spmd-specialization-list-push
            (&mut out)
            (ast-spmd-specialization-clone
              (ast-spmd-specialization-list-get
                items
                index
                (ast-spmd-specialization-fallback))))
          (set! index (+ index 1))))
      out)))

(define (ast-renderable-name-id-fallback) : ci.InternId
  (ci.intern-id-from-renderable 0))

(define (ast-imported-spmd-specialization-fallback) : AstImportedSpmdSpecialization
  (let
    [fallback : ci.InternId (ast-renderable-name-id-fallback)]
    (AstImportedSpmdSpecialization
      fallback
      fallback
      0
      fallback
      fallback
      -1
      fallback)))

(define (ast-imported-spmd-specialization-list-with-capacity [capacity : i64]) : AstImportedSpmdSpecializationList
  (AstImportedSpmdSpecializationList
    (__tl_make-array
      AstImportedSpmdSpecialization
      (if (< capacity 1)
        1
        capacity))
    0))

(define (ast-imported-spmd-specialization-list-new) : AstImportedSpmdSpecializationList
  (ast-imported-spmd-specialization-list-with-capacity 2))

(define (ast-imported-spmd-specialization-list-len
  [items : (& items AstImportedSpmdSpecializationList)]) : i64
  items.len)

(define (ast-imported-spmd-specialization-list-get
  [items : (& items AstImportedSpmdSpecializationList)]
  [index : i64]
  [fallback : AstImportedSpmdSpecialization]) : AstImportedSpmdSpecialization
  (if (and (>= index 0) (< index items.len))
    (array-ref items.slots index)
    fallback))

(define (ast-imported-spmd-specialization-list-copy-range
  [dst : (&mut dst (__tl_dyn-array AstImportedSpmdSpecialization))]
  [src : (& src (__tl_dyn-array AstImportedSpmdSpecialization))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (ast-imported-spmd-specialization-list-copy-range
        dst
        src
        (+ index 1)
        count))))

(define (ast-imported-spmd-specialization-list-grow
  [items : (&mut items AstImportedSpmdSpecializationList)]) : unit
  (let
    [len : i64 items.len]
    [old-cap : i64 (array-length items.slots)]
    [next : (__tl_dyn-array AstImportedSpmdSpecialization)
      (__tl_make-array
        AstImportedSpmdSpecialization
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (ast-imported-spmd-specialization-list-copy-range
        (&mut next)
        (& items.slots)
        0
        len)
      (set! items.slots next))))

(define (ast-imported-spmd-specialization-list-push
  [items : (&mut items AstImportedSpmdSpecializationList)]
  [value : AstImportedSpmdSpecialization]) : unit
  (begin
    (if (< items.len (array-length items.slots))
      unit
      (ast-imported-spmd-specialization-list-grow items))
    (let
      [index : i64 items.len]
      (begin
        (set! (array-ref items.slots index) value)
        (set! items.len (+ index 1))))))

(define (ast-imported-spmd-callable-fallback) : AstImportedSpmdCallable
  (AstImportedSpmdCallable
    (ast-renderable-name-id-fallback)
    (ast-imported-spmd-specialization-list-new)))

(define (ast-imported-spmd-callable-list-with-capacity [capacity : i64]) : AstImportedSpmdCallableList
  (AstImportedSpmdCallableList
    (__tl_make-array
      AstImportedSpmdCallable
      (if (< capacity 1)
        1
        capacity))
    0))

(define (ast-imported-spmd-callable-list-new) : AstImportedSpmdCallableList
  (ast-imported-spmd-callable-list-with-capacity 1))

(define (ast-imported-spmd-callable-list-len
  [items : (& items AstImportedSpmdCallableList)]) : i64
  items.len)

(define (ast-imported-spmd-callable-list-get
  [items : (& items AstImportedSpmdCallableList)]
  [index : i64]
  [fallback : AstImportedSpmdCallable]) : AstImportedSpmdCallable
  (if (and (>= index 0) (< index items.len))
    (array-ref items.slots index)
    fallback))

(define (ast-imported-spmd-callable-list-copy-range
  [dst : (&mut dst (__tl_dyn-array AstImportedSpmdCallable))]
  [src : (& src (__tl_dyn-array AstImportedSpmdCallable))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (ast-imported-spmd-callable-list-copy-range dst src (+ index 1) count))))

(define (ast-imported-spmd-callable-list-grow
  [items : (&mut items AstImportedSpmdCallableList)]) : unit
  (let
    [len : i64 items.len]
    [old-cap : i64 (array-length items.slots)]
    [next : (__tl_dyn-array AstImportedSpmdCallable)
      (__tl_make-array
        AstImportedSpmdCallable
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (ast-imported-spmd-callable-list-copy-range
        (&mut next)
        (& items.slots)
        0
        len)
      (set! items.slots next))))

(define (ast-imported-spmd-callable-list-push
  [items : (&mut items AstImportedSpmdCallableList)]
  [value : AstImportedSpmdCallable]) : unit
  (begin
    (if (< items.len (array-length items.slots))
      unit
      (ast-imported-spmd-callable-list-grow items))
    (let
      [index : i64 items.len]
      (begin
        (set! (array-ref items.slots index) value)
        (set! items.len (+ index 1))))))

(define (ast-imported-spmd-specialization-list-clone
  [items : (& items AstImportedSpmdSpecializationList)]) : AstImportedSpmdSpecializationList
  (let
    [count : i64 (ast-imported-spmd-specialization-list-len items)]
    [out : AstImportedSpmdSpecializationList
      (ast-imported-spmd-specialization-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast-imported-spmd-specialization-list-push
            (&mut out)
            (ast-imported-spmd-specialization-list-get
              items
              index
              (ast-imported-spmd-specialization-fallback)))
          (set! index (+ index 1))))
      out)))

(define (ast-imported-spmd-callable-list-clone
  [items : (& items AstImportedSpmdCallableList)]) : AstImportedSpmdCallableList
  (let
    [count : i64 (ast-imported-spmd-callable-list-len items)]
    [out : AstImportedSpmdCallableList
      (ast-imported-spmd-callable-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [item : AstImportedSpmdCallable
            (ast-imported-spmd-callable-list-get
              items
              index
              (ast-imported-spmd-callable-fallback))]
          (begin
            (ast-imported-spmd-callable-list-push
              (&mut out)
              (AstImportedSpmdCallable
                item.signature
                (ast-imported-spmd-specialization-list-clone
                  (& item.specializations))))
            (set! index (+ index 1)))))
      out)))

(define (ast-imported-spmd-metadata-clone [metadata : AstImportedSpmdMetadata]) : AstImportedSpmdMetadata
  (match metadata
    [(AstImportedSpmdMetadata.No) AstImportedSpmdMetadata.No]
    [(AstImportedSpmdMetadata.Package owner version name callables)
      (AstImportedSpmdMetadata.Package
        (string.copy owner)
        (string.copy version)
        name
        (box (ast-imported-spmd-callable-list-clone (& (deref callables)))))]))

(define (ast-fn-metadata-clone [metadata : AstFnMetadata]) : AstFnMetadata
  (match metadata
    [(AstFnMetadata.No) AstFnMetadata.No]
    [(AstFnMetadata.Export symbol) (AstFnMetadata.Export symbol)]
    [(AstFnMetadata.SpmdCallable items)
      (AstFnMetadata.SpmdCallable
        (box (ast-spmd-specialization-list-clone (& (deref items)))))]))

(define (ast-fn-metadata [export : AstFnExport]) : AstFnMetadata
  (match export
    [(AstFnExport.No) AstFnMetadata.No]
    [(AstFnExport.Export symbol) (AstFnMetadata.Export symbol)]))

(define (ast-fn-metadata-full
  [export : AstFnExport]
  [spmd-callable : AstSpmdCallable]) : AstFnMetadata
  (match spmd-callable
    [(AstSpmdCallable.No) (ast-fn-metadata export)]
    [(AstSpmdCallable.Callable items) (AstFnMetadata.SpmdCallable (box items))]))

(define (ast-fn-metadata-export [metadata : AstFnMetadata]) : AstFnExport
  (match metadata
    [(AstFnMetadata.Export symbol) (AstFnExport.Export symbol)]
    [_ AstFnExport.No]))

(define (ast-fn-metadata-spmd-callable [metadata : AstFnMetadata]) : AstSpmdCallable
  (match metadata
    [(AstFnMetadata.SpmdCallable items)
      (AstSpmdCallable.Callable
        (ast-spmd-specialization-list-clone (& (deref items))))]
    [_ AstSpmdCallable.No]))

(define (ast-struct-cleanup-fn-id [name : ci.InternSyntaxId]) : AstStructCleanup
  (AstStructCleanup.Fn name))

(define (ast-enum-cleanup-fn-id [name : ci.InternSyntaxId]) : AstEnumCleanup
  (AstEnumCleanup.Fn name))

(define (ast-variant-payload-cleanup-fn-id [name : ci.InternSyntaxId]) : AstVariantPayloadCleanup
  (AstVariantPayloadCleanup.Fn name))

(define (ast-variant-payload-cleanup-fallback) : AstVariantPayloadCleanup
  AstVariantPayloadCleanup.No)

(dense_list.compiler-dense-list-operations
  AstVariantPayloadCleanup
  AstVariantPayloadCleanupList
  ast-variant-payload-cleanup-list
  caller-provided-fallback
  shared-zero-capacity
  ast-empty-variant-payload-cleanup-slots
  len
  append-from)

(define (ast-variant-def-id
  [name : i64]
  [fields : AstTypeList]
  [cleanups : AstVariantPayloadCleanupList]) : AstVariantDef
  (AstVariantDef.Def name fields cleanups))

;; One shared fallback value instead of one per call.
;;
;; Every one of this function's call sites is the default argument of a
;; bounds-checked `ast-variant-def-list-get`, so the value is built eagerly on
;; every lookup and discarded on every hit, each construction allocating two
;; list structs plus the enum. Sharing is safe
;; for the same reason the hit path is: `ast-variant-def-list-get` hands back a
;; value callers only destructure and read (a caller that mutated it would
;; already be writing into the stored element on the hit path), and both payload
;; lists are empty with the shared zero-length backing, so even a `push` on a
;; copy grows into private storage before it stores anything.
;;
;; Declared after `ast-empty-i64-slots` and
;; `ast-empty-variant-payload-cleanup-slots`, which its initializer reads.
(define ast-variant-def-fallback-value : AstVariantDef
  (AstVariantDef.Def
    0
    (ast-type-list-new)
    (ast-variant-payload-cleanup-list-new)))

(define (ast-variant-def-fallback) : AstVariantDef
  (ast-global-shared-view ast-variant-def-fallback-value))

(dense_list.compiler-dense-list-operations
  AstVariantDef
  AstVariantDefList
  ast-variant-def-list
  caller-provided-fallback
  minimum-one
  compiler-dense-list-unused-shared-zero-storage
  len
  empty?
  append-from)

(define (ast-variant-def-cons [head : AstVariantDef] [rest : AstVariantDefList]) : AstVariantDefList
  (let
    [out : AstVariantDefList
      (ast-variant-def-list-with-capacity (+ 1 rest.len))]
    (begin
      (ast-variant-def-list-push (&mut out) head)
      (ast-variant-def-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-variant-payload-cleanup-cons
  [head : AstVariantPayloadCleanup]
  [rest : AstVariantPayloadCleanupList]) : AstVariantPayloadCleanupList
  (let
    [out : AstVariantPayloadCleanupList
      (ast-variant-payload-cleanup-list-with-capacity (+ 1 rest.len))]
    (begin
      (ast-variant-payload-cleanup-list-push (&mut out) head)
      (ast-variant-payload-cleanup-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-pattern-fallback) : AstPattern
  AstPattern.Wildcard)

(dense_list.compiler-dense-list-operations
  AstPattern
  AstPatternList
  ast-pattern-list
  caller-provided-fallback
  minimum-one
  compiler-dense-list-unused-shared-zero-storage
  len
  empty?
  append-from)

(define (ast-pattern-list-tail [items : AstPatternList]) : AstPatternList
  (let
    [out : AstPatternList (ast-pattern-list-with-capacity (- items.len 1))]
    (begin
      (ast-pattern-list-append-from (&mut out) (& items) 1)
      out)))

(define (ast-pattern-cons [head : AstPattern] [rest : AstPatternList]) : AstPatternList
  (let
    [out : AstPatternList (ast-pattern-list-with-capacity (+ 1 rest.len))]
    (begin
      (ast-pattern-list-push (&mut out) head)
      (ast-pattern-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-pat-binding-id [name : i64]) : AstPattern
  (AstPattern.Binding name))

(define (ast-pat-tuple [items : AstPatternList]) : AstPattern
  (AstPattern.Tuple (box items)))

(define (ast-pat-array [items : AstPatternList]) : AstPattern
  (AstPattern.Array (box items)))

(define (ast-pat-slice [items : AstPatternList] [has-rest : bool]) : AstPattern
  (AstPattern.Slice (box items) has-rest))

(define (ast-pat-variant-id [name : i64] [items : AstPatternList]) : AstPattern
  (AstPattern.Variant name (box items)))

(define (ast-let-binding-id
  [name : i64]
  [maybe-ty : AstMaybeType]
  [value : i64]) : AstLetBinding
  (AstLetBinding.Binding name maybe-ty value))

(define (ast-let-binding-fallback) : AstLetBinding
  (AstLetBinding.Binding 0 (AstMaybeType.No) 0))

(dense_list.compiler-dense-list-operations
  AstLetBinding
  AstLetBindingList
  ast-let-binding-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage
  len
  append-from)

(define (ast-let-binding-cons [head : AstLetBinding] [rest : AstLetBindingList]) : AstLetBindingList
  (let
    [out : AstLetBindingList
      (ast-let-binding-list-with-capacity
        (+ 1 (ast-let-binding-list-len (& rest))))]
    (begin
      (ast-let-binding-list-push (&mut out) head)
      (ast-let-binding-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-resource-binding-id [name : i64] [init : i64] [cleanup : i64]) : AstResourceBinding
  (AstResourceBinding.Binding name init cleanup false))

(define (ast-resource-binding-fallback) : AstResourceBinding
  (AstResourceBinding.Binding 0 0 0 false))

(dense_list.compiler-dense-list-operations
  AstResourceBinding
  AstResourceBindingList
  ast-resource-binding-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage
  len
  append-from)

(define (ast-resource-binding-cons
  [head : AstResourceBinding]
  [rest : AstResourceBindingList]) : AstResourceBindingList
  (let
    [out : AstResourceBindingList
      (ast-resource-binding-list-with-capacity
        (+ 1 (ast-resource-binding-list-len (& rest))))]
    (begin
      (ast-resource-binding-list-push (&mut out) head)
      (ast-resource-binding-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-match-arm [pattern : AstPattern] [body : i64]) : AstMatchArm
  (AstMatchArm.Arm pattern body))

(define (ast-match-arm-fallback) : AstMatchArm
  (AstMatchArm.Arm AstPattern.Wildcard 0))

(dense_list.compiler-dense-list-operations
  AstMatchArm
  AstMatchArmList
  ast-match-arm-list
  caller-provided-fallback
  minimum-one
  compiler-dense-list-unused-shared-zero-storage
  len
  empty?
  append-from)

(define (ast-match-arm-list-tail [items : AstMatchArmList]) : AstMatchArmList
  (let
    [out : AstMatchArmList (ast-match-arm-list-with-capacity (- items.len 1))]
    (begin
      (ast-match-arm-list-append-from (&mut out) (& items) 1)
      out)))

(define (ast-match-arm-cons [head : AstMatchArm] [rest : AstMatchArmList]) : AstMatchArmList
  (let
    [out : AstMatchArmList (ast-match-arm-list-with-capacity (+ 1 rest.len))]
    (begin
      (ast-match-arm-list-push (&mut out) head)
      (ast-match-arm-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-expr-list-with-capacity [capacity : i64]) : AstExprList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstExprList (__tl_make-array i64 cap) 0)))

(define (ast-expr-list-new) : AstExprList
  (ast-expr-list-with-capacity 4))

(define (ast-expr-list-len [v : (& v AstExprList)]) : i64
  v.len)

(define (ast-expr-list-empty? [v : (& v AstExprList)]) : bool
  (= v.len 0))

(define (ast-expr-list-get
  [v : (& v AstExprList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index v.len))
    (array-ref v.slots index)
    fallback))

(define (ast-expr-list-copy-range
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (ast-expr-list-copy-range dst src (+ index 1) count))))

(define (ast-expr-list-grow [v : (&mut v AstExprList)]) : unit
  (let
    [n : i64 v.len]
    [old-cap : i64 (array-length v.slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
    (begin
      (ast-expr-list-copy-range (&mut bigger) (& v.slots) 0 n)
      (set! v.slots bigger))))

(define (ast-expr-list-push [v : (&mut v AstExprList)] [value : i64]) : unit
  (begin
    (if (< v.len (array-length v.slots))
      unit
      (ast-expr-list-grow v))
    (let
      [index : i64 v.len]
      (begin
        (set! (array-ref v.slots index) value)
        (set! v.len (+ index 1))))))

(define (ast-expr-list-append-from
  [out : (&mut out AstExprList)]
  [items : (& items AstExprList)]
  [index : i64]) : unit
  (if (>= index items.len)
    unit
    (begin
      (ast-expr-list-push out (ast-expr-list-get items index 0))
      (ast-expr-list-append-from out items (+ index 1)))))

(define (ast-expr-list-tail [items : AstExprList]) : AstExprList
  (let
    [out : AstExprList (ast-expr-list-with-capacity (- items.len 1))]
    (begin
      (ast-expr-list-append-from (&mut out) (& items) 1)
      out)))

(define (ast-expr-list-tail-from-ref
  [items : (& items AstExprList)]
  [index : i64]) : AstExprList
  (let
    [out : AstExprList (ast-expr-list-with-capacity (- items.len index))]
    (begin
      (ast-expr-list-append-from (&mut out) items index)
      out)))

(define (ast-expr-cons [head : i64] [rest : AstExprList]) : AstExprList
  (let
    [out : AstExprList (ast-expr-list-with-capacity (+ 1 rest.len))]
    (begin
      (ast-expr-list-push (&mut out) head)
      (ast-expr-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-expr-clause [first : i64] [second : i64]) : AstExprClause
  (AstExprClause first second))

(define (ast-expr-clause-fallback) : AstExprClause
  (AstExprClause 0 0))

(dense_list.compiler-dense-list-operations
  AstExprClause
  AstExprClauseList
  ast-expr-clause-list
  caller-provided-fallback
  minimum-one
  compiler-dense-list-unused-shared-zero-storage)

(define (ast-expr-binding-clause-id
  [name : ci.InternSyntaxId]
  [has-type : bool]
  [ty : i64]
  [init : i64]
  [init-produced : AstType]
  [span : AstSourceSpan]) : AstExprBindingClause
  (AstExprBindingClause name has-type ty init init-produced span))

(define (ast-expr-binding-clause-fallback) : AstExprBindingClause
  (AstExprBindingClause
    (ci.intern-syntax-id-from-raw 0)
    false
    0
    0
    (AstType.Var -3)
    (ast-source-span 0 0 0 0)))

(dense_list.compiler-dense-list-operations
  AstExprBindingClause
  AstExprBindingClauseList
  ast-expr-binding-clause-list
  caller-provided-fallback
  minimum-one
  compiler-dense-list-unused-shared-zero-storage)

(define (ast-expr-spanned [inner : i64] [span : AstSourceSpan]) : i64
  (ast-node-push (AstExpr.Spanned inner span)))

(define (ast-expr-macro-expansion
  [inner : i64]
  [provenance-id : i64]
  [macro-name-id : i64]) : i64
  (ast-node-push (AstExpr.MacroExpansion inner provenance-id macro-name-id)))

(define (ast-expr-binary [op : AstBinOp] [left : i64] [right : i64]) : i64
  (ast-node-push (AstExpr.Binary op left right)))

(define (ast-expr-unary [op : AstUnOp] [inner : i64]) : i64
  (ast-node-push (AstExpr.Unary op inner)))

(define (ast-expr-call [callee : i64] [args : AstExprList]) : i64
  (ast-node-push (AstExpr.Call callee args)))

(define (ast-expr-bracket-clause [items : AstExprList]) : i64
  (ast-node-push (AstExpr.BracketClause items)))

(define (ast-expr-if [cond : i64] [then-expr : i64] [else-expr : i64]) : i64
  (ast-node-push (AstExpr.If cond then-expr else-expr)))

(define (ast-expr-let [bindings : AstLetBindingList] [body : i64]) : i64
  (ast-node-push (AstExpr.Let (box (AstLet.Let bindings body)))))

(define (ast-expr-lambda
  [params : AstParamList]
  [ret : AstMaybeType]
  [body : i64]) : i64
  (ast-node-push (AstExpr.Lambda (box (AstLambda.Lambda params ret body)))))

(define (ast-expr-tuple-ref [target : i64] [index : i64]) : i64
  (ast-node-push (AstExpr.TupleRef target index)))

(define (ast-expr-make-array-id [elem-id : i64] [size : i64]) : i64
  (ast-node-push (AstExpr.MakeArray elem-id size)))

(define (ast-expr-fixed-make-array-id [elem-id : i64] [size : i64]) : i64
  (ast-node-push (AstExpr.FixedMakeArray elem-id size)))

(define (ast-expr-array-ref [target : i64] [index : i64]) : i64
  (ast-node-push (AstExpr.ArrayRef target index)))

(define (ast-expr-array-set [target : i64] [index : i64] [value : i64]) : i64
  (ast-node-push (AstExpr.ArraySet target index value)))

(define (ast-expr-array-take [target : i64] [live : i64] [index : i64]) : i64
  (ast-node-push (AstExpr.ArrayTake target live index)))

(define (ast-expr-replace [place : i64] [replacement : i64]) : i64
  (ast-node-push (AstExpr.Replace place replacement)))

(define (ast-expr-while [cond : i64] [body : i64]) : i64
  (ast-node-push (AstExpr.While cond body)))

(define (ast-for-owned-state-payload
  [source-name : i64]
  [index-name : i64]
  [source : i64]
  [body : i64]) : AstExprList
  (let
    [fields : AstExprList (ast-expr-list-with-capacity 4)]
    (begin
      (ast-expr-list-push (&mut fields) source-name)
      (ast-expr-list-push (&mut fields) index-name)
      (ast-expr-list-push (&mut fields) source)
      (ast-expr-list-push (&mut fields) body)
      fields)))

(define (ast-for-owned-step-payload
  [source-name : i64]
  [index-name : i64]
  [binding-name : i64]
  [expected-type : i64]
  [done-name : i64]
  [body : i64]) : AstExprList
  (let
    [fields : AstExprList (ast-expr-list-with-capacity 6)]
    (begin
      (ast-expr-list-push (&mut fields) source-name)
      (ast-expr-list-push (&mut fields) index-name)
      (ast-expr-list-push (&mut fields) binding-name)
      (ast-expr-list-push (&mut fields) expected-type)
      (ast-expr-list-push (&mut fields) done-name)
      (ast-expr-list-push (&mut fields) body)
      fields)))

(define (ast-for-owned-payload-get
  [payload : (& payload AstExprList)]
  [index : i64]) : i64
  (ast-expr-list-get payload index -1))

(define (ast-for-owned-state-source-name [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 0))

(define (ast-for-owned-state-index-name [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 1))

(define (ast-for-owned-state-source [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 2))

(define (ast-for-owned-state-body [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 3))

(define (ast-for-owned-step-source-name [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 0))

(define (ast-for-owned-step-index-name [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 1))

(define (ast-for-owned-step-binding-name [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 2))

(define (ast-for-owned-step-expected-type [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 3))

(define (ast-for-owned-step-done-name [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 4))

(define (ast-for-owned-step-body [payload : (& payload AstExprList)]) : i64
  (ast-for-owned-payload-get payload 5))

;; --- AstExpr child schema ---
;; The one shared description of which payload fields of each AstExpr variant
;; are child syntax. The walker macros expand to a direct match over every
;; variant, with no wildcard arm, so a new variant fails to compile until it is
;; classified here. Like compiler-ir-call-args-visit they call pass-owned hooks
;; (functions or macros) with the extra context expressions first, then the
;; child. Children come in payload order, in four kinds:
;;   expr     expression node ids: operands, list items, let initializers,
;;            match-arm bodies, resource init/cleanup, and the for-owned slots
;;            (a for-owned-step without an item annotation has no slot 3)
;;   type-id  type node ids, including Init's annotation when present (>= 0)
;;   type     inline AstTypes: parameter types, let and lambda-result
;;            annotations when present, and the Foreach/SPMD index, prefix and
;;            slot types
;;   pattern  match-arm patterns
;; Names, literals, operators, spans and other scalars are not children; the
;; map macro copies them and takes hooks for the owned literal and binary-data
;; payloads. A walker that treats some variants specially (binding scopes,
;; names, fences) matches those itself and hands the rest to the schema.
;;
;; `ast-expr-fold-children` evaluates to `seed` for a node without children
;; and otherwise to `(combine (... (combine seed child0) ...) childN)`, each
;; child being the matching hook's result. `ast-expr-for-each-child` is that
;; fold with `begin`/unit; a short-circuit query folds with `ast-fold-or` and
;; false.
(defmacro (ast-fold-seq [acc : Expr] [value : Expr]) : Expr
  `(begin
    ,acc
    ,value))

(defmacro (ast-fold-or [acc : Expr] [value : Expr]) : Expr
  `(or ,acc ,value))

;; Hooks for child kinds a walker does not visit.
(defmacro (ast-child-unit [_ignored : Expr ...]) : Expr
  `unit)

(defmacro (ast-fold-1
  [combine : Expr]
  [seed : Expr]
  [hook : Expr]
  [child : Expr]
  [contexts : Expr ...]) : Expr
  `(,combine ,seed (,hook ,@contexts ,child)))

(defmacro (ast-fold-2
  [combine : Expr]
  [seed : Expr]
  [hook : Expr]
  [a : Expr]
  [b : Expr]
  [contexts : Expr ...]) : Expr
  `(,combine (,combine ,seed (,hook ,@contexts ,a)) (,hook ,@contexts ,b)))

(defmacro (ast-fold-3
  [combine : Expr]
  [seed : Expr]
  [hook : Expr]
  [a : Expr]
  [b : Expr]
  [c : Expr]
  [contexts : Expr ...]) : Expr
  `(,combine
    (,combine (,combine ,seed (,hook ,@contexts ,a)) (,hook ,@contexts ,b))
    (,hook ,@contexts ,c)))

(defmacro (ast-maybe-type-fold
  [maybe-ty : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [acc ,seed]
    (match ,maybe-ty
      [(AstMaybeType.Some ty) (,combine acc (,on-type ,@contexts ty))]
      [(AstMaybeType.No) acc])))

(defmacro (ast-expr-list-fold
  [items : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,items]
    [acc ,seed]
    [index : i64 0]
    (begin
      (while (< index (ast-expr-list-len (& list)))
        (begin
          (set!
            acc
            (,combine
              acc
              (,on-expr ,@contexts (ast-expr-list-get (& list) index 0))))
          (set! index (+ index 1))))
      acc)))

;; For-owned payload slots; an absent slot is -1.
(defmacro (ast-for-owned-slots-fold
  [items : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,items]
    [acc ,seed]
    [index : i64 0]
    (begin
      (while (< index (ast-expr-list-len (& list)))
        (let
          [child : i64 (ast-expr-list-get (& list) index 0)]
          (begin
            (if (< child 0)
              unit
              (set! acc (,combine acc (,on-expr ,@contexts child))))
            (set! index (+ index 1)))))
      acc)))

(defmacro (ast-let-binding-list-fold
  [bindings : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-expr : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,bindings]
    [acc ,seed]
    [index : i64 0]
    (begin
      (while (< index (ast-let-binding-list-len (& list)))
        (begin
          (match (ast-let-binding-list-get
            (& list)
            index
            (ast-let-binding-fallback))
            [(AstLetBinding.Binding _ maybe-ty init)
              (set!
                acc
                (,combine
                  (ast-maybe-type-fold
                    maybe-ty
                    ,combine
                    acc
                    ,on-type
                    ,@contexts)
                  (,on-expr ,@contexts init)))])
          (set! index (+ index 1))))
      acc)))

(defmacro (ast-param-list-fold
  [params : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,params]
    [acc ,seed]
    [index : i64 0]
    (begin
      (while (< index (ast-param-list-len (& list)))
        (begin
          (match (ast-param-list-get (& list) index (ast-param-fallback))
            [(AstParam.Param _ ty _)
              (set! acc (,combine acc (,on-type ,@contexts ty)))])
          (set! index (+ index 1))))
      acc)))

(defmacro (ast-match-arm-list-fold
  [arms : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-expr : Expr]
  [on-pattern : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,arms]
    [acc ,seed]
    [index : i64 0]
    (begin
      (while (< index (ast-match-arm-list-len (& list)))
        (begin
          (match (ast-match-arm-list-get
            (& list)
            index
            (ast-match-arm-fallback))
            [(AstMatchArm.Arm pattern body)
              (set!
                acc
                (,combine
                  (,combine acc (,on-pattern ,@contexts pattern))
                  (,on-expr ,@contexts body)))])
          (set! index (+ index 1))))
      acc)))

(defmacro (ast-resource-binding-list-fold
  [bindings : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,bindings]
    [acc ,seed]
    [index : i64 0]
    (begin
      (while (< index (ast-resource-binding-list-len (& list)))
        (begin
          (match (ast-resource-binding-list-get
            (& list)
            index
            (ast-resource-binding-fallback))
            [(AstResourceBinding.Binding _ init cleanup _)
              (set!
                acc
                (ast-fold-2 ,combine acc ,on-expr init cleanup ,@contexts))])
          (set! index (+ index 1))))
      acc)))

(defmacro (ast-expr-fold-children
  [expr : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-expr : Expr]
  [on-type-id : Expr]
  [on-type : Expr]
  [on-pattern : Expr]
  [contexts : Expr ...]) : Expr
  (let
    [c : Expr combine]
    [s : Expr seed]
    [e : Expr on-expr]
    [ti : Expr on-type-id]
    [ty : Expr on-type]
    [p : Expr on-pattern]
    [x : ExprList contexts]
    `(match ,expr
      [(AstExpr.Spanned a _) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Literal _) ,s]
      [(AstExpr.Var _) ,s]
      [(AstExpr.Binary _ a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.Unary _ a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Call a items)
        (ast-expr-list-fold items ,c (ast-fold-1 ,c ,s ,e a ,@x) ,e ,@x)]
      [(AstExpr.If a b d) (ast-fold-3 ,c ,s ,e a b d ,@x)]
      [(AstExpr.Let payload)
        (match (__tl-box-place payload)
          [(AstLet.Let bindings body)
            (ast-fold-1
              ,c
              (ast-let-binding-list-fold bindings ,c ,s ,e ,ty ,@x)
              ,e
              body
              ,@x)])]
      [(AstExpr.Lambda payload)
        (match (__tl-box-place payload)
          [(AstLambda.Lambda params maybe-ret body)
            (ast-fold-1
              ,c
              (ast-maybe-type-fold
                maybe-ret
                ,c
                (ast-param-list-fold params ,c ,s ,ty ,@x)
                ,ty
                ,@x)
              ,e
              body
              ,@x)])]
      [(AstExpr.Tuple items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.TupleRef a _) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Array items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.DynArray items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.FixedMakeArray t a)
        (ast-fold-1 ,c (ast-fold-1 ,c ,s ,ti t ,@x) ,e a ,@x)]
      [(AstExpr.MakeArray t a)
        (ast-fold-1 ,c (ast-fold-1 ,c ,s ,ti t ,@x) ,e a ,@x)]
      [(AstExpr.ArrayRef a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.ArraySet a b d) (ast-fold-3 ,c ,s ,e a b d ,@x)]
      [(AstExpr.ArrayTake a b d) (ast-fold-3 ,c ,s ,e a b d ,@x)]
      [(AstExpr.ArrayPush a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.StringRef a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.While a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.Begin items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.Unsafe items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.Set _ a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Replace a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.Ann a t) (ast-fold-1 ,c (ast-fold-1 ,c ,s ,e a ,@x) ,ti t ,@x)]
      [(AstExpr.Cast a t) (ast-fold-1 ,c (ast-fold-1 ,c ,s ,e a ,@x) ,ti t ,@x)]
      [(AstExpr.Borrow _ _ a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Match payload)
        (match (__tl-box-place payload)
          [(AstMatch.Match a arms)
            (ast-match-arm-list-fold
              arms
              ,c
              (ast-fold-1 ,c ,s ,e a ,@x)
              ,e
              ,p
              ,@x)])]
      [(AstExpr.Foreach payload)
        (match (__tl-box-place payload)
          [(AstForeach.Foreach _ t a b d)
            (ast-fold-3 ,c (ast-fold-1 ,c ,s ,ty t ,@x) ,e a b d ,@x)])]
      [(AstExpr.SpmdReduce payload)
        (match (__tl-box-place payload)
          [(AstSpmdReduce.Reduce _ _ t a b d f)
            (ast-fold-2
              ,c
              (ast-fold-2 ,c (ast-fold-1 ,c ,s ,ty t ,@x) ,e a b ,@x)
              ,e
              d
              f
              ,@x)])]
      [(AstExpr.SpmdScan payload)
        (match (__tl-box-place payload)
          [(AstSpmdScan.Scan _ _ t a b _ u d f g)
            (ast-fold-3
              ,c
              (ast-fold-1
                ,c
                (ast-fold-2 ,c (ast-fold-1 ,c ,s ,ty t ,@x) ,e a b ,@x)
                ,ty
                u
                ,@x)
              ,e
              d
              f
              g
              ,@x)])]
      [(AstExpr.SpmdCompact payload)
        (match (__tl-box-place payload)
          [(AstSpmdCompact.Compact _ t a b _ u d f g)
            (ast-fold-3
              ,c
              (ast-fold-1
                ,c
                (ast-fold-2 ,c (ast-fold-1 ,c ,s ,ty t ,@x) ,e a b ,@x)
                ,ty
                u
                ,@x)
              ,e
              d
              f
              g
              ,@x)])]
      [(AstExpr.SpmdBroadcast a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.SpmdShuffle a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.SpmdProgramIndex) ,s]
      [(AstExpr.SpmdProgramCount) ,s]
      [(AstExpr.StructGet a _) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.StructSet a _ b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.WithRegion _ items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.WithEscape a items)
        (ast-expr-list-fold items ,c (ast-fold-1 ,c ,s ,e a ,@x) ,e ,@x)]
      [(AstExpr.WithScratch items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.InArena a items)
        (ast-expr-list-fold items ,c (ast-fold-1 ,c ,s ,e a ,@x) ,e ,@x)]
      [(AstExpr.WithResource payload)
        (match (__tl-box-place payload)
          [(AstWithResource.WithResource bindings items)
            (ast-expr-list-fold
              items
              ,c
              (ast-resource-binding-list-fold bindings ,c ,s ,e ,@x)
              ,e
              ,@x)])]
      [(AstExpr.Box a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.BoxGet a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.BoxTake a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.BoxSet a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.TypeLiteral t) (ast-fold-1 ,c ,s ,ti t ,@x)]
      [(AstExpr.Init t)
        (if (< t 0)
          ,s
          (ast-fold-1 ,c ,s ,ti t ,@x))]
      [(AstExpr.Comptime a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Quote a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Quasiquote a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Unquote a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.UnquoteSplicing a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.BracketClause items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.Try a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Return a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Break) ,s]
      [(AstExpr.Continue) ,s]
      [(AstExpr.PtrNull t) (ast-fold-1 ,c ,s ,ti t ,@x)]
      [(AstExpr.PtrNullCheck a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.PtrAddrOf a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.PtrRead a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.PtrWrite a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.PtrOffset a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.PtrCast a t)
        (ast-fold-1 ,c (ast-fold-1 ,c ,s ,e a ,@x) ,ti t ,@x)]
      [(AstExpr.PtrToInt a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.IntToPtr a t)
        (ast-fold-1 ,c (ast-fold-1 ,c ,s ,e a ,@x) ,ti t ,@x)]
      [(AstExpr.StringData a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.StringFromBytes a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.ArrayData a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.BinaryData _) ,s]
      [(AstExpr.ProgramArgc) ,s]
      [(AstExpr.ProgramArgv) ,s]
      [(AstExpr.ProgramEnvp) ,s]
      [(AstExpr.CpuIdEax a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.CpuIdEbx a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.CpuIdEcx a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.CpuIdEdx a b) (ast-fold-2 ,c ,s ,e a b ,@x)]
      [(AstExpr.Xgetbv a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.Syscall items) (ast-expr-list-fold items ,c ,s ,e ,@x)]
      [(AstExpr.ForOwnedState items)
        (ast-for-owned-slots-fold items ,c ,s ,e ,@x)]
      [(AstExpr.ForOwnedStep items)
        (ast-for-owned-slots-fold items ,c ,s ,e ,@x)]
      [(AstExpr.MacroExpansion a _ _) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.ForeachActive _ a) (ast-fold-1 ,c ,s ,e a ,@x)]
      [(AstExpr.LaneValue a) (ast-fold-1 ,c ,s ,e a ,@x)])))

(defmacro (ast-expr-for-each-child
  [expr : Expr]
  [on-expr : Expr]
  [on-type-id : Expr]
  [on-type : Expr]
  [on-pattern : Expr]
  [contexts : Expr ...]) : unit
  `(ast-expr-fold-children
    ,expr
    ast-fold-seq
    unit
    ,on-expr
    ,on-type-id
    ,on-type
    ,on-pattern
    ,@contexts))

;; `ast-expr-map-children` rebuilds the node with every child replaced by its
;; hook's result, mapping children in payload order (so side effects of the
;; hooks, such as pushing new nodes, happen in that order). Negative for-owned
;; slots stay as they are.
(defmacro (ast-maybe-type-map
  [maybe-ty : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(match ,maybe-ty
    [(AstMaybeType.No) AstMaybeType.No]
    [(AstMaybeType.Some ty) (AstMaybeType.Some (,on-type ,@contexts ty))]))

(defmacro (ast-expr-list-map
  [items : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,items]
    [out (ast-expr-list-with-capacity (ast-expr-list-len (& list)))]
    [index : i64 0]
    (begin
      (while (< index (ast-expr-list-len (& list)))
        (begin
          (ast-expr-list-push
            (&mut out)
            (,on-expr ,@contexts (ast-expr-list-get (& list) index 0)))
          (set! index (+ index 1))))
      out)))

(defmacro (ast-for-owned-slots-map
  [items : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,items]
    [out (ast-expr-list-with-capacity (ast-expr-list-len (& list)))]
    [index : i64 0]
    (begin
      (while (< index (ast-expr-list-len (& list)))
        (let
          [child : i64 (ast-expr-list-get (& list) index 0)]
          (begin
            (ast-expr-list-push
              (&mut out)
              (if (< child 0)
                child
                (,on-expr ,@contexts child)))
            (set! index (+ index 1)))))
      out)))

(defmacro (ast-let-binding-list-map
  [bindings : Expr]
  [on-expr : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,bindings]
    [out
      (ast-let-binding-list-with-capacity (ast-let-binding-list-len (& list)))]
    [index : i64 0]
    (begin
      (while (< index (ast-let-binding-list-len (& list)))
        (begin
          (match (ast-let-binding-list-get
            (& list)
            index
            (ast-let-binding-fallback))
            [(AstLetBinding.Binding name maybe-ty init)
              (ast-let-binding-list-push
                (&mut out)
                (AstLetBinding.Binding
                  name
                  (ast-maybe-type-map maybe-ty ,on-type ,@contexts)
                  (,on-expr ,@contexts init)))])
          (set! index (+ index 1))))
      out)))

(defmacro (ast-param-list-map
  [params : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,params]
    [out (ast-param-list-with-capacity (ast-param-list-len (& list)))]
    [index : i64 0]
    (begin
      (while (< index (ast-param-list-len (& list)))
        (begin
          (match (ast-param-list-get (& list) index (ast-param-fallback))
            [(AstParam.Param name ty is-comptime)
              (ast-param-list-push
                (&mut out)
                (AstParam.Param name (,on-type ,@contexts ty) is-comptime))])
          (set! index (+ index 1))))
      out)))

(defmacro (ast-match-arm-list-map
  [arms : Expr]
  [on-expr : Expr]
  [on-pattern : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,arms]
    [out (ast-match-arm-list-with-capacity (ast-match-arm-list-len (& list)))]
    [index : i64 0]
    (begin
      (while (< index (ast-match-arm-list-len (& list)))
        (begin
          (match (ast-match-arm-list-get
            (& list)
            index
            (ast-match-arm-fallback))
            [(AstMatchArm.Arm pattern body)
              (ast-match-arm-list-push
                (&mut out)
                (AstMatchArm.Arm
                  (,on-pattern ,@contexts pattern)
                  (,on-expr ,@contexts body)))])
          (set! index (+ index 1))))
      out)))

(defmacro (ast-resource-binding-list-map
  [bindings : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,bindings]
    [out
      (ast-resource-binding-list-with-capacity
        (ast-resource-binding-list-len (& list)))]
    [index : i64 0]
    (begin
      (while (< index (ast-resource-binding-list-len (& list)))
        (begin
          (match (ast-resource-binding-list-get
            (& list)
            index
            (ast-resource-binding-fallback))
            [(AstResourceBinding.Binding name init cleanup move-aware?)
              (ast-resource-binding-list-push
                (&mut out)
                (AstResourceBinding.Binding
                  name
                  (,on-expr ,@contexts init)
                  (,on-expr ,@contexts cleanup)
                  move-aware?))])
          (set! index (+ index 1))))
      out)))

(defmacro (ast-expr-map-children
  [expr : Expr]
  [on-expr : Expr]
  [on-type-id : Expr]
  [on-type : Expr]
  [on-pattern : Expr]
  [on-literal : Expr]
  [on-bytes : Expr]
  [contexts : Expr ...]) : AstExpr
  (let
    [e : Expr on-expr]
    [ti : Expr on-type-id]
    [ty : Expr on-type]
    [p : Expr on-pattern]
    [x : ExprList contexts]
    `(match ,expr
      [(AstExpr.Spanned a span) (AstExpr.Spanned (,e ,@x a) span)]
      [(AstExpr.Literal lit) (AstExpr.Literal (,on-literal ,@x lit))]
      [(AstExpr.Var name) (AstExpr.Var name)]
      [(AstExpr.Binary op a b) (AstExpr.Binary op (,e ,@x a) (,e ,@x b))]
      [(AstExpr.Unary op a) (AstExpr.Unary op (,e ,@x a))]
      [(AstExpr.Call a items)
        (AstExpr.Call (,e ,@x a) (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.If a b d) (AstExpr.If (,e ,@x a) (,e ,@x b) (,e ,@x d))]
      [(AstExpr.Let payload)
        (match (__tl-box-place payload)
          [(AstLet.Let bindings body)
            (AstExpr.Let
              (box
                (AstLet.Let
                  (ast-let-binding-list-map bindings ,e ,ty ,@x)
                  (,e ,@x body))))])]
      [(AstExpr.Lambda payload)
        (match (__tl-box-place payload)
          [(AstLambda.Lambda params maybe-ret body)
            (AstExpr.Lambda
              (box
                (AstLambda.Lambda
                  (ast-param-list-map params ,ty ,@x)
                  (ast-maybe-type-map maybe-ret ,ty ,@x)
                  (,e ,@x body))))])]
      [(AstExpr.Tuple items) (AstExpr.Tuple (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.TupleRef a index) (AstExpr.TupleRef (,e ,@x a) index)]
      [(AstExpr.Array items) (AstExpr.Array (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.DynArray items)
        (AstExpr.DynArray (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.FixedMakeArray t a)
        (AstExpr.FixedMakeArray (,ti ,@x t) (,e ,@x a))]
      [(AstExpr.MakeArray t a) (AstExpr.MakeArray (,ti ,@x t) (,e ,@x a))]
      [(AstExpr.ArrayRef a b) (AstExpr.ArrayRef (,e ,@x a) (,e ,@x b))]
      [(AstExpr.ArraySet a b d)
        (AstExpr.ArraySet (,e ,@x a) (,e ,@x b) (,e ,@x d))]
      [(AstExpr.ArrayTake a b d)
        (AstExpr.ArrayTake (,e ,@x a) (,e ,@x b) (,e ,@x d))]
      [(AstExpr.ArrayPush a b) (AstExpr.ArrayPush (,e ,@x a) (,e ,@x b))]
      [(AstExpr.StringRef a b) (AstExpr.StringRef (,e ,@x a) (,e ,@x b))]
      [(AstExpr.While a b) (AstExpr.While (,e ,@x a) (,e ,@x b))]
      [(AstExpr.Begin items) (AstExpr.Begin (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.Unsafe items) (AstExpr.Unsafe (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.Set name a) (AstExpr.Set name (,e ,@x a))]
      [(AstExpr.Replace a b) (AstExpr.Replace (,e ,@x a) (,e ,@x b))]
      [(AstExpr.Ann a t) (AstExpr.Ann (,e ,@x a) (,ti ,@x t))]
      [(AstExpr.Cast a t) (AstExpr.Cast (,e ,@x a) (,ti ,@x t))]
      [(AstExpr.Borrow mutable lifetime a)
        (AstExpr.Borrow mutable lifetime (,e ,@x a))]
      [(AstExpr.Match payload)
        (match (__tl-box-place payload)
          [(AstMatch.Match a arms)
            (AstExpr.Match
              (box
                (AstMatch.Match
                  (,e ,@x a)
                  (ast-match-arm-list-map arms ,e ,p ,@x))))])]
      [(AstExpr.Foreach payload)
        (match (__tl-box-place payload)
          [(AstForeach.Foreach name t a b d)
            (AstExpr.Foreach
              (box
                (AstForeach.Foreach
                  name
                  (,ty ,@x t)
                  (,e ,@x a)
                  (,e ,@x b)
                  (,e ,@x d))))])]
      [(AstExpr.SpmdReduce payload)
        (match (__tl-box-place payload)
          [(AstSpmdReduce.Reduce op index t a b d f)
            (AstExpr.SpmdReduce
              (box
                (AstSpmdReduce.Reduce
                  op
                  index
                  (,ty ,@x t)
                  (,e ,@x a)
                  (,e ,@x b)
                  (,e ,@x d)
                  (,e ,@x f))))])]
      [(AstExpr.SpmdScan payload)
        (match (__tl-box-place payload)
          [(AstSpmdScan.Scan op index t a b prefix u d f g)
            (AstExpr.SpmdScan
              (box
                (AstSpmdScan.Scan
                  op
                  index
                  (,ty ,@x t)
                  (,e ,@x a)
                  (,e ,@x b)
                  prefix
                  (,ty ,@x u)
                  (,e ,@x d)
                  (,e ,@x f)
                  (,e ,@x g))))])]
      [(AstExpr.SpmdCompact payload)
        (match (__tl-box-place payload)
          [(AstSpmdCompact.Compact index t a b slot u d f g)
            (AstExpr.SpmdCompact
              (box
                (AstSpmdCompact.Compact
                  index
                  (,ty ,@x t)
                  (,e ,@x a)
                  (,e ,@x b)
                  slot
                  (,ty ,@x u)
                  (,e ,@x d)
                  (,e ,@x f)
                  (,e ,@x g))))])]
      [(AstExpr.SpmdBroadcast a b)
        (AstExpr.SpmdBroadcast (,e ,@x a) (,e ,@x b))]
      [(AstExpr.SpmdShuffle a b) (AstExpr.SpmdShuffle (,e ,@x a) (,e ,@x b))]
      [(AstExpr.SpmdProgramIndex) AstExpr.SpmdProgramIndex]
      [(AstExpr.SpmdProgramCount) AstExpr.SpmdProgramCount]
      [(AstExpr.StructGet a field) (AstExpr.StructGet (,e ,@x a) field)]
      [(AstExpr.StructSet a field b)
        (AstExpr.StructSet (,e ,@x a) field (,e ,@x b))]
      [(AstExpr.WithRegion region items)
        (AstExpr.WithRegion region (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.WithEscape a items)
        (AstExpr.WithEscape (,e ,@x a) (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.WithScratch items)
        (AstExpr.WithScratch (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.InArena a items)
        (AstExpr.InArena (,e ,@x a) (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.WithResource payload)
        (match (__tl-box-place payload)
          [(AstWithResource.WithResource bindings items)
            (AstExpr.WithResource
              (box
                (AstWithResource.WithResource
                  (ast-resource-binding-list-map bindings ,e ,@x)
                  (ast-expr-list-map items ,e ,@x))))])]
      [(AstExpr.Box a) (AstExpr.Box (,e ,@x a))]
      [(AstExpr.BoxGet a) (AstExpr.BoxGet (,e ,@x a))]
      [(AstExpr.BoxTake a) (AstExpr.BoxTake (,e ,@x a))]
      [(AstExpr.BoxSet a b) (AstExpr.BoxSet (,e ,@x a) (,e ,@x b))]
      [(AstExpr.TypeLiteral t) (AstExpr.TypeLiteral (,ti ,@x t))]
      [(AstExpr.Init t)
        (AstExpr.Init
          (if (< t 0)
            t
            (,ti ,@x t)))]
      [(AstExpr.Comptime a) (AstExpr.Comptime (,e ,@x a))]
      [(AstExpr.Quote a) (AstExpr.Quote (,e ,@x a))]
      [(AstExpr.Quasiquote a) (AstExpr.Quasiquote (,e ,@x a))]
      [(AstExpr.Unquote a) (AstExpr.Unquote (,e ,@x a))]
      [(AstExpr.UnquoteSplicing a) (AstExpr.UnquoteSplicing (,e ,@x a))]
      [(AstExpr.BracketClause items)
        (AstExpr.BracketClause (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.Try a) (AstExpr.Try (,e ,@x a))]
      [(AstExpr.Return a) (AstExpr.Return (,e ,@x a))]
      [(AstExpr.Break) AstExpr.Break]
      [(AstExpr.Continue) AstExpr.Continue]
      [(AstExpr.PtrNull t) (AstExpr.PtrNull (,ti ,@x t))]
      [(AstExpr.PtrNullCheck a) (AstExpr.PtrNullCheck (,e ,@x a))]
      [(AstExpr.PtrAddrOf a) (AstExpr.PtrAddrOf (,e ,@x a))]
      [(AstExpr.PtrRead a) (AstExpr.PtrRead (,e ,@x a))]
      [(AstExpr.PtrWrite a b) (AstExpr.PtrWrite (,e ,@x a) (,e ,@x b))]
      [(AstExpr.PtrOffset a b) (AstExpr.PtrOffset (,e ,@x a) (,e ,@x b))]
      [(AstExpr.PtrCast a t) (AstExpr.PtrCast (,e ,@x a) (,ti ,@x t))]
      [(AstExpr.PtrToInt a) (AstExpr.PtrToInt (,e ,@x a))]
      [(AstExpr.IntToPtr a t) (AstExpr.IntToPtr (,e ,@x a) (,ti ,@x t))]
      [(AstExpr.StringData a) (AstExpr.StringData (,e ,@x a))]
      [(AstExpr.StringFromBytes a b)
        (AstExpr.StringFromBytes (,e ,@x a) (,e ,@x b))]
      [(AstExpr.ArrayData a) (AstExpr.ArrayData (,e ,@x a))]
      [(AstExpr.BinaryData bytes) (AstExpr.BinaryData (,on-bytes ,@x bytes))]
      [(AstExpr.ProgramArgc) AstExpr.ProgramArgc]
      [(AstExpr.ProgramArgv) AstExpr.ProgramArgv]
      [(AstExpr.ProgramEnvp) AstExpr.ProgramEnvp]
      [(AstExpr.CpuIdEax a b) (AstExpr.CpuIdEax (,e ,@x a) (,e ,@x b))]
      [(AstExpr.CpuIdEbx a b) (AstExpr.CpuIdEbx (,e ,@x a) (,e ,@x b))]
      [(AstExpr.CpuIdEcx a b) (AstExpr.CpuIdEcx (,e ,@x a) (,e ,@x b))]
      [(AstExpr.CpuIdEdx a b) (AstExpr.CpuIdEdx (,e ,@x a) (,e ,@x b))]
      [(AstExpr.Xgetbv a) (AstExpr.Xgetbv (,e ,@x a))]
      [(AstExpr.Syscall items)
        (AstExpr.Syscall (ast-expr-list-map items ,e ,@x))]
      [(AstExpr.ForOwnedState items)
        (AstExpr.ForOwnedState (ast-for-owned-slots-map items ,e ,@x))]
      [(AstExpr.ForOwnedStep items)
        (AstExpr.ForOwnedStep (ast-for-owned-slots-map items ,e ,@x))]
      [(AstExpr.MacroExpansion a provenance name)
        (AstExpr.MacroExpansion (,e ,@x a) provenance name)]
      [(AstExpr.ForeachActive lane a) (AstExpr.ForeachActive lane (,e ,@x a))]
      [(AstExpr.LaneValue a) (AstExpr.LaneValue (,e ,@x a))])))

;; The expression-child schema as two functions, for walkers that treat a
;; node's expression children uniformly: `ast-expr-child-ids` lists them in
;; payload order, and `ast-expr-with-child-ids` rebuilds the node with them
;; replaced by `ids` in the same order, keeping every other payload field.
;; Type and pattern children are not included, and absent for-owned slots are
;; neither listed nor replaced. A walker keeps the arms it has rules for and
;; hands every other node to its list form over these ids, so each schema
;; expansion is compiled once here rather than once per walker.
(define (ast-expr-child-ids [expr : AstExpr]) : AstExprList
  (let
    [ids : AstExprList (ast-expr-list-new)]
    (begin
      (ast-expr-for-each-child
        expr
        ast-expr-list-push
        ast-child-unit
        ast-child-unit
        ast-child-unit
        (&mut ids))
      ids)))

(defmacro (ast-expr-take-child-id [ids : Expr] [next : Expr] [_replaced : Expr]) : Expr
  `(begin
    (set! ,next (+ ,next 1))
    (ast-expr-list-get ,ids (- ,next 1) -1)))

(defmacro (ast-child-keep [_ids : Expr] [_next : Expr] [value : Expr]) : Expr
  value)

(define (ast-expr-with-child-ids [expr : AstExpr] [ids : (& ids AstExprList)]) : AstExpr
  (let
    [next : i64 0]
    (ast-expr-map-children
      expr
      ast-expr-take-child-id
      ast-child-keep
      ast-child-keep
      ast-child-keep
      ast-child-keep
      ast-child-keep
      ids
      next)))

;; `ast-expr-children` lists every child, typed by kind, in payload order: the
;; expression ids of `ast-expr-child-ids` interleaved with the type-id, inline
;; type and pattern children, for walkers that also visit those in order.
(defenum AstExprChild
  (Expr i64)
  (TypeId i64)
  (Type AstType)
  (Pattern AstPattern))

(defstruct AstExprChildList
  (slots (__tl_dyn-array AstExprChild))
  (len i64))

(define (ast-expr-child-fallback) : AstExprChild
  (AstExprChild.Expr -1))

(dense_list.compiler-dense-list-operations
  AstExprChild
  AstExprChildList
  ast-expr-child-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage)

(defmacro (ast-expr-child-push-expr! [out : Expr] [child : Expr]) : Expr
  `(ast-expr-child-list-push ,out (AstExprChild.Expr ,child)))

(defmacro (ast-expr-child-push-type-id! [out : Expr] [child : Expr]) : Expr
  `(ast-expr-child-list-push ,out (AstExprChild.TypeId ,child)))

(defmacro (ast-expr-child-push-type! [out : Expr] [child : Expr]) : Expr
  `(ast-expr-child-list-push ,out (AstExprChild.Type ,child)))

(defmacro (ast-expr-child-push-pattern! [out : Expr] [child : Expr]) : Expr
  `(ast-expr-child-list-push ,out (AstExprChild.Pattern ,child)))

(define (ast-expr-children [expr : AstExpr]) : AstExprChildList
  (let
    [children : AstExprChildList (ast-expr-child-list-with-capacity 0)]
    (begin
      (ast-expr-for-each-child
        expr
        ast-expr-child-push-expr!
        ast-expr-child-push-type-id!
        ast-expr-child-push-type!
        ast-expr-child-push-pattern!
        (&mut children))
      children)))

;; `ast-expr-children-eq?` is structural equality of two nodes: the same
;; variant, equal scalar payloads, and children equal pairwise by the hooks,
;; which receive both children (`on-literal` compares literals). It is pure:
;; the order of the comparisons only decides how early it answers false.
(define (ast-borrow-lifetime-id-eq? [a : i64] [b : i64]) : bool
  (if (< a 0)
    (< b 0)
    (= a b)))

(defmacro (ast-maybe-type-eq?
  [left : Expr]
  [right : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(match ,left
    [(AstMaybeType.No)
      (match ,right
        [(AstMaybeType.No) true]
        [_ false])]
    [(AstMaybeType.Some a)
      (match ,right
        [(AstMaybeType.Some b) (,on-type ,@contexts a b)]
        [_ false])]))

(defmacro (ast-expr-list-eq?
  [left : Expr]
  [right : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [a ,left]
    [b ,right]
    [same : bool (= (ast-expr-list-len (& a)) (ast-expr-list-len (& b)))]
    [index : i64 0]
    (begin
      (while (and same (< index (ast-expr-list-len (& a))))
        (begin
          (set!
            same
            (,on-expr
              ,@contexts
              (ast-expr-list-get (& a) index 0)
              (ast-expr-list-get (& b) index 0)))
          (set! index (+ index 1))))
      same)))

(defmacro (ast-for-owned-slots-eq?
  [left : Expr]
  [right : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [a ,left]
    [b ,right]
    [same : bool (= (ast-expr-list-len (& a)) (ast-expr-list-len (& b)))]
    [index : i64 0]
    (begin
      (while (and same (< index (ast-expr-list-len (& a))))
        (let
          [a-slot : i64 (ast-expr-list-get (& a) index 0)]
          [b-slot : i64 (ast-expr-list-get (& b) index 0)]
          (begin
            (set!
              same
              (if (< a-slot 0)
                (< b-slot 0)
                (and (>= b-slot 0) (,on-expr ,@contexts a-slot b-slot))))
            (set! index (+ index 1)))))
      same)))

(defmacro (ast-let-binding-list-eq?
  [left : Expr]
  [right : Expr]
  [on-expr : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [a ,left]
    [b ,right]
    [same : bool
      (= (ast-let-binding-list-len (& a)) (ast-let-binding-list-len (& b)))]
    [index : i64 0]
    (begin
      (while (and same (< index (ast-let-binding-list-len (& a))))
        (begin
          (match (ast-let-binding-list-get
            (& a)
            index
            (ast-let-binding-fallback))
            [(AstLetBinding.Binding a-name a-ty a-init)
              (match (ast-let-binding-list-get
                (& b)
                index
                (ast-let-binding-fallback))
                [(AstLetBinding.Binding b-name b-ty b-init)
                  (set!
                    same
                    (and
                      (= a-name b-name)
                      (ast-maybe-type-eq? a-ty b-ty ,on-type ,@contexts)
                      (,on-expr ,@contexts a-init b-init)))])])
          (set! index (+ index 1))))
      same)))

(defmacro (ast-param-list-eq?
  [left : Expr]
  [right : Expr]
  [on-type : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [a ,left]
    [b ,right]
    [same : bool (= (ast-param-list-len (& a)) (ast-param-list-len (& b)))]
    [index : i64 0]
    (begin
      (while (and same (< index (ast-param-list-len (& a))))
        (begin
          (match (ast-param-list-get (& a) index (ast-param-fallback))
            [(AstParam.Param a-name a-ty a-comptime)
              (match (ast-param-list-get (& b) index (ast-param-fallback))
                [(AstParam.Param b-name b-ty b-comptime)
                  (set!
                    same
                    (and
                      (= a-name b-name)
                      (,on-type ,@contexts a-ty b-ty)
                      (= a-comptime b-comptime)))])])
          (set! index (+ index 1))))
      same)))

(defmacro (ast-match-arm-list-eq?
  [left : Expr]
  [right : Expr]
  [on-expr : Expr]
  [on-pattern : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [a ,left]
    [b ,right]
    [same : bool
      (= (ast-match-arm-list-len (& a)) (ast-match-arm-list-len (& b)))]
    [index : i64 0]
    (begin
      (while (and same (< index (ast-match-arm-list-len (& a))))
        (begin
          (match (ast-match-arm-list-get (& a) index (ast-match-arm-fallback))
            [(AstMatchArm.Arm a-pattern a-body)
              (match (ast-match-arm-list-get
                (& b)
                index
                (ast-match-arm-fallback))
                [(AstMatchArm.Arm b-pattern b-body)
                  (set!
                    same
                    (and
                      (,on-pattern ,@contexts a-pattern b-pattern)
                      (,on-expr ,@contexts a-body b-body)))])])
          (set! index (+ index 1))))
      same)))

(defmacro (ast-resource-binding-list-eq?
  [left : Expr]
  [right : Expr]
  [on-expr : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [a ,left]
    [b ,right]
    [same : bool
      (=
        (ast-resource-binding-list-len (& a))
        (ast-resource-binding-list-len (& b)))]
    [index : i64 0]
    (begin
      (while (and same (< index (ast-resource-binding-list-len (& a))))
        (begin
          (match (ast-resource-binding-list-get
            (& a)
            index
            (ast-resource-binding-fallback))
            [(AstResourceBinding.Binding a-name a-init a-cleanup a-move-aware?)
              (match (ast-resource-binding-list-get
                (& b)
                index
                (ast-resource-binding-fallback))
                [(AstResourceBinding.Binding
                    b-name
                    b-init
                    b-cleanup
                    b-move-aware?)
                  (set!
                    same
                    (and
                      (= a-name b-name)
                      (= a-move-aware? b-move-aware?)
                      (,on-expr ,@contexts a-init b-init)
                      (,on-expr ,@contexts a-cleanup b-cleanup)))])])
          (set! index (+ index 1))))
      same)))

(defmacro (ast-expr-children-eq?
  [left : Expr]
  [right : Expr]
  [on-expr : Expr]
  [on-type-id : Expr]
  [on-type : Expr]
  [on-pattern : Expr]
  [on-literal : Expr]
  [contexts : Expr ...]) : bool
  (let
    [r : Expr right]
    [e : Expr on-expr]
    [ti : Expr on-type-id]
    [ty : Expr on-type]
    [x : ExprList contexts]
    `(match ,left
      [(AstExpr.Spanned a0 s0)
        (match ,r
          [(AstExpr.Spanned b0 s1)
            (and (,e ,@x a0 b0) (ast-source-span-eq? s0 s1))]
          [_ false])]
      [(AstExpr.Literal a0)
        (match ,r
          [(AstExpr.Literal b0) (,on-literal ,@x a0 b0)]
          [_ false])]
      [(AstExpr.Var a0)
        (match ,r
          [(AstExpr.Var b0) (= a0 b0)]
          [_ false])]
      [(AstExpr.Binary op0 a0 a1)
        (match ,r
          [(AstExpr.Binary op1 b0 b1)
            (and (= op0 op1) (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.Unary op0 a0)
        (match ,r
          [(AstExpr.Unary op1 b0) (and (= op0 op1) (,e ,@x a0 b0))]
          [_ false])]
      [(AstExpr.Call a0 as)
        (match ,r
          [(AstExpr.Call b0 bs)
            (and (,e ,@x a0 b0) (ast-expr-list-eq? as bs ,e ,@x))]
          [_ false])]
      [(AstExpr.If a0 a1 a2)
        (match ,r
          [(AstExpr.If b0 b1 b2)
            (and (,e ,@x a0 b0) (,e ,@x a1 b1) (,e ,@x a2 b2))]
          [_ false])]
      [(AstExpr.Let a-payload)
        (match (__tl-box-place a-payload)
          [(AstLet.Let as a0)
            (match ,r
              [(AstExpr.Let b-payload)
                (match (__tl-box-place b-payload)
                  [(AstLet.Let bs b0)
                    (and
                      (ast-let-binding-list-eq? as bs ,e ,ty ,@x)
                      (,e ,@x a0 b0))])]
              [_ false])])]
      [(AstExpr.Lambda a-payload)
        (match (__tl-box-place a-payload)
          [(AstLambda.Lambda as a-ret a0)
            (match ,r
              [(AstExpr.Lambda b-payload)
                (match (__tl-box-place b-payload)
                  [(AstLambda.Lambda bs b-ret b0)
                    (and
                      (ast-param-list-eq? as bs ,ty ,@x)
                      (ast-maybe-type-eq? a-ret b-ret ,ty ,@x)
                      (,e ,@x a0 b0))])]
              [_ false])])]
      [(AstExpr.Tuple as)
        (match ,r
          [(AstExpr.Tuple bs) (ast-expr-list-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.TupleRef a0 i0)
        (match ,r
          [(AstExpr.TupleRef b0 i1) (and (= i0 i1) (,e ,@x a0 b0))]
          [_ false])]
      [(AstExpr.Array as)
        (match ,r
          [(AstExpr.Array bs) (ast-expr-list-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.DynArray as)
        (match ,r
          [(AstExpr.DynArray bs) (ast-expr-list-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.FixedMakeArray t0 a0)
        (match ,r
          [(AstExpr.FixedMakeArray t1 b0) (and (,ti ,@x t0 t1) (,e ,@x a0 b0))]
          [_ false])]
      [(AstExpr.MakeArray t0 a0)
        (match ,r
          [(AstExpr.MakeArray t1 b0) (and (,ti ,@x t0 t1) (,e ,@x a0 b0))]
          [_ false])]
      [(AstExpr.ArrayRef a0 a1)
        (match ,r
          [(AstExpr.ArrayRef b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.ArraySet a0 a1 a2)
        (match ,r
          [(AstExpr.ArraySet b0 b1 b2)
            (and (,e ,@x a0 b0) (,e ,@x a1 b1) (,e ,@x a2 b2))]
          [_ false])]
      [(AstExpr.ArrayTake a0 a1 a2)
        (match ,r
          [(AstExpr.ArrayTake b0 b1 b2)
            (and (,e ,@x a0 b0) (,e ,@x a1 b1) (,e ,@x a2 b2))]
          [_ false])]
      [(AstExpr.ArrayPush a0 a1)
        (match ,r
          [(AstExpr.ArrayPush b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.StringRef a0 a1)
        (match ,r
          [(AstExpr.StringRef b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.While a0 a1)
        (match ,r
          [(AstExpr.While b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.Begin as)
        (match ,r
          [(AstExpr.Begin bs) (ast-expr-list-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.Unsafe as)
        (match ,r
          [(AstExpr.Unsafe bs) (ast-expr-list-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.Set n0 a0)
        (match ,r
          [(AstExpr.Set n1 b0) (and (= n0 n1) (,e ,@x a0 b0))]
          [_ false])]
      [(AstExpr.Replace a0 a1)
        (match ,r
          [(AstExpr.Replace b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.Ann a0 t0)
        (match ,r
          [(AstExpr.Ann b0 t1) (and (,e ,@x a0 b0) (,ti ,@x t0 t1))]
          [_ false])]
      [(AstExpr.Cast a0 t0)
        (match ,r
          [(AstExpr.Cast b0 t1) (and (,e ,@x a0 b0) (,ti ,@x t0 t1))]
          [_ false])]
      [(AstExpr.Borrow m0 l0 a0)
        (match ,r
          [(AstExpr.Borrow m1 l1 b0)
            (and (= m0 m1) (ast-borrow-lifetime-id-eq? l0 l1) (,e ,@x a0 b0))]
          [_ false])]
      [(AstExpr.Match a-payload)
        (match (__tl-box-place a-payload)
          [(AstMatch.Match a0 as)
            (match ,r
              [(AstExpr.Match b-payload)
                (match (__tl-box-place b-payload)
                  [(AstMatch.Match b0 bs)
                    (and
                      (,e ,@x a0 b0)
                      (ast-match-arm-list-eq? as bs ,e ,on-pattern ,@x))])]
              [_ false])])]
      [(AstExpr.Foreach a-payload)
        (match (__tl-box-place a-payload)
          [(AstForeach.Foreach n0 t0 a0 a1 a2)
            (match ,r
              [(AstExpr.Foreach b-payload)
                (match (__tl-box-place b-payload)
                  [(AstForeach.Foreach n1 t1 b0 b1 b2)
                    (and
                      (= n0 n1)
                      (,ty ,@x t0 t1)
                      (,e ,@x a0 b0)
                      (,e ,@x a1 b1)
                      (,e ,@x a2 b2))])]
              [_ false])])]
      [(AstExpr.SpmdReduce a-payload)
        (match (__tl-box-place a-payload)
          [(AstSpmdReduce.Reduce op0 n0 t0 a0 a1 a2 a3)
            (match ,r
              [(AstExpr.SpmdReduce b-payload)
                (match (__tl-box-place b-payload)
                  [(AstSpmdReduce.Reduce op1 n1 t1 b0 b1 b2 b3)
                    (and
                      (= op0 op1)
                      (= n0 n1)
                      (,ty ,@x t0 t1)
                      (,e ,@x a0 b0)
                      (,e ,@x a1 b1)
                      (,e ,@x a2 b2)
                      (,e ,@x a3 b3))])]
              [_ false])])]
      [(AstExpr.SpmdScan a-payload)
        (match (__tl-box-place a-payload)
          [(AstSpmdScan.Scan op0 n0 t0 a0 a1 p0 u0 a2 a3 a4)
            (match ,r
              [(AstExpr.SpmdScan b-payload)
                (match (__tl-box-place b-payload)
                  [(AstSpmdScan.Scan op1 n1 t1 b0 b1 p1 u1 b2 b3 b4)
                    (and
                      (= op0 op1)
                      (= n0 n1)
                      (,ty ,@x t0 t1)
                      (,e ,@x a0 b0)
                      (,e ,@x a1 b1)
                      (= p0 p1)
                      (,ty ,@x u0 u1)
                      (,e ,@x a2 b2)
                      (,e ,@x a3 b3)
                      (,e ,@x a4 b4))])]
              [_ false])])]
      [(AstExpr.SpmdCompact a-payload)
        (match (__tl-box-place a-payload)
          [(AstSpmdCompact.Compact n0 t0 a0 a1 p0 u0 a2 a3 a4)
            (match ,r
              [(AstExpr.SpmdCompact b-payload)
                (match (__tl-box-place b-payload)
                  [(AstSpmdCompact.Compact n1 t1 b0 b1 p1 u1 b2 b3 b4)
                    (and
                      (= n0 n1)
                      (,ty ,@x t0 t1)
                      (,e ,@x a0 b0)
                      (,e ,@x a1 b1)
                      (= p0 p1)
                      (,ty ,@x u0 u1)
                      (,e ,@x a2 b2)
                      (,e ,@x a3 b3)
                      (,e ,@x a4 b4))])]
              [_ false])])]
      [(AstExpr.SpmdBroadcast a0 a1)
        (match ,r
          [(AstExpr.SpmdBroadcast b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.SpmdShuffle a0 a1)
        (match ,r
          [(AstExpr.SpmdShuffle b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.SpmdProgramIndex)
        (match ,r
          [(AstExpr.SpmdProgramIndex) true]
          [_ false])]
      [(AstExpr.SpmdProgramCount)
        (match ,r
          [(AstExpr.SpmdProgramCount) true]
          [_ false])]
      [(AstExpr.StructGet a0 f0)
        (match ,r
          [(AstExpr.StructGet b0 f1) (and (= f0 f1) (,e ,@x a0 b0))]
          [_ false])]
      [(AstExpr.StructSet a0 f0 a1)
        (match ,r
          [(AstExpr.StructSet b0 f1 b1)
            (and (= f0 f1) (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.WithRegion n0 as)
        (match ,r
          [(AstExpr.WithRegion n1 bs)
            (and (= n0 n1) (ast-expr-list-eq? as bs ,e ,@x))]
          [_ false])]
      [(AstExpr.WithEscape a0 as)
        (match ,r
          [(AstExpr.WithEscape b0 bs)
            (and (,e ,@x a0 b0) (ast-expr-list-eq? as bs ,e ,@x))]
          [_ false])]
      [(AstExpr.WithScratch as)
        (match ,r
          [(AstExpr.WithScratch bs) (ast-expr-list-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.InArena a0 as)
        (match ,r
          [(AstExpr.InArena b0 bs)
            (and (,e ,@x a0 b0) (ast-expr-list-eq? as bs ,e ,@x))]
          [_ false])]
      [(AstExpr.WithResource a-payload)
        (match (__tl-box-place a-payload)
          [(AstWithResource.WithResource a-bindings as)
            (match ,r
              [(AstExpr.WithResource b-payload)
                (match (__tl-box-place b-payload)
                  [(AstWithResource.WithResource b-bindings bs)
                    (and
                      (ast-resource-binding-list-eq?
                        a-bindings
                        b-bindings
                        ,e
                        ,@x)
                      (ast-expr-list-eq? as bs ,e ,@x))])]
              [_ false])])]
      [(AstExpr.Box a0)
        (match ,r
          [(AstExpr.Box b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.BoxGet a0)
        (match ,r
          [(AstExpr.BoxGet b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.BoxTake a0)
        (match ,r
          [(AstExpr.BoxTake b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.BoxSet a0 a1)
        (match ,r
          [(AstExpr.BoxSet b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.TypeLiteral t0)
        (match ,r
          [(AstExpr.TypeLiteral t1) (,ti ,@x t0 t1)]
          [_ false])]
      [(AstExpr.Init t0)
        (match ,r
          [(AstExpr.Init t1)
            (if (< t0 0)
              (< t1 0)
              (and (>= t1 0) (,ti ,@x t0 t1)))]
          [_ false])]
      [(AstExpr.Comptime a0)
        (match ,r
          [(AstExpr.Comptime b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.Quote a0)
        (match ,r
          [(AstExpr.Quote b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.Quasiquote a0)
        (match ,r
          [(AstExpr.Quasiquote b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.Unquote a0)
        (match ,r
          [(AstExpr.Unquote b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.UnquoteSplicing a0)
        (match ,r
          [(AstExpr.UnquoteSplicing b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.BracketClause as)
        (match ,r
          [(AstExpr.BracketClause bs) (ast-expr-list-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.Try a0)
        (match ,r
          [(AstExpr.Try b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.Return a0)
        (match ,r
          [(AstExpr.Return b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.Break)
        (match ,r
          [(AstExpr.Break) true]
          [_ false])]
      [(AstExpr.Continue)
        (match ,r
          [(AstExpr.Continue) true]
          [_ false])]
      [(AstExpr.PtrNull t0)
        (match ,r
          [(AstExpr.PtrNull t1) (,ti ,@x t0 t1)]
          [_ false])]
      [(AstExpr.PtrNullCheck a0)
        (match ,r
          [(AstExpr.PtrNullCheck b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.PtrAddrOf a0)
        (match ,r
          [(AstExpr.PtrAddrOf b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.PtrRead a0)
        (match ,r
          [(AstExpr.PtrRead b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.PtrWrite a0 a1)
        (match ,r
          [(AstExpr.PtrWrite b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.PtrOffset a0 a1)
        (match ,r
          [(AstExpr.PtrOffset b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.PtrCast a0 t0)
        (match ,r
          [(AstExpr.PtrCast b0 t1) (and (,e ,@x a0 b0) (,ti ,@x t0 t1))]
          [_ false])]
      [(AstExpr.PtrToInt a0)
        (match ,r
          [(AstExpr.PtrToInt b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.IntToPtr a0 t0)
        (match ,r
          [(AstExpr.IntToPtr b0 t1) (and (,e ,@x a0 b0) (,ti ,@x t0 t1))]
          [_ false])]
      [(AstExpr.StringData a0)
        (match ,r
          [(AstExpr.StringData b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.StringFromBytes a0 a1)
        (match ,r
          [(AstExpr.StringFromBytes b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.ArrayData a0)
        (match ,r
          [(AstExpr.ArrayData b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.BinaryData a0)
        (match ,r
          [(AstExpr.BinaryData b0) (string.eq a0 b0)]
          [_ false])]
      [(AstExpr.ProgramArgc)
        (match ,r
          [(AstExpr.ProgramArgc) true]
          [_ false])]
      [(AstExpr.ProgramArgv)
        (match ,r
          [(AstExpr.ProgramArgv) true]
          [_ false])]
      [(AstExpr.ProgramEnvp)
        (match ,r
          [(AstExpr.ProgramEnvp) true]
          [_ false])]
      [(AstExpr.CpuIdEax a0 a1)
        (match ,r
          [(AstExpr.CpuIdEax b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.CpuIdEbx a0 a1)
        (match ,r
          [(AstExpr.CpuIdEbx b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.CpuIdEcx a0 a1)
        (match ,r
          [(AstExpr.CpuIdEcx b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.CpuIdEdx a0 a1)
        (match ,r
          [(AstExpr.CpuIdEdx b0 b1) (and (,e ,@x a0 b0) (,e ,@x a1 b1))]
          [_ false])]
      [(AstExpr.Xgetbv a0)
        (match ,r
          [(AstExpr.Xgetbv b0) (,e ,@x a0 b0)]
          [_ false])]
      [(AstExpr.Syscall as)
        (match ,r
          [(AstExpr.Syscall bs) (ast-expr-list-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.ForOwnedState as)
        (match ,r
          [(AstExpr.ForOwnedState bs) (ast-for-owned-slots-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.ForOwnedStep as)
        (match ,r
          [(AstExpr.ForOwnedStep bs) (ast-for-owned-slots-eq? as bs ,e ,@x)]
          [_ false])]
      [(AstExpr.MacroExpansion a0 p0 n0)
        (match ,r
          [(AstExpr.MacroExpansion b0 p1 n1)
            (and (,e ,@x a0 b0) (= p0 p1) (= n0 n1))]
          [_ false])]
      [(AstExpr.ForeachActive n0 a0)
        (match ,r
          [(AstExpr.ForeachActive n1 b0) (and (= n0 n1) (,e ,@x a0 b0))]
          [_ false])]
      [(AstExpr.LaneValue a0)
        (match ,r
          [(AstExpr.LaneValue b0) (,e ,@x a0 b0)]
          [_ false])])))

(define (ast-expr-for-owned? [expr : (& expr AstExpr)]) : bool
  (match expr
    [(AstExpr.ForOwnedState _) true]
    [(AstExpr.ForOwnedStep _) true]
    [_ false]))

;; --- AstType child schema ---
;; The child type ids of each AstType variant, in payload order: Func's
;; argument ids and then its result id, Tuple's element ids, and the single
;; element, inner or signature id of the other composite variants. Nominal
;; names, lifetimes, regions, array lengths and C-function modes are not
;; children. Like the AstExpr schema, each macro expands to a direct match over
;; every variant with no wildcard arm and calls a pass-owned hook with the
;; context expressions first and the child id last.
(defmacro (ast-type-id-list-fold
  [ids : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-type-id : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,ids]
    [acc ,seed]
    [index : i64 0]
    (begin
      (while (< index (ast-type-list-len (& list)))
        (begin
          (set!
            acc
            (,combine
              acc
              (,on-type-id
                ,@contexts
                (ast-type-list-get (& list) index (ast-type-id-fallback)))))
          (set! index (+ index 1))))
      acc)))

(defmacro (ast-type-fold-children
  [ty : Expr]
  [combine : Expr]
  [seed : Expr]
  [on-type-id : Expr]
  [contexts : Expr ...]) : Expr
  (let
    [c : Expr combine]
    [s : Expr seed]
    [t : Expr on-type-id]
    [x : ExprList contexts]
    `(match ,ty
      [(AstType.I64) ,s]
      [(AstType.I32) ,s]
      [(AstType.I16) ,s]
      [(AstType.I8) ,s]
      [(AstType.U64) ,s]
      [(AstType.U32) ,s]
      [(AstType.U16) ,s]
      [(AstType.U8) ,s]
      [(AstType.F64) ,s]
      [(AstType.F32) ,s]
      [(AstType.Bool) ,s]
      [(AstType.Char) ,s]
      [(AstType.String) ,s]
      [(AstType.Str) ,s]
      [(AstType.Bytes) ,s]
      [(AstType.Unit) ,s]
      [(AstType.Never) ,s]
      [(AstType.Expr) ,s]
      [(AstType.ExprList) ,s]
      [(AstType.Func args ret)
        (,c (ast-type-id-list-fold (deref args) ,c ,s ,t ,@x) (,t ,@x ret))]
      [(AstType.Tuple elems) (ast-type-id-list-fold (deref elems) ,c ,s ,t ,@x)]
      [(AstType.Array elem _) (,c ,s (,t ,@x elem))]
      [(AstType.DynArray elem) (,c ,s (,t ,@x elem))]
      [(AstType.Box elem) (,c ,s (,t ,@x elem))]
      [(AstType.Ptr elem) (,c ,s (,t ,@x elem))]
      [(AstType.MutPtr elem) (,c ,s (,t ,@x elem))]
      [(AstType.Slice elem) (,c ,s (,t ,@x elem))]
      [(AstType.Region _ inner) (,c ,s (,t ,@x inner))]
      [(AstType.Ref _ inner) (,c ,s (,t ,@x inner))]
      [(AstType.MutRef _ inner) (,c ,s (,t ,@x inner))]
      [(AstType.Enum _) ,s]
      [(AstType.Struct _) ,s]
      [(AstType.Var _) ,s]
      [(AstType.EnumArgs _ _) ,s]
      [(AstType.StructArgs _ _) ,s]
      [(AstType.VarArgs _ _) ,s]
      [(AstType.CFunc signature _) (,c ,s (,t ,@x signature))]
      [(AstType.Invalidate _ inner) (,c ,s (,t ,@x inner))])))

(defmacro (ast-type-for-each-child
  [ty : Expr]
  [on-type-id : Expr]
  [contexts : Expr ...]) : unit
  `(ast-type-fold-children ,ty ast-fold-seq unit ,on-type-id ,@contexts))

;; `ast-type-map-children` rebuilds the node with each child id replaced by its
;; hook's result, in payload order, and copies the lifetime lists.
(defmacro (ast-type-id-list-map
  [ids : Expr]
  [on-type-id : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [list ,ids]
    [out (ast-type-list-with-capacity (ast-type-list-len (& list)))]
    [index : i64 0]
    (begin
      (while (< index (ast-type-list-len (& list)))
        (begin
          (ast-type-list-push
            (&mut out)
            (,on-type-id
              ,@contexts
              (ast-type-list-get (& list) index (ast-type-id-fallback))))
          (set! index (+ index 1))))
      out)))

(defmacro (ast-type-map-children
  [ty : Expr]
  [on-type-id : Expr]
  [contexts : Expr ...]) : AstType
  (let
    [t : Expr on-type-id]
    [x : ExprList contexts]
    `(match ,ty
      [(AstType.I64) (AstType.I64)]
      [(AstType.I32) (AstType.I32)]
      [(AstType.I16) (AstType.I16)]
      [(AstType.I8) (AstType.I8)]
      [(AstType.U64) (AstType.U64)]
      [(AstType.U32) (AstType.U32)]
      [(AstType.U16) (AstType.U16)]
      [(AstType.U8) (AstType.U8)]
      [(AstType.F64) (AstType.F64)]
      [(AstType.F32) (AstType.F32)]
      [(AstType.Bool) (AstType.Bool)]
      [(AstType.Char) (AstType.Char)]
      [(AstType.String) (AstType.String)]
      [(AstType.Str) (AstType.Str)]
      [(AstType.Bytes) (AstType.Bytes)]
      [(AstType.Unit) (AstType.Unit)]
      [(AstType.Never) (AstType.Never)]
      [(AstType.Expr) (AstType.Expr)]
      [(AstType.ExprList) (AstType.ExprList)]
      [(AstType.Func args ret)
        (AstType.Func
          (box (ast-type-id-list-map (deref args) ,t ,@x))
          (,t ,@x ret))]
      [(AstType.Tuple elems)
        (AstType.Tuple (box (ast-type-id-list-map (deref elems) ,t ,@x)))]
      [(AstType.Array elem count) (AstType.Array (,t ,@x elem) count)]
      [(AstType.DynArray elem) (AstType.DynArray (,t ,@x elem))]
      [(AstType.Box elem) (AstType.Box (,t ,@x elem))]
      [(AstType.Ptr elem) (AstType.Ptr (,t ,@x elem))]
      [(AstType.MutPtr elem) (AstType.MutPtr (,t ,@x elem))]
      [(AstType.Slice elem) (AstType.Slice (,t ,@x elem))]
      [(AstType.Region name inner) (AstType.Region name (,t ,@x inner))]
      [(AstType.Ref name inner) (AstType.Ref name (,t ,@x inner))]
      [(AstType.MutRef name inner) (AstType.MutRef name (,t ,@x inner))]
      [(AstType.Enum name) (AstType.Enum name)]
      [(AstType.Struct name) (AstType.Struct name)]
      [(AstType.Var name) (AstType.Var name)]
      [(AstType.EnumArgs name lifetimes)
        (AstType.EnumArgs name (box (ast-lifetime-list-copy (deref lifetimes))))]
      [(AstType.StructArgs name lifetimes)
        (AstType.StructArgs
          name
          (box (ast-lifetime-list-copy (deref lifetimes))))]
      [(AstType.VarArgs name lifetimes)
        (AstType.VarArgs name (box (ast-lifetime-list-copy (deref lifetimes))))]
      [(AstType.CFunc signature mode) (AstType.CFunc (,t ,@x signature) mode)]
      [(AstType.Invalidate name inner) (AstType.Invalidate name (,t ,@x inner))])))

;; `ast-type-children-eq?` is structural equality of two nodes: the same
;; variant, equal non-child payloads, and child ids equal pairwise by the hook.
(defmacro (ast-type-id-list-eq?
  [left : Expr]
  [right : Expr]
  [on-type-id : Expr]
  [contexts : Expr ...]) : Expr
  `(let
    [a ,left]
    [b ,right]
    [same : bool (= (ast-type-list-len (& a)) (ast-type-list-len (& b)))]
    [index : i64 0]
    (begin
      (while (and same (< index (ast-type-list-len (& a))))
        (begin
          (set!
            same
            (,on-type-id
              ,@contexts
              (ast-type-list-get (& a) index (ast-type-id-fallback))
              (ast-type-list-get (& b) index (ast-type-id-fallback))))
          (set! index (+ index 1))))
      same)))

(defmacro (ast-type-children-eq?
  [left : Expr]
  [right : Expr]
  [on-type-id : Expr]
  [contexts : Expr ...]) : bool
  (let
    [r : Expr right]
    [t : Expr on-type-id]
    [x : ExprList contexts]
    `(match ,left
      [(AstType.I64)
        (match ,r
          [(AstType.I64) true]
          [_ false])]
      [(AstType.I32)
        (match ,r
          [(AstType.I32) true]
          [_ false])]
      [(AstType.I16)
        (match ,r
          [(AstType.I16) true]
          [_ false])]
      [(AstType.I8)
        (match ,r
          [(AstType.I8) true]
          [_ false])]
      [(AstType.U64)
        (match ,r
          [(AstType.U64) true]
          [_ false])]
      [(AstType.U32)
        (match ,r
          [(AstType.U32) true]
          [_ false])]
      [(AstType.U16)
        (match ,r
          [(AstType.U16) true]
          [_ false])]
      [(AstType.U8)
        (match ,r
          [(AstType.U8) true]
          [_ false])]
      [(AstType.F64)
        (match ,r
          [(AstType.F64) true]
          [_ false])]
      [(AstType.F32)
        (match ,r
          [(AstType.F32) true]
          [_ false])]
      [(AstType.Bool)
        (match ,r
          [(AstType.Bool) true]
          [_ false])]
      [(AstType.Char)
        (match ,r
          [(AstType.Char) true]
          [_ false])]
      [(AstType.String)
        (match ,r
          [(AstType.String) true]
          [_ false])]
      [(AstType.Str)
        (match ,r
          [(AstType.Str) true]
          [_ false])]
      [(AstType.Bytes)
        (match ,r
          [(AstType.Bytes) true]
          [_ false])]
      [(AstType.Unit)
        (match ,r
          [(AstType.Unit) true]
          [_ false])]
      [(AstType.Never)
        (match ,r
          [(AstType.Never) true]
          [_ false])]
      [(AstType.Expr)
        (match ,r
          [(AstType.Expr) true]
          [_ false])]
      [(AstType.ExprList)
        (match ,r
          [(AstType.ExprList) true]
          [_ false])]
      [(AstType.Func a-args a-ret)
        (match ,r
          [(AstType.Func b-args b-ret)
            (and
              (ast-type-id-list-eq? (deref a-args) (deref b-args) ,t ,@x)
              (,t ,@x a-ret b-ret))]
          [_ false])]
      [(AstType.Tuple a-elems)
        (match ,r
          [(AstType.Tuple b-elems)
            (ast-type-id-list-eq? (deref a-elems) (deref b-elems) ,t ,@x)]
          [_ false])]
      [(AstType.Array a-elem a-count)
        (match ,r
          [(AstType.Array b-elem b-count)
            (and (= a-count b-count) (,t ,@x a-elem b-elem))]
          [_ false])]
      [(AstType.DynArray a-elem)
        (match ,r
          [(AstType.DynArray b-elem) (,t ,@x a-elem b-elem)]
          [_ false])]
      [(AstType.Box a-elem)
        (match ,r
          [(AstType.Box b-elem) (,t ,@x a-elem b-elem)]
          [_ false])]
      [(AstType.Ptr a-elem)
        (match ,r
          [(AstType.Ptr b-elem) (,t ,@x a-elem b-elem)]
          [_ false])]
      [(AstType.MutPtr a-elem)
        (match ,r
          [(AstType.MutPtr b-elem) (,t ,@x a-elem b-elem)]
          [_ false])]
      [(AstType.Slice a-elem)
        (match ,r
          [(AstType.Slice b-elem) (,t ,@x a-elem b-elem)]
          [_ false])]
      [(AstType.Region a-name a-inner)
        (match ,r
          [(AstType.Region b-name b-inner)
            (and (= a-name b-name) (,t ,@x a-inner b-inner))]
          [_ false])]
      [(AstType.Ref a-name a-inner)
        (match ,r
          [(AstType.Ref b-name b-inner)
            (and (= a-name b-name) (,t ,@x a-inner b-inner))]
          [_ false])]
      [(AstType.MutRef a-name a-inner)
        (match ,r
          [(AstType.MutRef b-name b-inner)
            (and (= a-name b-name) (,t ,@x a-inner b-inner))]
          [_ false])]
      [(AstType.Enum a-name)
        (match ,r
          [(AstType.Enum b-name) (= a-name b-name)]
          [_ false])]
      [(AstType.Struct a-name)
        (match ,r
          [(AstType.Struct b-name) (= a-name b-name)]
          [_ false])]
      [(AstType.Var a-name)
        (match ,r
          [(AstType.Var b-name) (= a-name b-name)]
          [_ false])]
      [(AstType.EnumArgs a-name a-lifetimes)
        (match ,r
          [(AstType.EnumArgs b-name b-lifetimes)
            (and
              (= a-name b-name)
              (ast-lifetime-list-eq? (deref a-lifetimes) (deref b-lifetimes)))]
          [_ false])]
      [(AstType.StructArgs a-name a-lifetimes)
        (match ,r
          [(AstType.StructArgs b-name b-lifetimes)
            (and
              (= a-name b-name)
              (ast-lifetime-list-eq? (deref a-lifetimes) (deref b-lifetimes)))]
          [_ false])]
      [(AstType.VarArgs a-name a-lifetimes)
        (match ,r
          [(AstType.VarArgs b-name b-lifetimes)
            (and
              (= a-name b-name)
              (ast-lifetime-list-eq? (deref a-lifetimes) (deref b-lifetimes)))]
          [_ false])]
      [(AstType.CFunc a-signature a-mode)
        (match ,r
          [(AstType.CFunc b-signature b-mode)
            (and
              (ast-c-function-mode-eq? a-mode b-mode)
              (,t ,@x a-signature b-signature))]
          [_ false])]
      [(AstType.Invalidate a-name a-inner)
        (match ,r
          [(AstType.Invalidate b-name b-inner)
            (and (= a-name b-name) (,t ,@x a-inner b-inner))]
          [_ false])])))

;; Hooks: child ids compare equal as ids (hash-consed pools), or by structure
;; through the installed reader or a hoisted segment-bases token.
(defmacro (ast-type-id-same? [a : Expr] [b : Expr]) : Expr
  `(= ,a ,b))

(defmacro (ast-type-installed-ids-eq? [a : Expr] [b : Expr]) : Expr
  `(ast-type-eq?
    (ast-node-pool-reader-type-get ,a)
    (ast-node-pool-reader-type-get ,b)))

(defmacro (ast-type-seg-ids-eq? [seg-bases : Expr] [a : Expr] [b : Expr]) : Expr
  `(ast-type-eq-with-seg-bases?
    ,seg-bases
    (ast-type-segment-bases-get ,seg-bases ,a)
    (ast-type-segment-bases-get ,seg-bases ,b)))

(define (ast-expr-for-owned-state
  [source-name : i64]
  [index-name : i64]
  [source : i64]
  [body : i64]) : i64
  (ast-node-push
    (AstExpr.ForOwnedState
      (ast-for-owned-state-payload source-name index-name source body))))

(define (ast-expr-for-owned-step
  [source-name : i64]
  [index-name : i64]
  [binding-name : i64]
  [expected-type : i64]
  [done-name : i64]
  [body : i64]) : i64
  (ast-node-push
    (AstExpr.ForOwnedStep
      (ast-for-owned-step-payload
        source-name
        index-name
        binding-name
        expected-type
        done-name
        body))))

(define (ast-expr-set-id [name : i64] [value : i64]) : i64
  (ast-node-push (AstExpr.Set name value)))

(define (ast-expr-ann-id [expr : i64] [ty-id : i64]) : i64
  (ast-node-push (AstExpr.Ann expr ty-id)))

(define (ast-expr-cast [expr : i64] [ty : AstType]) : i64
  (ast-node-push (AstExpr.Cast expr (ty-node-push ty))))

(define (ast-expr-cast-id [expr : i64] [ty-id : i64]) : i64
  (ast-node-push (AstExpr.Cast expr ty-id)))

(define (ast-expr-borrow
  [mutable : bool]
  [lifetime : AstBorrowLifetime]
  [expr : i64]) : i64
  (ast-node-push
    (AstExpr.Borrow mutable (ast-borrow-lifetime-to-id lifetime) expr)))

(define (ast-expr-borrow-id [mutable : bool] [lifetime-id : i64] [expr : i64]) : i64
  (ast-node-push (AstExpr.Borrow mutable lifetime-id expr)))

(define (ast-expr-match [scrutinee : i64] [arms : AstMatchArmList]) : i64
  (ast-node-push (AstExpr.Match (box (AstMatch.Match scrutinee arms)))))

(define (ast-expr-foreach-id
  [name : i64]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [body : i64]) : i64
  (ast-node-push
    (AstExpr.Foreach (box (AstForeach.Foreach name index-ty start end body)))))

(define (ast-expr-spmd-program-index) : i64
  (ast-node-push (AstExpr.SpmdProgramIndex)))

(define (ast-expr-spmd-program-count) : i64
  (ast-node-push (AstExpr.SpmdProgramCount)))

(define (ast-expr-struct-get-id [target : i64] [field : i64]) : i64
  (ast-node-push (AstExpr.StructGet target field)))

(define (ast-expr-struct-set-id [target : i64] [field : i64] [value : i64]) : i64
  (ast-node-push (AstExpr.StructSet target field value)))

(define (ast-expr-unquote-set-target-field-id) : i64
  cbi.compiler-builtin-id-fix-tl_unquote_set_target)

(define (ast-expr-with-escape [escape : i64] [body : AstExprList]) : i64
  (ast-node-push (AstExpr.WithEscape escape body)))

(define (ast-expr-with-scratch [body : AstExprList]) : i64
  (ast-node-push (AstExpr.WithScratch body)))

(define (ast-expr-in-arena [arena : i64] [body : AstExprList]) : i64
  (ast-node-push (AstExpr.InArena arena body)))

(define (ast-expr-box [value : i64]) : i64
  (ast-node-push (AstExpr.Box value)))

(define (ast-expr-box-get [value : i64]) : i64
  (ast-node-push (AstExpr.BoxGet value)))

(define (ast-expr-box-take [value : i64]) : i64
  (ast-node-push (AstExpr.BoxTake value)))

(define (ast-expr-box-set [target : i64] [value : i64]) : i64
  (ast-node-push (AstExpr.BoxSet target value)))

;: Intern a maybe-type into the installed type pool, `-1` for absent.
(define (ast-maybe-type-to-id [maybe-ty : AstMaybeType]) : i64
  (match maybe-ty
    [(AstMaybeType.No) ast-maybe-type-id-absent]
    [(AstMaybeType.Some ty) (ty-node-push ty)]))

(define (ast-maybe-type-from-id [id : i64]) : AstMaybeType
  (if (< id 0)
    (AstMaybeType.No)
    (AstMaybeType.Some (ty-node-get id))))

(define (ast-maybe-type-to-id-with-pools
  [pools : AstNodePoolContext]
  [maybe-ty : AstMaybeType]) : i64
  (match maybe-ty
    [(AstMaybeType.No) ast-maybe-type-id-absent]
    [(AstMaybeType.Some ty) (ast-node-pool-context-type-push pools ty)]))

(define (ast-maybe-type-from-id-with-pools
  [pools : AstNodePoolContext]
  [id : i64]) : AstMaybeType
  (if (< id 0)
    (AstMaybeType.No)
    (AstMaybeType.Some (ast-node-pool-context-type-get pools id))))

(define (ast-expr-init-maybe [maybe-ty : AstMaybeType]) : i64
  (ast-node-push (AstExpr.Init (ast-maybe-type-to-id maybe-ty))))

(define (ast-expr-init [ty : AstType]) : i64
  (ast-expr-init-maybe (AstMaybeType.Some ty)))

(define (ast-expr-comptime [inner : i64]) : i64
  (ast-node-push (AstExpr.Comptime inner)))

(define (ast-expr-return [inner : i64]) : i64
  (ast-node-push (AstExpr.Return inner)))

(define (ast-expr-ptr-null-check [ptr : i64]) : i64
  (ast-node-push (AstExpr.PtrNullCheck ptr)))

(define (ast-expr-ptr-addr-of-id [place : i64]) : i64
  (ast-node-push (AstExpr.PtrAddrOf place)))

(define (ast-expr-ptr-read [ptr : i64]) : i64
  (ast-node-push (AstExpr.PtrRead ptr)))

(define (ast-expr-ptr-write [ptr : i64] [value : i64]) : i64
  (ast-node-push (AstExpr.PtrWrite ptr value)))

(define (ast-expr-ptr-offset [ptr : i64] [offset : i64]) : i64
  (ast-node-push (AstExpr.PtrOffset ptr offset)))

(define (ast-expr-ptr-cast-id [ptr : i64] [ty-id : i64]) : i64
  (ast-node-push (AstExpr.PtrCast ptr ty-id)))

(define (ast-expr-ptr-to-int [ptr : i64]) : i64
  (ast-node-push (AstExpr.PtrToInt ptr)))

(define (ast-expr-int-to-ptr-id [value : i64] [ty-id : i64]) : i64
  (ast-node-push (AstExpr.IntToPtr value ty-id)))

(define (ast-expr-string-data [value : i64]) : i64
  (ast-node-push (AstExpr.StringData value)))

(define (ast-expr-string-from-bytes [data : i64] [len : i64]) : i64
  (ast-node-push (AstExpr.StringFromBytes data len)))

(define (ast-expr-array-data [value : i64]) : i64
  (ast-node-push (AstExpr.ArrayData value)))

(define (ast-expr-cpuid-eax [leaf : i64] [subleaf : i64]) : i64
  (ast-node-push (AstExpr.CpuIdEax leaf subleaf)))

(define (ast-expr-cpuid-ebx [leaf : i64] [subleaf : i64]) : i64
  (ast-node-push (AstExpr.CpuIdEbx leaf subleaf)))

(define (ast-expr-cpuid-ecx [leaf : i64] [subleaf : i64]) : i64
  (ast-node-push (AstExpr.CpuIdEcx leaf subleaf)))

(define (ast-expr-cpuid-edx [leaf : i64] [subleaf : i64]) : i64
  (ast-node-push (AstExpr.CpuIdEdx leaf subleaf)))

(define (ast-expr-xgetbv [index : i64]) : i64
  (ast-node-push (AstExpr.Xgetbv index)))

(define (ast-expr-syscall [args : AstExprList]) : i64
  (ast-node-push (AstExpr.Syscall args)))

(define (ast-expr-spanned-with-pools
  [pools : (& pools AstNodePoolContext)]
  [inner : i64]
  [span : AstSourceSpan]) : i64
  (ast-node-pool-context-expr-push-borrowed pools (AstExpr.Spanned inner span)))

;; Transitional per-use source view.  The legacy wrapper remains observable for
;; #6329's dual-read migration, while the pool push records either the first
;; canonical span or a sparse ReSpan without changing the semantic node's
;; canonical provenance.
(define (ast-expr-source-view-with-pools
  [pools : AstNodePoolContext]
  [inner : i64]
  [span : AstSourceSpan]) : i64
  (ast-expr-spanned-with-pools pools inner span))

(define (ast-expr-binary-with-pools
  [pools : AstNodePoolContext]
  [op : AstBinOp]
  [left : i64]
  [right : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed
    (& pools)
    (AstExpr.Binary op left right)))

(define (ast-expr-unary-with-pools
  [pools : AstNodePoolContext]
  [op : AstUnOp]
  [inner : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed (& pools) (AstExpr.Unary op inner)))

(define (ast-expr-call-with-pools
  [pools : AstNodePoolContext]
  [callee : i64]
  [args : AstExprList]) : i64
  (ast-node-pool-context-expr-push-borrowed
    (& pools)
    (AstExpr.Call callee args)))

(define (ast-expr-bracket-clause-with-pools
  [pools : AstNodePoolContext]
  [items : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.BracketClause items)))

(define (ast-expr-if-with-pools
  [pools : AstNodePoolContext]
  [cond : i64]
  [then-expr : i64]
  [else-expr : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed
    (& pools)
    (AstExpr.If cond then-expr else-expr)))

(define (ast-expr-let-with-pools
  [pools : AstNodePoolContext]
  [bindings : AstLetBindingList]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push-cells
    (ast-pool-cell-data pools.expr-pool)
    (ast-pool-cell-data pools.type-pool)
    (AstExpr.Let (box (AstLet.Let bindings body)))))

(define (ast-expr-lambda-with-pools
  [pools : AstNodePoolContext]
  [params : AstParamList]
  [ret : AstMaybeType]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.Lambda (box (AstLambda.Lambda params ret body)))))

(define (ast-expr-tuple-ref-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [index : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.TupleRef target index)))

(define (ast-expr-make-array-with-pools
  [pools : AstNodePoolContext]
  [elem : AstType]
  [size : i64]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.MakeArray (ast-node-pool-context-type-push pools elem) size)))

(define (ast-expr-fixed-make-array-with-pools
  [pools : AstNodePoolContext]
  [elem : AstType]
  [size : i64]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.FixedMakeArray (ast-node-pool-context-type-push pools elem) size)))

(define (ast-expr-make-array-with-cells
  [expr-cell-address : u64]
  [type-cell-address : u64]
  [elem : AstType]
  [size : i64]) : i64
  (ast-node-pool-context-expr-push-cells
    expr-cell-address
    type-cell-address
    (AstExpr.MakeArray
      (ast-node-pool-context-type-push-cells
        expr-cell-address
        type-cell-address
        elem)
      size)))

(define (ast-expr-type-literal-with-pools
  [pools : AstNodePoolContext]
  [ty : AstType]) : i64
  (let
    [ty-id : i64 (ast-node-pool-context-type-push pools ty)]
    (ast-node-pool-context-expr-push pools (AstExpr.TypeLiteral ty-id))))

(define (ast-expr-dyn-array-with-pools
  [pools : AstNodePoolContext]
  [items : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.DynArray items)))

(define (ast-expr-array-ref-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [index : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed
    (& pools)
    (AstExpr.ArrayRef target index)))

(define (ast-expr-array-set-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [index : i64]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.ArraySet target index value)))

(define (ast-expr-array-take-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [live : i64]
  [index : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.ArrayTake target live index)))

(define (ast-expr-replace-with-pools
  [pools : AstNodePoolContext]
  [place : i64]
  [replacement : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Replace place replacement)))

(define (ast-expr-array-push-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.ArrayPush target value)))

(define (ast-expr-string-ref-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [index : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.StringRef target index)))

(define (ast-expr-while-with-pools
  [pools : AstNodePoolContext]
  [cond : i64]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed (& pools) (AstExpr.While cond body)))

(define (ast-expr-for-owned-state-with-pools
  [pools : AstNodePoolContext]
  [source-name : i64]
  [index-name : i64]
  [source : i64]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed
    (& pools)
    (AstExpr.ForOwnedState
      (ast-for-owned-state-payload source-name index-name source body))))

(define (ast-expr-for-owned-step-with-pools
  [pools : AstNodePoolContext]
  [source-name : i64]
  [index-name : i64]
  [binding-name : i64]
  [expected-type : i64]
  [done-name : i64]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed
    (& pools)
    (AstExpr.ForOwnedStep
      (ast-for-owned-step-payload
        source-name
        index-name
        binding-name
        expected-type
        done-name
        body))))

(define (ast-expr-set-id-with-pools
  [pools : AstNodePoolContext]
  [name : i64]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed (& pools) (AstExpr.Set name value)))

(define (ast-expr-ann-with-pools
  [pools : AstNodePoolContext]
  [expr : i64]
  [ty : AstType]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.Ann expr (ast-node-pool-context-type-push pools ty))))

(define (ast-expr-ann-with-pools-id
  [pools : AstNodePoolContext]
  [expr : i64]
  [ty-id : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Ann expr ty-id)))

(define (ast-expr-cast-with-pools
  [pools : AstNodePoolContext]
  [expr : i64]
  [ty : AstType]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.Cast expr (ast-node-pool-context-type-push pools ty))))

(define (ast-expr-cast-with-pools-id
  [pools : AstNodePoolContext]
  [expr : i64]
  [ty-id : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Cast expr ty-id)))

(define (ast-expr-borrow-with-pools
  [pools : AstNodePoolContext]
  [mutable : bool]
  [lifetime : AstBorrowLifetime]
  [expr : i64]) : i64
  (ast-node-pool-context-expr-push-borrowed
    (& pools)
    (AstExpr.Borrow mutable (ast-borrow-lifetime-to-id lifetime) expr)))

(define (ast-expr-match-with-pools
  [pools : AstNodePoolContext]
  [scrutinee : i64]
  [arms : AstMatchArmList]) : i64
  (ast-node-pool-context-expr-push-borrowed
    (& pools)
    (AstExpr.Match (box (AstMatch.Match scrutinee arms)))))

(define (ast-expr-foreach-id-with-pools
  [pools : AstNodePoolContext]
  [name : i64]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.Foreach (box (AstForeach.Foreach name index-ty start end body)))))

(define (ast-expr-spmd-reduce-id-with-pools
  [pools : AstNodePoolContext]
  [op : AstReduceOp]
  [name : i64]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [init : i64]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.SpmdReduce
      (box (AstSpmdReduce.Reduce op name index-ty start end init value)))))

(define (ast-expr-spmd-scan-id-with-pools
  [pools : AstNodePoolContext]
  [op : AstReduceOp]
  [index : i64]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [prefix : i64]
  [prefix-ty : AstType]
  [init : i64]
  [value : i64]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.SpmdScan
      (box
        (AstSpmdScan.Scan
          op
          index
          index-ty
          start
          end
          prefix
          prefix-ty
          init
          value
          body)))))

(define (ast-expr-spmd-compact-id-with-pools
  [pools : AstNodePoolContext]
  [index : i64]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [slot : i64]
  [slot-ty : AstType]
  [init : i64]
  [keep : i64]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.SpmdCompact
      (box
        (AstSpmdCompact.Compact
          index
          index-ty
          start
          end
          slot
          slot-ty
          init
          keep
          body)))))

(define (ast-expr-spmd-broadcast-with-pools
  [pools : AstNodePoolContext]
  [value : i64]
  [lane : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.SpmdBroadcast value lane)))

(define (ast-expr-spmd-shuffle-with-pools
  [pools : AstNodePoolContext]
  [value : i64]
  [lane : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.SpmdShuffle value lane)))

(define (ast-expr-spmd-program-index-with-pools [pools : AstNodePoolContext]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.SpmdProgramIndex)))

(define (ast-expr-spmd-program-count-with-pools [pools : AstNodePoolContext]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.SpmdProgramCount)))

(define (ast-expr-foreach-active-with-pools
  [pools : AstNodePoolContext]
  [lane : i64]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.ForeachActive lane body)))

(define (ast-expr-lane-value-with-pools
  [pools : AstNodePoolContext]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.LaneValue value)))

(define (ast-expr-struct-get-id-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [field : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.StructGet target field)))

(define (ast-expr-struct-set-id-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [field : i64]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.StructSet target field value)))

(define (ast-expr-with-escape-with-pools
  [pools : AstNodePoolContext]
  [escape : i64]
  [body : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.WithEscape escape body)))

(define (ast-expr-with-scratch-with-pools
  [pools : AstNodePoolContext]
  [body : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.WithScratch body)))

(define (ast-expr-in-arena-with-pools
  [pools : AstNodePoolContext]
  [arena : i64]
  [body : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.InArena arena body)))

(define (ast-expr-box-with-pools [pools : AstNodePoolContext] [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Box value)))

(define (ast-expr-box-get-with-pools [pools : AstNodePoolContext] [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.BoxGet value)))

(define (ast-expr-box-take-with-pools
  [pools : AstNodePoolContext]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.BoxTake value)))

(define (ast-expr-box-set-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.BoxSet target value)))

(define (ast-expr-init-maybe-with-pools
  [pools : AstNodePoolContext]
  [maybe-ty : AstMaybeType]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.Init (ast-maybe-type-to-id-with-pools pools maybe-ty))))

(define (ast-expr-init-with-pools [pools : AstNodePoolContext] [ty : AstType]) : i64
  (ast-expr-init-maybe-with-pools pools (AstMaybeType.Some ty)))

(define (ast-expr-init-contextual-with-pools [pools : AstNodePoolContext]) : i64
  (ast-expr-init-maybe-with-pools pools AstMaybeType.No))

(define (ast-expr-comptime-with-pools
  [pools : AstNodePoolContext]
  [inner : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Comptime inner)))

(define (ast-expr-quote-with-pools [pools : AstNodePoolContext] [inner : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Quote inner)))

(define (ast-expr-quasiquote-with-pools
  [pools : AstNodePoolContext]
  [inner : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Quasiquote inner)))

(define (ast-expr-unquote-with-pools [pools : AstNodePoolContext] [inner : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Unquote inner)))

(define (ast-expr-unquote-splicing-with-pools
  [pools : AstNodePoolContext]
  [inner : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.UnquoteSplicing inner)))

(define (ast-expr-try-with-pools [pools : AstNodePoolContext] [inner : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Try inner)))

(define (ast-expr-return-with-pools [pools : AstNodePoolContext] [inner : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Return inner)))

(define (ast-expr-break-with-pools [pools : AstNodePoolContext]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Break)))

(define (ast-expr-continue-with-pools [pools : AstNodePoolContext]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Continue)))

(define (ast-expr-ptr-null-check-with-pools
  [pools : AstNodePoolContext]
  [ptr : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.PtrNullCheck ptr)))

(define (ast-expr-ptr-addr-of-id-with-pools
  [pools : AstNodePoolContext]
  [place : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.PtrAddrOf place)))

(define (ast-expr-ptr-read-with-pools [pools : AstNodePoolContext] [ptr : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.PtrRead ptr)))

(define (ast-expr-ptr-write-with-pools
  [pools : AstNodePoolContext]
  [ptr : i64]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.PtrWrite ptr value)))

(define (ast-expr-ptr-offset-with-pools
  [pools : AstNodePoolContext]
  [ptr : i64]
  [offset : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.PtrOffset ptr offset)))

(define (ast-expr-ptr-cast-with-pools
  [pools : AstNodePoolContext]
  [ptr : i64]
  [ty : AstType]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.PtrCast ptr (ast-node-pool-context-type-push pools ty))))

(define (ast-expr-ptr-to-int-with-pools
  [pools : AstNodePoolContext]
  [ptr : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.PtrToInt ptr)))

(define (ast-expr-int-to-ptr-with-pools
  [pools : AstNodePoolContext]
  [value : i64]
  [ty : AstType]) : i64
  (ast-node-pool-context-expr-push
    pools
    (AstExpr.IntToPtr value (ast-node-pool-context-type-push pools ty))))

(define (ast-expr-string-data-with-pools
  [pools : AstNodePoolContext]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.StringData value)))

(define (ast-expr-string-from-bytes-with-pools
  [pools : AstNodePoolContext]
  [data : i64]
  [len : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.StringFromBytes data len)))

(define (ast-expr-array-data-with-pools
  [pools : AstNodePoolContext]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.ArrayData value)))

(define (ast-expr-cpuid-eax-with-pools
  [pools : AstNodePoolContext]
  [leaf : i64]
  [subleaf : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.CpuIdEax leaf subleaf)))

(define (ast-expr-cpuid-ebx-with-pools
  [pools : AstNodePoolContext]
  [leaf : i64]
  [subleaf : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.CpuIdEbx leaf subleaf)))

(define (ast-expr-cpuid-ecx-with-pools
  [pools : AstNodePoolContext]
  [leaf : i64]
  [subleaf : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.CpuIdEcx leaf subleaf)))

(define (ast-expr-cpuid-edx-with-pools
  [pools : AstNodePoolContext]
  [leaf : i64]
  [subleaf : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.CpuIdEdx leaf subleaf)))

(define (ast-expr-xgetbv-with-pools [pools : AstNodePoolContext] [index : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Xgetbv index)))

(define (ast-expr-syscall-with-pools
  [pools : AstNodePoolContext]
  [args : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Syscall args)))

(define (ast-dispatch-variant-fallback) : AstDispatchVariant
  (AstDispatchVariant.Variant (AstDispatchIsa.Scalar) 0))

(dense_list.compiler-dense-list-operations
  AstDispatchVariant
  AstDispatchVariantList
  ast-dispatch-variant-list
  caller-provided-fallback
  minimum-one
  compiler-dense-list-unused-shared-zero-storage
  len
  empty?)

(define (ast-decl-fallback) : AstDecl
  (AstDecl.Module cbi.compiler-builtin-id-fix-lt_ast_decl_list_fallback_gt))

;; Synthetic declaration helpers may still need a neutral source-span value;
;; this does not imply storage alongside every AstDeclList element.
(define (ast-decl-span-fallback) : AstSourceSpan
  (ast-source-span 0 0 0 0))

(define (ast-decl-list-with-capacity [capacity : i64]) : AstDeclList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstDeclList (__tl_make-array AstDecl cap) 0 0 true)))

(define (ast-decl-list-new) : AstDeclList
  (ast-decl-list-with-capacity 4))

(define (ast-decl-list-len [v : (& v AstDeclList)]) : i64
  v.len)

(define (ast-decl-list-get
  [v : (& v AstDeclList)]
  [index : i64]
  [fallback : AstDecl]) : AstDecl
  (if (and (>= index 0) (< index (ast-decl-list-len v)))
    (array-ref v.slots (+ v.offset index))
    fallback))

(define (ast-decl-list-ref [v : (& v AstDeclList)] [index : i64]) : AstDecl
  (let
    [list : AstDeclList (owned_view.compiler-owned-reference-shared-view v)]
    (array-ref list.slots (+ list.offset index))))

(define (ast-decl-list-ref-borrowed [v : (& v AstDeclList)] [index : i64]) : (&
    v
    AstDecl)
  (& (array-ref v.slots (+ v.offset index))))

;; Field-selective declaration readers.
;;
;; `ast-decl-list-step` emulates a cons cell over what is already a flat array
;; slice: each step copies the whole 104 B `AstDecl` row AND writes a 144 B
;; `AstDeclListStep` through the SRET pointer, to deliver values whose consumers
;; read a tag plus at most one or two ids. The readers below let a scan walk
;; `(decls, index)` and touch only the tag word, re-reading the row by value
;; only on the arm that actually consumes a payload -- where the read is an
;; inline projection, so a scalar-only arm loads the field directly instead of
;; copying the row. The list layout is unchanged and `ast-decl-list-step` stays
;; for callers that genuinely need the record.
;; Module id of a module marker at `index`, or `fallback` for any other
;; declaration. The match scrutinee is an element projection, so only the tag
;; and the id word are loaded.
(define (ast-decl-list-module-id-at
  [v : (& v AstDeclList)]
  [index : i64]
  [fallback : i64]) : i64
  (match (array-ref v.slots (+ v.offset index))
    [(AstDecl.Module name) name]
    [_ fallback]))

(define (ast-decl-list-copy-range
  [dst : (&mut dst (__tl_dyn-array AstDecl))]
  [src : (& src (__tl_dyn-array AstDecl))]
  [src-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src (+ src-offset index)))
      (ast-decl-list-copy-range dst src src-offset (+ index 1) count))))

(define (ast-decl-list-copy-to
  [dst : (&mut dst (__tl_dyn-array AstDecl))]
  [src : (& src (__tl_dyn-array AstDecl))]
  [src-offset : i64]
  [dst-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set!
        (array-ref dst (+ dst-offset index))
        (array-ref src (+ src-offset index)))
      (ast-decl-list-copy-to dst src src-offset dst-offset (+ index 1) count))))

(define (ast-decl-list-grow [v : (&mut v AstDeclList)]) : unit
  (let
    [n : i64 v.len]
    [old-cap : i64 (- (array-length v.slots) v.offset)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array AstDecl) (__tl_make-array AstDecl new-cap)]
    (begin
      (ast-decl-list-copy-range (&mut bigger) (& v.slots) v.offset 0 n)
      (set! v.slots bigger)
      (set! v.offset 0)
      (set! v.prependable true))))

(define (ast-decl-list-push [v : (&mut v AstDeclList)] [value : AstDecl]) : unit
  (begin
    (if (< v.len (- (array-length v.slots) v.offset))
      unit
      (ast-decl-list-grow v))
    (let
      [index : i64 (+ v.offset v.len)]
      (begin
        (set! (array-ref v.slots index) value)
        (set! v.len (+ v.len 1))))))

;; Append one declaration read straight out of a source slot array.
;;
;; `ast-decl-list-get` returns `AstDecl` through an SRET pointer, so the append
;; loops copied the whole 104 B row into a stack temporary and then copied it
;; again into the destination -- two row copies and an out-of-line call per
;; declaration. This copies array-to-array, leaving one.
;;
;; A shared `AstDeclList` borrow cannot yield an element by value at all (a
;; direct aggregate read through a shared vector borrow is not an owned value),
;; but it can reborrow its `slots` field, which is the form this takes.
;;
;; The destination slot is always `offset + len`, i.e. one past the
;; destination's live range. Callers must not append a list to itself; every
;; caller in tree appends into a freshly allocated `ast-decl-list-with-capacity`
;; result.
(define (ast-decl-list-push-from
  [v : (&mut v AstDeclList)]
  [src : (& src (__tl_dyn-array AstDecl))]
  [src-index : i64]) : unit
  (begin
    (if (< v.len (- (array-length v.slots) v.offset))
      unit
      (ast-decl-list-grow v))
    (let
      [index : i64 (+ v.offset v.len)]
      (begin
        (set! (array-ref v.slots index) (array-ref src src-index))
        (set! v.len (+ v.len 1))))))

(define (ast-decl-list-step [items : (& items AstDeclList)]) : AstDeclListStep
  (let
    [list : AstDeclList (owned_view.compiler-owned-reference-shared-view items)]
    [len : i64 list.len]
    [offset : i64 list.offset]
    (if (<= len 0)
      (AstDeclListStep.Nil)
      (AstDeclListStep.Cons
        (ast-array-shared-view list.slots offset)
        (AstDeclList list.slots (+ offset 1) (- len 1) false)))))

(define (ast-decl-list-append-from
  [out : (&mut out AstDeclList)]
  [items : (& items AstDeclList)]
  [index : i64]) : unit
  (if (>= index (ast-decl-list-len items))
    unit
    (begin
      (ast-decl-list-push-from out (& items.slots) (+ items.offset index))
      (ast-decl-list-append-from out items (+ index 1)))))

(define (ast-decl-list-prepend-builder [head : AstDecl] [rest : AstDeclList]) : AstDeclList
  (if (and (> rest.offset 0) rest.prependable)
    (let
      [new-offset : i64 (- rest.offset 1)]
      (begin
        (set! (array-ref rest.slots new-offset) head)
        (AstDeclList rest.slots new-offset (+ rest.len 1) true)))
    (let
      [rest-len : i64 (ast-decl-list-len (& rest))]
      [new-len : i64 (+ rest-len 1)]
      [new-cap : i64
        (if (< rest-len 4)
          4
          (* new-len 2))]
      [new-offset : i64 (- new-cap new-len)]
      [slots : (__tl_dyn-array AstDecl) (__tl_make-array AstDecl new-cap)]
      (begin
        (set! (array-ref slots new-offset) head)
        (ast-decl-list-copy-to
          (&mut slots)
          (& rest.slots)
          rest.offset
          (+ new-offset 1)
          0
          rest-len)
        (AstDeclList slots new-offset new-len true)))))

(define (ast-decl-cons [head : AstDecl] [rest : AstDeclList]) : AstDeclList
  (let
    [out : AstDeclList
      (ast-decl-list-with-capacity (+ 1 (ast-decl-list-len (& rest))))]
    (begin
      (ast-decl-list-push (&mut out) head)
      (ast-decl-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-decl-cons-boxed [head : AstDecl] [rest : (Box AstDeclList)]) : AstDeclList
  (let
    [borrowed-rest : (& rest AstDeclList) (& (deref rest))]
    [out : AstDeclList
      (ast-decl-list-with-capacity (+ 1 (ast-decl-list-len borrowed-rest)))]
    (begin
      (ast-decl-list-push (&mut out) head)
      (ast-decl-list-append-from (&mut out) borrowed-rest 0)
      out)))

(define (ast-decl-module-id [name : i64]) : AstDecl
  (AstDecl.Module name))

(define (ast-decl-module-body-id [name : i64] [body : AstDeclList]) : AstDecl
  (AstDecl.ModuleBody name (box body)))

(define (ast-decl-def-id [name : i64] [maybe-ty : AstMaybeType] [value : i64]) : AstDecl
  (AstDecl.Def
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    maybe-ty
    value))

(define (ast-decl-def-fn-id
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]) : AstDecl
  (AstDecl.DefFn
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    params
    ret
    body
    (ast-fn-metadata AstFnExport.No)))

(define (ast-decl-def-fn-metadata-id
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [metadata : AstFnMetadata]) : AstDecl
  (AstDecl.DefFn
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    params
    ret
    body
    (ast-fn-metadata-clone metadata)))

(define (ast-decl-def-macro-id
  [name : i64]
  [params : AstMacroParamList]
  [ret : AstType]
  [body : i64]) : AstDecl
  (AstDecl.DefMacro
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    params
    ret
    body))

(define (ast-decl-extern-id
  [name : i64]
  [kind : AstExternKind]
  [metadata : AstExternMetadata]
  [ty : AstType]) : AstDecl
  (AstDecl.Extern
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    kind
    (box metadata)
    ty))

(define (ast-decl-def-enum-id
  [name : i64]
  [cleanup : AstEnumCleanup]
  [variants : AstVariantDefList]) : AstDecl
  (AstDecl.DefEnum
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    cleanup
    variants))

(define (ast-decl-def-enum-lifetimes-id
  [name : i64]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [variants : AstVariantDefList]) : AstDecl
  (AstDecl.DefEnumLifetimes
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    lifetimes
    cleanup
    variants))

(define (ast-decl-def-struct-id
  [name : i64]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : AstDecl
  (AstDecl.DefStruct
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    repr
    cleanup
    fields))

(define (ast-decl-def-struct-lifetimes-id
  [name : i64]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : AstDecl
  (AstDecl.DefStructLifetimes
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    lifetimes
    repr
    cleanup
    fields))

(define (ast-decl-def-dispatch-id
  [name : i64]
  [variants : AstDispatchVariantList]) : AstDecl
  (AstDecl.DefDispatch
    (ast-global-shared-view ast-decl-meta-runtime)
    name
    variants))

(define (ast-decl-test-id [name : i64] [body : i64] [span : AstSourceSpan]) : AstDecl
  (AstDecl.Test name body (ast-test-metadata-none-shared-view) span))

(define (ast-decl-test-metadata-id
  [name : i64]
  [body : i64]
  [metadata : AstTestMetadata]
  [span : AstSourceSpan]) : AstDecl
  (AstDecl.Test name body metadata span))

(define (ast-decl-unsafe [inner : AstDecl]) : AstDecl
  (AstDecl.Unsafe (box inner)))

(define (ast-decl-meta [decl : (& decl AstDecl)]) : AstDeclMeta
  (match (owned_view.compiler-owned-reference-shared-view decl)
    [(AstDecl.Def decl-meta _ _ _) decl-meta]
    [(AstDecl.DefFn decl-meta _ _ _ _ _) decl-meta]
    [(AstDecl.DefMacro decl-meta _ _ _ _) decl-meta]
    [(AstDecl.Extern decl-meta _ _ _ _) decl-meta]
    [(AstDecl.DefEnum decl-meta _ _ _) decl-meta]
    [(AstDecl.DefEnumLifetimes decl-meta _ _ _ _) decl-meta]
    [(AstDecl.DefStruct decl-meta _ _ _ _) decl-meta]
    [(AstDecl.DefStructLifetimes decl-meta _ _ _ _ _) decl-meta]
    [(AstDecl.DefDispatch decl-meta _ _) decl-meta]
    [(AstDecl.Import decl-meta _) decl-meta]
    [(AstDecl.Unsafe inner-box) (ast-decl-meta (deref inner-box))]
    [_ (ast-global-shared-view ast-decl-meta-runtime)]))

(define (ast-decl-generated-meta [decl : (& decl AstDecl)]) : AstGeneratedDeclMeta
  (match (__tl-box-place (__tl-project-field (ast-decl-meta decl) value))
    [(AstDeclMetaValue.Runtime _) AstGeneratedDeclMeta.No]
    [(AstDeclMetaValue.Comptime meta _) meta]))

(define (ast-decl-comptime-only? [decl : (& decl AstDecl)]) : bool
  (match (__tl-box-place (__tl-project-field (ast-decl-meta decl) value))
    [(AstDeclMetaValue.Runtime _) false]
    [(AstDeclMetaValue.Comptime _ _) true]))

;; Aggregate markers are declaration metadata, not runtime representation.
;; Bit 0 is :must-use; higher bits are reserved for future aggregate markers.
(define (ast-decl-meta-aggregate-markers [meta : AstDeclMeta]) : i64
  (match (__tl-box-place meta.value)
    [(AstDeclMetaValue.Runtime markers) markers]
    [(AstDeclMetaValue.Comptime _ markers) markers]))

(define (ast-decl-aggregate-markers [decl : (& decl AstDecl)]) : i64
  (ast-decl-meta-aggregate-markers (ast-decl-meta decl)))

(define (ast-decl-must-use? [decl : (& decl AstDecl)]) : bool
  (not (= (bit-and (ast-decl-aggregate-markers decl) 1) 0)))

(define (ast-decl-with-meta [meta : AstDeclMeta] [inner : AstDecl]) : AstDecl
  (let
    [fallback : AstDecl (ast-global-shared-view inner)]
    (match inner
      [(AstDecl.Def _ name maybe-ty value)
        (AstDecl.Def meta name maybe-ty value)]
      [(AstDecl.DefFn _ name params ret body fn-meta)
        (AstDecl.DefFn meta name params ret body fn-meta)]
      [(AstDecl.DefMacro _ name params ret body)
        (AstDecl.DefMacro meta name params ret body)]
      [(AstDecl.Extern _ name kind extern-meta ty)
        (AstDecl.Extern meta name kind extern-meta ty)]
      [(AstDecl.DefEnum _ name cleanup variants)
        (AstDecl.DefEnum meta name cleanup variants)]
      [(AstDecl.DefEnumLifetimes _ name lifetimes cleanup variants)
        (AstDecl.DefEnumLifetimes meta name lifetimes cleanup variants)]
      [(AstDecl.DefStruct _ name repr cleanup fields)
        (AstDecl.DefStruct meta name repr cleanup fields)]
      [(AstDecl.DefStructLifetimes _ name lifetimes repr cleanup fields)
        (AstDecl.DefStructLifetimes meta name lifetimes repr cleanup fields)]
      [(AstDecl.DefDispatch _ name variants)
        (AstDecl.DefDispatch meta name variants)]
      [(AstDecl.Import _ spec) (AstDecl.Import meta spec)]
      [(AstDecl.Unsafe inner-box)
        (AstDecl.Unsafe (box (ast-decl-with-meta meta (deref inner-box))))]
      [_ fallback])))

(define (ast-decl-comptime-decl [inner : AstDecl]) : AstDecl
  (ast-decl-with-meta
    (AstDeclMeta
      (box
        (AstDeclMetaValue.Comptime
          AstGeneratedDeclMeta.No
          (ast-decl-aggregate-markers inner))))
    inner))

(define (ast-decl-comptime-decl-with-meta
  [meta : AstGeneratedDeclMeta]
  [inner : AstDecl]) : AstDecl
  (ast-decl-with-meta
    (AstDeclMeta
      (box (AstDeclMetaValue.Comptime meta (ast-decl-aggregate-markers inner))))
    inner))

(define (ast-decl-with-aggregate-markers [inner : AstDecl] [markers : i64]) : AstDecl
  (if (= markers (ast-decl-aggregate-markers inner))
    inner
    (ast-decl-with-meta
      (match (__tl-box-place (__tl-project-field (ast-decl-meta inner) value))
        [(AstDeclMetaValue.Runtime _)
          (ast-decl-meta-runtime-with-aggregate-markers markers)]
        [(AstDeclMetaValue.Comptime generated _)
          (AstDeclMeta (box (AstDeclMetaValue.Comptime generated markers)))])
      inner)))

(define (ast-decl-unwrapped [decl : AstDecl]) : AstDecl
  (let
    [fallback : AstDecl (ast-global-shared-view decl)]
    (match decl
      [(AstDecl.Unsafe inner-box) (ast-decl-unwrapped (deref inner-box))]
      [_ fallback])))

;; Declaration classifiers for the index/cache builders.
;;
;; `ast-decl-unwrapped` copies a 104 B row twice -- once into the call and once
;; back out through the SRET pointer -- to answer the one-bit question "is this
;; wrapped in `unsafe`". These scans only need to know whether the peeled
;; declaration is one of the few kinds whose payload they read; every other kind
;; can be skipped without copying anything.
;;
;; The `-at?` forms read the outer tag through a borrow. The internal BoxGet
;; node requires owned `Box` storage, so a borrow cannot walk the wrapper chain itself; only
;; an `AstDecl.Unsafe` row -- the rare case -- is copied, to finish the peel
;; through the by-value form below it. Callers pair these with a by-value
;; re-read on the arm that consumes a payload, so a row copy is paid only where
;; it is used.
(define (ast-decl-unwrapped-import? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Import decl-meta _) true]
    [(AstDecl.Unsafe inner-box) (ast-decl-unwrapped-import? (deref inner-box))]
    [_ false]))

(define (ast-decl-list-unwrapped-import-at?
  [v : (& v AstDeclList)]
  [index : i64]) : bool
  (match (ast-decl-list-ref-borrowed v index)
    [(AstDecl.Import decl-meta _) true]
    [(AstDecl.Unsafe _)
      (ast-decl-unwrapped-import?
        (ast-decl-list-get v index (ast-decl-fallback)))]
    [_ false]))

(define (ast-decl-unwrapped-module-or-import? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Module _) true]
    [(AstDecl.Import decl-meta _) true]
    [(AstDecl.Unsafe inner-box)
      (ast-decl-unwrapped-module-or-import? (deref inner-box))]
    [_ false]))

(define (ast-decl-list-unwrapped-module-or-import-at?
  [v : (& v AstDeclList)]
  [index : i64]) : bool
  (match (ast-decl-list-ref-borrowed v index)
    [(AstDecl.Module _) true]
    [(AstDecl.Import decl-meta _) true]
    [(AstDecl.Unsafe _)
      (ast-decl-unwrapped-module-or-import?
        (ast-decl-list-get v index (ast-decl-fallback)))]
    [_ false]))

;; Module markers plus the two type-definition kinds the clone fixpoint reads.
(define (ast-decl-unwrapped-module-or-type-definition? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Module _) true]
    [(AstDecl.DefEnum decl-meta _ _ _) true]
    [(AstDecl.DefStruct decl-meta _ _ _ _) true]
    [(AstDecl.Unsafe inner-box)
      (ast-decl-unwrapped-module-or-type-definition? (deref inner-box))]
    [_ false]))

(define (ast-decl-list-unwrapped-module-or-type-definition-at?
  [v : (& v AstDeclList)]
  [index : i64]) : bool
  (match (ast-decl-list-ref-borrowed v index)
    [(AstDecl.Module _) true]
    [(AstDecl.DefEnum decl-meta _ _ _) true]
    [(AstDecl.DefStruct decl-meta _ _ _ _) true]
    [(AstDecl.Unsafe _)
      (ast-decl-unwrapped-module-or-type-definition?
        (ast-decl-list-get v index (ast-decl-fallback)))]
    [_ false]))

(define (ast-decl-path-list-with-capacity [capacity : i64]) : AstDeclPathList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstDeclPathList
      (__tl_make-array String cap)
      (__tl_make-array i64 (* cap 2))
      0
      0
      true)))

(define (ast-decl-path-list-new) : AstDeclPathList
  (ast-decl-path-list-with-capacity 4))

(define (ast-decl-path-list-len [v : (& v AstDeclPathList)]) : i64
  v.len)

(define (ast-decl-path-list-get
  [v : (& v AstDeclPathList)]
  [index : i64]
  [fallback : String]) : String
  (if (and (>= index 0) (< index (ast-decl-path-list-len v)))
    (array-ref v.slots (+ v.offset index))
    fallback))

(define (ast-decl-path-list-owner-id
  [v : (& v AstDeclPathList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-decl-path-list-len v)))
    (array-ref v.owner-ids (+ v.offset index))
    fallback))

(define (ast-decl-path-list-provenance-id
  [v : (& v AstDeclPathList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-decl-path-list-len v)))
    (array-ref v.owner-ids (+ (array-length v.slots) v.offset index))
    fallback))

(define (ast-decl-path-list-set-owner-and-provenance-id-at-physical-index!
  [owner-ids : (__tl_dyn-array i64)]
  [capacity : i64]
  [index : i64]
  [owner-id : i64]
  [provenance-id : i64]) : unit
  (begin
    (set! (array-ref owner-ids index) owner-id)
    (set! (array-ref owner-ids (+ capacity index)) provenance-id)))

(define (ast-decl-path-list-copy-range
  [dst : (&mut dst (__tl_dyn-array String))]
  [src : (& src (__tl_dyn-array String))]
  [src-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src (+ src-offset index)))
      (ast-decl-path-list-copy-range dst src src-offset (+ index 1) count))))

(define (ast-decl-path-list-copy-to
  [dst : (&mut dst (__tl_dyn-array String))]
  [src : (& src (__tl_dyn-array String))]
  [src-offset : i64]
  [dst-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set!
        (array-ref dst (+ dst-offset index))
        (array-ref src (+ src-offset index)))
      (ast-decl-path-list-copy-to
        dst
        src
        src-offset
        dst-offset
        (+ index 1)
        count))))

(define (ast-decl-path-list-grow [v : (&mut v AstDeclPathList)]) : unit
  (let
    [n : i64 v.len]
    [old-cap : i64 (- (array-length v.slots) v.offset)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [old-total-cap : i64 (array-length v.slots)]
    [bigger : (__tl_dyn-array String) (__tl_make-array String new-cap)]
    [bigger-owner-ids : (__tl_dyn-array i64)
      (__tl_make-array i64 (* new-cap 2))]
    (begin
      (ast-decl-path-list-copy-range (&mut bigger) (& v.slots) v.offset 0 n)
      (ast-decl-module-list-copy-to
        (&mut bigger-owner-ids)
        (& v.owner-ids)
        v.offset
        0
        0
        n)
      (ast-decl-module-list-copy-to
        (&mut bigger-owner-ids)
        (& v.owner-ids)
        (+ old-total-cap v.offset)
        new-cap
        0
        n)
      (set! v.slots bigger)
      (set! v.owner-ids bigger-owner-ids)
      (set! v.offset 0)
      (set! v.prependable true))))

(define (ast-decl-path-list-push-with-owner-and-provenance-id
  [v : (&mut v AstDeclPathList)]
  [value : String]
  [owner-id : i64]
  [provenance-id : i64]) : unit
  (begin
    (if (< v.len (- (array-length v.slots) v.offset))
      unit
      (ast-decl-path-list-grow v))
    (let
      [index : i64 (+ v.offset v.len)]
      (begin
        (set! (array-ref v.slots index) value)
        (set! (array-ref v.owner-ids index) owner-id)
        (set!
          (array-ref v.owner-ids (+ (array-length v.slots) index))
          provenance-id)
        (set! v.len (+ v.len 1))))))

(define (ast-decl-path-list-push-with-owner-id
  [v : (&mut v AstDeclPathList)]
  [value : String]
  [owner-id : i64]) : unit
  (ast-decl-path-list-push-with-owner-and-provenance-id
    v
    value
    owner-id
    owner-id))

(define (ast-decl-path-list-tail [items : AstDeclPathList]) : AstDeclPathList
  (if (<= (ast-decl-path-list-len (& items)) 0)
    (ast-decl-path-list-new)
    (AstDeclPathList
      items.slots
      items.owner-ids
      (+ items.offset 1)
      (- items.len 1)
      false)))

(define (ast-decl-path-list-step [items : (& items AstDeclPathList)]) : AstDeclPathListStep
  (let
    [list : AstDeclPathList
      (owned_view.compiler-owned-reference-shared-view items)]
    [len : i64 list.len]
    [offset : i64 list.offset]
    (if (<= len 0)
      (AstDeclPathListStep.Nil)
      (AstDeclPathListStep.Cons
        (ast-array-shared-view list.slots offset)
        (AstDeclPathList list.slots list.owner-ids (+ offset 1) (- len 1) false)))))

(define (ast-decl-path-list-append-from
  [out : (&mut out AstDeclPathList)]
  [items : (& items AstDeclPathList)]
  [index : i64]) : unit
  (if (>= index (ast-decl-path-list-len items))
    unit
    (begin
      (ast-decl-path-list-push-with-owner-and-provenance-id
        out
        (ast-decl-path-list-get items index "")
        (ast-decl-path-list-owner-id
          items
          index
          cbi.compiler-builtin-id-fix-empty)
        (ast-decl-path-list-provenance-id
          items
          index
          cbi.compiler-builtin-id-fix-empty))
      (ast-decl-path-list-append-from out items (+ index 1)))))

(define (ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
  [head : String]
  [owner-id : i64]
  [provenance-id : i64]
  [rest : AstDeclPathList]) : AstDeclPathList
  (if (and (> rest.offset 0) rest.prependable)
    (let
      [new-offset : i64 (- rest.offset 1)]
      (begin
        (set! (array-ref rest.slots new-offset) head)
        (ast-decl-path-list-set-owner-and-provenance-id-at-physical-index!
          (ast-global-shared-view rest.owner-ids)
          (array-length rest.slots)
          new-offset
          owner-id
          provenance-id)
        (AstDeclPathList
          rest.slots
          rest.owner-ids
          new-offset
          (+ rest.len 1)
          true)))
    (let
      [rest-len : i64 (ast-decl-path-list-len (& rest))]
      [new-len : i64 (+ rest-len 1)]
      [new-cap : i64
        (if (< rest-len 4)
          4
          (* new-len 2))]
      [new-offset : i64 (- new-cap new-len)]
      [slots : (__tl_dyn-array String) (__tl_make-array String new-cap)]
      [owner-ids : (__tl_dyn-array i64) (__tl_make-array i64 (* new-cap 2))]
      [rest-cap : i64 (array-length rest.slots)]
      (begin
        (set! (array-ref slots new-offset) head)
        (set! (array-ref owner-ids new-offset) owner-id)
        (set! (array-ref owner-ids (+ new-cap new-offset)) provenance-id)
        (ast-decl-path-list-copy-to
          (&mut slots)
          (& rest.slots)
          rest.offset
          (+ new-offset 1)
          0
          rest-len)
        (ast-decl-module-list-copy-to
          (&mut owner-ids)
          (& rest.owner-ids)
          rest.offset
          (+ new-offset 1)
          0
          rest-len)
        (ast-decl-module-list-copy-to
          (&mut owner-ids)
          (& rest.owner-ids)
          (+ rest-cap rest.offset)
          (+ new-cap new-offset 1)
          0
          rest-len)
        (AstDeclPathList slots owner-ids new-offset new-len true)))))

(define (ast-decl-path-list-prepend-builder-with-owner-id
  [head : String]
  [owner-id : i64]
  [rest : AstDeclPathList]) : AstDeclPathList
  (ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
    head
    owner-id
    owner-id
    rest))

(define (ast-decl-path-cons-with-owner-id
  [head : String]
  [owner-id : i64]
  [rest : AstDeclPathList]) : AstDeclPathList
  (let
    [out : AstDeclPathList
      (ast-decl-path-list-with-capacity (+ 1 (ast-decl-path-list-len (& rest))))]
    (begin
      (ast-decl-path-list-push-with-owner-id (&mut out) head owner-id)
      (ast-decl-path-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-decl-root-path-cons [head : String] [rest : AstDeclPathList]) : AstDeclPathList
  (ast-decl-path-cons-with-owner-id head cbi.compiler-builtin-id-fix-empty rest))

(define (ast-decl-module-list-with-capacity [capacity : i64]) : AstDeclModuleList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstDeclModuleList (__tl_make-array i64 cap) 0 0 true)))

(define (ast-decl-module-list-new) : AstDeclModuleList
  (ast-decl-module-list-with-capacity 4))

(define (ast-decl-module-list-len [v : (& v AstDeclModuleList)]) : i64
  v.len)

(define (ast-decl-module-list-get-id
  [v : (& v AstDeclModuleList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-decl-module-list-len v)))
    (array-ref v.slots (+ v.offset index))
    fallback))

(define (ast-decl-module-list-copy-to
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [src-offset : i64]
  [dst-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set!
        (array-ref dst (+ dst-offset index))
        (array-ref src (+ src-offset index)))
      (ast-decl-module-list-copy-to
        dst
        src
        src-offset
        dst-offset
        (+ index 1)
        count))))

(define (ast-decl-module-list-grow [v : (&mut v AstDeclModuleList)]) : unit
  (let
    [n : i64 v.len]
    [old-cap : i64 (array-length v.slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
    (begin
      (ast-decl-module-list-copy-to (&mut bigger) (& v.slots) v.offset 0 0 n)
      (set! v.slots bigger)
      (set! v.offset 0)
      (set! v.prependable true))))

(define (ast-decl-module-list-push-id
  [v : (&mut v AstDeclModuleList)]
  [value : i64]) : unit
  (begin
    (if (< (+ v.offset v.len) (array-length v.slots))
      unit
      (ast-decl-module-list-grow v))
    (let
      [index : i64 (+ v.offset v.len)]
      (begin
        (set! (array-ref v.slots index) value)
        (set! v.len (+ v.len 1))))))

(define (ast-decl-module-list-append-from
  [out : (&mut out AstDeclModuleList)]
  [items : (& items AstDeclModuleList)]
  [index : i64]) : unit
  (if (>= index (ast-decl-module-list-len items))
    unit
    (begin
      (ast-decl-module-list-push-id
        out
        (ast-decl-module-list-get-id
          items
          index
          cbi.compiler-builtin-id-fix-empty))
      (ast-decl-module-list-append-from out items (+ index 1)))))

(define (ast-decl-module-list-prepend-builder-id
  [head : i64]
  [rest : AstDeclModuleList]) : AstDeclModuleList
  (if (and (> rest.offset 0) rest.prependable)
    (let
      [new-offset : i64 (- rest.offset 1)]
      (begin
        (set! (array-ref rest.slots new-offset) head)
        (AstDeclModuleList rest.slots new-offset (+ rest.len 1) true)))
    (let
      [rest-len : i64 (ast-decl-module-list-len (& rest))]
      [new-len : i64 (+ rest-len 1)]
      [new-cap : i64
        (if (< rest-len 4)
          4
          (* new-len 2))]
      [new-offset : i64 (- new-cap new-len)]
      [slots : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
      (begin
        (set! (array-ref slots new-offset) head)
        (ast-decl-module-list-copy-to
          (&mut slots)
          (& rest.slots)
          rest.offset
          (+ new-offset 1)
          0
          rest-len)
        (AstDeclModuleList slots new-offset new-len true)))))

(define (ast-decl-module-cons-id [head : i64] [rest : AstDeclModuleList]) : AstDeclModuleList
  (let
    [out : AstDeclModuleList
      (ast-decl-module-list-with-capacity
        (+ 1 (ast-decl-module-list-len (& rest))))]
    (begin
      (ast-decl-module-list-push-id (&mut out) head)
      (ast-decl-module-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-decl-path-list-with-modules
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]) : AstDeclPathList
  (let
    [capacity : i64 (array-length paths.slots)]
    [owner-ids : (__tl_dyn-array i64) (__tl_make-array i64 (* capacity 2))]
    [index : i64 0]
    [count : i64 (ast-decl-path-list-len (& paths))]
    (begin
      (while (< index count)
        (let
          [module-id : i64
            (ast-decl-module-list-get-id
              (& modules)
              index
              cbi.compiler-builtin-id-fix-empty)]
          [recorded-owner-id : i64
            (ast-decl-path-list-owner-id
              (& paths)
              index
              cbi.compiler-builtin-id-fix-empty)]
          [owner-id : i64
            (cond
              [(not (= module-id cbi.compiler-builtin-id-fix-empty)) module-id]
              [(not (= recorded-owner-id cbi.compiler-builtin-id-fix-empty))
                recorded-owner-id]
              [else cbi.compiler-builtin-id-fix-empty])]
          (begin
            (set! (array-ref owner-ids (+ paths.offset index)) owner-id)
            (set!
              (array-ref owner-ids (+ capacity paths.offset index))
              (ast-decl-path-list-provenance-id
                (& paths)
                index
                cbi.compiler-builtin-id-fix-empty))
            (set! index (+ index 1)))))
      (AstDeclPathList
        paths.slots
        owner-ids
        paths.offset
        paths.len
        paths.prependable))))

(define (ast-program [decls : AstDeclList]) : AstProgram
  (AstProgram.Program (box decls)))

(defenum AstProgramCompaction
  (AstProgramCompaction AstProgram AstNodePoolContext))

;; `source-expr-bases` is the source pool's segment-bases pointer, resolved once
;; when the remap is built. `ast-compaction-remap-expr-id` reads a source node
;; per reachable expression; compaction only reads `source-pools`, and the
;; pointer is stable across reads (see `ast-node-pool-context-expr-segment-bases`),
;; so one resolution serves the whole walk.
;; `shared-expr-base` / `shared-type-base` split the source id space in two. An
;; id below its base is ALREADY in the destination with destination-owned
;; payloads, so the walk returns it unchanged and never descends into it; only
;; ids at or above the base are copied, and the id maps are indexed relative to
;; the base so they cover `[base, len)` rather than the whole pool. Whole-pool
;; callers pass 0. The per-declaration macro
;; generation (`macro-expand-decl-with-path-generational`) passes the pool
;; lengths taken before the expansion, which bounds one copy-out to the nodes
;; that expansion actually created.
;;
;; `persist-in-place` changes what happens to an id AT OR ABOVE the expression
;; base. Normally the walk pushes a rebuilt row at the pool tail and returns the
;; new id. In persist mode it rebuilds the row's out-of-line payloads in the
;; destination arena and writes the row back to the SAME id, returning that id
;; unchanged: the pool does not grow at all. That is sound exactly because an id
;; at or above the base was created by the caller's own transient scope -- no
;; committed structure can reference it yet -- so overwriting it with an
;; equal-valued, destination-owned copy is unobservable. `expr-map` degrades to
;; a visited set (1 = already persisted), which is what stops a shared subgraph
;; from being walked, or re-entered, twice.
;;
;; LOAD-BEARING: both `ast-compaction-remap-expr` (the AstExpr child schema's
;; `ast-expr-map-children`) and `ast-compaction-remap-decl` (18 arms for 18
;; variants) are EXHAUSTIVE matches with NO catch-all arm, and persist mode
;; inherits that property because it reuses those two walks rather than
;; duplicating them. A new variant added to either enum breaks this file at
;; build time. Do not add a `[_ ...]` arm to
;; either match: a variant that fell through would silently keep a payload in
;; the caller's transient arena, and the failure mode is a use-after-free.
(defstruct AstProgramCompactionRemap
  (source-pools AstNodePoolContext)
  (dest-pools AstNodePoolContext)
  ;; These are invocation-stable scalar facts. Read them directly from the
  ;; borrowed remap in recursive probes: materializing a borrow cell and
  ;; recovering the remap address on every visit only repeats pointer traffic.
  (expr-map-address u64)
  (type-map-address u64)
  (source-expr-bases i64)
  (shared-expr-base i64)
  (shared-type-base i64)
  (persist-in-place bool)
  ;; Two String slots owned by the compaction entry point: the last generated
  ;; identity key seen and its destination copy (ast-compaction-copy-generated-key).
  (generated-key-cache-address u64))

;; Return the backing address, not the address of the dynamic-array descriptor.
;; Compaction maps are allocated at their final length, never grow, and remain
;; owned by the caller's map/generation arena until the copy walk returns. That
;; makes this pointer stable for exactly the remap lifetime and saves a
;; descriptor load on every expression/type map probe.
(defstruct AstI32ArrayRef
  (:lifetimes items)
  (value (& items (__tl_dyn-array i32))))

(define (ast-i32-array-address-of [items : (& items (__tl_dyn-array i32))]) : u64
  (let
    [cell : (AstI32ArrayRef items) (AstI32ArrayRef items)]
    [descriptor-address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr descriptor-address : (Ptr u64))))))

(defmacro (ast-i32-array-address [items : Expr]) : Expr
  `(ast-i32-array-address-of (& ,items)))

(define (ast-compaction-map-ref [address : u64] [index : i64]) : i32
  (unsafe
    (ptr-read (ptr-offset (int->ptr address : (Ptr i32)) index))))

(define (ast-compaction-map-set! [address : u64] [index : i64] [value : i32]) : unit
  (unsafe
    (ptr-write! (ptr-offset (int->ptr address : (MutPtr i32)) index) value)))

;; Compile-profile-only reachability census for the per-declaration macro
;; generation copy-out.  The copy walk is the ownership authority: ids below
;; the declaration's entry bases are source/shared references, while the first
;; visit to an id at or above a base is a macro-pool survivor.  Keeping the
;; census here avoids a second graph traversal and, importantly, counts the
;; same exhaustive set of AstExpr/AstDecl variants as the copy itself.
;;
;; Type nodes are committed at push time, so the copy's operational
;; `shared-type-base` is taken after expansion.  `source-type-base` preserves
;; the entry boundary for attribution, and `survivor-type-map` deduplicates the
;; newly committed type ids that the returned declaration actually reaches.
(cfg
  compile-profile
  (define ast-compaction-profile-active : bool
    false))
(cfg
  compile-profile
  (define ast-compaction-profile-source-type-base : i64
    0))
(cfg
  compile-profile
  (define ast-compaction-profile-survivor-type-map : (__tl_dyn-array i32)
    (__tl_make-array i32 1)))
(cfg
  compile-profile
  (define ast-compaction-profile-source-shared-expr-refs : i64
    0))
(cfg
  compile-profile
  (define ast-compaction-profile-source-shared-type-refs : i64
    0))
(cfg
  compile-profile
  (define ast-compaction-profile-survivor-expr-nodes : i64
    0))
(cfg
  compile-profile
  (define ast-compaction-profile-survivor-type-nodes : i64
    0))

(cfg
  compile-profile
  (define (ast-compaction-profile-start!
    [source-type-base : i64]
    [survivor-type-map : (__tl_dyn-array i32)]) : unit
    (begin
      (set! ast-compaction-profile-source-type-base source-type-base)
      (set! ast-compaction-profile-survivor-type-map survivor-type-map)
      (set! ast-compaction-profile-source-shared-expr-refs 0)
      (set! ast-compaction-profile-source-shared-type-refs 0)
      (set! ast-compaction-profile-survivor-expr-nodes 0)
      (set! ast-compaction-profile-survivor-type-nodes 0)
      (set! ast-compaction-profile-active true))))

(cfg
  compile-profile
  (define (ast-compaction-profile-finish!) : unit
    (set! ast-compaction-profile-active false)))

(cfg
  compile-profile
  (define (ast-compaction-profile-note-source-expr!) : unit
    (if ast-compaction-profile-active
      (set!
        ast-compaction-profile-source-shared-expr-refs
        (+ ast-compaction-profile-source-shared-expr-refs 1))
      unit)))

(cfg
  compile-profile
  (define (ast-compaction-profile-note-survivor-expr!) : unit
    (if ast-compaction-profile-active
      (set!
        ast-compaction-profile-survivor-expr-nodes
        (+ ast-compaction-profile-survivor-expr-nodes 1))
      unit)))

(cfg
  compile-profile
  (define (ast-compaction-profile-note-shared-type! [id : i64]) : unit
    (if (not ast-compaction-profile-active)
      unit
      (if (< id ast-compaction-profile-source-type-base)
        (set!
          ast-compaction-profile-source-shared-type-refs
          (+ ast-compaction-profile-source-shared-type-refs 1))
        (let
          [slot : i64 (- id ast-compaction-profile-source-type-base)]
          (if (or
            (< slot 0)
            (>= slot (array-length ast-compaction-profile-survivor-type-map)))
            unit
            (if (> (array-ref ast-compaction-profile-survivor-type-map slot) 0)
              unit
              (begin
                (set!
                  (array-ref ast-compaction-profile-survivor-type-map slot)
                  1)
                (set!
                  ast-compaction-profile-survivor-type-nodes
                  (+ ast-compaction-profile-survivor-type-nodes 1))))))))))

(cfg
  compile-profile
  (define (ast-compaction-profile-source-shared-expr-ref-count) : i64
    ast-compaction-profile-source-shared-expr-refs))

(cfg
  compile-profile
  (define (ast-compaction-profile-source-shared-type-ref-count) : i64
    ast-compaction-profile-source-shared-type-refs))

(cfg
  compile-profile
  (define (ast-compaction-profile-survivor-expr-node-count) : i64
    ast-compaction-profile-survivor-expr-nodes))

(cfg
  compile-profile
  (define (ast-compaction-profile-survivor-type-node-count) : i64
    ast-compaction-profile-survivor-type-nodes))

(define (ast-compaction-id-map-create [count : i64]) : (__tl_dyn-array i32)
  (let
    [cap : i64
      (if (< count 1)
        1
        count)]
    ;; Arrays are zero-initialized. Store destination ids as id+1 so zero can
    ;; remain the unseen sentinel without an O(source-pool-size) initialization
    ;; pass before each compaction.
    ;; Pool ids are bounded below i32::MAX by the 4096-segment pool ceiling.
    (__tl_make-array i32 cap)))

(define (ast-compaction-remap-source-type-get
  [remap : (& remap AstProgramCompactionRemap)]
  [id : i64]) : AstType
  (ast-type-segment-bases-get
    (__tl-project-field
      (ast-type-pool-cell-read remap.source-pools.type-pool)
      segment-bases)
    id))

(define (ast-compaction-remap-sync-dest-base-arena!
  [remap : (& remap AstProgramCompactionRemap)]
  [base-arena : i64]) : unit
  (begin
    (ast-expr-pool-cell-write!
      remap.dest-pools.expr-pool
      (ast-expr-node-pool-state-with-base-arena
        (ast-expr-pool-cell-read remap.dest-pools.expr-pool)
        base-arena))
    (ast-type-pool-cell-write!
      remap.dest-pools.type-pool
      (ast-type-node-pool-state-with-base-arena
        (ast-type-pool-cell-read remap.dest-pools.type-pool)
        base-arena))))

(define (ast-compaction-remap-dest-type-push
  [remap : (& remap AstProgramCompactionRemap)]
  [node : AstType]) : i64
  (let
    [current : AstTypeNodePoolState
      (ast-type-pool-cell-read remap.dest-pools.type-pool)]
    (match (ast-type-node-pool-state-push (ast-global-shared-view current) node)
      [(AstTypeNodePoolPushOk next id)
        (begin
          (ast-type-pool-cell-write! remap.dest-pools.type-pool next)
          (if (not (= current.base-arena next.base-arena))
            (ast-compaction-remap-sync-dest-base-arena! remap next.base-arena)
            unit)
          (ast-node-pool-compat-context-sync-installed!)
          id)])))

(define (ast-compaction-remap-dest-expr-set!
  [remap : (& remap AstProgramCompactionRemap)]
  [id : i64]
  [node : AstExpr]) : unit
  (begin
    (ast-expr-pool-cell-write!
      remap.dest-pools.expr-pool
      (ast-expr-node-pool-state-set!
        (ast-expr-pool-cell-read remap.dest-pools.expr-pool)
        id
        node))
    (ast-node-pool-compat-context-sync-installed!)))

(define (ast-compaction-remap-dest-expr-push
  [remap : (& remap AstProgramCompactionRemap)]
  [node : AstExpr]) : i64
  (let
    [pool-cell : (__tl_dyn-array AstExprNodePoolState)
      (ast-expr-pool-cell remap.dest-pools.expr-pool)]
    [current-base-arena : i64
      (__tl-project-field (array-ref pool-cell 0) base-arena)]
    [id : i64
      (ast-expr-node-pool-state-push-in-place!
        (&mut (array-ref pool-cell 0))
        node)]
    [next-base-arena : i64
      (__tl-project-field (array-ref pool-cell 0) base-arena)]
    (begin
      (if (not (= current-base-arena next-base-arena))
        (ast-compaction-remap-sync-dest-base-arena! remap next-base-arena)
        unit)
      (ast-node-pool-compat-context-sync-installed!)
      id)))

(define (ast-compaction-copy-string [text : String]) : String
  (string.copy (& text)))

(define (ast-lifetime-list-copy-into
  [lifetimes : (& lifetimes AstLifetimeList)]
  [out : (&mut out AstLifetimeList)]
  [index : i64]) : unit
  (if (>= index (ast-lifetime-list-len lifetimes))
    unit
    (begin
      (ast-lifetime-list-push
        out
        (ast-lifetime-list-get lifetimes index (ast-lifetime-fallback)))
      (ast-lifetime-list-copy-into lifetimes out (+ index 1)))))

(define (ast-lifetime-list-copy [lifetimes : AstLifetimeList]) : AstLifetimeList
  (let
    [out : AstLifetimeList
      (ast-lifetime-list-with-capacity (ast-lifetime-list-len (& lifetimes)))]
    (begin
      (ast-lifetime-list-copy-into (& lifetimes) (&mut out) 0)
      out)))

(define (ast-compaction-remap-type-list
  [remap : (& remap AstProgramCompactionRemap)]
  [types : AstTypeList]) : AstTypeList
  (ast-type-id-list-map types ast-compaction-remap-type-id remap))

(define (ast-compaction-remap-type
  [remap : (& remap AstProgramCompactionRemap)]
  [ty : AstType]) : AstType
  (ast-type-map-children ty ast-compaction-remap-type-id remap))

(define (ast-compaction-remap-type-id
  [remap : (& remap AstProgramCompactionRemap)]
  [id : i64]) : i64
  (let
    [base : i64 remap.shared-type-base]
    (if (< id base)
      (begin
        (cfg compile-profile (ast-compaction-profile-note-shared-type! id))
        id)
      (let
        [type-map-address : u64 remap.type-map-address]
        [slot : i64 (- id base)]
        [cached : i32 (ast-compaction-map-ref type-map-address slot)]
        (if (> cached 0)
          (cast (- cached 1) : i64)
          (let
            [source-ty : AstType
              (ast-compaction-remap-source-type-get remap id)]
            [new-ty : AstType (ast-compaction-remap-type remap source-ty)]
            [new-id : i64 (ast-compaction-remap-dest-type-push remap new-ty)]
            (begin
              (ast-compaction-map-set!
                type-map-address
                slot
                (cast (+ new-id 1) : i32))
              new-id)))))))

(define (ast-compaction-remap-maybe-type
  [remap : (& remap AstProgramCompactionRemap)]
  [maybe-ty : AstMaybeType]) : AstMaybeType
  (match maybe-ty
    [(AstMaybeType.No) AstMaybeType.No]
    [(AstMaybeType.Some ty)
      (AstMaybeType.Some (ast-compaction-remap-type remap ty))]))

(define (ast-compaction-remap-param-list
  [remap : (& remap AstProgramCompactionRemap)]
  [params : AstParamList]) : AstParamList
  (ast-param-list-map params ast-compaction-remap-type remap))

(define (ast-compaction-remap-macro-param
  [remap : (& remap AstProgramCompactionRemap)]
  [param : AstMacroParam]) : AstMacroParam
  (match param
    [(AstMacroParam.Param name ty variadic type-kinds)
      (AstMacroParam.Param
        name
        (ast-compaction-remap-type remap ty)
        variadic
        (ast-compaction-copy-macro-type-kind-list (& type-kinds)))]))

(define (ast-compaction-copy-macro-type-kind-list
  [kinds : (& kinds AstMacroTypeKindList)]) : AstMacroTypeKindList
  (ast-macro-type-kind-list-copy kinds))

(define (ast-compaction-remap-macro-param-list
  [remap : (& remap AstProgramCompactionRemap)]
  [params : AstMacroParamList]) : AstMacroParamList
  (let
    [out : AstMacroParamList
      (ast-macro-param-list-with-capacity (ast-macro-param-list-len (& params)))]
    (begin
      (ast-compaction-remap-macro-param-list-into remap (& params) 0 (&mut out))
      out)))

(define (ast-compaction-remap-macro-param-list-into
  [remap : (& remap AstProgramCompactionRemap)]
  [params : (& params AstMacroParamList)]
  [index : i64]
  [out : (&mut out AstMacroParamList)]) : unit
  (if (>= index (ast-macro-param-list-len params))
    unit
    (begin
      (ast-macro-param-list-push
        out
        (ast-compaction-remap-macro-param
          remap
          (ast-macro-param-list-get params index (ast-macro-param-fallback))))
      (ast-compaction-remap-macro-param-list-into remap params (+ index 1) out))))

(define (ast-compaction-remap-field-def
  [remap : (& remap AstProgramCompactionRemap)]
  [field : AstFieldDef]) : AstFieldDef
  (match field
    [(AstFieldDef.Def name ty cleanup)
      (AstFieldDef.Def
        name
        (ast-compaction-remap-type remap ty)
        (ast-compaction-remap-field-cleanup cleanup))]))

(define (ast-compaction-remap-field-cleanup [cleanup : AstFieldCleanup]) : AstFieldCleanup
  (match cleanup
    [(AstFieldCleanup.No) AstFieldCleanup.No]
    [(AstFieldCleanup.Fn name) (AstFieldCleanup.Fn name)]
    [(AstFieldCleanup.Owned) AstFieldCleanup.Owned]))

(define (ast-compaction-remap-field-def-list-into
  [remap : (& remap AstProgramCompactionRemap)]
  [fields : (& fields AstFieldDefList)]
  [index : i64]
  [out : (&mut out AstFieldDefList)]) : unit
  (if (>= index (ast-field-def-list-len fields))
    unit
    (begin
      (ast-field-def-list-push
        out
        (ast-compaction-remap-field-def
          remap
          (ast-field-def-list-get fields index (ast-field-def-fallback))))
      (ast-compaction-remap-field-def-list-into remap fields (+ index 1) out))))

(define (ast-compaction-remap-field-def-list
  [remap : (& remap AstProgramCompactionRemap)]
  [fields : AstFieldDefList]) : AstFieldDefList
  (let
    [out : AstFieldDefList
      (ast-field-def-list-with-capacity (ast-field-def-list-len (& fields)))]
    (begin
      (ast-compaction-remap-field-def-list-into remap (& fields) 0 (&mut out))
      out)))

(define (ast-compaction-remap-extern-abi
  [remap : (& remap AstProgramCompactionRemap)]
  [abi : AstExternAbi]) : AstExternAbi
  (match abi
    [(AstExternAbi.C) AstExternAbi.C]
    [(AstExternAbi.CVarargsOpen) AstExternAbi.CVarargsOpen]
    [(AstExternAbi.CVarargsTyped ty)
      (AstExternAbi.CVarargsTyped (ast-compaction-remap-type remap ty))]
    [(AstExternAbi.TypeLisp) AstExternAbi.TypeLisp]))

(define (ast-compaction-remap-extern-link-input [input : AstExternLinkInput]) : AstExternLinkInput
  (match input
    [(AstExternLinkInput.Lib name)
      (AstExternLinkInput.Lib (ast-compaction-copy-string name))]
    [(AstExternLinkInput.Search dir)
      (AstExternLinkInput.Search (ast-compaction-copy-string dir))]
    [(AstExternLinkInput.Arg arg)
      (AstExternLinkInput.Arg (ast-compaction-copy-string arg))]))

(define (ast-compaction-remap-extern-link-input-list-into
  [inputs : (& inputs AstExternLinkInputList)]
  [index : i64]
  [out : (&mut out AstExternLinkInputList)]) : unit
  (if (>= index (ast-extern-link-input-list-len inputs))
    unit
    (begin
      (ast-extern-link-input-list-push
        out
        (ast-compaction-remap-extern-link-input
          (ast-extern-link-input-list-get
            inputs
            index
            (ast-extern-link-input-fallback))))
      (ast-compaction-remap-extern-link-input-list-into inputs (+ index 1) out))))

(define (ast-compaction-remap-extern-link-input-list
  [inputs : AstExternLinkInputList]) : AstExternLinkInputList
  (let
    [out : AstExternLinkInputList
      (ast-extern-link-input-list-with-capacity
        (ast-extern-link-input-list-len (& inputs)))]
    (begin
      (ast-compaction-remap-extern-link-input-list-into (& inputs) 0 (&mut out))
      out)))

(define (ast-compaction-remap-extern-metadata
  [remap : (& remap AstProgramCompactionRemap)]
  [metadata : AstExternMetadata]) : AstExternMetadata
  (match metadata
    [(AstExternMetadata.Metadata abi symbol links flags imported-spmd)
      (AstExternMetadata.Metadata
        (ast-compaction-remap-extern-abi remap abi)
        symbol
        (ast-compaction-remap-extern-link-input-list links)
        flags
        (ast-imported-spmd-metadata-clone imported-spmd))]))

(define (ast-compaction-remap-variant-payload-cleanup
  [cleanup : AstVariantPayloadCleanup]) : AstVariantPayloadCleanup
  (match cleanup
    [(AstVariantPayloadCleanup.No) AstVariantPayloadCleanup.No]
    [(AstVariantPayloadCleanup.Fn name) (AstVariantPayloadCleanup.Fn name)]
    [(AstVariantPayloadCleanup.Owned) AstVariantPayloadCleanup.Owned]))

(define (ast-compaction-remap-variant-payload-cleanup-list
  [cleanups : AstVariantPayloadCleanupList]) : AstVariantPayloadCleanupList
  (let
    [out : AstVariantPayloadCleanupList
      (ast-variant-payload-cleanup-list-with-capacity
        (ast-variant-payload-cleanup-list-len (& cleanups)))]
    (begin
      (ast-compaction-remap-variant-payload-cleanup-list-into
        (& cleanups)
        0
        (&mut out))
      out)))

(define (ast-compaction-remap-variant-payload-cleanup-list-into
  [cleanups : (& cleanups AstVariantPayloadCleanupList)]
  [index : i64]
  [out : (&mut out AstVariantPayloadCleanupList)]) : unit
  (if (>= index (ast-variant-payload-cleanup-list-len cleanups))
    unit
    (begin
      (ast-variant-payload-cleanup-list-push
        out
        (ast-compaction-remap-variant-payload-cleanup
          (ast-variant-payload-cleanup-list-get
            cleanups
            index
            (ast-variant-payload-cleanup-fallback))))
      (ast-compaction-remap-variant-payload-cleanup-list-into
        cleanups
        (+ index 1)
        out))))

(define (ast-compaction-remap-variant-def
  [remap : (& remap AstProgramCompactionRemap)]
  [variant : AstVariantDef]) : AstVariantDef
  (match variant
    [(AstVariantDef.Def name fields cleanups)
      (AstVariantDef.Def
        name
        (ast-compaction-remap-type-list remap fields)
        (ast-compaction-remap-variant-payload-cleanup-list cleanups))]))

(define (ast-compaction-remap-variant-def-list
  [remap : (& remap AstProgramCompactionRemap)]
  [variants : AstVariantDefList]) : AstVariantDefList
  (let
    [out : AstVariantDefList
      (ast-variant-def-list-with-capacity
        (ast-variant-def-list-len (& variants)))]
    (begin
      (ast-compaction-remap-variant-def-list-into
        remap
        (& variants)
        0
        (&mut out))
      out)))

(define (ast-compaction-remap-variant-def-list-into
  [remap : (& remap AstProgramCompactionRemap)]
  [variants : (& variants AstVariantDefList)]
  [index : i64]
  [out : (&mut out AstVariantDefList)]) : unit
  (if (>= index (ast-variant-def-list-len variants))
    unit
    (begin
      (ast-variant-def-list-push
        out
        (ast-compaction-remap-variant-def
          remap
          (ast-variant-def-list-get variants index (ast-variant-def-fallback))))
      (ast-compaction-remap-variant-def-list-into
        remap
        variants
        (+ index 1)
        out))))

(define (ast-compaction-remap-struct-cleanup [cleanup : AstStructCleanup]) : AstStructCleanup
  (match cleanup
    [(AstStructCleanup.No) AstStructCleanup.No]
    [(AstStructCleanup.Fn name) (AstStructCleanup.Fn name)]))

(define (ast-compaction-remap-enum-cleanup [cleanup : AstEnumCleanup]) : AstEnumCleanup
  (match cleanup
    [(AstEnumCleanup.No) AstEnumCleanup.No]
    [(AstEnumCleanup.Fn name) (AstEnumCleanup.Fn name)]))

(define (ast-compaction-remap-import-kind
  [remap : (& remap AstProgramCompactionRemap)]
  [kind : AstImportKind]) : AstImportKind
  (match kind
    [(AstImportKind.Module) AstImportKind.Module]
    [(AstImportKind.ModuleAll) AstImportKind.ModuleAll]
    [(AstImportKind.ModuleItem item) (AstImportKind.ModuleItem item)]
    [(AstImportKind.Macro call module-name)
      (AstImportKind.Macro
        (ast-compaction-remap-expr-id remap call)
        (ast-compaction-remap-maybe-module-name module-name))]
    [(AstImportKind.MacroDecls call module-name)
      (AstImportKind.MacroDecls
        (ast-compaction-remap-expr-id remap call)
        (ast-compaction-remap-maybe-module-name module-name))]))

(define (ast-compaction-remap-maybe-module-name
  [module-name : AstMaybeModuleName]) : AstMaybeModuleName
  (match module-name
    [(AstMaybeModuleName.No) AstMaybeModuleName.No]
    [(AstMaybeModuleName.Some name) (AstMaybeModuleName.Some name)]))

(define (ast-compaction-remap-maybe-import-alias [alias : AstMaybeImportAlias]) : AstMaybeImportAlias
  (match alias
    [(AstMaybeImportAlias.No) AstMaybeImportAlias.No]
    [(AstMaybeImportAlias.Some name) (AstMaybeImportAlias.Some name)]))

(define (ast-compaction-remap-import-spec
  [remap : (& remap AstProgramCompactionRemap)]
  [spec : AstImportSpec]) : AstImportSpec
  (match spec
    [(AstImportSpec.Spec kind path module-name alias span)
      (AstImportSpec.Spec
        (ast-compaction-remap-import-kind remap kind)
        (ast-compaction-copy-string path)
        (ast-compaction-remap-maybe-module-name module-name)
        (ast-compaction-remap-maybe-import-alias alias)
        (box (__tl-box-place span)))]))

(define (ast-compaction-remap-dispatch-variant [variant : AstDispatchVariant]) : AstDispatchVariant
  (match variant
    [(AstDispatchVariant.Variant isa name)
      (AstDispatchVariant.Variant isa name)]))

(define (ast-compaction-remap-dispatch-variant-list-into
  [variants : (& variants AstDispatchVariantList)]
  [index : i64]
  [out : (&mut out AstDispatchVariantList)]) : unit
  (if (>= index (ast-dispatch-variant-list-len variants))
    unit
    (begin
      (ast-dispatch-variant-list-push
        out
        (ast-compaction-remap-dispatch-variant
          (ast-dispatch-variant-list-get
            variants
            index
            (ast-dispatch-variant-fallback))))
      (ast-compaction-remap-dispatch-variant-list-into variants (+ index 1) out))))

(define (ast-compaction-remap-dispatch-variant-list
  [variants : AstDispatchVariantList]) : AstDispatchVariantList
  (let
    [out : AstDispatchVariantList
      (ast-dispatch-variant-list-with-capacity
        (ast-dispatch-variant-list-len (& variants)))]
    (begin
      (ast-compaction-remap-dispatch-variant-list-into
        (& variants)
        0
        (&mut out))
      out)))

(define (ast-compaction-remap-literal [lit : AstLiteral]) : AstLiteral
  (match lit
    [(AstLiteral.Int value text)
      (AstLiteral.Int value (ast-compaction-copy-string text))]
    [(AstLiteral.Float text)
      (AstLiteral.Float (ast-compaction-copy-string text))]
    [(AstLiteral.Bool value) (AstLiteral.Bool value)]
    [(AstLiteral.Char value) (AstLiteral.Char value)]
    [(AstLiteral.String string-id) (AstLiteral.String string-id)]
    [(AstLiteral.Unit) AstLiteral.Unit]))

;; Literal and binary-data hooks for the schema map in ast-compaction-remap-expr.
(defmacro (ast-compaction-remap-literal-hook [_remap : Expr] [lit : Expr]) : Expr
  `(ast-compaction-remap-literal ,lit))

(defmacro (ast-compaction-remap-bytes-hook [_remap : Expr] [bytes : Expr]) : Expr
  `(ast-compaction-copy-string ,bytes))

(define (ast-compaction-remap-pattern
  [remap : (& remap AstProgramCompactionRemap)]
  [pattern : AstPattern]) : AstPattern
  (match pattern
    [(AstPattern.Var name maybe-ty)
      (AstPattern.Var name (ast-compaction-remap-maybe-type remap maybe-ty))]
    [(AstPattern.Tuple items)
      (AstPattern.Tuple
        (box (ast-compaction-remap-pattern-list remap (deref items))))]
    [(AstPattern.Array items)
      (AstPattern.Array
        (box (ast-compaction-remap-pattern-list remap (deref items))))]
    [(AstPattern.Slice items has-rest)
      (AstPattern.Slice
        (box (ast-compaction-remap-pattern-list remap (deref items)))
        has-rest)]
    [(AstPattern.Wildcard) AstPattern.Wildcard]
    [(AstPattern.Binding name) (AstPattern.Binding name)]
    [(AstPattern.Variant name items)
      (AstPattern.Variant
        name
        (box (ast-compaction-remap-pattern-list remap (deref items))))]
    [(AstPattern.Literal lit)
      (AstPattern.Literal (ast-compaction-remap-literal lit))]))

(define (ast-compaction-remap-pattern-list-into
  [remap : (& remap AstProgramCompactionRemap)]
  [patterns : (& patterns AstPatternList)]
  [index : i64]
  [out : (&mut out AstPatternList)]) : unit
  (if (>= index (ast-pattern-list-len patterns))
    unit
    (begin
      (ast-pattern-list-push
        out
        (ast-compaction-remap-pattern
          remap
          (ast-pattern-list-get patterns index (ast-pattern-fallback))))
      (ast-compaction-remap-pattern-list-into remap patterns (+ index 1) out))))

(define (ast-compaction-remap-pattern-list
  [remap : (& remap AstProgramCompactionRemap)]
  [patterns : AstPatternList]) : AstPatternList
  (let
    [out : AstPatternList
      (ast-pattern-list-with-capacity (ast-pattern-list-len (& patterns)))]
    (begin
      (ast-compaction-remap-pattern-list-into remap (& patterns) 0 (&mut out))
      out)))

(define (ast-compaction-remap-expr-list
  [remap : (& remap AstProgramCompactionRemap)]
  [exprs : AstExprList]) : AstExprList
  (ast-expr-list-map exprs ast-compaction-remap-expr-id remap))

(define (ast-compaction-remap-expr
  [remap : (& remap AstProgramCompactionRemap)]
  [expr : AstExpr]) : AstExpr
  (ast-expr-map-children
    expr
    ast-compaction-remap-expr-id
    ast-compaction-remap-type-id
    ast-compaction-remap-type
    ast-compaction-remap-pattern
    ast-compaction-remap-literal-hook
    ast-compaction-remap-bytes-hook
    remap))

(define (ast-compaction-remap-expr-id
  [remap : (& remap AstProgramCompactionRemap)]
  [id : i64]) : i64
  (let
    [base : i64 remap.shared-expr-base]
    (if (< id base)
      (begin
        (cfg compile-profile (ast-compaction-profile-note-source-expr!))
        id)
      (let
        [expr-map-address : u64 remap.expr-map-address]
        [slot : i64 (- id base)]
        [cached : i32 (ast-compaction-map-ref expr-map-address slot)]
        [persist? : bool remap.persist-in-place]
        (if (> cached 0)
          (if persist?
            id
            (cast (- cached 1) : i64))
          (if persist?
            ;; Mark BEFORE descending: a shared subgraph reached twice must
            ;; return its id on the second visit rather than rebuild, and a
            ;; re-entrant edge must not recurse forever. The direct source-row
            ;; view remains valid while descendants rewrite other rows because
            ;; segments never relocate. A re-entrant edge observes this mark
            ;; and returns without rewriting its ancestor; only after the
            ;; exhaustive walk has produced `owned-expr` do we rewrite this
            ;; exact row and end the view.
            (let
              [_mark : unit
                (begin
                  (ast-compaction-map-set! expr-map-address slot (cast 1 : i32))
                  (cfg
                    compile-profile
                    (ast-compaction-profile-note-survivor-expr!)))]
              [owned-expr : AstExpr
                (ast-compaction-remap-expr
                  remap
                  (ast-expr-segment-bases-shared-view
                    remap.source-expr-bases
                    id))]
              (begin
                (ast-compaction-remap-dest-expr-set! remap id owned-expr)
                id))
            (let
              [new-expr : AstExpr
                (ast-compaction-remap-expr
                  remap
                  (ast-expr-segment-bases-shared-view
                    remap.source-expr-bases
                    id))]
              [new-id : i64
                (ast-compaction-remap-dest-expr-push remap new-expr)]
              (begin
                (ast-compaction-map-set!
                  expr-map-address
                  slot
                  (cast (+ new-id 1) : i32))
                new-id))))))))

(define (ast-string-same-storage? [left : (& left str)] [right : (& right str)]) : bool
  (and
    (= (__tl_string_length left) (__tl_string_length right))
    (unsafe
      (= (ptr->int (string-data left)) (ptr->int (string-data right))))))

;; Every declaration one macro expansion generates carries the same identity-key
;; String (macro-wrap-generated-decls shares it), and a key can run to hundreds
;; of KB. The compaction copies such a key once and hands the later declarations
;; the same copy, as the source shared it. A key with the storage of the last
;; key copied is the same immutable text, so sharing its copy is unobservable.
(define (ast-compaction-copy-generated-key
  [remap : (& remap AstProgramCompactionRemap)]
  [key : String]) : String
  (unsafe
    (let
      [slots : (MutPtr String)
        (int->ptr remap.generated-key-cache-address : (MutPtr String))]
      [cached-source : String (ptr-read slots)]
      (if (ast-string-same-storage? (& key) (& cached-source))
        (ptr-read (ptr-offset slots 1))
        (let
          [copy : String (string.copy (& key))]
          (begin
            (ptr-write! slots key)
            (ptr-write! (ptr-offset slots 1) (ast-global-shared-view copy))
            copy))))))

(define (ast-compaction-remap-generated-meta
  [remap : (& remap AstProgramCompactionRemap)]
  [meta : AstGeneratedDeclMeta]) : AstGeneratedDeclMeta
  (match meta
    [(AstGeneratedDeclMeta.No) AstGeneratedDeclMeta.No]
    [(AstGeneratedDeclMeta.Some generator item args key)
      (AstGeneratedDeclMeta.Some
        (ast-compaction-copy-string generator)
        (ast-compaction-copy-string item)
        (ast-compaction-remap-expr-list remap args)
        (ast-compaction-copy-generated-key remap key))]))

(define (ast-compaction-remap-decl-meta
  [remap : (& remap AstProgramCompactionRemap)]
  [meta : AstDeclMeta]) : AstDeclMeta
  (match (__tl-box-place meta.value)
    [(AstDeclMetaValue.Runtime markers)
      (ast-decl-meta-runtime-with-aggregate-markers markers)]
    [(AstDeclMetaValue.Comptime generated markers)
      (AstDeclMeta
        (box
          (AstDeclMetaValue.Comptime
            (ast-compaction-remap-generated-meta remap generated)
            markers)))]))

(define (ast-compaction-remap-test-metadata [metadata : AstTestMetadata]) : AstTestMetadata
  (match (__tl-box-place metadata.value)
    [(AstTestMetadataValue.None) (ast-test-metadata-none-shared-view)]
    [(AstTestMetadataValue.Metadata ignore-reason slow)
      (AstTestMetadata
        (box
          (AstTestMetadataValue.Metadata
            (match ignore-reason
              [(AstTestIgnoreReason.No) AstTestIgnoreReason.No]
              [(AstTestIgnoreReason.Some reason)
                (AstTestIgnoreReason.Some (ast-compaction-copy-string reason))])
            slow)))]))

(define (ast-compaction-remap-decl
  [remap : (& remap AstProgramCompactionRemap)]
  [decl : AstDecl]) : AstDecl
  (match decl
    [(AstDecl.Module name) (AstDecl.Module name)]
    [(AstDecl.ModuleBody name body)
      (AstDecl.ModuleBody
        name
        (box (ast-compaction-remap-decl-list remap (deref body))))]
    [(AstDecl.Def decl-meta name maybe-ty value)
      (AstDecl.Def
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-compaction-remap-maybe-type remap maybe-ty)
        (ast-compaction-remap-expr-id remap value))]
    [(AstDecl.DefFn decl-meta name params ret body metadata)
      (AstDecl.DefFn
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-compaction-remap-param-list remap params)
        (ast-compaction-remap-type remap ret)
        (ast-compaction-remap-expr-id remap body)
        (ast-fn-metadata-clone metadata))]
    [(AstDecl.DefMacro decl-meta name params ret body)
      (AstDecl.DefMacro
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-compaction-remap-macro-param-list remap params)
        (ast-compaction-remap-type remap ret)
        (ast-compaction-remap-expr-id remap body))]
    [(AstDecl.Extern decl-meta name kind metadata ty)
      (AstDecl.Extern
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        kind
        (box (ast-compaction-remap-extern-metadata remap (deref metadata)))
        (ast-compaction-remap-type remap ty))]
    [(AstDecl.DefEnum decl-meta name cleanup variants)
      (AstDecl.DefEnum
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-compaction-remap-enum-cleanup cleanup)
        (ast-compaction-remap-variant-def-list remap variants))]
    [(AstDecl.DefEnumLifetimes decl-meta name lifetimes cleanup variants)
      (AstDecl.DefEnumLifetimes
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-lifetime-list-copy lifetimes)
        (ast-compaction-remap-enum-cleanup cleanup)
        (ast-compaction-remap-variant-def-list remap variants))]
    [(AstDecl.DefStruct decl-meta name repr cleanup fields)
      (AstDecl.DefStruct
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-struct-repr-copy repr)
        (ast-compaction-remap-struct-cleanup cleanup)
        (ast-compaction-remap-field-def-list remap fields))]
    [(AstDecl.DefStructLifetimes decl-meta name lifetimes repr cleanup fields)
      (AstDecl.DefStructLifetimes
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-lifetime-list-copy lifetimes)
        (ast-struct-repr-copy repr)
        (ast-compaction-remap-struct-cleanup cleanup)
        (ast-compaction-remap-field-def-list remap fields))]
    [(AstDecl.Import decl-meta spec)
      (AstDecl.Import
        (ast-compaction-remap-decl-meta remap decl-meta)
        (ast-compaction-remap-import-spec remap spec))]
    [(AstDecl.IncludeStr name path)
      (AstDecl.IncludeStr name (ast-compaction-copy-string path))]
    [(AstDecl.IncludeStrComptime name path)
      (AstDecl.IncludeStrComptime name (ast-compaction-copy-string path))]
    [(AstDecl.IncludeStrLzss name path)
      (AstDecl.IncludeStrLzss name (ast-compaction-copy-string path))]
    [(AstDecl.IncludeBin name path)
      (AstDecl.IncludeBin name (ast-compaction-copy-string path))]
    [(AstDecl.DefDispatch decl-meta name variants)
      (AstDecl.DefDispatch
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-compaction-remap-dispatch-variant-list variants))]
    [(AstDecl.Test name body metadata span)
      (AstDecl.Test
        name
        (ast-compaction-remap-expr-id remap body)
        (ast-compaction-remap-test-metadata metadata)
        span)]
    [(AstDecl.Unsafe inner)
      (AstDecl.Unsafe (box (ast-compaction-remap-decl remap (deref inner))))]))

(define (ast-compaction-remap-decl-list
  [remap : (& remap AstProgramCompactionRemap)]
  [decls : AstDeclList]) : AstDeclList
  ;; Index cursor rather than `ast-decl-list-step`: every row is handed to
  ;; `ast-compaction-remap-decl` anyway, so the step result's 144 B and its
  ;; extra row copy buy nothing.
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [decl-offset : i64 decls.offset]
    [decl-slots : (__tl_dyn-array AstDecl) decls.slots]
    [index : i64 0]
    [out : AstDeclList (ast-decl-list-with-capacity count)]
    (begin
      (while (< index count)
        (begin
          (ast-decl-list-push
            (&mut out)
            (ast-compaction-remap-decl
              remap
              (ast-array-shared-view decl-slots (+ decl-offset index))))
          (set! index (+ index 1))))
      out)))

(define (ast-compaction-remap-program
  [remap : (& remap AstProgramCompactionRemap)]
  [program : AstProgram]) : AstProgram
  (match program
    [(AstProgram.Program decls)
      (AstProgram.Program
        (box (ast-compaction-remap-decl-list remap (deref decls))))]))

;: Copy `program` from `source-pools` into a reset `dest-pools`, remapping every
;: reachable expression id and recursive type id into dense destination ids.
;: `dest-pools` is expected to be distinct from `source-pools`.
(define (ast-program-compact-with-pools
  [source-pools : AstNodePoolContext]
  [dest-pools : AstNodePoolContext]
  [program : AstProgram]) : AstProgramCompaction
  (begin
    (ast-node-pool-context-reset-to! dest-pools 0 0)
    ;; A destination semantic node gets one canonical record, from the first
    ;; wrapper the traversal reaches, and copies a distinct source node that
    ;; normally owns one already, so the source's record count is the expected
    ;; size. Reserving it once replaces the doubling copies, which would stay
    ;; dead in the destination arena for the rest of the compile. It is only a
    ;; hint: growth stays checked, and the reserve never exceeds the record
    ;; count the source already holds.
    (let
      [cell : (__tl_dyn-array AstExprNodePoolState)
        (ast-expr-pool-cell dest-pools.expr-pool)]
      (ast-expr-node-pool-state-canonical-records-reserve-in-place!
        (&mut (array-ref cell 0))
        (ast-node-pool-context-expr-canonical-span-count source-pools)))
    (ast-node-pool-compat-context-sync-installed!)
    (let
      [prev-arena : i64 (arena.tl_arena_current)]
      [map-arena : i64 (arena.tl_arena_make)]
      [_set-map-arena : unit
        (unsafe
          (arena.tl_arena_set map-arena))]
      [expr-map : (__tl_dyn-array i32)
        (ast-compaction-id-map-create
          (ast-node-pool-context-expr-len source-pools))]
      [type-map : (__tl_dyn-array i32)
        (ast-compaction-id-map-create
          (ast-node-pool-context-type-len source-pools))]
      [key-cache : (Array String 2) (array "" "")]
      [remap : AstProgramCompactionRemap
        (AstProgramCompactionRemap
          source-pools
          dest-pools
          (ast-i32-array-address expr-map)
          (ast-i32-array-address type-map)
          (ast-node-pool-context-expr-segment-bases source-pools)
          0
          0
          false
          (unsafe
            (ptr->int (__tl_array-data key-cache))))]
      [dest-arena : i64 (ast-node-pool-context-base-arena dest-pools)]
      [out-program : AstProgram
        (begin
          (unsafe
            (arena.tl_arena_set dest-arena))
          (let
            [out : AstProgram (ast-compaction-remap-program remap program)]
            (begin
              (unsafe
                (arena.tl_arena_set prev-arena))
              out)))]
      (begin
        (unsafe
          (arena.tl_arena_destroy map-arena))
        (AstProgramCompaction
          out-program
          (ast-node-pool-context-snapshot dest-pools))))))

;: Copy `program` into the existing tail of `dest-pools`, sharing every source
;: id below the given bases and remapping the rest. Ids below a base are
;: already resident in `dest-pools` with destination-owned payloads, so they are
;: returned unchanged and never descended into; the id maps only cover
;: `[base, len)`. `ast-program-copy-append-with-pools` is this with both bases
;: at zero.
(define (ast-program-copy-append-above-with-pools
  [source-pools : AstNodePoolContext]
  [dest-pools : AstNodePoolContext]
  [program : AstProgram]
  [shared-expr-base : i64]
  [shared-type-base : i64]) : AstProgramCompaction
  (let
    [prev-arena : i64 (arena.tl_arena_current)]
    [map-arena : i64 (arena.tl_arena_make)]
    [_set-map-arena : unit
      (unsafe
        (arena.tl_arena_set map-arena))]
    [expr-map : (__tl_dyn-array i32)
      (ast-compaction-id-map-create
        (- (ast-node-pool-context-expr-len source-pools) shared-expr-base))]
    [type-map : (__tl_dyn-array i32)
      (ast-compaction-id-map-create
        (- (ast-node-pool-context-type-len source-pools) shared-type-base))]
    [_restore-map-arena : unit
      (unsafe
        (arena.tl_arena_set prev-arena))]
    [out : AstProgramCompaction
      (ast-program-copy-append-above-with-maps
        source-pools
        dest-pools
        program
        shared-expr-base
        shared-type-base
        (ast-i32-array-address expr-map)
        (ast-i32-array-address type-map)
        false)]
    (begin
      (unsafe
        (arena.tl_arena_destroy map-arena))
      out)))

;: `ast-program-copy-append-above-with-pools` with the id maps supplied by the
;: caller. A caller that already owns a short-lived arena (the per-declaration
;: macro generation) allocates them there and saves the reserve/release syscall
;: pair a private map arena costs.
;: The maps must be zero-filled: zero is the "unseen"/"unvisited" sentinel.
;: Their addresses point directly at fixed-length backing storage and must stay
;: valid until this copy and every escape-persistence walk using the maps ends.
;:
;: With `persist-in-place`, expression rows at or above `shared-expr-base` are
;: rewritten in place instead of appended, so `dest-pools` does not grow and
;: every id in `program` survives unchanged. Only a caller that owns those ids
;: outright -- because its own transient scope created them and nothing
;: committed can reference them yet -- may pass true.
(define (ast-program-copy-append-above-with-maps
  [source-pools : AstNodePoolContext]
  [dest-pools : AstNodePoolContext]
  [program : AstProgram]
  [shared-expr-base : i64]
  [shared-type-base : i64]
  [expr-map-address : u64]
  [type-map-address : u64]
  [persist-in-place : bool]) : AstProgramCompaction
  (let
    [prev-arena : i64 (arena.tl_arena_current)]
    [key-cache : (Array String 2) (array "" "")]
    [remap : AstProgramCompactionRemap
      (AstProgramCompactionRemap
        source-pools
        dest-pools
        expr-map-address
        type-map-address
        (ast-node-pool-context-expr-segment-bases source-pools)
        shared-expr-base
        shared-type-base
        persist-in-place
        (unsafe
          (ptr->int (__tl_array-data key-cache))))]
    [dest-arena : i64 (ast-node-pool-context-base-arena dest-pools)]
    [out-program : AstProgram
      (begin
        (unsafe
          (arena.tl_arena_set dest-arena))
        (let
          [out : AstProgram (ast-compaction-remap-program remap program)]
          (begin
            (unsafe
              (arena.tl_arena_set prev-arena))
            out)))]
    (AstProgramCompaction
      out-program
      (ast-node-pool-context-snapshot dest-pools))))

;: Copy `program` into the existing tail of `dest-pools`, remapping every
;: reachable source id without discarding declarations already copied there.
;: This is the per-file loader counterpart to whole-program compaction.
(define (ast-program-copy-append-with-pools
  [source-pools : AstNodePoolContext]
  [dest-pools : AstNodePoolContext]
  [program : AstProgram]) : AstProgramCompaction
  (ast-program-copy-append-above-with-pools source-pools dest-pools program 0 0))

(define (ast-type-tag [ty : AstType]) : i64
  (match ty
    [(AstType.I64) 1]
    [(AstType.I32) 2]
    [(AstType.I16) 3]
    [(AstType.I8) 4]
    [(AstType.U64) 5]
    [(AstType.U32) 6]
    [(AstType.U16) 7]
    [(AstType.U8) 8]
    [(AstType.F64) 9]
    [(AstType.F32) 10]
    [(AstType.Bool) 11]
    [(AstType.Char) 12]
    [(AstType.String) 13]
    [(AstType.Str) 30]
    [(AstType.Bytes) 35]
    [(AstType.Unit) 14]
    [(AstType.Never) 15]
    [(AstType.Expr) 16]
    [(AstType.ExprList) 29]
    [(AstType.Func _ _) 17]
    [(AstType.Tuple _) 18]
    [(AstType.Array _ _) 19]
    [(AstType.DynArray _) 20]
    [(AstType.Region _ _) 21]
    [(AstType.Ref _ _) 22]
    [(AstType.MutRef _ _) 23]
    [(AstType.Enum _) 24]
    [(AstType.Struct _) 25]
    [(AstType.Var _) 26]
    [(AstType.CFunc _ _) 38]
    [(AstType.Ptr _) 27]
    [(AstType.MutPtr _) 28]
    [(AstType.Box _) 31]
    [(AstType.EnumArgs _ _) 32]
    [(AstType.StructArgs _ _) 33]
    [(AstType.VarArgs _ _) 34]
    [(AstType.Slice _) 37]
    [(AstType.Invalidate _ _) 39]))

;; The expression a source-span wrapper at ID wraps, or -1 when the node at ID
;; is not one. Readers peel a wrapper through this and read its span from the
;; sidecar (ast-expr-view-span), so they never match the wrapper variant.
(define (ast-expr-span-wrapper-inner [id : i64]) : i64
  (match (ast-node-get id)
    [(AstExpr.Spanned inner _) inner]
    [_ -1]))

(define (ast-expr-unspan [expr : AstExpr]) : AstExpr
  (let
    [fallback : AstExpr (ast-global-shared-view expr)]
    (match expr
      [(AstExpr.Spanned inner-id _) (ast-expr-unspan (ast-node-get inner-id))]
      [(AstExpr.MacroExpansion inner-id _ _)
        (ast-expr-unspan (ast-node-get inner-id))]
      [_ fallback])))

(define (ast-expr-unspan-with-pools
  [pools : (& pools AstNodePoolContext)]
  [expr : AstExpr]) : AstExpr
  (ast-expr-unspan-with-segment-bases
    (ast-node-pool-context-expr-segment-bases pools)
    expr))

(define (ast-expr-unspan-with-segment-bases
  [segment-bases : i64]
  [expr : AstExpr]) : AstExpr
  (let
    [fallback : AstExpr (ast-global-shared-view expr)]
    (match expr
      [(AstExpr.Spanned inner-id _)
        (ast-expr-unspan-with-segment-bases
          segment-bases
          ;; The callee receives the row directly. Neither this frame nor the
          ;; recursive walk mutates or installs an expression-pool context.
          (ast-expr-segment-bases-shared-view segment-bases inner-id))]
      [(AstExpr.MacroExpansion inner-id _ _)
        (ast-expr-unspan-with-segment-bases
          segment-bases
          (ast-expr-segment-bases-shared-view segment-bases inner-id))]
      [_ fallback])))

(define (ast-struct-repr-c? [repr : (& repr AstStructRepr)]) : bool
  (match repr
    [(AstStructRepr.C _ _) true]
    [(AstStructRepr.Default) false]))

;; The field alignments of a struct without any.
(define ast-no-field-aligns-storage : (__tl_dyn-array i64)
  (__tl_make-array i64 0))

(define (ast-no-field-aligns) : AstFieldAligns
  (AstFieldAligns
    (unsafe
      (ptr-read (ptr-addr-of ast-no-field-aligns-storage)))))

;; The number of field alignment entries.
(define (ast-field-aligns-len [fields : (& fields AstFieldAligns)]) : i64
  (array-length fields.slots))

;; Field `index`'s declared alignment, or 0 past the last declared one.
(define (ast-field-aligns-ref
  [fields : (& fields AstFieldAligns)]
  [index : i64]) : i64
  (if (< index (array-length fields.slots))
    (array-ref fields.slots index)
    0))

;; `(:repr c)` without declared alignment.
(define (ast-struct-repr-c) : AstStructRepr
  (AstStructRepr.C 0 (ast-no-field-aligns)))

;; The struct's declared `(:align N)` value, or 0 when it has none.
(define (ast-struct-repr-declared-align [repr : (& repr AstStructRepr)]) : i64
  (match repr
    [(AstStructRepr.C align _) (deref align)]
    [(AstStructRepr.Default) 0]))

;; Field `index`'s declared `(:align N)` value, or 0 when it has none.
(define (ast-struct-repr-field-declared-align
  [repr : (& repr AstStructRepr)]
  [index : i64]) : i64
  (match repr
    [(AstStructRepr.C _ fields) (ast-field-aligns-ref fields index)]
    [(AstStructRepr.Default) 0]))

;; Whether the struct or any of its fields declares an alignment.
(define (ast-struct-repr-declares-align? [repr : (& repr AstStructRepr)]) : bool
  (match repr
    [(AstStructRepr.C align fields)
      (or (> (deref align) 0) (> (ast-field-aligns-len fields) 0))]
    [(AstStructRepr.Default) false]))

;; The first `count` field alignments of `fields` in fresh storage, padded
;; with absent entries.
(define (ast-field-aligns-copy
  [fields : (& fields AstFieldAligns)]
  [count : i64]) : AstFieldAligns
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref out index) (ast-field-aligns-ref fields index))
          (set! index (+ index 1))))
      (AstFieldAligns out))))

;; `repr` with field `index` declaring `align`. The array grows only for a
;; nonzero `align`, so it never ends in an absent entry.
(define (ast-struct-repr-with-field-align
  [repr : AstStructRepr]
  [index : i64]
  [align : i64]) : AstStructRepr
  (if (= align 0)
    repr
    (match repr
      [(AstStructRepr.C struct-align fields)
        (let
          [out : AstFieldAligns (ast-field-aligns-copy (& fields) (+ index 1))]
          (begin
            (set! (array-ref out.slots index) align)
            (AstStructRepr.C struct-align out)))]
      [(AstStructRepr.Default) AstStructRepr.Default])))

;; A copy whose field array owns fresh storage, for moving a declaration into
;; another arena.
(define (ast-struct-repr-copy [repr : AstStructRepr]) : AstStructRepr
  (match repr
    [(AstStructRepr.C align fields)
      (AstStructRepr.C
        align
        (if (= (ast-field-aligns-len (& fields)) 0)
          (ast-no-field-aligns)
          (ast-field-aligns-copy (& fields) (ast-field-aligns-len (& fields)))))]
    [(AstStructRepr.Default) AstStructRepr.Default]))

;; The shared cap on a declared `(:align N)` value: one page on both targets.
(define ast-declared-align-max : i64
  4096)

;; A literal `(:align N)` value: a power of two from 1 through the cap.
(define (ast-declared-align-valid? [align : i64]) : bool
  (and
    (> align 0)
    (<= align ast-declared-align-max)
    (= (bit-and align (- align 1)) 0)))

;; A stored declared alignment: absent (0) or a valid literal value.
(define (ast-declared-align-encodable? [align : i64]) : bool
  (or (= align 0) (ast-declared-align-valid? align)))

;; Whether calls use the platform C convention. A package dependency's
;; function still does until a TypeLisp-internal convention exists.
(define (ast-extern-abi-c? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbi.C) true]
    [(AstExternAbi.CVarargsOpen) true]
    [(AstExternAbi.CVarargsTyped _) true]
    [(AstExternAbi.TypeLisp) true]))

(define (ast-extern-abi-c-varargs? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbi.C) false]
    [(AstExternAbi.CVarargsOpen) true]
    [(AstExternAbi.CVarargsTyped _) true]
    [(AstExternAbi.TypeLisp) false]))

(define (ast-extern-abi-c-varargs-open? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbi.CVarargsOpen) true]
    [_ false]))

(define (ast-extern-abi-c-varargs-typed? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbi.CVarargsTyped _) true]
    [_ false]))

(define (ast-extern-abi-varargs-tail-type [abi : AstExternAbi]) : AstType
  (match abi
    [(AstExternAbi.CVarargsTyped ty) ty]
    [_ (AstType.Unit)]))

(define (ast-lifetime-list-eq-at?
  [a : (& a AstLifetimeList)]
  [b : (& b AstLifetimeList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (= (array-ref a.slots index) (array-ref b.slots index))
      (ast-lifetime-list-eq-at? a b len (+ index 1)))))

(define (ast-lifetime-list-eq? [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (let
    [len : i64 (ast-lifetime-list-len (& a))]
    (and
      (= len (ast-lifetime-list-len (& b)))
      (ast-lifetime-list-eq-at? (& a) (& b) len 0))))

(define (ast-type-eq? [a : AstType] [b : AstType]) : bool
  (ast-type-children-eq? a b ast-type-installed-ids-eq?))

(define (ast-extern-abi-eq? [a : AstExternAbi] [b : AstExternAbi]) : bool
  (match a
    [(AstExternAbi.C)
      (match b
        [(AstExternAbi.C) true]
        [_ false])]
    [(AstExternAbi.CVarargsOpen)
      (match b
        [(AstExternAbi.CVarargsOpen) true]
        [_ false])]
    [(AstExternAbi.CVarargsTyped aty)
      (match b
        [(AstExternAbi.CVarargsTyped bty) (ast-type-eq? aty bty)]
        [_ false])]
    [(AstExternAbi.TypeLisp)
      (match b
        [(AstExternAbi.TypeLisp) true]
        [_ false])]))

;; Read-only walk entry point: snapshot the type pool's segment-bases once, so
;; the recursive workers address nodes exactly as cheaply as `ty-node-get`.
;; Safe because these walkers never push, and pushes are what replace the cell.
(define (ast-type-eq-with-pools?
  [pools : AstNodePoolContext]
  [a : AstType]
  [b : AstType]) : bool
  (ast-type-eq-with-seg-bases?
    (ast-node-pool-context-type-segment-bases pools)
    a
    b))

(define (ast-type-eq-with-seg-bases?
  [seg-bases : i64]
  [a : AstType]
  [b : AstType]) : bool
  (ast-type-children-eq? a b ast-type-seg-ids-eq? seg-bases))

(define (ast-extern-link-input-eq?
  [a : AstExternLinkInput]
  [b : AstExternLinkInput]) : bool
  (match a
    [(AstExternLinkInput.Lib aname)
      (match b
        [(AstExternLinkInput.Lib bname) (string.eq aname bname)]
        [_ false])]
    [(AstExternLinkInput.Search adir)
      (match b
        [(AstExternLinkInput.Search bdir) (string.eq adir bdir)]
        [_ false])]
    [(AstExternLinkInput.Arg aarg)
      (match b
        [(AstExternLinkInput.Arg barg) (string.eq aarg barg)]
        [_ false])]))

(define (ast-extern-link-input-list-eq?
  [a : AstExternLinkInputList]
  [b : AstExternLinkInputList]) : bool
  (let
    [alen : i64 (ast-extern-link-input-list-len (& a))]
    [blen : i64 (ast-extern-link-input-list-len (& b))]
    (and (= alen blen) (ast-extern-link-input-list-eq-at? (& a) (& b) 0 alen))))

(define (ast-extern-link-input-list-eq-at?
  [a : (& a AstExternLinkInputList)]
  [b : (& b AstExternLinkInputList)]
  [index : i64]
  [len : i64]) : bool
  (if (>= index len)
    true
    (and
      (ast-extern-link-input-eq?
        (ast-extern-link-input-list-get
          a
          index
          (ast-extern-link-input-fallback))
        (ast-extern-link-input-list-get
          b
          index
          (ast-extern-link-input-fallback)))
      (ast-extern-link-input-list-eq-at? a b (+ index 1) len))))

(define (ast-extern-metadata-symbol [metadata : AstExternMetadata]) : String
  (match metadata
    [(AstExternMetadata.Metadata _ symbol-id _ _ _)
      (ci.intern-id-str symbol-id)]))

(define (ast-extern-metadata-symbol-id [metadata : AstExternMetadata]) : ci.InternId
  (match metadata
    [(AstExternMetadata.Metadata _ symbol-id _ _ _) symbol-id]))

(define (ast-extern-metadata-abi [metadata : AstExternMetadata]) : AstExternAbi
  (match metadata
    [(AstExternMetadata.Metadata abi _ _ _ _) abi]))

(define (ast-extern-metadata-link-inputs [metadata : AstExternMetadata]) : AstExternLinkInputList
  (match metadata
    [(AstExternMetadata.Metadata _ _ link-inputs _ _) link-inputs]))

(define (ast-extern-metadata-explicit-abi? [metadata : AstExternMetadata]) : bool
  (match metadata
    [(AstExternMetadata.Metadata _ _ _ flags _)
      (ast-extern-metadata-flags-explicit-abi? flags)]))

(define (ast-extern-metadata-symbol-matches-source?
  [metadata : AstExternMetadata]) : bool
  (match metadata
    [(AstExternMetadata.Metadata _ _ _ flags _)
      (ast-extern-metadata-flags-symbol-matches-source? flags)]))

(define (ast-extern-metadata-imported-spmd [metadata : AstExternMetadata]) : AstImportedSpmdMetadata
  (match metadata
    [(AstExternMetadata.Metadata _ _ _ _ imported-spmd) imported-spmd]))

(define (ast-struct-cleanup? [cleanup : AstStructCleanup]) : bool
  (match cleanup
    [(AstStructCleanup.Fn _) true]
    [(AstStructCleanup.No) false]))

(define (ast-enum-cleanup? [cleanup : AstEnumCleanup]) : bool
  (match cleanup
    [(AstEnumCleanup.Fn _) true]
    [(AstEnumCleanup.No) false]))

(define (ast-field-cleanup? [cleanup : AstFieldCleanup]) : bool
  (match cleanup
    [(AstFieldCleanup.Fn _) true]
    [(AstFieldCleanup.Owned) true]
    [(AstFieldCleanup.No) false]))

(define (ast-variant-payload-cleanup? [cleanup : AstVariantPayloadCleanup]) : bool
  (match cleanup
    [(AstVariantPayloadCleanup.Fn _) true]
    [(AstVariantPayloadCleanup.Owned) true]
    [(AstVariantPayloadCleanup.No) false]))