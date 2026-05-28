;; test.tl - Selfhost inline test runner planner (#940).
;;
;; Discovers `(test name body...)` declarations through the selfhost loader,
;; lowers them into private unit-returning functions plus a generated `main`,
;; and emits a private host-action plan whose assembly is assembled/linked/run
;; by the Rust host boundary. Normal compile paths ignore `AstDeclTest`.
(import "compiler_backend.tl")

(import "compiler_load.tl")

(import "compiler_optimize.tl")

(import "compiler_typecheck.tl")

(import "host_plan.tl")

(defenum TestMode
  (TestModeRun)
  (TestModeCheck))

(defenum TestConfig
  (TestConfig String String String CompilerLoadRootList i64 TestMode))

(defenum ResultTestConfig
  (OkTestConfig TestConfig)
  (ErrTestConfig String))

(defenum InlineTest
  (InlineTest String String i64 AstExpr String))

(defenum InlineTestList
  (InlineTestNil)
  (InlineTestCons InlineTest InlineTestList))

(defenum InlineCollect
  (InlineCollect AstDeclList AstDeclPathList InlineTestList i64))

(defenum InlineHarness
  (InlineHarness AstProgram AstDeclPathList i64))

(defenum InlineRuntimeDecls
  (InlineRuntimeDecls AstDeclList AstDeclPathList))

(define (tltest-root-cons [root : String] [roots : CompilerLoadRootList]) : CompilerLoadRootList
  (CompilerLoadRootCons root roots))

(define (tltest-unknown-target [value : String]) : String
  (host-plan-cat3 "test: unknown target " value ""))

(define (tltest-unknown-mode [value : String]) : String
  (host-plan-cat3 "test: unknown backend mode " value ""))

(define (tltest-unsupported-mode [value : String]) : String
  (host-plan-cat3 "test: backend mode " value " is not implemented"))

(define (tltest-invalid-opt-level [value : String]) : String
  (host-plan-cat3 "test: invalid --opt-level " value "; expected 0, 1, 2, or 3"))

(define (tltest-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [target : String]
  [mode : String]
  [roots : CompilerLoadRootList]
  [has-opt-level : bool]
  [opt-level : i64]
  [test-mode : TestMode]) : ResultTestConfig
  (if (>= idx count)
    (if has-source
      (OkTestConfig (TestConfig source target mode roots opt-level test-mode))
      (ErrTestConfig "test: expected source path"))
    (let
      [current : String (arg idx)]
      (cond
        [(string-eq current "--check")
          (tltest-parse-options
            (+ idx 1)
            count
            source
            has-source
            target
            mode
            roots
            has-opt-level
            opt-level
            TestModeCheck)]
        [(string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ErrTestConfig "test: --target requires a value")
            (let
              [value : String (arg (+ idx 1))]
              (if (host-plan-target-valid? value)
                (tltest-parse-options
                  (+ idx 2)
                  count
                  source
                  has-source
                  value
                  mode
                  roots
                  has-opt-level
                  opt-level
                  test-mode)
                (ErrTestConfig (tltest-unknown-target value)))))]
        [(string-eq current "--backend-mode")
          (if (>= (+ idx 1) count)
            (ErrTestConfig "test: --backend-mode requires a value")
            (let
              [value : String (arg (+ idx 1))]
              (if (host-plan-backend-mode-valid? value)
                (if (string-eq value "scalar")
                  (tltest-parse-options
                    (+ idx 2)
                    count
                    source
                    has-source
                    target
                    value
                    roots
                    has-opt-level
                    opt-level
                    test-mode)
                  (ErrTestConfig (tltest-unsupported-mode value)))
                (ErrTestConfig (tltest-unknown-mode value)))))]
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrTestConfig "test: --stdlib-root requires a value")
            (tltest-parse-options
              (+ idx 2)
              count
              source
              has-source
              target
              mode
              (tltest-root-cons (arg (+ idx 1)) roots)
              has-opt-level
              opt-level
              test-mode))]
        [(string-eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ErrTestConfig "test: --opt-level requires a value")
            (if has-opt-level
              (ErrTestConfig "test: --opt-level was provided more than once")
              (let
                [value : String (arg (+ idx 1))]
                (match (compiler-optimize-parse-level value)
                  [(OkCompilerOptimizeLevel parsed-level)
                    (tltest-parse-options
                      (+ idx 2)
                      count
                      source
                      has-source
                      target
                      mode
                      roots
                      true
                      parsed-level
                      test-mode)]
                  [(ErrCompilerOptimizeLevel)
                    (ErrTestConfig (tltest-invalid-opt-level value))]))))]
        [(host-plan-flag? current)
          (ErrTestConfig (string-append "test: unknown flag " current))]
        [has-source (ErrTestConfig "test: accepts only one source file")]
        [else
          (tltest-parse-options
            (+ idx 1)
            count
            current
            true
            target
            mode
            roots
            has-opt-level
            opt-level
            test-mode)]))))

