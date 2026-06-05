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
  (AstTyStruct String)
  (AstTyVar String)
  (AstTyPtr (Box AstType))
  (AstTyMutPtr (Box AstType)))

(defenum AstTypeList
  (AstTypeNil)
  (AstTypeCons AstType (Box AstTypeList)))

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
  (AstPatTuple AstPatternList)
  (AstPatWildcard)
  (AstPatBinding String)
  (AstPatVariant String AstPatternList)
  (AstPatLiteral AstLiteral))

(defenum AstPatternList
  (AstPatternNil)
  (AstPatternCons AstPattern (Box AstPatternList)))

(defenum AstLetBinding
  (AstLetBinding String AstMaybeType AstExpr))

(defenum AstLetBindingList
  (AstLetBindingNil)
  (AstLetBindingCons AstLetBinding (Box AstLetBindingList)))

(defenum AstResourceBinding
  (AstResourceBinding String AstExpr AstExpr))

(defenum AstResourceBindingList
  (AstResourceBindingNil)
  (AstResourceBindingCons AstResourceBinding (Box AstResourceBindingList)))

(defenum AstMatchArm
  (AstMatchArm AstPattern AstExpr))

(defenum AstMatchArmList
  (AstMatchArmNil)
  (AstMatchArmCons AstMatchArm (Box AstMatchArmList)))

