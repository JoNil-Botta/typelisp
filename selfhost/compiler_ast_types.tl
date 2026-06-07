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
  (AstTyEnum String)
  (AstTyEnumArgs String AstLifetimeList)
  (AstTyStruct String)
  (AstTyStructArgs String AstLifetimeList)
  (AstTyVar String)
  (AstTyVarArgs String AstLifetimeList)
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
  (AstParam String AstType bool))

(defenum AstParamList
  (AstParamNil)
  (AstParamCons AstParam (Box AstParamList)))

(defenum AstMacroParam
  (AstMacroParam String AstType bool))

(defenum AstMacroParamList
  (AstMacroParamNil)
  (AstMacroParamCons AstMacroParam (Box AstMacroParamList)))

(defenum AstFieldCleanup
  (AstFieldNoCleanup)
  (AstFieldCleanupFn String)
  (AstFieldOwnedCleanup))

(defenum AstFieldDef
  (AstFieldDef String AstType AstFieldCleanup))

(defenum AstFieldDefList
  (AstFieldDefNil)
  (AstFieldDefCons AstFieldDef (Box AstFieldDefList)))

(defenum AstStructRepr
  (AstStructReprDefault)
  (AstStructReprC))

(defenum AstExternAbi
  (AstExternAbiC)
  (AstExternAbiCVarargs i64)
  (AstExternAbiCVarargsOpen i64)
  (AstExternAbiCVarargsTyped i64 AstType))

(defenum AstExternLinkInput
  (AstExternLinkLib String)
  (AstExternLinkSearch String)
  (AstExternLinkArg String))

(defenum AstExternLinkInputList
  (AstExternLinkInputNil)
  (AstExternLinkInputCons AstExternLinkInput (Box AstExternLinkInputList)))

(defenum AstFnExport
  (AstFnNoExport)
  (AstFnExport String))

(defenum AstExternMetadata
  (AstExternMetadata AstExternAbi String AstExternLinkInputList bool))

(defenum AstStructCleanup
  (AstStructNoCleanup)
  (AstStructCleanupFn String))

(defenum AstEnumCleanup
  (AstEnumNoCleanup)
  (AstEnumCleanupFn String))

(defenum AstVariantPayloadCleanup
  (AstVariantPayloadNoCleanup)
  (AstVariantPayloadCleanupFn String)
  (AstVariantPayloadOwnedCleanup))

(defenum AstVariantPayloadCleanupList
  (AstVariantPayloadCleanupNil)
  (AstVariantPayloadCleanupCons
    AstVariantPayloadCleanup
    (Box AstVariantPayloadCleanupList)))

(defenum AstVariantDef
  (AstVariantDef String AstTypeList AstVariantPayloadCleanupList))

(defenum AstVariantDefList
  (AstVariantDefNil)
  (AstVariantDefCons AstVariantDef (Box AstVariantDefList)))

(defenum AstPattern
  (AstPatVar String AstMaybeType)
  (AstPatTuple (Box AstPatternList))
  (AstPatWildcard)
  (AstPatBinding String)
  (AstPatVariant String (Box AstPatternList))
  (AstPatLiteral AstLiteral))

(defenum AstPatternList
  (AstPatternNil)
  (AstPatternCons (Box AstPattern) (Box AstPatternList)))

(defenum AstLetBinding
  (AstLetBinding String AstMaybeType i64))

(defenum AstLetBindingList
  (AstLetBindingNil)
  (AstLetBindingCons AstLetBinding (Box AstLetBindingList)))

(defenum AstResourceBinding
  (AstResourceBinding String i64 i64))

(defenum AstResourceBindingList
  (AstResourceBindingNil)
  (AstResourceBindingCons AstResourceBinding (Box AstResourceBindingList)))

(defenum AstMatchArm
  (AstMatchArm AstPattern i64))

(defenum AstMatchArmList
  (AstMatchArmNil)
  (AstMatchArmCons AstMatchArm (Box AstMatchArmList)))