(define (tltest-config [count : i64]) : ResultTestConfig
  (tltest-parse-options
    1
    count
    ""
    false
    "linux-x86_64"
    "scalar"
    CompilerLoadRootNil
    false
    (compiler-optimize-default-level)
    TestModeRun))

(define (tltest-decl-list-reverse-in [items : AstDeclList] [out : AstDeclList]) : AstDeclList
  (match items
    [(AstDeclNil) out]
    [(AstDeclCons head rest)
      (tltest-decl-list-reverse-in rest (AstDeclCons head out))]))

(define (tltest-decl-list-reverse [items : AstDeclList]) : AstDeclList
  (tltest-decl-list-reverse-in items AstDeclNil))

(define (tltest-path-list-reverse-in
  [items : AstDeclPathList]
  [out : AstDeclPathList]) : AstDeclPathList
  (match items
    [(AstDeclPathNil) out]
    [(AstDeclPathCons head rest)
      (tltest-path-list-reverse-in rest (AstDeclPathCons head out))]))

(define (tltest-path-list-reverse [items : AstDeclPathList]) : AstDeclPathList
  (tltest-path-list-reverse-in items AstDeclPathNil))

(define (tltest-inline-list-reverse-in
  [items : InlineTestList]
  [out : InlineTestList]) : InlineTestList
  (match items
    [(InlineTestNil) out]
    [(InlineTestCons head rest)
      (tltest-inline-list-reverse-in rest (InlineTestCons head out))]))

(define (tltest-inline-list-reverse [items : InlineTestList]) : InlineTestList
  (tltest-inline-list-reverse-in items InlineTestNil))

(define (tltest-decl-list-append [left : AstDeclList] [right : AstDeclList]) : AstDeclList
  (match left
    [(AstDeclNil) right]
    [(AstDeclCons head rest)
      (AstDeclCons head (tltest-decl-list-append rest right))]))

(define (tltest-decl-list-count [items : AstDeclList]) : i64
  (match items
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest) (+ 1 (tltest-decl-list-count rest))]))

(define (tltest-path-list-append
  [left : AstDeclPathList]
  [right : AstDeclPathList]) : AstDeclPathList
  (match left
    [(AstDeclPathNil) right]
    [(AstDeclPathCons head rest)
      (AstDeclPathCons head (tltest-path-list-append rest right))]))

(define (tltest-main-decl? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclDef name _ _) (string-eq name "main")]
    [(AstDeclDefFn name _ _ _) (string-eq name "main")]
    [_ false]))

(define (tltest-source-line [span : AstSourceSpan]) : i64
  (struct-get span start-line))

(define (tltest-private-name [idx : i64]) : String
  (string-append "__tl_inline_test_" (int->string idx)))

(define (tltest-collect
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [runtime-rev : AstDeclList]
  [path-rev : AstDeclPathList]
  [tests-rev : InlineTestList]
  [test-count : i64]) : InlineCollect
  (match decls
    [(AstDeclNil)
      (InlineCollect
        (tltest-decl-list-reverse runtime-rev)
        (tltest-path-list-reverse path-rev)
        (tltest-inline-list-reverse tests-rev)
        test-count)]
    [(AstDeclCons decl rest)
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) ""])]
        (let
          [rest-paths : AstDeclPathList
            (match paths
              [(AstDeclPathCons _ path-rest) path-rest]
              [(AstDeclPathNil) AstDeclPathNil])]
          (match decl
            [(AstDeclTest name body span)
              (tltest-collect
                rest
                rest-paths
                runtime-rev
                path-rev
                (InlineTestCons
                  (InlineTest
                    name
                    decl-path
                    (tltest-source-line span)
                    body
                    (tltest-private-name test-count))
                  tests-rev)
                (+ test-count 1))]
            [(AstDeclImport _)
              (tltest-collect
                rest
                rest-paths
                runtime-rev
                path-rev
                tests-rev
                test-count)]
            [_
              (if (tltest-main-decl? decl)
                (tltest-collect
                  rest
                  rest-paths
                  runtime-rev
                  path-rev
                  tests-rev
                  test-count)
                (tltest-collect
                  rest
                  rest-paths
                  (AstDeclCons decl runtime-rev)
                  (AstDeclPathCons decl-path path-rev)
                  tests-rev
                  test-count))])))]))

