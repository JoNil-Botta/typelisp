;; compiler_ast_types.tl - Self-hosted model of the real TypeLisp AST.
;;
;; This module is intentionally separate from ast_types.tl, which remains the
;; smaller compile_smoke AST. The types below mirror Rust's src/ast.rs and
;; src/types.rs closely enough for the Sexpr -> real-AST parser to target them.
;; Parser result/error wrappers, typechecker registries, inferred types, and
;; lowered IR metadata live elsewhere.
(import compiler_intern as ci)
(import compiler_builtin_ids as cbi)
(import stdlib.array)

;; Arena access for the node-pool grow paths -- a regrown pool array must
;; be allocated in the persistent program arena, never a transient scratch arena
;; (which gets destroyed, leaving the global pool dangling). arena.tl has no
;; imports, so this adds no cycle.
(import stdlib.arena)

(cfg
  compiler-arena-debug
  (extern (tl_arena_debug_protect_never_reset [handle : i64]) : unit (:symbol "tl_arena_debug_protect_never_reset")))
(cfg
  compiler-arena-debug
  (extern (tl_arena_debug_assert_pool_install [handle : i64]) : unit (:symbol "tl_arena_debug_assert_pool_install")))

(define (compiler-arena-debug-protect-never-reset! [_handle : i64]) : unit
  (cfg
    (all compiler-arena-debug (not stage0-seed-bootstrap))
    (tl_arena_debug_protect_never_reset _handle)
    unit))

(define (compiler-arena-debug-assert-pool-install! [_handle : i64]) : unit
  (cfg
    (all compiler-arena-debug (not stage0-seed-bootstrap))
    (tl_arena_debug_assert_pool_install _handle)
    unit))

;; Compiler AST pool storage starts with 16 MiB instead of a general arena's
;; 64 MiB. Larger inputs append general chunks that pack multiple segments.
(define (ast-node-pool-arena-make) : i64
  (arena.tl_arena_make_small))

;; Hash/equality helpers for the ty-node hash-consing table below.
(import stdlib.hash)
(import stdlib.string)

;; Nominal AST nodes carry either a parser intern id or a structural module/name
;; id. Rendering must decode the latter instead of indexing the intern pool with
;; the composite value.
(define (ast-nominal-name-id-display [name-id : i64]) : String
  (let
    [stride : i64 (ci.intern-capacity)]
    [stride2 : i64 (* stride stride)]
    [triple-offset : i64 (+ stride stride2)]
    (cond
      [(and
          (>= name-id triple-offset)
          (< name-id (+ triple-offset (* stride2 stride))))
        (let
          [raw : i64 (- name-id triple-offset)]
          [module-id : i64 (/ raw stride2)]
          [enum-id : i64 (% (/ raw stride) stride)]
          [variant-id : i64 (% raw stride)]
          (string.append
            (ci.intern-str module-id)
            (string.append
              "/"
              (string.append
                (ci.intern-str enum-id)
                (string.append "." (ci.intern-str variant-id))))))]
      [(and (>= name-id stride) (< name-id (+ stride stride2)))
        (let
          [raw : i64 (- name-id stride)]
          (string.append
            (ci.intern-str (/ raw stride))
            (string.append "/" (ci.intern-str (% raw stride)))))]
      [(and (>= name-id 0) (< name-id stride)) (ci.intern-str name-id)]
      [else "<structural-nominal>"])))

(defstruct AstSourceSpan
  (start-line i32)
  (start-col i32)
  (end-line i32)
  (end-col i32))

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
  (cast (struct-get span start-line) : i64))

(define (ast-source-span-start-col [span : AstSourceSpan]) : i64
  (cast (struct-get span start-col) : i64))

(define (ast-source-span-end-line [span : AstSourceSpan]) : i64
  (cast (struct-get span end-line) : i64))

(define (ast-source-span-end-col [span : AstSourceSpan]) : i64
  (cast (struct-get span end-col) : i64))

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

(define (ast-lit-string-text [string-id : i64]) : String
  (ci.intern-str string-id))

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

(define (ast-int-literal-negative? [text : String]) : bool
  (and (> (string.string-length text) 0) (= (string.string-ref text 0) '-')))

(define (ast-int-literal-digits-start [text : String]) : i64
  (if (ast-int-literal-negative? text)
    1
    0))

(define (ast-int-literal-base [text : String]) : i64
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

(define (ast-int-literal-value-start [text : String]) : i64
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
  [text : String]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    (begin
      (while (and (< i end) (= (string.string-ref text i) '0'))
        (set! i (+ i 1)))
      i)))

(define (ast-int-literal-magnitude-leq-limit?
  [text : String]
  [start : i64]
  [end : i64]
  [limit : String]) : bool
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
  [text : String]
  [limit-dec : String]
  [limit-hex : String]
  [limit-bin : String]) : bool
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
  ;; Static callable-parameter effect. Legal only inside Func argument lists.
  (Consume i64))

(defstruct AstTypeList
  (slots (Array i64))
  (len i64))

(defstruct AstLifetimeList
  (slots (Array i64))
  (len i64))

(defenum AstMaybeType
  (No)
  (Some AstType))

(defenum AstBorrowLifetime
  (Inferred)
  (Named i64))

(defenum AstParam
  (Param i64 AstType bool bool))

(defstruct AstParamList
  (slots (Array AstParam))
  (len i64))

(defenum AstMacroTypeKindList
  (Nil)
  (Cons i64 (Box AstMacroTypeKindList)))

(defenum AstMacroParam
  (Param i64 AstType bool AstMacroTypeKindList))

(defstruct AstMacroParamList
  (slots (Array AstMacroParam))
  (len i64))

(defenum AstFieldCleanup
  (No)
  (Fn i64)
  (Owned))

(defenum AstFieldDef
  (Def i64 AstType AstFieldCleanup))

(defstruct AstFieldDefList
  (slots (Array AstFieldDef))
  (len i64))

(defenum AstStructRepr
  (Default)
  (C))

(defenum AstExternAbi
  (C)
  (CVarargsOpen)
  (CVarargsTyped AstType))

(defenum AstExternKind
  (Value)
  (Function))

(defenum AstExternLinkInput
  (Lib String)
  (Search String)
  (Arg String))

(defstruct AstExternLinkInputList
  (slots (Array AstExternLinkInput))
  (len i64))

(defenum AstFnExport
  (No)
  (Export i64))

(defenum AstSpmdParamClass
  (Uniform)
  (Varying))

(defstruct AstSpmdParamClassList
  (slots (Array AstSpmdParamClass))
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
  (slots (Array AstSpmdSpecialization))
  (len i64))

(defenum AstSpmdCallable
  (No)
  (Callable AstSpmdSpecializationList))

;; Package imports remain ordinary scalar externs outside SPMD regions.  The
;; loader copies just the TLCI selection fields into this AST-owned form so the
;; metadata has the same compile-job lifetime as the synthetic extern and the
;; lowerer does not depend on loader/TLCI global state.
(defstruct AstImportedSpmdSpecialization
  (abi i64)
  (backend i64)
  (lanes i64)
  (args i64)
  (result i64)
  (index-param i64)
  (symbol i64))

(defstruct AstImportedSpmdSpecializationList
  (slots (Array AstImportedSpmdSpecialization))
  (len i64))

(defstruct AstImportedSpmdCallable
  (signature i64)
  (specializations AstImportedSpmdSpecializationList))

(defstruct AstImportedSpmdCallableList
  (slots (Array AstImportedSpmdCallable))
  (len i64))

(defenum AstImportedSpmdMetadata
  (No)
  ;; Canonical helper name plus every TLCI callable record having that name.
  ;; An empty list marks a package-owned extern for which no record exists.
  (Package i64 (Box AstImportedSpmdCallableList)))

;; Export and callable metadata are mutually exclusive. Keep the common `No`
;; and export cases inline at the old `AstFnExport` footprint, while boxing the
;; rare specialization list so every ordinary function remains allocation-free.
(defenum AstFnMetadata
  (No)
  (Export i64)
  (SpmdCallable (Box AstSpmdSpecializationList)))

(defenum AstExternMetadata
  ;; The final word packs whether the ABI was explicit and whether the
  ;; link-symbol spelling is the declaration's source spelling. The latter is
  ;; established at the parser/loader boundary so lowering never has to render
  ;; two ids and compare their bytes to recover that identity fact. Packing the
  ;; bits preserves the compact boxed metadata layout.
  (Metadata AstExternAbi i64 AstExternLinkInputList i64 AstImportedSpmdMetadata))

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
  (Fn i64))

(defenum AstEnumCleanup
  (No)
  (Fn i64))

(defenum AstVariantPayloadCleanup
  (No)
  (Fn i64)
  (Owned))

(defstruct AstVariantPayloadCleanupList
  (slots (Array AstVariantPayloadCleanup))
  (len i64))

(defenum AstVariantDef
  (Def i64 AstTypeList AstVariantPayloadCleanupList))

(defstruct AstVariantDefList
  (slots (Array AstVariantDef))
  (len i64))

(defenum AstPattern
  (Var i64 AstMaybeType)
  (Tuple (Box AstPatternList))
  (Wildcard)
  (Binding i64)
  (Variant i64 (Box AstPatternList))
  (Literal AstLiteral))

(defstruct AstPatternList
  (slots (Array AstPattern))
  (len i64))

(defenum AstLetBinding
  (Binding i64 AstMaybeType i64))

(defstruct AstLetBindingList
  (slots (Array AstLetBinding))
  (len i64))

(defenum AstResourceBinding
  (Binding i64 i64 i64 bool))

(defstruct AstResourceBindingList
  (slots (Array AstResourceBinding))
  (len i64))

(defenum AstMatchArm
  (Arm AstPattern i64))

(defstruct AstMatchArmList
  (slots (Array AstMatchArm))
  (len i64))

;; Boxed payload for `AstExpr.Lambda`. Lambdas are rare in the AST, but their
;; inline payload (AstParamList ~80 B + AstMaybeType ~48 B) made
;; `AstExpr.Lambda` the single largest `AstExpr` variant at 144 B -- and because
;; a defenum is laid out as `tag + max(variant)`, every one of the ~2M nodes in
;; the flat node pool paid that 144 B. Boxing the payload collapses the variant
;; to one word, shrinking every node (pool footprint and the per-node
;; `ast-node-get` copy) without slowing the common small variants.
(defenum AstLambda
  (Lambda AstParamList AstMaybeType i64))

;; Boxed payload for `AstExpr.SpmdScan`. With ten fields including two
;; inline `AstType`s, the variant is 152 B -- the largest `AstExpr` variant,
;; which sets the size of every node in the flat pool. spmd-scan is rare, so
;; boxing its payload collapses the variant to one word and shrinks every node.
(defenum AstSpmdScan
  (Scan AstReduceOp i64 AstType i64 i64 i64 AstType i64 i64 i64))

;; Boxed payloads for the 104 B AstExpr tier.
;; AstExpr.Let inlines AstLetBindingList; AstExpr.SpmdReduce has
;; an inline AstType plus six scalars. Boxing both drops the node to 80 B.
(defenum AstLet
  (Let AstLetBindingList i64))

(defenum AstSpmdReduce
  (Reduce AstReduceOp i64 AstType i64 i64 i64 i64))

;; Boxed payloads for the 80 B AstExpr tier.
;; AstExpr.Foreach inlines an AstType plus four scalars;
;; AstExpr.WithResource inlines two list heads. Boxing both drops the node to
;; 56 B (bounded by the AstType-carrying variants like Cast/Ann/Init).
(defenum AstForeach
  (Foreach i64 AstType i64 i64 i64))

(defenum AstWithResource
  (WithResource AstResourceBindingList AstExprList))

;; Boxed payload for `AstExpr.Match`. After boxing AstExpr.Lambda/AstExpr.SpmdScan,
;; `AstExpr.Match i64 AstMatchArmList` is the largest variant at 112 B
;; (its arm list inlines AstMatchArm -> AstPattern -> AstMaybeType -> AstType).
;; Boxing it collapses the variant to one word, dropping the node to 104 B.
(defenum AstMatch
  (Match i64 AstMatchArmList))

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
  (Array AstExprList)
  (DynArray AstExprList)
  (MakeArray AstType i64)
  (ArrayRef i64 i64)
  (ArraySet i64 i64 i64)
  ;; Checked move-out from a compatibility dynamic array. The second operand is
  ;; a parallel bool liveness bitmap; the result is `(Tuple bool T)` whose
  ;; payload is meaningful only when its leading flag is true.
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
  (Ann i64 AstType)
  (Cast i64 AstType)
  (Borrow bool AstBorrowLifetime i64)
  (Match (Box AstMatch))
  (Foreach (Box AstForeach))
  (SpmdReduce (Box AstSpmdReduce))
  (SpmdScan (Box AstSpmdScan))
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
  (TypeLiteral AstType)
  ;; Zero/identity initialization. `(init : T)` carries `AstMaybeType.Some T`;
  ;; contextual `(init)` carries `AstMaybeType.No` until type checking/lowering sees
  ;; an expected type.
  (Init AstMaybeType)
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
  (PtrNull AstType)
  ;; Null check `(ptr-null? p)` on a raw pointer. Result is `bool`.
  (PtrNullCheck i64)
  ;; Unsafe raw-pointer operations. The typechecker admits these only
  ;; inside `(unsafe ...)`; lowering maps them to existing pointer IR.
  (PtrAddrOf i64)
  (PtrRead i64)
  (PtrWrite i64 i64)
  (PtrOffset i64 i64)
  (PtrCast i64 AstType)
  (PtrToInt i64)
  (IntToPtr i64 AstType)
  ;; Low-level FFI bridge operations used by stdlib. These expose raw backing
  ;; storage and process entry state without synthesizing runtime wrapper calls.
  (StringData i64)
  (StringFromBytes i64 i64)
  (ArrayData i64)
  ;; Loader-generated payload for `(include-bin name "path")`. This is not a
  ;; source expression; it typechecks as `(Array u8)` and lowers to static data.
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
  (Syscall AstExprList))

;; --- segmented AST node pool ---
;; AstExpr nodes live in fixed-size segments, referenced by AstNodeId (a flat
;; logical index) instead of i64. Parsing appends nodes without per-node boxes,
;; traversal resolves a segment and offset, and growth never relocates nodes.
;; and the loader needs no per-file deep clone (nodes already persist in the pool).
;; The pool is process-global and reset per compile (see ast-node-pool-reset!),
;; reusing its allocated segments; AstNodeId values stay valid because the pool only
;; grows within a compile (callers truncate via ast-node-pool-mark/reset on parse
;; error). The process-global pool is only the compatibility fallback: compiler
;; and lint drivers install state-owned pools sized for their workloads before
;; parsing. Keep enough room for direct parser/typechecker smoke users without
;; permanently paying for a second selfhost-sized backing array. The fallback
;; retains the proven grow path for larger legacy callers.
;; Plain mutable globals keep the hot compatibility path simple and avoid the
;; global-struct reassignment that previously tripped an opt2 miscompile.
(define ast-expr-node-pool-segment-size : i64
  65536)
(define ast-type-node-pool-segment-size : i64
  1024)
(define ast-expr-node-pool-segment-bytes : i64
  ;; `size-of` on an enum type value reports the handle width, not the
  ;; compiler's inline enum representation. AstExpr occupies 40 bytes in an
  ;; array slot after payload boxing; keep this counter aligned with the arena
  ;; allocation (plus the array's separately profiled 16-byte header).
  (* 65536 40))
(define ast-type-node-pool-segment-bytes : i64
  ;; AstType occupies 24 bytes in an array slot.
  (* 1024 24))
(define ast-node-pool-max-segments : i64
  ;; Preserve the former type pool's practical four-million-node ceiling while
  ;; keeping the fixed base table small (32 KiB per pool).
  4096)

(define (ast-node-pool-segment-base-table-new) : (Array i64)
  (array.make-array i64 ast-node-pool-max-segments))

(define (ast-expr-node-pool-biased-segment-base
  [segment : (Array AstExpr)]
  [segment-index : i64]) : i64
  (-
    (cast
      (unsafe
        (ptr->int (ptr-cast (array-data segment) : (Ptr u8))))
      : i64)
    (* segment-index ast-expr-node-pool-segment-bytes)))

(define ast-node-pool-first-segment : (Array AstExpr)
  (array.make-array AstExpr ast-expr-node-pool-segment-size))
(define ast-node-pool-segment-bases : i64
  (let
    [bases : (Array i64) (ast-node-pool-segment-base-table-new)]
    (begin
      (array-set!
        bases
        0
        (ast-expr-node-pool-biased-segment-base ast-node-pool-first-segment 0))
      (cast
        (unsafe
          (ptr->int (ptr-cast (array-data bases) : (Ptr u8))))
        : i64))))
(define ast-node-pool-segment-count : i64
  1)

;; The program (base) arena, captured at global-init while it is the
;; active arena (the seed make-array above proves an allocation has happened, so
;; this is the real base handle, not the pre-allocation 0 sentinel). The node
;; pools live here for the whole program; a grow MUST allocate the new backing
;; array here too, otherwise -- if the grow fires while a transient scratch arena
;; is active (lowering/optimize) -- the regrown global array is freed when that
;; scratch arena is destroyed, leaving the pool dangling (a non-deterministic
;; use-after-free). This is why the pool previously failed closed.
(define node-pool-base-arena : i64
  (arena.tl_arena_current))
(define ast-node-pool-storage-arena : i64
  0)
(define ty-node-pool-storage-arena : i64
  0)
(define ast-node-pool-count : i64
  0)

(define (node-pool-restore-arena-after-base-alloc!
  [prev-arena : i64]
  [base-arena : i64]
  [head-arena : i64]) : unit
  (unsafe
    (arena.tl_arena_set
      (if (= prev-arena base-arena)
        head-arena
        prev-arena))))

(define (node-pool-restore-arena-after-storage-alloc!
  [prev-arena : i64]
  [old-storage-arena : i64]
  [new-storage-arena : i64]) : unit
  (unsafe
    (arena.tl_arena_set
      (if (= prev-arena old-storage-arena)
        new-storage-arena
        prev-arena))))

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
    [prev-arena : i64 (arena.tl_arena_current)]
    [old-storage-arena : i64 ast-node-pool-storage-arena]
    [storage-root : i64
      (if (= old-storage-arena 0)
        (arena.tl_arena_make)
        old-storage-arena)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set storage-root))]
    [new-segment : (Array AstExpr)
      (array.make-array AstExpr ast-expr-node-pool-segment-size)]
    [new-storage-arena : i64 (arena.tl_arena_current)]
    (begin
      (unsafe
        (ptr-write!
          (ptr-offset
            (int->ptr ast-node-pool-segment-bases : (MutPtr i64))
            segment-index)
          (ast-expr-node-pool-biased-segment-base new-segment segment-index)))
      (node-pool-restore-arena-after-storage-alloc!
        prev-arena
        old-storage-arena
        new-storage-arena)
      (set! ast-node-pool-storage-arena new-storage-arena)
      (set! ast-node-pool-segment-count (+ segment-index 1)))))

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
          (int->ptr (+ biased-base (* id 40)) : (MutPtr i64)))]
      [source : (Ptr i64)
        (unsafe
          (ptr-cast (ptr-addr-of node) : (Ptr i64)))]
      (begin
        (unsafe
          (begin
            (ptr-write! dest (ptr-read source))
            (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
            (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))
            (ptr-write! (ptr-offset dest 3) (ptr-read (ptr-offset source 3)))
            (ptr-write! (ptr-offset dest 4) (ptr-read (ptr-offset source 4)))))
        (set! ast-node-pool-count (+ id 1))
        (ast-node-pool-active-context-capture-expr!)
        id))))

;: Append `node` to the selected AST pool and return its AstNodeId.
(define (ast-node-push [node : AstExpr]) : i64
  (if ast-node-pool-compat-context-explicit?
    (ast-node-pool-context-expr-push ast-node-pool-compat-context node)
    (ast-node-push-active node)))

;: Read the node at `id` from the installed AST pool.
;;
;; IDs below `count` prove both indices valid. Avoid two redundant bounds checks
;; in this hottest compiler operation, but cast through bytes so pointer offset
;; uses AstExpr's real 40-byte inline stride rather than pointer-word stride.
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
      (ptr-read (int->ptr (+ biased-base (* id 40)) : (Ptr AstExpr))))))

;: Overwrite the node at `id` in the selected AST pool (used when a node is
;; rewritten in place).
(define (ast-node-set! [id : i64] [node : AstExpr]) : unit
  (if ast-node-pool-compat-context-explicit?
    (ast-node-pool-context-expr-set! ast-node-pool-compat-context id node)
    (let
      [biased-base : i64
        (unsafe
          (ptr-read
            (ptr-offset
              (int->ptr ast-node-pool-segment-bases : (Ptr i64))
              (shr id 16))))]
      [dest : (MutPtr i64)
        (unsafe
          (int->ptr (+ biased-base (* id 40)) : (MutPtr i64)))]
      [source : (Ptr i64)
        (unsafe
          (ptr-cast (ptr-addr-of node) : (Ptr i64)))]
      (unsafe
        (begin
          (ptr-write! dest (ptr-read source))
          (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
          (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))
          (ptr-write! (ptr-offset dest 3) (ptr-read (ptr-offset source 3)))
          (ptr-write! (ptr-offset dest 4) (ptr-read (ptr-offset source 4))))))))

;: Truncate the pool back to `mark` nodes (used to discard nodes from a failed
;: parse). Reset to 0 between compiles so a fresh compile reuses its segments.
(define (ast-node-pool-truncate! [mark : i64]) : unit
  (begin
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
  (segment-count i64))

(define (ast-expr-node-pool-state-with-base-arena
  [pool : AstExprNodePoolState]
  [base-arena : i64]) : AstExprNodePoolState
  (AstExprNodePoolState
    (struct-get pool segment-bases)
    (struct-get pool count)
    base-arena
    (struct-get pool storage-arena)
    (struct-get pool segment-count)))

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
    [prev-arena : i64 (arena.tl_arena_current)]
    [_set-base-arena : unit
      (unsafe
        (arena.tl_arena_set base-arena))]
    [segment-bases : (Array i64) (ast-node-pool-segment-base-table-new)]
    [base-head : i64 (arena.tl_arena_current)]
    [storage-root : i64 (ast-node-pool-arena-make)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set storage-root))]
    [segment-index : i64 0]
    (begin
      (while (< segment-index segment-count)
        (let
          [segment : (Array AstExpr)
            (array.make-array AstExpr ast-expr-node-pool-segment-size)]
          (begin
            (array-set!
              segment-bases
              segment-index
              (ast-expr-node-pool-biased-segment-base segment segment-index))
            (set! segment-index (+ segment-index 1)))))
      (let
        [storage-arena : i64 (arena.tl_arena_current)]
        (begin
          (node-pool-restore-arena-after-base-alloc!
            prev-arena
            base-arena
            base-head)
          (AstExprNodePoolState
            (cast
              (unsafe
                (ptr->int (ptr-cast (array-data segment-bases) : (Ptr u8))))
              : i64)
            0
            base-head
            storage-arena
            segment-count))))))

(define (ast-expr-node-pool-state-create [capacity : i64]) : AstExprNodePoolState
  (ast-expr-node-pool-state-init capacity (arena.tl_arena_current)))

(define (ast-expr-node-pool-state-len [pool : AstExprNodePoolState]) : i64
  (struct-get pool count))

(define (ast-expr-node-pool-state-capacity [pool : AstExprNodePoolState]) : i64
  (* (struct-get pool segment-count) ast-expr-node-pool-segment-size))

(define (ast-expr-node-pool-state-mark [pool : AstExprNodePoolState]) : i64
  (ast-expr-node-pool-state-len pool))

(define (ast-expr-node-pool-state-reset-to
  [pool : AstExprNodePoolState]
  [mark : i64]) : AstExprNodePoolState
  (AstExprNodePoolState
    (struct-get pool segment-bases)
    mark
    (struct-get pool base-arena)
    (struct-get pool storage-arena)
    (struct-get pool segment-count)))

(define (ast-expr-node-pool-state-reset-to-mark
  [pool : AstExprNodePoolState]
  [mark : i64]) : AstExprNodePoolState
  (ast-expr-node-pool-state-reset-to pool mark))

(define (ast-expr-node-pool-state-grow [pool : AstExprNodePoolState]) : AstExprNodePoolState
  (let
    [segment-bases : i64 (struct-get pool segment-bases)]
    [segment-index : i64 (struct-get pool segment-count)]
    [base-arena : i64 (struct-get pool base-arena)]
    [old-storage-arena : i64 (struct-get pool storage-arena)]
    [prev-arena : i64 (arena.tl_arena_current)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set old-storage-arena))]
    [new-segment : (Array AstExpr)
      (array.make-array AstExpr ast-expr-node-pool-segment-size)]
    [new-storage-arena : i64 (arena.tl_arena_current)]
    [len : i64 (struct-get pool count)]
    (begin
      (unsafe
        (ptr-write!
          (ptr-offset (int->ptr segment-bases : (MutPtr i64)) segment-index)
          (ast-expr-node-pool-biased-segment-base new-segment segment-index)))
      (node-pool-restore-arena-after-storage-alloc!
        prev-arena
        old-storage-arena
        new-storage-arena)
      (AstExprNodePoolState
        segment-bases
        len
        base-arena
        new-storage-arena
        (+ segment-index 1)))))

(define (ast-expr-node-pool-state-push
  [pool : AstExprNodePoolState]
  [node : AstExpr]) : AstExprNodePoolPushResult
  (let
    [ready : AstExprNodePoolState
      (if (>=
        (ast-expr-node-pool-state-len pool)
        (ast-expr-node-pool-state-capacity pool))
        (ast-expr-node-pool-state-grow pool)
        pool)]
    [segment-bases : i64 (struct-get ready segment-bases)]
    [id : i64 (struct-get ready count)]
    [biased-base : i64
      (unsafe
        (ptr-read (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 16))))]
    [dest : (MutPtr i64)
      (unsafe
        (int->ptr (+ biased-base (* id 40)) : (MutPtr i64)))]
    [source : (Ptr i64)
      (unsafe
        (ptr-cast (ptr-addr-of node) : (Ptr i64)))]
    (begin
      (unsafe
        (begin
          (ptr-write! dest (ptr-read source))
          (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
          (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))
          (ptr-write! (ptr-offset dest 3) (ptr-read (ptr-offset source 3)))
          (ptr-write! (ptr-offset dest 4) (ptr-read (ptr-offset source 4)))))
      (AstExprNodePoolPushOk
        (AstExprNodePoolState
          segment-bases
          (+ id 1)
          (struct-get ready base-arena)
          (struct-get ready storage-arena)
          (struct-get ready segment-count))
        id))))

(define (ast-expr-node-pool-state-get [pool : AstExprNodePoolState] [id : i64]) : AstExpr
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset
            (int->ptr (struct-get pool segment-bases) : (Ptr i64))
            (shr id 16))))]
    (unsafe
      (ptr-read (int->ptr (+ biased-base (* id 40)) : (Ptr AstExpr))))))

(define (ast-expr-node-pool-state-set!
  [pool : AstExprNodePoolState]
  [id : i64]
  [node : AstExpr]) : AstExprNodePoolState
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset
            (int->ptr (struct-get pool segment-bases) : (Ptr i64))
            (shr id 16))))]
    [dest : (MutPtr i64)
      (unsafe
        (int->ptr (+ biased-base (* id 40)) : (MutPtr i64)))]
    [source : (Ptr i64)
      (unsafe
        (ptr-cast (ptr-addr-of node) : (Ptr i64)))]
    (begin
      (unsafe
        (begin
          (ptr-write! dest (ptr-read source))
          (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
          (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))
          (ptr-write! (ptr-offset dest 3) (ptr-read (ptr-offset source 3)))
          (ptr-write! (ptr-offset dest 4) (ptr-read (ptr-offset source 4)))))
      pool)))