(defenum AstExpr
  (AstExprSpanned i64 AstSourceSpan)
  (AstExprLiteral AstLiteral)
  (AstExprVar i64)
  (AstExprBinary AstBinOp i64 i64)
  (AstExprUnary AstUnOp i64)
  (AstExprCall i64 AstExprList)
  (AstExprIf i64 i64 i64)
  (AstExprLet AstLetBindingList i64)
  (AstExprLambda AstParamList AstMaybeType i64)
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
  (AstExprSet String i64)
  (AstExprAnn i64 AstType)
  (AstExprCast i64 AstType)
  (AstExprBorrow bool AstBorrowLifetime i64)
  (AstExprMatch i64 AstMatchArmList)
  (AstExprForeach String AstType i64 i64 i64)
  (AstExprSpmdReduce AstReduceOp String AstType i64 i64 i64 i64)
  (AstExprStructGet i64 String)
  (AstExprWithRegion String AstExprList)
  (AstExprWithEscape i64 AstExprList)
  (AstExprWithResource AstResourceBindingList AstExprList)
  (AstExprBox i64)
  (AstExprBoxGet i64)
  ;; Compile-time-only type value literal: `(type T)`.
  (AstExprTypeLiteral AstType)
  ;; Explicit zero/identity initialization for values of type `T`.
  (AstExprInit AstType)
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
  (AstExprPtrAddrOf String)
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
  ;; Raw Linux x86_64 syscall. `(syscall number a0 .. a5)` lowers directly to a
  ;; `syscall` instruction: the number plus up to six arguments. Returns the raw
  ;; kernel result in an i64 (negative is `-errno`); callers translate errno.
  (AstExprSyscall AstExprList))

;; --- flat AST node pool (flat-node rewrite; owner directive "do the hard thing")
;; AstExpr nodes live in one growable pool, referenced by AstNodeId (an index)
;; instead of i64. This makes the expression AST a flat array: parsing
;; appends nodes (no per-node box), traversal indexes the pool (cache-friendly),
;; and the loader needs no per-file deep clone (nodes already persist in the pool).
;; The pool is process-global and reset per compile (see ast-node-pool-reset!),
;; reusing one backing array; AstNodeId values stay valid because the pool only
;; grows within a compile (callers truncate via ast-node-pool-mark/reset on parse
;; error). See the typelisp-flat-ast-rewrite memory for the full design.
;; Two flat globals (array + count) rather than a reassigned struct: the hot
;; push/get paths are inlined everywhere, and a global-struct reassign in that
;; hot path tripped an opt2 miscompile. Plain mutable globals keep codegen simple.
(define ast-node-pool-slots : (Array AstExpr)
  (make-array AstExpr 4000000))

(define ast-node-pool-count : i64
  0)

;: Current node count (also the next AstNodeId that ast-node-push will assign).
(define (ast-node-pool-len) : i64
  ast-node-pool-count)