(define (tltest-print-expr [text : String]) : AstExpr
  (AstExprCall
    (AstExprVar "print-error")
    (AstExprCons (AstExprLiteral (AstLitString text)) AstExprNil)))

(define (tltest-call-expr [name : String]) : AstExpr
  (AstExprCall (AstExprVar name) AstExprNil))

(define (tltest-location [path : String] [line : i64]) : String
  (if (string-eq path "")
    (string-append "<unknown>:" (int->string line))
    (string-append path (string-append ":" (int->string line)))))

(define (tltest-running-line [test : InlineTest]) : String
  (match test
    [(InlineTest name path line _ _)
      (string-append
        "test "
        (string-append
          name
          (string-append " " (string-append (tltest-location path line) "\n"))))]))

(define (tltest-ok-line [test : InlineTest]) : String
  (match test
    [(InlineTest name _ _ _ _) (string-append "ok " (string-append name "\n"))]))

(define (tltest-summary-line [count : i64]) : String
  (string-append
    "TypeLisp tests passed: "
    (string-append (int->string count) " test(s)\n")))

(define (tltest-main-exprs [tests : InlineTestList] [count : i64]) : AstExprList
  (match tests
    [(InlineTestNil)
      (AstExprCons
        (tltest-print-expr (tltest-summary-line count))
        (AstExprCons (AstExprLiteral (AstLitInt 0)) AstExprNil))]
    [(InlineTestCons test rest)
      (match test
        [(InlineTest _ _ _ _ private-name)
          (AstExprCons
            (tltest-print-expr (tltest-running-line test))
            (AstExprCons
              (tltest-call-expr private-name)
              (AstExprCons
                (tltest-print-expr (tltest-ok-line test))
                (tltest-main-exprs rest count))))])]))

(define (tltest-test-decls [tests : InlineTestList]) : AstDeclList
  (match tests
    [(InlineTestNil) AstDeclNil]
    [(InlineTestCons test rest)
      (match test
        [(InlineTest _ _ _ body private-name)
          (AstDeclCons
            (AstDeclDefFn private-name AstParamNil (AstTyUnit) body)
            (tltest-test-decls rest))])]))

(define (tltest-test-paths [tests : InlineTestList]) : AstDeclPathList
  (match tests
    [(InlineTestNil) AstDeclPathNil]
    [(InlineTestCons test rest)
      (match test
        [(InlineTest _ path _ _ _)
          (AstDeclPathCons path (tltest-test-paths rest))])]))

(define (tltest-main-decl [tests : InlineTestList] [count : i64]) : AstDecl
  (AstDeclDefFn
    "main"
    AstParamNil
    (AstTyI64)
    (AstExprBegin (tltest-main-exprs tests count))))

(define (tltest-reach-mark-name [names : SymI64Env] [name : String]) : SymI64Env
  (if (sym-i64-contains names name)
    names
    (sym-i64-bind names name 1)))

(define (tltest-reach-mark-expr-list [exprs : AstExprList] [names : SymI64Env]) : SymI64Env
  (match exprs
    [(AstExprNil) names]
    [(AstExprCons head rest)
      (tltest-reach-mark-expr-list rest (tltest-reach-mark-expr head names))]))

(define (tltest-reach-mark-let-bindings
  [bindings : AstLetBindingList]
  [names : SymI64Env]) : SymI64Env
  (match bindings
    [(AstLetBindingNil) names]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding _ _ value)
          (tltest-reach-mark-let-bindings
            rest
            (tltest-reach-mark-expr value names))])]))

(define (tltest-reach-mark-resource-bindings
  [bindings : AstResourceBindingList]
  [names : SymI64Env]) : SymI64Env
  (match bindings
    [(AstResourceBindingNil) names]
    [(AstResourceBindingCons binding rest)
      (match binding
        [(AstResourceBinding _ init cleanup)
          (tltest-reach-mark-resource-bindings
            rest
            (tltest-reach-mark-expr cleanup (tltest-reach-mark-expr init names)))])]))

