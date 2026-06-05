;; test_cli_core.tl - Selfhost test command logic.
;;
;; Discovers `(test name body...)` declarations through the selfhost loader,
;; lowers them into private unit-returning functions plus a generated `main`,
;; then assembles, links, and runs that generated harness directly. Normal
;; compile paths ignore `AstDeclTest`.
(import "../stdlib/io.tl")

(import "build_run_core.tl")

(import "compiler_backend.tl")

(import "compiler_load.tl")

(import "compiler_optimize.tl")

(import "compiler_typecheck.tl")

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
  (source-tool-cat3 "test: unknown target " value ""))

(define (tltest-unknown-mode [value : String]) : String
  (source-tool-cat3 "test: unknown backend mode " value ""))

(define (tltest-unsupported-mode [value : String]) : String
  (source-tool-cat3 "test: backend mode " value " is not implemented"))

(define (tltest-invalid-opt-level [value : String]) : String
  (source-tool-cat3
    "test: invalid --opt-level "
    value
    "; expected 0, 1, 2, or 3"))

(define (tltest-target-valid? [value : String]) : bool
  (match (source-tool-target value)
    [(OkSourceToolTarget _) true]
    [(ErrSourceToolTarget _) false]))

(define (tltest-backend-mode-valid? [value : String]) : bool
  (or
    (string-eq value "scalar")
    (or (string-eq value "avx2") (string-eq value "avx512"))))

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
              (if (tltest-target-valid? value)
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
              (if (tltest-backend-mode-valid? value)
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
        [(source-tool-flag? current)
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

;; Parse the `test` config from arguments starting at `start` (the index of the
;; first argument after any subcommand name). `count` is `(arg-count)`.
(define (tltest-config-from [start : i64] [count : i64]) : ResultTestConfig
  (tltest-parse-options
    start
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
      (let
        [rest : AstDeclList (box-get rest)]
        (tltest-decl-list-reverse-in rest (ast-decl-cons head out)))]))

(define (tltest-decl-list-reverse [items : AstDeclList]) : AstDeclList
  (tltest-decl-list-reverse-in items AstDeclNil))

(define (tltest-path-list-reverse-in
  [items : AstDeclPathList]
  [out : AstDeclPathList]) : AstDeclPathList
  (match items
    [(AstDeclPathNil) out]
    [(AstDeclPathCons head rest)
      (let
        [rest : AstDeclPathList (box-get rest)]
        (tltest-path-list-reverse-in rest (ast-decl-path-cons head out)))]))

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
      (let
        [rest : AstDeclList (box-get rest)]
        (ast-decl-cons head (tltest-decl-list-append rest right)))]))

(define (tltest-decl-list-count [items : AstDeclList]) : i64
  (match items
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (+ 1 (tltest-decl-list-count rest)))]))

(define (tltest-path-list-append
  [left : AstDeclPathList]
  [right : AstDeclPathList]) : AstDeclPathList
  (match left
    [(AstDeclPathNil) right]
    [(AstDeclPathCons head rest)
      (let
        [rest : AstDeclPathList (box-get rest)]
        (ast-decl-path-cons head (tltest-path-list-append rest right)))]))

(define (tltest-main-decl? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclDef name _ _) (string-eq name "main")]
    [(AstDeclDefFn name _ _ _) (string-eq name "main")]
    [(AstDeclDefMacro _ _ _ _) false]
    [(AstDeclUnsafe inner) (tltest-main-decl? inner)]
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
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) ""])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
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
          [(AstDeclIncludeStr _ _)
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
                (ast-decl-cons decl runtime-rev)
                (ast-decl-path-cons decl-path path-rev)
                tests-rev
                test-count))]))]))

(define (tltest-print-expr [text : String]) : AstExpr
  (ast-expr-call
    (AstExprVar "__tl_test_print_error")
    (ast-expr-cons (AstExprLiteral (AstLitString text)) AstExprNil)))

(define (tltest-call-expr [name : String]) : AstExpr
  (ast-expr-call (AstExprVar name) AstExprNil))

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

