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
  (TestConfig String String String CompilerLoadRootList TestMode))

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

(define (tltest-root-cons [root : String] [roots : CompilerLoadRootList]) : CompilerLoadRootList
  (CompilerLoadRootCons root roots))

(define (tltest-unknown-target [value : String]) : String
  (host-plan-cat3 "test: unknown target " value ""))

(define (tltest-unknown-mode [value : String]) : String
  (host-plan-cat3 "test: unknown backend mode " value ""))

(define (tltest-unsupported-mode [value : String]) : String
  (host-plan-cat3 "test: backend mode " value " is not implemented"))

(define (tltest-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [target : String]
  [mode : String]
  [roots : CompilerLoadRootList]
  [test-mode : TestMode]) : ResultTestConfig
  (if (>= idx count)
    (if has-source
      (OkTestConfig (TestConfig source target mode roots test-mode))
      (ErrTestConfig "test: expected source path"))
    (let ([current : String (arg idx)])
      (if (string-eq current "--check")
        (tltest-parse-options
          (+ idx 1)
          count
          source
          has-source
          target
          mode
          roots
          TestModeCheck)
        (if (string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ErrTestConfig "test: --target requires a value")
            (let ([value : String (arg (+ idx 1))])
              (if (host-plan-target-valid? value)
                (tltest-parse-options
                  (+ idx 2)
                  count
                  source
                  has-source
                  value
                  mode
                  roots
                  test-mode)
                (ErrTestConfig (tltest-unknown-target value)))))
          (if (string-eq current "--backend-mode")
            (if (>= (+ idx 1) count)
              (ErrTestConfig "test: --backend-mode requires a value")
              (let ([value : String (arg (+ idx 1))])
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
                      test-mode)
                    (ErrTestConfig (tltest-unsupported-mode value)))
                  (ErrTestConfig (tltest-unknown-mode value)))))
            (if (string-eq current "--stdlib-root")
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
                  test-mode))
              (if (host-plan-flag? current)
                (ErrTestConfig (string-append "test: unknown flag " current))
                (if has-source
                  (ErrTestConfig "test: accepts only one source file")
                  (tltest-parse-options
                    (+ idx 1)
                    count
                    current
                    true
                    target
                    mode
                    roots
                    test-mode))))))))))

(define (tltest-config [count : i64]) : ResultTestConfig
  (tltest-parse-options
    1
    count
    ""
    false
    "linux-x86_64"
    "scalar"
    CompilerLoadRootNil
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
      (let ([decl-path
          :
          String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) ""])])
        (let ([rest-paths
            :
            AstDeclPathList
            (match paths
              [(AstDeclPathCons _ path-rest) path-rest]
              [(AstDeclPathNil) AstDeclPathNil])])
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

(define (tltest-build-harness
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : InlineHarness
  (match (tltest-collect decls paths AstDeclNil AstDeclPathNil InlineTestNil 0)
    [(InlineCollect runtime-decls runtime-paths tests count)
      (let ([test-decls : AstDeclList (tltest-test-decls tests)]
        [test-paths : AstDeclPathList (tltest-test-paths tests)])
        (InlineHarness
          (AstProgram
            (tltest-decl-list-append
              runtime-decls
              (tltest-decl-list-append
                test-decls
                (AstDeclCons (tltest-main-decl tests count) AstDeclNil))))
          (tltest-path-list-append
            runtime-paths
            (tltest-path-list-append
              test-paths
              (AstDeclPathCons source AstDeclPathNil)))
          count))]))

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
  [target : String]
  [mode : String]) : i64
  (match (lower-compiler-program-with-path source program)
    [(OkCompilerLower ir spans)
      (match (compiler-backend-emit-program-with-spans-for-target
        (optimize-program ir)
        spans
        (tltest-backend-target target))
        [(OkCompilerBackend asm)
          (let ([asm-path : String (tltest-scratch-asm-path source)])
            (begin
              (write-file asm-path asm)
              (print-string (tltest-plan asm-path target mode))
              0))]
        [(ErrCompilerBackend diag)
          (begin
            (print-error (compiler-diagnostic-render diag))
            1)])]
    [(ErrCompilerLower diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (tltest-run-config [config : TestConfig]) : i64
  (match config
    [(TestConfig source target mode roots test-mode)
      (match (compiler-load-file-with-paths-and-roots
        source
        (sym-i64-empty)
        roots)
        [(OkCompilerLoadWithPaths decls paths _)
          (match (tltest-build-harness source decls paths)
            [(InlineHarness program harness-paths count)
              (match test-mode
                [(TestModeCheck)
                  (tltest-check-only program harness-paths count)]
                [(TestModeRun) (tltest-run-plan source program target mode)])])]
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