(define (tltest-reach-mark-match-arms
  [arms : AstMatchArmList]
  [names : SymI64Env]) : SymI64Env
  (match arms
    [(AstMatchArmNil) names]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm _ body)
          (tltest-reach-mark-match-arms
            rest
            (tltest-reach-mark-expr body names))])]))

(define (tltest-reach-mark-expr [expr : AstExpr] [names : SymI64Env]) : SymI64Env
  (match expr
    [(AstExprSpanned inner _) (tltest-reach-mark-expr inner names)]
    [(AstExprLiteral _) names]
    [(AstExprVar name) (tltest-reach-mark-name names name)]
    [(AstExprBinary _ left right)
      (tltest-reach-mark-expr right (tltest-reach-mark-expr left names))]
    [(AstExprUnary _ inner) (tltest-reach-mark-expr inner names)]
    [(AstExprCall func args)
      (tltest-reach-mark-expr-list args (tltest-reach-mark-expr func names))]
    [(AstExprIf cond then-branch else-branch)
      (tltest-reach-mark-expr
        else-branch
        (tltest-reach-mark-expr then-branch (tltest-reach-mark-expr cond names)))]
    [(AstExprLet bindings body)
      (tltest-reach-mark-expr
        body
        (tltest-reach-mark-let-bindings bindings names))]
    [(AstExprLambda _ _ body) (tltest-reach-mark-expr body names)]
    [(AstExprTuple exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprTupleRef tuple _) (tltest-reach-mark-expr tuple names)]
    [(AstExprArray exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprMakeArray _ len) (tltest-reach-mark-expr len names)]
    [(AstExprArrayRef array index)
      (tltest-reach-mark-expr index (tltest-reach-mark-expr array names))]
    [(AstExprArraySet array index value)
      (tltest-reach-mark-expr
        value
        (tltest-reach-mark-expr index (tltest-reach-mark-expr array names)))]
    [(AstExprArrayPush array value)
      (tltest-reach-mark-expr value (tltest-reach-mark-expr array names))]
    [(AstExprStringRef text index)
      (tltest-reach-mark-expr index (tltest-reach-mark-expr text names))]
    [(AstExprWhile cond body)
      (tltest-reach-mark-expr body (tltest-reach-mark-expr cond names))]
    [(AstExprBegin exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprUnsafe exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprSet name value)
      (tltest-reach-mark-expr value (tltest-reach-mark-name names name))]
    [(AstExprAnn inner _) (tltest-reach-mark-expr inner names)]
    [(AstExprCast inner _) (tltest-reach-mark-expr inner names)]
    [(AstExprBorrow _ place) (tltest-reach-mark-expr place names)]
    [(AstExprMatch scrutinee arms)
      (tltest-reach-mark-match-arms
        arms
        (tltest-reach-mark-expr scrutinee names))]
    [(AstExprForeach _ _ start end body)
      (tltest-reach-mark-expr
        body
        (tltest-reach-mark-expr end (tltest-reach-mark-expr start names)))]
    [(AstExprSpmdReduce _ _ _ start end init value)
      (tltest-reach-mark-expr
        value
        (tltest-reach-mark-expr
          init
          (tltest-reach-mark-expr end (tltest-reach-mark-expr start names))))]
    [(AstExprStructGet receiver _) (tltest-reach-mark-expr receiver names)]
    [(AstExprWithRegion _ body) (tltest-reach-mark-expr-list body names)]
    [(AstExprWithResource bindings body)
      (tltest-reach-mark-expr-list
        body
        (tltest-reach-mark-resource-bindings bindings names))]
    [(AstExprBorrow _ place) (tltest-reach-mark-expr place names)]
    [(AstExprTypeLiteral _) names]
    [(AstExprComptime inner) (tltest-reach-mark-expr inner names)]
    [(AstExprTry inner) (tltest-reach-mark-expr inner names)]
    [(AstExprPtrNull _) names]
    [(AstExprPtrNullCheck inner) (tltest-reach-mark-expr inner names)]
    [(AstExprPtrRead ptr) (tltest-reach-mark-expr ptr names)]
    [(AstExprPtrWrite ptr value)
      (tltest-reach-mark-expr value (tltest-reach-mark-expr ptr names))]
    [(AstExprPtrOffset ptr offset)
      (tltest-reach-mark-expr offset (tltest-reach-mark-expr ptr names))]
    [(AstExprPtrCast ptr _) (tltest-reach-mark-expr ptr names)]
    [(AstExprPtrToInt ptr) (tltest-reach-mark-expr ptr names)]
    [(AstExprIntToPtr value _) (tltest-reach-mark-expr value names)]))