(define (tltest-print-runtime-write-symbol [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux) "write"]
    [(BackendTargetWindows) "_write"]))

(define (tltest-print-runtime-write-type) : AstType
  (ast-ty-func
    (ast-type-cons
      (AstTyI32)
      (ast-type-cons
        (ast-ty-ptr (AstTyU8))
        (ast-type-cons (AstTyI32) AstTypeNil)))
    (AstTyI32)))

(define (tltest-print-runtime-write-decl [target : CompilerBackendTarget]) : AstDecl
  (AstDeclExtern
    "__tl_test_write"
    (AstExternMetadata
      (AstExternAbiC)
      (tltest-print-runtime-write-symbol target)
      AstExternLinkInputNil)
    (tltest-print-runtime-write-type)))

(define (tltest-text-param-list) : AstParamList
  (ast-param-cons (AstParam "text" (AstTyString) false) AstParamNil))

(define (tltest-text-length-expr) : AstExpr
  (ast-expr-call
    (AstExprVar "string-length")
    (ast-expr-cons (AstExprVar "text") AstExprNil)))

(define (tltest-print-runtime-write-call) : AstExpr
  (ast-expr-call
    (AstExprVar "__tl_test_write")
    (ast-expr-cons
      (ast-expr-cast (AstExprLiteral (AstLitInt 2)) (AstTyI32))
      (ast-expr-cons
        (AstExprUnsafe
          (ast-expr-cons (ast-expr-string-data (AstExprVar "text")) AstExprNil))
        (ast-expr-cons
          (ast-expr-cast (tltest-text-length-expr) (AstTyI32))
          AstExprNil)))))

(define (tltest-print-runtime-print-decl) : AstDecl
  (AstDeclDefFn
    "__tl_test_print_error"
    (tltest-text-param-list)
    (AstTyUnit)
    (AstExprBegin
      (ast-expr-cons
        (tltest-print-runtime-write-call)
        (ast-expr-cons (AstExprLiteral (AstLitUnit)) AstExprNil)))))

(define (tltest-print-runtime-decls [target : CompilerBackendTarget]) : AstDeclList
  (ast-decl-cons
    (tltest-print-runtime-write-decl target)
    (ast-decl-cons (tltest-print-runtime-print-decl) AstDeclNil)))

(define (tltest-program-with-print-runtime
  [program : AstProgram]
  [target : CompilerBackendTarget]) : AstProgram
  (match program
    [(AstProgram decls)
      (AstProgram
        (tltest-decl-list-append (tltest-print-runtime-decls target) decls))]))

(define (tltest-paths-with-print-runtime [paths : AstDeclPathList]) : AstDeclPathList
  (ast-decl-path-cons
    "<generated test runtime>"
    (ast-decl-path-cons "<generated test runtime>" paths)))

(define (tltest-main-exprs [tests : InlineTestList] [count : i64]) : AstExprList
  (match tests
    [(InlineTestNil)
      (ast-expr-cons
        (tltest-print-expr (tltest-summary-line count))
        (ast-expr-cons (AstExprLiteral (AstLitInt 0)) AstExprNil))]
    [(InlineTestCons test rest)
      (match test
        [(InlineTest _ _ _ _ private-name)
          (ast-expr-cons
            (tltest-print-expr (tltest-running-line test))
            (ast-expr-cons
              (tltest-call-expr private-name)
              (ast-expr-cons
                (tltest-print-expr (tltest-ok-line test))
                (tltest-main-exprs rest count))))])]))

(define (tltest-test-decls [tests : InlineTestList]) : AstDeclList
  (match tests
    [(InlineTestNil) AstDeclNil]
    [(InlineTestCons test rest)
      (match test
        [(InlineTest _ _ _ body private-name)
          (ast-decl-cons
            (AstDeclDefFn private-name AstParamNil (AstTyUnit) body)
            (tltest-test-decls rest))])]))

