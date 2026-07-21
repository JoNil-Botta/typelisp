;; Reverse mixed-source nominal identity regression.
(import "../compiler_typecheck_core.tl")

(define (tc-reverse-mixed-source-nominal-match-smoke?) : bool
  (match (parse-ast-source
    "(defstruct ReverseMixedItem (value i64))
(import \"reverse_mixed.tl\" module reverse.mixed :as reverse)
(module reverse.mixed)
(defstruct ReverseMixedItem (value i64))
(defstruct ReverseMixedOther (value i64))")
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
                [actual : AstType (ast-ty-array (AstType.Struct flat-id) 1)]
                [expected : AstType
                  (ast-ty-array (AstType.Struct qualified-id) 1)]
                [different : AstType
                  (ast-ty-array (AstType.Struct other-qualified-id) 1)]
                (and
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
                    [(TcInferredTypeMatch.Mismatch _) true])))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(test
  compiler-typecheck-reverse-mixed-source-nominal-match
  (if (tc-reverse-mixed-source-nominal-match-smoke?)
    unit
    (io.panic "typecheck: reverse mixed-source nominal match failed")))