(define (tltest-reach-mark-tests [tests : InlineTestList] [names : SymI64Env]) : SymI64Env
  (match tests
    [(InlineTestNil) names]
    [(InlineTestCons test rest)
      (match test
        [(InlineTest _ _ _ body _)
          (tltest-reach-mark-tests rest (tltest-reach-mark-expr body names))])]))

(define (tltest-reach-mark-decl [decl : AstDecl] [names : SymI64Env]) : SymI64Env
  (match decl
    [(AstDeclDef name _ expr)
      (if (sym-i64-contains names name)
        (tltest-reach-mark-expr expr names)
        names)]
    [(AstDeclDefFn name _ _ body)
      (if (sym-i64-contains names name)
        (tltest-reach-mark-expr body names)
        names)]
    [_ names]))

(define (tltest-reach-mark-decls [decls : AstDeclList] [names : SymI64Env]) : SymI64Env
  (match decls
    [(AstDeclNil) names]
    [(AstDeclCons decl rest)
      (tltest-reach-mark-decls rest (tltest-reach-mark-decl decl names))]))

(define (tltest-reach-fixed
  [decls : AstDeclList]
  [fuel : i64]
  [names : SymI64Env]) : SymI64Env
  (if (<= fuel 0)
    names
    (tltest-reach-fixed decls (- fuel 1) (tltest-reach-mark-decls decls names))))

(define (tltest-reachable-names [decls : AstDeclList] [tests : InlineTestList]) : SymI64Env
  (tltest-reach-fixed
    decls
    (tltest-decl-list-count decls)
    (tltest-reach-mark-tests tests (sym-i64-empty))))

(define (tltest-reachable-runtime-decl? [decl : AstDecl] [names : SymI64Env]) : bool
  (match decl
    [(AstDeclDef name _ _) (sym-i64-contains names name)]
    [(AstDeclDefFn name _ _ _) (sym-i64-contains names name)]
    [(AstDeclExtern name _ _) (sym-i64-contains names name)]
    [_ true]))

(define (tltest-prune-runtime-decls-in
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [names : SymI64Env]
  [decls-rev : AstDeclList]
  [paths-rev : AstDeclPathList]) : InlineRuntimeDecls
  (match decls
    [(AstDeclNil)
      (InlineRuntimeDecls
        (tltest-decl-list-reverse decls-rev)
        (tltest-path-list-reverse paths-rev))]
    [(AstDeclCons decl rest)
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) ""])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        (if (tltest-reachable-runtime-decl? decl names)
          (tltest-prune-runtime-decls-in
            rest
            rest-paths
            names
            (AstDeclCons decl decls-rev)
            (AstDeclPathCons decl-path paths-rev))
          (tltest-prune-runtime-decls-in
            rest
            rest-paths
            names
            decls-rev
            paths-rev)))]))

(define (tltest-prune-runtime-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [tests : InlineTestList]) : InlineRuntimeDecls
  (tltest-prune-runtime-decls-in
    decls
    paths
    (tltest-reachable-names decls tests)
    AstDeclNil
    AstDeclPathNil))

