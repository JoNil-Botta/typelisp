;; Reverse mixed-source nominal identity regression.
(import "../compiler_typecheck_core.tl")

(define (tc-qualified-variant-member-lookup-smoke?
  [module-id : i64]
  [enum-id : i64]) : bool
  (let
    [variant-id : i64 (intern "Value")]
    [generated-variant-id : i64 (ci.intern-generated-canonical-name "Value")]
    [dotted-pattern-id : i64
      (ci.intern-generated-canonical-name "ReverseMixedItem.Value")]
    [hygienic-variant-id : i64
      (macro-hygiene-global-id
        (compiler-symbol-root-module-id)
        generated-variant-id
        false)]
    [qualified-variant-id : i64
      (compiler-symbol-module-key-id-by-id
        module-id
        (compiler-enum-qualified-variant-name-id enum-id hygienic-variant-id))]
    [qualified-variants : AstVariantDefList (ast-variant-def-list-new)]
    [enum-handle : i64
      (compiler-symbol-make-handle (compiler-symbol-kind-defenum) 0)]
    (begin
      (ast-variant-def-list-push
        (&mut qualified-variants)
        (AstVariantDef.Def
          qualified-variant-id
          (ast-type-list-new)
          (ast-variant-payload-cleanup-list-new)))
      (and
        (not (= variant-id generated-variant-id))
        (match (tc-variant-handle-in-list-at
          enum-handle
          variant-id
          (& qualified-variants)
          0)
          [(option_i64.Some _) true]
          [(option_i64.None) false])
        (match (tc-variant-handle-in-list-at
          enum-handle
          dotted-pattern-id
          (& qualified-variants)
          0)
          [(option_i64.Some _) true]
          [(option_i64.None) false])
        (match (tc-variant-handle-in-list-at
          enum-handle
          (intern "Missing")
          (& qualified-variants)
          0)
          [(option_i64.Some _) false]
          [(option_i64.None) true])))))