(define (tltest-test-paths [tests : InlineTestList]) : AstDeclPathList
  (match tests
    [(InlineTestNil) AstDeclPathNil]
    [(InlineTestCons test rest)
      (match test
        [(InlineTest _ path _ _ _)
          (ast-decl-path-cons path (tltest-test-paths rest))])]))

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
      (let
        [rest : AstExprList (box-get rest)]
        (tltest-reach-mark-expr-list rest (tltest-reach-mark-expr head names)))]))

(define (tltest-reach-mark-let-bindings
  [bindings : AstLetBindingList]
  [names : SymI64Env]) : SymI64Env
  (match bindings
    [(AstLetBindingNil) names]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ _ value-box)
            (let
              [value : AstExpr (box-get value-box)]
              (tltest-reach-mark-let-bindings
                rest
                (tltest-reach-mark-expr value names)))]))]))

(define (tltest-reach-mark-resource-bindings
  [bindings : AstResourceBindingList]
  [names : SymI64Env]) : SymI64Env
  (match bindings
    [(AstResourceBindingNil) names]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding _ init-box cleanup-box)
            (let
              [init : AstExpr (box-get init-box)]
              [cleanup : AstExpr (box-get cleanup-box)]
              (tltest-reach-mark-resource-bindings
                rest
                (tltest-reach-mark-expr
                  cleanup
                  (tltest-reach-mark-expr init names))))]))]))

(define (tltest-reach-mark-match-arms
  [arms : AstMatchArmList]
  [names : SymI64Env]) : SymI64Env
  (match arms
    [(AstMatchArmNil) names]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm _ body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (tltest-reach-mark-match-arms
                rest
                (tltest-reach-mark-expr body names)))]))]))

(define (tltest-reach-mark-expr [expr : AstExpr] [names : SymI64Env]) : SymI64Env
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprLiteral _) names]
    [(AstExprVar name) (tltest-reach-mark-name names name)]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (tltest-reach-mark-expr right (tltest-reach-mark-expr left names)))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (tltest-reach-mark-expr-list args (tltest-reach-mark-expr func names)))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (tltest-reach-mark-expr
          else-branch
          (tltest-reach-mark-expr
            then-branch
            (tltest-reach-mark-expr cond names))))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tltest-reach-mark-expr
          body
          (tltest-reach-mark-let-bindings bindings names)))]
    [(AstExprLambda _ _ body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tltest-reach-mark-expr body names))]
    [(AstExprTuple exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprTupleRef tuple-box _)
      (let
        [tuple : AstExpr (box-get tuple-box)]
        (tltest-reach-mark-expr tuple names))]
    [(AstExprArray exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprMakeArray _ len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (tltest-reach-mark-expr len names))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (tltest-reach-mark-expr index (tltest-reach-mark-expr array names)))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
        (tltest-reach-mark-expr
          value
          (tltest-reach-mark-expr index (tltest-reach-mark-expr array names))))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-expr array names)))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (box-get text-box)]
        [index : AstExpr (box-get index-box)]
        (tltest-reach-mark-expr index (tltest-reach-mark-expr text names)))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
        (tltest-reach-mark-expr body (tltest-reach-mark-expr cond names)))]
    [(AstExprBegin exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprUnsafe exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-name names name)))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprBorrow _ place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (tltest-reach-mark-expr place names))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
        (tltest-reach-mark-match-arms
          arms
          (tltest-reach-mark-expr scrutinee names)))]
    [(AstExprForeach _ _ start-box end-box body-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (tltest-reach-mark-expr
          body
          (tltest-reach-mark-expr end (tltest-reach-mark-expr start names))))]
    [(AstExprSpmdReduce _ _ _ start-box end-box init-box value-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (tltest-reach-mark-expr
          value
          (tltest-reach-mark-expr
            init
            (tltest-reach-mark-expr end (tltest-reach-mark-expr start names)))))]
    [(AstExprStructGet receiver-box _)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (tltest-reach-mark-expr receiver names))]
    [(AstExprWithRegion _ body) (tltest-reach-mark-expr-list body names)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (tltest-reach-mark-expr-list
          body
          (tltest-reach-mark-expr scratch names)))]
    [(AstExprWithResource bindings body)
      (tltest-reach-mark-expr-list
        body
        (tltest-reach-mark-resource-bindings bindings names))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprBorrow _ place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (tltest-reach-mark-expr place names))]
    [(AstExprTypeLiteral _) names]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprQuote _) names]
    [(AstExprQuasiquote _) names]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprPtrNull _) names]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-expr ptr names)))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
        (tltest-reach-mark-expr offset (tltest-reach-mark-expr ptr names)))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (box-get value-box)]
        (tltest-reach-mark-expr value names))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
        (tltest-reach-mark-expr len (tltest-reach-mark-expr ptr names)))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprProgramArgc) names]
    [(AstExprProgramArgv) names]
    [(AstExprProgramEnvp) names]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (box-get index-box)]
        (tltest-reach-mark-expr index names))]))

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
    [(AstDeclDefMacro _ _ _ _) names]
    [(AstDeclUnsafe inner) (tltest-reach-mark-decl inner names)]
    [_ names]))