(define (tltest-build-harness
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : InlineHarness
  (match (tltest-collect decls paths AstDeclNil AstDeclPathNil InlineTestNil 0)
    [(InlineCollect runtime-decls runtime-paths tests count)
      (let
        [test-decls : AstDeclList (tltest-test-decls tests)]
        [test-paths : AstDeclPathList (tltest-test-paths tests)]
        (match (tltest-prune-runtime-decls runtime-decls runtime-paths tests)
          [(InlineRuntimeDecls pruned-decls pruned-paths)
            (InlineHarness
              (AstProgram
                (tltest-decl-list-append
                  pruned-decls
                  (tltest-decl-list-append
                    test-decls
                    (AstDeclCons (tltest-main-decl tests count) AstDeclNil))))
              (tltest-path-list-append
                pruned-paths
                (tltest-path-list-append
                  test-paths
                  (AstDeclPathCons source AstDeclPathNil)))
              count)]))]))

(define (tltest-backend-target [target : String]) : CompilerBackendTarget
  (if (or
    (string-eq target "windows-x86_64")
    (string-eq target "windows_x86_64"))
    (BackendTargetWindows)
    (BackendTargetLinux)))

(define (tltest-scratch-asm-path [source : String]) : String
  (string-append source ".test.s"))

(define (tltest-plan [asm-path : String] [target : String] [mode : String]) : String
  (string-append
    (host-plan-header)
    (string-append
      (host-plan-word-line "action" "run-scratch-assembly")
      (string-append
        (host-plan-netline "scratch-assembly-path" asm-path)
        (string-append
          (host-plan-word-line "target" target)
          (string-append (host-plan-word-line "backend-mode" mode) "end\n"))))))

(define (tltest-check-only
  [program : AstProgram]
  [paths : AstDeclPathList]
  [count : i64]) : i64
  (match (typecheck-compiler-program-with-paths program paths)
    [(OkCompilerTypecheck _)
      (begin
        (print-string
          (string-append
            "TypeLisp test typecheck passed: "
            (string-append (int->string count) " test(s)\n")))
        0)]
    [(ErrCompilerTypecheck diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (tltest-run-plan
  [source : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [target : String]
  [mode : String]
  [opt-level : i64]) : i64
  (match (lower-compiler-program-with-decl-paths source program paths)
    [(OkCompilerLower ir spans)
      (match (optimize-program-with-spans-and-level ir spans opt-level)
        [(CompilerOptimizedProgram optimized optimized-spans)
          (match (compiler-backend-emit-program-with-spans-for-target
            optimized
            optimized-spans
            (tltest-backend-target target))
            [(OkCompilerBackend asm)
              (let
                [asm-path : String (tltest-scratch-asm-path source)]
                (begin
                  (write-file asm-path asm)
                  (print-string (tltest-plan asm-path target mode))
                  0))]
            [(ErrCompilerBackend diag)
              (begin
                (print-error (compiler-diagnostic-render diag))
                1)])])]
    [(ErrCompilerLower diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (tltest-no-tests-check [decls : AstDeclList] [paths : AstDeclPathList]) : i64
  (match (typecheck-compiler-program-with-paths (AstProgram decls) paths)
    [(OkCompilerTypecheck _)
      (begin
        (print-string "TypeLisp test typecheck passed: 0 test(s)\n")
        0)]
    [(ErrCompilerTypecheck diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (tltest-no-tests-run
  [source : String]
  [target : String]
  [mode : String]
  [opt-level : i64])
  :
  i64
  ;; With no inline tests there is no source harness to validate here. `test
  ;; --check` owns source typechecking; run mode only needs the zero-test runner
  ;; plan so the Rust host-action boundary can keep its normal contract.
  (tltest-run-plan
    source
    (AstProgram (AstDeclCons (tltest-main-decl InlineTestNil 0) AstDeclNil))
    (AstDeclPathCons source AstDeclPathNil)
    target
    mode
    opt-level))

(define (tltest-run-config [config : TestConfig]) : i64
  (match config
    [(TestConfig source target mode roots opt-level test-mode)
      (match (compiler-load-file-with-paths-and-roots
        source
        (sym-i64-empty)
        roots)
        [(OkCompilerLoadWithPaths decls paths _ _)
          (match (tltest-build-harness source decls paths)
            [(InlineHarness program harness-paths count)
              (if (= count 0)
                (match test-mode
                  [(TestModeCheck) (tltest-no-tests-check decls paths)]
                  [(TestModeRun)
                    (tltest-no-tests-run source target mode opt-level)])
                (match test-mode
                  [(TestModeCheck)
                    (tltest-check-only program harness-paths count)]
                  [(TestModeRun)
                    (tltest-run-plan
                      source
                      program
                      harness-paths
                      target
                      mode
                      opt-level)]))])]
        [(ErrCompilerLoadWithPaths diag)
          (begin
            (print-error (compiler-diagnostic-render diag))
            1)])]))

(define (main) : i64
  (match (tltest-config (arg-count))
    [(OkTestConfig config) (tltest-run-config config)]
    [(ErrTestConfig message)
      (begin
        (print-error message)
        1)]))