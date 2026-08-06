;; Reverse mixed-source nominal identity regression.
(import compiler_typecheck_core)
(import compiler_intern as ci)
(import compiler_symbols as csym)
(import compiler_ast_types as ast)
(import compiler_parse_core as parser)
(import compiler_builtin_ids as cbi)
(import stdlib.io)

(define (tc-qualified-variant-member-lookup-smoke?
  [module-id : i64]
  [enum-id : i64]) : bool
  (let
    [variant-id : i64 (ci.intern "Value")]
    [generated-variant-id : i64 (ci.intern-generated-canonical-name "Value")]
    [dotted-pattern-id : i64
      (ci.intern-generated-canonical-name "ReverseMixedItem.Value")]
    [hygienic-variant-id : i64
      (compiler_typecheck_core.macro-hygiene-global-id
        (csym.compiler-symbol-root-module-id)
        generated-variant-id
        false)]
    [qualified-variant-id : i64
      (csym.compiler-symbol-module-key-id-by-id
        module-id
        (csym.compiler-enum-qualified-variant-name-id
          enum-id
          hygienic-variant-id))]
    [qualified-variants : ast.AstVariantDefList (ast.ast-variant-def-list-new)]
    [enum-handle : i64
      (csym.compiler-symbol-make-handle (csym.compiler-symbol-kind-defenum) 0)]
    (begin
      (ast.ast-variant-def-list-push
        (&mut qualified-variants)
        (ast.AstVariantDef.Def
          qualified-variant-id
          (ast.ast-type-list-new)
          (ast.ast-variant-payload-cleanup-list-new)))
      (and
        (not (= variant-id generated-variant-id))
        (match (compiler_typecheck_core.tc-variant-handle-in-list-at
          enum-handle
          variant-id
          (& qualified-variants)
          0)
          [(option_i64.Some _) true]
          [(option_i64.None) false])
        (match (compiler_typecheck_core.tc-variant-handle-in-list-at
          enum-handle
          dotted-pattern-id
          (& qualified-variants)
          0)
          [(option_i64.Some _) true]
          [(option_i64.None) false])
        (match (compiler_typecheck_core.tc-variant-handle-in-list-at
          enum-handle
          (ci.intern "Missing")
          (& qualified-variants)
          0)
          [(option_i64.Some _) false]
          [(option_i64.None) true])))))

