;; compiler_ast_types.tl - Self-hosted model of the real TypeLisp AST (#334).
;;
;; This module is intentionally separate from ast_types.tl, which remains the
;; smaller compile_smoke AST. The types below mirror Rust's src/ast.rs and
;; src/types.rs closely enough for the future Sexpr -> real-AST parser to target
;; them without committing to typechecking, lowering, or code generation yet.
;;
;; Deferred on purpose: parser result/error wrappers, typechecker registries,
;; inferred types, and lowered IR metadata. Source spans are represented as data
;; but later parser work decides when they are populated.
(import "compiler_intern.tl")

;; #2357: arena access for the node-pool grow paths -- a regrown pool array must
;; be allocated in the persistent program arena, never a transient scratch arena
;; (which gets destroyed, leaving the global pool dangling). arena.tl has no
;; imports, so this adds no cycle.
(import "../stdlib/arena.tl")

;; #2604: hash/equality helpers for the ty-node hash-consing table below.
(import "../stdlib/hash.tl")
(import "../stdlib/string.tl")

(defstruct AstSourceSpan
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64))

(defenum AstLiteral
  (AstLitInt i64)
  (AstLitFloat String)
  (AstLitBool bool)
  (AstLitChar char)
  (AstLitString String)
  (AstLitUnit))

(defenum AstBinOp
  (AstBinAdd)
  (AstBinSub)
  (AstBinMul)
  (AstBinDiv)
  (AstBinMod)
  (AstBinEq)
  (AstBinNe)
  (AstBinLt)
  (AstBinLe)
  (AstBinGt)
  (AstBinGe)
  (AstBinAnd)
  (AstBinOr)
  (AstBinBitAnd)
  (AstBinBitOr)
  (AstBinBitXor)
  (AstBinShl)
  (AstBinShr))

(defenum AstUnOp
  (AstUnNeg)
  (AstUnNot)
  (AstUnBitNot))

(defenum AstReduceOp
  (AstReduceSum)
  (AstReduceMin)
  (AstReduceMax)
  (AstReduceAll)
  (AstReduceAny))