;: Grow the pool's backing array to at least double its current capacity.
(define (ast-node-pool-grow!) : unit
  (let
    [old-slots : (Array AstExpr) ast-node-pool-slots]
    [old-cap : i64 (array-length old-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [new-slots : (Array AstExpr) (make-array AstExpr new-cap)]
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
(define (ast-node-get [id : i64]) : AstExpr
  (array-ref ast-node-pool-slots id))

;: Overwrite the node at `id` in place (used when a node is rewritten in place).
(define (ast-node-set! [id : i64] [node : AstExpr]) : unit
  (array-set! ast-node-pool-slots id node))

;: Truncate the pool back to `mark` nodes (used to discard nodes from a failed
;: parse). Reset to 0 between compiles so a fresh compile reuses the array.
(define (ast-node-pool-truncate! [mark : i64]) : unit
  (set! ast-node-pool-count mark))

(define (ast-node-pool-reset!) : unit
  (ast-node-pool-truncate! 0))

;; --- AstType node pool (flat ty ids) ---
;; AstType's recursive children are stored as i64 ids into this pool instead of
;; (Box AstType), mirroring the AstExpr pool above. The pool is PERSISTENT for a
;; compile (types live for the whole compile, never per-form like the spanned
;; pool); ty-node-pool-reset! clears it between compiles (REPL/LSP). Pre-sized so
;; grow! never fires on real inputs -- a grow! reassign in the inlined hot path
;; trips an opt2 miscompile (see the typelisp-flat-asttype-plan memory).
(define ty-node-pool-slots : (Array AstType)
  (make-array AstType 2000000))

(define ty-node-pool-count : i64
  0)

;: Current type-node count (also the next ty id ty-node-push will assign).
(define (ty-node-pool-len) : i64
  ty-node-pool-count)

;: Grow the pool's backing array to at least double its current capacity.
(define (ty-node-pool-grow!) : unit
  (let
    [old-slots : (Array AstType) ty-node-pool-slots]
    [old-cap : i64 (array-length old-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [new-slots : (Array AstType) (make-array AstType new-cap)]
    [len : i64 ty-node-pool-count]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! new-slots i (array-ref old-slots i))
          (set! i (+ i 1))))
      (set! ty-node-pool-slots new-slots))))

;: Append `node` to the pool and return its ty id.
(define (ty-node-push [node : AstType]) : i64
  (begin
    (if (>= ty-node-pool-count (array-length ty-node-pool-slots))
      (ty-node-pool-grow!)
      unit)
    (let
      [id : i64 ty-node-pool-count]
      (begin
        (array-set! ty-node-pool-slots id node)
        (set! ty-node-pool-count (+ id 1))
        id))))

;: Read the type node at `id`.
(define (ty-node-get [id : i64]) : AstType
  (array-ref ty-node-pool-slots id))

;: Overwrite the type node at `id` in place.
(define (ty-node-set! [id : i64] [node : AstType]) : unit
  (array-set! ty-node-pool-slots id node))

;: Truncate the pool back to `mark` nodes (discard from a failed parse).
(define (ty-node-pool-truncate! [mark : i64]) : unit
  (set! ty-node-pool-count mark))

(define (ty-node-pool-reset!) : unit
  (ty-node-pool-truncate! 0))

(defenum AstExprList
  (AstExprNil)
  (AstExprCons i64 (Box AstExprList)))

(defenum AstMaybeModuleName
  (AstNoModuleName)
  (AstSomeModuleName String))

(defenum AstMaybeImportAlias
  (AstNoImportAlias)
  (AstSomeImportAlias String))

(defenum AstImportSpec
  (AstImportSpec String AstMaybeModuleName AstMaybeImportAlias))

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
  (AstDeclModule String)
  (AstDeclDef String AstMaybeType i64)
  (AstDeclDefFn String AstParamList AstType i64 AstFnExport)
  (AstDeclDefMacro String AstMacroParamList AstType i64)
  (AstDeclExtern String AstExternMetadata AstType)
  (AstDeclDefEnum String AstEnumCleanup AstVariantDefList)
  (AstDeclDefEnumLifetimes
    String
    AstLifetimeList
    AstEnumCleanup
    AstVariantDefList)
  (AstDeclDefStruct String AstStructRepr AstStructCleanup AstFieldDefList)
  (AstDeclDefStructLifetimes
    String
    AstLifetimeList
    AstStructRepr
    AstStructCleanup
    AstFieldDefList)
  (AstDeclImport AstImportSpec)
  (AstDeclIncludeStr String String)
  (AstDeclExport AstExportItemList)
  (AstDeclDefDispatch String AstDispatchVariantList)
  (AstDeclTest String i64 AstSourceSpan)
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

(define (ast-param-cons [head : AstParam] [rest : AstParamList]) : AstParamList
  (AstParamCons head (box rest)))

(define (ast-macro-param-cons [head : AstMacroParam] [rest : AstMacroParamList]) : AstMacroParamList
  (AstMacroParamCons head (box rest)))

(define (ast-field-def-cons [head : AstFieldDef] [rest : AstFieldDefList]) : AstFieldDefList
  (AstFieldDefCons head (box rest)))

(define (ast-extern-link-input-cons
  [head : AstExternLinkInput]
  [rest : AstExternLinkInputList]) : AstExternLinkInputList
  (AstExternLinkInputCons head (box rest)))

(define (ast-variant-def-cons [head : AstVariantDef] [rest : AstVariantDefList]) : AstVariantDefList
  (AstVariantDefCons head (box rest)))

(define (ast-variant-payload-cleanup-cons
  [head : AstVariantPayloadCleanup]
  [rest : AstVariantPayloadCleanupList]) : AstVariantPayloadCleanupList
  (AstVariantPayloadCleanupCons head (box rest)))

(define (ast-pattern-cons [head : AstPattern] [rest : AstPatternList]) : AstPatternList
  (AstPatternCons (box head) (box rest)))

(define (ast-pat-tuple [items : AstPatternList]) : AstPattern
  (AstPatTuple (box items)))

(define (ast-pat-variant [name : String] [items : AstPatternList]) : AstPattern
  (AstPatVariant name (box items)))

(define (ast-let-binding
  [name : String]
  [maybe-ty : AstMaybeType]
  [value : i64]) : AstLetBinding
  (AstLetBinding name maybe-ty value))

(define (ast-let-binding-cons [head : AstLetBinding] [rest : AstLetBindingList]) : AstLetBindingList
  (AstLetBindingCons head (box rest)))

(define (ast-resource-binding [name : String] [init : i64] [cleanup : i64]) : AstResourceBinding
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

(define (ast-expr-spanned [inner : i64] [span : AstSourceSpan]) : i64
  (ast-node-push (AstExprSpanned inner span)))

(define (ast-expr-binary [op : AstBinOp] [left : i64] [right : i64]) : i64
  (ast-node-push (AstExprBinary op left right)))

(define (ast-expr-unary [op : AstUnOp] [inner : i64]) : i64
  (ast-node-push (AstExprUnary op inner)))

(define (ast-expr-call [callee : i64] [args : AstExprList]) : i64
  (ast-node-push (AstExprCall callee args)))

(define (ast-expr-if [cond : i64] [then-expr : i64] [else-expr : i64]) : i64
  (ast-node-push (AstExprIf cond then-expr else-expr)))

(define (ast-expr-let [bindings : AstLetBindingList] [body : i64]) : i64
  (ast-node-push (AstExprLet bindings body)))

(define (ast-expr-lambda
  [params : AstParamList]
  [ret : AstMaybeType]
  [body : i64]) : i64
  (ast-node-push (AstExprLambda params ret body)))

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
  (ast-node-push (AstExprMatch scrutinee arms)))

(define (ast-expr-foreach
  [name : String]
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
  (ast-node-push (AstExprSpmdReduce op name index-ty start end init value)))

(define (ast-expr-struct-get [target : i64] [field : String]) : i64
  (ast-node-push (AstExprStructGet target field)))

(define (ast-expr-with-escape [escape : i64] [body : AstExprList]) : i64
  (ast-node-push (AstExprWithEscape escape body)))

(define (ast-expr-box [value : i64]) : i64
  (ast-node-push (AstExprBox value)))

(define (ast-expr-box-get [value : i64]) : i64
  (ast-node-push (AstExprBoxGet value)))

(define (ast-expr-init [ty : AstType]) : i64
  (ast-node-push (AstExprInit ty)))

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

(define (ast-decl-def [name : String] [maybe-ty : AstMaybeType] [value : i64]) : AstDecl
  (AstDeclDef name maybe-ty value))

(define (ast-decl-def-fn
  [name : String]
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
  (AstDeclDefFn name params ret body export))

(define (ast-decl-def-macro
  [name : String]
  [params : AstMacroParamList]
  [ret : AstType]
  [body : i64]) : AstDecl
  (AstDeclDefMacro name params ret body))

(define (ast-decl-test [name : String] [body : i64] [span : AstSourceSpan]) : AstDecl
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
    [(AstExprLambda _ _ _) 9]
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
    [(AstExprMatch _ _) 22]
    [(AstExprForeach _ _ _ _ _) 23]
    [(AstExprStructGet _ _) 24]
    [(AstExprWithRegion _ _) 25]
    [(AstExprWithEscape _ _) 48]
    [(AstExprTypeLiteral _) 26]
    [(AstExprInit _) 61]
    [(AstExprComptime _) 27]
    [(AstExprSpmdReduce _ _ _ _ _ _ _) 28]
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
    [(AstExprQuote _) 44]
    [(AstExprQuasiquote _) 45]
    [(AstExprUnquote _) 46]
    [(AstExprUnquoteSplicing _) 47]
    [(AstExprStringData _) 49]
    [(AstExprStringFromBytes _ _) 50]
    [(AstExprArrayData _) 51]
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
    [(AstDeclExtern _ _ _) 3]
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
    [(AstDeclDefDispatch _ _) 16]))

(define (ast-struct-repr-c? [repr : AstStructRepr]) : bool
  (match repr
    [(AstStructReprC) true]
    [(AstStructReprDefault) false]))

(define (ast-extern-abi-c? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiC) true]
    [(AstExternAbiCVarargs _) true]
    [(AstExternAbiCVarargsOpen _) true]
    [(AstExternAbiCVarargsTyped _ _) true]))

(define (ast-extern-abi-c-varargs? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiC) false]
    [(AstExternAbiCVarargs _) true]
    [(AstExternAbiCVarargsOpen _) true]
    [(AstExternAbiCVarargsTyped _ _) true]))