(define (tc-reverse-mixed-source-nominal-match-smoke?) : bool
  (match (parser.parse-ast-source
    "(defenum ReverseMixedItem (Value i64))
(import reverse.mixed as reverse)
(module reverse.mixed)
(defenum ReverseMixedItem (Value i64))
(defenum ReverseMixedOther (Value i64))")
    [(parser.ResultAstProgram.Ok program)
      (match (csym.build-compiler-symbols program)
        [(csym.ResultCompilerSymbols.Ok symbols)
          (match (csym.build-compiler-registries program)
            [(csym.ResultCompilerRegistries.Ok registries)
              (let
                [flat-id : i64 (ci.intern "ReverseMixedItem")]
                [ctx : compiler_typecheck_core.TcContext
                  (compiler_typecheck_core.tc-context-new
                    program
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                [parsed-module-id : i64
                  (match program
                    [(ast.AstProgram.Program decls-box)
                      (match (ast.ast-decl-list-ref (box-get decls-box) 1)
                        [(ast.AstDecl.Import
                            _
                            (ast.AstImportSpec.Spec
                              _
                              _
                              (ast.AstMaybeModuleName.Some target)
                              _
                              _))
                          target]
                        [_ -1])])]
                [module-id : i64
                  (ci.intern-generated-canonical-name
                    (ci.intern-str parsed-module-id))]
                [qualified-id : i64
                  (csym.compiler-symbol-module-key-id-by-id module-id flat-id)]
                [other-qualified-id : i64
                  (csym.compiler-symbol-module-key-id-by-id
                    module-id
                    (ci.intern "ReverseMixedOther"))]
                [actual : ast.AstType
                  (ast.ast-ty-array (ast.AstType.Enum flat-id) 1)]
                [expected : ast.AstType
                  (ast.ast-ty-array (ast.AstType.Enum qualified-id) 1)]
                [different : ast.AstType
                  (ast.ast-ty-array (ast.AstType.Enum other-qualified-id) 1)]
                [lifetime-id : i64 (ci.intern "out")]
                [type-module-ctx : compiler_typecheck_core.TcContext
                  (compiler_typecheck_core.tc-context-with-type-module-id
                    ctx
                    module-id)]
                [type-env : compiler_typecheck_core.TcTypeEnv
                  (compiler_typecheck_core.tc-default-env)]
                [actual-ref : ast.AstType
                  (ast.ast-ty-mut-ref lifetime-id (ast.AstType.Enum flat-id))]
                [expected-ref : ast.AstType
                  (ast.ast-ty-mut-ref
                    lifetime-id
                    (ast.AstType.Enum qualified-id))]
                [different-ref : ast.AstType
                  (ast.ast-ty-mut-ref
                    lifetime-id
                    (ast.AstType.Enum other-qualified-id))]
                [other-constructor-id : i64
                  (ci.intern-generated-canonical-name "ReverseMixedOther.Value")]
                [missing-constructor-id : i64
                  (ci.intern-generated-canonical-name
                    "ReverseMixedOther.Missing")]
                (and
                  (compiler_typecheck_core.tc-nominal-name-id-canonical-eq?
                    ctx
                    flat-id
                    qualified-id)
                  (compiler_typecheck_core.tc-nominal-name-id-canonical-eq?
                    ctx
                    qualified-id
                    flat-id)
                  (not
                    (compiler_typecheck_core.tc-nominal-name-id-canonical-eq?
                      ctx
                      flat-id
                      other-qualified-id))
                  (match (compiler_typecheck_core.tc-match-inferred-type-for-expected
                    ctx
                    type-env
                    actual
                    expected)
                    [(compiler_typecheck_core.TcInferredTypeMatch.Compatible _)
                      true]
                    [(compiler_typecheck_core.TcInferredTypeMatch.Mismatch _)
                      false])
                  (match (compiler_typecheck_core.tc-match-inferred-type-for-expected
                    ctx
                    type-env
                    expected
                    actual)
                    [(compiler_typecheck_core.TcInferredTypeMatch.Compatible _)
                      true]
                    [(compiler_typecheck_core.TcInferredTypeMatch.Mismatch _)
                      false])
                  (match (compiler_typecheck_core.tc-match-inferred-type-for-expected
                    ctx
                    type-env
                    actual
                    different)
                    [(compiler_typecheck_core.TcInferredTypeMatch.Compatible _)
                      false]
                    [(compiler_typecheck_core.TcInferredTypeMatch.Mismatch _)
                      true])
                  (match (compiler_typecheck_core.tc-match-inferred-type-for-expected
                    type-module-ctx
                    type-env
                    actual-ref
                    expected-ref)
                    [(compiler_typecheck_core.TcInferredTypeMatch.Compatible _)
                      true]
                    [(compiler_typecheck_core.TcInferredTypeMatch.Mismatch _)
                      false])
                  (match (compiler_typecheck_core.tc-match-inferred-type-for-expected
                    type-module-ctx
                    type-env
                    actual-ref
                    different-ref)
                    [(compiler_typecheck_core.TcInferredTypeMatch.Compatible _)
                      false]
                    [(compiler_typecheck_core.TcInferredTypeMatch.Mismatch _)
                      true])
                  (match (compiler_typecheck_core.tc-infer-lifetime-subst-from-mixed-source-type
                    type-module-ctx
                    type-env
                    (ast.ast-lifetime-list-new)
                    compiler_typecheck_core.TcLifetimeSubst.Nil
                    actual-ref
                    expected-ref)
                    [(compiler_typecheck_core.ResultTcLifetimeSubst.Ok _) true]
                    [(compiler_typecheck_core.ResultTcLifetimeSubst.Err _)
                      false])
                  (match (compiler_typecheck_core.tc-infer-lifetime-subst-from-mixed-source-type
                    type-module-ctx
                    type-env
                    (ast.ast-lifetime-list-new)
                    compiler_typecheck_core.TcLifetimeSubst.Nil
                    actual-ref
                    different-ref)
                    [(compiler_typecheck_core.ResultTcLifetimeSubst.Ok _) false]
                    [(compiler_typecheck_core.ResultTcLifetimeSubst.Err _) true])
                  (match (compiler_typecheck_core.tc-enum-qualified-variant-lookup-key-id
                    ctx
                    other-constructor-id
                    (compiler_typecheck_core.tc-context-module-id ctx))
                    [(option_i64.Some _) false]
                    [(option_i64.None) true])
                  (match (compiler_typecheck_core.tc-enum-qualified-variant-lookup-handle
                    ctx
                    other-constructor-id)
                    [(option_i64.Some _) false]
                    [(option_i64.None) true])
                  (match (compiler_typecheck_core.tc-enum-qualified-variant-constructor-handle
                    ctx
                    other-constructor-id)
                    [(option_i64.Some _) true]
                    [(option_i64.None) false])
                  (match (compiler_typecheck_core.tc-source-lookup-error-or-variant-constructor
                    ctx
                    other-constructor-id
                    "missing constructor")
                    [(compiler_typecheck_core.ResultTcType.Ok _) true]
                    [(compiler_typecheck_core.ResultTcType.Err _) false])
                  (match (compiler_typecheck_core.tc-enum-qualified-variant-lookup-handle
                    ctx
                    missing-constructor-id)
                    [(option_i64.Some _) false]
                    [(option_i64.None) true])
                  (match (compiler_typecheck_core.tc-enum-qualified-variant-constructor-handle
                    ctx
                    missing-constructor-id)
                    [(option_i64.Some _) false]
                    [(option_i64.None) true])
                  (match (compiler_typecheck_core.tc-source-lookup-error-or-variant-constructor
                    ctx
                    missing-constructor-id
                    "missing constructor")
                    [(compiler_typecheck_core.ResultTcType.Ok _) false]
                    [(compiler_typecheck_core.ResultTcType.Err _) true])
                  (tc-qualified-variant-member-lookup-smoke? module-id flat-id)))]
            [(csym.ResultCompilerRegistries.Err _) false])]
        [(csym.ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(test
  compiler-typecheck-reverse-mixed-source-nominal-match
  (if (tc-reverse-mixed-source-nominal-match-smoke?)
    unit
    (io.panic "typecheck: reverse mixed-source nominal match failed")))