(defenum AstExpr
  (AstExprSpanned AstExpr AstSourceSpan)
  (AstExprLiteral AstLiteral)
  (AstExprVar String)
  (AstExprBinary AstBinOp AstExpr AstExpr)
  (AstExprUnary AstUnOp AstExpr)
  (AstExprCall AstExpr AstExprList)
  (AstExprIf AstExpr AstExpr AstExpr)
  (AstExprLet AstLetBindingList AstExpr)
  (AstExprLambda AstParamList AstMaybeType AstExpr)
  (AstExprTuple AstExprList)
  (AstExprTupleRef AstExpr i64)
  (AstExprArray AstExprList)
  (AstExprMakeArray AstType AstExpr)
  (AstExprArrayRef AstExpr AstExpr)
  (AstExprArraySet AstExpr AstExpr AstExpr)
  (AstExprArrayPush AstExpr AstExpr)
  (AstExprStringRef AstExpr AstExpr)
  (AstExprWhile AstExpr AstExpr)
  (AstExprBegin AstExprList)
  ;; `(unsafe expr+)` (#1053): a `begin`-like block that additionally marks an
  ;; unsafe context (v1 has the same runtime/type behavior as `begin`; the
  ;; unsafe-context flag is consumed by later raw-pointer ops, #955).
  (AstExprUnsafe AstExprList)
  (AstExprSet String AstExpr)
  (AstExprAnn AstExpr AstType)
  (AstExprCast AstExpr AstType)
  (AstExprBorrow AstBorrowLifetime AstExpr)
  (AstExprMatch AstExpr AstMatchArmList)
  (AstExprForeach String AstType AstExpr AstExpr AstExpr)
  (AstExprSpmdReduce AstReduceOp String AstType AstExpr AstExpr AstExpr AstExpr)
  (AstExprStructGet AstExpr String)
  (AstExprWithRegion String AstExprList)
  (AstExprWithEscape AstExpr AstExprList)
  (AstExprWithResource AstResourceBindingList AstExprList)
  (AstExprBox AstExpr)
  (AstExprBoxGet AstExpr)
  ;; Compile-time-only type value literal: `(type T)`.
  (AstExprTypeLiteral AstType)
  ;; Reserved compile-time evaluation form `(comptime expr)` (#718). Parsed and
  ;; type-checked (as the inner expression's type); evaluation lands in #719.
  (AstExprComptime AstExpr)
  ;; Macro quote syntax (#1136). The reader desugars prefix quote tokens into
  ;; these list-headed forms before parsing:
  ;;   'x       -> (quote x)
  ;;   `x       -> (quasiquote x)
  ;;   ,x       -> (unquote x)
  ;;   ,@xs     -> (unquote-splicing xs)
  (AstExprQuote AstExpr)
  (AstExprQuasiquote AstExpr)
  (AstExprUnquote AstExpr)
  (AstExprUnquoteSplicing AstExpr)
  ;; Narrow Result-like propagation form `(try expr)` (#903). The temporary
  ;; convention recognizes concrete enums with one `Ok*` and one `Err*`
  ;; variant, each carrying exactly one payload.
  (AstExprTry AstExpr)
  ;; General function-local early exit: `(return expr)` checks `expr` against
  ;; the enclosing function's return type and has the internal `never` type.
  (AstExprReturn AstExpr)
  ;; Null raw-pointer construction `(ptr-null : T)` where `T` is `(Ptr U)` or
  ;; `(MutPtr U)` (#1054). Lowers to a pointer-sized zero; type is `T`.
  (AstExprPtrNull AstType)
  ;; Null check `(ptr-null? p)` on a raw pointer (#1054). Result is `bool`.
  (AstExprPtrNullCheck AstExpr)
  ;; Unsafe raw-pointer operations (#1055). The typechecker admits these only
  ;; inside `(unsafe ...)`; lowering maps them to existing pointer IR.
  (AstExprPtrRead AstExpr)
  (AstExprPtrWrite AstExpr AstExpr)
  (AstExprPtrOffset AstExpr AstExpr)
  (AstExprPtrCast AstExpr AstType)
  (AstExprPtrToInt AstExpr)
  (AstExprIntToPtr AstExpr AstType)
  ;; Low-level FFI bridge operations used by stdlib. These expose raw backing
  ;; storage and process entry state without synthesizing runtime wrapper calls.
  (AstExprStringData AstExpr)
  (AstExprStringFromBytes AstExpr AstExpr)
  (AstExprArrayData AstExpr)
  (AstExprProgramArgc)
  (AstExprProgramArgv)
  (AstExprProgramEnvp)
  ;; Inline CPU feature instructions. These lower directly to x86_64 `cpuid`
  ;; and `xgetbv` instructions, avoiding emitted forwarding helpers.
  (AstExprCpuIdEax AstExpr AstExpr)
  (AstExprCpuIdEbx AstExpr AstExpr)
  (AstExprCpuIdEcx AstExpr AstExpr)
  (AstExprCpuIdEdx AstExpr AstExpr)
  (AstExprXgetbv AstExpr))

(defenum AstExprList
  (AstExprNil)
  (AstExprCons AstExpr (Box AstExprList)))

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

(defenum AstDecl
  (AstDeclModule String)
  (AstDeclDef String AstMaybeType AstExpr)
  (AstDeclDefFn String AstParamList AstType AstExpr)
  (AstDeclDefMacro String AstMacroParamList AstType AstExpr)
  (AstDeclExtern String AstExternMetadata AstType)
  (AstDeclDefEnum String AstVariantDefList)
  (AstDeclDefStruct String AstStructRepr AstStructCleanup AstFieldDefList)
  (AstDeclImport AstImportSpec)
  (AstDeclIncludeStr String String)
  (AstDeclExport AstExportItemList)
  (AstDeclTest String AstExpr AstSourceSpan)
  (AstDeclUnsafe AstDecl)
  (AstDeclComptimeDecl AstDecl))

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
  (AstProgram AstDeclList))

(define (ast-type-cons [head : AstType] [rest : AstTypeList]) : AstTypeList
  (AstTypeCons head (box rest)))

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
  (AstPatternCons head (box rest)))

(define (ast-let-binding-cons [head : AstLetBinding] [rest : AstLetBindingList]) : AstLetBindingList
  (AstLetBindingCons head (box rest)))

(define (ast-resource-binding-cons
  [head : AstResourceBinding]
  [rest : AstResourceBindingList]) : AstResourceBindingList
  (AstResourceBindingCons head (box rest)))

(define (ast-match-arm-cons [head : AstMatchArm] [rest : AstMatchArmList]) : AstMatchArmList
  (AstMatchArmCons head (box rest)))

(define (ast-expr-cons [head : AstExpr] [rest : AstExprList]) : AstExprList
  (AstExprCons head (box rest)))

(define (ast-export-item-cons [head : AstExportItem] [rest : AstExportItemList]) : AstExportItemList
  (AstExportItemCons head (box rest)))

(define (ast-decl-cons [head : AstDecl] [rest : AstDeclList]) : AstDeclList
  (AstDeclCons head (box rest)))

(define (ast-decl-path-cons [head : String] [rest : AstDeclPathList]) : AstDeclPathList
  (AstDeclPathCons head (box rest)))

(define (ast-decl-module-cons [head : String] [rest : AstDeclModuleList]) : AstDeclModuleList
  (AstDeclModuleCons head (box rest)))

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
    [(AstTyBox _) 31]))

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
    [(AstExprSpanned inner _) (ast-expr-unspan inner)]
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
    [(AstDeclComptimeDecl _) 8]
    [(AstDeclModule _) 9]
    [(AstDeclExport _) 11]
    [(AstDeclIncludeStr _ _) 12]
    [(AstDeclUnsafe _) 13]))

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
    [expr : AstExpr (AstExprBinary (AstBinAdd) (AstExprLiteral lit) one)]
    [param : AstParam (AstParam "x" i64-ty false)]
    [params : AstParamList (ast-param-cons param AstParamNil)]
    [decl : AstDecl (AstDeclDefFn "main" params i64-ty expr)]
    [program : AstProgram (AstProgram (ast-decl-cons decl AstDeclNil))]
    (match program
      [(AstProgram _)
        (if nested-ty-ok?
          (+ (ast-type-tag fn-ty) (+ (ast-expr-tag expr) (ast-decl-tag decl)))
          0)])))