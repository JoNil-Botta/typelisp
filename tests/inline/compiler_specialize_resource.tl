;; Owner isolation and diagnostic order for the resource specialization walkers.
(import compiler_specialize as spec)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import compiler_ctfe as ctfe)
(import compiler_diagnostic as diagnostic)
(import compiler_owned_view as view)
(import stdlib.string)
(import stdlib.test)

(define (resource-with-owner [owner : (& owner spec.SpecOwnerContext)]) : ast.AstExpr
  (let
    [value : i64
      (spec.spec-owner-expr-push
        owner
        (ast.AstExpr.Var cbi.compiler-builtin-id-fix-x))]
    [ty : i64
      (spec.spec-owner-type-push
        owner
        (ast.AstType.Var cbi.compiler-builtin-id-fix-T))]
    [init : i64
      (spec.spec-owner-expr-push owner (ast.AstExpr.MakeArray ty value))]
    [bindings : ast.AstResourceBindingList (ast.ast-resource-binding-list-new)]
    [body : ast.AstExprList (ast.ast-expr-list-new)]
    (begin
      (ast.ast-resource-binding-list-push
        (&mut bindings)
        (ast.AstResourceBinding.Binding
          cbi.compiler-builtin-id-fix-x
          init
          value
          true))
      (ast.ast-expr-list-push (&mut body) value)
      (ast.AstExpr.WithResource
        (box (ast.AstWithResource.WithResource bindings body))))))

(define (literal-five? [owner : (& owner spec.SpecOwnerContext)] [id : i64]) : bool
  (match (spec.spec-owner-expr-get owner id)
    [(ast.AstExpr.Literal literal)
      (match literal
        [(ast.AstLiteral.Int n _) (= n 5)]
        [_ false])]
    [_ false]))

(define (rewritten-resource-ok?
  [owner : (& owner spec.SpecOwnerContext)]
  [id : i64]) : bool
  (match (spec.spec-owner-expr-get owner id)
    [(ast.AstExpr.WithResource resource)
      (match (ast.ast-with-resource-box-shared-view resource)
        [(ast.AstWithResource.WithResource bindings body)
          (match (ast.ast-resource-binding-list-get
            (& bindings)
            0
            (ast.ast-resource-binding-fallback))
            [(ast.AstResourceBinding.Binding name init cleanup move-aware?)
              (and
                (= name cbi.compiler-builtin-id-fix-x)
                move-aware?
                (literal-five? owner cleanup)
                (match (spec.spec-owner-expr-get owner init)
                  [(ast.AstExpr.MakeArray ty length)
                    (and
                      (literal-five? owner length)
                      (match (spec.spec-owner-type-get owner ty)
                        [(ast.AstType.I64) true]
                        [_ false]))]
                  [_ false])
                (match (spec.spec-owner-expr-get
                  owner
                  (ast.ast-expr-list-get (& body) 0 0))
                  [(ast.AstExpr.Var name)
                    (= name cbi.compiler-builtin-id-fix-x)]
                  [_ false]))])])]
    [_ false]))

(test
  resource-substitution-uses-explicit-owner
  (let
    [_builtins : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 32 32)]
    [owner : spec.SpecOwnerContext
      (spec.spec-owner-context-new
        pools
        (ci.intern-compat-state-capture-active))]
    [expr : ast.AstExpr (resource-with-owner (& owner))]
    [types : spec.SpecTypeSubst
      (spec.spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        (ast.AstType.I64)
        (spec.spec-type-subst-new))]
    [values : spec.SpecValueSubst
      (spec.spec-value-subst-cons
        cbi.compiler-builtin-id-fix-x
        (ctfe.CompilerCtfeValue.I64 5)
        (spec.spec-value-subst-new))]
    [ambient-count : i64 (ast.ast-node-pool-len)]
    (begin
      (match (spec.spec-substitute-types-expr-with-owner
        (& owner)
        expr
        (& types))
        [(spec.ResultSpecSubExpr.Ok typed)
          (match (spec.spec-substitute-values-expr-with-owner
            (& owner)
            (spec.spec-owner-expr-get (& owner) typed)
            (& values))
            [(spec.ResultSpecSubExpr.Ok result)
              (test.assert-true
                (rewritten-resource-ok? (& owner) result)
                "type and value substitution route every resource child through its owner")]
            [_ (test.assert-true false "value substitution succeeds")])]
        [_ (test.assert-true false "type substitution succeeds")])
      (test.assert-i64-eq
        (ast.ast-node-pool-len)
        ambient-count
        "non-installed resource owner leaves ambient pool untouched"))))