(define (ast-node-pool-state-capture) : AstExprNodePoolState
  (AstExprNodePoolState
    ast-node-pool-segment-bases
    ast-node-pool-count
    node-pool-base-arena
    ast-node-pool-storage-arena
    ast-node-pool-segment-count))

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
  [segment : (Array AstType)]
  [segment-index : i64]) : i64
  (-
    (cast
      (unsafe
        (ptr->int (ptr-cast (array-data segment) : (Ptr u8))))
      : i64)
    (* segment-index ast-type-node-pool-segment-bytes)))

(define ty-node-pool-first-segment : (Array AstType)
  (array.make-array AstType ast-type-node-pool-segment-size))
(define ty-node-pool-segment-bases : i64
  (let
    [bases : (Array i64) (ast-node-pool-segment-base-table-new)]
    (begin
      (array-set!
        bases
        0
        (ast-type-node-pool-biased-segment-base ty-node-pool-first-segment 0))
      (cast
        (unsafe
          (ptr->int (ptr-cast (array-data bases) : (Ptr u8))))
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

(define (ty-node-pool-capacity) : i64
  (* ty-node-pool-segment-count ast-type-node-pool-segment-size))

(define (ty-node-pool-exhausted?) : bool
  ty-node-pool-exhausted)

(define (ty-node-pool-exhausted-message) : String
  "compiler: AstType node pool exhausted")

;: Add one fixed-size backing segment without relocating earlier nodes.
;;
;; Type IDs use the same stable segment/offset mapping as expression IDs. The
;; smaller segment size follows the measured hash-consed selfhost population.
(define (ty-node-pool-grow!) : unit
  (let
    [segment-index : i64 ty-node-pool-segment-count]
    [prev-arena : i64 (arena.tl_arena_current)]
    [old-storage-arena : i64 ty-node-pool-storage-arena]
    [storage-root : i64
      (if (= old-storage-arena 0)
        (arena.tl_arena_make)
        old-storage-arena)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set storage-root))]
    [new-segment : (Array AstType)
      (array.make-array AstType ast-type-node-pool-segment-size)]
    [new-storage-arena : i64 (arena.tl_arena_current)]
    (begin
      (unsafe
        (ptr-write!
          (ptr-offset
            (int->ptr ty-node-pool-segment-bases : (MutPtr i64))
            segment-index)
          (ast-type-node-pool-biased-segment-base new-segment segment-index)))
      (node-pool-restore-arena-after-storage-alloc!
        prev-arena
        old-storage-arena
        new-storage-arena)
      (set! ty-node-pool-storage-arena new-storage-arena)
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
  (match node
    [(AstType.Func args ret)
      (AstType.Func (box (ty-node-persist-type-list (box-get args))) ret)]
    [(AstType.Tuple args)
      (AstType.Tuple (box (ty-node-persist-type-list (box-get args))))]
    [(AstType.Region name inner) (AstType.Region name inner)]
    [(AstType.Ref name inner) (AstType.Ref name inner)]
    [(AstType.MutRef name inner) (AstType.MutRef name inner)]
    [(AstType.EnumArgs name lifetimes)
      (AstType.EnumArgs
        name
        (box (ty-node-persist-lifetimes (box-get lifetimes))))]
    [(AstType.StructArgs name lifetimes)
      (AstType.StructArgs
        name
        (box (ty-node-persist-lifetimes (box-get lifetimes))))]
    [(AstType.VarArgs name lifetimes)
      (AstType.VarArgs
        name
        (box (ty-node-persist-lifetimes (box-get lifetimes))))]
    [(AstType.Consume inner) (AstType.Consume inner)]
    [_ node]))

;; State-owned type node pools mirror the global type-node backing store while
;; keeping each worker's ids, reset marks, and hash-consing table independent.
;; The compiler hot path still uses the process-global compatibility wrappers
;; until parser/typechecker/driver state is threaded through every call.
(defstruct AstTypeNodePoolState
  (segment-bases i64)
  (count i64)
  (base-arena i64)
  (exhausted bool)
  (dedup-slots (Array i64))
  (dedup-count i64)
  (storage-arena i64)
  (segment-count i64))

(define (ast-type-node-pool-state-with-base-arena
  [pool : AstTypeNodePoolState]
  [base-arena : i64]) : AstTypeNodePoolState
  (AstTypeNodePoolState
    (struct-get pool segment-bases)
    (struct-get pool count)
    base-arena
    (struct-get pool exhausted)
    (struct-get pool dedup-slots)
    (struct-get pool dedup-count)
    (struct-get pool storage-arena)
    (struct-get pool segment-count)))

(defenum AstTypeNodePoolPushResult
  (AstTypeNodePoolPushOk AstTypeNodePoolState i64))

(define (ast-type-node-pool-state-dedup-capacity [capacity : i64]) : i64
  (let
    [want
      : i64
      ;; Large ordinary transformer bodies can exceed the old half-full
      ;; 8K/32K uniqueness budgets before the rest of a self-host check begins.
      ;; The scalar `for` source port measures about 37.5K distinct nodes in a
      ;; full check; retain headroom instead of falling back to millions of
      ;; duplicate raw type nodes.
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
    [prev-arena : i64 (arena.tl_arena_current)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set base-arena))]
    [segment-bases : (Array i64) (ast-node-pool-segment-base-table-new)]
    [dedup-slots : (Array i64) (array.make-array i64 dedup-cap)]
    [head-arena : i64 (arena.tl_arena_current)]
    [storage-root : i64 (ast-node-pool-arena-make)]
    [_set-storage-arena : unit
      (unsafe
        (arena.tl_arena_set storage-root))]
    [segment-index : i64 0]
    (begin
      (while (< segment-index segment-count)
        (let
          [segment : (Array AstType)
            (array.make-array AstType ast-type-node-pool-segment-size)]
          (begin
            (array-set!
              segment-bases
              segment-index
              (ast-type-node-pool-biased-segment-base segment segment-index))
            (set! segment-index (+ segment-index 1)))))
      (let
        [storage-arena : i64 (arena.tl_arena_current)]
        (begin
          (node-pool-restore-arena-after-base-alloc!
            prev-arena
            base-arena
            head-arena)
          (AstTypeNodePoolState
            (cast
              (unsafe
                (ptr->int (ptr-cast (array-data segment-bases) : (Ptr u8))))
              : i64)
            0
            head-arena
            false
            dedup-slots
            0
            storage-arena
            segment-count))))))

(define (ast-type-node-pool-state-create [capacity : i64]) : AstTypeNodePoolState
  (ast-type-node-pool-state-init capacity (arena.tl_arena_current)))

(define (ast-type-node-pool-state-len [pool : AstTypeNodePoolState]) : i64
  (struct-get pool count))

(define (ast-type-node-pool-state-capacity [pool : AstTypeNodePoolState]) : i64
  (* (struct-get pool segment-count) ast-type-node-pool-segment-size))

(define (ast-type-node-pool-state-exhausted? [pool : AstTypeNodePoolState]) : bool
  (struct-get pool exhausted))

(define (ast-type-node-pool-state-mark [pool : AstTypeNodePoolState]) : i64
  (ast-type-node-pool-state-len pool))

(define (ast-type-node-pool-state-dedup-clear [pool : AstTypeNodePoolState]) : AstTypeNodePoolState
  (let
    [slots : (Array i64) (struct-get pool dedup-slots)]
    [cap : i64 (array-length slots)]
    [i : i64 0]
    (begin
      (while (< i cap)
        (begin
          (array-set! slots i 0)
          (set! i (+ i 1))))
      (AstTypeNodePoolState
        (struct-get pool segment-bases)
        (struct-get pool count)
        (struct-get pool base-arena)
        (struct-get pool exhausted)
        slots
        0
        (struct-get pool storage-arena)
        (struct-get pool segment-count)))))

(define (ast-type-node-pool-state-reset-to
  [pool : AstTypeNodePoolState]
  [mark : i64]) : AstTypeNodePoolState
  ;; Reset truncates the node prefix. Clear, rather than rebuild, the dedup
  ;; table so no entry can point at an id >= mark; later pushes repopulate it.
  (ast-type-node-pool-state-dedup-clear
    (AstTypeNodePoolState
      (struct-get pool segment-bases)
      mark
      (struct-get pool base-arena)
      false
      (struct-get pool dedup-slots)
      (struct-get pool dedup-count)
      (struct-get pool storage-arena)
      (struct-get pool segment-count))))

(define (ast-type-node-pool-state-reset-to-mark
  [pool : AstTypeNodePoolState]
  [mark : i64]) : AstTypeNodePoolState
  (ast-type-node-pool-state-reset-to pool mark))

(define (ast-type-node-pool-state-grow [pool : AstTypeNodePoolState]) : AstTypeNodePoolState
  (let
    [segment-bases : i64 (struct-get pool segment-bases)]
    [segment-index : i64 (struct-get pool segment-count)]
    [base-arena : i64 (struct-get pool base-arena)]
    [old-storage-arena : i64 (struct-get pool storage-arena)]
    [prev-arena : i64 (arena.tl_arena_current)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set old-storage-arena))]
    [new-segment : (Array AstType)
      (array.make-array AstType ast-type-node-pool-segment-size)]
    [new-storage-arena : i64 (arena.tl_arena_current)]
    [len : i64 (struct-get pool count)]
    (begin
      (unsafe
        (ptr-write!
          (ptr-offset (int->ptr segment-bases : (MutPtr i64)) segment-index)
          (ast-type-node-pool-biased-segment-base new-segment segment-index)))
      (node-pool-restore-arena-after-storage-alloc!
        prev-arena
        old-storage-arena
        new-storage-arena)
      (AstTypeNodePoolState
        segment-bases
        len
        base-arena
        (struct-get pool exhausted)
        (struct-get pool dedup-slots)
        (struct-get pool dedup-count)
        new-storage-arena
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
    [segment-bases : i64 (struct-get ready segment-bases)]
    [id : i64 (struct-get ready count)]
    [biased-base : i64
      (unsafe
        (ptr-read (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 10))))]
    [base-arena : i64 (struct-get ready base-arena)]
    [prev-arena : i64 (arena.tl_arena_current)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set base-arena))]
    [persistent : AstType (ty-node-persist node)]
    [dest : (MutPtr i64)
      (unsafe
        (int->ptr (+ biased-base (* id 24)) : (MutPtr i64)))]
    [source : (Ptr i64)
      (unsafe
        (ptr-cast (ptr-addr-of persistent) : (Ptr i64)))]
    [head-arena : i64 (arena.tl_arena_current)]
    [_restore-arena : unit
      (node-pool-restore-arena-after-base-alloc!
        prev-arena
        base-arena
        head-arena)]
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
          head-arena
          (struct-get ready exhausted)
          (struct-get ready dedup-slots)
          (struct-get ready dedup-count)
          (struct-get ready storage-arena)
          (struct-get ready segment-count))
        id))))

(define (ast-type-node-pool-state-push-dedup
  [pool : AstTypeNodePoolState]
  [node : AstType]
  [dedup-slots : (Array i64)]
  [dedup-count : i64]
  [idx : i64]
  [mask : i64]) : AstTypeNodePoolPushResult
  (let
    [slot : i64 (array-ref dedup-slots idx)]
    (if (= slot 0)
      (match (ast-type-node-pool-state-push-raw pool node)
        [(AstTypeNodePoolPushOk next id)
          (begin
            (array-set! dedup-slots idx (+ id 1))
            (AstTypeNodePoolPushOk
              (AstTypeNodePoolState
                (struct-get next segment-bases)
                (struct-get next count)
                (struct-get next base-arena)
                (struct-get next exhausted)
                dedup-slots
                (+ dedup-count 1)
                (struct-get next storage-arena)
                (struct-get next segment-count))
              id))])
      (if (ty-node-shallow-value-eq?
        (ast-type-node-pool-state-get pool (- slot 1))
        node)
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
    [dedup-slots : (Array i64) (struct-get pool dedup-slots)]
    [dedup-cap : i64 (array-length dedup-slots)]
    [dedup-count : i64 (struct-get pool dedup-count)]
    (if (>= (* dedup-count 2) dedup-cap)
      (ast-type-node-pool-state-push-raw pool node)
      (let
        [mask : i64 (- dedup-cap 1)]
        [idx : i64 (bit-and (ty-node-hash-value node) mask)]
        (ast-type-node-pool-state-push-dedup
          pool
          node
          dedup-slots
          dedup-count
          idx
          mask)))))

(define (ast-type-node-pool-state-get [pool : AstTypeNodePoolState] [id : i64]) : AstType
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset
            (int->ptr (struct-get pool segment-bases) : (Ptr i64))
            (shr id 10))))]
    (unsafe
      (ptr-read (int->ptr (+ biased-base (* id 24)) : (Ptr AstType))))))

(define (ast-type-node-pool-state-set!
  [pool : AstTypeNodePoolState]
  [id : i64]
  [node : AstType]) : AstTypeNodePoolState
  (let
    [prev-arena : i64 (arena.tl_arena_current)]
    [base-arena : i64 (struct-get pool base-arena)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set base-arena))]
    [persistent : AstType (ty-node-persist node)]
    [head-arena : i64 (arena.tl_arena_current)]
    [_restore-arena : unit
      (node-pool-restore-arena-after-base-alloc!
        prev-arena
        base-arena
        head-arena)]
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset
            (int->ptr (struct-get pool segment-bases) : (Ptr i64))
            (shr id 10))))]
    [dest : (MutPtr i64)
      (unsafe
        (int->ptr (+ biased-base (* id 24)) : (MutPtr i64)))]
    [source : (Ptr i64)
      (unsafe
        (ptr-cast (ptr-addr-of persistent) : (Ptr i64)))]
    (begin
      (unsafe
        (begin
          (ptr-write! dest (ptr-read source))
          (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
          (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2)))))
      ;; Overwriting an existing id can make hash entries stale. Clear the
      ;; private table and let future pushes repopulate it from new candidates.
      (ast-type-node-pool-state-dedup-clear
        (ast-type-node-pool-state-with-base-arena pool head-arena)))))

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
      [prev-arena : i64 (arena.tl_arena_current)]
      [base-arena : i64 node-pool-base-arena]
      [_set-arena : unit
        (unsafe
          (arena.tl_arena_set base-arena))]
      [persistent : AstType (ty-node-persist node)]
      [dest : (MutPtr i64)
        (unsafe
          (int->ptr (+ biased-base (* id 24)) : (MutPtr i64)))]
      [source : (Ptr i64)
        (unsafe
          (ptr-cast (ptr-addr-of persistent) : (Ptr i64)))]
      [head-arena : i64 (arena.tl_arena_current)]
      [_restore-arena : unit
        (node-pool-restore-arena-after-base-alloc!
          prev-arena
          base-arena
          head-arena)]
      (begin
        (set! node-pool-base-arena head-arena)
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
;; equality (child ids included) exact structural equality. A cli.tl compile
;; previously pushed >8M nodes for a few thousand distinct types; hash-consing
;; collapses the pool by orders of magnitude, shrinking both the 40-byte-slot
;; footprint and the pre-sized pool itself. The dedup table is a fixed
;; open-addressing map from node hash to id (+1; 0 = empty), cleared on pool
;; truncate/reset. If it ever passes half load, pushes fall back to plain
;; appends -- only deduplication, never correctness, degrades.
;;
;; Equality is explicit field-wise matching, NOT a byte compare of the slots:
;; enum slot tails beyond a variant's payload are uninitialized, so a byte
;; compare would dedup nondeterministically and break the stage2 == stage3
;; fixpoint. String payloads (lifetime names) compare by content.
(define ty-node-dedup-capacity : i64
  131072)
(define ty-node-dedup-slots : (Array i64)
  (array.make-array i64 131072))
(define ty-node-dedup-count : i64
  0)

(define (ty-node-dedup-clear!) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i ty-node-dedup-capacity)
        (begin
          (array-set! ty-node-dedup-slots i 0)
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
      [name : i64 (array-ref (struct-get items slots) index)]
      (ty-lifetime-list-hash-at items len (hash.combine seed name) (+ index 1)))))

(define (ty-lifetime-list-hash [items : AstLifetimeList] [seed : i64]) : i64
  (ty-lifetime-list-hash-at (& items) (ast-lifetime-list-len (& items)) seed 0))

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
      (hash.combine seed (array-ref (struct-get items slots) index))
      (+ index 1))))

(define (ty-type-list-hash [items : AstTypeList] [seed : i64]) : i64
  (ty-type-list-hash-at (& items) (ast-type-list-len (& items)) seed 0))

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
      (hash.combine (ty-type-list-hash (box-get args) 19) ret)]
    [(AstType.Tuple elems) (ty-type-list-hash (box-get elems) 20)]
    [(AstType.Array elem count) (hash.combine (hash.combine 21 elem) count)]
    [(AstType.DynArray elem) (hash.combine 22 elem)]
    [(AstType.Box inner) (hash.combine 23 inner)]
    [(AstType.Region name inner) (hash.combine (hash.combine 24 name) inner)]
    [(AstType.Ref name inner) (hash.combine (hash.combine 25 name) inner)]
    [(AstType.MutRef name inner) (hash.combine (hash.combine 26 name) inner)]
    [(AstType.Enum name) (hash.combine 27 name)]
    [(AstType.EnumArgs name lifetimes)
      (ty-lifetime-list-hash (box-get lifetimes) (hash.combine 28 name))]
    [(AstType.Struct name) (hash.combine 29 name)]
    [(AstType.StructArgs name lifetimes)
      (ty-lifetime-list-hash (box-get lifetimes) (hash.combine 30 name))]
    [(AstType.Var name) (hash.combine 31 name)]
    [(AstType.VarArgs name lifetimes)
      (ty-lifetime-list-hash (box-get lifetimes) (hash.combine 32 name))]
    [(AstType.Ptr inner) (hash.combine 33 inner)]
    [(AstType.MutPtr inner) (hash.combine 34 inner)]
    [(AstType.Consume inner) (hash.combine 36 inner)]))