(define (tltest-reach-mark-decls [decls : AstDeclList] [names : SymI64Env]) : SymI64Env
  (match decls
    [(AstDeclNil) names]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (tltest-reach-mark-decls rest (tltest-reach-mark-decl decl names)))]))

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
    [(AstDeclDefMacro _ _ _ _) true]
    [(AstDeclUnsafe inner) (tltest-reachable-runtime-decl? inner names)]
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
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) ""])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (if (tltest-reachable-runtime-decl? decl names)
          (tltest-prune-runtime-decls-in
            rest
            rest-paths
            names
            (ast-decl-cons decl decls-rev)
            (ast-decl-path-cons decl-path paths-rev))
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
                    (ast-decl-cons (tltest-main-decl tests count) AstDeclNil))))
              (tltest-path-list-append
                pruned-paths
                (tltest-path-list-append
                  test-paths
                  (ast-decl-path-cons source AstDeclPathNil)))
              count)]))]))

(define (tltest-check-only
  [program : AstProgram]
  [paths : AstDeclPathList]
  [count : i64]
  [target : CompilerBackendTarget]) : i64
  (match (typecheck-compiler-program-with-paths
    (tltest-program-with-print-runtime program target)
    (tltest-paths-with-print-runtime paths))
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

(define (tltest-stderr-ends-with-newline? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    (if (= n 0)
      true
      (let
        [last : char (string-ref text (- n 1))]
        (or (= last #\newline') (= last #\return'))))))

(define (tltest-report-child-status [output : ProcessOutput]) : unit
  (begin
    (if (tltest-stderr-ends-with-newline? (process-output-stderr output))
      unit
      (print-error "\n"))
    (print-error
      (string-append
        "typelisp test: test executable exited with exit status: "
        (string-append (int->string (process-output-status output)) "\n")))))

(define (tltest-run-harness-in-temp
  [source : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [temp-dir : String]) : i64
  (let
    [asm-path : String (source-tool-asm-path temp-dir source)]
    [obj-path : String (source-tool-obj-path temp-dir source target)]
    [bin-path : String (source-tool-temp-bin-path temp-dir source target)]
    (match (lower-compiler-program-with-decl-paths source program paths)
      [(OkCompilerLower ir spans)
        (match (optimize-program-with-spans-and-level ir spans opt-level)
          [(CompilerOptimizedProgram optimized optimized-spans)
            (match (compiler-backend-emit-program-with-spans-for-target
              optimized
              optimized-spans
              target)
              [(OkCompilerBackend asm)
                (match (source-tool-write-file
                  asm-path
                  asm
                  "test: failed to write assembly artifact")
                  [(SourceToolCommandErr message)
                    (begin
                      (print-error message)
                      (source-tool-clean-temp
                        temp-dir
                        asm-path
                        obj-path
                        bin-path
                        true)
                      1)]
                  [(SourceToolCommandOk)
                    (match (source-tool-assemble-and-link
                      target
                      asm-path
                      obj-path
                      bin-path
                      (source-tool-link-inputs-empty))
                      [(SourceToolCommandErr message)
                        (begin
                          (print-error message)
                          (source-tool-clean-temp
                            temp-dir
                            asm-path
                            obj-path
                            bin-path
                            true)
                          1)]
                      [(SourceToolCommandOk)
                        (match (source-tool-run-executable
                          bin-path
                          target
                          (process-args-empty))
                          [(OkProcessOutput output)
                            (let
                              [status : i64 (process-output-status output)]
                              (begin
                                (source-tool-forward-output output)
                                (if (= status 0)
                                  unit
                                  (tltest-report-child-status output))
                                (source-tool-clean-temp
                                  temp-dir
                                  asm-path
                                  obj-path
                                  bin-path
                                  true)
                                ;; A failed test executable (including one that
                                ;; panics/aborts, which exits 134) is a test
                                ;; FAILURE, not a host crash: report the raw
                                ;; status above, but exit cleanly with 1 so CI
                                ;; does not retry it as a transient #1204 segfault.
                                (if (= status 0)
                                  0
                                  1)))]
                          [(ErrProcessOutput error)
                            (begin
                              (print-error
                                (string-append
                                  (string-append
                                    "Error: failed to run test executable '"
                                    bin-path)
                                  (string-append
                                    "': "
                                    (process-error-message error))))
                              (source-tool-clean-temp
                                temp-dir
                                asm-path
                                obj-path
                                bin-path
                                true)
                              1)])])])]
              [(ErrCompilerBackend diag)
                (begin
                  (print-error (compiler-diagnostic-render diag))
                  (source-tool-clean-temp
                    temp-dir
                    asm-path
                    obj-path
                    bin-path
                    true)
                  1)])])]
      [(ErrCompilerLower diag)
        (begin
          (print-error (compiler-diagnostic-render diag))
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          1)])))

(define (tltest-run-direct
  [source : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [target : String]
  [opt-level : i64]) : i64
  (match (source-tool-target target)
    [(ErrSourceToolTarget _)
      (begin
        (print-error (tltest-unknown-target target))
        1)]
    [(OkSourceToolTarget backend-target)
      (match (source-tool-create-temp-dir "typelisp-test")
        [(OkSourceToolString temp-dir)
          (tltest-run-harness-in-temp
            source
            (tltest-program-with-print-runtime program backend-target)
            (tltest-paths-with-print-runtime paths)
            backend-target
            opt-level
            temp-dir)]
        [(ErrSourceToolString message)
          (begin
            (print-error
              (string-append "test: failed to create temp dir: " message))
            1)])]))

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
  ;; --check` owns source typechecking; run mode only needs the zero-test runner.
  (tltest-run-direct
    source
    (AstProgram (ast-decl-cons (tltest-main-decl InlineTestNil 0) AstDeclNil))
    (ast-decl-path-cons source AstDeclPathNil)
    target
    opt-level))

(define (tltest-run-config [config : TestConfig]) : i64
  (match config
    [(TestConfig source target mode roots opt-level test-mode)
      (match (source-tool-target target)
        [(ErrSourceToolTarget _)
          (begin
            (print-error (tltest-unknown-target target))
            1)]
        [(OkSourceToolTarget backend-target)
          (match (compiler-load-file-with-paths-and-roots-cfg
            source
            (sym-i64-empty)
            roots
            (compiler-driver-target-cfgs backend-target (compiler-cfg-empty)))
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
                        (tltest-check-only
                          program
                          harness-paths
                          count
                          backend-target)]
                      [(TestModeRun)
                        (tltest-run-direct
                          source
                          program
                          harness-paths
                          target
                          opt-level)]))])]
            [(ErrCompilerLoadWithPaths diag)
              (begin
                (print-error (compiler-diagnostic-render diag))
                1)])])]))

;; Run the `test` command over arguments starting at `start`.
(define (tltest-run-from [start : i64] [count : i64]) : i64
  (match (tltest-config-from start count)
    [(OkTestConfig config) (tltest-run-config config)]
    [(ErrTestConfig message)
      (begin
        (print-error message)
        1)]))