;; compiler_frontend_smoke_suite.tl - Compile-once suite for source-owned
;; semantic and documentation self-tests. Drivers with substantial test bodies
;; remain standalone.
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)
(import stdlib.str_cat)
(import compiler_symbols)
(import compiler_check_core)
(import compiler_semantic_index)
(import compiler_typecheck)
(import compiler_ctfe)
(import compiler_ast_types as ast)
(import compiler_parse_core as parser)
(import compiler_intern as ci)
(import compiler_diagnostic as cdiag)
(import compiler_embedded_stdlib as embedded_stdlib)
(import doc_test)
(import compiler_builtin_ids as cbi)
(import compiler_owned_view as owned_view)

(define (compiler-ctfe-source-parity-value-eq?
  [a : compiler_ctfe.CompilerCtfeValue]
  [b : compiler_ctfe.CompilerCtfeValue]
  [env : (& env compiler_ctfe.CtfeEnv)]) : bool
  (match (compiler_ctfe.ctfe-apply-binop
    (ast.AstBinOp.Eq)
    a
    b
    (ast.AstExpr.Literal (ast.AstLiteral.Unit))
    (compiler_ctfe.ctfe-env-shared-view env)
    (compiler_ctfe.ctfe-fuel-limit))
    [(compiler_ctfe.ResultCtfe.Ok value _)
      (match value
        [(compiler_ctfe.CompilerCtfeValue.Bool same?) same?]
        [_ false])]
    [(compiler_ctfe.ResultCtfe.Err _) false]))

(define (compiler-ctfe-source-parity-arg
  [index : i64]
  [first : compiler_ctfe.CompilerCtfeValue]
  [second : compiler_ctfe.CompilerCtfeValue]) : compiler_ctfe.CompilerCtfeValue
  (if (= index 0)
    first
    second))

(define (compiler-ctfe-source-parity-bind-params
  [env : compiler_ctfe.CtfeEnv]
  [params : (& params ast.AstParamList)]
  [first : compiler_ctfe.CompilerCtfeValue]
  [second : compiler_ctfe.CompilerCtfeValue]
  [arity : i64]
  [index : i64]) : compiler_ctfe.CtfeEnv
  (if (>= index arity)
    env
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name _ _)
        (compiler-ctfe-source-parity-bind-params
          (compiler_ctfe.ctfe-env-extend-id
            env
            name
            (compiler-ctfe-source-parity-arg
              index
              (owned_view.compiler-owned-shared-view first)
              (owned_view.compiler-owned-shared-view second)))
          params
          (owned_view.compiler-owned-shared-view first)
          (owned_view.compiler-owned-shared-view second)
          arity
          (+ index 1))])))

(define (compiler-ctfe-source-parity-param-var
  [env : (& env compiler_ctfe.CtfeEnv)]
  [params : (& params ast.AstParamList)]
  [index : i64]) : i64
  (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
    [(ast.AstParam.Param name _ _)
      (compiler_ctfe.ctfe-ast-push env (ast.AstExpr.Var name))]))

(define (compiler-ctfe-source-parity-direct-call
  [env : (& env compiler_ctfe.CtfeEnv)]
  [params : (& params ast.AstParamList)]
  [builtin-index : i64]
  [arity : i64]) : i64
  (if (= arity 1)
    (compiler_ctfe.compiler-ctfe-call1-in-env
      env
      (cbi.compiler-builtin-ctfe-ref builtin-index)
      (compiler-ctfe-source-parity-param-var env params 0))
    (compiler_ctfe.compiler-ctfe-call2-in-env
      env
      (cbi.compiler-builtin-ctfe-ref builtin-index)
      (compiler-ctfe-source-parity-param-var env params 0)
      (compiler-ctfe-source-parity-param-var env params 1))))