(define (ty-lifetime-list-eq-at?
  [a : (& a AstLifetimeList)]
  [b : (& b AstLifetimeList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (=
        (array-ref (struct-get a slots) index)
        (array-ref (struct-get b slots) index))
      (ty-lifetime-list-eq-at? a b len (+ index 1)))))

(define (ty-lifetime-list-eq? [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (let
    [len : i64 (ast-lifetime-list-len (& a))]
    (and
      (= len (ast-lifetime-list-len (& b)))
      (ty-lifetime-list-eq-at? (& a) (& b) len 0))))

(define (ty-type-list-eq-at?
  [a : (& a AstTypeList)]
  [b : (& b AstTypeList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (=
        (array-ref (struct-get a slots) index)
        (array-ref (struct-get b slots) index))
      (ty-type-list-eq-at? a b len (+ index 1)))))

(define (ty-type-list-eq? [a : AstTypeList] [b : AstTypeList]) : bool
  (let
    [len : i64 (ast-type-list-len (& a))]
    (and
      (= len (ast-type-list-len (& b)))
      (ty-type-list-eq-at? (& a) (& b) len 0))))

;; Shallow structural equality between a stored node and a candidate node. Child
;; ids compare as plain integers because children are themselves deduplicated.
(define (ty-node-shallow-value-eq? [a : AstType] [b : AstType]) : bool
  (match a
    [(AstType.I64)
      (match b
        [(AstType.I64) true]
        [_ false])]
    [(AstType.I32)
      (match b
        [(AstType.I32) true]
        [_ false])]
    [(AstType.I16)
      (match b
        [(AstType.I16) true]
        [_ false])]
    [(AstType.I8)
      (match b
        [(AstType.I8) true]
        [_ false])]
    [(AstType.U64)
      (match b
        [(AstType.U64) true]
        [_ false])]
    [(AstType.U32)
      (match b
        [(AstType.U32) true]
        [_ false])]
    [(AstType.U16)
      (match b
        [(AstType.U16) true]
        [_ false])]
    [(AstType.U8)
      (match b
        [(AstType.U8) true]
        [_ false])]
    [(AstType.F64)
      (match b
        [(AstType.F64) true]
        [_ false])]
    [(AstType.F32)
      (match b
        [(AstType.F32) true]
        [_ false])]
    [(AstType.Bool)
      (match b
        [(AstType.Bool) true]
        [_ false])]
    [(AstType.Char)
      (match b
        [(AstType.Char) true]
        [_ false])]
    [(AstType.String)
      (match b
        [(AstType.String) true]
        [_ false])]
    [(AstType.Str)
      (match b
        [(AstType.Str) true]
        [_ false])]
    [(AstType.Bytes)
      (match b
        [(AstType.Bytes) true]
        [_ false])]
    [(AstType.Unit)
      (match b
        [(AstType.Unit) true]
        [_ false])]
    [(AstType.Never)
      (match b
        [(AstType.Never) true]
        [_ false])]
    [(AstType.Expr)
      (match b
        [(AstType.Expr) true]
        [_ false])]
    [(AstType.ExprList)
      (match b
        [(AstType.ExprList) true]
        [_ false])]
    [(AstType.Func a-args a-ret)
      (match b
        [(AstType.Func b-args b-ret)
          (and
            (= a-ret b-ret)
            (ty-type-list-eq? (box-get a-args) (box-get b-args)))]
        [_ false])]
    [(AstType.Tuple a-elems)
      (match b
        [(AstType.Tuple b-elems)
          (ty-type-list-eq? (box-get a-elems) (box-get b-elems))]
        [_ false])]
    [(AstType.Array a-elem a-count)
      (match b
        [(AstType.Array b-elem b-count)
          (and (= a-elem b-elem) (= a-count b-count))]
        [_ false])]
    [(AstType.DynArray a-elem)
      (match b
        [(AstType.DynArray b-elem) (= a-elem b-elem)]
        [_ false])]
    [(AstType.Box a-inner)
      (match b
        [(AstType.Box b-inner) (= a-inner b-inner)]
        [_ false])]
    [(AstType.Region a-name a-inner)
      (match b
        [(AstType.Region b-name b-inner)
          (and (= a-inner b-inner) (= a-name b-name))]
        [_ false])]
    [(AstType.Ref a-name a-inner)
      (match b
        [(AstType.Ref b-name b-inner)
          (and (= a-inner b-inner) (= a-name b-name))]
        [_ false])]
    [(AstType.MutRef a-name a-inner)
      (match b
        [(AstType.MutRef b-name b-inner)
          (and (= a-inner b-inner) (= a-name b-name))]
        [_ false])]
    [(AstType.Enum a-name)
      (match b
        [(AstType.Enum b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.EnumArgs a-name a-lifetimes)
      (match b
        [(AstType.EnumArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ty-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Struct a-name)
      (match b
        [(AstType.Struct b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.StructArgs a-name a-lifetimes)
      (match b
        [(AstType.StructArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ty-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Var a-name)
      (match b
        [(AstType.Var b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.VarArgs a-name a-lifetimes)
      (match b
        [(AstType.VarArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ty-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Ptr a-inner)
      (match b
        [(AstType.Ptr b-inner) (= a-inner b-inner)]
        [_ false])]
    [(AstType.MutPtr a-inner)
      (match b
        [(AstType.MutPtr b-inner) (= a-inner b-inner)]
        [_ false])]
    [(AstType.Consume a-inner)
      (match b
        [(AstType.Consume b-inner) (= a-inner b-inner)]
        [_ false])]))

(define (ty-node-shallow-eq? [a-id : i64] [b : AstType]) : bool
  (ty-node-shallow-value-eq? (ty-node-get a-id) b))

;: Append `node` to the active pool, returning an existing id when an identical node
;: was already pushed. The table is probed before appending so the common
;: duplicate path does not churn the pool count or temporarily force growth.
(define (ty-node-push-active [node : AstType]) : i64
  (if (>= (* ty-node-dedup-count 2) ty-node-dedup-capacity)
    (ty-node-push-raw node)
    (let
      [mask : i64 (- ty-node-dedup-capacity 1)]
      [idx : i64 (bit-and (ty-node-hash-value node) mask)]
      [result : i64 (- 0 1)]
      (begin
        (while (< result 0)
          (let
            [slot : i64 (array-ref ty-node-dedup-slots idx)]
            (if (= slot 0)
              (let
                [id : i64 (ty-node-push-raw node)]
                (begin
                  (array-set! ty-node-dedup-slots idx (+ id 1))
                  (set! ty-node-dedup-count (+ ty-node-dedup-count 1))
                  (set! result id)))
              (if (ty-node-shallow-eq? (- slot 1) node)
                (set! result (- slot 1))
                (set! idx (bit-and (+ idx 1) mask))))))
        result))))

;: Append `node` to the selected type pool.
(define (ty-node-push [node : AstType]) : i64
  (if ast-node-pool-compat-context-explicit?
    (ast-node-pool-context-type-push ast-node-pool-compat-context node)
    (ty-node-push-active node)))

;: Read the type node at `id` from the installed type pool.
;;
;; As with `ast-node-get`, cast the inner backing store through bytes so the
;; unchecked load uses AstType's 24-byte inline stride.
(define (ty-node-get [id : i64]) : AstType
  (let
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset
            (int->ptr ty-node-pool-segment-bases : (Ptr i64))
            (shr id 10))))]
    (unsafe
      (ptr-read (int->ptr (+ biased-base (* id 24)) : (Ptr AstType))))))

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
    ty-node-dedup-slots
    ty-node-dedup-count
    ty-node-pool-storage-arena
    ty-node-pool-segment-count))

(define (ast-node-pools-state-install!
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]) : unit
  (begin
    (set! ast-node-pool-segment-bases (struct-get expr-pool segment-bases))
    (set! ast-node-pool-count (struct-get expr-pool count))
    (set! ast-node-pool-storage-arena (struct-get expr-pool storage-arena))
    (set! ast-node-pool-segment-count (struct-get expr-pool segment-count))
    (set! ty-node-pool-segment-bases (struct-get type-pool segment-bases))
    (set! ty-node-pool-count (struct-get type-pool count))
    (set! ty-node-pool-storage-arena (struct-get type-pool storage-arena))
    (set! ty-node-pool-segment-count (struct-get type-pool segment-count))
    (set! ty-node-pool-generation (+ ty-node-pool-generation 1))
    (set! ty-node-pool-exhausted (struct-get type-pool exhausted))
    (set!
      ty-node-dedup-capacity
      (array-length (struct-get type-pool dedup-slots)))
    (set! ty-node-dedup-slots (struct-get type-pool dedup-slots))
    (set! ty-node-dedup-count (struct-get type-pool dedup-count))
    ;; Driver-created states allocate both pools in one persistent arena. Keep
    ;; the shared compatibility grow/persist target there after both installs.
    (set! node-pool-base-arena (struct-get expr-pool base-arena))))

(defstruct AstNodePoolContext
  (expr-pool (Array AstExprNodePoolState))
  (type-pool (Array AstTypeNodePoolState)))

(define (ast-node-pool-context-from-cells
  [expr-pool : (Array AstExprNodePoolState)]
  [type-pool : (Array AstTypeNodePoolState)]) : AstNodePoolContext
  (AstNodePoolContext expr-pool type-pool))

(define (ast-node-pool-context-new
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]) : AstNodePoolContext
  (let
    [expr-cell : (Array AstExprNodePoolState)
      (array.make-array AstExprNodePoolState 1)]
    [type-cell : (Array AstTypeNodePoolState)
      (array.make-array AstTypeNodePoolState 1)]
    (begin
      (array-set! expr-cell 0 expr-pool)
      (array-set! type-cell 0 type-pool)
      (AstNodePoolContext expr-cell type-cell))))

(define (ast-node-pool-context-capture-active-raw) : AstNodePoolContext
  (ast-node-pool-context-new
    (ast-node-pool-state-capture)
    (ty-node-pool-state-capture)))

(define ast-node-pool-compat-context-explicit? : bool
  false)
(define ast-node-pool-compat-context : AstNodePoolContext
  (ast-node-pool-context-capture-active-raw))
(define ast-node-pool-compat-saved-context : AstNodePoolContext
  (ast-node-pool-context-capture-active-raw))

(define (ast-node-pool-context-capture-active) : AstNodePoolContext
  (if ast-node-pool-compat-context-explicit?
    (ast-node-pool-context-new
      (array-ref (struct-get ast-node-pool-compat-context expr-pool) 0)
      (array-ref (struct-get ast-node-pool-compat-context type-pool) 0))
    (ast-node-pool-context-capture-active-raw)))

(define ast-node-pool-active-context-installed? : bool
  false)
(define ast-node-pool-active-context : AstNodePoolContext
  (ast-node-pool-context-capture-active))

(define (ast-node-pool-active-context-capture-expr!) : unit
  (if ast-node-pool-active-context-installed?
    (array-set!
      (struct-get ast-node-pool-active-context expr-pool)
      0
      (ast-node-pool-state-capture))
    unit))

(define (ast-node-pool-active-context-capture-type!) : unit
  (if ast-node-pool-active-context-installed?
    (array-set!
      (struct-get ast-node-pool-active-context type-pool)
      0
      (ty-node-pool-state-capture))
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
      ast-node-pool-compat-saved-context
      (ast-node-pool-context-capture-active-raw))
    (set! ast-node-pool-compat-context pools)
    (set! ast-node-pool-compat-context-explicit? true)
    (ast-node-pools-state-install!
      (array-ref (struct-get ast-node-pool-compat-context expr-pool) 0)
      (array-ref (struct-get ast-node-pool-compat-context type-pool) 0))))

(define (ast-node-pool-compat-context-clear!) : unit
  (begin
    (ast-node-pools-state-install!
      (array-ref (struct-get ast-node-pool-compat-saved-context expr-pool) 0)
      (array-ref (struct-get ast-node-pool-compat-saved-context type-pool) 0))
    (set! ast-node-pool-compat-context-explicit? false)))

(define (ast-node-pool-compat-context-active?) : bool
  ast-node-pool-compat-context-explicit?)

(define (ast-node-pool-compat-context-current) : AstNodePoolContext
  ast-node-pool-compat-context)

(define (ast-node-pool-compat-context-sync-installed!) : unit
  (if ast-node-pool-compat-context-explicit?
    (ast-node-pools-state-install!
      (array-ref (struct-get ast-node-pool-compat-context expr-pool) 0)
      (array-ref (struct-get ast-node-pool-compat-context type-pool) 0))
    unit))

(define (ast-node-pool-context-snapshot [pools : AstNodePoolContext]) : AstNodePoolContext
  (ast-node-pool-context-new
    (array-ref (struct-get pools expr-pool) 0)
    (array-ref (struct-get pools type-pool) 0)))

(define (ast-node-pool-context-capture-active! [pools : AstNodePoolContext]) : unit
  (if ast-node-pool-compat-context-explicit?
    unit
    (begin
      (array-set! (struct-get pools expr-pool) 0 (ast-node-pool-state-capture))
      (array-set! (struct-get pools type-pool) 0 (ty-node-pool-state-capture)))))

(define (ast-node-pool-active-context-clear!) : unit
  (set! ast-node-pool-active-context-installed? false))

;; The newest segment of the active node-pool chain. The pool arena's live
;; chain is only reachable from this head (overflow segments link newest->root
;; by `prev`), so a reset/destroy that starts from the make() root handle leaks
;; every overflow segment. Callers releasing a grown pool arena must destroy
;; from this head.
(define (ast-node-pool-base-arena-handle) : i64
  node-pool-base-arena)

(define (ast-node-pool-expr-storage-arena-handle) : i64
  ast-node-pool-storage-arena)

(define (ast-node-pool-type-storage-arena-handle) : i64
  ty-node-pool-storage-arena)

(define (ast-node-pool-context-install! [pools : AstNodePoolContext]) : unit
  (if ast-node-pool-compat-context-explicit?
    unit
    (begin
      (compiler-arena-debug-assert-pool-install!
        (struct-get (array-ref (struct-get pools expr-pool) 0) base-arena))
      (ast-node-pools-state-install!
        (array-ref (struct-get pools expr-pool) 0)
        (array-ref (struct-get pools type-pool) 0))
      ;; Update the persistent global struct's fields instead of assigning the
      ;; struct value: the assignment heap-copies the struct in the CURRENT
      ;; arena, leaving the global pointing into freed memory when the install
      ;; runs inside a rewindable declaration/function scratch arena.
      (set!
        (struct-get ast-node-pool-active-context expr-pool)
        (struct-get pools expr-pool))
      (set!
        (struct-get ast-node-pool-active-context type-pool)
        (struct-get pools type-pool))
      (set! ast-node-pool-active-context-installed? true))))

(define (ast-node-pool-context-expr-len [pools : AstNodePoolContext]) : i64
  (ast-expr-node-pool-state-len (array-ref (struct-get pools expr-pool) 0)))

(define (ast-node-pool-context-expr-capacity [pools : AstNodePoolContext]) : i64
  (ast-expr-node-pool-state-capacity (array-ref (struct-get pools expr-pool) 0)))

(define (ast-node-pool-context-expr-segment-count [pools : AstNodePoolContext]) : i64
  (struct-get (array-ref (struct-get pools expr-pool) 0) segment-count))

(define (ast-node-pool-context-expr-segment-bytes [pools : AstNodePoolContext]) : i64
  (*
    (ast-node-pool-context-expr-segment-count pools)
    ast-expr-node-pool-segment-bytes))

(define (ast-node-pool-context-type-len [pools : AstNodePoolContext]) : i64
  (ast-type-node-pool-state-len (array-ref (struct-get pools type-pool) 0)))

(define (ast-node-pool-context-type-capacity [pools : AstNodePoolContext]) : i64
  (ast-type-node-pool-state-capacity (array-ref (struct-get pools type-pool) 0)))

(define (ast-node-pool-context-type-segment-count [pools : AstNodePoolContext]) : i64
  (struct-get (array-ref (struct-get pools type-pool) 0) segment-count))

(define (ast-node-pool-context-type-segment-bytes [pools : AstNodePoolContext]) : i64
  (*
    (ast-node-pool-context-type-segment-count pools)
    ast-type-node-pool-segment-bytes))

(define (ast-node-pool-context-expr-storage-arena [pools : AstNodePoolContext]) : i64
  (struct-get (array-ref (struct-get pools expr-pool) 0) storage-arena))

(define (ast-node-pool-context-type-storage-arena [pools : AstNodePoolContext]) : i64
  (struct-get (array-ref (struct-get pools type-pool) 0) storage-arena))

(define (ast-node-pool-context-type-exhausted? [pools : AstNodePoolContext]) : bool
  (ast-type-node-pool-state-exhausted?
    (array-ref (struct-get pools type-pool) 0)))

(define (ast-node-pool-context-base-arena [pools : AstNodePoolContext]) : i64
  (struct-get (array-ref (struct-get pools expr-pool) 0) base-arena))

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

(define (ast-node-pool-context-sync-base-arena!
  [pools : AstNodePoolContext]
  [base-arena : i64]) : unit
  (begin
    (array-set!
      (struct-get pools expr-pool)
      0
      (ast-expr-node-pool-state-with-base-arena
        (array-ref (struct-get pools expr-pool) 0)
        base-arena))
    (array-set!
      (struct-get pools type-pool)
      0
      (ast-type-node-pool-state-with-base-arena
        (array-ref (struct-get pools type-pool) 0)
        base-arena))))

(define (ast-node-pool-context-new-with-capacities-in-arena
  [expr-capacity : i64]
  [type-capacity : i64]
  [base-arena : i64]) : AstNodePoolContext
  (let
    [expr-pool : AstExprNodePoolState
      (ast-expr-node-pool-state-init expr-capacity base-arena)]
    [type-pool : AstTypeNodePoolState
      (ast-type-node-pool-state-init
        type-capacity
        (struct-get expr-pool base-arena))]
    [shared-arena : i64 (struct-get type-pool base-arena)]
    [previous-arena : i64 (arena.tl_arena_current)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set shared-arena))]
    ;; The context cells are part of the pool's retained ownership graph. If
    ;; they land in the caller's active scratch arena, committing the pool and
    ;; releasing that scratch arena leaves every explicit pool access dangling.
    [pools : AstNodePoolContext
      (ast-node-pool-context-new
        (ast-expr-node-pool-state-with-base-arena expr-pool shared-arena)
        (ast-type-node-pool-state-with-base-arena type-pool shared-arena))]
    [head-arena : i64 (arena.tl_arena_current)]
    (begin
      (ast-node-pool-context-sync-base-arena! pools head-arena)
      (node-pool-restore-arena-after-base-alloc!
        previous-arena
        shared-arena
        head-arena)
      pools)))

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
    (array-set!
      (struct-get pools expr-pool)
      0
      (ast-expr-node-pool-state-reset-to
        (array-ref (struct-get pools expr-pool) 0)
        expr-mark))
    (array-set!
      (struct-get pools type-pool)
      0
      (ast-type-node-pool-state-reset-to
        (array-ref (struct-get pools type-pool) 0)
        type-mark))
    (ast-node-pool-compat-context-sync-installed!)))

;; Clear the type-node dedup index on a captured pool context without
;; truncating any live nodes. Pushes after this rebuild the index from the
;; current node prefix, so a stale dedup entry inherited from a prior batch
;; entry's pool snapshot can never resolve to an id whose slot now holds an
;; unrelated node.
(define (ast-node-pool-context-type-dedup-clear! [pools : AstNodePoolContext]) : unit
  (begin
    (array-set!
      (struct-get pools type-pool)
      0
      (ast-type-node-pool-state-dedup-clear
        (array-ref (struct-get pools type-pool) 0)))
    (ast-node-pool-compat-context-sync-installed!)))

(define (ast-node-pool-context-expr-push
  [pools : AstNodePoolContext]
  [node : AstExpr]) : i64
  (let
    [current : AstExprNodePoolState (array-ref (struct-get pools expr-pool) 0)]
    (match (ast-expr-node-pool-state-push current node)
      [(AstExprNodePoolPushOk next id)
        (begin
          (array-set! (struct-get pools expr-pool) 0 next)
          (if (not
            (= (struct-get current base-arena) (struct-get next base-arena)))
            (ast-node-pool-context-sync-base-arena!
              pools
              (struct-get next base-arena))
            unit)
          (ast-node-pool-compat-context-sync-installed!)
          id)])))

;; Raw expression-node read keyed by the pool's segment-bases pointer rather
;; than a pool value, mirroring `ast-type-segment-bases-get` on the type side.
;; Addressing is `ast-node-get`'s without its process-global load, so a
;; read-only walk that hoists the pointer once pays less per node than the
;; installed-pool fast path (13 instructions against 14 at opt2) instead of the
;; 30 a per-node `AstNodePoolContext` read costs.
(define (ast-expr-segment-bases-get [segment-bases : i64] [id : i64]) : AstExpr
  (let
    [biased-base : i64
      (unsafe
        (ptr-read (ptr-offset (int->ptr segment-bases : (Ptr i64)) (shr id 16))))]
    (unsafe
      (ptr-read (int->ptr (+ biased-base (* id 40)) : (Ptr AstExpr))))))

;; Segment-bases pointer of the context's live expr-pool cell. A grow appends to
;; this table in place and never moves it, and a push rewrites the cell without
;; changing the pointer, so a walk may cache it across reads; only installing a
;; different pool context invalidates it.
(define (ast-node-pool-context-expr-segment-bases [pools : AstNodePoolContext]) : i64
  (struct-get
    (unsafe
      (ptr-read (array-data (struct-get pools expr-pool))))
    segment-bases))

;; Segment-bases pointer of the process-global (installed) expression pool, the
;; one `ast-node-get` reads.
(define (ast-node-pool-active-expr-segment-bases) : i64
  ast-node-pool-segment-bases)

(define (ast-node-pool-context-expr-get [pools : AstNodePoolContext] [id : i64]) : AstExpr
  (ast-expr-segment-bases-get
    (ast-node-pool-context-expr-segment-bases pools)
    id))

(define (ast-node-pool-context-expr-set!
  [pools : AstNodePoolContext]
  [id : i64]
  [node : AstExpr]) : unit
  (begin
    (array-set!
      (struct-get pools expr-pool)
      0
      (ast-expr-node-pool-state-set!
        (array-ref (struct-get pools expr-pool) 0)
        id
        node))
    (ast-node-pool-compat-context-sync-installed!)))

(define (ast-node-pool-context-type-push
  [pools : AstNodePoolContext]
  [node : AstType]) : i64
  (let
    [current : AstTypeNodePoolState (array-ref (struct-get pools type-pool) 0)]
    (match (ast-type-node-pool-state-push current node)
      [(AstTypeNodePoolPushOk next id)
        (begin
          (array-set! (struct-get pools type-pool) 0 next)
          (if (not
            (= (struct-get current base-arena) (struct-get next base-arena)))
            (ast-node-pool-context-sync-base-arena!
              pools
              (struct-get next base-arena))
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
      (ptr-read (int->ptr (+ biased-base (* id 24)) : (Ptr AstType))))))

;; Segment-bases pointer of the context's live type-pool cell. The cell is
;; replaced on every push, so callers may only cache this across pure reads.
(define (ast-node-pool-context-type-segment-bases [pools : AstNodePoolContext]) : i64
  (struct-get (array-ref (struct-get pools type-pool) 0) segment-bases))

(define (ast-node-pool-context-type-get [pools : AstNodePoolContext] [id : i64]) : AstType
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
      (array-ref (struct-get source type-pool) 0)]
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
          (array-ref (struct-get dest type-pool) 0)
          (ast-type-node-pool-state-get source-state i))
          [(AstTypeNodePoolPushOk next _)
            (begin
              (array-set! (struct-get dest type-pool) 0 next)
              (ast-node-pool-context-sync-base-arena!
                dest
                (struct-get next base-arena))
              ;; Raw pushes append exactly once and therefore retain the
              ;; source's insertion-ordered id.
              (set! i (+ i 1)))]))
      (let
        [source-dedup : (Array i64) (struct-get source-state dedup-slots)]
        [dedup-cap : i64 (array-length source-dedup)]
        [dedup-copy : (Array i64) (array.make-array i64 dedup-cap)]
        [dedup-i : i64 0]
        (begin
          (while (< dedup-i dedup-cap)
            (begin
              (array-set! dedup-copy dedup-i (array-ref source-dedup dedup-i))
              (set! dedup-i (+ dedup-i 1))))
          (let
            [cloned : AstTypeNodePoolState
              (array-ref (struct-get dest type-pool) 0)]
            (array-set!
              (struct-get dest type-pool)
              0
              (AstTypeNodePoolState
                (struct-get cloned segment-bases)
                (struct-get cloned count)
                (struct-get cloned base-arena)
                (struct-get source-state exhausted)
                dedup-copy
                (struct-get source-state dedup-count)
                (struct-get cloned storage-arena)
                (struct-get cloned segment-count))))))
      (unsafe
        (arena.tl_arena_set previous-arena))
      dest)))

;; Explicit reader used by compile-job phases. The pools value is intentionally
;; part of the call so interleaved jobs cannot observe whichever context a
;; compatibility caller most recently installed.
(define (ast-node-pool-reader-type-get-with-pools
  [pools : AstNodePoolContext]
  [id : i64]) : AstType
  (ast-node-pool-context-type-get pools id))

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
  (slots (Array i64))
  (len i64))

(defstruct AstExprClause
  (first i64)
  (second i64))

(defstruct AstExprClauseList
  (slots (Array AstExprClause))
  (len i64))

(defstruct AstExprBindingClause
  (name i64)
  (has-type bool)
  (ty i64)
  (init i64)
  ;; Produced-type metadata is populated lazily only for transformers that
  ;; call `expr-type`; ordinary syntax-only binding captures keep the untyped
  ;; sentinel and pay no caller typecheck cost.
  (init-produced AstType)
  (span AstSourceSpan))

(defstruct AstExprBindingClauseList
  (slots (Array AstExprBindingClause))
  (len i64))

(defenum AstMaybeModuleName
  (No)
  (Some i64))

(defenum AstMaybeImportAlias
  (No)
  (Some i64))

(defenum AstImportKind
  (Path)
  (Module)
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
  (slots (Array AstDispatchVariant))
  (len i64))

(defenum AstGeneratedDeclMeta
  (No)
  (Some String String AstExprList String))

(defenum AstDeclMetaValue
  (Runtime)
  (Comptime AstGeneratedDeclMeta))

;; Keep the per-declaration metadata field pointer-sized. An inline tagged
;; AstDeclMeta adds both a tag and a payload word to every AstDecl slot, while
;; only compile-time declarations need storage for the tagged state.
(defstruct AstDeclMeta
  (value (Box AstDeclMetaValue)))

(define ast-decl-meta-runtime : AstDeclMeta
  (AstDeclMeta (box AstDeclMetaValue.Runtime)))

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
  (Test i64 i64 AstSourceSpan)
  (Unsafe (Box AstDecl)))

(defstruct AstDeclList
  (slots (Array AstDecl))
  (offset i64)
  (len i64)
  (prependable bool))

(defenum AstDeclListStep
  (Nil)
  (Cons AstDecl AstDeclList))

(defstruct AstDeclPathList
  (slots (Array String))
  (owner-ids (Array i64))
  (offset i64)
  (len i64)
  (prependable bool))

(defenum AstDeclPathListStep
  (Nil)
  (Cons String AstDeclPathList))

(defstruct AstDeclModuleList
  (slots (Array i64))
  (offset i64)
  (len i64)
  (prependable bool))

(defenum AstProgram
  (Program (Box AstDeclList)))

(define (ast-type-id-fallback) : i64
  0)

(define (ast-type-list-with-capacity [capacity : i64]) : AstTypeList
  (let
    [cap : i64
      (if (< capacity 0)
        0
        capacity)]
    (AstTypeList (array.make-array i64 cap) 0)))

(define (ast-type-list-new) : AstTypeList
  (ast-type-list-with-capacity 0))

(define (ast-type-list-len [v : (& v AstTypeList)]) : i64
  (struct-get v len))

(define (ast-type-list-empty? [v : (& v AstTypeList)]) : bool
  (= (ast-type-list-len v) 0))

