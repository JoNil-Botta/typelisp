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
  (AstTyFunc AstTypeList (Box AstType))
  (AstTyTuple AstTypeList)
  (AstTyArray (Box AstType) i64)
  (AstTyDynArray (Box AstType))
  (AstTyBox (Box AstType))
  (AstTyRegion String (Box AstType))
  (AstTyRef String (Box AstType))
  (AstTyMutRef String (Box AstType))
  (AstTyEnum String)
  (AstTyEnumArgs String AstLifetimeList)
  (AstTyStruct String)
  (AstTyStructArgs String AstLifetimeList)
  (AstTyVar String)
  (AstTyVarArgs String AstLifetimeList)
  (AstTyPtr (Box AstType))
  (AstTyMutPtr (Box AstType)))

(defenum AstTypeList
  (AstTypeNil)
  (AstTypeCons (Box AstType) (Box AstTypeList)))

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
  (AstExternAbiCVarargs i64))

(defenum AstExternLinkInput
  (AstExternLinkLib String)
  (AstExternLinkSearch String)
  (AstExternLinkArg String))

(defenum AstExternLinkInputList
  (AstExternLinkInputNil)
  (AstExternLinkInputCons AstExternLinkInput (Box AstExternLinkInputList)))

(defenum AstExternMetadata
  (AstExternMetadata AstExternAbi String AstExternLinkInputList))

(defenum AstStructCleanup
  (AstStructNoCleanup)
  (AstStructCleanupFn String))

(defenum AstVariantDef
  (AstVariantDef String AstTypeList))

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
  (AstLetBinding String AstMaybeType (Box AstExpr)))

(defenum AstLetBindingList
  (AstLetBindingNil)
  (AstLetBindingCons AstLetBinding (Box AstLetBindingList)))

(defenum AstResourceBinding
  (AstResourceBinding String (Box AstExpr) (Box AstExpr)))

(defenum AstResourceBindingList
  (AstResourceBindingNil)
  (AstResourceBindingCons AstResourceBinding (Box AstResourceBindingList)))

(defenum AstMatchArm
  (AstMatchArm AstPattern (Box AstExpr)))

(defenum AstMatchArmList
  (AstMatchArmNil)
  (AstMatchArmCons AstMatchArm (Box AstMatchArmList)))