(define (compiler-ctfe-source-parity-eval-decl
  [params : ast.AstParamList]
  [body : i64]
  [builtin-index : i64]
  [first : compiler_ctfe.CompilerCtfeValue]
  [second : compiler_ctfe.CompilerCtfeValue]
  [arity : i64]) : bool
  (let
    [env : compiler_ctfe.CtfeEnv
      (compiler-ctfe-source-parity-bind-params
        (compiler_ctfe.ctfe-env-empty)
        (& params)
        first
        second
        arity
        0)]
    [direct-call : i64
      (compiler-ctfe-source-parity-direct-call
        (& env)
        (& params)
        builtin-index
        arity)]
    (match (compiler_ctfe.compiler-ctfe-eval
      (compiler_ctfe.ctfe-ast-get (& env) body)
      (& env)
      (compiler_ctfe.ctfe-fuel-limit))
      [(compiler_ctfe.ResultCtfe.Ok source-value _)
        (match (compiler_ctfe.compiler-ctfe-eval
          (compiler_ctfe.ctfe-ast-get (& env) direct-call)
          (& env)
          (compiler_ctfe.ctfe-fuel-limit))
          [(compiler_ctfe.ResultCtfe.Ok direct-value _)
            (compiler-ctfe-source-parity-value-eq?
              source-value
              direct-value
              (& env))]
          [(compiler_ctfe.ResultCtfe.Err _) false])]
      [(compiler_ctfe.ResultCtfe.Err source-diag)
        (match (compiler_ctfe.compiler-ctfe-eval
          (compiler_ctfe.ctfe-ast-get (& env) direct-call)
          (& env)
          (compiler_ctfe.ctfe-fuel-limit))
          [(compiler_ctfe.ResultCtfe.Err direct-diag)
            (string.eq
              (cdiag.compiler-diagnostic-message (__tl-box-place source-diag))
              (cdiag.compiler-diagnostic-message (__tl-box-place direct-diag)))]
          [(compiler_ctfe.ResultCtfe.Ok _ _) false])])))

(define (compiler-ctfe-source-parity-find
  [decls : ast.AstDeclList]
  [index : i64]
  [name-id : i64]
  [builtin-index : i64]
  [first : compiler_ctfe.CompilerCtfeValue]
  [second : compiler_ctfe.CompilerCtfeValue]
  [arity : i64]) : bool
  (if (>= index (ast.ast-decl-list-len (& decls)))
    false
    (match (ast.ast-decl-list-ref (ast.ast-global-shared-view decls) index)
      [(ast.AstDecl.DefFn _ found-name params _ body _)
        (if (= found-name name-id)
          (compiler-ctfe-source-parity-eval-decl
            params
            body
            builtin-index
            first
            second
            arity)
          (compiler-ctfe-source-parity-find
            (ast.ast-global-shared-view decls)
            (+ index 1)
            name-id
            builtin-index
            first
            second
            arity))]
      [_
        (compiler-ctfe-source-parity-find
          (ast.ast-global-shared-view decls)
          (+ index 1)
          name-id
          builtin-index
          first
          second
          arity)])))

(define (compiler-ctfe-source-parity-check-owned
  [decls : ast.AstDeclList]
  [name : String]
  [builtin-index : i64]
  [first : compiler_ctfe.CompilerCtfeValue]
  [second : compiler_ctfe.CompilerCtfeValue]
  [arity : i64]) : bool
  (compiler-ctfe-source-parity-find
    decls
    0
    (ci.intern (owned_view.compiler-owned-shared-view name))
    builtin-index
    first
    second
    arity))

(defmacro (compiler-ctfe-source-parity-check
  [decls : Expr]
  [name : Expr]
  [builtin-index : Expr]
  [first : Expr]
  [second : Expr]
  [arity : Expr]) : Expr
  `(compiler-ctfe-source-parity-check-owned
    (ast.ast-global-shared-view ,decls)
    ,name
    ,builtin-index
    (owned_view.compiler-owned-shared-view ,first)
    (owned_view.compiler-owned-shared-view ,second)
    ,arity))

(define (compiler-ctfe-source-placeholder-bind-params
  [env : compiler_ctfe.CtfeEnv]
  [params : (& params ast.AstParamList)]
  [index : i64]) : compiler_ctfe.CtfeEnv
  (if (>= index (ast.ast-param-list-len params))
    env
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name _ _)
        (compiler-ctfe-source-placeholder-bind-params
          (compiler_ctfe.ctfe-env-extend-id
            env
            name
            (compiler_ctfe.CompilerCtfeValue.Unit))
          params
          (+ index 1))])))

(define (compiler-ctfe-source-placeholder-eval?
  [params : ast.AstParamList]
  [body : i64]
  [message : String]) : bool
  (let
    [env : compiler_ctfe.CtfeEnv
      (compiler-ctfe-source-placeholder-bind-params
        (compiler_ctfe.ctfe-env-empty)
        (& params)
        0)]
    (match (compiler_ctfe.compiler-ctfe-eval
      (compiler_ctfe.ctfe-ast-get env body)
      env
      (compiler_ctfe.ctfe-fuel-limit))
      [(compiler_ctfe.ResultCtfe.Err diag)
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          message)]
      [(compiler_ctfe.ResultCtfe.Ok _ _) false])))

(define (compiler-ctfe-source-placeholder-find?
  [decls : ast.AstDeclList]
  [index : i64]
  [name-id : i64]
  [message : String]) : bool
  (if (>= index (ast.ast-decl-list-len (& decls)))
    false
    (match (ast.ast-decl-list-ref (ast.ast-global-shared-view decls) index)
      [(ast.AstDecl.DefFn _ found-name params _ body _)
        (if (= found-name name-id)
          (compiler-ctfe-source-placeholder-eval? params body message)
          (compiler-ctfe-source-placeholder-find?
            (ast.ast-global-shared-view decls)
            (+ index 1)
            name-id
            message))]
      [_
        (compiler-ctfe-source-placeholder-find?
          (ast.ast-global-shared-view decls)
          (+ index 1)
          name-id
          message)])))

(define (compiler-ctfe-source-placeholder-check-owned?
  [decls : ast.AstDeclList]
  [name : String]) : bool
  (compiler-ctfe-source-placeholder-find?
    decls
    0
    (ci.intern (owned_view.compiler-owned-shared-view name))
    (str_cat.str-cat
      name
      " CTFE intrinsic reached without compiler interception")))

(defmacro (compiler-ctfe-source-placeholder-check? [decls : Expr] [name : Expr]) : Expr
  `(compiler-ctfe-source-placeholder-check-owned?
    (ast.ast-global-shared-view ,decls)
    ,name))