(test
  resource-discovery-owner-and-sequential-shadowing
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 64 64)]
    [source : String
      "(define (pick [comptime n : i64]) : i64 n)
       (define (main) : i64
         (begin
           (with ([pick (pick 1) (pick 2)] [later (pick 3) drop])
             (+ later (pick 4)))
           (pick 5)))"]
    (match (parser.parse-ast-source-with-cfg-and-pools
      source
      (parser.compiler-cfg-empty)
      (view.compiler-owned-shared-view pools))
      [(parser.ResultAstProgram.Ok program)
        (let
          [ambient-count : i64 (ast.ast-node-pool-len)]
          (begin
            (match (spec.compiler-specialize-program-with-pools-and-intern-state
              program
              pools
              (ci.intern-compat-state-capture-active))
              [(spec.ResultSpecProgram.Ok specialized)
                (match specialized
                  [(ast.AstProgram.Program boxed-decls)
                    (let
                      [decls : ast.AstDeclList
                        (ast.ast-decl-list-box-shared-view boxed-decls)]
                      (begin
                        (test.assert-true
                          (spec.compiler-specialize-decl-list-defines?
                            (view.compiler-owned-shared-view decls)
                            "__tl_specialized_pick_i64_1_none")
                          "own initializer sees template")
                        (test.assert-true
                          (spec.compiler-specialize-decl-list-defines?
                            (view.compiler-owned-shared-view decls)
                            "__tl_specialized_pick_i64_2_none")
                          "own cleanup sees template")
                        (test.assert-true
                          (not
                            (spec.compiler-specialize-decl-list-defines?
                              (view.compiler-owned-shared-view decls)
                              "__tl_specialized_pick_i64_3_none"))
                          "later initializer sees resource")
                        (test.assert-true
                          (not
                            (spec.compiler-specialize-decl-list-defines?
                              (view.compiler-owned-shared-view decls)
                              "__tl_specialized_pick_i64_4_none"))
                          "body sees resource")
                        (test.assert-true
                          (spec.compiler-specialize-decl-list-defines?
                            decls
                            "__tl_specialized_pick_i64_5_none")
                          "sibling restores template")))])]
              [_ (test.assert-true false "resource discovery succeeds")])
            (test.assert-i64-eq
              (ast.ast-node-pool-len)
              ambient-count
              "discovery leaves ambient pool untouched")))]
      [_ (test.assert-true false "resource discovery source parses")])))

(test
  resource-initializer-error-precedes-cleanup-error
  (match (parser.parse-ast-source
    "(define (bad [comptime T : type] [comptime U : type]) : i64
       (with ([r T U]) 0))
     (define (main) : i64 (bad (type i64) (type bool)))")
    [(parser.ResultAstProgram.Ok program)
      (match (spec.compiler-specialize-program program)
        [(spec.ResultSpecProgram.Err boxed-diag)
          (let
            [diag : diagnostic.CompilerDiagnostic
              (diagnostic.compiler-diagnostic-box-shared-view boxed-diag)]
            (test.assert-true
              (string.eq
                diag.message
                "type-valued comptime parameter 'T' cannot be used as a runtime value")
              "initializer error wins over cleanup error"))]
        [_ (test.assert-true false "invalid runtime type use is rejected")])]
    [_ (test.assert-true false "diagnostic-order source parses")]))