(defenum AstExpr
  (AstExprSpanned (Box AstExpr) AstSourceSpan)
  (AstExprLiteral AstLiteral)
  (AstExprVar String)
  (AstExprBinary AstBinOp (Box AstExpr) (Box AstExpr))
  (AstExprUnary AstUnOp (Box AstExpr))
  (AstExprCall (Box AstExpr) AstExprList)
  (AstExprIf (Box AstExpr) (Box AstExpr) (Box AstExpr))
  (AstExprLet AstLetBindingList (Box AstExpr))
  (AstExprLambda AstParamList AstMaybeType (Box AstExpr))
  (AstExprTuple AstExprList)
  (AstExprTupleRef (Box AstExpr) i64)
  (AstExprArray AstExprList)
  (AstExprMakeArray AstType (Box AstExpr))
  (AstExprArrayRef (Box AstExpr) (Box AstExpr))
  (AstExprArraySet (Box AstExpr) (Box AstExpr) (Box AstExpr))
  (AstExprArrayPush (Box AstExpr) (Box AstExpr))
  (AstExprStringRef (Box AstExpr) (Box AstExpr))
  (AstExprWhile (Box AstExpr) (Box AstExpr))
  (AstExprBegin AstExprList)
  ;; `(unsafe expr+)` (#1053): a `begin`-like block that additionally marks an
  ;; unsafe context (v1 has the same runtime/type behavior as `begin`; the
  ;; unsafe-context flag is consumed by later raw-pointer ops, #955).
  (AstExprUnsafe AstExprList)
  (AstExprSet String (Box AstExpr))
  (AstExprAnn (Box AstExpr) AstType)
  (AstExprCast (Box AstExpr) AstType)
  (AstExprBorrow AstBorrowLifetime (Box AstExpr))
  (AstExprMatch (Box AstExpr) AstMatchArmList)
  (AstExprForeach String AstType (Box AstExpr) (Box AstExpr) (Box AstExpr))
  (AstExprSpmdReduce
    AstReduceOp
    String
    AstType
    (Box AstExpr)
    (Box AstExpr)
    (Box AstExpr)
    (Box AstExpr))
  (AstExprStructGet (Box AstExpr) String)
  (AstExprWithRegion String AstExprList)
  (AstExprWithEscape (Box AstExpr) AstExprList)
  (AstExprWithResource AstResourceBindingList AstExprList)
  (AstExprBox (Box AstExpr))
  (AstExprBoxGet (Box AstExpr))
  ;; Compile-time-only type value literal: `(type T)`.
  (AstExprTypeLiteral AstType)
  ;; Reserved compile-time evaluation form `(comptime expr)` (#718). Parsed and
  ;; type-checked (as the inner expression's type); evaluation lands in #719.
  (AstExprComptime (Box AstExpr))
  ;; Macro quote syntax (#1136). The reader desugars prefix quote tokens into
  ;; these list-headed forms before parsing:
  ;;   'x       -> (quote x)
  ;;   `x       -> (quasiquote x)
  ;;   ,x       -> (unquote x)
  ;;   ,@xs     -> (unquote-splicing xs)
  (AstExprQuote (Box AstExpr))
  (AstExprQuasiquote (Box AstExpr))
  (AstExprUnquote (Box AstExpr))
  (AstExprUnquoteSplicing (Box AstExpr))
  ;; Narrow Result-like propagation form `(try expr)` (#903). The temporary
  ;; convention recognizes concrete enums with one `Ok*` and one `Err*`
  ;; variant, each carrying exactly one payload.
  (AstExprTry (Box AstExpr))
  ;; General function-local early exit: `(return expr)` checks `expr` against
  ;; the enclosing function's return type and has the internal `never` type.
  (AstExprReturn (Box AstExpr))
  ;; Null raw-pointer construction `(ptr-null : T)` where `T` is `(Ptr U)` or
  ;; `(MutPtr U)` (#1054). Lowers to a pointer-sized zero; type is `T`.
  (AstExprPtrNull AstType)
  ;; Null check `(ptr-null? p)` on a raw pointer (#1054). Result is `bool`.
  (AstExprPtrNullCheck (Box AstExpr))
  ;; Unsafe raw-pointer operations (#1055). The typechecker admits these only
  ;; inside `(unsafe ...)`; lowering maps them to existing pointer IR.
  (AstExprPtrRead (Box AstExpr))
  (AstExprPtrWrite (Box AstExpr) (Box AstExpr))
  (AstExprPtrOffset (Box AstExpr) (Box AstExpr))
  (AstExprPtrCast (Box AstExpr) AstType)
  (AstExprPtrToInt (Box AstExpr))
  (AstExprIntToPtr (Box AstExpr) AstType)
  ;; Low-level FFI bridge operations used by stdlib. These expose raw backing
  ;; storage and process entry state without synthesizing runtime wrapper calls.
  (AstExprStringData (Box AstExpr))
  (AstExprStringFromBytes (Box AstExpr) (Box AstExpr))
  (AstExprArrayData (Box AstExpr))
  (AstExprProgramArgc)
  (AstExprProgramArgv)
  (AstExprProgramEnvp)
  ;; Inline CPU feature instructions. These lower directly to x86_64 `cpuid`
  ;; and `xgetbv` instructions, avoiding emitted forwarding helpers.
  (AstExprCpuIdEax (Box AstExpr) (Box AstExpr))
  (AstExprCpuIdEbx (Box AstExpr) (Box AstExpr))
  (AstExprCpuIdEcx (Box AstExpr) (Box AstExpr))
  (AstExprCpuIdEdx (Box AstExpr) (Box AstExpr))
  (AstExprXgetbv (Box AstExpr)))

(defenum AstExprList
  (AstExprNil)
  (AstExprCons (Box AstExpr) (Box AstExprList)))

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
  (AstSomeGeneratedDeclMeta String String AstExprList))

(defenum AstDecl
  (AstDeclModule String)
  (AstDeclDef String AstMaybeType (Box AstExpr))
  (AstDeclDefFn String AstParamList AstType (Box AstExpr))
  (AstDeclDefMacro String AstMacroParamList AstType (Box AstExpr))
  (AstDeclExtern String AstExternMetadata AstType)
  (AstDeclDefEnum String AstVariantDefList)
  (AstDeclDefEnumLifetimes String AstLifetimeList AstVariantDefList)
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
  (AstDeclTest String (Box AstExpr) AstSourceSpan)
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
  (AstTypeCons (box head) (box rest)))

(define (ast-ty-func [args : AstTypeList] [ret : AstType]) : AstType
  (AstTyFunc args (box ret)))

(define (ast-ty-array [elem : AstType] [count : i64]) : AstType
  (AstTyArray (box elem) count))

(define (ast-ty-dyn-array [elem : AstType]) : AstType
  (AstTyDynArray (box elem)))

(define (ast-ty-box [elem : AstType]) : AstType
  (AstTyBox (box elem)))

(define (ast-ty-region [region : String] [inner : AstType]) : AstType
  (AstTyRegion region (box inner)))

(define (ast-ty-ref [region : String] [inner : AstType]) : AstType
  (AstTyRef region (box inner)))

(define (ast-ty-mut-ref [region : String] [inner : AstType]) : AstType
  (AstTyMutRef region (box inner)))

(define (ast-ty-ptr [elem : AstType]) : AstType
  (AstTyPtr (box elem)))

(define (ast-ty-mut-ptr [elem : AstType]) : AstType
  (AstTyMutPtr (box elem)))

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

(define (ast-pattern-cons [head : AstPattern] [rest : AstPatternList]) : AstPatternList
  (AstPatternCons (box head) (box rest)))

(define (ast-pat-tuple [items : AstPatternList]) : AstPattern
  (AstPatTuple (box items)))

(define (ast-pat-variant [name : String] [items : AstPatternList]) : AstPattern
  (AstPatVariant name (box items)))

(define (ast-let-binding
  [name : String]
  [maybe-ty : AstMaybeType]
  [value : AstExpr]) : AstLetBinding
  (AstLetBinding name maybe-ty (box value)))

(define (ast-let-binding-cons [head : AstLetBinding] [rest : AstLetBindingList]) : AstLetBindingList
  (AstLetBindingCons head (box rest)))

(define (ast-resource-binding
  [name : String]
  [init : AstExpr]
  [cleanup : AstExpr]) : AstResourceBinding
  (AstResourceBinding name (box init) (box cleanup)))

(define (ast-resource-binding-cons
  [head : AstResourceBinding]
  [rest : AstResourceBindingList]) : AstResourceBindingList
  (AstResourceBindingCons head (box rest)))

(define (ast-match-arm [pattern : AstPattern] [body : AstExpr]) : AstMatchArm
  (AstMatchArm pattern (box body)))

(define (ast-match-arm-cons [head : AstMatchArm] [rest : AstMatchArmList]) : AstMatchArmList
  (AstMatchArmCons head (box rest)))

(define (ast-expr-cons [head : AstExpr] [rest : AstExprList]) : AstExprList
  (AstExprCons (box head) (box rest)))

(define (ast-expr-spanned [inner : AstExpr] [span : AstSourceSpan]) : AstExpr
  (AstExprSpanned (box inner) span))

(define (ast-expr-binary [op : AstBinOp] [left : AstExpr] [right : AstExpr]) : AstExpr
  (AstExprBinary op (box left) (box right)))

(define (ast-expr-unary [op : AstUnOp] [inner : AstExpr]) : AstExpr
  (AstExprUnary op (box inner)))

(define (ast-expr-call [callee : AstExpr] [args : AstExprList]) : AstExpr
  (AstExprCall (box callee) args))

(define (ast-expr-if
  [cond : AstExpr]
  [then-expr : AstExpr]
  [else-expr : AstExpr]) : AstExpr
  (AstExprIf (box cond) (box then-expr) (box else-expr)))

(define (ast-expr-let [bindings : AstLetBindingList] [body : AstExpr]) : AstExpr
  (AstExprLet bindings (box body)))

(define (ast-expr-lambda
  [params : AstParamList]
  [ret : AstMaybeType]
  [body : AstExpr]) : AstExpr
  (AstExprLambda params ret (box body)))

(define (ast-expr-tuple-ref [target : AstExpr] [index : i64]) : AstExpr
  (AstExprTupleRef (box target) index))

(define (ast-expr-make-array [elem : AstType] [size : AstExpr]) : AstExpr
  (AstExprMakeArray elem (box size)))

(define (ast-expr-array-ref [target : AstExpr] [index : AstExpr]) : AstExpr
  (AstExprArrayRef (box target) (box index)))

(define (ast-expr-array-set
  [target : AstExpr]
  [index : AstExpr]
  [value : AstExpr]) : AstExpr
  (AstExprArraySet (box target) (box index) (box value)))

(define (ast-expr-array-push [target : AstExpr] [value : AstExpr]) : AstExpr
  (AstExprArrayPush (box target) (box value)))

(define (ast-expr-string-ref [target : AstExpr] [index : AstExpr]) : AstExpr
  (AstExprStringRef (box target) (box index)))

(define (ast-expr-while [cond : AstExpr] [body : AstExpr]) : AstExpr
  (AstExprWhile (box cond) (box body)))

(define (ast-expr-set [name : String] [value : AstExpr]) : AstExpr
  (AstExprSet name (box value)))

(define (ast-expr-ann [expr : AstExpr] [ty : AstType]) : AstExpr
  (AstExprAnn (box expr) ty))

(define (ast-expr-cast [expr : AstExpr] [ty : AstType]) : AstExpr
  (AstExprCast (box expr) ty))

(define (ast-expr-borrow [lifetime : AstBorrowLifetime] [expr : AstExpr]) : AstExpr
  (AstExprBorrow lifetime (box expr)))

(define (ast-expr-match [scrutinee : AstExpr] [arms : AstMatchArmList]) : AstExpr
  (AstExprMatch (box scrutinee) arms))

(define (ast-expr-foreach
  [name : String]
  [index-ty : AstType]
  [start : AstExpr]
  [end : AstExpr]
  [body : AstExpr]) : AstExpr
  (AstExprForeach name index-ty (box start) (box end) (box body)))

(define (ast-expr-spmd-reduce
  [op : AstReduceOp]
  [name : String]
  [index-ty : AstType]
  [start : AstExpr]
  [end : AstExpr]
  [init : AstExpr]
  [value : AstExpr]) : AstExpr
  (AstExprSpmdReduce
    op
    name
    index-ty
    (box start)
    (box end)
    (box init)
    (box value)))

(define (ast-expr-struct-get [target : AstExpr] [field : String]) : AstExpr
  (AstExprStructGet (box target) field))

(define (ast-expr-with-escape [escape : AstExpr] [body : AstExprList]) : AstExpr
  (AstExprWithEscape (box escape) body))

(define (ast-expr-box [value : AstExpr]) : AstExpr
  (AstExprBox (box value)))

(define (ast-expr-box-get [value : AstExpr]) : AstExpr
  (AstExprBoxGet (box value)))

(define (ast-expr-comptime [inner : AstExpr]) : AstExpr
  (AstExprComptime (box inner)))

(define (ast-expr-quote [inner : AstExpr]) : AstExpr
  (AstExprQuote (box inner)))

(define (ast-expr-quasiquote [inner : AstExpr]) : AstExpr
  (AstExprQuasiquote (box inner)))

(define (ast-expr-unquote [inner : AstExpr]) : AstExpr
  (AstExprUnquote (box inner)))

(define (ast-expr-unquote-splicing [inner : AstExpr]) : AstExpr
  (AstExprUnquoteSplicing (box inner)))

(define (ast-expr-try [inner : AstExpr]) : AstExpr
  (AstExprTry (box inner)))

(define (ast-expr-return [inner : AstExpr]) : AstExpr
  (AstExprReturn (box inner)))

(define (ast-expr-ptr-null-check [ptr : AstExpr]) : AstExpr
  (AstExprPtrNullCheck (box ptr)))

(define (ast-expr-ptr-read [ptr : AstExpr]) : AstExpr
  (AstExprPtrRead (box ptr)))

(define (ast-expr-ptr-write [ptr : AstExpr] [value : AstExpr]) : AstExpr
  (AstExprPtrWrite (box ptr) (box value)))

(define (ast-expr-ptr-offset [ptr : AstExpr] [offset : AstExpr]) : AstExpr
  (AstExprPtrOffset (box ptr) (box offset)))

(define (ast-expr-ptr-cast [ptr : AstExpr] [ty : AstType]) : AstExpr
  (AstExprPtrCast (box ptr) ty))

(define (ast-expr-ptr-to-int [ptr : AstExpr]) : AstExpr
  (AstExprPtrToInt (box ptr)))

(define (ast-expr-int-to-ptr [value : AstExpr] [ty : AstType]) : AstExpr
  (AstExprIntToPtr (box value) ty))

(define (ast-expr-string-data [value : AstExpr]) : AstExpr
  (AstExprStringData (box value)))

(define (ast-expr-string-from-bytes [data : AstExpr] [len : AstExpr]) : AstExpr
  (AstExprStringFromBytes (box data) (box len)))

(define (ast-expr-array-data [value : AstExpr]) : AstExpr
  (AstExprArrayData (box value)))

(define (ast-expr-cpuid-eax [leaf : AstExpr] [subleaf : AstExpr]) : AstExpr
  (AstExprCpuIdEax (box leaf) (box subleaf)))

(define (ast-expr-cpuid-ebx [leaf : AstExpr] [subleaf : AstExpr]) : AstExpr
  (AstExprCpuIdEbx (box leaf) (box subleaf)))

(define (ast-expr-cpuid-ecx [leaf : AstExpr] [subleaf : AstExpr]) : AstExpr
  (AstExprCpuIdEcx (box leaf) (box subleaf)))

(define (ast-expr-cpuid-edx [leaf : AstExpr] [subleaf : AstExpr]) : AstExpr
  (AstExprCpuIdEdx (box leaf) (box subleaf)))

(define (ast-expr-xgetbv [index : AstExpr]) : AstExpr
  (AstExprXgetbv (box index)))

(define (ast-export-item-cons [head : AstExportItem] [rest : AstExportItemList]) : AstExportItemList
  (AstExportItemCons head (box rest)))

(define (ast-dispatch-variant-cons
  [head : AstDispatchVariant]
  [rest : AstDispatchVariantList]) : AstDispatchVariantList
  (AstDispatchVariantCons head (box rest)))

(define (ast-decl-cons [head : AstDecl] [rest : AstDeclList]) : AstDeclList
  (AstDeclCons head (box rest)))

(define (ast-decl-def
  [name : String]
  [maybe-ty : AstMaybeType]
  [value : AstExpr]) : AstDecl
  (AstDeclDef name maybe-ty (box value)))

(define (ast-decl-def-fn
  [name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : AstExpr]) : AstDecl
  (AstDeclDefFn name params ret (box body)))

(define (ast-decl-def-macro
  [name : String]
  [params : AstMacroParamList]
  [ret : AstType]
  [body : AstExpr]) : AstDecl
  (AstDeclDefMacro name params ret (box body)))

(define (ast-decl-test [name : String] [body : AstExpr] [span : AstSourceSpan]) : AstDecl
  (AstDeclTest name (box body) span))

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
    [(AstExprBorrow _ _) 40]
    [(AstExprMatch _ _) 22]
    [(AstExprForeach _ _ _ _ _) 23]
    [(AstExprStructGet _ _) 24]
    [(AstExprWithRegion _ _) 25]
    [(AstExprWithEscape _ _) 48]
    [(AstExprTypeLiteral _) 26]
    [(AstExprComptime _) 27]
    [(AstExprSpmdReduce _ _ _ _ _ _ _) 28]
    [(AstExprTry _) 29]
    [(AstExprReturn _) 48]
    [(AstExprPtrNull _) 30]
    [(AstExprPtrNullCheck _) 31]
    [(AstExprWithResource _ _) 33]
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
    [(AstExprXgetbv _) 59]))

(define (ast-expr-unspan [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-unspan inner))]
    [_ expr]))

(define (ast-decl-tag [decl : AstDecl]) : i64
  (match decl
    [(AstDeclDef _ _ _) 1]
    [(AstDeclDefFn _ _ _ _) 2]
    [(AstDeclDefMacro _ _ _ _) 10]
    [(AstDeclExtern _ _ _) 3]
    [(AstDeclDefEnum _ _) 4]
    [(AstDeclDefStruct _ _ _ _) 5]
    [(AstDeclImport _) 6]
    [(AstDeclTest _ _ _) 7]
    [(AstDeclComptimeDecl _ _) 8]
    [(AstDeclModule _) 9]
    [(AstDeclExport _) 11]
    [(AstDeclIncludeStr _ _) 12]
    [(AstDeclUnsafe _) 13]
    [(AstDeclDefEnumLifetimes _ _ _) 14]
    [(AstDeclDefStructLifetimes _ _ _ _ _) 15]
    [(AstDeclDefDispatch _ _) 16]))

(define (ast-struct-repr-c? [repr : AstStructRepr]) : bool
  (match repr
    [(AstStructReprC) true]
    [(AstStructReprDefault) false]))

(define (ast-extern-abi-c? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiC) true]
    [(AstExternAbiCVarargs _) true]))

(define (ast-extern-abi-c-varargs? [abi : AstExternAbi]) : bool
  (match abi
    [(AstExternAbiC) false]
    [(AstExternAbiCVarargs _) true]))

(define (ast-extern-abi-varargs-fixed-count [abi : AstExternAbi]) : i64
  (match abi
    [(AstExternAbiC) 0]
    [(AstExternAbiCVarargs fixed-count) fixed-count]))

(define (ast-extern-abi-eq? [a : AstExternAbi] [b : AstExternAbi]) : bool
  (match a
    [(AstExternAbiC)
      (match b
        [(AstExternAbiC) true]
        [_ false])]
    [(AstExternAbiCVarargs afixed)
      (match b
        [(AstExternAbiCVarargs bfixed) (= afixed bfixed)]
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
  (AstExternMetadata (AstExternAbiC) name AstExternLinkInputNil))

(define (ast-extern-metadata-symbol [metadata : AstExternMetadata]) : String
  (match metadata
    [(AstExternMetadata _ symbol _) symbol]))

(define (ast-extern-metadata-abi [metadata : AstExternMetadata]) : AstExternAbi
  (match metadata
    [(AstExternMetadata abi _ _) abi]))

(define (ast-extern-metadata-link-inputs [metadata : AstExternMetadata]) : AstExternLinkInputList
  (match metadata
    [(AstExternMetadata _ _ link-inputs) link-inputs]))

(define (ast-struct-cleanup? [cleanup : AstStructCleanup]) : bool
  (match cleanup
    [(AstStructCleanupFn _) true]
    [(AstStructNoCleanup) false]))

(define (ast-field-cleanup? [cleanup : AstFieldCleanup]) : bool
  (match cleanup
    [(AstFieldCleanupFn _) true]
    [(AstFieldOwnedCleanup) true]
    [(AstFieldNoCleanup) false]))

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
            [(AstMatchArm pattern body-box)
              (let
                [body : AstExpr (box-get body-box)]
                (and
                  (compiler-ast-nested-pattern-box-ok? pattern)
                  (compiler-ast-begin-expr? body)))]
            [_ false])))]
    [_ false]))

(define (compiler-ast-nested-expr-box-ok? [expr : AstExpr]) : bool
  (match expr
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
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
                        [init : AstExpr (box-get init-box)]
                        (and
                          (string-eq name "x")
                          (compiler-ast-begin-expr? init)))]
                    [_ false])))]
            [_ false])
          (match body
            [(AstExprIf cond-box then-box else-box)
              (let
                [cond : AstExpr (box-get cond-box)]
                [then-expr : AstExpr (box-get then-box)]
                [else-expr : AstExpr (box-get else-box)]
                (and
                  (match cond
                    [(AstExprVar name) (string-eq name "cond")]
                    [_ false])
                  (and
                    (match then-expr
                      [(AstExprMatch scrut-box arms)
                        (let
                          [scrut : AstExpr (box-get scrut-box)]
                          (and
                            (match scrut
                              [(AstExprVar name) (string-eq name "input")]
                              [_ false])
                            (compiler-ast-single-arm-box-ok? arms)))]
                      [_ false])
                    (compiler-ast-begin-expr? else-expr))))]
            [_ false])))]
    [_ false]))

(define (compiler-ast-expr-pattern-box-smoke?) : bool
  (let
    [one : AstExpr (AstExprLiteral (AstLitInt 1))]
    [two : AstExpr (AstExprLiteral (AstLitInt 2))]
    [begin-expr : AstExpr
      (AstExprBegin (ast-expr-cons one (ast-expr-cons two AstExprNil)))]
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
    [match-expr : AstExpr (ast-expr-match (AstExprVar "input") arms)]
    [nested : AstExpr
      (ast-expr-let
        bindings
        (ast-expr-if (AstExprVar "cond") match-expr begin-expr))]
    (compiler-ast-nested-expr-box-ok? nested)))

(define (compiler-ast-decl-def-lit-ok?
  [decl : AstDecl]
  [want-name : String]
  [want-value : i64]) : bool
  (match decl
    [(AstDeclDef name _ value-box)
      (let
        [value : AstExpr (box-get value-box)]
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
        (AstExprLiteral (AstLitInt 7)))]
    [runtime : AstDecl
      (ast-decl-def
        "runtime"
        (AstSomeType (AstTyI64))
        (AstExprLiteral (AstLitInt 9)))]
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
          (match (box-get ret)
            [(AstTyRef region ptr)
              (and
                (string-eq region "r")
                (match (box-get ptr)
                  [(AstTyPtr array)
                    (match (box-get array)
                      [(AstTyArray elem count)
                        (and
                          (= count 4)
                          (match (box-get elem)
                            [(AstTyI64) true]
                            [_ false]))]
                      [_ false])]
                  [_ false]))]
            [_ false])]
        [_ false])]
    [lit : AstLiteral (AstLitInt 41)]
    [one : AstExpr (AstExprLiteral (AstLitInt 1))]
    [expr : AstExpr (ast-expr-binary (AstBinAdd) (AstExprLiteral lit) one)]
    [nested-expr-pattern-ok? : bool (compiler-ast-expr-pattern-box-smoke?)]
    [decl-program-ok? : bool (compiler-ast-decl-program-box-smoke?)]
    [param : AstParam (AstParam "x" i64-ty false)]
    [params : AstParamList (ast-param-cons param AstParamNil)]
    [decl : AstDecl (ast-decl-def-fn "main" params i64-ty expr)]
    [program : AstProgram (ast-program (ast-decl-cons decl AstDeclNil))]
    (match program
      [(AstProgram _)
        (if (and nested-ty-ok? (and nested-expr-pattern-ok? decl-program-ok?))
          (+ (ast-type-tag fn-ty) (+ (ast-expr-tag expr) (ast-decl-tag decl)))
          0)])))