(define (compiler-ctfe-stdlib-source-parity-for-decls?
  [decls : ast.AstDeclList]) : bool
  (let
    [env : compiler_ctfe.CtfeEnv (compiler_ctfe.ctfe-env-empty)]
    [true-node : i64
      (compiler_ctfe.ctfe-ast-push
        env
        (ast.AstExpr.Literal (ast.AstLiteral.Bool true)))]
    [false-node : i64
      (compiler_ctfe.ctfe-ast-push
        env
        (ast.AstExpr.Literal (ast.AstLiteral.Bool false)))]
    [first-int-node : i64
      (compiler_ctfe.ctfe-ast-push
        env
        (ast.AstExpr.Literal (ast.ast-lit-int 1)))]
    [second-int-node : i64
      (compiler_ctfe.ctfe-ast-push
        env
        (ast.AstExpr.Literal (ast.ast-lit-int 2)))]
    [if-node : i64
      (compiler_ctfe.ctfe-ast-push
        env
        (ast.AstExpr.If true-node first-int-node second-int-node))]
    [true-expr : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.CompilerCtfeValue.Expr true-node (ast.AstType.Bool))]
    [false-expr : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.CompilerCtfeValue.Expr false-node (ast.AstType.Bool))]
    [if-expr : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.CompilerCtfeValue.Expr if-node (ast.AstType.I64))]
    [exprs : ast.AstExprList (ast.ast-expr-list-new)]
    [clause : ast.AstExprClause (ast.ast-expr-clause true-node false-node)]
    [clause-value : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.CompilerCtfeValue.ExprClause
        (owned_view.compiler-owned-shared-view clause))]
    [clauses : ast.AstExprClauseList (ast.ast-expr-clause-list-new)]
    [binding : ast.AstExprBindingClause
      (ast.ast-expr-binding-clause-id
        (ci.intern "answer")
        true
        true-node
        false-node
        (ast.AstType.Bool)
        (ast.ast-source-span 0 0 0 0))]
    [bindings : ast.AstExprBindingClauseList
      (ast.ast-expr-binding-clause-list-new)]
    [binding-value : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.CompilerCtfeValue.ExprBindingClause
        (owned_view.compiler-owned-shared-view binding))]
    [unused : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.CompilerCtfeValue.Unit)]
    [zero : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.CompilerCtfeValue.I64 0)]
    [out-of-range : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.CompilerCtfeValue.I64 99)]
    (begin
      (ast.ast-expr-list-push (&mut exprs) true-node)
      (ast.ast-expr-list-push (&mut exprs) false-node)
      (ast.ast-expr-clause-list-push (&mut clauses) clause)
      (ast.ast-expr-binding-clause-list-push (&mut bindings) binding)
      (let
        [expr-list-value : compiler_ctfe.CompilerCtfeValue
          (compiler_ctfe.CompilerCtfeValue.ExprList exprs)]
        [clause-list-value : compiler_ctfe.CompilerCtfeValue
          (compiler_ctfe.CompilerCtfeValue.ExprClauseList clauses)]
        [binding-list-value : compiler_ctfe.CompilerCtfeValue
          (compiler_ctfe.CompilerCtfeValue.ExprBindingClauseList bindings)]
        (and
          (compiler-ctfe-source-parity-check
            decls
            "expr-bool?"
            19
            true-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-bool?"
            19
            if-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-bool-value"
            20
            false-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-bool-value"
            20
            if-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-if?"
            21
            if-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-if?"
            21
            true-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-if-cond"
            22
            if-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-if-cond"
            22
            true-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-if-then"
            23
            if-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-if-then"
            23
            true-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-if-else"
            24
            if-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-if-else"
            24
            true-expr
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-clause-first"
            25
            clause-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-clause-second"
            26
            clause-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-list-length"
            51
            expr-list-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-list-nth"
            54
            expr-list-value
            zero
            2)
          (compiler-ctfe-source-parity-check
            decls
            "expr-list-nth"
            54
            expr-list-value
            out-of-range
            2)
          (compiler-ctfe-source-parity-check
            decls
            "expr-clause-list-length"
            56
            clause-list-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-clause-list-nth"
            59
            clause-list-value
            zero
            2)
          (compiler-ctfe-source-parity-check
            decls
            "expr-clause-list-nth"
            59
            clause-list-value
            out-of-range
            2)
          (compiler-ctfe-source-parity-check
            decls
            "expr-binding-clause-name"
            61
            binding-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-binding-clause-has-type?"
            62
            binding-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-binding-clause-type"
            63
            binding-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-binding-clause-init"
            64
            binding-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-binding-clause-list-length"
            66
            binding-list-value
            unused
            1)
          (compiler-ctfe-source-parity-check
            decls
            "expr-binding-clause-list-nth"
            69
            binding-list-value
            zero
            2)
          (compiler-ctfe-source-parity-check
            decls
            "expr-binding-clause-list-nth"
            69
            binding-list-value
            out-of-range
            2)
          (compiler-ctfe-source-placeholder-check? decls "expr-list-cons")
          (compiler-ctfe-source-placeholder-check?
            decls
            "expr-clause-list-fold-if")
          (compiler-ctfe-source-placeholder-check? decls "pattern-list-cons")
          (compiler-ctfe-source-placeholder-check? decls "match-arm-list-cons")
          (compiler-ctfe-source-placeholder-check?
            decls
            "expr-clause-list->expr-list"))))))