(define (tc-reverse-mixed-source-nominal-match-smoke?) : bool
  (match (parse-ast-source
    "(defenum ReverseMixedItem (Value i64))
(import \"reverse_mixed.tl\" module reverse.mixed :as reverse)
(module reverse.mixed)
(defenum ReverseMixedItem (Value i64))
(defenum ReverseMixedOther (Value i64))")
    [(ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (let
                [flat-id : i64 (intern "ReverseMixedItem")]
                [ctx : TcContext
                  (tc-context-new
                    program
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast-node-pool-context-capture-active))]
                [parsed-module-id : i64
                  (match program
                    [(AstProgram.Program decls-box)
                      (match (ast-decl-list-ref (box-get decls-box) 1)
                        [(AstDecl.Import
                            _
                            (AstImportSpec.Spec
                              _
                              _
                              (AstMaybeModuleName.Some target)
                              _
                              _))
                          target]
                        [_ -1])])]
                [module-id : i64
                  (ci.intern-generated-canonical-name
                    (intern-str parsed-module-id))]
                [qualified-id : i64
                  (compiler-symbol-module-key-id-by-id module-id flat-id)]
                [other-qualified-id : i64
                  (compiler-symbol-module-key-id-by-id
                    module-id
                    (intern "ReverseMixedOther"))]
                [actual : AstType (ast-ty-array (AstType.Enum flat-id) 1)]
                [expected : AstType
                  (ast-ty-array (AstType.Enum qualified-id) 1)]
                [different : AstType
                  (ast-ty-array (AstType.Enum other-qualified-id) 1)]
                [lifetime-id : i64 (intern "out")]
                [type-module-ctx : TcContext
                  (tc-context-with-type-module-id ctx module-id)]
                [actual-ref : AstType
                  (ast-ty-mut-ref lifetime-id (AstType.Enum flat-id))]
                [expected-ref : AstType
                  (ast-ty-mut-ref lifetime-id (AstType.Enum qualified-id))]
                [different-ref : AstType
                  (ast-ty-mut-ref lifetime-id (AstType.Enum other-qualified-id))]
                [other-constructor-id : i64
                  (ci.intern-generated-canonical-name "ReverseMixedOther.Value")]
                [missing-constructor-id : i64
                  (ci.intern-generated-canonical-name
                    "ReverseMixedOther.Missing")]
                (and
                  (tc-nominal-name-id-canonical-eq? ctx flat-id qualified-id)
                  (tc-nominal-name-id-canonical-eq? ctx qualified-id flat-id)
                  (not
                    (tc-nominal-name-id-canonical-eq?
                      ctx
                      flat-id
                      other-qualified-id))
                  (match (tc-match-inferred-type-for-expected
                    ctx
                    actual
                    expected)
                    [(TcInferredTypeMatch.Compatible _) true]
                    [(TcInferredTypeMatch.Mismatch _) false])
                  (match (tc-match-inferred-type-for-expected
                    ctx
                    expected
                    actual)
                    [(TcInferredTypeMatch.Compatible _) true]
                    [(TcInferredTypeMatch.Mismatch _) false])
                  (match (tc-match-inferred-type-for-expected
                    ctx
                    actual
                    different)
                    [(TcInferredTypeMatch.Compatible _) false]
                    [(TcInferredTypeMatch.Mismatch _) true])
                  (match (tc-match-inferred-type-for-expected
                    type-module-ctx
                    actual-ref
                    expected-ref)
                    [(TcInferredTypeMatch.Compatible _) true]
                    [(TcInferredTypeMatch.Mismatch _) false])
                  (match (tc-match-inferred-type-for-expected
                    type-module-ctx
                    actual-ref
                    different-ref)
                    [(TcInferredTypeMatch.Compatible _) false]
                    [(TcInferredTypeMatch.Mismatch _) true])
                  (match (tc-infer-lifetime-subst-from-mixed-source-type
                    type-module-ctx
                    (ast-lifetime-list-new)
                    TcLifetimeSubst.Nil
                    actual-ref
                    expected-ref)
                    [(ResultTcLifetimeSubst.Ok _) true]
                    [(ResultTcLifetimeSubst.Err _) false])
                  (match (tc-infer-lifetime-subst-from-mixed-source-type
                    type-module-ctx
                    (ast-lifetime-list-new)
                    TcLifetimeSubst.Nil
                    actual-ref
                    different-ref)
                    [(ResultTcLifetimeSubst.Ok _) false]
                    [(ResultTcLifetimeSubst.Err _) true])
                  (match (tc-enum-qualified-variant-lookup-key-id
                    ctx
                    other-constructor-id
                    (tc-context-module-id ctx))
                    [(option_i64.Some _) false]
                    [(option_i64.None) true])
                  (match (tc-enum-qualified-variant-lookup-handle
                    ctx
                    other-constructor-id)
                    [(option_i64.Some _) false]
                    [(option_i64.None) true])
                  (match (tc-enum-qualified-variant-constructor-handle
                    ctx
                    other-constructor-id)
                    [(option_i64.Some _) true]
                    [(option_i64.None) false])
                  (match (tc-source-lookup-error-or-variant-constructor
                    ctx
                    other-constructor-id
                    "missing constructor")
                    [(ResultTcType.Ok _) true]
                    [(ResultTcType.Err _) false])
                  (match (tc-enum-qualified-variant-lookup-handle
                    ctx
                    missing-constructor-id)
                    [(option_i64.Some _) false]
                    [(option_i64.None) true])
                  (match (tc-enum-qualified-variant-constructor-handle
                    ctx
                    missing-constructor-id)
                    [(option_i64.Some _) false]
                    [(option_i64.None) true])
                  (match (tc-source-lookup-error-or-variant-constructor
                    ctx
                    missing-constructor-id
                    "missing constructor")
                    [(ResultTcType.Ok _) false]
                    [(ResultTcType.Err _) true])
                  (tc-qualified-variant-member-lookup-smoke? module-id flat-id)))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(test
  compiler-typecheck-reverse-mixed-source-nominal-match
  (if (tc-reverse-mixed-source-nominal-match-smoke?)
    unit
    (io.panic "typecheck: reverse mixed-source nominal match failed")))