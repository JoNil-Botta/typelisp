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
  (AstTyUnit)
  (AstTyNever)
  (AstTyFunc AstTypeList AstType)
  (AstTyTuple AstTypeList)
  (AstTyArray AstType i64)
  (AstTyDynArray AstType)
  (AstTyRegion String AstType)
  (AstTyEnum String)
  (AstTyStruct String)
  (AstTyVar String))

(defenum AstTypeList
  (AstTypeNil)
  (AstTypeCons AstType AstTypeList))

(defenum AstMaybeType
  (AstNoType)
  (AstSomeType AstType))

(defenum AstParam
  (AstParam String AstType bool))

(defenum AstParamList
  (AstParamNil)
  (AstParamCons AstParam AstParamList))

(defenum AstFieldDef
  (AstFieldDef String AstType))

(defenum AstFieldDefList
  (AstFieldDefNil)
  (AstFieldDefCons AstFieldDef AstFieldDefList))

(defenum AstVariantDef
  (AstVariantDef String AstTypeList))

(defenum AstVariantDefList
  (AstVariantDefNil)
  (AstVariantDefCons AstVariantDef AstVariantDefList))

(defenum AstPattern
  (AstPatVar String AstMaybeType)
  (AstPatTuple AstPatternList)
  (AstPatWildcard)
  (AstPatBinding String)
  (AstPatVariant String AstPatternList)
  (AstPatLiteral AstLiteral))

(defenum AstPatternList
  (AstPatternNil)
  (AstPatternCons AstPattern AstPatternList))

(defenum AstLetBinding
  (AstLetBinding String AstMaybeType AstExpr))

(defenum AstLetBindingList
  (AstLetBindingNil)
  (AstLetBindingCons AstLetBinding AstLetBindingList))

(defenum AstMatchArm
  (AstMatchArm AstPattern AstExpr))

(defenum AstMatchArmList
  (AstMatchArmNil)
  (AstMatchArmCons AstMatchArm AstMatchArmList))

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
  (AstExprStringRef AstExpr AstExpr)
  (AstExprWhile AstExpr AstExpr)
  (AstExprBegin AstExprList)
  (AstExprSet String AstExpr)
  (AstExprAnn AstExpr AstType)
  (AstExprCast AstExpr AstType)
  (AstExprMatch AstExpr AstMatchArmList)
  (AstExprForeach String AstType AstExpr AstExpr AstExpr)
  (AstExprSpmdReduce AstReduceOp String AstType AstExpr AstExpr AstExpr AstExpr)
  (AstExprStructGet AstExpr String)
  (AstExprWithRegion String AstExprList)
  ;; Compile-time-only type value literal: `(type T)`.
  (AstExprTypeLiteral AstType)
  ;; Reserved compile-time evaluation form `(comptime expr)` (#718). Parsed and
  ;; type-checked (as the inner expression's type); evaluation lands in #719.
  (AstExprComptime AstExpr))

(defenum AstExprList
  (AstExprNil)
  (AstExprCons AstExpr AstExprList))

(defenum AstDecl
  (AstDeclDef String AstMaybeType AstExpr)
  (AstDeclDefFn String AstParamList AstType AstExpr)
  (AstDeclExtern String AstType)
  (AstDeclDefEnum String AstVariantDefList)
  (AstDeclDefStruct String AstFieldDefList)
  (AstDeclImport String)
  (AstDeclTest String AstExpr AstSourceSpan)
  (AstDeclComptimeDecl AstDecl))

(defenum AstDeclList
  (AstDeclNil)
  (AstDeclCons AstDecl AstDeclList))

(defenum AstDeclPathList
  (AstDeclPathNil)
  (AstDeclPathCons String AstDeclPathList))

(defenum AstProgram
  (AstProgram AstDeclList))

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
    [(AstTyUnit) 14]
    [(AstTyNever) 15]
    [(AstTyFunc _ _) 16]
    [(AstTyTuple _) 17]
    [(AstTyArray _ _) 18]
    [(AstTyDynArray _) 19]
    [(AstTyRegion _ _) 20]
    [(AstTyEnum _) 21]
    [(AstTyStruct _) 22]
    [(AstTyVar _) 23]))

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
    [(AstExprStringRef _ _) 16]
    [(AstExprWhile _ _) 17]
    [(AstExprBegin _) 18]
    [(AstExprSet _ _) 19]
    [(AstExprAnn _ _) 20]
    [(AstExprCast _ _) 21]
    [(AstExprMatch _ _) 22]
    [(AstExprForeach _ _ _ _ _) 23]
    [(AstExprStructGet _ _) 24]
    [(AstExprWithRegion _ _) 25]
    [(AstExprTypeLiteral _) 26]
    [(AstExprComptime _) 27]
    [(AstExprSpmdReduce _ _ _ _ _ _ _) 28]))

(define (ast-expr-unspan [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExprSpanned inner _) (ast-expr-unspan inner)]
    [_ expr]))

(define (ast-decl-tag [decl : AstDecl]) : i64
  (match decl
    [(AstDeclDef _ _ _) 1]
    [(AstDeclDefFn _ _ _ _) 2]
    [(AstDeclExtern _ _) 3]
    [(AstDeclDefEnum _ _) 4]
    [(AstDeclDefStruct _ _) 5]
    [(AstDeclImport _) 6]
    [(AstDeclTest _ _ _) 7]
    [(AstDeclComptimeDecl _) 8]))

(define (compiler-ast-smoke) : i64
  (let (
    [i64-ty : AstType (AstTyI64)]
    [string-ty : AstType (AstTyString)]
    [arg-tys : AstTypeList
      (AstTypeCons i64-ty (AstTypeCons string-ty AstTypeNil))]
    [fn-ty : AstType (AstTyFunc arg-tys i64-ty)]
    [lit : AstLiteral (AstLitInt 41)]
    [one : AstExpr (AstExprLiteral (AstLitInt 1))]
    [expr : AstExpr (AstExprBinary (AstBinAdd) (AstExprLiteral lit) one)]
    [param : AstParam (AstParam "x" i64-ty false)]
    [params : AstParamList (AstParamCons param AstParamNil)]
    [decl : AstDecl (AstDeclDefFn "main" params i64-ty expr)]
    [program : AstProgram (AstProgram (AstDeclCons decl AstDeclNil))])
    (match program
      [(AstProgram _)
        (+ (ast-type-tag fn-ty) (+ (ast-expr-tag expr) (ast-decl-tag decl)))])))