(define (compiler-ctfe-stdlib-source-parity-ok?) : bool
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match (embedded_stdlib.compiler-embedded-stdlib-lookup "comptime.tl")
      [(embedded_stdlib.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibSomeSource
          source)
        (match (parser.parse-ast-source source)
          [(parser.ResultAstProgram.Ok program)
            (match program
              [(ast.AstProgram.Program decls-box)
                (compiler-ctfe-stdlib-source-parity-for-decls?
                  (owned_view.compiler-owned-box-shared-view decls-box))])]
          [(parser.ResultAstProgram.Err _) false])]
      [(embedded_stdlib.CompilerEmbeddedStdlibSource.CompilerEmbeddedStdlibNoSource)
        false])))

(define (compiler-smoke-suite-require-child [name : String] [message : String]) : unit
  (let
    [started-ms : i64
      (compiler_semantic_index.compiler-semantic-index-smoke-timing-start)]
    [result : process.ResultProcessOutput
      (process.output
        (process.command (io.arg 0) (process.args-single (clone name))))]
    [status : i64 (process.result-status-or (clone result) -1)]
    [timing-ok : bool
      (compiler_semantic_index.compiler-semantic-index-smoke-timing-record
        (str_cat.str-cat "child-" name)
        started-ms
        status)]
    (unless
      (and timing-ok (process.result-output-eq? result 42 "" ""))
      (io.panic message))))

(define (compiler-smoke-suite-child [name : String]) : i64
  (cond
    [(string.eq name "symbols")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (compiler_symbols.compiler-symbols-self-test))]
    [(string.eq name "check")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (if (and
          (= (compiler_check_core.compiler-check-self-test) 42)
          (compiler_semantic_index.compiler-check-semantic-index-ok?))
          42
          1))]
    [(string.eq name "ctfe")
      (if (and
        (= (compiler_ctfe.compiler-ctfe-self-test) 42)
        (compiler-ctfe-stdlib-source-parity-ok?))
        42
        1)]
    [(string.eq name "reflection")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (if (compiler_typecheck.compiler-typecheck-reflection-tests-ok?)
          42
          1))]
    [(string.eq name "doc-test") (doc_test.doc-test-smoke-all)]
    [else 1]))

(define (main) : i64
  (if (> (io.arg-count) 1)
    (compiler-smoke-suite-child (io.arg 1))
    (begin
      (compiler-smoke-suite-require-child
        "symbols"
        "compiler smoke suite: compiler_symbols_smoke failed")
      (compiler-smoke-suite-require-child
        "check"
        "compiler smoke suite: compiler_check_smoke failed")
      (compiler-smoke-suite-require-child
        "ctfe"
        "compiler smoke suite: compiler_ctfe_smoke failed")
      (compiler-smoke-suite-require-child
        "reflection"
        "compiler smoke suite: compiler_typecheck_reflection_smoke failed")
      (compiler-smoke-suite-require-child
        "doc-test"
        "compiler smoke suite: doc_test_smoke failed")
      42)))