(define (ast-extern-abi-varargs-fixed-count [abi : AstExternAbi]) : i64
  (match abi
    [(AstExternAbiC) 0]
    [(AstExternAbiCVarargs fixed-count) fixed-count]
    [(AstExternAbiCVarargsOpen fixed-count) fixed-count]
    [(AstExternAbiCVarargsTyped fixed-count _) fixed-count]))

(define (ast-extern-abi-c-varargs-open? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiCVarargsOpen _) true]
    [_ false]))

(define (ast-extern-abi-c-varargs-typed? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiCVarargsTyped _ _) true]
    [_ false]))

(define (ast-extern-abi-varargs-tail-type [abi : AstExternAbi]) : AstType
  (match abi
    [(AstExternAbiCVarargsTyped _ ty) ty]
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
        [(AstTyEnum b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyEnumArgs a-name a-lifetimes)
      (match b
        [(AstTyEnumArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
            (ast-lifetime-list-eq? a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyStructArgs a-name a-lifetimes)
      (match b
        [(AstTyStructArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
            (ast-lifetime-list-eq? a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyVarArgs a-name a-lifetimes)
      (match b
        [(AstTyVarArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
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
    [(AstExternAbiCVarargs afixed)
      (match b
        [(AstExternAbiCVarargs bfixed) (= afixed bfixed)]
        [_ false])]
    [(AstExternAbiCVarargsOpen afixed)
      (match b
        [(AstExternAbiCVarargsOpen bfixed) (= afixed bfixed)]
        [_ false])]
    [(AstExternAbiCVarargsTyped afixed _)
      (match b
        [(AstExternAbiCVarargsTyped bfixed bty)
          (and
            (= afixed bfixed)
            (ast-type-eq? (ast-extern-abi-varargs-tail-type a) bty))]
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
          (string-eq name "Some")
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
                                    (string-eq bind-name "item")]
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
                          (string-eq name "x")
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
                  (and
                    (match then-expr
                      [(AstExprMatch scrut-box arms)
                        (let
                          [scrut : AstExpr (ast-node-get scrut-box)]
                          (and
                            (match scrut
                              [(AstExprVar name)
                                (string-eq (intern-str name) "input")]
                              [_ false])
                            (compiler-ast-single-arm-box-ok? arms)))]
                      [_ false])
                    (compiler-ast-begin-expr? else-expr))))]
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
          (AstPatBinding "item")
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
          (string-eq name want-name)
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
    [param : AstParam (AstParam "x" i64-ty false)]
    [params : AstParamList (ast-param-cons param AstParamNil)]
    [decl : AstDecl (ast-decl-def-fn "main" params i64-ty expr)]
    [program : AstProgram (ast-program (ast-decl-cons decl AstDeclNil))]
    (match program
      [(AstProgram _)
        (if (and nested-ty-ok? (and nested-expr-pattern-ok? decl-program-ok?))
          (+
            (ast-type-tag fn-ty)
            (+ (ast-expr-tag (ast-node-get expr)) (ast-decl-tag decl)))
          0)])))