(define (ast-type-list-get
  [v : (& v AstTypeList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-type-list-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-type-list-copy-range
  [dst : (&mut dst (Array i64))]
  [src : (& src (Array i64))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-type-list-copy-range dst src (+ index 1) count))))

(define (ast-type-list-grow [v : (&mut v AstTypeList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array i64) (array.make-array i64 new-cap)]
    (begin
      (ast-type-list-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (ast-type-list-push [v : (&mut v AstTypeList)] [value : i64]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-type-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

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

(define (ast-type-list-slice [items : AstTypeList] [start : i64]) : AstTypeList
  (let
    [len : i64 (ast-type-list-len (& items))]
    [out : AstTypeList
      (ast-type-list-with-capacity
        (if (< start len)
          (- len start)
          0))]
    (begin
      (ast-type-list-slice-into (&mut out) (& items) start 0)
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

(define (ast-ty-consume [inner : AstType]) : AstType
  (AstType.Consume (ast-node-pool-reader-type-push inner)))

(define (ast-type-consuming-param? [ty : AstType]) : bool
  (match ty
    [(AstType.Consume _) true]
    [_ false]))

;; Legacy/test adapter. Compile-job callers use the explicit-pools twin below.
(define (ast-type-strip-consuming-param [ty : AstType]) : AstType
  (match ty
    [(AstType.Consume inner) (ast-node-pool-reader-type-get inner)]
    [_ ty]))

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

(define (ast-ty-box [elem : AstType]) : AstType
  (AstType.Box (ast-node-pool-reader-type-push elem)))

(define (ast-ty-region [region : i64] [inner : AstType]) : AstType
  (AstType.Region region (ast-node-pool-reader-type-push inner)))

(define (ast-ty-ref [region : i64] [inner : AstType]) : AstType
  (AstType.Ref region (ast-node-pool-reader-type-push inner)))

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

(define (ast-type-strip-consuming-param-with-pools
  [pools : AstNodePoolContext]
  [ty : AstType]) : AstType
  (match ty
    [(AstType.Consume inner)
      (ast-type-segment-bases-get
        (ast-node-pool-context-type-segment-bases pools)
        inner)]
    [_ ty]))

(define (ast-ty-func-with-pools
  [pools : AstNodePoolContext]
  [args : AstTypeList]
  [ret : AstType]) : AstType
  (AstType.Func (box args) (ast-node-pool-context-type-push pools ret)))

(define (ast-ty-consume-with-pools
  [pools : AstNodePoolContext]
  [inner : AstType]) : AstType
  (AstType.Consume (ast-node-pool-context-type-push pools inner)))

(define (ast-ty-array-with-pools
  [pools : AstNodePoolContext]
  [elem : AstType]
  [count : i64]) : AstType
  (AstType.Array (ast-node-pool-context-type-push pools elem) count))

(define (ast-ty-dyn-array-with-pools
  [pools : AstNodePoolContext]
  [elem : AstType]) : AstType
  (AstType.DynArray (ast-node-pool-context-type-push pools elem)))

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
  (let
    [cap : i64
      (if (< capacity 0)
        0
        capacity)]
    (AstLifetimeList (array.make-array i64 cap) 0)))

(define (ast-lifetime-list-new) : AstLifetimeList
  (ast-lifetime-list-with-capacity 0))

(define (ast-lifetime-list-len [v : (& v AstLifetimeList)]) : i64
  (struct-get v len))

(define (ast-lifetime-list-empty? [v : (& v AstLifetimeList)]) : bool
  (= (ast-lifetime-list-len v) 0))

(define (ast-lifetime-list-get
  [v : (& v AstLifetimeList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-lifetime-list-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-lifetime-list-copy-range
  [dst : (&mut dst (Array i64))]
  [src : (& src (Array i64))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-lifetime-list-copy-range dst src (+ index 1) count))))

(define (ast-lifetime-list-grow [v : (&mut v AstLifetimeList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array i64) (array.make-array i64 new-cap)]
    (begin
      (ast-lifetime-list-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (ast-lifetime-list-push [v : (&mut v AstLifetimeList)] [value : i64]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-lifetime-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

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

(define (ast-param-id [name : i64] [ty : AstType] [is-comptime : bool]) : AstParam
  (AstParam.Param name ty is-comptime false))

(define (ast-param-id-with-consume
  [name : i64]
  [ty : AstType]
  [is-comptime : bool]
  [consume : bool]) : AstParam
  (AstParam.Param name ty is-comptime consume))

(define (ast-param-fallback) : AstParam
  (AstParam.Param 0 (AstType.Unit) false false))

(define (ast-param-list-with-capacity [capacity : i64]) : AstParamList
  (let
    [cap : i64
      (if (< capacity 0)
        0
        capacity)]
    (AstParamList (array.make-array AstParam cap) 0)))

(define (ast-param-list-new) : AstParamList
  (ast-param-list-with-capacity 0))

(define (ast-param-list-len [v : (& v AstParamList)]) : i64
  (struct-get v len))

(define (ast-param-list-get
  [v : (& v AstParamList)]
  [index : i64]
  [fallback : AstParam]) : AstParam
  (if (and (>= index 0) (< index (ast-param-list-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-param-list-copy-range
  [dst : (&mut dst (Array AstParam))]
  [src : (& src (Array AstParam))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-param-list-copy-range dst src (+ index 1) count))))

(define (ast-param-list-grow [v : (&mut v AstParamList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstParam) (array.make-array AstParam new-cap)]
    (begin
      (ast-param-list-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (ast-param-list-push [v : (&mut v AstParamList)] [value : AstParam]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-param-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-param-list-append-from
  [out : (&mut out AstParamList)]
  [items : (& items AstParamList)]
  [index : i64]) : unit
  (if (>= index (ast-param-list-len items))
    unit
    (begin
      (ast-param-list-push
        out
        (ast-param-list-get items index (ast-param-fallback)))
      (ast-param-list-append-from out items (+ index 1)))))

(define (ast-param-cons [head : AstParam] [rest : AstParamList]) : AstParamList
  (let
    [out : AstParamList
      (ast-param-list-with-capacity (+ 1 (ast-param-list-len (& rest))))]
    (begin
      (ast-param-list-push (&mut out) head)
      (ast-param-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-macro-type-kind-list-empty) : AstMacroTypeKindList
  AstMacroTypeKindList.Nil)

(define (ast-macro-type-kind-list-cons-id
  [kind : i64]
  [rest : AstMacroTypeKindList]) : AstMacroTypeKindList
  (AstMacroTypeKindList.Cons kind (box rest)))

(define (ast-macro-type-kind-list-cons
  [kind : i64]
  [rest : AstMacroTypeKindList]) : AstMacroTypeKindList
  (ast-macro-type-kind-list-cons-id kind rest))

(define (ast-macro-type-kind-list-contains-id?
  [kinds : AstMacroTypeKindList]
  [kind : i64]) : bool
  (match kinds
    [(AstMacroTypeKindList.Nil) false]
    [(AstMacroTypeKindList.Cons head rest)
      (or
        (= head kind)
        (ast-macro-type-kind-list-contains-id? (box-get rest) kind))]))

(define (ast-macro-type-kind-list-eq?
  [a : AstMacroTypeKindList]
  [b : AstMacroTypeKindList]) : bool
  (match a
    [(AstMacroTypeKindList.Nil)
      (match b
        [(AstMacroTypeKindList.Nil) true]
        [_ false])]
    [(AstMacroTypeKindList.Cons a-head a-rest)
      (match b
        [(AstMacroTypeKindList.Cons b-head b-rest)
          (and
            (= a-head b-head)
            (ast-macro-type-kind-list-eq? (box-get a-rest) (box-get b-rest)))]
        [_ false])]))

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

(define (ast-macro-param-id [name : i64] [ty : AstType] [variadic : bool]) : AstMacroParam
  (ast-macro-param name ty variadic))

(define (ast-macro-param-fallback) : AstMacroParam
  (AstMacroParam.Param 0 (AstType.Unit) false (ast-macro-type-kind-list-empty)))

(define (ast-macro-param-list-with-capacity [capacity : i64]) : AstMacroParamList
  (let
    [cap : i64
      (if (< capacity 0)
        0
        capacity)]
    (AstMacroParamList (array.make-array AstMacroParam cap) 0)))

(define (ast-macro-param-list-new) : AstMacroParamList
  (ast-macro-param-list-with-capacity 0))

(define (ast-macro-param-list-len [v : (& v AstMacroParamList)]) : i64
  (struct-get v len))

(define (ast-macro-param-list-get
  [v : (& v AstMacroParamList)]
  [index : i64]
  [fallback : AstMacroParam]) : AstMacroParam
  (if (and (>= index 0) (< index (ast-macro-param-list-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-macro-param-list-copy-range
  [dst : (&mut dst (Array AstMacroParam))]
  [src : (& src (Array AstMacroParam))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-macro-param-list-copy-range dst src (+ index 1) count))))

(define (ast-macro-param-list-grow [v : (&mut v AstMacroParamList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstMacroParam) (array.make-array AstMacroParam new-cap)]
    (begin
      (ast-macro-param-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-macro-param-list-push
  [v : (&mut v AstMacroParamList)]
  [value : AstMacroParam]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-macro-param-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-field-cleanup-fn-id [name : i64]) : AstFieldCleanup
  (AstFieldCleanup.Fn name))

(define (ast-field-def-id
  [name : i64]
  [ty : AstType]
  [cleanup : AstFieldCleanup]) : AstFieldDef
  (AstFieldDef.Def name ty cleanup))

(define (ast-field-def-fallback) : AstFieldDef
  (AstFieldDef.Def 0 (AstType.Unit) AstFieldCleanup.No))

(define (ast-field-def-list-with-capacity [capacity : i64]) : AstFieldDefList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstFieldDefList (array.make-array AstFieldDef cap) 0)))

(define (ast-field-def-list-new) : AstFieldDefList
  (ast-field-def-list-with-capacity 4))

(define (ast-field-def-list-len [v : (& v AstFieldDefList)]) : i64
  (struct-get v len))

(define (ast-field-def-list-empty? [v : (& v AstFieldDefList)]) : bool
  (= (struct-get v len) 0))

(define (ast-field-def-list-get
  [v : (& v AstFieldDefList)]
  [index : i64]
  [fallback : AstFieldDef]) : AstFieldDef
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-field-def-list-copy-range
  [dst : (&mut dst (Array AstFieldDef))]
  [src : (& src (Array AstFieldDef))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-field-def-list-copy-range dst src (+ index 1) count))))

(define (ast-field-def-list-grow [v : (&mut v AstFieldDefList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstFieldDef) (array.make-array AstFieldDef new-cap)]
    (begin
      (ast-field-def-list-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (ast-field-def-list-push
  [v : (&mut v AstFieldDefList)]
  [value : AstFieldDef]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-field-def-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-field-def-list-append-from
  [out : (&mut out AstFieldDefList)]
  [items : (& items AstFieldDefList)]
  [index : i64]) : unit
  (if (>= index (struct-get items len))
    unit
    (begin
      (ast-field-def-list-push
        out
        (ast-field-def-list-get items index (ast-field-def-fallback)))
      (ast-field-def-list-append-from out items (+ index 1)))))

(define (ast-field-def-cons [head : AstFieldDef] [rest : AstFieldDefList]) : AstFieldDefList
  (let
    [out : AstFieldDefList
      (ast-field-def-list-with-capacity (+ 1 (struct-get (& rest) len)))]
    (begin
      (ast-field-def-list-push (&mut out) head)
      (ast-field-def-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-extern-link-input-fallback) : AstExternLinkInput
  (AstExternLinkInput.Arg ""))

(define (ast-extern-link-input-list-with-capacity [capacity : i64]) : AstExternLinkInputList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstExternLinkInputList (array.make-array AstExternLinkInput cap) 0)))

(define (ast-extern-link-input-list-new) : AstExternLinkInputList
  (ast-extern-link-input-list-with-capacity 4))

(define (ast-extern-link-input-list-len [v : (& v AstExternLinkInputList)]) : i64
  (struct-get v len))

(define (ast-extern-link-input-list-get
  [v : (& v AstExternLinkInputList)]
  [index : i64]
  [fallback : AstExternLinkInput]) : AstExternLinkInput
  (if (and (>= index 0) (< index (ast-extern-link-input-list-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-extern-link-input-list-copy-range
  [dst : (&mut dst (Array AstExternLinkInput))]
  [src : (& src (Array AstExternLinkInput))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-extern-link-input-list-copy-range dst src (+ index 1) count))))

(define (ast-extern-link-input-list-grow [v : (&mut v AstExternLinkInputList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstExternLinkInput)
      (array.make-array AstExternLinkInput new-cap)]
    (begin
      (ast-extern-link-input-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-extern-link-input-list-push
  [v : (&mut v AstExternLinkInputList)]
  [value : AstExternLinkInput]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-extern-link-input-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-fn-export-id [name : i64]) : AstFnExport
  (AstFnExport.Export name))

(define (ast-spmd-param-class-list-with-capacity [capacity : i64]) : AstSpmdParamClassList
  (AstSpmdParamClassList
    (array.make-array
      AstSpmdParamClass
      (if (< capacity 1)
        1
        capacity))
    0))

(define (ast-spmd-param-class-list-new) : AstSpmdParamClassList
  (ast-spmd-param-class-list-with-capacity 4))

(define (ast-spmd-param-class-list-len
  [items : (& items AstSpmdParamClassList)]) : i64
  (struct-get items len))

(define (ast-spmd-param-class-list-get
  [items : (& items AstSpmdParamClassList)]
  [index : i64]
  [fallback : AstSpmdParamClass]) : AstSpmdParamClass
  (if (and (>= index 0) (< index (struct-get items len)))
    (array-ref (struct-get items slots) index)
    fallback))

(define (ast-spmd-param-class-list-copy-range
  [dst : (&mut dst (Array AstSpmdParamClass))]
  [src : (& src (Array AstSpmdParamClass))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-spmd-param-class-list-copy-range dst src (+ index 1) count))))

(define (ast-spmd-param-class-list-grow
  [items : (&mut items AstSpmdParamClassList)]) : unit
  (let
    [len : i64 (struct-get items len)]
    [old-cap : i64 (array-length (struct-get items slots))]
    [next : (Array AstSpmdParamClass)
      (array.make-array
        AstSpmdParamClass
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (ast-spmd-param-class-list-copy-range
        (&mut next)
        (& (struct-get items slots))
        0
        len)
      (set! (struct-get items slots) next))))

(define (ast-spmd-param-class-list-push
  [items : (&mut items AstSpmdParamClassList)]
  [value : AstSpmdParamClass]) : unit
  (begin
    (if (< (struct-get items len) (array-length (struct-get items slots)))
      unit
      (ast-spmd-param-class-list-grow items))
    (let
      [index : i64 (struct-get items len)]
      (begin
        (array-set! (struct-get items slots) index value)
        (set! (struct-get items len) (+ index 1))))))

(define (ast-spmd-specialization-list-with-capacity [capacity : i64]) : AstSpmdSpecializationList
  (AstSpmdSpecializationList
    (array.make-array
      AstSpmdSpecialization
      (if (< capacity 1)
        1
        capacity))
    0))

(define (ast-spmd-specialization-list-new) : AstSpmdSpecializationList
  (ast-spmd-specialization-list-with-capacity 2))

(define (ast-spmd-specialization-list-len
  [items : (& items AstSpmdSpecializationList)]) : i64
  (struct-get items len))

(define (ast-spmd-specialization-list-get
  [items : (& items AstSpmdSpecializationList)]
  [index : i64]
  [fallback : AstSpmdSpecialization]) : AstSpmdSpecialization
  (if (and (>= index 0) (< index (struct-get items len)))
    (array-ref (struct-get items slots) index)
    fallback))

(define (ast-spmd-specialization-list-copy-range
  [dst : (&mut dst (Array AstSpmdSpecialization))]
  [src : (& src (Array AstSpmdSpecialization))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-spmd-specialization-list-copy-range dst src (+ index 1) count))))

(define (ast-spmd-specialization-list-grow
  [items : (&mut items AstSpmdSpecializationList)]) : unit
  (let
    [len : i64 (struct-get items len)]
    [old-cap : i64 (array-length (struct-get items slots))]
    [next : (Array AstSpmdSpecialization)
      (array.make-array
        AstSpmdSpecialization
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (ast-spmd-specialization-list-copy-range
        (&mut next)
        (& (struct-get items slots))
        0
        len)
      (set! (struct-get items slots) next))))

(define (ast-spmd-specialization-list-push
  [items : (&mut items AstSpmdSpecializationList)]
  [value : AstSpmdSpecialization]) : unit
  (begin
    (if (< (struct-get items len) (array-length (struct-get items slots)))
      unit
      (ast-spmd-specialization-list-grow items))
    (let
      [index : i64 (struct-get items len)]
      (begin
        (array-set! (struct-get items slots) index value)
        (set! (struct-get items len) (+ index 1))))))

(define (ast-spmd-param-class-list-clone [items : AstSpmdParamClassList]) : AstSpmdParamClassList
  (let
    [count : i64 (ast-spmd-param-class-list-len (& items))]
    [out : AstSpmdParamClassList
      (ast-spmd-param-class-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast-spmd-param-class-list-push
            (&mut out)
            (ast-spmd-param-class-list-get
              (& items)
              index
              AstSpmdParamClass.Uniform))
          (set! index (+ index 1))))
      out)))

(define (ast-spmd-specialization-clone [item : AstSpmdSpecialization]) : AstSpmdSpecialization
  (AstSpmdSpecialization
    (struct-get item lanes)
    (box (ast-spmd-param-class-list-clone (box-get (struct-get item args))))
    (struct-get item result)
    (struct-get item index-param)))

(define (ast-spmd-specialization-list-clone [items : AstSpmdSpecializationList]) : AstSpmdSpecializationList
  (let
    [count : i64 (ast-spmd-specialization-list-len (& items))]
    [out : AstSpmdSpecializationList
      (ast-spmd-specialization-list-with-capacity count)]
    [fallback : AstSpmdSpecialization
      (AstSpmdSpecialization
        2
        (box (ast-spmd-param-class-list-new))
        AstSpmdResultClass.Unit
        -1)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast-spmd-specialization-list-push
            (&mut out)
            (ast-spmd-specialization-clone
              (ast-spmd-specialization-list-get (& items) index fallback)))
          (set! index (+ index 1))))
      out)))

(define (ast-imported-spmd-specialization-fallback) : AstImportedSpmdSpecialization
  (AstImportedSpmdSpecialization 0 0 0 0 0 -1 0))

(define (ast-imported-spmd-specialization-list-with-capacity [capacity : i64]) : AstImportedSpmdSpecializationList
  (AstImportedSpmdSpecializationList
    (array.make-array
      AstImportedSpmdSpecialization
      (if (< capacity 1)
        1
        capacity))
    0))

(define (ast-imported-spmd-specialization-list-new) : AstImportedSpmdSpecializationList
  (ast-imported-spmd-specialization-list-with-capacity 2))

(define (ast-imported-spmd-specialization-list-len
  [items : (& items AstImportedSpmdSpecializationList)]) : i64
  (struct-get items len))

(define (ast-imported-spmd-specialization-list-get
  [items : (& items AstImportedSpmdSpecializationList)]
  [index : i64]
  [fallback : AstImportedSpmdSpecialization]) : AstImportedSpmdSpecialization
  (if (and (>= index 0) (< index (struct-get items len)))
    (array-ref (struct-get items slots) index)
    fallback))

(define (ast-imported-spmd-specialization-list-copy-range
  [dst : (&mut dst (Array AstImportedSpmdSpecialization))]
  [src : (& src (Array AstImportedSpmdSpecialization))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-imported-spmd-specialization-list-copy-range
        dst
        src
        (+ index 1)
        count))))

(define (ast-imported-spmd-specialization-list-grow
  [items : (&mut items AstImportedSpmdSpecializationList)]) : unit
  (let
    [len : i64 (struct-get items len)]
    [old-cap : i64 (array-length (struct-get items slots))]
    [next : (Array AstImportedSpmdSpecialization)
      (array.make-array
        AstImportedSpmdSpecialization
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (ast-imported-spmd-specialization-list-copy-range
        (&mut next)
        (& (struct-get items slots))
        0
        len)
      (set! (struct-get items slots) next))))

(define (ast-imported-spmd-specialization-list-push
  [items : (&mut items AstImportedSpmdSpecializationList)]
  [value : AstImportedSpmdSpecialization]) : unit
  (begin
    (if (< (struct-get items len) (array-length (struct-get items slots)))
      unit
      (ast-imported-spmd-specialization-list-grow items))
    (let
      [index : i64 (struct-get items len)]
      (begin
        (array-set! (struct-get items slots) index value)
        (set! (struct-get items len) (+ index 1))))))

(define (ast-imported-spmd-callable-fallback) : AstImportedSpmdCallable
  (AstImportedSpmdCallable 0 (ast-imported-spmd-specialization-list-new)))

(define (ast-imported-spmd-callable-list-with-capacity [capacity : i64]) : AstImportedSpmdCallableList
  (AstImportedSpmdCallableList
    (array.make-array
      AstImportedSpmdCallable
      (if (< capacity 1)
        1
        capacity))
    0))

(define (ast-imported-spmd-callable-list-new) : AstImportedSpmdCallableList
  (ast-imported-spmd-callable-list-with-capacity 1))

(define (ast-imported-spmd-callable-list-len
  [items : (& items AstImportedSpmdCallableList)]) : i64
  (struct-get items len))

(define (ast-imported-spmd-callable-list-get
  [items : (& items AstImportedSpmdCallableList)]
  [index : i64]
  [fallback : AstImportedSpmdCallable]) : AstImportedSpmdCallable
  (if (and (>= index 0) (< index (struct-get items len)))
    (array-ref (struct-get items slots) index)
    fallback))

(define (ast-imported-spmd-callable-list-copy-range
  [dst : (&mut dst (Array AstImportedSpmdCallable))]
  [src : (& src (Array AstImportedSpmdCallable))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-imported-spmd-callable-list-copy-range dst src (+ index 1) count))))

(define (ast-imported-spmd-callable-list-grow
  [items : (&mut items AstImportedSpmdCallableList)]) : unit
  (let
    [len : i64 (struct-get items len)]
    [old-cap : i64 (array-length (struct-get items slots))]
    [next : (Array AstImportedSpmdCallable)
      (array.make-array
        AstImportedSpmdCallable
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (ast-imported-spmd-callable-list-copy-range
        (&mut next)
        (& (struct-get items slots))
        0
        len)
      (set! (struct-get items slots) next))))

(define (ast-imported-spmd-callable-list-push
  [items : (&mut items AstImportedSpmdCallableList)]
  [value : AstImportedSpmdCallable]) : unit
  (begin
    (if (< (struct-get items len) (array-length (struct-get items slots)))
      unit
      (ast-imported-spmd-callable-list-grow items))
    (let
      [index : i64 (struct-get items len)]
      (begin
        (array-set! (struct-get items slots) index value)
        (set! (struct-get items len) (+ index 1))))))

(define (ast-imported-spmd-specialization-list-clone
  [items : AstImportedSpmdSpecializationList]) : AstImportedSpmdSpecializationList
  (let
    [count : i64 (ast-imported-spmd-specialization-list-len (& items))]
    [out : AstImportedSpmdSpecializationList
      (ast-imported-spmd-specialization-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast-imported-spmd-specialization-list-push
            (&mut out)
            (ast-imported-spmd-specialization-list-get
              (& items)
              index
              (ast-imported-spmd-specialization-fallback)))
          (set! index (+ index 1))))
      out)))

(define (ast-imported-spmd-callable-list-clone
  [items : AstImportedSpmdCallableList]) : AstImportedSpmdCallableList
  (let
    [count : i64 (ast-imported-spmd-callable-list-len (& items))]
    [out : AstImportedSpmdCallableList
      (ast-imported-spmd-callable-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [item : AstImportedSpmdCallable
            (ast-imported-spmd-callable-list-get
              (& items)
              index
              (ast-imported-spmd-callable-fallback))]
          (begin
            (ast-imported-spmd-callable-list-push
              (&mut out)
              (AstImportedSpmdCallable
                (struct-get item signature)
                (ast-imported-spmd-specialization-list-clone
                  (struct-get item specializations))))
            (set! index (+ index 1)))))
      out)))

(define (ast-imported-spmd-metadata-clone [metadata : AstImportedSpmdMetadata]) : AstImportedSpmdMetadata
  (match metadata
    [(AstImportedSpmdMetadata.No) AstImportedSpmdMetadata.No]
    [(AstImportedSpmdMetadata.Package name callables)
      (AstImportedSpmdMetadata.Package
        name
        (box (ast-imported-spmd-callable-list-clone (box-get callables))))]))

(define (ast-fn-metadata-clone [metadata : AstFnMetadata]) : AstFnMetadata
  (match metadata
    [(AstFnMetadata.No) AstFnMetadata.No]
    [(AstFnMetadata.Export symbol) (AstFnMetadata.Export symbol)]
    [(AstFnMetadata.SpmdCallable items)
      (AstFnMetadata.SpmdCallable
        (box (ast-spmd-specialization-list-clone (box-get items))))]))

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
      (AstSpmdCallable.Callable (box-get items))]
    [_ AstSpmdCallable.No]))

(define (ast-struct-cleanup-fn-id [name : i64]) : AstStructCleanup
  (AstStructCleanup.Fn name))

(define (ast-enum-cleanup-fn-id [name : i64]) : AstEnumCleanup
  (AstEnumCleanup.Fn name))

(define (ast-variant-payload-cleanup-fn-id [name : i64]) : AstVariantPayloadCleanup
  (AstVariantPayloadCleanup.Fn name))

(define (ast-variant-payload-cleanup-fallback) : AstVariantPayloadCleanup
  AstVariantPayloadCleanup.No)

(define (ast-variant-payload-cleanup-list-with-capacity [capacity : i64]) : AstVariantPayloadCleanupList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstVariantPayloadCleanupList
      (array.make-array AstVariantPayloadCleanup cap)
      0)))

(define (ast-variant-payload-cleanup-list-new) : AstVariantPayloadCleanupList
  (ast-variant-payload-cleanup-list-with-capacity 4))

(define (ast-variant-payload-cleanup-list-len
  [v : (& v AstVariantPayloadCleanupList)]) : i64
  (struct-get v len))

(define (ast-variant-payload-cleanup-list-get
  [v : (& v AstVariantPayloadCleanupList)]
  [index : i64]
  [fallback : AstVariantPayloadCleanup]) : AstVariantPayloadCleanup
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-variant-payload-cleanup-list-copy-range
  [dst : (&mut dst (Array AstVariantPayloadCleanup))]
  [src : (& src (Array AstVariantPayloadCleanup))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-variant-payload-cleanup-list-copy-range dst src (+ index 1) count))))

(define (ast-variant-payload-cleanup-list-grow
  [v : (&mut v AstVariantPayloadCleanupList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstVariantPayloadCleanup)
      (array.make-array AstVariantPayloadCleanup new-cap)]
    (begin
      (ast-variant-payload-cleanup-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-variant-payload-cleanup-list-push
  [v : (&mut v AstVariantPayloadCleanupList)]
  [value : AstVariantPayloadCleanup]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-variant-payload-cleanup-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-variant-payload-cleanup-list-append-from
  [out : (&mut out AstVariantPayloadCleanupList)]
  [items : (& items AstVariantPayloadCleanupList)]
  [index : i64]) : unit
  (if (>= index (struct-get items len))
    unit
    (begin
      (ast-variant-payload-cleanup-list-push
        out
        (ast-variant-payload-cleanup-list-get
          items
          index
          (ast-variant-payload-cleanup-fallback)))
      (ast-variant-payload-cleanup-list-append-from out items (+ index 1)))))

(define (ast-variant-def-id
  [name : i64]
  [fields : AstTypeList]
  [cleanups : AstVariantPayloadCleanupList]) : AstVariantDef
  (AstVariantDef.Def name fields cleanups))

(define (ast-variant-def-fallback) : AstVariantDef
  (AstVariantDef.Def
    0
    (ast-type-list-new)
    (ast-variant-payload-cleanup-list-new)))

(define (ast-variant-def-list-with-capacity [capacity : i64]) : AstVariantDefList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstVariantDefList (array.make-array AstVariantDef cap) 0)))

(define (ast-variant-def-list-new) : AstVariantDefList
  (ast-variant-def-list-with-capacity 4))

(define (ast-variant-def-list-len [v : (& v AstVariantDefList)]) : i64
  (struct-get v len))

(define (ast-variant-def-list-empty? [v : (& v AstVariantDefList)]) : bool
  (= (struct-get v len) 0))

(define (ast-variant-def-list-get
  [v : (& v AstVariantDefList)]
  [index : i64]
  [fallback : AstVariantDef]) : AstVariantDef
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-variant-def-list-copy-range
  [dst : (&mut dst (Array AstVariantDef))]
  [src : (& src (Array AstVariantDef))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-variant-def-list-copy-range dst src (+ index 1) count))))

(define (ast-variant-def-list-grow [v : (&mut v AstVariantDefList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstVariantDef) (array.make-array AstVariantDef new-cap)]
    (begin
      (ast-variant-def-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-variant-def-list-push
  [v : (&mut v AstVariantDefList)]
  [value : AstVariantDef]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-variant-def-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-variant-def-list-append-from
  [out : (&mut out AstVariantDefList)]
  [items : (& items AstVariantDefList)]
  [index : i64]) : unit
  (if (>= index (struct-get items len))
    unit
    (begin
      (ast-variant-def-list-push
        out
        (ast-variant-def-list-get items index (ast-variant-def-fallback)))
      (ast-variant-def-list-append-from out items (+ index 1)))))

(define (ast-variant-def-cons [head : AstVariantDef] [rest : AstVariantDefList]) : AstVariantDefList
  (let
    [out : AstVariantDefList
      (ast-variant-def-list-with-capacity (+ 1 (struct-get (& rest) len)))]
    (begin
      (ast-variant-def-list-push (&mut out) head)
      (ast-variant-def-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-variant-payload-cleanup-cons
  [head : AstVariantPayloadCleanup]
  [rest : AstVariantPayloadCleanupList]) : AstVariantPayloadCleanupList
  (let
    [out : AstVariantPayloadCleanupList
      (ast-variant-payload-cleanup-list-with-capacity
        (+ 1 (struct-get (& rest) len)))]
    (begin
      (ast-variant-payload-cleanup-list-push (&mut out) head)
      (ast-variant-payload-cleanup-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-pattern-fallback) : AstPattern
  AstPattern.Wildcard)

(define (ast-pattern-list-with-capacity [capacity : i64]) : AstPatternList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstPatternList (array.make-array AstPattern cap) 0)))

(define (ast-pattern-list-new) : AstPatternList
  (ast-pattern-list-with-capacity 4))

(define (ast-pattern-list-len [v : (& v AstPatternList)]) : i64
  (struct-get v len))

(define (ast-pattern-list-empty? [v : (& v AstPatternList)]) : bool
  (= (struct-get v len) 0))

(define (ast-pattern-list-get
  [v : (& v AstPatternList)]
  [index : i64]
  [fallback : AstPattern]) : AstPattern
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-pattern-list-copy-range
  [dst : (&mut dst (Array AstPattern))]
  [src : (& src (Array AstPattern))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-pattern-list-copy-range dst src (+ index 1) count))))

(define (ast-pattern-list-grow [v : (&mut v AstPatternList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstPattern) (array.make-array AstPattern new-cap)]
    (begin
      (ast-pattern-list-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (ast-pattern-list-push
  [v : (&mut v AstPatternList)]
  [value : AstPattern]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-pattern-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-pattern-list-append-from
  [out : (&mut out AstPatternList)]
  [items : (& items AstPatternList)]
  [index : i64]) : unit
  (if (>= index (struct-get items len))
    unit
    (begin
      (ast-pattern-list-push
        out
        (ast-pattern-list-get items index (ast-pattern-fallback)))
      (ast-pattern-list-append-from out items (+ index 1)))))

(define (ast-pattern-list-tail [items : AstPatternList]) : AstPatternList
  (let
    [out : AstPatternList
      (ast-pattern-list-with-capacity (- (struct-get (& items) len) 1))]
    (begin
      (ast-pattern-list-append-from (&mut out) (& items) 1)
      out)))

(define (ast-pattern-cons [head : AstPattern] [rest : AstPatternList]) : AstPatternList
  (let
    [out : AstPatternList
      (ast-pattern-list-with-capacity (+ 1 (struct-get (& rest) len)))]
    (begin
      (ast-pattern-list-push (&mut out) head)
      (ast-pattern-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-pat-binding-id [name : i64]) : AstPattern
  (AstPattern.Binding name))

(define (ast-pat-tuple [items : AstPatternList]) : AstPattern
  (AstPattern.Tuple (box items)))

(define (ast-pat-variant-id [name : i64] [items : AstPatternList]) : AstPattern
  (AstPattern.Variant name (box items)))

(define (ast-let-binding-id
  [name : i64]
  [maybe-ty : AstMaybeType]
  [value : i64]) : AstLetBinding
  (AstLetBinding.Binding name maybe-ty value))

(define (ast-let-binding-fallback) : AstLetBinding
  (AstLetBinding.Binding 0 (AstMaybeType.No) 0))

(define (ast-let-binding-list-with-capacity [capacity : i64]) : AstLetBindingList
  (let
    [cap : i64
      (if (< capacity 0)
        0
        capacity)]
    (AstLetBindingList (array.make-array AstLetBinding cap) 0)))

(define (ast-let-binding-list-new) : AstLetBindingList
  (ast-let-binding-list-with-capacity 0))

(define (ast-let-binding-list-len [v : (& v AstLetBindingList)]) : i64
  (struct-get v len))

(define (ast-let-binding-list-empty? [v : (& v AstLetBindingList)]) : bool
  (= (ast-let-binding-list-len v) 0))

(define (ast-let-binding-list-get
  [v : (& v AstLetBindingList)]
  [index : i64]
  [fallback : AstLetBinding]) : AstLetBinding
  (if (and (>= index 0) (< index (ast-let-binding-list-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-let-binding-list-copy-range
  [dst : (&mut dst (Array AstLetBinding))]
  [src : (& src (Array AstLetBinding))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-let-binding-list-copy-range dst src (+ index 1) count))))

(define (ast-let-binding-list-grow [v : (&mut v AstLetBindingList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstLetBinding) (array.make-array AstLetBinding new-cap)]
    (begin
      (ast-let-binding-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-let-binding-list-push
  [v : (&mut v AstLetBindingList)]
  [value : AstLetBinding]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-let-binding-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-let-binding-list-append-from
  [out : (&mut out AstLetBindingList)]
  [items : (& items AstLetBindingList)]
  [index : i64]) : unit
  (if (>= index (ast-let-binding-list-len items))
    unit
    (begin
      (ast-let-binding-list-push
        out
        (ast-let-binding-list-get items index (ast-let-binding-fallback)))
      (ast-let-binding-list-append-from out items (+ index 1)))))

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

(define (ast-move-aware-resource-binding-id
  [name : i64]
  [init : i64]
  [cleanup : i64]) : AstResourceBinding
  (AstResourceBinding.Binding name init cleanup true))

(define (ast-resource-binding-fallback) : AstResourceBinding
  (AstResourceBinding.Binding 0 0 0 false))

(define (ast-resource-binding-list-with-capacity [capacity : i64]) : AstResourceBindingList
  (let
    [cap : i64
      (if (< capacity 0)
        0
        capacity)]
    (AstResourceBindingList (array.make-array AstResourceBinding cap) 0)))

(define (ast-resource-binding-list-new) : AstResourceBindingList
  (ast-resource-binding-list-with-capacity 0))

(define (ast-resource-binding-list-len [v : (& v AstResourceBindingList)]) : i64
  (struct-get v len))

(define (ast-resource-binding-list-get
  [v : (& v AstResourceBindingList)]
  [index : i64]
  [fallback : AstResourceBinding]) : AstResourceBinding
  (if (and (>= index 0) (< index (ast-resource-binding-list-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-resource-binding-list-copy-range
  [dst : (&mut dst (Array AstResourceBinding))]
  [src : (& src (Array AstResourceBinding))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-resource-binding-list-copy-range dst src (+ index 1) count))))

(define (ast-resource-binding-list-grow [v : (&mut v AstResourceBindingList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstResourceBinding)
      (array.make-array AstResourceBinding new-cap)]
    (begin
      (ast-resource-binding-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-resource-binding-list-push
  [v : (&mut v AstResourceBindingList)]
  [value : AstResourceBinding]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-resource-binding-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-resource-binding-list-append-from
  [out : (&mut out AstResourceBindingList)]
  [items : (& items AstResourceBindingList)]
  [index : i64]) : unit
  (if (>= index (ast-resource-binding-list-len items))
    unit
    (begin
      (ast-resource-binding-list-push
        out
        (ast-resource-binding-list-get
          items
          index
          (ast-resource-binding-fallback)))
      (ast-resource-binding-list-append-from out items (+ index 1)))))

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

(define (ast-match-arm-list-with-capacity [capacity : i64]) : AstMatchArmList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstMatchArmList (array.make-array AstMatchArm cap) 0)))

(define (ast-match-arm-list-new) : AstMatchArmList
  (ast-match-arm-list-with-capacity 4))

(define (ast-match-arm-list-len [v : (& v AstMatchArmList)]) : i64
  (struct-get v len))

(define (ast-match-arm-list-empty? [v : (& v AstMatchArmList)]) : bool
  (= (struct-get v len) 0))

(define (ast-match-arm-list-get
  [v : (& v AstMatchArmList)]
  [index : i64]
  [fallback : AstMatchArm]) : AstMatchArm
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-match-arm-list-copy-range
  [dst : (&mut dst (Array AstMatchArm))]
  [src : (& src (Array AstMatchArm))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-match-arm-list-copy-range dst src (+ index 1) count))))

(define (ast-match-arm-list-grow [v : (&mut v AstMatchArmList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstMatchArm) (array.make-array AstMatchArm new-cap)]
    (begin
      (ast-match-arm-list-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (ast-match-arm-list-push
  [v : (&mut v AstMatchArmList)]
  [value : AstMatchArm]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-match-arm-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-match-arm-list-append-from
  [out : (&mut out AstMatchArmList)]
  [items : (& items AstMatchArmList)]
  [index : i64]) : unit
  (if (>= index (struct-get items len))
    unit
    (begin
      (ast-match-arm-list-push
        out
        (ast-match-arm-list-get items index (ast-match-arm-fallback)))
      (ast-match-arm-list-append-from out items (+ index 1)))))

(define (ast-match-arm-list-tail [items : AstMatchArmList]) : AstMatchArmList
  (let
    [out : AstMatchArmList
      (ast-match-arm-list-with-capacity (- (struct-get (& items) len) 1))]
    (begin
      (ast-match-arm-list-append-from (&mut out) (& items) 1)
      out)))

(define (ast-match-arm-cons [head : AstMatchArm] [rest : AstMatchArmList]) : AstMatchArmList
  (let
    [out : AstMatchArmList
      (ast-match-arm-list-with-capacity (+ 1 (struct-get (& rest) len)))]
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
    (AstExprList (array.make-array i64 cap) 0)))

(define (ast-expr-list-new) : AstExprList
  (ast-expr-list-with-capacity 4))

(define (ast-expr-list-len [v : (& v AstExprList)]) : i64
  (struct-get v len))

(define (ast-expr-list-empty? [v : (& v AstExprList)]) : bool
  (= (struct-get v len) 0))

(define (ast-expr-list-get
  [v : (& v AstExprList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-expr-list-copy-range
  [dst : (&mut dst (Array i64))]
  [src : (& src (Array i64))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-expr-list-copy-range dst src (+ index 1) count))))

(define (ast-expr-list-grow [v : (&mut v AstExprList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array i64) (array.make-array i64 new-cap)]
    (begin
      (ast-expr-list-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (ast-expr-list-push [v : (&mut v AstExprList)] [value : i64]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-expr-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-expr-list-append-from
  [out : (&mut out AstExprList)]
  [items : (& items AstExprList)]
  [index : i64]) : unit
  (if (>= index (struct-get items len))
    unit
    (begin
      (ast-expr-list-push out (ast-expr-list-get items index 0))
      (ast-expr-list-append-from out items (+ index 1)))))

(define (ast-expr-list-tail [items : AstExprList]) : AstExprList
  (let
    [out : AstExprList
      (ast-expr-list-with-capacity (- (struct-get (& items) len) 1))]
    (begin
      (ast-expr-list-append-from (&mut out) (& items) 1)
      out)))

(define (ast-expr-list-tail-from-ref
  [items : (& items AstExprList)]
  [index : i64]) : AstExprList
  (let
    [out : AstExprList
      (ast-expr-list-with-capacity (- (struct-get items len) index))]
    (begin
      (ast-expr-list-append-from (&mut out) items index)
      out)))

(define (ast-expr-cons [head : i64] [rest : AstExprList]) : AstExprList
  (let
    [out : AstExprList
      (ast-expr-list-with-capacity (+ 1 (struct-get (& rest) len)))]
    (begin
      (ast-expr-list-push (&mut out) head)
      (ast-expr-list-append-from (&mut out) (& rest) 0)
      out)))

(define (ast-expr-clause [first : i64] [second : i64]) : AstExprClause
  (AstExprClause first second))

(define (ast-expr-clause-fallback) : AstExprClause
  (AstExprClause 0 0))

(define (ast-expr-clause-list-with-capacity [capacity : i64]) : AstExprClauseList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstExprClauseList (array.make-array AstExprClause cap) 0)))

(define (ast-expr-clause-list-new) : AstExprClauseList
  (ast-expr-clause-list-with-capacity 4))

(define (ast-expr-clause-list-empty? [v : (& v AstExprClauseList)]) : bool
  (= (struct-get v len) 0))

(define (ast-expr-clause-list-get
  [v : (& v AstExprClauseList)]
  [index : i64]
  [fallback : AstExprClause]) : AstExprClause
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-expr-clause-list-copy-range
  [dst : (&mut dst (Array AstExprClause))]
  [src : (& src (Array AstExprClause))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-expr-clause-list-copy-range dst src (+ index 1) count))))

(define (ast-expr-clause-list-grow [v : (&mut v AstExprClauseList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstExprClause) (array.make-array AstExprClause new-cap)]
    (begin
      (ast-expr-clause-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-expr-clause-list-push
  [v : (&mut v AstExprClauseList)]
  [value : AstExprClause]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-expr-clause-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-expr-clause-list-tail [items : AstExprClauseList]) : AstExprClauseList
  (let
    [out : AstExprClauseList
      (ast-expr-clause-list-with-capacity (- (struct-get (& items) len) 1))]
    [index : i64 1]
    (begin
      (while (< index (struct-get (& items) len))
        (begin
          (ast-expr-clause-list-push
            (&mut out)
            (ast-expr-clause-list-get
              (& items)
              index
              (ast-expr-clause-fallback)))
          (set! index (+ index 1))))
      out)))

(define (ast-expr-binding-clause-id
  [name : i64]
  [has-type : bool]
  [ty : i64]
  [init : i64]
  [init-produced : AstType]
  [span : AstSourceSpan]) : AstExprBindingClause
  (AstExprBindingClause name has-type ty init init-produced span))

(define (ast-expr-binding-clause-fallback) : AstExprBindingClause
  (AstExprBindingClause 0 false 0 0 (AstType.Var -3) (ast-source-span 0 0 0 0)))

(define (ast-expr-binding-clause-list-with-capacity [capacity : i64]) : AstExprBindingClauseList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstExprBindingClauseList (array.make-array AstExprBindingClause cap) 0)))

(define (ast-expr-binding-clause-list-new) : AstExprBindingClauseList
  (ast-expr-binding-clause-list-with-capacity 4))

(define (ast-expr-binding-clause-list-empty?
  [v : (& v AstExprBindingClauseList)]) : bool
  (= (struct-get v len) 0))

(define (ast-expr-binding-clause-list-get
  [v : (& v AstExprBindingClauseList)]
  [index : i64]
  [fallback : AstExprBindingClause]) : AstExprBindingClause
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-expr-binding-clause-list-copy-range
  [dst : (&mut dst (Array AstExprBindingClause))]
  [src : (& src (Array AstExprBindingClause))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-expr-binding-clause-list-copy-range dst src (+ index 1) count))))

(define (ast-expr-binding-clause-list-grow
  [v : (&mut v AstExprBindingClauseList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstExprBindingClause)
      (array.make-array AstExprBindingClause new-cap)]
    (begin
      (ast-expr-binding-clause-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-expr-binding-clause-list-push
  [v : (&mut v AstExprBindingClauseList)]
  [value : AstExprBindingClause]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-expr-binding-clause-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (ast-expr-binding-clause-list-tail [items : AstExprBindingClauseList]) : AstExprBindingClauseList
  (let
    [out : AstExprBindingClauseList
      (ast-expr-binding-clause-list-with-capacity
        (- (struct-get (& items) len) 1))]
    [index : i64 1]
    (begin
      (while (< index (struct-get (& items) len))
        (begin
          (ast-expr-binding-clause-list-push
            (&mut out)
            (ast-expr-binding-clause-list-get
              (& items)
              index
              (ast-expr-binding-clause-fallback)))
          (set! index (+ index 1))))
      out)))

(define (ast-expr-spanned [inner : i64] [span : AstSourceSpan]) : i64
  (ast-node-push (AstExpr.Spanned inner span)))

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

(define (ast-expr-make-array [elem : AstType] [size : i64]) : i64
  (ast-node-push (AstExpr.MakeArray elem size)))

(define (ast-expr-array-ref [target : i64] [index : i64]) : i64
  (ast-node-push (AstExpr.ArrayRef target index)))

(define (ast-expr-array-set [target : i64] [index : i64] [value : i64]) : i64
  (ast-node-push (AstExpr.ArraySet target index value)))

(define (ast-expr-array-take [target : i64] [live : i64] [index : i64]) : i64
  (ast-node-push (AstExpr.ArrayTake target live index)))

(define (ast-expr-array-push [target : i64] [value : i64]) : i64
  (ast-node-push (AstExpr.ArrayPush target value)))

(define (ast-expr-string-ref [target : i64] [index : i64]) : i64
  (ast-node-push (AstExpr.StringRef target index)))

(define (ast-expr-while [cond : i64] [body : i64]) : i64
  (ast-node-push (AstExpr.While cond body)))

(define (ast-expr-set-id [name : i64] [value : i64]) : i64
  (ast-node-push (AstExpr.Set name value)))

(define (ast-expr-ann [expr : i64] [ty : AstType]) : i64
  (ast-node-push (AstExpr.Ann expr ty)))

(define (ast-expr-cast [expr : i64] [ty : AstType]) : i64
  (ast-node-push (AstExpr.Cast expr ty)))

(define (ast-expr-borrow
  [mutable : bool]
  [lifetime : AstBorrowLifetime]
  [expr : i64]) : i64
  (ast-node-push (AstExpr.Borrow mutable lifetime expr)))

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

(define (ast-expr-spmd-reduce-id
  [op : AstReduceOp]
  [name : i64]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [init : i64]
  [value : i64]) : i64
  (ast-node-push
    (AstExpr.SpmdReduce
      (box (AstSpmdReduce.Reduce op name index-ty start end init value)))))

(define (ast-expr-spmd-scan-id
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
  (ast-node-push
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

(define (ast-expr-spmd-broadcast [value : i64] [lane : i64]) : i64
  (ast-node-push (AstExpr.SpmdBroadcast value lane)))

(define (ast-expr-spmd-shuffle [value : i64] [lane : i64]) : i64
  (ast-node-push (AstExpr.SpmdShuffle value lane)))

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

(define (ast-expr-init-maybe [maybe-ty : AstMaybeType]) : i64
  (ast-node-push (AstExpr.Init maybe-ty)))

(define (ast-expr-init [ty : AstType]) : i64
  (ast-expr-init-maybe (AstMaybeType.Some ty)))

(define (ast-expr-comptime [inner : i64]) : i64
  (ast-node-push (AstExpr.Comptime inner)))

(define (ast-expr-quote [inner : i64]) : i64
  (ast-node-push (AstExpr.Quote inner)))

(define (ast-expr-quasiquote [inner : i64]) : i64
  (ast-node-push (AstExpr.Quasiquote inner)))

(define (ast-expr-unquote [inner : i64]) : i64
  (ast-node-push (AstExpr.Unquote inner)))

(define (ast-expr-unquote-splicing [inner : i64]) : i64
  (ast-node-push (AstExpr.UnquoteSplicing inner)))

(define (ast-expr-try [inner : i64]) : i64
  (ast-node-push (AstExpr.Try inner)))

(define (ast-expr-return [inner : i64]) : i64
  (ast-node-push (AstExpr.Return inner)))

(define (ast-expr-break) : i64
  (ast-node-push (AstExpr.Break)))

(define (ast-expr-continue) : i64
  (ast-node-push (AstExpr.Continue)))

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

(define (ast-expr-ptr-cast [ptr : i64] [ty : AstType]) : i64
  (ast-node-push (AstExpr.PtrCast ptr ty)))

(define (ast-expr-ptr-to-int [ptr : i64]) : i64
  (ast-node-push (AstExpr.PtrToInt ptr)))

(define (ast-expr-int-to-ptr [value : i64] [ty : AstType]) : i64
  (ast-node-push (AstExpr.IntToPtr value ty)))

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
  [pools : AstNodePoolContext]
  [inner : i64]
  [span : AstSourceSpan]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Spanned inner span)))

(define (ast-expr-binary-with-pools
  [pools : AstNodePoolContext]
  [op : AstBinOp]
  [left : i64]
  [right : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Binary op left right)))

(define (ast-expr-unary-with-pools
  [pools : AstNodePoolContext]
  [op : AstUnOp]
  [inner : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Unary op inner)))

(define (ast-expr-call-with-pools
  [pools : AstNodePoolContext]
  [callee : i64]
  [args : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Call callee args)))

(define (ast-expr-bracket-clause-with-pools
  [pools : AstNodePoolContext]
  [items : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.BracketClause items)))

(define (ast-expr-if-with-pools
  [pools : AstNodePoolContext]
  [cond : i64]
  [then-expr : i64]
  [else-expr : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.If cond then-expr else-expr)))

(define (ast-expr-let-with-pools
  [pools : AstNodePoolContext]
  [bindings : AstLetBindingList]
  [body : i64]) : i64
  (ast-node-pool-context-expr-push
    pools
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
  (ast-node-pool-context-expr-push pools (AstExpr.MakeArray elem size)))

(define (ast-expr-dyn-array-with-pools
  [pools : AstNodePoolContext]
  [items : AstExprList]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.DynArray items)))

(define (ast-expr-array-ref-with-pools
  [pools : AstNodePoolContext]
  [target : i64]
  [index : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.ArrayRef target index)))

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
  (ast-node-pool-context-expr-push pools (AstExpr.While cond body)))

(define (ast-expr-set-id-with-pools
  [pools : AstNodePoolContext]
  [name : i64]
  [value : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Set name value)))

(define (ast-expr-ann-with-pools
  [pools : AstNodePoolContext]
  [expr : i64]
  [ty : AstType]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Ann expr ty)))

(define (ast-expr-cast-with-pools
  [pools : AstNodePoolContext]
  [expr : i64]
  [ty : AstType]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Cast expr ty)))

(define (ast-expr-borrow-with-pools
  [pools : AstNodePoolContext]
  [mutable : bool]
  [lifetime : AstBorrowLifetime]
  [expr : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.Borrow mutable lifetime expr)))

(define (ast-expr-match-with-pools
  [pools : AstNodePoolContext]
  [scrutinee : i64]
  [arms : AstMatchArmList]) : i64
  (ast-node-pool-context-expr-push
    pools
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
  (ast-node-pool-context-expr-push pools (AstExpr.Init maybe-ty)))

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
  (ast-node-pool-context-expr-push pools (AstExpr.PtrCast ptr ty)))

(define (ast-expr-ptr-to-int-with-pools
  [pools : AstNodePoolContext]
  [ptr : i64]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.PtrToInt ptr)))

(define (ast-expr-int-to-ptr-with-pools
  [pools : AstNodePoolContext]
  [value : i64]
  [ty : AstType]) : i64
  (ast-node-pool-context-expr-push pools (AstExpr.IntToPtr value ty)))

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

(define (ast-dispatch-variant-list-with-capacity [capacity : i64]) : AstDispatchVariantList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstDispatchVariantList (array.make-array AstDispatchVariant cap) 0)))

(define (ast-dispatch-variant-list-new) : AstDispatchVariantList
  (ast-dispatch-variant-list-with-capacity 4))

(define (ast-dispatch-variant-list-len [v : (& v AstDispatchVariantList)]) : i64
  (struct-get v len))

(define (ast-dispatch-variant-list-empty? [v : (& v AstDispatchVariantList)]) : bool
  (= (struct-get v len) 0))

(define (ast-dispatch-variant-list-get
  [v : (& v AstDispatchVariantList)]
  [index : i64]
  [fallback : AstDispatchVariant]) : AstDispatchVariant
  (if (and (>= index 0) (< index (struct-get v len)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (ast-dispatch-variant-list-copy-range
  [dst : (&mut dst (Array AstDispatchVariant))]
  [src : (& src (Array AstDispatchVariant))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (ast-dispatch-variant-list-copy-range dst src (+ index 1) count))))

(define (ast-dispatch-variant-list-grow [v : (&mut v AstDispatchVariantList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstDispatchVariant)
      (array.make-array AstDispatchVariant new-cap)]
    (begin
      (ast-dispatch-variant-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        0
        n)
      (set! (struct-get v slots) bigger))))

(define (ast-dispatch-variant-list-push
  [v : (&mut v AstDispatchVariantList)]
  [value : AstDispatchVariant]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (ast-dispatch-variant-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

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
    (AstDeclList (array.make-array AstDecl cap) 0 0 true)))

(define (ast-decl-list-new) : AstDeclList
  (ast-decl-list-with-capacity 4))

(define (ast-decl-list-len [v : (& v AstDeclList)]) : i64
  (struct-get v len))

(define (ast-decl-list-empty? [v : (& v AstDeclList)]) : bool
  (= (ast-decl-list-len v) 0))

(define (ast-decl-list-get
  [v : (& v AstDeclList)]
  [index : i64]
  [fallback : AstDecl]) : AstDecl
  (if (and (>= index 0) (< index (ast-decl-list-len v)))
    (array-ref (struct-get v slots) (+ (struct-get v offset) index))
    fallback))

(define (ast-decl-list-ref [v : AstDeclList] [index : i64]) : AstDecl
  (array-ref (struct-get v slots) (+ (struct-get v offset) index)))

(define (ast-decl-list-ref-borrowed [v : (& v AstDeclList)] [index : i64]) : (&
    v
    AstDecl)
  (& (array-ref (struct-get v slots) (+ (struct-get v offset) index))))

(define (ast-decl-list-copy-range
  [dst : (&mut dst (Array AstDecl))]
  [src : (& src (Array AstDecl))]
  [src-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src (+ src-offset index)))
      (ast-decl-list-copy-range dst src src-offset (+ index 1) count))))

(define (ast-decl-list-copy-to
  [dst : (&mut dst (Array AstDecl))]
  [src : (& src (Array AstDecl))]
  [src-offset : i64]
  [dst-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst (+ dst-offset index) (array-ref src (+ src-offset index)))
      (ast-decl-list-copy-to dst src src-offset dst-offset (+ index 1) count))))

(define (ast-decl-list-grow [v : (&mut v AstDeclList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64
      (- (array-length (struct-get v slots)) (struct-get v offset))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstDecl) (array.make-array AstDecl new-cap)]
    (begin
      (ast-decl-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        (struct-get v offset)
        0
        n)
      (set! (struct-get v slots) bigger)
      (set! (struct-get v offset) 0)
      (set! (struct-get v prependable) true))))

(define (ast-decl-list-push [v : (&mut v AstDeclList)] [value : AstDecl]) : unit
  (begin
    (if (<
      (struct-get v len)
      (- (array-length (struct-get v slots)) (struct-get v offset)))
      unit
      (ast-decl-list-grow v))
    (let
      [index : i64 (+ (struct-get v offset) (struct-get v len))]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ (struct-get v len) 1))))))

(define (ast-decl-list-tail [items : AstDeclList]) : AstDeclList
  (if (<= (ast-decl-list-len (& items)) 0)
    (ast-decl-list-new)
    (AstDeclList
      (struct-get items slots)
      (+ (struct-get items offset) 1)
      (- (struct-get items len) 1)
      false)))

(define (ast-decl-list-step [items : AstDeclList]) : AstDeclListStep
  (let
    [len : i64 (struct-get items len)]
    [offset : i64 (struct-get items offset)]
    (if (<= len 0)
      (AstDeclListStep.Nil)
      (AstDeclListStep.Cons
        (array-ref (struct-get items slots) offset)
        (AstDeclList (struct-get items slots) (+ offset 1) (- len 1) false)))))

(define (ast-decl-list-append-from
  [out : (&mut out AstDeclList)]
  [items : (& items AstDeclList)]
  [index : i64]) : unit
  (if (>= index (ast-decl-list-len items))
    unit
    (begin
      (ast-decl-list-push
        out
        (ast-decl-list-get items index (ast-decl-fallback)))
      (ast-decl-list-append-from out items (+ index 1)))))

(define (ast-decl-list-prepend-builder [head : AstDecl] [rest : AstDeclList]) : AstDeclList
  (if (and (> (struct-get rest offset) 0) (struct-get rest prependable))
    (let
      [new-offset : i64 (- (struct-get rest offset) 1)]
      (begin
        (array-set! (struct-get rest slots) new-offset head)
        (AstDeclList
          (struct-get rest slots)
          new-offset
          (+ (struct-get rest len) 1)
          true)))
    (let
      [rest-len : i64 (ast-decl-list-len (& rest))]
      [new-len : i64 (+ rest-len 1)]
      [new-cap : i64
        (if (< rest-len 4)
          4
          (* new-len 2))]
      [new-offset : i64 (- new-cap new-len)]
      [slots : (Array AstDecl) (array.make-array AstDecl new-cap)]
      (begin
        (array-set! slots new-offset head)
        (ast-decl-list-copy-to
          (&mut slots)
          (& (struct-get rest slots))
          (struct-get rest offset)
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
  (ast-decl-cons head (box-get rest)))

(define (ast-decl-module-id [name : i64]) : AstDecl
  (AstDecl.Module name))

(define (ast-decl-module-body-id [name : i64] [body : AstDeclList]) : AstDecl
  (AstDecl.ModuleBody name (box body)))

(define (ast-decl-def-id [name : i64] [maybe-ty : AstMaybeType] [value : i64]) : AstDecl
  (AstDecl.Def ast-decl-meta-runtime name maybe-ty value))

(define (ast-decl-def-fn-id
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]) : AstDecl
  (AstDecl.DefFn
    ast-decl-meta-runtime
    name
    params
    ret
    body
    (ast-fn-metadata AstFnExport.No)))

(define (ast-decl-def-fn-export-id
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [export : AstFnExport]) : AstDecl
  (AstDecl.DefFn
    ast-decl-meta-runtime
    name
    params
    ret
    body
    (ast-fn-metadata export)))

(define (ast-decl-def-fn-metadata-id
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [metadata : AstFnMetadata]) : AstDecl
  (AstDecl.DefFn
    ast-decl-meta-runtime
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
  (AstDecl.DefMacro ast-decl-meta-runtime name params ret body))

(define (ast-decl-extern-id
  [name : i64]
  [kind : AstExternKind]
  [metadata : AstExternMetadata]
  [ty : AstType]) : AstDecl
  (AstDecl.Extern ast-decl-meta-runtime name kind (box metadata) ty))

(define (ast-decl-def-enum-id
  [name : i64]
  [cleanup : AstEnumCleanup]
  [variants : AstVariantDefList]) : AstDecl
  (AstDecl.DefEnum ast-decl-meta-runtime name cleanup variants))

(define (ast-decl-def-enum-lifetimes-id
  [name : i64]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [variants : AstVariantDefList]) : AstDecl
  (AstDecl.DefEnumLifetimes
    ast-decl-meta-runtime
    name
    lifetimes
    cleanup
    variants))

(define (ast-decl-def-struct-id
  [name : i64]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : AstDecl
  (AstDecl.DefStruct ast-decl-meta-runtime name repr cleanup fields))

(define (ast-decl-def-struct-lifetimes-id
  [name : i64]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : AstDecl
  (AstDecl.DefStructLifetimes
    ast-decl-meta-runtime
    name
    lifetimes
    repr
    cleanup
    fields))

(define (ast-decl-def-dispatch-id
  [name : i64]
  [variants : AstDispatchVariantList]) : AstDecl
  (AstDecl.DefDispatch ast-decl-meta-runtime name variants))

(define (ast-decl-test-id [name : i64] [body : i64] [span : AstSourceSpan]) : AstDecl
  (AstDecl.Test name body span))

(define (ast-decl-unsafe [inner : AstDecl]) : AstDecl
  (AstDecl.Unsafe (box inner)))

(define (ast-decl-meta [decl : AstDecl]) : AstDeclMeta
  (match decl
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
    [(AstDecl.Unsafe inner-box) (ast-decl-meta (box-get inner-box))]
    [_ ast-decl-meta-runtime]))

(define (ast-decl-generated-meta [decl : AstDecl]) : AstGeneratedDeclMeta
  (match (box-get (struct-get (ast-decl-meta decl) value))
    [(AstDeclMetaValue.Runtime) AstGeneratedDeclMeta.No]
    [(AstDeclMetaValue.Comptime meta) meta]))

(define (ast-decl-comptime-only? [decl : AstDecl]) : bool
  (match (box-get (struct-get (ast-decl-meta decl) value))
    [(AstDeclMetaValue.Runtime) false]
    [(AstDeclMetaValue.Comptime _) true]))

(define (ast-decl-with-meta [meta : AstDeclMeta] [inner : AstDecl]) : AstDecl
  (match inner
    [(AstDecl.Def _ name maybe-ty value) (AstDecl.Def meta name maybe-ty value)]
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
      (AstDecl.Unsafe (box (ast-decl-with-meta meta (box-get inner-box))))]
    [_ inner]))

(define (ast-decl-comptime-decl [inner : AstDecl]) : AstDecl
  (ast-decl-with-meta
    (AstDeclMeta (box (AstDeclMetaValue.Comptime AstGeneratedDeclMeta.No)))
    inner))

(define (ast-decl-comptime-decl-with-meta
  [meta : AstGeneratedDeclMeta]
  [inner : AstDecl]) : AstDecl
  (ast-decl-with-meta
    (AstDeclMeta (box (AstDeclMetaValue.Comptime meta)))
    inner))

(define (ast-decl-unwrapped [decl : AstDecl]) : AstDecl
  (match decl
    [(AstDecl.Unsafe inner-box) (ast-decl-unwrapped (box-get inner-box))]
    [_ decl]))

(define (ast-decl-path-list-with-capacity [capacity : i64]) : AstDeclPathList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (AstDeclPathList
      (array.make-array String cap)
      (array.make-array i64 cap)
      0
      0
      true)))

(define (ast-decl-path-list-new) : AstDeclPathList
  (ast-decl-path-list-with-capacity 4))

(define (ast-decl-path-list-len [v : (& v AstDeclPathList)]) : i64
  (struct-get v len))

(define (ast-decl-path-list-get
  [v : (& v AstDeclPathList)]
  [index : i64]
  [fallback : String]) : String
  (if (and (>= index 0) (< index (ast-decl-path-list-len v)))
    (array-ref (struct-get v slots) (+ (struct-get v offset) index))
    fallback))

(define (ast-decl-path-list-owner-id
  [v : (& v AstDeclPathList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-decl-path-list-len v)))
    (array-ref (struct-get v owner-ids) (+ (struct-get v offset) index))
    fallback))

(define (ast-decl-path-list-copy-range
  [dst : (&mut dst (Array String))]
  [src : (& src (Array String))]
  [src-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src (+ src-offset index)))
      (ast-decl-path-list-copy-range dst src src-offset (+ index 1) count))))

(define (ast-decl-path-list-copy-to
  [dst : (&mut dst (Array String))]
  [src : (& src (Array String))]
  [src-offset : i64]
  [dst-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst (+ dst-offset index) (array-ref src (+ src-offset index)))
      (ast-decl-path-list-copy-to
        dst
        src
        src-offset
        dst-offset
        (+ index 1)
        count))))

(define (ast-decl-path-list-grow [v : (&mut v AstDeclPathList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64
      (- (array-length (struct-get v slots)) (struct-get v offset))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array String) (array.make-array String new-cap)]
    [bigger-owner-ids : (Array i64) (array.make-array i64 new-cap)]
    (begin
      (ast-decl-path-list-copy-range
        (&mut bigger)
        (& (struct-get v slots))
        (struct-get v offset)
        0
        n)
      (ast-decl-module-list-copy-to
        (&mut bigger-owner-ids)
        (& (struct-get v owner-ids))
        (struct-get v offset)
        0
        0
        n)
      (set! (struct-get v slots) bigger)
      (set! (struct-get v owner-ids) bigger-owner-ids)
      (set! (struct-get v offset) 0)
      (set! (struct-get v prependable) true))))

(define (ast-decl-path-list-push-with-owner-id
  [v : (&mut v AstDeclPathList)]
  [value : String]
  [owner-id : i64]) : unit
  (begin
    (if (<
      (struct-get v len)
      (- (array-length (struct-get v slots)) (struct-get v offset)))
      unit
      (ast-decl-path-list-grow v))
    (let
      [index : i64 (+ (struct-get v offset) (struct-get v len))]
      (begin
        (array-set! (struct-get v slots) index value)
        (array-set! (struct-get v owner-ids) index owner-id)
        (set! (struct-get v len) (+ (struct-get v len) 1))))))

(define (ast-decl-path-list-tail [items : AstDeclPathList]) : AstDeclPathList
  (if (<= (ast-decl-path-list-len (& items)) 0)
    (ast-decl-path-list-new)
    (AstDeclPathList
      (struct-get items slots)
      (struct-get items owner-ids)
      (+ (struct-get items offset) 1)
      (- (struct-get items len) 1)
      false)))

(define (ast-decl-path-list-step [items : AstDeclPathList]) : AstDeclPathListStep
  (let
    [len : i64 (struct-get items len)]
    [offset : i64 (struct-get items offset)]
    (if (<= len 0)
      (AstDeclPathListStep.Nil)
      (AstDeclPathListStep.Cons
        (array-ref (struct-get items slots) offset)
        (AstDeclPathList
          (struct-get items slots)
          (struct-get items owner-ids)
          (+ offset 1)
          (- len 1)
          false)))))

(define (ast-decl-path-list-append-from
  [out : (&mut out AstDeclPathList)]
  [items : (& items AstDeclPathList)]
  [index : i64]) : unit
  (if (>= index (ast-decl-path-list-len items))
    unit
    (begin
      (ast-decl-path-list-push-with-owner-id
        out
        (ast-decl-path-list-get items index "")
        (ast-decl-path-list-owner-id
          items
          index
          cbi.compiler-builtin-id-fix-empty))
      (ast-decl-path-list-append-from out items (+ index 1)))))

(define (ast-decl-path-list-prepend-builder-with-owner-id
  [head : String]
  [owner-id : i64]
  [rest : AstDeclPathList]) : AstDeclPathList
  (if (and (> (struct-get rest offset) 0) (struct-get rest prependable))
    (let
      [new-offset : i64 (- (struct-get rest offset) 1)]
      (begin
        (array-set! (struct-get rest slots) new-offset head)
        (array-set! (struct-get rest owner-ids) new-offset owner-id)
        (AstDeclPathList
          (struct-get rest slots)
          (struct-get rest owner-ids)
          new-offset
          (+ (struct-get rest len) 1)
          true)))
    (let
      [rest-len : i64 (ast-decl-path-list-len (& rest))]
      [new-len : i64 (+ rest-len 1)]
      [new-cap : i64
        (if (< rest-len 4)
          4
          (* new-len 2))]
      [new-offset : i64 (- new-cap new-len)]
      [slots : (Array String) (array.make-array String new-cap)]
      [owner-ids : (Array i64) (array.make-array i64 new-cap)]
      (begin
        (array-set! slots new-offset head)
        (array-set! owner-ids new-offset owner-id)
        (ast-decl-path-list-copy-to
          (&mut slots)
          (& (struct-get rest slots))
          (struct-get rest offset)
          (+ new-offset 1)
          0
          rest-len)
        (ast-decl-module-list-copy-to
          (&mut owner-ids)
          (& (struct-get rest owner-ids))
          (struct-get rest offset)
          (+ new-offset 1)
          0
          rest-len)
        (AstDeclPathList slots owner-ids new-offset new-len true)))))

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
    (AstDeclModuleList (array.make-array i64 cap) 0 0 true)))

(define (ast-decl-module-list-new) : AstDeclModuleList
  (ast-decl-module-list-with-capacity 4))

(define (ast-decl-module-list-len [v : (& v AstDeclModuleList)]) : i64
  (struct-get v len))

(define (ast-decl-module-list-get
  [v : (& v AstDeclModuleList)]
  [index : i64]
  [fallback : String]) : String
  (if (and (>= index 0) (< index (ast-decl-module-list-len v)))
    (ci.intern-str
      (array-ref (struct-get v slots) (+ (struct-get v offset) index)))
    fallback))

(define (ast-decl-module-list-get-id
  [v : (& v AstDeclModuleList)]
  [index : i64]
  [fallback : i64]) : i64
  (if (and (>= index 0) (< index (ast-decl-module-list-len v)))
    (array-ref (struct-get v slots) (+ (struct-get v offset) index))
    fallback))

(define (ast-decl-module-list-copy-to
  [dst : (&mut dst (Array i64))]
  [src : (& src (Array i64))]
  [src-offset : i64]
  [dst-offset : i64]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst (+ dst-offset index) (array-ref src (+ src-offset index)))
      (ast-decl-module-list-copy-to
        dst
        src
        src-offset
        dst-offset
        (+ index 1)
        count))))

(define (ast-decl-module-list-grow [v : (&mut v AstDeclModuleList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array i64) (array.make-array i64 new-cap)]
    (begin
      (ast-decl-module-list-copy-to
        (&mut bigger)
        (& (struct-get v slots))
        (struct-get v offset)
        0
        0
        n)
      (set! (struct-get v slots) bigger)
      (set! (struct-get v offset) 0)
      (set! (struct-get v prependable) true))))

(define (ast-decl-module-list-push-id
  [v : (&mut v AstDeclModuleList)]
  [value : i64]) : unit
  (begin
    (if (<
      (+ (struct-get v offset) (struct-get v len))
      (array-length (struct-get v slots)))
      unit
      (ast-decl-module-list-grow v))
    (let
      [index : i64 (+ (struct-get v offset) (struct-get v len))]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ (struct-get v len) 1))))))

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
  (if (and (> (struct-get rest offset) 0) (struct-get rest prependable))
    (let
      [new-offset : i64 (- (struct-get rest offset) 1)]
      (begin
        (array-set! (struct-get rest slots) new-offset head)
        (AstDeclModuleList
          (struct-get rest slots)
          new-offset
          (+ (struct-get rest len) 1)
          true)))
    (let
      [rest-len : i64 (ast-decl-module-list-len (& rest))]
      [new-len : i64 (+ rest-len 1)]
      [new-cap : i64
        (if (< rest-len 4)
          4
          (* new-len 2))]
      [new-offset : i64 (- new-cap new-len)]
      [slots : (Array i64) (array.make-array i64 new-cap)]
      (begin
        (array-set! slots new-offset head)
        (ast-decl-module-list-copy-to
          (&mut slots)
          (& (struct-get rest slots))
          (struct-get rest offset)
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
    [owner-ids : (Array i64)
      (array.make-array i64 (array-length (struct-get paths slots)))]
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
            (array-set! owner-ids (+ (struct-get paths offset) index) owner-id)
            (set! index (+ index 1)))))
      (AstDeclPathList
        (struct-get paths slots)
        owner-ids
        (struct-get paths offset)
        (struct-get paths len)
        (struct-get paths prependable)))))

(define (ast-program [decls : AstDeclList]) : AstProgram
  (AstProgram.Program (box decls)))

(defenum AstProgramCompaction
  (AstProgramCompaction AstProgram AstNodePoolContext))

(defstruct AstProgramCompactionRemap
  (source-pools AstNodePoolContext)
  (dest-pools AstNodePoolContext)
  (expr-map (Array i32))
  (type-map (Array i32)))

(define (ast-compaction-id-map-create [count : i64]) : (Array i32)
  (let
    [cap : i64
      (if (< count 1)
        1
        count)]
    ;; Arrays are zero-initialized. Store destination ids as id+1 so zero can
    ;; remain the unseen sentinel without an O(source-pool-size) initialization
    ;; pass before each compaction.
    ;; Pool ids are bounded below i32::MAX by the 4096-segment pool ceiling.
    (array.make-array i32 cap)))

(define (ast-compaction-remap-source-pools [remap : AstProgramCompactionRemap]) : AstNodePoolContext
  (struct-get remap source-pools))

(define (ast-compaction-remap-dest-pools [remap : AstProgramCompactionRemap]) : AstNodePoolContext
  (struct-get remap dest-pools))

(define (ast-compaction-copy-string [text : String]) : String
  (string.copy (& text)))

(define (ast-compaction-remap-lifetime-list-into
  [lifetimes : (& lifetimes AstLifetimeList)]
  [out : (&mut out AstLifetimeList)]
  [index : i64]) : unit
  (if (>= index (ast-lifetime-list-len lifetimes))
    unit
    (begin
      (ast-lifetime-list-push
        out
        (ast-lifetime-list-get lifetimes index (ast-lifetime-fallback)))
      (ast-compaction-remap-lifetime-list-into lifetimes out (+ index 1)))))

(define (ast-compaction-remap-lifetime-list [lifetimes : AstLifetimeList]) : AstLifetimeList
  (let
    [out : AstLifetimeList
      (ast-lifetime-list-with-capacity (ast-lifetime-list-len (& lifetimes)))]
    (begin
      (ast-compaction-remap-lifetime-list-into (& lifetimes) (&mut out) 0)
      out)))

(define (ast-compaction-remap-type-list
  [remap : AstProgramCompactionRemap]
  [types : AstTypeList]) : AstTypeList
  (let
    [out : AstTypeList
      (ast-type-list-with-capacity (ast-type-list-len (& types)))]
    (begin
      (ast-compaction-remap-type-list-into remap (& types) (&mut out) 0)
      out)))

(define (ast-compaction-remap-type-list-into
  [remap : AstProgramCompactionRemap]
  [types : (& types AstTypeList)]
  [out : (&mut out AstTypeList)]
  [index : i64]) : unit
  (if (>= index (ast-type-list-len types))
    unit
    (begin
      (ast-type-list-push
        out
        (ast-compaction-remap-type-id
          remap
          (ast-type-list-get types index (ast-type-id-fallback))))
      (ast-compaction-remap-type-list-into remap types out (+ index 1)))))

(define (ast-compaction-remap-type
  [remap : AstProgramCompactionRemap]
  [ty : AstType]) : AstType
  (match ty
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
        (box (ast-compaction-remap-type-list remap (box-get args)))
        (ast-compaction-remap-type-id remap ret))]
    [(AstType.Tuple elems)
      (AstType.Tuple
        (box (ast-compaction-remap-type-list remap (box-get elems))))]
    [(AstType.Array elem count)
      (AstType.Array (ast-compaction-remap-type-id remap elem) count)]
    [(AstType.DynArray elem)
      (AstType.DynArray (ast-compaction-remap-type-id remap elem))]
    [(AstType.Box elem) (AstType.Box (ast-compaction-remap-type-id remap elem))]
    [(AstType.Region region inner)
      (AstType.Region region (ast-compaction-remap-type-id remap inner))]
    [(AstType.Ref region inner)
      (AstType.Ref region (ast-compaction-remap-type-id remap inner))]
    [(AstType.MutRef region inner)
      (AstType.MutRef region (ast-compaction-remap-type-id remap inner))]
    [(AstType.Enum name) (AstType.Enum name)]
    [(AstType.EnumArgs name lifetimes)
      (AstType.EnumArgs
        name
        (box (ast-compaction-remap-lifetime-list (box-get lifetimes))))]
    [(AstType.Struct name) (AstType.Struct name)]
    [(AstType.StructArgs name lifetimes)
      (AstType.StructArgs
        name
        (box (ast-compaction-remap-lifetime-list (box-get lifetimes))))]
    [(AstType.Var name) (AstType.Var name)]
    [(AstType.VarArgs name lifetimes)
      (AstType.VarArgs
        name
        (box (ast-compaction-remap-lifetime-list (box-get lifetimes))))]
    [(AstType.Ptr elem) (AstType.Ptr (ast-compaction-remap-type-id remap elem))]
    [(AstType.MutPtr elem)
      (AstType.MutPtr (ast-compaction-remap-type-id remap elem))]
    [(AstType.Consume inner)
      (AstType.Consume (ast-compaction-remap-type-id remap inner))]))

(define (ast-compaction-remap-type-id
  [remap : AstProgramCompactionRemap]
  [id : i64]) : i64
  (let
    [type-map : (Array i32) (struct-get remap type-map)]
    [cached : i32 (array-ref type-map id)]
    (if (> cached 0)
      (cast (- cached 1) : i64)
      (let
        [source-pools : AstNodePoolContext
          (ast-compaction-remap-source-pools remap)]
        [dest-pools : AstNodePoolContext
          (ast-compaction-remap-dest-pools remap)]
        [source-ty : AstType (ast-node-pool-context-type-get source-pools id)]
        [new-ty : AstType (ast-compaction-remap-type remap source-ty)]
        [new-id : i64 (ast-node-pool-context-type-push dest-pools new-ty)]
        (begin
          (array-set! type-map id (cast (+ new-id 1) : i32))
          new-id)))))

(define (ast-compaction-remap-maybe-type
  [remap : AstProgramCompactionRemap]
  [maybe-ty : AstMaybeType]) : AstMaybeType
  (match maybe-ty
    [(AstMaybeType.No) AstMaybeType.No]
    [(AstMaybeType.Some ty)
      (AstMaybeType.Some (ast-compaction-remap-type remap ty))]))

(define (ast-compaction-remap-param
  [remap : AstProgramCompactionRemap]
  [param : AstParam]) : AstParam
  (match param
    [(AstParam.Param name ty is-comptime consume)
      (AstParam.Param
        name
        (ast-compaction-remap-type remap ty)
        is-comptime
        consume)]))

(define (ast-compaction-remap-param-list
  [remap : AstProgramCompactionRemap]
  [params : AstParamList]) : AstParamList
  (let
    [out : AstParamList
      (ast-param-list-with-capacity (ast-param-list-len (& params)))]
    (begin
      (ast-compaction-remap-param-list-into remap (& params) 0 (&mut out))
      out)))

(define (ast-compaction-remap-param-list-into
  [remap : AstProgramCompactionRemap]
  [params : (& params AstParamList)]
  [index : i64]
  [out : (&mut out AstParamList)]) : unit
  (if (>= index (ast-param-list-len params))
    unit
    (begin
      (ast-param-list-push
        out
        (ast-compaction-remap-param
          remap
          (ast-param-list-get params index (ast-param-fallback))))
      (ast-compaction-remap-param-list-into remap params (+ index 1) out))))

(define (ast-compaction-remap-macro-param
  [remap : AstProgramCompactionRemap]
  [param : AstMacroParam]) : AstMacroParam
  (match param
    [(AstMacroParam.Param name ty variadic type-kinds)
      (AstMacroParam.Param
        name
        (ast-compaction-remap-type remap ty)
        variadic
        (ast-compaction-copy-macro-type-kind-list type-kinds))]))

(define (ast-compaction-copy-macro-type-kind-list
  [kinds : AstMacroTypeKindList]) : AstMacroTypeKindList
  (match kinds
    [(AstMacroTypeKindList.Nil) AstMacroTypeKindList.Nil]
    [(AstMacroTypeKindList.Cons kind rest)
      (AstMacroTypeKindList.Cons
        kind
        (box (ast-compaction-copy-macro-type-kind-list (box-get rest))))]))

(define (ast-compaction-remap-macro-param-list
  [remap : AstProgramCompactionRemap]
  [params : AstMacroParamList]) : AstMacroParamList
  (let
    [out : AstMacroParamList
      (ast-macro-param-list-with-capacity (ast-macro-param-list-len (& params)))]
    (begin
      (ast-compaction-remap-macro-param-list-into remap (& params) 0 (&mut out))
      out)))

(define (ast-compaction-remap-macro-param-list-into
  [remap : AstProgramCompactionRemap]
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
  [remap : AstProgramCompactionRemap]
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
  [remap : AstProgramCompactionRemap]
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
  [remap : AstProgramCompactionRemap]
  [fields : AstFieldDefList]) : AstFieldDefList
  (let
    [out : AstFieldDefList
      (ast-field-def-list-with-capacity (ast-field-def-list-len (& fields)))]
    (begin
      (ast-compaction-remap-field-def-list-into remap (& fields) 0 (&mut out))
      out)))

(define (ast-compaction-remap-extern-abi
  [remap : AstProgramCompactionRemap]
  [abi : AstExternAbi]) : AstExternAbi
  (match abi
    [(AstExternAbi.C) AstExternAbi.C]
    [(AstExternAbi.CVarargsOpen) AstExternAbi.CVarargsOpen]
    [(AstExternAbi.CVarargsTyped ty)
      (AstExternAbi.CVarargsTyped (ast-compaction-remap-type remap ty))]))

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
  [remap : AstProgramCompactionRemap]
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
  [remap : AstProgramCompactionRemap]
  [variant : AstVariantDef]) : AstVariantDef
  (match variant
    [(AstVariantDef.Def name fields cleanups)
      (AstVariantDef.Def
        name
        (ast-compaction-remap-type-list remap fields)
        (ast-compaction-remap-variant-payload-cleanup-list cleanups))]))

(define (ast-compaction-remap-variant-def-list
  [remap : AstProgramCompactionRemap]
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
  [remap : AstProgramCompactionRemap]
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
  [remap : AstProgramCompactionRemap]
  [kind : AstImportKind]) : AstImportKind
  (match kind
    [(AstImportKind.Path) AstImportKind.Path]
    [(AstImportKind.Module) AstImportKind.Module]
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
  [remap : AstProgramCompactionRemap]
  [spec : AstImportSpec]) : AstImportSpec
  (match spec
    [(AstImportSpec.Spec kind path module-name alias span)
      (AstImportSpec.Spec
        (ast-compaction-remap-import-kind remap kind)
        (ast-compaction-copy-string path)
        (ast-compaction-remap-maybe-module-name module-name)
        (ast-compaction-remap-maybe-import-alias alias)
        (box (box-get span)))]))

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

(define (ast-compaction-remap-pattern
  [remap : AstProgramCompactionRemap]
  [pattern : AstPattern]) : AstPattern
  (match pattern
    [(AstPattern.Var name maybe-ty)
      (AstPattern.Var name (ast-compaction-remap-maybe-type remap maybe-ty))]
    [(AstPattern.Tuple items)
      (AstPattern.Tuple
        (box (ast-compaction-remap-pattern-list remap (box-get items))))]
    [(AstPattern.Wildcard) AstPattern.Wildcard]
    [(AstPattern.Binding name) (AstPattern.Binding name)]
    [(AstPattern.Variant name items)
      (AstPattern.Variant
        name
        (box (ast-compaction-remap-pattern-list remap (box-get items))))]
    [(AstPattern.Literal lit)
      (AstPattern.Literal (ast-compaction-remap-literal lit))]))

(define (ast-compaction-remap-pattern-list-into
  [remap : AstProgramCompactionRemap]
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
  [remap : AstProgramCompactionRemap]
  [patterns : AstPatternList]) : AstPatternList
  (let
    [out : AstPatternList
      (ast-pattern-list-with-capacity (ast-pattern-list-len (& patterns)))]
    (begin
      (ast-compaction-remap-pattern-list-into remap (& patterns) 0 (&mut out))
      out)))

(define (ast-compaction-remap-let-binding
  [remap : AstProgramCompactionRemap]
  [binding : AstLetBinding]) : AstLetBinding
  (match binding
    [(AstLetBinding.Binding name maybe-ty value)
      (AstLetBinding.Binding
        name
        (ast-compaction-remap-maybe-type remap maybe-ty)
        (ast-compaction-remap-expr-id remap value))]))

(define (ast-compaction-remap-let-binding-list
  [remap : AstProgramCompactionRemap]
  [bindings : AstLetBindingList]) : AstLetBindingList
  (let
    [out : AstLetBindingList
      (ast-let-binding-list-with-capacity
        (ast-let-binding-list-len (& bindings)))]
    (begin
      (ast-compaction-remap-let-binding-list-into
        remap
        (& bindings)
        0
        (&mut out))
      out)))

(define (ast-compaction-remap-let-binding-list-into
  [remap : AstProgramCompactionRemap]
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]
  [out : (&mut out AstLetBindingList)]) : unit
  (if (>= index (ast-let-binding-list-len bindings))
    unit
    (begin
      (ast-let-binding-list-push
        out
        (ast-compaction-remap-let-binding
          remap
          (ast-let-binding-list-get bindings index (ast-let-binding-fallback))))
      (ast-compaction-remap-let-binding-list-into
        remap
        bindings
        (+ index 1)
        out))))

(define (ast-compaction-remap-resource-binding
  [remap : AstProgramCompactionRemap]
  [binding : AstResourceBinding]) : AstResourceBinding
  (match binding
    [(AstResourceBinding.Binding name init cleanup move-aware?)
      (AstResourceBinding.Binding
        name
        (ast-compaction-remap-expr-id remap init)
        (ast-compaction-remap-expr-id remap cleanup)
        move-aware?)]))

(define (ast-compaction-remap-resource-binding-list
  [remap : AstProgramCompactionRemap]
  [bindings : AstResourceBindingList]) : AstResourceBindingList
  (let
    [out : AstResourceBindingList
      (ast-resource-binding-list-with-capacity
        (ast-resource-binding-list-len (& bindings)))]
    (begin
      (ast-compaction-remap-resource-binding-list-into
        remap
        (& bindings)
        0
        (&mut out))
      out)))

(define (ast-compaction-remap-resource-binding-list-into
  [remap : AstProgramCompactionRemap]
  [bindings : (& bindings AstResourceBindingList)]
  [index : i64]
  [out : (&mut out AstResourceBindingList)]) : unit
  (if (>= index (ast-resource-binding-list-len bindings))
    unit
    (begin
      (ast-resource-binding-list-push
        out
        (ast-compaction-remap-resource-binding
          remap
          (ast-resource-binding-list-get
            bindings
            index
            (ast-resource-binding-fallback))))
      (ast-compaction-remap-resource-binding-list-into
        remap
        bindings
        (+ index 1)
        out))))

(define (ast-compaction-remap-match-arm
  [remap : AstProgramCompactionRemap]
  [arm : AstMatchArm]) : AstMatchArm
  (match arm
    [(AstMatchArm.Arm pattern body)
      (AstMatchArm.Arm
        (ast-compaction-remap-pattern remap pattern)
        (ast-compaction-remap-expr-id remap body))]))

(define (ast-compaction-remap-match-arm-list-into
  [remap : AstProgramCompactionRemap]
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [out : (&mut out AstMatchArmList)]) : unit
  (if (>= index (ast-match-arm-list-len arms))
    unit
    (begin
      (ast-match-arm-list-push
        out
        (ast-compaction-remap-match-arm
          remap
          (ast-match-arm-list-get arms index (ast-match-arm-fallback))))
      (ast-compaction-remap-match-arm-list-into remap arms (+ index 1) out))))

(define (ast-compaction-remap-match-arm-list
  [remap : AstProgramCompactionRemap]
  [arms : AstMatchArmList]) : AstMatchArmList
  (let
    [out : AstMatchArmList
      (ast-match-arm-list-with-capacity (ast-match-arm-list-len (& arms)))]
    (begin
      (ast-compaction-remap-match-arm-list-into remap (& arms) 0 (&mut out))
      out)))

(define (ast-compaction-remap-expr-list-into
  [remap : AstProgramCompactionRemap]
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [out : (&mut out AstExprList)]) : unit
  (if (>= index (ast-expr-list-len exprs))
    unit
    (begin
      (ast-expr-list-push
        out
        (ast-compaction-remap-expr-id remap (ast-expr-list-get exprs index 0)))
      (ast-compaction-remap-expr-list-into remap exprs (+ index 1) out))))

(define (ast-compaction-remap-expr-list
  [remap : AstProgramCompactionRemap]
  [exprs : AstExprList]) : AstExprList
  (let
    [out : AstExprList
      (ast-expr-list-with-capacity (ast-expr-list-len (& exprs)))]
    (begin
      (ast-compaction-remap-expr-list-into remap (& exprs) 0 (&mut out))
      out)))

(define (ast-compaction-remap-expr
  [remap : AstProgramCompactionRemap]
  [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExpr.Spanned inner span)
      (AstExpr.Spanned (ast-compaction-remap-expr-id remap inner) span)]
    [(AstExpr.Literal lit) (AstExpr.Literal (ast-compaction-remap-literal lit))]
    [(AstExpr.Var name) (AstExpr.Var name)]
    [(AstExpr.Binary op left right)
      (AstExpr.Binary
        op
        (ast-compaction-remap-expr-id remap left)
        (ast-compaction-remap-expr-id remap right))]
    [(AstExpr.Unary op inner)
      (AstExpr.Unary op (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.Call callee args)
      (AstExpr.Call
        (ast-compaction-remap-expr-id remap callee)
        (ast-compaction-remap-expr-list remap args))]
    [(AstExpr.If cond then-expr else-expr)
      (AstExpr.If
        (ast-compaction-remap-expr-id remap cond)
        (ast-compaction-remap-expr-id remap then-expr)
        (ast-compaction-remap-expr-id remap else-expr))]
    [(AstExpr.Let payload)
      (match (box-get payload)
        [(AstLet.Let bindings body)
          (AstExpr.Let
            (box
              (AstLet.Let
                (ast-compaction-remap-let-binding-list remap bindings)
                (ast-compaction-remap-expr-id remap body))))])]
    [(AstExpr.Lambda payload)
      (match (box-get payload)
        [(AstLambda.Lambda params ret body)
          (AstExpr.Lambda
            (box
              (AstLambda.Lambda
                (ast-compaction-remap-param-list remap params)
                (ast-compaction-remap-maybe-type remap ret)
                (ast-compaction-remap-expr-id remap body))))])]
    [(AstExpr.Tuple items)
      (AstExpr.Tuple (ast-compaction-remap-expr-list remap items))]
    [(AstExpr.TupleRef target index)
      (AstExpr.TupleRef (ast-compaction-remap-expr-id remap target) index)]
    [(AstExpr.Array items)
      (AstExpr.Array (ast-compaction-remap-expr-list remap items))]
    [(AstExpr.DynArray items)
      (AstExpr.DynArray (ast-compaction-remap-expr-list remap items))]
    [(AstExpr.MakeArray elem size)
      (AstExpr.MakeArray
        (ast-compaction-remap-type remap elem)
        (ast-compaction-remap-expr-id remap size))]
    [(AstExpr.ArrayRef target index)
      (AstExpr.ArrayRef
        (ast-compaction-remap-expr-id remap target)
        (ast-compaction-remap-expr-id remap index))]
    [(AstExpr.ArraySet target index value)
      (AstExpr.ArraySet
        (ast-compaction-remap-expr-id remap target)
        (ast-compaction-remap-expr-id remap index)
        (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.ArrayTake target live index)
      (AstExpr.ArrayTake
        (ast-compaction-remap-expr-id remap target)
        (ast-compaction-remap-expr-id remap live)
        (ast-compaction-remap-expr-id remap index))]
    [(AstExpr.ArrayPush target value)
      (AstExpr.ArrayPush
        (ast-compaction-remap-expr-id remap target)
        (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.StringRef target index)
      (AstExpr.StringRef
        (ast-compaction-remap-expr-id remap target)
        (ast-compaction-remap-expr-id remap index))]
    [(AstExpr.While cond body)
      (AstExpr.While
        (ast-compaction-remap-expr-id remap cond)
        (ast-compaction-remap-expr-id remap body))]
    [(AstExpr.Begin exprs)
      (AstExpr.Begin (ast-compaction-remap-expr-list remap exprs))]
    [(AstExpr.Unsafe exprs)
      (AstExpr.Unsafe (ast-compaction-remap-expr-list remap exprs))]
    [(AstExpr.Set name value)
      (AstExpr.Set name (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.Ann inner ty)
      (AstExpr.Ann
        (ast-compaction-remap-expr-id remap inner)
        (ast-compaction-remap-type remap ty))]
    [(AstExpr.Cast inner ty)
      (AstExpr.Cast
        (ast-compaction-remap-expr-id remap inner)
        (ast-compaction-remap-type remap ty))]
    [(AstExpr.Borrow mutable lifetime inner)
      (AstExpr.Borrow
        mutable
        lifetime
        (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.Match payload)
      (match (box-get payload)
        [(AstMatch.Match scrutinee arms)
          (AstExpr.Match
            (box
              (AstMatch.Match
                (ast-compaction-remap-expr-id remap scrutinee)
                (ast-compaction-remap-match-arm-list remap arms))))])]
    [(AstExpr.Foreach payload)
      (match (box-get payload)
        [(AstForeach.Foreach name index-ty start end body)
          (AstExpr.Foreach
            (box
              (AstForeach.Foreach
                name
                (ast-compaction-remap-type remap index-ty)
                (ast-compaction-remap-expr-id remap start)
                (ast-compaction-remap-expr-id remap end)
                (ast-compaction-remap-expr-id remap body))))])]
    [(AstExpr.SpmdReduce payload)
      (match (box-get payload)
        [(AstSpmdReduce.Reduce op index index-ty start end init value)
          (AstExpr.SpmdReduce
            (box
              (AstSpmdReduce.Reduce
                op
                index
                (ast-compaction-remap-type remap index-ty)
                (ast-compaction-remap-expr-id remap start)
                (ast-compaction-remap-expr-id remap end)
                (ast-compaction-remap-expr-id remap init)
                (ast-compaction-remap-expr-id remap value))))])]
    [(AstExpr.SpmdScan payload)
      (match (box-get payload)
        [(AstSpmdScan.Scan
            op
            index
            index-ty
            start
            end
            prefix
            prefix-ty
            init
            value
            body)
          (AstExpr.SpmdScan
            (box
              (AstSpmdScan.Scan
                op
                index
                (ast-compaction-remap-type remap index-ty)
                (ast-compaction-remap-expr-id remap start)
                (ast-compaction-remap-expr-id remap end)
                prefix
                (ast-compaction-remap-type remap prefix-ty)
                (ast-compaction-remap-expr-id remap init)
                (ast-compaction-remap-expr-id remap value)
                (ast-compaction-remap-expr-id remap body))))])]
    [(AstExpr.SpmdBroadcast value lane)
      (AstExpr.SpmdBroadcast
        (ast-compaction-remap-expr-id remap value)
        (ast-compaction-remap-expr-id remap lane))]
    [(AstExpr.SpmdShuffle value lane)
      (AstExpr.SpmdShuffle
        (ast-compaction-remap-expr-id remap value)
        (ast-compaction-remap-expr-id remap lane))]
    [(AstExpr.SpmdProgramIndex) AstExpr.SpmdProgramIndex]
    [(AstExpr.SpmdProgramCount) AstExpr.SpmdProgramCount]
    [(AstExpr.StructGet target field)
      (AstExpr.StructGet (ast-compaction-remap-expr-id remap target) field)]
    [(AstExpr.StructSet target field value)
      (AstExpr.StructSet
        (ast-compaction-remap-expr-id remap target)
        field
        (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.WithRegion region body)
      (AstExpr.WithRegion region (ast-compaction-remap-expr-list remap body))]
    [(AstExpr.WithEscape escape body)
      (AstExpr.WithEscape
        (ast-compaction-remap-expr-id remap escape)
        (ast-compaction-remap-expr-list remap body))]
    [(AstExpr.WithScratch body)
      (AstExpr.WithScratch (ast-compaction-remap-expr-list remap body))]
    [(AstExpr.InArena arena body)
      (AstExpr.InArena
        (ast-compaction-remap-expr-id remap arena)
        (ast-compaction-remap-expr-list remap body))]
    [(AstExpr.WithResource payload)
      (match (box-get payload)
        [(AstWithResource.WithResource bindings body)
          (AstExpr.WithResource
            (box
              (AstWithResource.WithResource
                (ast-compaction-remap-resource-binding-list remap bindings)
                (ast-compaction-remap-expr-list remap body))))])]
    [(AstExpr.Box value)
      (AstExpr.Box (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.BoxGet value)
      (AstExpr.BoxGet (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.BoxTake value)
      (AstExpr.BoxTake (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.BoxSet target value)
      (AstExpr.BoxSet
        (ast-compaction-remap-expr-id remap target)
        (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.TypeLiteral ty)
      (AstExpr.TypeLiteral (ast-compaction-remap-type remap ty))]
    [(AstExpr.Init maybe-ty)
      (AstExpr.Init (ast-compaction-remap-maybe-type remap maybe-ty))]
    [(AstExpr.Comptime inner)
      (AstExpr.Comptime (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.Quote inner)
      (AstExpr.Quote (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.Quasiquote inner)
      (AstExpr.Quasiquote (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.Unquote inner)
      (AstExpr.Unquote (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.UnquoteSplicing inner)
      (AstExpr.UnquoteSplicing (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.BracketClause items)
      (AstExpr.BracketClause (ast-compaction-remap-expr-list remap items))]
    [(AstExpr.Try inner)
      (AstExpr.Try (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.Return inner)
      (AstExpr.Return (ast-compaction-remap-expr-id remap inner))]
    [(AstExpr.Break) AstExpr.Break]
    [(AstExpr.Continue) AstExpr.Continue]
    [(AstExpr.PtrNull ty)
      (AstExpr.PtrNull (ast-compaction-remap-type remap ty))]
    [(AstExpr.PtrNullCheck ptr)
      (AstExpr.PtrNullCheck (ast-compaction-remap-expr-id remap ptr))]
    [(AstExpr.PtrAddrOf place)
      (AstExpr.PtrAddrOf (ast-compaction-remap-expr-id remap place))]
    [(AstExpr.PtrRead ptr)
      (AstExpr.PtrRead (ast-compaction-remap-expr-id remap ptr))]
    [(AstExpr.PtrWrite ptr value)
      (AstExpr.PtrWrite
        (ast-compaction-remap-expr-id remap ptr)
        (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.PtrOffset ptr offset)
      (AstExpr.PtrOffset
        (ast-compaction-remap-expr-id remap ptr)
        (ast-compaction-remap-expr-id remap offset))]
    [(AstExpr.PtrCast ptr ty)
      (AstExpr.PtrCast
        (ast-compaction-remap-expr-id remap ptr)
        (ast-compaction-remap-type remap ty))]
    [(AstExpr.PtrToInt ptr)
      (AstExpr.PtrToInt (ast-compaction-remap-expr-id remap ptr))]
    [(AstExpr.IntToPtr value ty)
      (AstExpr.IntToPtr
        (ast-compaction-remap-expr-id remap value)
        (ast-compaction-remap-type remap ty))]
    [(AstExpr.StringData value)
      (AstExpr.StringData (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.StringFromBytes data len)
      (AstExpr.StringFromBytes
        (ast-compaction-remap-expr-id remap data)
        (ast-compaction-remap-expr-id remap len))]
    [(AstExpr.ArrayData value)
      (AstExpr.ArrayData (ast-compaction-remap-expr-id remap value))]
    [(AstExpr.BinaryData name)
      (AstExpr.BinaryData (ast-compaction-copy-string name))]
    [(AstExpr.ProgramArgc) AstExpr.ProgramArgc]
    [(AstExpr.ProgramArgv) AstExpr.ProgramArgv]
    [(AstExpr.ProgramEnvp) AstExpr.ProgramEnvp]
    [(AstExpr.CpuIdEax leaf subleaf)
      (AstExpr.CpuIdEax
        (ast-compaction-remap-expr-id remap leaf)
        (ast-compaction-remap-expr-id remap subleaf))]
    [(AstExpr.CpuIdEbx leaf subleaf)
      (AstExpr.CpuIdEbx
        (ast-compaction-remap-expr-id remap leaf)
        (ast-compaction-remap-expr-id remap subleaf))]
    [(AstExpr.CpuIdEcx leaf subleaf)
      (AstExpr.CpuIdEcx
        (ast-compaction-remap-expr-id remap leaf)
        (ast-compaction-remap-expr-id remap subleaf))]
    [(AstExpr.CpuIdEdx leaf subleaf)
      (AstExpr.CpuIdEdx
        (ast-compaction-remap-expr-id remap leaf)
        (ast-compaction-remap-expr-id remap subleaf))]
    [(AstExpr.Xgetbv index)
      (AstExpr.Xgetbv (ast-compaction-remap-expr-id remap index))]
    [(AstExpr.Syscall args)
      (AstExpr.Syscall (ast-compaction-remap-expr-list remap args))]))

(define (ast-compaction-remap-expr-id
  [remap : AstProgramCompactionRemap]
  [id : i64]) : i64
  (let
    [expr-map : (Array i32) (struct-get remap expr-map)]
    [cached : i32 (array-ref expr-map id)]
    (if (> cached 0)
      (cast (- cached 1) : i64)
      (let
        [source-pools : AstNodePoolContext
          (ast-compaction-remap-source-pools remap)]
        [dest-pools : AstNodePoolContext
          (ast-compaction-remap-dest-pools remap)]
        [source-expr : AstExpr (ast-node-pool-context-expr-get source-pools id)]
        [new-expr : AstExpr (ast-compaction-remap-expr remap source-expr)]
        [new-id : i64 (ast-node-pool-context-expr-push dest-pools new-expr)]
        (begin
          (array-set! expr-map id (cast (+ new-id 1) : i32))
          new-id)))))

(define (ast-compaction-remap-generated-meta
  [remap : AstProgramCompactionRemap]
  [meta : AstGeneratedDeclMeta]) : AstGeneratedDeclMeta
  (match meta
    [(AstGeneratedDeclMeta.No) AstGeneratedDeclMeta.No]
    [(AstGeneratedDeclMeta.Some generator item args key)
      (AstGeneratedDeclMeta.Some
        (ast-compaction-copy-string generator)
        (ast-compaction-copy-string item)
        (ast-compaction-remap-expr-list remap args)
        (ast-compaction-copy-string key))]))

(define (ast-compaction-remap-decl-meta
  [remap : AstProgramCompactionRemap]
  [meta : AstDeclMeta]) : AstDeclMeta
  (match (box-get (struct-get meta value))
    [(AstDeclMetaValue.Runtime) ast-decl-meta-runtime]
    [(AstDeclMetaValue.Comptime generated)
      (AstDeclMeta
        (box
          (AstDeclMetaValue.Comptime
            (ast-compaction-remap-generated-meta remap generated))))]))

(define (ast-compaction-remap-decl
  [remap : AstProgramCompactionRemap]
  [decl : AstDecl]) : AstDecl
  (match decl
    [(AstDecl.Module name) (AstDecl.Module name)]
    [(AstDecl.ModuleBody name body)
      (AstDecl.ModuleBody
        name
        (box (ast-compaction-remap-decl-list remap (box-get body))))]
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
        (box (ast-compaction-remap-extern-metadata remap (box-get metadata)))
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
        (ast-compaction-remap-lifetime-list lifetimes)
        (ast-compaction-remap-enum-cleanup cleanup)
        (ast-compaction-remap-variant-def-list remap variants))]
    [(AstDecl.DefStruct decl-meta name repr cleanup fields)
      (AstDecl.DefStruct
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        repr
        (ast-compaction-remap-struct-cleanup cleanup)
        (ast-compaction-remap-field-def-list remap fields))]
    [(AstDecl.DefStructLifetimes decl-meta name lifetimes repr cleanup fields)
      (AstDecl.DefStructLifetimes
        (ast-compaction-remap-decl-meta remap decl-meta)
        name
        (ast-compaction-remap-lifetime-list lifetimes)
        repr
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
    [(AstDecl.Test name body span)
      (AstDecl.Test name (ast-compaction-remap-expr-id remap body) span)]
    [(AstDecl.Unsafe inner)
      (AstDecl.Unsafe (box (ast-compaction-remap-decl remap (box-get inner))))]))

(define (ast-compaction-remap-decl-list
  [remap : AstProgramCompactionRemap]
  [decls : AstDeclList]) : AstDeclList
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [cursor : AstDeclList decls]
    [out : AstDeclList (ast-decl-list-with-capacity count)]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step cursor)
          [(AstDeclListStep.Nil) (set! done true)]
          [(AstDeclListStep.Cons decl rest)
            (begin
              (ast-decl-list-push
                (&mut out)
                (ast-compaction-remap-decl remap decl))
              (set! cursor rest))]))
      out)))

(define (ast-compaction-remap-program
  [remap : AstProgramCompactionRemap]
  [program : AstProgram]) : AstProgram
  (match program
    [(AstProgram.Program decls)
      (AstProgram.Program
        (box (ast-compaction-remap-decl-list remap (box-get decls))))]))

;: Copy `program` from `source-pools` into a reset `dest-pools`, remapping every
;: reachable expression id and recursive type id into dense destination ids.
;: `dest-pools` is expected to be distinct from `source-pools`.
(define (ast-program-compact-with-pools
  [source-pools : AstNodePoolContext]
  [dest-pools : AstNodePoolContext]
  [program : AstProgram]) : AstProgramCompaction
  (begin
    (ast-node-pool-context-reset-to! dest-pools 0 0)
    (let
      [prev-arena : i64 (arena.tl_arena_current)]
      [map-arena : i64 (arena.tl_arena_make)]
      [_set-map-arena : unit
        (unsafe
          (arena.tl_arena_set map-arena))]
      [expr-map : (Array i32)
        (ast-compaction-id-map-create
          (ast-node-pool-context-expr-len source-pools))]
      [type-map : (Array i32)
        (ast-compaction-id-map-create
          (ast-node-pool-context-type-len source-pools))]
      [remap : AstProgramCompactionRemap
        (AstProgramCompactionRemap source-pools dest-pools expr-map type-map)]
      [dest-arena : i64 (ast-node-pool-context-base-arena dest-pools)]
      [out-program : AstProgram
        (begin
          (unsafe
            (arena.tl_arena_set dest-arena))
          (let
            [out : AstProgram (ast-compaction-remap-program remap program)]
            (begin
              (ast-node-pool-context-sync-base-arena!
                dest-pools
                (arena.tl_arena_current))
              (unsafe
                (arena.tl_arena_set prev-arena))
              out)))]
      (begin
        (unsafe
          (arena.tl_arena_destroy map-arena))
        (AstProgramCompaction
          out-program
          (ast-node-pool-context-snapshot dest-pools))))))

;: Copy `program` into the existing tail of `dest-pools`, remapping every
;: reachable source id without discarding declarations already copied there.
;: This is the per-file loader counterpart to whole-program compaction.
(define (ast-program-copy-append-with-pools
  [source-pools : AstNodePoolContext]
  [dest-pools : AstNodePoolContext]
  [program : AstProgram]) : AstProgramCompaction
  (let
    [prev-arena : i64 (arena.tl_arena_current)]
    [map-arena : i64 (arena.tl_arena_make)]
    [_set-map-arena : unit
      (unsafe
        (arena.tl_arena_set map-arena))]
    [expr-map : (Array i32)
      (ast-compaction-id-map-create
        (ast-node-pool-context-expr-len source-pools))]
    [type-map : (Array i32)
      (ast-compaction-id-map-create
        (ast-node-pool-context-type-len source-pools))]
    [remap : AstProgramCompactionRemap
      (AstProgramCompactionRemap source-pools dest-pools expr-map type-map)]
    [dest-arena : i64 (ast-node-pool-context-base-arena dest-pools)]
    [out-program : AstProgram
      (begin
        (unsafe
          (arena.tl_arena_set dest-arena))
        (let
          [out : AstProgram (ast-compaction-remap-program remap program)]
          (begin
            (ast-node-pool-context-sync-base-arena!
              dest-pools
              (arena.tl_arena_current))
            (unsafe
              (arena.tl_arena_set prev-arena))
            out)))]
    (begin
      (unsafe
        (arena.tl_arena_destroy map-arena))
      (AstProgramCompaction
        out-program
        (ast-node-pool-context-snapshot dest-pools)))))

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
    [(AstType.Ptr _) 27]
    [(AstType.MutPtr _) 28]
    [(AstType.Box _) 31]
    [(AstType.EnumArgs _ _) 32]
    [(AstType.StructArgs _ _) 33]
    [(AstType.VarArgs _ _) 34]
    [(AstType.Consume _) 36]))

(define (ast-expr-tag [expr : AstExpr]) : i64
  (match expr
    [(AstExpr.Spanned _ _) 1]
    [(AstExpr.Literal _) 2]
    [(AstExpr.Var _) 3]
    [(AstExpr.Binary _ _ _) 4]
    [(AstExpr.Unary _ _) 5]
    [(AstExpr.Call _ _) 6]
    [(AstExpr.If _ _ _) 7]
    [(AstExpr.Let _) 8]
    [(AstExpr.Lambda _) 9]
    [(AstExpr.Tuple _) 10]
    [(AstExpr.TupleRef _ _) 11]
    [(AstExpr.Array _) 12]
    [(AstExpr.DynArray _) 74]
    [(AstExpr.MakeArray _ _) 13]
    [(AstExpr.ArrayRef _ _) 14]
    [(AstExpr.ArraySet _ _ _) 15]
    [(AstExpr.ArrayTake _ _ _) 75]
    [(AstExpr.ArrayPush _ _) 41]
    [(AstExpr.StringRef _ _) 16]
    [(AstExpr.While _ _) 17]
    [(AstExpr.Begin _) 18]
    [(AstExpr.Unsafe _) 32]
    [(AstExpr.Set _ _) 19]
    [(AstExpr.Ann _ _) 20]
    [(AstExpr.Cast _ _) 21]
    [(AstExpr.Borrow _ _ _) 40]
    [(AstExpr.Match _) 22]
    [(AstExpr.Foreach _) 23]
    [(AstExpr.StructGet _ _) 24]
    [(AstExpr.StructSet _ _ _) 63]
    [(AstExpr.WithRegion _ _) 25]
    [(AstExpr.WithEscape _ _) 48]
    [(AstExpr.WithScratch _) 67]
    [(AstExpr.InArena _ _) 65]
    [(AstExpr.TypeLiteral _) 26]
    [(AstExpr.Init _) 61]
    [(AstExpr.Comptime _) 27]
    [(AstExpr.SpmdReduce _) 28]
    [(AstExpr.SpmdScan _) 68]
    [(AstExpr.SpmdBroadcast _ _) 64]
    [(AstExpr.SpmdShuffle _ _) 71]
    [(AstExpr.SpmdProgramIndex) 69]
    [(AstExpr.SpmdProgramCount) 70]
    [(AstExpr.Try _) 29]
    [(AstExpr.Return _) 48]
    [(AstExpr.Break) 72]
    [(AstExpr.Continue) 73]
    [(AstExpr.PtrNull _) 30]
    [(AstExpr.PtrNullCheck _) 31]
    [(AstExpr.WithResource _) 33]
    [(AstExpr.PtrAddrOf _) 62]
    [(AstExpr.PtrRead _) 34]
    [(AstExpr.PtrWrite _ _) 35]
    [(AstExpr.PtrOffset _ _) 36]
    [(AstExpr.PtrCast _ _) 37]
    [(AstExpr.PtrToInt _) 38]
    [(AstExpr.IntToPtr _ _) 39]
    [(AstExpr.Box _) 42]
    [(AstExpr.BoxGet _) 43]
    [(AstExpr.BoxTake _) 65]
    [(AstExpr.BoxSet _ _) 66]
    [(AstExpr.Quote _) 44]
    [(AstExpr.Quasiquote _) 45]
    [(AstExpr.Unquote _) 46]
    [(AstExpr.UnquoteSplicing _) 47]
    [(AstExpr.BracketClause _) 63]
    [(AstExpr.StringData _) 49]
    [(AstExpr.StringFromBytes _ _) 50]
    [(AstExpr.ArrayData _) 51]
    [(AstExpr.BinaryData _) 64]
    [(AstExpr.ProgramArgc) 52]
    [(AstExpr.ProgramArgv) 53]
    [(AstExpr.ProgramEnvp) 54]
    [(AstExpr.CpuIdEax _ _) 55]
    [(AstExpr.CpuIdEbx _ _) 56]
    [(AstExpr.CpuIdEcx _ _) 57]
    [(AstExpr.CpuIdEdx _ _) 58]
    [(AstExpr.Xgetbv _) 59]
    [(AstExpr.Syscall _) 60]))

(define (ast-expr-unspan [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExpr.Spanned inner-id _) (ast-expr-unspan (ast-node-get inner-id))]
    [_ expr]))

(define (ast-expr-unspan-with-pools
  [pools : AstNodePoolContext]
  [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExpr.Spanned inner-id _)
      (ast-expr-unspan-with-pools
        pools
        (ast-node-pool-context-expr-get pools inner-id))]
    [_ expr]))

(define (ast-decl-tag [decl : AstDecl]) : i64
  (match decl
    [(AstDecl.Def decl-meta _ _ _) 1]
    [(AstDecl.DefFn decl-meta _ _ _ _ _) 2]
    [(AstDecl.DefMacro decl-meta _ _ _ _) 10]
    [(AstDecl.Extern decl-meta _ _ _ _) 3]
    [(AstDecl.DefEnum decl-meta _ _ _) 4]
    [(AstDecl.DefStruct decl-meta _ _ _ _) 5]
    [(AstDecl.Import decl-meta _) 6]
    [(AstDecl.Test _ _ _) 7]
    [(AstDecl.Module _) 9]
    [(AstDecl.ModuleBody _ _) 18]
    [(AstDecl.IncludeStr _ _) 12]
    [(AstDecl.IncludeStrComptime _ _) 19]
    [(AstDecl.IncludeStrLzss _ _) 20]
    [(AstDecl.Unsafe _) 13]
    [(AstDecl.DefEnumLifetimes decl-meta _ _ _ _) 14]
    [(AstDecl.DefStructLifetimes decl-meta _ _ _ _ _) 15]
    [(AstDecl.DefDispatch decl-meta _ _) 16]
    [(AstDecl.IncludeBin _ _) 17]))

(define (ast-struct-repr-c? [repr : AstStructRepr]) : bool
  (match repr
    [(AstStructRepr.C) true]
    [(AstStructRepr.Default) false]))

(define (ast-extern-abi-c? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbi.C) true]
    [(AstExternAbi.CVarargsOpen) true]
    [(AstExternAbi.CVarargsTyped _) true]))

(define (ast-extern-abi-c-varargs? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbi.C) false]
    [(AstExternAbi.CVarargsOpen) true]
    [(AstExternAbi.CVarargsTyped _) true]))

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
      (=
        (array-ref (struct-get a slots) index)
        (array-ref (struct-get b slots) index))
      (ast-lifetime-list-eq-at? a b len (+ index 1)))))

(define (ast-lifetime-list-eq? [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (let
    [len : i64 (ast-lifetime-list-len (& a))]
    (and
      (= len (ast-lifetime-list-len (& b)))
      (ast-lifetime-list-eq-at? (& a) (& b) len 0))))

;; Legacy/test equality family for callers using the installed reader. Compiler
;; phases use `ast-type-eq-with-pools?` or its hoisted segment-bases worker.
(define (ast-type-list-eq-at?
  [a : (& a AstTypeList)]
  [b : (& b AstTypeList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (ast-type-eq?
        (ast-node-pool-reader-type-get (array-ref (struct-get a slots) index))
        (ast-node-pool-reader-type-get (array-ref (struct-get b slots) index)))
      (ast-type-list-eq-at? a b len (+ index 1)))))

(define (ast-type-list-eq? [a : AstTypeList] [b : AstTypeList]) : bool
  (let
    [len : i64 (ast-type-list-len (& a))]
    (and
      (= len (ast-type-list-len (& b)))
      (ast-type-list-eq-at? (& a) (& b) len 0))))

(define (ast-type-eq? [a : AstType] [b : AstType]) : bool
  (match a
    [(AstType.I64)
      (match b
        [(AstType.I64) true]
        [_ false])]
    [(AstType.I32)
      (match b
        [(AstType.I32) true]
        [_ false])]
    [(AstType.I16)
      (match b
        [(AstType.I16) true]
        [_ false])]
    [(AstType.I8)
      (match b
        [(AstType.I8) true]
        [_ false])]
    [(AstType.U64)
      (match b
        [(AstType.U64) true]
        [_ false])]
    [(AstType.U32)
      (match b
        [(AstType.U32) true]
        [_ false])]
    [(AstType.U16)
      (match b
        [(AstType.U16) true]
        [_ false])]
    [(AstType.U8)
      (match b
        [(AstType.U8) true]
        [_ false])]
    [(AstType.F64)
      (match b
        [(AstType.F64) true]
        [_ false])]
    [(AstType.F32)
      (match b
        [(AstType.F32) true]
        [_ false])]
    [(AstType.Bool)
      (match b
        [(AstType.Bool) true]
        [_ false])]
    [(AstType.Char)
      (match b
        [(AstType.Char) true]
        [_ false])]
    [(AstType.String)
      (match b
        [(AstType.String) true]
        [_ false])]
    [(AstType.Str)
      (match b
        [(AstType.Str) true]
        [_ false])]
    [(AstType.Bytes)
      (match b
        [(AstType.Bytes) true]
        [_ false])]
    [(AstType.Unit)
      (match b
        [(AstType.Unit) true]
        [_ false])]
    [(AstType.Never)
      (match b
        [(AstType.Never) true]
        [_ false])]
    [(AstType.Expr)
      (match b
        [(AstType.Expr) true]
        [_ false])]
    [(AstType.ExprList)
      (match b
        [(AstType.ExprList) true]
        [_ false])]
    [(AstType.Func a-args a-ret)
      (match b
        [(AstType.Func b-args b-ret)
          (and
            (ast-type-list-eq? (box-get a-args) (box-get b-args))
            (ast-type-eq?
              (ast-node-pool-reader-type-get a-ret)
              (ast-node-pool-reader-type-get b-ret)))]
        [_ false])]
    [(AstType.Tuple a-elems)
      (match b
        [(AstType.Tuple b-elems)
          (ast-type-list-eq? (box-get a-elems) (box-get b-elems))]
        [_ false])]
    [(AstType.Array a-elem a-len)
      (match b
        [(AstType.Array b-elem b-len)
          (and
            (= a-len b-len)
            (ast-type-eq?
              (ast-node-pool-reader-type-get a-elem)
              (ast-node-pool-reader-type-get b-elem)))]
        [_ false])]
    [(AstType.DynArray a-elem)
      (match b
        [(AstType.DynArray b-elem)
          (ast-type-eq?
            (ast-node-pool-reader-type-get a-elem)
            (ast-node-pool-reader-type-get b-elem))]
        [_ false])]
    [(AstType.Box a-elem)
      (match b
        [(AstType.Box b-elem)
          (ast-type-eq?
            (ast-node-pool-reader-type-get a-elem)
            (ast-node-pool-reader-type-get b-elem))]
        [_ false])]
    [(AstType.Region a-region a-inner)
      (match b
        [(AstType.Region b-region b-inner)
          (and
            (= a-region b-region)
            (ast-type-eq?
              (ast-node-pool-reader-type-get a-inner)
              (ast-node-pool-reader-type-get b-inner)))]
        [_ false])]
    [(AstType.Ref a-lifetime a-inner)
      (match b
        [(AstType.Ref b-lifetime b-inner)
          (and
            (= a-lifetime b-lifetime)
            (ast-type-eq?
              (ast-node-pool-reader-type-get a-inner)
              (ast-node-pool-reader-type-get b-inner)))]
        [_ false])]
    [(AstType.MutRef a-lifetime a-inner)
      (match b
        [(AstType.MutRef b-lifetime b-inner)
          (and
            (= a-lifetime b-lifetime)
            (ast-type-eq?
              (ast-node-pool-reader-type-get a-inner)
              (ast-node-pool-reader-type-get b-inner)))]
        [_ false])]
    [(AstType.Enum a-name)
      (match b
        [(AstType.Enum b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.EnumArgs a-name a-lifetimes)
      (match b
        [(AstType.EnumArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Struct a-name)
      (match b
        [(AstType.Struct b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.StructArgs a-name a-lifetimes)
      (match b
        [(AstType.StructArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Var a-name)
      (match b
        [(AstType.Var b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.VarArgs a-name a-lifetimes)
      (match b
        [(AstType.VarArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Ptr a-elem)
      (match b
        [(AstType.Ptr b-elem)
          (ast-type-eq?
            (ast-node-pool-reader-type-get a-elem)
            (ast-node-pool-reader-type-get b-elem))]
        [_ false])]
    [(AstType.MutPtr a-elem)
      (match b
        [(AstType.MutPtr b-elem)
          (ast-type-eq?
            (ast-node-pool-reader-type-get a-elem)
            (ast-node-pool-reader-type-get b-elem))]
        [_ false])]
    [(AstType.Consume a-inner)
      (match b
        [(AstType.Consume b-inner)
          (ast-type-eq?
            (ast-node-pool-reader-type-get a-inner)
            (ast-node-pool-reader-type-get b-inner))]
        [_ false])]))

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
        [_ false])]))

(define (ast-type-list-eq-at-with-seg-bases?
  [seg-bases : i64]
  [a : (& a AstTypeList)]
  [b : (& b AstTypeList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (ast-type-eq-with-seg-bases?
        seg-bases
        (ast-type-segment-bases-get
          seg-bases
          (array-ref (struct-get a slots) index))
        (ast-type-segment-bases-get
          seg-bases
          (array-ref (struct-get b slots) index)))
      (ast-type-list-eq-at-with-seg-bases? seg-bases a b len (+ index 1)))))

;; Read-only walk entry point: snapshot the type pool's segment-bases once, so
;; the recursive workers address nodes exactly as cheaply as `ty-node-get`.
;; Safe because these walkers never push, and pushes are what replace the cell.
(define (ast-type-list-eq-at-with-pools?
  [pools : AstNodePoolContext]
  [a : (& a AstTypeList)]
  [b : (& b AstTypeList)]
  [len : i64]
  [index : i64]) : bool
  (ast-type-list-eq-at-with-seg-bases?
    (ast-node-pool-context-type-segment-bases pools)
    a
    b
    len
    index))

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
  (match a
    [(AstType.I64)
      (match b
        [(AstType.I64) true]
        [_ false])]
    [(AstType.I32)
      (match b
        [(AstType.I32) true]
        [_ false])]
    [(AstType.I16)
      (match b
        [(AstType.I16) true]
        [_ false])]
    [(AstType.I8)
      (match b
        [(AstType.I8) true]
        [_ false])]
    [(AstType.U64)
      (match b
        [(AstType.U64) true]
        [_ false])]
    [(AstType.U32)
      (match b
        [(AstType.U32) true]
        [_ false])]
    [(AstType.U16)
      (match b
        [(AstType.U16) true]
        [_ false])]
    [(AstType.U8)
      (match b
        [(AstType.U8) true]
        [_ false])]
    [(AstType.F64)
      (match b
        [(AstType.F64) true]
        [_ false])]
    [(AstType.F32)
      (match b
        [(AstType.F32) true]
        [_ false])]
    [(AstType.Bool)
      (match b
        [(AstType.Bool) true]
        [_ false])]
    [(AstType.Char)
      (match b
        [(AstType.Char) true]
        [_ false])]
    [(AstType.String)
      (match b
        [(AstType.String) true]
        [_ false])]
    [(AstType.Str)
      (match b
        [(AstType.Str) true]
        [_ false])]
    [(AstType.Bytes)
      (match b
        [(AstType.Bytes) true]
        [_ false])]
    [(AstType.Unit)
      (match b
        [(AstType.Unit) true]
        [_ false])]
    [(AstType.Never)
      (match b
        [(AstType.Never) true]
        [_ false])]
    [(AstType.Expr)
      (match b
        [(AstType.Expr) true]
        [_ false])]
    [(AstType.ExprList)
      (match b
        [(AstType.ExprList) true]
        [_ false])]
    [(AstType.Func a-args a-ret)
      (match b
        [(AstType.Func b-args b-ret)
          (let
            [a-arg-list : AstTypeList (box-get a-args)]
            [b-arg-list : AstTypeList (box-get b-args)]
            [a-arg-len : i64 (ast-type-list-len (& a-arg-list))]
            (and
              (= a-arg-len (ast-type-list-len (& b-arg-list)))
              (ast-type-list-eq-at-with-seg-bases?
                seg-bases
                (& a-arg-list)
                (& b-arg-list)
                a-arg-len
                0)
              (ast-type-eq-with-seg-bases?
                seg-bases
                (ast-type-segment-bases-get seg-bases a-ret)
                (ast-type-segment-bases-get seg-bases b-ret))))]
        [_ false])]
    [(AstType.Tuple a-elems)
      (match b
        [(AstType.Tuple b-elems)
          (let
            [a-elem-list : AstTypeList (box-get a-elems)]
            [b-elem-list : AstTypeList (box-get b-elems)]
            [a-elem-len : i64 (ast-type-list-len (& a-elem-list))]
            (and
              (= a-elem-len (ast-type-list-len (& b-elem-list)))
              (ast-type-list-eq-at-with-seg-bases?
                seg-bases
                (& a-elem-list)
                (& b-elem-list)
                a-elem-len
                0)))]
        [_ false])]
    [(AstType.Array a-elem a-len)
      (match b
        [(AstType.Array b-elem b-len)
          (and
            (= a-len b-len)
            (ast-type-eq-with-seg-bases?
              seg-bases
              (ast-type-segment-bases-get seg-bases a-elem)
              (ast-type-segment-bases-get seg-bases b-elem)))]
        [_ false])]
    [(AstType.DynArray a-elem)
      (match b
        [(AstType.DynArray b-elem)
          (ast-type-eq-with-seg-bases?
            seg-bases
            (ast-type-segment-bases-get seg-bases a-elem)
            (ast-type-segment-bases-get seg-bases b-elem))]
        [_ false])]
    [(AstType.Box a-elem)
      (match b
        [(AstType.Box b-elem)
          (ast-type-eq-with-seg-bases?
            seg-bases
            (ast-type-segment-bases-get seg-bases a-elem)
            (ast-type-segment-bases-get seg-bases b-elem))]
        [_ false])]
    [(AstType.Region a-region a-inner)
      (match b
        [(AstType.Region b-region b-inner)
          (and
            (= a-region b-region)
            (ast-type-eq-with-seg-bases?
              seg-bases
              (ast-type-segment-bases-get seg-bases a-inner)
              (ast-type-segment-bases-get seg-bases b-inner)))]
        [_ false])]
    [(AstType.Ref a-lifetime a-inner)
      (match b
        [(AstType.Ref b-lifetime b-inner)
          (and
            (= a-lifetime b-lifetime)
            (ast-type-eq-with-seg-bases?
              seg-bases
              (ast-type-segment-bases-get seg-bases a-inner)
              (ast-type-segment-bases-get seg-bases b-inner)))]
        [_ false])]
    [(AstType.MutRef a-lifetime a-inner)
      (match b
        [(AstType.MutRef b-lifetime b-inner)
          (and
            (= a-lifetime b-lifetime)
            (ast-type-eq-with-seg-bases?
              seg-bases
              (ast-type-segment-bases-get seg-bases a-inner)
              (ast-type-segment-bases-get seg-bases b-inner)))]
        [_ false])]
    [(AstType.Enum a-name)
      (match b
        [(AstType.Enum b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.EnumArgs a-name a-lifetimes)
      (match b
        [(AstType.EnumArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Struct a-name)
      (match b
        [(AstType.Struct b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.StructArgs a-name a-lifetimes)
      (match b
        [(AstType.StructArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Var a-name)
      (match b
        [(AstType.Var b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.VarArgs a-name a-lifetimes)
      (match b
        [(AstType.VarArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Ptr a-elem)
      (match b
        [(AstType.Ptr b-elem)
          (ast-type-eq-with-seg-bases?
            seg-bases
            (ast-type-segment-bases-get seg-bases a-elem)
            (ast-type-segment-bases-get seg-bases b-elem))]
        [_ false])]
    [(AstType.MutPtr a-elem)
      (match b
        [(AstType.MutPtr b-elem)
          (ast-type-eq-with-seg-bases?
            seg-bases
            (ast-type-segment-bases-get seg-bases a-elem)
            (ast-type-segment-bases-get seg-bases b-elem))]
        [_ false])]
    [(AstType.Consume a-inner)
      (match b
        [(AstType.Consume b-inner)
          (ast-type-eq-with-seg-bases?
            seg-bases
            (ast-type-segment-bases-get seg-bases a-inner)
            (ast-type-segment-bases-get seg-bases b-inner))]
        [_ false])]))

(define (ast-extern-abi-eq-with-pools?
  [pools : AstNodePoolContext]
  [a : AstExternAbi]
  [b : AstExternAbi]) : bool
  (ast-extern-abi-eq-with-seg-bases?
    (ast-node-pool-context-type-segment-bases pools)
    a
    b))

(define (ast-extern-abi-eq-with-seg-bases?
  [seg-bases : i64]
  [a : AstExternAbi]
  [b : AstExternAbi]) : bool
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
        [(AstExternAbi.CVarargsTyped bty)
          (ast-type-eq-with-seg-bases? seg-bases aty bty)]
        [_ false])]))

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
    [(AstExternMetadata.Metadata _ symbol-id _ _ _) (ci.intern-str symbol-id)]))

(define (ast-extern-metadata-symbol-id [metadata : AstExternMetadata]) : i64
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

(define (compiler-ast-begin-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Begin _) true]
    [_ false]))

(define (compiler-ast-nested-pattern-box-ok? [pattern : AstPattern]) : bool
  (match pattern
    [(AstPattern.Variant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (and
          (= name cbi.compiler-builtin-id-fix-Some)
          (= (struct-get (& args) len) 1)
          (match (ast-pattern-list-get (& args) 0 (ast-pattern-fallback))
            [(AstPattern.Tuple items-box)
              (let
                [items : AstPatternList (box-get items-box)]
                (and
                  (= (struct-get (& items) len) 2)
                  (match (ast-pattern-list-get
                    (& items)
                    0
                    (ast-pattern-fallback))
                    [(AstPattern.Binding bind-name)
                      (= bind-name cbi.compiler-builtin-id-fix-item)]
                    [_ false])
                  (match (ast-pattern-list-get
                    (& items)
                    1
                    (ast-pattern-fallback))
                    [(AstPattern.Wildcard) true]
                    [_ false])))]
            [_ false])))]
    [_ false]))

(define (compiler-ast-single-arm-box-ok? [arms : AstMatchArmList]) : bool
  (and
    (= (ast-match-arm-list-len (& arms)) 1)
    (match (ast-match-arm-list-get (& arms) 0 (ast-match-arm-fallback))
      [(AstMatchArm.Arm pattern body-id)
        (let
          [body : AstExpr (ast-node-get body-id)]
          (and
            (compiler-ast-nested-pattern-box-ok? pattern)
            (compiler-ast-begin-expr? body)))]
      [_ false])))

(define (compiler-ast-nested-expr-box-ok? [expr : AstExpr]) : bool
  (match expr
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (and
              (= (ast-let-binding-list-len (& bindings)) 1)
              (match (ast-let-binding-list-get
                (& bindings)
                0
                (ast-let-binding-fallback))
                [(AstLetBinding.Binding name _ init-box)
                  (let
                    [init : AstExpr (ast-node-get init-box)]
                    (and
                      (= name cbi.compiler-builtin-id-fix-x)
                      (compiler-ast-begin-expr? init)))]
                [_ false])
              (match body
                [(AstExpr.If cond-box then-box else-box)
                  (let
                    [cond : AstExpr (ast-node-get cond-box)]
                    [then-expr : AstExpr (ast-node-get then-box)]
                    [else-expr : AstExpr (ast-node-get else-box)]
                    (and
                      (match cond
                        [(AstExpr.Var name)
                          (string.eq (ci.intern-str name) "cond")]
                        [_ false])
                      (match then-expr
                        [(AstExpr.Match match-box)
                          (match (box-get match-box)
                            [(AstMatch.Match scrut-box arms)
                              (let
                                [scrut : AstExpr (ast-node-get scrut-box)]
                                (and
                                  (match scrut
                                    [(AstExpr.Var name)
                                      (string.eq (ci.intern-str name) "input")]
                                    [_ false])
                                  (compiler-ast-single-arm-box-ok? arms)))])]
                        [_ false])
                      (compiler-ast-begin-expr? else-expr)))]
                [_ false])))])]
    [_ false]))

(define (compiler-ast-expr-pattern-box-smoke?) : bool
  (let
    [one : i64 (ast-node-push (AstExpr.Literal (ast-lit-int 1)))]
    [two : i64 (ast-node-push (AstExpr.Literal (ast-lit-int 2)))]
    [begin-expr : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons one (ast-expr-cons two (ast-expr-list-new)))))]
    [bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding-id
          cbi.compiler-builtin-id-fix-x
          (AstMaybeType.No)
          begin-expr)
        (ast-let-binding-list-new))]
    [tuple-pattern : AstPattern
      (ast-pat-tuple
        (ast-pattern-cons
          (ast-pat-binding-id cbi.compiler-builtin-id-fix-item)
          (ast-pattern-cons (AstPattern.Wildcard) (ast-pattern-list-new))))]
    [variant-pattern : AstPattern
      (ast-pat-variant-id
        cbi.compiler-builtin-id-fix-Some
        (ast-pattern-cons tuple-pattern (ast-pattern-list-new)))]
    [arms : AstMatchArmList
      (ast-match-arm-cons
        (ast-match-arm variant-pattern begin-expr)
        (ast-match-arm-list-new))]
    [match-expr : i64
      (ast-expr-match
        (ast-node-push (AstExpr.Var cbi.compiler-builtin-id-fix-input))
        arms)]
    [nested : i64
      (ast-expr-let
        bindings
        (ast-expr-if
          (ast-node-push (AstExpr.Var cbi.compiler-builtin-id-fix-cond))
          match-expr
          begin-expr))]
    (compiler-ast-nested-expr-box-ok? (ast-node-get nested))))

(define (compiler-ast-decl-def-lit-ok?
  [decl : AstDecl]
  [want-name-id : i64]
  [want-value : i64]) : bool
  (match decl
    [(AstDecl.Def decl-meta name _ value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (and
          (= name want-name-id)
          (match value
            [(AstExpr.Literal (AstLiteral.Int actual _)) (= actual want-value)]
            [_ false])))]
    [_ false]))

(define (compiler-ast-nested-decl-box-ok?
  [decl : AstDecl]
  [generated-name-id : i64]) : bool
  (match decl
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (and
          (ast-decl-comptime-only? inner)
          (compiler-ast-decl-def-lit-ok? inner generated-name-id 7)))]
    [_ false]))

(define (compiler-ast-decl-program-box-smoke?) : bool
  (let
    [generated-name-id : i64 (ci.intern-generated-name "generated")]
    [runtime-name-id : i64 (ci.intern-generated-name "runtime")]
    [generated : AstDecl
      (ast-decl-def-id
        generated-name-id
        (AstMaybeType.Some (AstType.I64))
        (ast-node-push (AstExpr.Literal (ast-lit-int 7))))]
    [runtime : AstDecl
      (ast-decl-def-id
        runtime-name-id
        (AstMaybeType.Some (AstType.I64))
        (ast-node-push (AstExpr.Literal (ast-lit-int 9))))]
    [nested : AstDecl (ast-decl-unsafe (ast-decl-comptime-decl generated))]
    [program : AstProgram
      (ast-program
        (ast-decl-cons nested (ast-decl-cons runtime (ast-decl-list-new))))]
    (match program
      [(AstProgram.Program decls-box)
        (let
          [decls : AstDeclList (box-get decls-box)]
          (match (ast-decl-list-step decls)
            [(AstDeclListStep.Cons first rest-box)
              (let
                [rest : AstDeclList rest-box]
                (and
                  (compiler-ast-nested-decl-box-ok? first generated-name-id)
                  (match (ast-decl-list-step rest)
                    [(AstDeclListStep.Cons second done-box)
                      (let
                        [done : AstDeclList done-box]
                        (and
                          (compiler-ast-decl-def-lit-ok?
                            second
                            runtime-name-id
                            9)
                          (match (ast-decl-list-step done)
                            [(AstDeclListStep.Nil) true]
                            [_ false])))]
                    [_ false])))]
            [_ false]))])))

;; The ty-node pool grows on demand (see ty-node-pool-grow!) rather
;; than failing closed, so a push at capacity allocates a larger backing array and
;; assigns the next sequential id -- it never exhausts. Verify that growth.
(define (compiler-ast-type-pool-exhaustion-smoke?) : bool
  (let
    [capacity : i64 (ty-node-pool-capacity)]
    (begin
      (ty-node-pool-reset!)
      (ty-node-pool-truncate! capacity)
      (let
        [id : i64 (ty-node-push (AstType.I64))]
        [len : i64 (ty-node-pool-len)]
        [exhausted : bool (ty-node-pool-exhausted?)]
        [grew : bool (> (ty-node-pool-capacity) capacity)]
        (begin
          (ty-node-pool-reset!)
          (and (not exhausted) (= id capacity) (= len (+ capacity 1)) grew))))))

(define (compiler-ast-type-dedup-smoke?) : bool
  (begin
    (ty-node-pool-reset!)
    (let
      [first-i64 : i64 (ty-node-push (AstType.I64))]
      [first-len : i64 (ty-node-pool-len)]
      [second-i64 : i64 (ty-node-push (AstType.I64))]
      [second-len : i64 (ty-node-pool-len)]
      [first-array : i64 (ty-node-push (ast-ty-array (AstType.I64) 4))]
      [array-len : i64 (ty-node-pool-len)]
      [second-array : i64 (ty-node-push (ast-ty-array (AstType.I64) 4))]
      [final-len : i64 (ty-node-pool-len)]
      [first-bytes : i64 (ty-node-push (AstType.Bytes))]
      [bytes-len : i64 (ty-node-pool-len)]
      [second-bytes : i64 (ty-node-push (AstType.Bytes))]
      [second-bytes-len : i64 (ty-node-pool-len)]
      [str-ty : i64 (ty-node-push (AstType.Str))]
      [str-len : i64 (ty-node-pool-len)]
      [ok : bool
        (and
          (= first-i64 second-i64)
          (= first-len 1)
          (= second-len 1)
          (= first-array second-array)
          (= array-len 2)
          (= final-len 2)
          (= first-bytes second-bytes)
          (= bytes-len 3)
          (= second-bytes-len 3)
          (not (= first-bytes str-ty))
          (= str-len 4))]
      (begin
        (ty-node-pool-reset!)
        ok))))

(define (compiler-ast-spmd-metadata-clone-smoke?) : bool
  (let
    [classes : AstSpmdParamClassList (ast-spmd-param-class-list-new)]
    [specializations : AstSpmdSpecializationList
      (ast-spmd-specialization-list-new)]
    (begin
      (ast-spmd-param-class-list-push (&mut classes) AstSpmdParamClass.Varying)
      (ast-spmd-param-class-list-push (&mut classes) AstSpmdParamClass.Uniform)
      (ast-spmd-specialization-list-push
        (&mut specializations)
        (AstSpmdSpecialization 8 (box classes) AstSpmdResultClass.Varying 0))
      (let
        [copied : AstFnMetadata
          (ast-fn-metadata-clone
            (AstFnMetadata.SpmdCallable (box specializations)))]
        (match (ast-fn-metadata-spmd-callable copied)
          [(AstSpmdCallable.Callable copied-items)
            (let
              [fallback : AstSpmdSpecialization
                (AstSpmdSpecialization
                  2
                  (box (ast-spmd-param-class-list-new))
                  AstSpmdResultClass.Unit
                  -1)]
              [item : AstSpmdSpecialization
                (ast-spmd-specialization-list-get (& copied-items) 0 fallback)]
              [copied-classes : AstSpmdParamClassList
                (box-get (struct-get item args))]
              (and
                (= (ast-spmd-specialization-list-len (& copied-items)) 1)
                (= (struct-get item lanes) 8)
                (= (struct-get item index-param) 0)
                (match (struct-get item result)
                  [(AstSpmdResultClass.Varying) true]
                  [_ false])
                (match (ast-spmd-param-class-list-get
                  (& copied-classes)
                  0
                  AstSpmdParamClass.Uniform)
                  [(AstSpmdParamClass.Varying) true]
                  [_ false])
                (match (ast-spmd-param-class-list-get
                  (& copied-classes)
                  1
                  AstSpmdParamClass.Varying)
                  [(AstSpmdParamClass.Uniform) true]
                  [_ false])))]
          [_ false])))))

(define (compiler-ast-imported-spmd-metadata-clone-smoke?) : bool
  (let
    [specializations : AstImportedSpmdSpecializationList
      (ast-imported-spmd-specialization-list-new)]
    [callables : AstImportedSpmdCallableList
      (ast-imported-spmd-callable-list-new)]
    (begin
      (ast-imported-spmd-specialization-list-push
        (&mut specializations)
        (AstImportedSpmdSpecialization 1 2 8 3 4 0 5))
      (ast-imported-spmd-callable-list-push
        (&mut callables)
        (AstImportedSpmdCallable 6 specializations))
      (match (ast-imported-spmd-metadata-clone
        (AstImportedSpmdMetadata.Package 7 (box callables)))
        [(AstImportedSpmdMetadata.Package name copied-callables)
          (let
            [copied : AstImportedSpmdCallableList (box-get copied-callables)]
            [callable : AstImportedSpmdCallable
              (ast-imported-spmd-callable-list-get
                (& copied)
                0
                (ast-imported-spmd-callable-fallback))]
            [copied-specializations : AstImportedSpmdSpecializationList
              (struct-get callable specializations)]
            [item : AstImportedSpmdSpecialization
              (ast-imported-spmd-specialization-list-get
                (& copied-specializations)
                0
                (ast-imported-spmd-specialization-fallback))]
            (and
              (= name 7)
              (= (ast-imported-spmd-callable-list-len (& copied)) 1)
              (= (struct-get callable signature) 6)
              (=
                (ast-imported-spmd-specialization-list-len
                  (& copied-specializations))
                1)
              (= (struct-get item lanes) 8)
              (= (struct-get item symbol) 5)))]
        [(AstImportedSpmdMetadata.No) false]))))

(define (compiler-ast-smoke) : i64
  (let
    [_builtin-init : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [i64-ty : AstType (AstType.I64)]
    [string-ty : AstType (AstType.String)]
    [arg-tys : AstTypeList
      (ast-type-cons i64-ty (ast-type-cons string-ty (ast-type-list-new)))]
    [ret-ty : AstType
      (ast-ty-ref
        (ci.intern-generated-name "r")
        (ast-ty-ptr (ast-ty-array i64-ty 4)))]
    [fn-ty : AstType (ast-ty-func arg-tys ret-ty)]
    [nested-ty-ok? : bool
      (match fn-ty
        [(AstType.Func _ ret)
          (match (ty-node-get ret)
            [(AstType.Ref region ptr)
              (and
                (string.eq (ci.intern-str region) "r")
                (match (ty-node-get ptr)
                  [(AstType.Ptr array)
                    (match (ty-node-get array)
                      [(AstType.Array elem count)
                        (and
                          (= count 4)
                          (match (ty-node-get elem)
                            [(AstType.I64) true]
                            [_ false]))]
                      [_ false])]
                  [_ false]))]
            [_ false])]
        [_ false])]
    [lit : AstLiteral (ast-lit-int 41)]
    [one : i64 (ast-node-push (AstExpr.Literal (ast-lit-int 1)))]
    [expr : i64
      (ast-expr-binary (AstBinOp.Add) (ast-node-push (AstExpr.Literal lit)) one)]
    [nested-expr-pattern-ok? : bool (compiler-ast-expr-pattern-box-smoke?)]
    [decl-program-ok? : bool (compiler-ast-decl-program-box-smoke?)]
    [type-dedup-ok? : bool (compiler-ast-type-dedup-smoke?)]
    [pool-exhaustion-ok? : bool (compiler-ast-type-pool-exhaustion-smoke?)]
    [spmd-metadata-clone-ok? : bool (compiler-ast-spmd-metadata-clone-smoke?)]
    [imported-spmd-metadata-clone-ok? : bool
      (compiler-ast-imported-spmd-metadata-clone-smoke?)]
    [param : AstParam (ast-param-id cbi.compiler-builtin-id-fix-x i64-ty false)]
    [params : AstParamList (ast-param-cons param (ast-param-list-new))]
    [decl : AstDecl
      (ast-decl-def-fn-id cbi.compiler-builtin-id-fix-main params i64-ty expr)]
    [program : AstProgram
      (ast-program (ast-decl-cons decl (ast-decl-list-new)))]
    (match program
      [(AstProgram.Program _)
        (if (and
          nested-ty-ok?
          nested-expr-pattern-ok?
          decl-program-ok?
          type-dedup-ok?
          pool-exhaustion-ok?
          spmd-metadata-clone-ok?
          imported-spmd-metadata-clone-ok?)
          (+
            (ast-type-tag fn-ty)
            (+ (ast-expr-tag (ast-node-get expr)) (ast-decl-tag decl)))
          0)])))