(defenum AstType
  (AstTyI64)
  (AstTyI32)
  (AstTyI16)
  (AstTyI8)
  (AstTyU64)
  (AstTyU32)
  (AstTyU16)
  (AstTyU8)
  (AstTyF64)
  (AstTyF32)
  (AstTyBool)
  (AstTyChar)
  (AstTyString)
  (AstTyStr)
  (AstTyBytes)
  (AstTyUnit)
  (AstTyNever)
  ;; User-facing macro code-as-data type (#1135). This is a single concrete
  ;; compile-time-only type; the produced runtime type is tracked internally by
  ;; CTFE values, not as a source-level type parameter.
  (AstTyExpr)
  (AstTyExprList)
  (AstTyFunc AstTypeList i64)
  (AstTyTuple AstTypeList)
  (AstTyArray i64 i64)
  (AstTyDynArray i64)
  (AstTyBox i64)
  (AstTyRegion String i64)
  (AstTyRef String i64)
  (AstTyMutRef String i64)
  (AstTyEnum i64)
  (AstTyEnumArgs i64 AstLifetimeList)
  (AstTyStruct i64)
  (AstTyStructArgs i64 AstLifetimeList)
  (AstTyVar i64)
  (AstTyVarArgs i64 AstLifetimeList)
  (AstTyPtr i64)
  (AstTyMutPtr i64))

(defenum AstTypeList
  (AstTypeNil)
  (AstTypeCons i64 (Box AstTypeList)))

(defenum AstLifetimeList
  (AstLifetimeNil)
  (AstLifetimeCons String (Box AstLifetimeList)))

(defenum AstMaybeType
  (AstNoType)
  (AstSomeType AstType))

(defenum AstBorrowLifetime
  (AstBorrowLifetimeInferred)
  (AstBorrowLifetimeNamed String))

(defenum AstParam
  (AstParam i64 AstType bool))

(defenum AstParamList
  (AstParamNil)
  (AstParamCons AstParam (Box AstParamList)))

(defenum AstMacroParam
  (AstMacroParam i64 AstType bool))

(defenum AstMacroParamList
  (AstMacroParamNil)
  (AstMacroParamCons AstMacroParam (Box AstMacroParamList)))

(defenum AstFieldCleanup
  (AstFieldNoCleanup)
  (AstFieldCleanupFn i64)
  (AstFieldOwnedCleanup))

(defenum AstFieldDef
  (AstFieldDef i64 AstType AstFieldCleanup))

(defenum AstFieldDefList
  (AstFieldDefNil)
  (AstFieldDefCons AstFieldDef (Box AstFieldDefList)))

(defenum AstStructRepr
  (AstStructReprDefault)
  (AstStructReprC))

(defenum AstExternAbi
  (AstExternAbiC)
  (AstExternAbiCVarargsOpen)
  (AstExternAbiCVarargsTyped AstType))

(defenum AstExternKind
  (AstExternValue)
  (AstExternFunction))

(defenum AstExternLinkInput
  (AstExternLinkLib String)
  (AstExternLinkSearch String)
  (AstExternLinkArg String))

(defenum AstExternLinkInputList
  (AstExternLinkInputNil)
  (AstExternLinkInputCons AstExternLinkInput (Box AstExternLinkInputList)))

(defenum AstFnExport
  (AstFnNoExport)
  (AstFnExport i64))

(defenum AstExternMetadata
  (AstExternMetadata AstExternAbi String AstExternLinkInputList bool))

(defenum AstStructCleanup
  (AstStructNoCleanup)
  (AstStructCleanupFn i64))

(defenum AstEnumCleanup
  (AstEnumNoCleanup)
  (AstEnumCleanupFn i64))

(defenum AstVariantPayloadCleanup
  (AstVariantPayloadNoCleanup)
  (AstVariantPayloadCleanupFn i64)
  (AstVariantPayloadOwnedCleanup))

(defenum AstVariantPayloadCleanupList
  (AstVariantPayloadCleanupNil)
  (AstVariantPayloadCleanupCons
    AstVariantPayloadCleanup
    (Box AstVariantPayloadCleanupList)))

(defenum AstVariantDef
  (AstVariantDef i64 AstTypeList AstVariantPayloadCleanupList))

(defenum AstVariantDefList
  (AstVariantDefNil)
  (AstVariantDefCons AstVariantDef (Box AstVariantDefList)))

(defenum AstPattern
  (AstPatVar i64 AstMaybeType)
  (AstPatTuple (Box AstPatternList))
  (AstPatWildcard)
  (AstPatBinding i64)
  (AstPatVariant i64 (Box AstPatternList))
  (AstPatLiteral AstLiteral))

(defenum AstPatternList
  (AstPatternNil)
  (AstPatternCons (Box AstPattern) (Box AstPatternList)))

(defenum AstLetBinding
  (AstLetBinding i64 AstMaybeType i64))

(defenum AstLetBindingList
  (AstLetBindingNil)
  (AstLetBindingCons AstLetBinding (Box AstLetBindingList)))

(defenum AstResourceBinding
  (AstResourceBinding i64 i64 i64))

(defenum AstResourceBindingList
  (AstResourceBindingNil)
  (AstResourceBindingCons AstResourceBinding (Box AstResourceBindingList)))

(defenum AstMatchArm
  (AstMatchArm AstPattern i64))

(defenum AstMatchArmList
  (AstMatchArmNil)
  (AstMatchArmCons AstMatchArm (Box AstMatchArmList)))

;; Boxed payload for `AstExprLambda`. Lambdas are rare in the AST, but their
;; inline payload (AstParamList ~80 B + AstMaybeType ~48 B) made
;; `AstExprLambda` the single largest `AstExpr` variant at 144 B -- and because
;; a defenum is laid out as `tag + max(variant)`, every one of the ~2M nodes in
;; the flat node pool paid that 144 B. Boxing the payload collapses the variant
;; to one word, shrinking every node (pool footprint and the per-node
;; `ast-node-get` copy) without slowing the common small variants.
(defenum AstLambda
  (AstLambda AstParamList AstMaybeType i64))

;; Boxed payload for `AstExprSpmdScan` (#3299). With ten fields including two
;; inline `AstType`s, the variant is 152 B -- the largest `AstExpr` variant,
;; which sets the size of every node in the flat pool. spmd-scan is rare, so
;; boxing its payload collapses the variant to one word and shrinks every node.
(defenum AstSpmdScan
  (AstSpmdScan AstReduceOp i64 AstType i64 i64 i64 AstType i64 i64 i64))

;; Boxed payload for `AstExprMatch`. After boxing AstExprLambda/AstExprSpmdScan
;; (#3313), `AstExprMatch i64 AstMatchArmList` is the largest variant at 112 B
;; (its arm list inlines AstMatchArm -> AstPattern -> AstMaybeType -> AstType).
;; Boxing it collapses the variant to one word, dropping the node to 104 B.
(defenum AstMatch
  (AstMatch i64 AstMatchArmList))

(defenum AstExpr
  (AstExprSpanned i64 AstSourceSpan)
  (AstExprLiteral AstLiteral)
  (AstExprVar i64)
  (AstExprBinary AstBinOp i64 i64)
  (AstExprUnary AstUnOp i64)
  (AstExprCall i64 AstExprList)
  (AstExprIf i64 i64 i64)
  (AstExprLet AstLetBindingList i64)
  (AstExprLambda (Box AstLambda))
  (AstExprTuple AstExprList)
  (AstExprTupleRef i64 i64)
  (AstExprArray AstExprList)
  (AstExprMakeArray AstType i64)
  (AstExprArrayRef i64 i64)
  (AstExprArraySet i64 i64 i64)
  (AstExprArrayPush i64 i64)
  (AstExprStringRef i64 i64)
  (AstExprWhile i64 i64)
  (AstExprBegin AstExprList)
  ;; `(unsafe expr+)` (#1053): a `begin`-like block that additionally marks an
  ;; unsafe context (v1 has the same runtime/type behavior as `begin`; the
  ;; unsafe-context flag is consumed by later raw-pointer ops, #955).
  (AstExprUnsafe AstExprList)
  (AstExprSet i64 i64)
  (AstExprAnn i64 AstType)
  (AstExprCast i64 AstType)
  (AstExprBorrow bool AstBorrowLifetime i64)
  (AstExprMatch (Box AstMatch))
  (AstExprForeach i64 AstType i64 i64 i64)
  (AstExprSpmdReduce AstReduceOp i64 AstType i64 i64 i64 i64)
  (AstExprSpmdScan (Box AstSpmdScan))
  (AstExprSpmdBroadcast i64 i64)
  (AstExprStructGet i64 i64)
  (AstExprStructSet i64 i64 i64)
  (AstExprWithRegion String AstExprList)
  (AstExprWithEscape i64 AstExprList)
  (AstExprWithScratch AstExprList)
  (AstExprInArena i64 AstExprList)
  (AstExprWithResource AstResourceBindingList AstExprList)
  (AstExprBox i64)
  (AstExprBoxGet i64)
  (AstExprBoxTake i64)
  (AstExprBoxSet i64 i64)
  ;; Compile-time-only type value literal: `(type T)`.
  (AstExprTypeLiteral AstType)
  ;; Zero/identity initialization. `(init : T)` carries `AstSomeType T`;
  ;; contextual `(init)` carries `AstNoType` until type checking/lowering sees
  ;; an expected type.
  (AstExprInit AstMaybeType)
  ;; Reserved compile-time evaluation form `(comptime expr)` (#718). Parsed and
  ;; type-checked (as the inner expression's type); evaluation lands in #719.
  (AstExprComptime i64)
  ;; Macro quote syntax (#1136). The reader desugars prefix quote tokens into
  ;; these list-headed forms before parsing:
  ;;   'x       -> (quote x)
  ;;   `x       -> (quasiquote x)
  ;;   ,x       -> (unquote x)
  ;;   ,@xs     -> (unquote-splicing xs)
  (AstExprQuote i64)
  (AstExprQuasiquote i64)
  (AstExprUnquote i64)
  (AstExprUnquoteSplicing i64)
  ;; Macro-only call operand syntax: `[expr expr]` bracket clauses are parsed
  ;; only inside call argument lists. Ordinary typechecking rejects this node;
  ;; macro binding consumes it for `ExprClause` operands.
  (AstExprBracketClause AstExprList)
  ;; Narrow Result-like propagation form `(try expr)` (#903). The temporary
  ;; convention recognizes concrete enums with one `Ok*` and one `Err*`
  ;; variant, each carrying exactly one payload.
  (AstExprTry i64)
  ;; General function-local early exit: `(return expr)` checks `expr` against
  ;; the enclosing function's return type and has the internal `never` type.
  (AstExprReturn i64)
  ;; Null raw-pointer construction `(ptr-null : T)` where `T` is `(Ptr U)` or
  ;; `(MutPtr U)` (#1054). Lowers to a pointer-sized zero; type is `T`.
  (AstExprPtrNull AstType)
  ;; Null check `(ptr-null? p)` on a raw pointer (#1054). Result is `bool`.
  (AstExprPtrNullCheck i64)
  ;; Unsafe raw-pointer operations (#1055). The typechecker admits these only
  ;; inside `(unsafe ...)`; lowering maps them to existing pointer IR.
  (AstExprPtrAddrOf i64)
  (AstExprPtrRead i64)
  (AstExprPtrWrite i64 i64)
  (AstExprPtrOffset i64 i64)
  (AstExprPtrCast i64 AstType)
  (AstExprPtrToInt i64)
  (AstExprIntToPtr i64 AstType)
  ;; Low-level FFI bridge operations used by stdlib. These expose raw backing
  ;; storage and process entry state without synthesizing runtime wrapper calls.
  (AstExprStringData i64)
  (AstExprStringFromBytes i64 i64)
  (AstExprArrayData i64)
  ;; Loader-generated payload for `(include-bin name "path")`. This is not a
  ;; source expression; it typechecks as `(Array u8)` and lowers to static data.
  (AstExprBinaryData String)
  (AstExprProgramArgc)
  (AstExprProgramArgv)
  (AstExprProgramEnvp)
  ;; Inline CPU feature instructions. These lower directly to x86_64 `cpuid`
  ;; and `xgetbv` instructions, avoiding emitted forwarding helpers.
  (AstExprCpuIdEax i64 i64)
  (AstExprCpuIdEbx i64 i64)
  (AstExprCpuIdEcx i64 i64)
  (AstExprCpuIdEdx i64 i64)
  (AstExprXgetbv i64)
  ;; Raw Linux x86_64 syscall. `(unsafe (syscall number a0 .. a5))` lowers
  ;; directly to a `syscall` instruction: the number plus up to six arguments.
  ;; Returns the raw kernel result in an i64 (negative is `-errno`); callers
  ;; translate errno.
  (AstExprSyscall AstExprList))

;; --- flat AST node pool (flat-node rewrite; owner directive "do the hard thing")
;; AstExpr nodes live in one growable pool, referenced by AstNodeId (an index)
;; instead of i64. This makes the expression AST a flat array: parsing
;; appends nodes (no per-node box), traversal indexes the pool (cache-friendly),
;; and the loader needs no per-file deep clone (nodes already persist in the pool).
;; The pool is process-global and reset per compile (see ast-node-pool-reset!),
;; reusing one backing array; AstNodeId values stay valid because the pool only
;; grows within a compile (callers truncate via ast-node-pool-mark/reset on parse
;; error). #2604/#2357: start below the old 4M slot baseline while staying large
;; enough for current selfhost-sized programs to avoid persistent growth arrays.
;; Two flat globals (array + count) rather than a reassigned struct: the hot
;; push/get paths are inlined everywhere, and a global-struct reassign in that
;; hot path tripped an opt2 miscompile. Plain mutable globals keep codegen simple.
(define ast-node-pool-slots : (Array AstExpr)
  (make-array AstExpr 2097152))

;; #2357: the program (base) arena, captured at global-init while it is the
;; active arena (the pool make-array above proves an allocation has happened, so
;; this is the real base handle, not the pre-allocation 0 sentinel). The node
;; pools live here for the whole program; a grow MUST allocate the new backing
;; array here too, otherwise -- if the grow fires while a transient scratch arena
;; is active (lowering/optimize) -- the regrown global array is freed when that
;; scratch arena is destroyed, leaving the pool dangling (a non-deterministic
;; use-after-free). This is why the pool previously failed closed.
(define node-pool-base-arena : i64
  (arena-current))
(define ast-node-pool-count : i64
  0)

;: Current node count (also the next AstNodeId that ast-node-push will assign).
(define (ast-node-pool-len) : i64
  ast-node-pool-count)

;: Grow the pool's backing array to at least double its current capacity.
;; #2357: allocate the new backing array in the persistent base arena (see
;; node-pool-base-arena) so it survives destruction of any scratch arena active
;; when the grow fires.
(define (ast-node-pool-grow!) : unit
  (let
    [old-slots : (Array AstExpr) ast-node-pool-slots]
    [old-cap : i64 (array-length old-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [prev-arena : i64 (arena-current)]
    [new-slots : (Array AstExpr)
      (begin
        (unsafe
          (arena-set! node-pool-base-arena))
        (let
          [arr : (Array AstExpr) (make-array AstExpr new-cap)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            arr)))]
    [len : i64 ast-node-pool-count]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! new-slots i (array-ref old-slots i))
          (set! i (+ i 1))))
      (set! ast-node-pool-slots new-slots))))

;: Append `node` to the pool and return its AstNodeId.
(define (ast-node-push [node : AstExpr]) : i64
  (begin
    (if (>= ast-node-pool-count (array-length ast-node-pool-slots))
      (ast-node-pool-grow!)
      unit)
    (let
      [id : i64 ast-node-pool-count]
      (begin
        (array-set! ast-node-pool-slots id node)
        (set! ast-node-pool-count (+ id 1))
        id))))

;: Read the node at `id`.
;;
;; #2357: this MUST stay `array-ref`, not a raw `(ptr-read (ptr-offset (ptr-cast
;; (array-data ...) : (Ptr AstExpr)) id))`. With #1867 inline-by-value aggregates
;; `AstExpr` is a multi-word value; `array-ref` lowers with the correct element
;; stride/size, whereas the raw ptr-offset path scales by a fixed word and adds a
;; spurious load, reading garbage and corrupting the pool read.
(define (ast-node-get [id : i64]) : AstExpr
  (array-ref ast-node-pool-slots id))

;: Overwrite the node at `id` in place (used when a node is rewritten in place).
(define (ast-node-set! [id : i64] [node : AstExpr]) : unit
  (array-set! ast-node-pool-slots id node))

;: Truncate the pool back to `mark` nodes (used to discard nodes from a failed
;: parse). Reset to 0 between compiles so a fresh compile reuses the array.
(define (ast-node-pool-truncate! [mark : i64]) : unit
  (set! ast-node-pool-count mark))

(define (ast-node-pool-reset-to! [mark : i64]) : unit
  (ast-node-pool-truncate! mark))

(define (ast-node-pool-reset!) : unit
  (ast-node-pool-truncate! 0))

;; State-owned expression node pools are the migration substrate for compiler
;; workers. The current compiler hot path still uses the process-global wrappers
;; above until parser/typechecker/driver state is threaded through every call.
(defstruct AstExprNodePoolState
  (slots (Array AstExpr))
  (count i64)
  (base-arena i64))

(defenum AstExprNodePoolPushResult
  (AstExprNodePoolPushOk AstExprNodePoolState i64))

(define (node-pool-state-normalize-capacity [capacity : i64]) : i64
  (if (< capacity 1)
    1
    capacity))

(define (ast-expr-node-pool-state-init [capacity : i64] [base-arena : i64]) : AstExprNodePoolState
  (let
    [cap : i64 (node-pool-state-normalize-capacity capacity)]
    [prev-arena : i64 (arena-current)]
    [slots : (Array AstExpr)
      (begin
        (unsafe
          (arena-set! base-arena))
        (let
          [arr : (Array AstExpr) (make-array AstExpr cap)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            arr)))]
    (AstExprNodePoolState slots 0 base-arena)))

(define (ast-expr-node-pool-state-create [capacity : i64]) : AstExprNodePoolState
  (ast-expr-node-pool-state-init capacity (arena-current)))

(define (ast-expr-node-pool-state-len [pool : AstExprNodePoolState]) : i64
  (struct-get pool count))

(define (ast-expr-node-pool-state-capacity [pool : AstExprNodePoolState]) : i64
  (array-length (struct-get pool slots)))

(define (ast-expr-node-pool-state-mark [pool : AstExprNodePoolState]) : i64
  (ast-expr-node-pool-state-len pool))

(define (ast-expr-node-pool-state-reset-to
  [pool : AstExprNodePoolState]
  [mark : i64]) : AstExprNodePoolState
  (AstExprNodePoolState
    (struct-get pool slots)
    mark
    (struct-get pool base-arena)))

(define (ast-expr-node-pool-state-reset-to-mark
  [pool : AstExprNodePoolState]
  [mark : i64]) : AstExprNodePoolState
  (ast-expr-node-pool-state-reset-to pool mark))

(define (ast-expr-node-pool-state-reset [pool : AstExprNodePoolState]) : AstExprNodePoolState
  (ast-expr-node-pool-state-reset-to pool 0))

(define (ast-expr-node-pool-state-grow [pool : AstExprNodePoolState]) : AstExprNodePoolState
  (let
    [old-slots : (Array AstExpr) (struct-get pool slots)]
    [old-cap : i64 (array-length old-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [base-arena : i64 (struct-get pool base-arena)]
    [prev-arena : i64 (arena-current)]
    [new-slots : (Array AstExpr)
      (begin
        (unsafe
          (arena-set! base-arena))
        (let
          [arr : (Array AstExpr) (make-array AstExpr new-cap)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            arr)))]
    [len : i64 (struct-get pool count)]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! new-slots i (array-ref old-slots i))
          (set! i (+ i 1))))
      (AstExprNodePoolState new-slots len base-arena))))

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
    [slots : (Array AstExpr) (struct-get ready slots)]
    [id : i64 (struct-get ready count)]
    (begin
      (array-set! slots id node)
      (AstExprNodePoolPushOk
        (AstExprNodePoolState slots (+ id 1) (struct-get ready base-arena))
        id))))

(define (ast-expr-node-pool-state-get [pool : AstExprNodePoolState] [id : i64]) : AstExpr
  (array-ref (struct-get pool slots) id))

(define (ast-expr-node-pool-state-set!
  [pool : AstExprNodePoolState]
  [id : i64]
  [node : AstExpr]) : AstExprNodePoolState
  (begin
    (array-set! (struct-get pool slots) id node)
    pool))

(define (ast-node-pool-state-capture) : AstExprNodePoolState
  (AstExprNodePoolState
    ast-node-pool-slots
    ast-node-pool-count
    node-pool-base-arena))

;; --- AstType node pool (flat ty ids) ---
;; AstType's recursive children are stored as i64 ids into this pool instead of
;; (Box AstType), mirroring the AstExpr pool above. The pool is PERSISTENT for a
;; compile (types live for the whole compile, never per-form like the spanned
;; pool); ty-node-pool-reset! clears it between compiles (REPL/LSP). The pool is
;; pre-sized for real inputs and fails closed when exhausted because global array
;; reassignment in this hot path has triggered opt2 miscompiles.
;; #2604: with hash-consed pushes (below) the unique-node count for a cli.tl
;; sized program is a tiny fraction of the former 4M+ duplicated nodes, so the
;; pool starts small; the proven grow path remains as backstop.
(define ty-node-pool-slots : (Array AstType)
  (make-array AstType 262144))
(define ty-node-pool-count : i64
  0)
(define ty-node-pool-exhausted : bool
  false)

;: Current type-node count (also the next ty id ty-node-push will assign).
(define (ty-node-pool-len) : i64
  ty-node-pool-count)

(define (ty-node-pool-capacity) : i64
  (array-length ty-node-pool-slots))

(define (ty-node-pool-exhausted?) : bool
  ty-node-pool-exhausted)

(define (ty-node-pool-exhausted-message) : String
  "compiler: AstType node pool exhausted")

;: Grow the pool's backing array to at least double its current capacity.
;;
;; #2357: restored from feat-aggregate-inline. main fail-closed this pool because
;; the global-array reassignment here had tripped opt2 miscompiles -- but that was
;; with the raw-ptr `ty-node-get` (now `array-ref`, see below) whose in-place alias
;; broke when the backing array was reassigned. With `array-ref` the reassignment
;; is safe (same pattern `ast-node-pool-grow!` already uses), and growing is needed
;; because #1867 inline-aggregate type resolution pushes more nodes (cli.tl/test.tl
;; exceed the old fixed 4M cap). Growing keeps the compile.tl bootstrap at its ~4M
;; footprint (no growth) while letting larger programs proceed.
(define (ty-node-pool-grow!) : unit
  (let
    [old-slots : (Array AstType) ty-node-pool-slots]
    [old-cap : i64 (array-length old-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [prev-arena : i64 (arena-current)]
    [new-slots : (Array AstType)
      (begin
        (unsafe
          (arena-set! node-pool-base-arena))
        (let
          [arr : (Array AstType) (make-array AstType new-cap)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            arr)))]
    [len : i64 ty-node-pool-count]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! new-slots i (array-ref old-slots i))
          (set! i (+ i 1))))
      (set! ty-node-pool-slots new-slots))))

;; #2596: payload copies for stored nodes. The pool array is persistent
;; (#2357) and `ty-node-push` dedup compares later candidates against stored
;; nodes, so a stored node must never embed a String, lifetime spine, or
;; type-list spine allocated in a transient scratch arena (per-function
;; typecheck arenas): after the scratch rewinds, the next dedup probe would
;; compare against freed memory. These helpers run with the node-pool base
;; arena active, so every copy is program-lifetime. Node-id references need
;; no copy: they point at pool nodes made persistent by the same rule.
(define (ty-node-persist-string [s : String]) : String
  (substring s 0 (string-length s)))

(define (ty-node-persist-lifetimes [items : AstLifetimeList]) : AstLifetimeList
  (match items
    [(AstLifetimeNil) AstLifetimeNil]
    [(AstLifetimeCons name rest)
      (AstLifetimeCons
        (ty-node-persist-string name)
        (box (ty-node-persist-lifetimes (box-get rest))))]))

(define (ty-node-persist-type-list [items : AstTypeList]) : AstTypeList
  (match items
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons id rest)
      (AstTypeCons id (box (ty-node-persist-type-list (box-get rest))))]))

(define (ty-node-persist [node : AstType]) : AstType
  (match node
    [(AstTyFunc args ret) (AstTyFunc (ty-node-persist-type-list args) ret)]
    [(AstTyTuple args) (AstTyTuple (ty-node-persist-type-list args))]
    [(AstTyRegion name inner) (AstTyRegion (ty-node-persist-string name) inner)]
    [(AstTyRef name inner) (AstTyRef (ty-node-persist-string name) inner)]
    [(AstTyMutRef name inner) (AstTyMutRef (ty-node-persist-string name) inner)]
    [(AstTyEnumArgs name lifetimes)
      (AstTyEnumArgs name (ty-node-persist-lifetimes lifetimes))]
    [(AstTyStructArgs name lifetimes)
      (AstTyStructArgs name (ty-node-persist-lifetimes lifetimes))]
    [(AstTyVarArgs name lifetimes)
      (AstTyVarArgs name (ty-node-persist-lifetimes lifetimes))]
    [_ node]))

;; State-owned type node pools mirror the global type-node backing store while
;; keeping each worker's ids, reset marks, and hash-consing table independent.
;; The compiler hot path still uses the process-global compatibility wrappers
;; until parser/typechecker/driver state is threaded through every call.
(defstruct AstTypeNodePoolState
  (slots (Array AstType))
  (count i64)
  (base-arena i64)
  (exhausted bool)
  (dedup-slots (Array i64))
  (dedup-count i64))

(defenum AstTypeNodePoolPushResult
  (AstTypeNodePoolPushOk AstTypeNodePoolState i64))

(define (ast-type-node-pool-state-dedup-capacity [capacity : i64]) : i64
  (let
    [want : i64
      (if (< capacity 16)
        16
        capacity)]
    [cap : i64 1]
    (begin
      (while (< cap want)
        (set! cap (* cap 2)))
      cap)))

(define (ast-type-node-pool-state-init [capacity : i64] [base-arena : i64]) : AstTypeNodePoolState
  (let
    [cap : i64 (node-pool-state-normalize-capacity capacity)]
    [dedup-cap : i64 (ast-type-node-pool-state-dedup-capacity cap)]
    [prev-arena : i64 (arena-current)]
    [slots : (Array AstType)
      (begin
        (unsafe
          (arena-set! base-arena))
        (let
          [arr : (Array AstType) (make-array AstType cap)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            arr)))]
    [dedup-slots : (Array i64)
      (begin
        (unsafe
          (arena-set! base-arena))
        (let
          [arr : (Array i64) (make-array i64 dedup-cap)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            arr)))]
    (AstTypeNodePoolState slots 0 base-arena false dedup-slots 0)))

(define (ast-type-node-pool-state-create [capacity : i64]) : AstTypeNodePoolState
  (ast-type-node-pool-state-init capacity (arena-current)))

(define (ast-type-node-pool-state-len [pool : AstTypeNodePoolState]) : i64
  (struct-get pool count))

(define (ast-type-node-pool-state-capacity [pool : AstTypeNodePoolState]) : i64
  (array-length (struct-get pool slots)))

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
        (struct-get pool slots)
        (struct-get pool count)
        (struct-get pool base-arena)
        (struct-get pool exhausted)
        slots
        0))))

(define (ast-type-node-pool-state-reset-to
  [pool : AstTypeNodePoolState]
  [mark : i64]) : AstTypeNodePoolState
  ;; Reset truncates the node prefix. Clear, rather than rebuild, the dedup
  ;; table so no entry can point at an id >= mark; later pushes repopulate it.
  (ast-type-node-pool-state-dedup-clear
    (AstTypeNodePoolState
      (struct-get pool slots)
      mark
      (struct-get pool base-arena)
      false
      (struct-get pool dedup-slots)
      (struct-get pool dedup-count))))

(define (ast-type-node-pool-state-reset-to-mark
  [pool : AstTypeNodePoolState]
  [mark : i64]) : AstTypeNodePoolState
  (ast-type-node-pool-state-reset-to pool mark))

(define (ast-type-node-pool-state-reset [pool : AstTypeNodePoolState]) : AstTypeNodePoolState
  (ast-type-node-pool-state-reset-to pool 0))

(define (ast-type-node-pool-state-grow [pool : AstTypeNodePoolState]) : AstTypeNodePoolState
  (let
    [old-slots : (Array AstType) (struct-get pool slots)]
    [old-cap : i64 (array-length old-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [base-arena : i64 (struct-get pool base-arena)]
    [prev-arena : i64 (arena-current)]
    [new-slots : (Array AstType)
      (begin
        (unsafe
          (arena-set! base-arena))
        (let
          [arr : (Array AstType) (make-array AstType new-cap)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            arr)))]
    [len : i64 (struct-get pool count)]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! new-slots i (array-ref old-slots i))
          (set! i (+ i 1))))
      (AstTypeNodePoolState
        new-slots
        len
        base-arena
        (struct-get pool exhausted)
        (struct-get pool dedup-slots)
        (struct-get pool dedup-count)))))

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
    [slots : (Array AstType) (struct-get ready slots)]
    [id : i64 (struct-get ready count)]
    [base-arena : i64 (struct-get ready base-arena)]
    [prev-arena : i64 (arena-current)]
    [persistent : AstType
      (begin
        (unsafe
          (arena-set! base-arena))
        (let
          [out : AstType (ty-node-persist node)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            out)))]
    (begin
      (array-set! slots id persistent)
      (AstTypeNodePoolPushOk
        (AstTypeNodePoolState
          slots
          (+ id 1)
          base-arena
          (struct-get ready exhausted)
          (struct-get ready dedup-slots)
          (struct-get ready dedup-count))
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
                (struct-get next slots)
                (struct-get next count)
                (struct-get next base-arena)
                (struct-get next exhausted)
                dedup-slots
                (+ dedup-count 1))
              id))])
      (if (ty-node-shallow-value-eq?
        (array-ref (struct-get pool slots) (- slot 1))
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
  (array-ref (struct-get pool slots) id))

(define (ast-type-node-pool-state-set!
  [pool : AstTypeNodePoolState]
  [id : i64]
  [node : AstType]) : AstTypeNodePoolState
  (let
    [prev-arena : i64 (arena-current)]
    [base-arena : i64 (struct-get pool base-arena)]
    [persistent : AstType
      (begin
        (unsafe
          (arena-set! base-arena))
        (let
          [out : AstType (ty-node-persist node)]
          (begin
            (unsafe
              (arena-set! prev-arena))
            out)))]
    (begin
      (array-set! (struct-get pool slots) id persistent)
      ;; Overwriting an existing id can make hash entries stale. Clear the
      ;; private table and let future pushes repopulate it from new candidates.
      (ast-type-node-pool-state-dedup-clear pool))))

;: Append `node` to the pool unconditionally and return its ty id.
(define (ty-node-push-raw [node : AstType]) : i64
  (begin
    (if (>= ty-node-pool-count (array-length ty-node-pool-slots))
      (ty-node-pool-grow!)
      unit)
    (let
      [id : i64 ty-node-pool-count]
      [prev-arena : i64 (arena-current)]
      [persistent : AstType
        (begin
          (unsafe
            (arena-set! node-pool-base-arena))
          (let
            [out : AstType (ty-node-persist node)]
            (begin
              (unsafe
                (arena-set! prev-arena))
              out)))]
      (begin
        (array-set! ty-node-pool-slots id persistent)
        (set! ty-node-pool-count (+ id 1))
        id))))

;; --- ty-node hash-consing (#2604) -------------------------------------------
;; Type nodes are immutable (`ty-node-set!` has no callers) and constructed
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
  1048576)
(define ty-node-dedup-slots : (Array i64)
  (make-array i64 1048576))
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

(define (ty-lifetime-list-hash [items : AstLifetimeList] [seed : i64]) : i64
  (match items
    [(AstLifetimeNil) (hash-combine seed 11)]
    [(AstLifetimeCons name rest)
      (ty-lifetime-list-hash
        (box-get rest)
        (hash-combine seed (hash-string (& name))))]))

(define (ty-type-list-hash [items : AstTypeList] [seed : i64]) : i64
  (match items
    [(AstTypeNil) (hash-combine seed 13)]
    [(AstTypeCons id rest)
      (ty-type-list-hash (box-get rest) (hash-combine seed id))]))

(define (ty-node-hash-value [node : AstType]) : i64
  (match node
    [(AstTyI64) 1]
    [(AstTyI32) 2]
    [(AstTyI16) 3]
    [(AstTyI8) 4]
    [(AstTyU64) 5]
    [(AstTyU32) 6]
    [(AstTyU16) 7]
    [(AstTyU8) 8]
    [(AstTyF64) 9]
    [(AstTyF32) 10]
    [(AstTyBool) 11]
    [(AstTyChar) 12]
    [(AstTyString) 13]
    [(AstTyStr) 14]
    [(AstTyBytes) 35]
    [(AstTyUnit) 15]
    [(AstTyNever) 16]
    [(AstTyExpr) 17]
    [(AstTyExprList) 18]
    [(AstTyFunc args ret) (hash-combine (ty-type-list-hash args 19) ret)]
    [(AstTyTuple elems) (ty-type-list-hash elems 20)]
    [(AstTyArray elem count) (hash-combine (hash-combine 21 elem) count)]
    [(AstTyDynArray elem) (hash-combine 22 elem)]
    [(AstTyBox inner) (hash-combine 23 inner)]
    [(AstTyRegion name inner)
      (hash-combine (hash-combine 24 (hash-string (& name))) inner)]
    [(AstTyRef name inner)
      (hash-combine (hash-combine 25 (hash-string (& name))) inner)]
    [(AstTyMutRef name inner)
      (hash-combine (hash-combine 26 (hash-string (& name))) inner)]
    [(AstTyEnum name) (hash-combine 27 name)]
    [(AstTyEnumArgs name lifetimes)
      (ty-lifetime-list-hash lifetimes (hash-combine 28 name))]
    [(AstTyStruct name) (hash-combine 29 name)]
    [(AstTyStructArgs name lifetimes)
      (ty-lifetime-list-hash lifetimes (hash-combine 30 name))]
    [(AstTyVar name) (hash-combine 31 name)]
    [(AstTyVarArgs name lifetimes)
      (ty-lifetime-list-hash lifetimes (hash-combine 32 name))]
    [(AstTyPtr inner) (hash-combine 33 inner)]
    [(AstTyMutPtr inner) (hash-combine 34 inner)]))

(define (ty-lifetime-list-eq? [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (match a
    [(AstLifetimeNil)
      (match b
        [(AstLifetimeNil) true]
        [_ false])]
    [(AstLifetimeCons a-name a-rest)
      (match b
        [(AstLifetimeCons b-name b-rest)
          (and
            (string-eq a-name b-name)
            (ty-lifetime-list-eq? (box-get a-rest) (box-get b-rest)))]
        [_ false])]))

(define (ty-type-list-eq? [a : AstTypeList] [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
      (match b
        [(AstTypeNil) true]
        [_ false])]
    [(AstTypeCons a-id a-rest)
      (match b
        [(AstTypeCons b-id b-rest)
          (and
            (= a-id b-id)
            (ty-type-list-eq? (box-get a-rest) (box-get b-rest)))]
        [_ false])]))

;; Shallow structural equality between a stored node and a candidate node. Child
;; ids compare as plain integers because children are themselves deduplicated.
(define (ty-node-shallow-value-eq? [a : AstType] [b : AstType]) : bool
  (match a
    [(AstTyI64)
      (match b
        [(AstTyI64) true]
        [_ false])]
    [(AstTyI32)
      (match b
        [(AstTyI32) true]
        [_ false])]
    [(AstTyI16)
      (match b
        [(AstTyI16) true]
        [_ false])]
    [(AstTyI8)
      (match b
        [(AstTyI8) true]
        [_ false])]
    [(AstTyU64)
      (match b
        [(AstTyU64) true]
        [_ false])]
    [(AstTyU32)
      (match b
        [(AstTyU32) true]
        [_ false])]
    [(AstTyU16)
      (match b
        [(AstTyU16) true]
        [_ false])]
    [(AstTyU8)
      (match b
        [(AstTyU8) true]
        [_ false])]
    [(AstTyF64)
      (match b
        [(AstTyF64) true]
        [_ false])]
    [(AstTyF32)
      (match b
        [(AstTyF32) true]
        [_ false])]
    [(AstTyBool)
      (match b
        [(AstTyBool) true]
        [_ false])]
    [(AstTyChar)
      (match b
        [(AstTyChar) true]
        [_ false])]
    [(AstTyString)
      (match b
        [(AstTyString) true]
        [_ false])]
    [(AstTyStr)
      (match b
        [(AstTyStr) true]
        [_ false])]
    [(AstTyBytes)
      (match b
        [(AstTyBytes) true]
        [_ false])]
    [(AstTyUnit)
      (match b
        [(AstTyUnit) true]
        [_ false])]
    [(AstTyNever)
      (match b
        [(AstTyNever) true]
        [_ false])]
    [(AstTyExpr)
      (match b
        [(AstTyExpr) true]
        [_ false])]
    [(AstTyExprList)
      (match b
        [(AstTyExprList) true]
        [_ false])]
    [(AstTyFunc a-args a-ret)
      (match b
        [(AstTyFunc b-args b-ret)
          (and (= a-ret b-ret) (ty-type-list-eq? a-args b-args))]
        [_ false])]
    [(AstTyTuple a-elems)
      (match b
        [(AstTyTuple b-elems) (ty-type-list-eq? a-elems b-elems)]
        [_ false])]
    [(AstTyArray a-elem a-count)
      (match b
        [(AstTyArray b-elem b-count)
          (and (= a-elem b-elem) (= a-count b-count))]
        [_ false])]
    [(AstTyDynArray a-elem)
      (match b
        [(AstTyDynArray b-elem) (= a-elem b-elem)]
        [_ false])]
    [(AstTyBox a-inner)
      (match b
        [(AstTyBox b-inner) (= a-inner b-inner)]
        [_ false])]
    [(AstTyRegion a-name a-inner)
      (match b
        [(AstTyRegion b-name b-inner)
          (and (= a-inner b-inner) (string-eq a-name b-name))]
        [_ false])]
    [(AstTyRef a-name a-inner)
      (match b
        [(AstTyRef b-name b-inner)
          (and (= a-inner b-inner) (string-eq a-name b-name))]
        [_ false])]
    [(AstTyMutRef a-name a-inner)
      (match b
        [(AstTyMutRef b-name b-inner)
          (and (= a-inner b-inner) (string-eq a-name b-name))]
        [_ false])]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyEnumArgs a-name a-lifetimes)
      (match b
        [(AstTyEnumArgs b-name b-lifetimes)
          (and (= a-name b-name) (ty-lifetime-list-eq? a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyStructArgs a-name a-lifetimes)
      (match b
        [(AstTyStructArgs b-name b-lifetimes)
          (and (= a-name b-name) (ty-lifetime-list-eq? a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyVarArgs a-name a-lifetimes)
      (match b
        [(AstTyVarArgs b-name b-lifetimes)
          (and (= a-name b-name) (ty-lifetime-list-eq? a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyPtr a-inner)
      (match b
        [(AstTyPtr b-inner) (= a-inner b-inner)]
        [_ false])]
    [(AstTyMutPtr a-inner)
      (match b
        [(AstTyMutPtr b-inner) (= a-inner b-inner)]
        [_ false])]))

(define (ty-node-shallow-eq? [a-id : i64] [b : AstType]) : bool
  (ty-node-shallow-value-eq? (ty-node-get a-id) b))

(define (ast-type-node-pool-state-shallow-eq?
  [pool : AstTypeNodePoolState]
  [a-id : i64]
  [b : AstType]) : bool
  (ty-node-shallow-value-eq? (ast-type-node-pool-state-get pool a-id) b))

;: Append `node` to the pool, returning an existing id when an identical node
;: was already pushed. The table is probed before appending so the common
;: duplicate path does not churn the pool count or temporarily force growth.
(define (ty-node-push [node : AstType]) : i64
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

;: Read the type node at `id`.
;;
;; #2357: MUST stay `array-ref` (see `ast-node-get`): with #1867 inline-by-value
;; `AstType` is a multi-word value, and the raw ptr-offset/ptr-read path mis-scales
;; the element stride and reads garbage. `array-ref` lowers with the right size.
(define (ty-node-get [id : i64]) : AstType
  (array-ref ty-node-pool-slots id))

;: Overwrite the type node at `id` in place.
(define (ty-node-set! [id : i64] [node : AstType]) : unit
  (array-set! ty-node-pool-slots id node))

;: Truncate the pool back to `mark` nodes (discard from a failed parse).
;; Dedup entries above `mark` would dangle, so the table is cleared; truncation
;; happens at most a few times per compile (parse rollback, per-compile reset).
(define (ty-node-pool-truncate! [mark : i64]) : unit
  (begin
    (set! ty-node-pool-count mark)
    (ty-node-dedup-clear!)))

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
    ty-node-pool-slots
    ty-node-pool-count
    node-pool-base-arena
    ty-node-pool-exhausted
    ty-node-dedup-slots
    ty-node-dedup-count))

(define (ast-node-pools-state-install!
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]) : unit
  (begin
    (set! ast-node-pool-slots (struct-get expr-pool slots))
    (set! ast-node-pool-count (struct-get expr-pool count))
    (set! ty-node-pool-slots (struct-get type-pool slots))
    (set! ty-node-pool-count (struct-get type-pool count))
    (set! ty-node-pool-exhausted (struct-get type-pool exhausted))
    (set!
      ty-node-dedup-capacity
      (array-length (struct-get type-pool dedup-slots)))
    (set! ty-node-dedup-slots (struct-get type-pool dedup-slots))
    (set! ty-node-dedup-count (struct-get type-pool dedup-count))
    ;; Driver-created states allocate both pools in one persistent arena. Keep
    ;; the shared compatibility grow/persist target there after both installs.
    (set! node-pool-base-arena (struct-get expr-pool base-arena))))

(defenum AstExprList
  (AstExprNil)
  (AstExprCons i64 (Box AstExprList)))

(defstruct AstExprClause
  (first i64)
  (second i64))

(defenum AstExprClauseList
  (AstExprClauseNil)
  (AstExprClauseCons AstExprClause (Box AstExprClauseList)))

(defenum AstMaybeModuleName
  (AstNoModuleName)
  (AstSomeModuleName String))

(defenum AstMaybeImportAlias
  (AstNoImportAlias)
  (AstSomeImportAlias String))

(defenum AstImportKind
  (AstImportPath)
  (AstImportModule)
  (AstImportMacro i64)
  (AstImportMacroDecls i64))

(defenum AstImportSpec
  (AstImportSpec
    AstImportKind
    String
    AstMaybeModuleName
    AstMaybeImportAlias
    AstSourceSpan))

(defenum AstExportItem
  (AstExportValue String)
  (AstExportType String)
  (AstExportMacro String)
  (AstExportConstructor String)
  (AstExportField String String)
  (AstExportVariant String))

(defenum AstExportItemList
  (AstExportItemNil)
  (AstExportItemCons AstExportItem (Box AstExportItemList)))

(defenum AstDispatchIsa
  (AstDispatchScalar)
  (AstDispatchAvx2)
  (AstDispatchAvx512))

(defenum AstDispatchVariant
  (AstDispatchVariant AstDispatchIsa String))

(defenum AstDispatchVariantList
  (AstDispatchVariantNil)
  (AstDispatchVariantCons AstDispatchVariant (Box AstDispatchVariantList)))

(defenum AstGeneratedDeclMeta
  (AstNoGeneratedDeclMeta)
  (AstSomeGeneratedDeclMeta String String AstExprList String))

(defenum AstDecl
  (AstDeclModule i64)
  (AstDeclDef i64 AstMaybeType i64)
  (AstDeclDefFn i64 AstParamList AstType i64 AstFnExport)
  (AstDeclDefMacro i64 AstMacroParamList AstType i64)
  (AstDeclExtern i64 AstExternKind AstExternMetadata AstType)
  (AstDeclDefEnum i64 AstEnumCleanup AstVariantDefList)
  (AstDeclDefEnumLifetimes i64 AstLifetimeList AstEnumCleanup AstVariantDefList)
  (AstDeclDefStruct i64 AstStructRepr AstStructCleanup AstFieldDefList)
  (AstDeclDefStructLifetimes
    i64
    AstLifetimeList
    AstStructRepr
    AstStructCleanup
    AstFieldDefList)
  (AstDeclImport AstImportSpec)
  (AstDeclIncludeStr String String)
  (AstDeclIncludeBin String String)
  (AstDeclExport AstExportItemList)
  (AstDeclDefDispatch i64 AstDispatchVariantList)
  (AstDeclTest i64 i64 AstSourceSpan)
  (AstDeclUnsafe (Box AstDecl))
  (AstDeclComptimeDecl AstGeneratedDeclMeta (Box AstDecl)))

(defenum AstDeclList
  (AstDeclNil)
  (AstDeclCons AstDecl (Box AstDeclList)))

(defenum AstDeclPathList
  (AstDeclPathNil)
  (AstDeclPathCons String (Box AstDeclPathList)))

(defenum AstDeclModuleList
  (AstDeclModuleNil)
  (AstDeclModuleCons String (Box AstDeclModuleList)))

(defenum AstProgram
  (AstProgram (Box AstDeclList)))

(define (ast-type-cons [head : AstType] [rest : AstTypeList]) : AstTypeList
  (AstTypeCons (ty-node-push head) (box rest)))

(define (ast-ty-func [args : AstTypeList] [ret : AstType]) : AstType
  (AstTyFunc args (ty-node-push ret)))

(define (ast-ty-array [elem : AstType] [count : i64]) : AstType
  (AstTyArray (ty-node-push elem) count))

(define (ast-ty-dyn-array [elem : AstType]) : AstType
  (AstTyDynArray (ty-node-push elem)))

(define (ast-ty-box [elem : AstType]) : AstType
  (AstTyBox (ty-node-push elem)))

(define (ast-ty-region [region : String] [inner : AstType]) : AstType
  (AstTyRegion region (ty-node-push inner)))

(define (ast-ty-ref [region : String] [inner : AstType]) : AstType
  (AstTyRef region (ty-node-push inner)))

(define (ast-ty-mut-ref [region : String] [inner : AstType]) : AstType
  (AstTyMutRef region (ty-node-push inner)))

(define (ast-ty-ptr [elem : AstType]) : AstType
  (AstTyPtr (ty-node-push elem)))

(define (ast-ty-mut-ptr [elem : AstType]) : AstType
  (AstTyMutPtr (ty-node-push elem)))

(define (ast-lifetime-cons [head : String] [rest : AstLifetimeList]) : AstLifetimeList
  (AstLifetimeCons head (box rest)))

(define (ast-param [name : String] [ty : AstType] [is-comptime : bool]) : AstParam
  (AstParam (intern name) ty is-comptime))

(define (ast-param-id [name : i64] [ty : AstType] [is-comptime : bool]) : AstParam
  (AstParam name ty is-comptime))

(define (ast-param-cons [head : AstParam] [rest : AstParamList]) : AstParamList
  (AstParamCons head (box rest)))

(define (ast-macro-param [name : String] [ty : AstType] [variadic : bool]) : AstMacroParam
  (AstMacroParam (intern name) ty variadic))

(define (ast-macro-param-id [name : i64] [ty : AstType] [variadic : bool]) : AstMacroParam
  (AstMacroParam name ty variadic))

(define (ast-macro-param-cons [head : AstMacroParam] [rest : AstMacroParamList]) : AstMacroParamList
  (AstMacroParamCons head (box rest)))

(define (ast-field-cleanup-fn [name : String]) : AstFieldCleanup
  (AstFieldCleanupFn (intern name)))

(define (ast-field-cleanup-fn-id [name : i64]) : AstFieldCleanup
  (AstFieldCleanupFn name))

(define (ast-field-def
  [name : String]
  [ty : AstType]
  [cleanup : AstFieldCleanup]) : AstFieldDef
  (AstFieldDef (intern name) ty cleanup))

(define (ast-field-def-id
  [name : i64]
  [ty : AstType]
  [cleanup : AstFieldCleanup]) : AstFieldDef
  (AstFieldDef name ty cleanup))

(define (ast-field-def-cons [head : AstFieldDef] [rest : AstFieldDefList]) : AstFieldDefList
  (AstFieldDefCons head (box rest)))

(define (ast-extern-link-input-cons
  [head : AstExternLinkInput]
  [rest : AstExternLinkInputList]) : AstExternLinkInputList
  (AstExternLinkInputCons head (box rest)))

(define (ast-fn-export [name : String]) : AstFnExport
  (AstFnExport (intern name)))

(define (ast-fn-export-id [name : i64]) : AstFnExport
  (AstFnExport name))

(define (ast-struct-cleanup-fn [name : String]) : AstStructCleanup
  (AstStructCleanupFn (intern name)))

(define (ast-struct-cleanup-fn-id [name : i64]) : AstStructCleanup
  (AstStructCleanupFn name))

(define (ast-enum-cleanup-fn [name : String]) : AstEnumCleanup
  (AstEnumCleanupFn (intern name)))

(define (ast-enum-cleanup-fn-id [name : i64]) : AstEnumCleanup
  (AstEnumCleanupFn name))

(define (ast-variant-payload-cleanup-fn [name : String]) : AstVariantPayloadCleanup
  (AstVariantPayloadCleanupFn (intern name)))

(define (ast-variant-payload-cleanup-fn-id [name : i64]) : AstVariantPayloadCleanup
  (AstVariantPayloadCleanupFn name))

(define (ast-variant-def
  [name : String]
  [fields : AstTypeList]
  [cleanups : AstVariantPayloadCleanupList]) : AstVariantDef
  (AstVariantDef (intern name) fields cleanups))

(define (ast-variant-def-id
  [name : i64]
  [fields : AstTypeList]
  [cleanups : AstVariantPayloadCleanupList]) : AstVariantDef
  (AstVariantDef name fields cleanups))

(define (ast-variant-def-cons [head : AstVariantDef] [rest : AstVariantDefList]) : AstVariantDefList
  (AstVariantDefCons head (box rest)))

(define (ast-variant-payload-cleanup-cons
  [head : AstVariantPayloadCleanup]
  [rest : AstVariantPayloadCleanupList]) : AstVariantPayloadCleanupList
  (AstVariantPayloadCleanupCons head (box rest)))

(define (ast-pattern-cons [head : AstPattern] [rest : AstPatternList]) : AstPatternList
  (AstPatternCons (box head) (box rest)))

(define (ast-pat-binding [name : String]) : AstPattern
  (AstPatBinding (intern name)))

(define (ast-pat-binding-id [name : i64]) : AstPattern
  (AstPatBinding name))

(define (ast-pat-tuple [items : AstPatternList]) : AstPattern
  (AstPatTuple (box items)))

(define (ast-pat-variant [name : String] [items : AstPatternList]) : AstPattern
  (AstPatVariant (intern name) (box items)))

(define (ast-pat-variant-id [name : i64] [items : AstPatternList]) : AstPattern
  (AstPatVariant name (box items)))

(define (ast-let-binding
  [name : String]
  [maybe-ty : AstMaybeType]
  [value : i64]) : AstLetBinding
  (AstLetBinding (intern name) maybe-ty value))

(define (ast-let-binding-id
  [name : i64]
  [maybe-ty : AstMaybeType]
  [value : i64]) : AstLetBinding
  (AstLetBinding name maybe-ty value))

(define (ast-let-binding-cons [head : AstLetBinding] [rest : AstLetBindingList]) : AstLetBindingList
  (AstLetBindingCons head (box rest)))

(define (ast-resource-binding [name : String] [init : i64] [cleanup : i64]) : AstResourceBinding
  (AstResourceBinding (intern name) init cleanup))

(define (ast-resource-binding-id [name : i64] [init : i64] [cleanup : i64]) : AstResourceBinding
  (AstResourceBinding name init cleanup))

(define (ast-resource-binding-cons
  [head : AstResourceBinding]
  [rest : AstResourceBindingList]) : AstResourceBindingList
  (AstResourceBindingCons head (box rest)))

(define (ast-match-arm [pattern : AstPattern] [body : i64]) : AstMatchArm
  (AstMatchArm pattern body))

(define (ast-match-arm-cons [head : AstMatchArm] [rest : AstMatchArmList]) : AstMatchArmList
  (AstMatchArmCons head (box rest)))

(define (ast-expr-cons [head : i64] [rest : AstExprList]) : AstExprList
  (AstExprCons head (box rest)))

(define (ast-expr-clause [first : i64] [second : i64]) : AstExprClause
  (AstExprClause first second))

(define (ast-expr-clause-cons [head : AstExprClause] [rest : AstExprClauseList]) : AstExprClauseList
  (AstExprClauseCons head (box rest)))

(define (ast-expr-spanned [inner : i64] [span : AstSourceSpan]) : i64
  (ast-node-push (AstExprSpanned inner span)))

(define (ast-expr-binary [op : AstBinOp] [left : i64] [right : i64]) : i64
  (ast-node-push (AstExprBinary op left right)))

(define (ast-expr-unary [op : AstUnOp] [inner : i64]) : i64
  (ast-node-push (AstExprUnary op inner)))

(define (ast-expr-call [callee : i64] [args : AstExprList]) : i64
  (ast-node-push (AstExprCall callee args)))

(define (ast-expr-bracket-clause [items : AstExprList]) : i64
  (ast-node-push (AstExprBracketClause items)))

(define (ast-expr-if [cond : i64] [then-expr : i64] [else-expr : i64]) : i64
  (ast-node-push (AstExprIf cond then-expr else-expr)))

(define (ast-expr-let [bindings : AstLetBindingList] [body : i64]) : i64
  (ast-node-push (AstExprLet bindings body)))

(define (ast-expr-lambda
  [params : AstParamList]
  [ret : AstMaybeType]
  [body : i64]) : i64
  (ast-node-push (AstExprLambda (box (AstLambda params ret body)))))

(define (ast-expr-tuple-ref [target : i64] [index : i64]) : i64
  (ast-node-push (AstExprTupleRef target index)))

(define (ast-expr-make-array [elem : AstType] [size : i64]) : i64
  (ast-node-push (AstExprMakeArray elem size)))

(define (ast-expr-array-ref [target : i64] [index : i64]) : i64
  (ast-node-push (AstExprArrayRef target index)))

(define (ast-expr-array-set [target : i64] [index : i64] [value : i64]) : i64
  (ast-node-push (AstExprArraySet target index value)))

(define (ast-expr-array-push [target : i64] [value : i64]) : i64
  (ast-node-push (AstExprArrayPush target value)))

(define (ast-expr-string-ref [target : i64] [index : i64]) : i64
  (ast-node-push (AstExprStringRef target index)))

(define (ast-expr-while [cond : i64] [body : i64]) : i64
  (ast-node-push (AstExprWhile cond body)))

(define (ast-expr-set [name : String] [value : i64]) : i64
  (ast-node-push (AstExprSet (intern name) value)))

(define (ast-expr-set-id [name : i64] [value : i64]) : i64
  (ast-node-push (AstExprSet name value)))

(define (ast-expr-ann [expr : i64] [ty : AstType]) : i64
  (ast-node-push (AstExprAnn expr ty)))

(define (ast-expr-cast [expr : i64] [ty : AstType]) : i64
  (ast-node-push (AstExprCast expr ty)))

(define (ast-expr-borrow
  [mutable : bool]
  [lifetime : AstBorrowLifetime]
  [expr : i64]) : i64
  (ast-node-push (AstExprBorrow mutable lifetime expr)))

(define (ast-expr-match [scrutinee : i64] [arms : AstMatchArmList]) : i64
  (ast-node-push (AstExprMatch (box (AstMatch scrutinee arms)))))

(define (ast-expr-foreach
  [name : String]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [body : i64]) : i64
  (ast-node-push (AstExprForeach (intern name) index-ty start end body)))

(define (ast-expr-foreach-id
  [name : i64]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [body : i64]) : i64
  (ast-node-push (AstExprForeach name index-ty start end body)))

(define (ast-expr-spmd-reduce
  [op : AstReduceOp]
  [name : String]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [init : i64]
  [value : i64]) : i64
  (ast-node-push
    (AstExprSpmdReduce op (intern name) index-ty start end init value)))

(define (ast-expr-spmd-reduce-id
  [op : AstReduceOp]
  [name : i64]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [init : i64]
  [value : i64]) : i64
  (ast-node-push (AstExprSpmdReduce op name index-ty start end init value)))

(define (ast-expr-spmd-scan
  [op : AstReduceOp]
  [index : String]
  [index-ty : AstType]
  [start : i64]
  [end : i64]
  [prefix : String]
  [prefix-ty : AstType]
  [init : i64]
  [value : i64]
  [body : i64]) : i64
  (ast-node-push
    (AstExprSpmdScan
      (box
        (AstSpmdScan
          op
          (intern index)
          index-ty
          start
          end
          (intern prefix)
          prefix-ty
          init
          value
          body)))))

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
    (AstExprSpmdScan
      (box
        (AstSpmdScan
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
  (ast-node-push (AstExprSpmdBroadcast value lane)))

(define (ast-expr-struct-get [target : i64] [field : String]) : i64
  (ast-node-push (AstExprStructGet target (intern field))))

(define (ast-expr-struct-get-id [target : i64] [field : i64]) : i64
  (ast-node-push (AstExprStructGet target field)))

(define (ast-expr-struct-set [target : i64] [field : String] [value : i64]) : i64
  (ast-node-push (AstExprStructSet target (intern field) value)))

(define (ast-expr-struct-set-id [target : i64] [field : i64] [value : i64]) : i64
  (ast-node-push (AstExprStructSet target field value)))

(define (ast-expr-with-escape [escape : i64] [body : AstExprList]) : i64
  (ast-node-push (AstExprWithEscape escape body)))

(define (ast-expr-with-scratch [body : AstExprList]) : i64
  (ast-node-push (AstExprWithScratch body)))

(define (ast-expr-in-arena [arena : i64] [body : AstExprList]) : i64
  (ast-node-push (AstExprInArena arena body)))

(define (ast-expr-box [value : i64]) : i64
  (ast-node-push (AstExprBox value)))

(define (ast-expr-box-get [value : i64]) : i64
  (ast-node-push (AstExprBoxGet value)))

(define (ast-expr-box-take [value : i64]) : i64
  (ast-node-push (AstExprBoxTake value)))

(define (ast-expr-box-set [target : i64] [value : i64]) : i64
  (ast-node-push (AstExprBoxSet target value)))

(define (ast-expr-init-maybe [maybe-ty : AstMaybeType]) : i64
  (ast-node-push (AstExprInit maybe-ty)))

(define (ast-expr-init [ty : AstType]) : i64
  (ast-expr-init-maybe (AstSomeType ty)))

(define (ast-expr-init-contextual) : i64
  (ast-expr-init-maybe AstNoType))

(define (ast-expr-comptime [inner : i64]) : i64
  (ast-node-push (AstExprComptime inner)))

(define (ast-expr-quote [inner : i64]) : i64
  (ast-node-push (AstExprQuote inner)))

(define (ast-expr-quasiquote [inner : i64]) : i64
  (ast-node-push (AstExprQuasiquote inner)))

(define (ast-expr-unquote [inner : i64]) : i64
  (ast-node-push (AstExprUnquote inner)))

(define (ast-expr-unquote-splicing [inner : i64]) : i64
  (ast-node-push (AstExprUnquoteSplicing inner)))

(define (ast-expr-try [inner : i64]) : i64
  (ast-node-push (AstExprTry inner)))

(define (ast-expr-return [inner : i64]) : i64
  (ast-node-push (AstExprReturn inner)))

(define (ast-expr-ptr-null-check [ptr : i64]) : i64
  (ast-node-push (AstExprPtrNullCheck ptr)))

(define (ast-expr-ptr-addr-of [name : String]) : i64
  (ast-node-push (AstExprPtrAddrOf (intern name))))

(define (ast-expr-ptr-addr-of-id [name : i64]) : i64
  (ast-node-push (AstExprPtrAddrOf name)))

(define (ast-expr-ptr-read [ptr : i64]) : i64
  (ast-node-push (AstExprPtrRead ptr)))

(define (ast-expr-ptr-write [ptr : i64] [value : i64]) : i64
  (ast-node-push (AstExprPtrWrite ptr value)))

(define (ast-expr-ptr-offset [ptr : i64] [offset : i64]) : i64
  (ast-node-push (AstExprPtrOffset ptr offset)))

(define (ast-expr-ptr-cast [ptr : i64] [ty : AstType]) : i64
  (ast-node-push (AstExprPtrCast ptr ty)))

(define (ast-expr-ptr-to-int [ptr : i64]) : i64
  (ast-node-push (AstExprPtrToInt ptr)))

(define (ast-expr-int-to-ptr [value : i64] [ty : AstType]) : i64
  (ast-node-push (AstExprIntToPtr value ty)))

(define (ast-expr-string-data [value : i64]) : i64
  (ast-node-push (AstExprStringData value)))

(define (ast-expr-string-from-bytes [data : i64] [len : i64]) : i64
  (ast-node-push (AstExprStringFromBytes data len)))

(define (ast-expr-array-data [value : i64]) : i64
  (ast-node-push (AstExprArrayData value)))

(define (ast-expr-cpuid-eax [leaf : i64] [subleaf : i64]) : i64
  (ast-node-push (AstExprCpuIdEax leaf subleaf)))

(define (ast-expr-cpuid-ebx [leaf : i64] [subleaf : i64]) : i64
  (ast-node-push (AstExprCpuIdEbx leaf subleaf)))

(define (ast-expr-cpuid-ecx [leaf : i64] [subleaf : i64]) : i64
  (ast-node-push (AstExprCpuIdEcx leaf subleaf)))

(define (ast-expr-cpuid-edx [leaf : i64] [subleaf : i64]) : i64
  (ast-node-push (AstExprCpuIdEdx leaf subleaf)))

(define (ast-expr-xgetbv [index : i64]) : i64
  (ast-node-push (AstExprXgetbv index)))

(define (ast-expr-syscall [args : AstExprList]) : i64
  (ast-node-push (AstExprSyscall args)))

(define (ast-export-item-cons [head : AstExportItem] [rest : AstExportItemList]) : AstExportItemList
  (AstExportItemCons head (box rest)))

(define (ast-dispatch-variant-cons
  [head : AstDispatchVariant]
  [rest : AstDispatchVariantList]) : AstDispatchVariantList
  (AstDispatchVariantCons head (box rest)))

(define (ast-decl-cons [head : AstDecl] [rest : AstDeclList]) : AstDeclList
  (AstDeclCons head (box rest)))

(define (ast-decl-module [name : String]) : AstDecl
  (AstDeclModule (intern name)))

(define (ast-decl-module-id [name : i64]) : AstDecl
  (AstDeclModule name))

(define (ast-decl-def [name : String] [maybe-ty : AstMaybeType] [value : i64]) : AstDecl
  (AstDeclDef (intern name) maybe-ty value))

(define (ast-decl-def-id [name : i64] [maybe-ty : AstMaybeType] [value : i64]) : AstDecl
  (AstDeclDef name maybe-ty value))

(define (ast-decl-def-fn
  [name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]) : AstDecl
  (AstDeclDefFn (intern name) params ret body AstFnNoExport))

(define (ast-decl-def-fn-id
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]) : AstDecl
  (AstDeclDefFn name params ret body AstFnNoExport))

(define (ast-decl-def-fn-export
  [name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [export : AstFnExport]) : AstDecl
  (AstDeclDefFn (intern name) params ret body export))

(define (ast-decl-def-fn-export-id
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [export : AstFnExport]) : AstDecl
  (AstDeclDefFn name params ret body export))

(define (ast-decl-def-macro
  [name : String]
  [params : AstMacroParamList]
  [ret : AstType]
  [body : i64]) : AstDecl
  (AstDeclDefMacro (intern name) params ret body))

(define (ast-decl-def-macro-id
  [name : i64]
  [params : AstMacroParamList]
  [ret : AstType]
  [body : i64]) : AstDecl
  (AstDeclDefMacro name params ret body))

(define (ast-decl-extern
  [name : String]
  [kind : AstExternKind]
  [metadata : AstExternMetadata]
  [ty : AstType]) : AstDecl
  (AstDeclExtern (intern name) kind metadata ty))

(define (ast-decl-extern-id
  [name : i64]
  [kind : AstExternKind]
  [metadata : AstExternMetadata]
  [ty : AstType]) : AstDecl
  (AstDeclExtern name kind metadata ty))

(define (ast-decl-def-enum
  [name : String]
  [cleanup : AstEnumCleanup]
  [variants : AstVariantDefList]) : AstDecl
  (AstDeclDefEnum (intern name) cleanup variants))

(define (ast-decl-def-enum-id
  [name : i64]
  [cleanup : AstEnumCleanup]
  [variants : AstVariantDefList]) : AstDecl
  (AstDeclDefEnum name cleanup variants))

(define (ast-decl-def-enum-lifetimes
  [name : String]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [variants : AstVariantDefList]) : AstDecl
  (AstDeclDefEnumLifetimes (intern name) lifetimes cleanup variants))

(define (ast-decl-def-enum-lifetimes-id
  [name : i64]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [variants : AstVariantDefList]) : AstDecl
  (AstDeclDefEnumLifetimes name lifetimes cleanup variants))

(define (ast-decl-def-struct
  [name : String]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : AstDecl
  (AstDeclDefStruct (intern name) repr cleanup fields))

(define (ast-decl-def-struct-id
  [name : i64]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : AstDecl
  (AstDeclDefStruct name repr cleanup fields))

(define (ast-decl-def-struct-lifetimes
  [name : String]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : AstDecl
  (AstDeclDefStructLifetimes (intern name) lifetimes repr cleanup fields))

(define (ast-decl-def-struct-lifetimes-id
  [name : i64]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : AstDecl
  (AstDeclDefStructLifetimes name lifetimes repr cleanup fields))

(define (ast-decl-def-dispatch
  [name : String]
  [variants : AstDispatchVariantList]) : AstDecl
  (AstDeclDefDispatch (intern name) variants))

(define (ast-decl-def-dispatch-id
  [name : i64]
  [variants : AstDispatchVariantList]) : AstDecl
  (AstDeclDefDispatch name variants))

(define (ast-decl-test [name : String] [body : i64] [span : AstSourceSpan]) : AstDecl
  (AstDeclTest (intern name) body span))

(define (ast-decl-test-id [name : i64] [body : i64] [span : AstSourceSpan]) : AstDecl
  (AstDeclTest name body span))

(define (ast-decl-unsafe [inner : AstDecl]) : AstDecl
  (AstDeclUnsafe (box inner)))

(define (ast-decl-comptime-decl [inner : AstDecl]) : AstDecl
  (AstDeclComptimeDecl AstNoGeneratedDeclMeta (box inner)))

(define (ast-decl-comptime-decl-with-meta
  [meta : AstGeneratedDeclMeta]
  [inner : AstDecl]) : AstDecl
  (AstDeclComptimeDecl meta (box inner)))

(define (ast-decl-path-cons [head : String] [rest : AstDeclPathList]) : AstDeclPathList
  (AstDeclPathCons head (box rest)))

(define (ast-decl-module-cons [head : String] [rest : AstDeclModuleList]) : AstDeclModuleList
  (AstDeclModuleCons head (box rest)))

(define (ast-program [decls : AstDeclList]) : AstProgram
  (AstProgram (box decls)))

(define (ast-type-tag [ty : AstType]) : i64
  (match ty
    [(AstTyI64) 1]
    [(AstTyI32) 2]
    [(AstTyI16) 3]
    [(AstTyI8) 4]
    [(AstTyU64) 5]
    [(AstTyU32) 6]
    [(AstTyU16) 7]
    [(AstTyU8) 8]
    [(AstTyF64) 9]
    [(AstTyF32) 10]
    [(AstTyBool) 11]
    [(AstTyChar) 12]
    [(AstTyString) 13]
    [(AstTyStr) 30]
    [(AstTyBytes) 35]
    [(AstTyUnit) 14]
    [(AstTyNever) 15]
    [(AstTyExpr) 16]
    [(AstTyExprList) 29]
    [(AstTyFunc _ _) 17]
    [(AstTyTuple _) 18]
    [(AstTyArray _ _) 19]
    [(AstTyDynArray _) 20]
    [(AstTyRegion _ _) 21]
    [(AstTyRef _ _) 22]
    [(AstTyMutRef _ _) 23]
    [(AstTyEnum _) 24]
    [(AstTyStruct _) 25]
    [(AstTyVar _) 26]
    [(AstTyPtr _) 27]
    [(AstTyMutPtr _) 28]
    [(AstTyBox _) 31]
    [(AstTyEnumArgs _ _) 32]
    [(AstTyStructArgs _ _) 33]
    [(AstTyVarArgs _ _) 34]))

(define (ast-expr-tag [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned _ _) 1]
    [(AstExprLiteral _) 2]
    [(AstExprVar _) 3]
    [(AstExprBinary _ _ _) 4]
    [(AstExprUnary _ _) 5]
    [(AstExprCall _ _) 6]
    [(AstExprIf _ _ _) 7]
    [(AstExprLet _ _) 8]
    [(AstExprLambda _) 9]
    [(AstExprTuple _) 10]
    [(AstExprTupleRef _ _) 11]
    [(AstExprArray _) 12]
    [(AstExprMakeArray _ _) 13]
    [(AstExprArrayRef _ _) 14]
    [(AstExprArraySet _ _ _) 15]
    [(AstExprArrayPush _ _) 41]
    [(AstExprStringRef _ _) 16]
    [(AstExprWhile _ _) 17]
    [(AstExprBegin _) 18]
    [(AstExprUnsafe _) 32]
    [(AstExprSet _ _) 19]
    [(AstExprAnn _ _) 20]
    [(AstExprCast _ _) 21]
    [(AstExprBorrow _ _ _) 40]
    [(AstExprMatch _) 22]
    [(AstExprForeach _ _ _ _ _) 23]
    [(AstExprStructGet _ _) 24]
    [(AstExprStructSet _ _ _) 63]
    [(AstExprWithRegion _ _) 25]
    [(AstExprWithEscape _ _) 48]
    [(AstExprWithScratch _) 67]
    [(AstExprInArena _ _) 65]
    [(AstExprTypeLiteral _) 26]
    [(AstExprInit _) 61]
    [(AstExprComptime _) 27]
    [(AstExprSpmdReduce _ _ _ _ _ _ _) 28]
    [(AstExprSpmdScan _) 68]
    [(AstExprSpmdBroadcast _ _) 64]
    [(AstExprTry _) 29]
    [(AstExprReturn _) 48]
    [(AstExprPtrNull _) 30]
    [(AstExprPtrNullCheck _) 31]
    [(AstExprWithResource _ _) 33]
    [(AstExprPtrAddrOf _) 62]
    [(AstExprPtrRead _) 34]
    [(AstExprPtrWrite _ _) 35]
    [(AstExprPtrOffset _ _) 36]
    [(AstExprPtrCast _ _) 37]
    [(AstExprPtrToInt _) 38]
    [(AstExprIntToPtr _ _) 39]
    [(AstExprBox _) 42]
    [(AstExprBoxGet _) 43]
    [(AstExprBoxTake _) 65]
    [(AstExprBoxSet _ _) 66]
    [(AstExprQuote _) 44]
    [(AstExprQuasiquote _) 45]
    [(AstExprUnquote _) 46]
    [(AstExprUnquoteSplicing _) 47]
    [(AstExprBracketClause _) 63]
    [(AstExprStringData _) 49]
    [(AstExprStringFromBytes _ _) 50]
    [(AstExprArrayData _) 51]
    [(AstExprBinaryData _) 64]
    [(AstExprProgramArgc) 52]
    [(AstExprProgramArgv) 53]
    [(AstExprProgramEnvp) 54]
    [(AstExprCpuIdEax _ _) 55]
    [(AstExprCpuIdEbx _ _) 56]
    [(AstExprCpuIdEcx _ _) 57]
    [(AstExprCpuIdEdx _ _) 58]
    [(AstExprXgetbv _) 59]
    [(AstExprSyscall _) 60]))

(define (ast-expr-unspan [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExprSpanned inner-id _) (ast-expr-unspan (ast-node-get inner-id))]
    [_ expr]))

(define (ast-decl-tag [decl : AstDecl]) : i64
  (match decl
    [(AstDeclDef _ _ _) 1]
    [(AstDeclDefFn _ _ _ _ _) 2]
    [(AstDeclDefMacro _ _ _ _) 10]
    [(AstDeclExtern _ _ _ _) 3]
    [(AstDeclDefEnum _ _ _) 4]
    [(AstDeclDefStruct _ _ _ _) 5]
    [(AstDeclImport _) 6]
    [(AstDeclTest _ _ _) 7]
    [(AstDeclComptimeDecl _ _) 8]
    [(AstDeclModule _) 9]
    [(AstDeclExport _) 11]
    [(AstDeclIncludeStr _ _) 12]
    [(AstDeclUnsafe _) 13]
    [(AstDeclDefEnumLifetimes _ _ _ _) 14]
    [(AstDeclDefStructLifetimes _ _ _ _ _) 15]
    [(AstDeclDefDispatch _ _) 16]
    [(AstDeclIncludeBin _ _) 17]))

(define (ast-struct-repr-c? [repr : AstStructRepr]) : bool
  (match repr
    [(AstStructReprC) true]
    [(AstStructReprDefault) false]))

(define (ast-extern-abi-c? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiC) true]
    [(AstExternAbiCVarargsOpen) true]
    [(AstExternAbiCVarargsTyped _) true]))

(define (ast-extern-abi-c-varargs? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiC) false]
    [(AstExternAbiCVarargsOpen) true]
    [(AstExternAbiCVarargsTyped _) true]))

(define (ast-extern-abi-c-varargs-open? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiCVarargsOpen) true]
    [_ false]))

(define (ast-extern-abi-c-varargs-typed? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiCVarargsTyped _) true]
    [_ false]))

(define (ast-extern-abi-varargs-tail-type [abi : AstExternAbi]) : AstType
  (match abi
    [(AstExternAbiCVarargsTyped ty) ty]
    [_ (AstTyUnit)]))

(define (ast-lifetime-list-eq? [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (match a
    [(AstLifetimeNil)
      (match b
        [(AstLifetimeNil) true]
        [_ false])]
    [(AstLifetimeCons a-head a-rest)
      (match b
        [(AstLifetimeCons b-head b-rest)
          (and
            (string-eq a-head b-head)
            (ast-lifetime-list-eq? (box-get a-rest) (box-get b-rest)))]
        [_ false])]))

(define (ast-type-list-eq? [a : AstTypeList] [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
      (match b
        [(AstTypeNil) true]
        [_ false])]
    [(AstTypeCons a-head a-rest)
      (match b
        [(AstTypeCons b-head b-rest)
          (and
            (ast-type-eq? (ty-node-get a-head) (ty-node-get b-head))
            (ast-type-list-eq? (box-get a-rest) (box-get b-rest)))]
        [_ false])]))

(define (ast-type-eq? [a : AstType] [b : AstType]) : bool
  (match a
    [(AstTyI64)
      (match b
        [(AstTyI64) true]
        [_ false])]
    [(AstTyI32)
      (match b
        [(AstTyI32) true]
        [_ false])]
    [(AstTyI16)
      (match b
        [(AstTyI16) true]
        [_ false])]
    [(AstTyI8)
      (match b
        [(AstTyI8) true]
        [_ false])]
    [(AstTyU64)
      (match b
        [(AstTyU64) true]
        [_ false])]
    [(AstTyU32)
      (match b
        [(AstTyU32) true]
        [_ false])]
    [(AstTyU16)
      (match b
        [(AstTyU16) true]
        [_ false])]
    [(AstTyU8)
      (match b
        [(AstTyU8) true]
        [_ false])]
    [(AstTyF64)
      (match b
        [(AstTyF64) true]
        [_ false])]
    [(AstTyF32)
      (match b
        [(AstTyF32) true]
        [_ false])]
    [(AstTyBool)
      (match b
        [(AstTyBool) true]
        [_ false])]
    [(AstTyChar)
      (match b
        [(AstTyChar) true]
        [_ false])]
    [(AstTyString)
      (match b
        [(AstTyString) true]
        [_ false])]
    [(AstTyStr)
      (match b
        [(AstTyStr) true]
        [_ false])]
    [(AstTyBytes)
      (match b
        [(AstTyBytes) true]
        [_ false])]
    [(AstTyUnit)
      (match b
        [(AstTyUnit) true]
        [_ false])]
    [(AstTyNever)
      (match b
        [(AstTyNever) true]
        [_ false])]
    [(AstTyExpr)
      (match b
        [(AstTyExpr) true]
        [_ false])]
    [(AstTyExprList)
      (match b
        [(AstTyExprList) true]
        [_ false])]
    [(AstTyFunc a-args a-ret)
      (match b
        [(AstTyFunc b-args b-ret)
          (and
            (ast-type-list-eq? a-args b-args)
            (ast-type-eq? (ty-node-get a-ret) (ty-node-get b-ret)))]
        [_ false])]
    [(AstTyTuple a-elems)
      (match b
        [(AstTyTuple b-elems) (ast-type-list-eq? a-elems b-elems)]
        [_ false])]
    [(AstTyArray a-elem a-len)
      (match b
        [(AstTyArray b-elem b-len)
          (and
            (= a-len b-len)
            (ast-type-eq? (ty-node-get a-elem) (ty-node-get b-elem)))]
        [_ false])]
    [(AstTyDynArray a-elem)
      (match b
        [(AstTyDynArray b-elem)
          (ast-type-eq? (ty-node-get a-elem) (ty-node-get b-elem))]
        [_ false])]
    [(AstTyBox a-elem)
      (match b
        [(AstTyBox b-elem)
          (ast-type-eq? (ty-node-get a-elem) (ty-node-get b-elem))]
        [_ false])]
    [(AstTyRegion a-region a-inner)
      (match b
        [(AstTyRegion b-region b-inner)
          (and
            (string-eq a-region b-region)
            (ast-type-eq? (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyRef a-lifetime a-inner)
      (match b
        [(AstTyRef b-lifetime b-inner)
          (and
            (string-eq a-lifetime b-lifetime)
            (ast-type-eq? (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyMutRef a-lifetime a-inner)
      (match b
        [(AstTyMutRef b-lifetime b-inner)
          (and
            (string-eq a-lifetime b-lifetime)
            (ast-type-eq? (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyEnumArgs a-name a-lifetimes)
      (match b
        [(AstTyEnumArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyStructArgs a-name a-lifetimes)
      (match b
        [(AstTyStructArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyVarArgs a-name a-lifetimes)
      (match b
        [(AstTyVarArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ast-lifetime-list-eq? a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyPtr a-elem)
      (match b
        [(AstTyPtr b-elem)
          (ast-type-eq? (ty-node-get a-elem) (ty-node-get b-elem))]
        [_ false])]
    [(AstTyMutPtr a-elem)
      (match b
        [(AstTyMutPtr b-elem)
          (ast-type-eq? (ty-node-get a-elem) (ty-node-get b-elem))]
        [_ false])]))

(define (ast-extern-abi-eq? [a : AstExternAbi] [b : AstExternAbi]) : bool
  (match a
    [(AstExternAbiC)
      (match b
        [(AstExternAbiC) true]
        [_ false])]
    [(AstExternAbiCVarargsOpen)
      (match b
        [(AstExternAbiCVarargsOpen) true]
        [_ false])]
    [(AstExternAbiCVarargsTyped aty)
      (match b
        [(AstExternAbiCVarargsTyped bty) (ast-type-eq? aty bty)]
        [_ false])]))

(define (ast-extern-link-input-eq?
  [a : AstExternLinkInput]
  [b : AstExternLinkInput]) : bool
  (match a
    [(AstExternLinkLib aname)
      (match b
        [(AstExternLinkLib bname) (string-eq aname bname)]
        [_ false])]
    [(AstExternLinkSearch adir)
      (match b
        [(AstExternLinkSearch bdir) (string-eq adir bdir)]
        [_ false])]
    [(AstExternLinkArg aarg)
      (match b
        [(AstExternLinkArg barg) (string-eq aarg barg)]
        [_ false])]))

(define (ast-extern-link-input-list-eq?
  [a : AstExternLinkInputList]
  [b : AstExternLinkInputList]) : bool
  (match a
    [(AstExternLinkInputNil)
      (match b
        [(AstExternLinkInputNil) true]
        [_ false])]
    [(AstExternLinkInputCons ahead arest)
      (let
        [arest : AstExternLinkInputList (box-get arest)]
        (match b
          [(AstExternLinkInputCons bhead brest)
            (let
              [brest : AstExternLinkInputList (box-get brest)]
              (and
                (ast-extern-link-input-eq? ahead bhead)
                (ast-extern-link-input-list-eq? arest brest)))]
          [_ false]))]))

(define (ast-extern-link-input-list-append
  [items : AstExternLinkInputList]
  [item : AstExternLinkInput]) : AstExternLinkInputList
  (match items
    [(AstExternLinkInputNil)
      (ast-extern-link-input-cons item AstExternLinkInputNil)]
    [(AstExternLinkInputCons head rest)
      (let
        [rest : AstExternLinkInputList (box-get rest)]
        (ast-extern-link-input-cons
          head
          (ast-extern-link-input-list-append rest item)))]))

(define (ast-extern-default-metadata [name : String]) : AstExternMetadata
  (AstExternMetadata (AstExternAbiC) name AstExternLinkInputNil false))

(define (ast-extern-metadata-symbol [metadata : AstExternMetadata]) : String
  (match metadata
    [(AstExternMetadata _ symbol _ _) symbol]))

(define (ast-extern-metadata-abi [metadata : AstExternMetadata]) : AstExternAbi
  (match metadata
    [(AstExternMetadata abi _ _ _) abi]))

(define (ast-extern-metadata-link-inputs [metadata : AstExternMetadata]) : AstExternLinkInputList
  (match metadata
    [(AstExternMetadata _ _ link-inputs _) link-inputs]))

(define (ast-extern-metadata-explicit-abi? [metadata : AstExternMetadata]) : bool
  (match metadata
    [(AstExternMetadata _ _ _ explicit-abi) explicit-abi]))

(define (ast-struct-cleanup? [cleanup : AstStructCleanup]) : bool
  (match cleanup
    [(AstStructCleanupFn _) true]
    [(AstStructNoCleanup) false]))

(define (ast-enum-cleanup? [cleanup : AstEnumCleanup]) : bool
  (match cleanup
    [(AstEnumCleanupFn _) true]
    [(AstEnumNoCleanup) false]))

(define (ast-field-cleanup? [cleanup : AstFieldCleanup]) : bool
  (match cleanup
    [(AstFieldCleanupFn _) true]
    [(AstFieldOwnedCleanup) true]
    [(AstFieldNoCleanup) false]))

(define (ast-variant-payload-cleanup? [cleanup : AstVariantPayloadCleanup]) : bool
  (match cleanup
    [(AstVariantPayloadCleanupFn _) true]
    [(AstVariantPayloadOwnedCleanup) true]
    [(AstVariantPayloadNoCleanup) false]))

(define (compiler-ast-begin-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExprBegin _) true]
    [_ false]))

(define (compiler-ast-nested-pattern-box-ok? [pattern : AstPattern]) : bool
  (match pattern
    [(AstPatVariant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (and
          (= name (intern "Some"))
          (match args
            [(AstPatternCons tuple-pattern rest-box)
              (let
                [tuple-pattern : AstPattern (box-get tuple-pattern)]
                [rest : AstPatternList (box-get rest-box)]
                (and
                  (match rest
                    [(AstPatternNil) true]
                    [_ false])
                  (match tuple-pattern
                    [(AstPatTuple items-box)
                      (let
                        [items : AstPatternList (box-get items-box)]
                        (match items
                          [(AstPatternCons first tail-box)
                            (let
                              [first : AstPattern (box-get first)]
                              [tail : AstPatternList (box-get tail-box)]
                              (and
                                (match first
                                  [(AstPatBinding bind-name)
                                    (= bind-name (intern "item"))]
                                  [_ false])
                                (match tail
                                  [(AstPatternCons second done-box)
                                    (let
                                      [second : AstPattern (box-get second)]
                                      [done : AstPatternList (box-get done-box)]
                                      (and
                                        (match second
                                          [(AstPatWildcard) true]
                                          [_ false])
                                        (match done
                                          [(AstPatternNil) true]
                                          [_ false])))]
                                  [_ false])))]
                          [_ false]))]
                    [_ false])))]
            [_ false])))]
    [_ false]))

(define (compiler-ast-single-arm-box-ok? [arms : AstMatchArmList]) : bool
  (match arms
    [(AstMatchArmCons arm rest-box)
      (let
        [rest : AstMatchArmList (box-get rest-box)]
        (and
          (match rest
            [(AstMatchArmNil) true]
            [_ false])
          (match arm
            [(AstMatchArm pattern body-id)
              (let
                [body : AstExpr (ast-node-get body-id)]
                (and
                  (compiler-ast-nested-pattern-box-ok? pattern)
                  (compiler-ast-begin-expr? body)))]
            [_ false])))]
    [_ false]))

(define (compiler-ast-nested-expr-box-ok? [expr : AstExpr]) : bool
  (match expr
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (and
          (match bindings
            [(AstLetBindingCons binding rest-box)
              (let
                [rest : AstLetBindingList (box-get rest-box)]
                (and
                  (match rest
                    [(AstLetBindingNil) true]
                    [_ false])
                  (match binding
                    [(AstLetBinding name _ init-box)
                      (let
                        [init : AstExpr (ast-node-get init-box)]
                        (and
                          (= name (intern "x"))
                          (compiler-ast-begin-expr? init)))]
                    [_ false])))]
            [_ false])
          (match body
            [(AstExprIf cond-box then-box else-box)
              (let
                [cond : AstExpr (ast-node-get cond-box)]
                [then-expr : AstExpr (ast-node-get then-box)]
                [else-expr : AstExpr (ast-node-get else-box)]
                (and
                  (match cond
                    [(AstExprVar name) (string-eq (intern-str name) "cond")]
                    [_ false])
                  (match then-expr
                    [(AstExprMatch match-box)
                      (match (box-get match-box)
                        [(AstMatch scrut-box arms)
                          (let
                            [scrut : AstExpr (ast-node-get scrut-box)]
                            (and
                              (match scrut
                                [(AstExprVar name)
                                  (string-eq (intern-str name) "input")]
                                [_ false])
                              (compiler-ast-single-arm-box-ok? arms)))])]
                    [_ false])
                  (compiler-ast-begin-expr? else-expr)))]
            [_ false])))]
    [_ false]))

(define (compiler-ast-expr-pattern-box-smoke?) : bool
  (let
    [one : i64 (ast-node-push (AstExprLiteral (AstLitInt 1)))]
    [two : i64 (ast-node-push (AstExprLiteral (AstLitInt 2)))]
    [begin-expr : i64
      (ast-node-push
        (AstExprBegin (ast-expr-cons one (ast-expr-cons two AstExprNil))))]
    [bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding "x" (AstNoType) begin-expr)
        AstLetBindingNil)]
    [tuple-pattern : AstPattern
      (ast-pat-tuple
        (ast-pattern-cons
          (ast-pat-binding "item")
          (ast-pattern-cons (AstPatWildcard) AstPatternNil)))]
    [variant-pattern : AstPattern
      (ast-pat-variant "Some" (ast-pattern-cons tuple-pattern AstPatternNil))]
    [arms : AstMatchArmList
      (ast-match-arm-cons
        (ast-match-arm variant-pattern begin-expr)
        AstMatchArmNil)]
    [match-expr : i64
      (ast-expr-match (ast-node-push (AstExprVar (intern "input"))) arms)]
    [nested : i64
      (ast-expr-let
        bindings
        (ast-expr-if
          (ast-node-push (AstExprVar (intern "cond")))
          match-expr
          begin-expr))]
    (compiler-ast-nested-expr-box-ok? (ast-node-get nested))))

(define (compiler-ast-decl-def-lit-ok?
  [decl : AstDecl]
  [want-name : String]
  [want-value : i64]) : bool
  (match decl
    [(AstDeclDef name _ value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (and
          (= name (intern want-name))
          (match value
            [(AstExprLiteral (AstLitInt actual)) (= actual want-value)]
            [_ false])))]
    [_ false]))

(define (compiler-ast-nested-decl-box-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (match inner
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (compiler-ast-decl-def-lit-ok? template "generated" 7))]
          [_ false]))]
    [_ false]))

(define (compiler-ast-decl-program-box-smoke?) : bool
  (let
    [generated : AstDecl
      (ast-decl-def
        "generated"
        (AstSomeType (AstTyI64))
        (ast-node-push (AstExprLiteral (AstLitInt 7))))]
    [runtime : AstDecl
      (ast-decl-def
        "runtime"
        (AstSomeType (AstTyI64))
        (ast-node-push (AstExprLiteral (AstLitInt 9))))]
    [nested : AstDecl (ast-decl-unsafe (ast-decl-comptime-decl generated))]
    [program : AstProgram
      (ast-program (ast-decl-cons nested (ast-decl-cons runtime AstDeclNil)))]
    (match program
      [(AstProgram decls-box)
        (let
          [decls : AstDeclList (box-get decls-box)]
          (match decls
            [(AstDeclCons first rest-box)
              (let
                [rest : AstDeclList (box-get rest-box)]
                (and
                  (compiler-ast-nested-decl-box-ok? first)
                  (match rest
                    [(AstDeclCons second done-box)
                      (let
                        [done : AstDeclList (box-get done-box)]
                        (and
                          (compiler-ast-decl-def-lit-ok? second "runtime" 9)
                          (match done
                            [(AstDeclNil) true]
                            [_ false])))]
                    [_ false])))]
            [_ false]))])))

;; #2357: the ty-node pool now grows on demand (see ty-node-pool-grow!) rather
;; than failing closed, so a push at capacity allocates a larger backing array and
;; assigns the next sequential id -- it never exhausts. Verify that growth.
(define (compiler-ast-type-pool-exhaustion-smoke?) : bool
  (let
    [capacity : i64 (ty-node-pool-capacity)]
    (begin
      (ty-node-pool-reset!)
      (ty-node-pool-truncate! capacity)
      (let
        [id : i64 (ty-node-push (AstTyI64))]
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
      [first-i64 : i64 (ty-node-push (AstTyI64))]
      [first-len : i64 (ty-node-pool-len)]
      [second-i64 : i64 (ty-node-push (AstTyI64))]
      [second-len : i64 (ty-node-pool-len)]
      [first-array : i64 (ty-node-push (ast-ty-array (AstTyI64) 4))]
      [array-len : i64 (ty-node-pool-len)]
      [second-array : i64 (ty-node-push (ast-ty-array (AstTyI64) 4))]
      [final-len : i64 (ty-node-pool-len)]
      [first-bytes : i64 (ty-node-push (AstTyBytes))]
      [bytes-len : i64 (ty-node-pool-len)]
      [second-bytes : i64 (ty-node-push (AstTyBytes))]
      [second-bytes-len : i64 (ty-node-pool-len)]
      [str-ty : i64 (ty-node-push (AstTyStr))]
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

(define (compiler-ast-smoke) : i64
  (let
    [i64-ty : AstType (AstTyI64)]
    [string-ty : AstType (AstTyString)]
    [arg-tys : AstTypeList
      (ast-type-cons i64-ty (ast-type-cons string-ty AstTypeNil))]
    [ret-ty : AstType (ast-ty-ref "r" (ast-ty-ptr (ast-ty-array i64-ty 4)))]
    [fn-ty : AstType (ast-ty-func arg-tys ret-ty)]
    [nested-ty-ok? : bool
      (match fn-ty
        [(AstTyFunc _ ret)
          (match (ty-node-get ret)
            [(AstTyRef region ptr)
              (and
                (string-eq region "r")
                (match (ty-node-get ptr)
                  [(AstTyPtr array)
                    (match (ty-node-get array)
                      [(AstTyArray elem count)
                        (and
                          (= count 4)
                          (match (ty-node-get elem)
                            [(AstTyI64) true]
                            [_ false]))]
                      [_ false])]
                  [_ false]))]
            [_ false])]
        [_ false])]
    [lit : AstLiteral (AstLitInt 41)]
    [one : i64 (ast-node-push (AstExprLiteral (AstLitInt 1)))]
    [expr : i64
      (ast-expr-binary (AstBinAdd) (ast-node-push (AstExprLiteral lit)) one)]
    [nested-expr-pattern-ok? : bool (compiler-ast-expr-pattern-box-smoke?)]
    [decl-program-ok? : bool (compiler-ast-decl-program-box-smoke?)]
    [type-dedup-ok? : bool (compiler-ast-type-dedup-smoke?)]
    [pool-exhaustion-ok? : bool (compiler-ast-type-pool-exhaustion-smoke?)]
    [param : AstParam (ast-param "x" i64-ty false)]
    [params : AstParamList (ast-param-cons param AstParamNil)]
    [decl : AstDecl (ast-decl-def-fn "main" params i64-ty expr)]
    [program : AstProgram (ast-program (ast-decl-cons decl AstDeclNil))]
    (match program
      [(AstProgram _)
        (if (and
          nested-ty-ok?
          nested-expr-pattern-ok?
          decl-program-ok?
          type-dedup-ok?
          pool-exhaustion-ok?)
          (+
            (ast-type-tag fn-ty)
            (+ (ast-expr-tag (ast-node-get expr)) (ast-decl-tag decl)))
          0)])))