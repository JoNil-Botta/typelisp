;; test_cli_core.tl - Selfhost test command logic.
;;
;; Discovers `(test name body...)` declarations through the selfhost loader,
;; lowers them into private unit-returning functions plus a generated `main`,
;; then assembles, links, and runs that generated harness directly. Normal
;; compile paths ignore `AstDeclTest`.
(import "../stdlib/core_macros.tl" module stdlib.core-macros as core)

(import "../stdlib/io.tl")

(import "build_run_core.tl")

(import "compiler_backend.tl")

(import "compiler_load.tl")

(import "package_source_core.tl")

(import "compiler_optimize.tl")

(import "compiler_typecheck.tl")

(import "../stdlib/string.tl")

(import "../stdlib/str_cat.tl")

(defenum TestMode
  (TestModeRun)
  (TestModeCheck))

(defenum TestConfig
  (TestFileConfig String String String StringVec i64 TestMode)
  (TestBatchConfig StringVec String String StringVec i64 TestMode)
  (TestPackageConfig String bool String String StringVec i64 TestMode))

(defenum ResultTestConfig
  (OkTestConfig TestConfig)
  (ErrTestConfig String))

(defenum TestMaybeString
  (TestNoString)
  (TestSomeString String))

(defenum ResultTestBatchPaths
  (OkTestBatchPaths StringVec)
  (ErrTestBatchPaths String))

(defenum InlineTest
  (InlineTest String String i64 i64 String))

(defenum InlineCollect
  (InlineCollect (Array AstDecl) (Array String) (Array InlineTest)))

(defenum InlineHarness
  (InlineHarness AstProgram AstDeclPathList i64))

(defenum InlineRuntimeDecls
  (InlineRuntimeDecls (Array AstDecl) (Array String)))

(defenum ResultTestPackageTotals
  (OkTestPackageTotals i64 i64)
  (ErrTestPackageTotals i64))

(defenum ResultTestFileCheck
  (OkTestFileCheck i64)
  (ErrTestFileCheck i64))

(define (tltest-unknown-target [value : String]) : String
  (str-cat "test: unknown target " value ""))

(define (tltest-unknown-mode [value : String]) : String
  (str-cat "test: unknown backend mode " value ""))

(define (tltest-unsupported-mode [value : String]) : String
  (str-cat "test: backend mode " value " is not implemented"))

(define (tltest-invalid-opt-level [value : String]) : String
  (str-cat "test: invalid --opt-level " value "; expected 0, 1, 2, or 3"))

(define (tltest-batch-line-end [text : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (or
            (= (string-ref text i) #\newline')
            (= (string-ref text i) #\return'))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (tltest-batch-next-line-start
  [text : String]
  [line-end : i64]
  [n : i64]) : i64
  (begin
    (unless (< line-end n) (return line-end))
    (let
      [c : char (string-ref text line-end)]
      (begin
        (unless (= c #\return') (return (+ line-end 1)))
        (unless (< (+ line-end 1) n) (return (+ line-end 1)))
        (if (= (string-ref text (+ line-end 1)) #\newline')
          (+ line-end 2)
          (+ line-end 1))))))

(define (tltest-batch-paths-from-text [text : String]) : StringVec
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [paths : StringVec (string-vec-new)]
    (begin
      (while (< i n)
        (let
          [line-end : i64 (tltest-batch-line-end text i n)]
          [line : String (substring text i (- line-end i))]
          (begin
            (if (> (string-length line) 0)
              (set! paths (string-vec-push paths line))
              unit)
            (set! i (tltest-batch-next-line-start text line-end n)))))
      paths)))

(define (tltest-batch-paths [list-path : String]) : ResultTestBatchPaths
  (match (try-read-file (& list-path))
    [(OkIoString text) (OkTestBatchPaths (tltest-batch-paths-from-text text))]
    [(ErrIoString error)
      (ErrTestBatchPaths
        (string-append
          "test: failed to read --batch list file: "
          (io-error-message error)))]))

(define (tltest-config-finish
  [source : String]
  [has-source : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [mode : String]
  [roots : StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [batch-list : TestMaybeString]) : ResultTestConfig
  (match batch-list
    [(TestSomeString list-path)
      (if has-manifest
        (ErrTestConfig "test: cannot combine --batch with --manifest-path")
        (if has-source
          (ErrTestConfig "test: cannot combine input paths with --batch")
          (match test-mode
            [(TestModeRun) (ErrTestConfig "test: --batch requires --check")]
            [(TestModeCheck)
              (match (tltest-batch-paths list-path)
                [(OkTestBatchPaths paths)
                  (if (string-vec-is-empty? paths)
                    (ErrTestConfig "test: --batch list is empty")
                    (OkTestConfig
                      (TestBatchConfig
                        paths
                        target
                        mode
                        roots
                        opt-level
                        test-mode)))]
                [(ErrTestBatchPaths message) (ErrTestConfig message)])])))]
    [(TestNoString)
      (if has-source
        (if has-manifest
          (ErrTestConfig
            "test: cannot combine source path with --manifest-path")
          (OkTestConfig
            (TestFileConfig source target mode roots opt-level test-mode)))
        (OkTestConfig
          (TestPackageConfig
            manifest-path
            has-manifest
            target
            mode
            roots
            opt-level
            test-mode)))]))

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
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [mode : String]
  [roots : StringVec]
  [has-opt-level : bool]
  [opt-level : i64]
  [test-mode : TestMode]
  [batch-list : TestMaybeString]) : ResultTestConfig
  (if (>= idx count)
    (tltest-config-finish
      source
      has-source
      manifest-path
      has-manifest
      target
      mode
      roots
      opt-level
      test-mode
      batch-list)
    (let
      [current : String (arg idx)]
      (core/cond
        (string-eq current "--check")
        (tltest-parse-options
          (+ idx 1)
          count
          source
          has-source
          manifest-path
          has-manifest
          target
          mode
          roots
          has-opt-level
          opt-level
          TestModeCheck
          batch-list)
        (string-eq current "--target")
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
                manifest-path
                has-manifest
                value
                mode
                roots
                has-opt-level
                opt-level
                test-mode
                batch-list)
              (ErrTestConfig (tltest-unknown-target value)))))
        (string-eq current "--backend-mode")
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
                  manifest-path
                  has-manifest
                  target
                  value
                  roots
                  has-opt-level
                  opt-level
                  test-mode
                  batch-list)
                (ErrTestConfig (tltest-unsupported-mode value)))
              (ErrTestConfig (tltest-unknown-mode value)))))
        (string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ErrTestConfig "test: --stdlib-root requires a value")
          (tltest-parse-options
            (+ idx 2)
            count
            source
            has-source
            manifest-path
            has-manifest
            target
            mode
            (string-vec-push roots (arg (+ idx 1)))
            has-opt-level
            opt-level
            test-mode
            batch-list))
        (string-eq current "--manifest-path")
        (if (>= (+ idx 1) count)
          (ErrTestConfig "test: --manifest-path requires a value")
          (if has-manifest
            (ErrTestConfig "test: duplicate --manifest-path")
            (tltest-parse-options
              (+ idx 2)
              count
              source
              has-source
              (arg (+ idx 1))
              true
              target
              mode
              roots
              has-opt-level
              opt-level
              test-mode
              batch-list)))
        (string-eq current "--batch")
        (if (>= (+ idx 1) count)
          (ErrTestConfig "test: --batch requires a value")
          (match batch-list
            [(TestSomeString _) (ErrTestConfig "test: duplicate --batch")]
            [(TestNoString)
              (tltest-parse-options
                (+ idx 2)
                count
                source
                has-source
                manifest-path
                has-manifest
                target
                mode
                roots
                has-opt-level
                opt-level
                test-mode
                (TestSomeString (arg (+ idx 1))))]))
        (string-eq current "--opt-level")
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
                    manifest-path
                    has-manifest
                    target
                    mode
                    roots
                    true
                    parsed-level
                    test-mode
                    batch-list)]
                [(ErrCompilerOptimizeLevel)
                  (ErrTestConfig (tltest-invalid-opt-level value))]))))
        (source-tool-flag? current)
        (ErrTestConfig (string-append "test: unknown flag " current))
        has-source
        (ErrTestConfig "test: accepts only one source file")
        (tltest-parse-options
          (+ idx 1)
          count
          current
          true
          manifest-path
          has-manifest
          target
          mode
          roots
          has-opt-level
          opt-level
          test-mode
          batch-list)))))

;; Parse the `test` config from arguments starting at `start` (the index of the
;; first argument after any subcommand name). `count` is `(arg-count)`.
(define (tltest-config-from [start : i64] [count : i64]) : ResultTestConfig
  (tltest-parse-options
    start
    count
    ""
    false
    ""
    false
    "linux-x86_64"
    "scalar"
    (string-vec-new)
    false
    (compiler-optimize-default-level)
    TestModeRun
    (TestNoString)))

(define (tltest-decls-onto
  [items : (Array AstDecl)]
  [index : i64]
  [out : AstDeclList]) : AstDeclList
  (if (< index 0)
    out
    (tltest-decls-onto
      items
      (- index 1)
      (ast-decl-cons (array-ref items index) out))))

(define (tltest-paths-onto
  [items : (Array String)]
  [index : i64]
  [out : AstDeclPathList]) : AstDeclPathList
  (if (< index 0)
    out
    (tltest-paths-onto
      items
      (- index 1)
      (ast-decl-path-cons (array-ref items index) out))))

(define (tltest-main-decl? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclDef name _ _) (= name (intern "main"))]
    [(AstDeclDefFn name _ _ _ _) (= name (intern "main"))]
    [(AstDeclDefMacro _ _ _ _) false]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-main-decl? inner))]
    [_ false]))

(define (tltest-source-line [span : AstSourceSpan]) : i64
  (struct-get span start-line))

(define (tltest-private-name [idx : i64]) : String
  (string-append "__tl_inline_test_" (int->string idx)))

(define (tltest-collect-in
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [runtime-decls : (Array AstDecl)]
  [runtime-paths : (Array String)]
  [tests : (Array InlineTest)]) : InlineCollect
  (match decls
    [(AstDeclNil) (InlineCollect runtime-decls runtime-paths tests)]
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
          [(AstDeclTest name body-box span)
            (let
              [body : i64 body-box]
              [test-count : i64 (array-length tests)]
              (begin
                (array-push!
                  tests
                  (InlineTest
                    (intern-str name)
                    decl-path
                    (tltest-source-line span)
                    body
                    (tltest-private-name test-count)))
                (tltest-collect-in
                  rest
                  rest-paths
                  runtime-decls
                  runtime-paths
                  tests)))]
          [(AstDeclImport _)
            (begin
              (array-push! runtime-decls decl)
              (array-push! runtime-paths decl-path)
              (tltest-collect-in
                rest
                rest-paths
                runtime-decls
                runtime-paths
                tests))]
          [(AstDeclIncludeStr _ _)
            (tltest-collect-in
              rest
              rest-paths
              runtime-decls
              runtime-paths
              tests)]
          [_
            (if (tltest-main-decl? decl)
              (tltest-collect-in
                rest
                rest-paths
                runtime-decls
                runtime-paths
                tests)
              (begin
                (array-push! runtime-decls decl)
                (array-push! runtime-paths decl-path)
                (tltest-collect-in
                  rest
                  rest-paths
                  runtime-decls
                  runtime-paths
                  tests)))]))]))

(define (tltest-collect [decls : AstDeclList] [paths : AstDeclPathList]) : InlineCollect
  (tltest-collect-in
    decls
    paths
    (make-array AstDecl 0)
    (make-array String 0)
    (make-array InlineTest 0)))

(define (tltest-print-expr [text : String]) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern "__tl_test_print_error")))
    (ast-expr-cons
      (ast-node-push (AstExprLiteral (AstLitString text)))
      AstExprNil)))

(define (tltest-call-expr [name : String]) : i64
  (ast-expr-call (ast-node-push (AstExprVar (intern name))) AstExprNil))

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

(define (tltest-print-runtime-write-params) : AstParamList
  (ast-param-cons
    (ast-param "fd" (AstTyI32) false)
    (ast-param-cons
      (ast-param "buf" (ast-ty-ptr (AstTyU8)) false)
      (ast-param-cons (ast-param "n" (AstTyI32) false) AstParamNil))))

(define (tltest-linux-write-ptr-arg) : i64
  (ast-node-push
    (AstExprUnsafe
      (ast-expr-cons
        (ast-expr-cast
          (ast-expr-ptr-to-int (ast-node-push (AstExprVar (intern "buf"))))
          (AstTyI64))
        AstExprNil))))

(define (tltest-linux-write-syscall) : i64
  (ast-expr-syscall
    (ast-expr-cons
      (ast-node-push (AstExprLiteral (AstLitInt 1)))
      (ast-expr-cons
        (ast-expr-cast (ast-node-push (AstExprVar (intern "fd"))) (AstTyI64))
        (ast-expr-cons
          (tltest-linux-write-ptr-arg)
          (ast-expr-cons
            (ast-expr-cast (ast-node-push (AstExprVar (intern "n"))) (AstTyI64))
            AstExprNil))))))

(define (tltest-linux-print-runtime-write-decl) : AstDecl
  (ast-decl-def-fn
    "__tl_test_write"
    (tltest-print-runtime-write-params)
    (AstTyI32)
    (ast-expr-cast (tltest-linux-write-syscall) (AstTyI32))))

(define (tltest-windows-get-std-handle-decl) : AstDecl
  (ast-decl-extern
    "__tl_test_get_std_handle"
    (AstExternFunction)
    (AstExternMetadata
      (AstExternAbiC)
      "GetStdHandle"
      AstExternLinkInputNil
      true)
    (ast-ty-func (ast-type-cons (AstTyI32) AstTypeNil) (AstTyI64))))

(define (tltest-windows-write-file-decl) : AstDecl
  (ast-decl-extern
    "__tl_test_write_file"
    (AstExternFunction)
    (AstExternMetadata (AstExternAbiC) "WriteFile" AstExternLinkInputNil true)
    (ast-ty-func
      (ast-type-cons
        (AstTyI64)
        (ast-type-cons
          (ast-ty-ptr (AstTyU8))
          (ast-type-cons
            (AstTyI32)
            (ast-type-cons
              (ast-ty-mut-ptr (AstTyI32))
              (ast-type-cons (AstTyI64) AstTypeNil)))))
      (AstTyI32))))

(define (tltest-windows-get-stderr-handle-expr) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern "__tl_test_get_std_handle")))
    (ast-expr-cons
      (ast-expr-cast
        (ast-node-push (AstExprLiteral (AstLitInt -12)))
        (AstTyI32))
      AstExprNil)))

(define (tltest-windows-write-file-call) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern "__tl_test_write_file")))
    (ast-expr-cons
      (ast-node-push (AstExprVar (intern "handle")))
      (ast-expr-cons
        (ast-node-push (AstExprVar (intern "buf")))
        (ast-expr-cons
          (ast-node-push (AstExprVar (intern "n")))
          (ast-expr-cons
            (ast-node-push (AstExprPtrNull (ast-ty-mut-ptr (AstTyI32))))
            (ast-expr-cons
              (ast-node-push (AstExprLiteral (AstLitInt 0)))
              AstExprNil)))))))

(define (tltest-windows-write-body) : i64
  (ast-expr-let
    (ast-let-binding-cons
      (ast-let-binding
        "handle"
        (AstSomeType (AstTyI64))
        (tltest-windows-get-stderr-handle-expr))
      (ast-let-binding-cons
        (ast-let-binding
          "ok"
          (AstSomeType (AstTyI32))
          (tltest-windows-write-file-call))
        AstLetBindingNil))
    (ast-expr-if
      (ast-expr-binary
        (AstBinEq)
        (ast-node-push (AstExprVar (intern "ok")))
        (ast-expr-cast
          (ast-node-push (AstExprLiteral (AstLitInt 0)))
          (AstTyI32)))
      (ast-expr-cast (ast-node-push (AstExprLiteral (AstLitInt -1))) (AstTyI32))
      (ast-node-push (AstExprVar (intern "n"))))))

(define (tltest-windows-print-runtime-write-decl) : AstDecl
  (ast-decl-def-fn
    "__tl_test_write"
    (tltest-print-runtime-write-params)
    (AstTyI32)
    (tltest-windows-write-body)))

(define (tltest-print-runtime-write-decl [target : CompilerBackendTarget]) : AstDecl
  (match target
    [(BackendTargetLinux) (tltest-linux-print-runtime-write-decl)]
    [(BackendTargetWindows) (tltest-windows-print-runtime-write-decl)]))

(define (tltest-text-param-list) : AstParamList
  (ast-param-cons (ast-param "text" (AstTyString) false) AstParamNil))

(define (tltest-text-length-expr) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern "string-length")))
    (ast-expr-cons (ast-node-push (AstExprVar (intern "text"))) AstExprNil)))

(define (tltest-print-runtime-write-call) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern "__tl_test_write")))
    (ast-expr-cons
      (ast-expr-cast (ast-node-push (AstExprLiteral (AstLitInt 2))) (AstTyI32))
      (ast-expr-cons
        (ast-node-push
          (AstExprUnsafe
            (ast-expr-cons
              (ast-expr-string-data
                (ast-node-push (AstExprVar (intern "text"))))
              AstExprNil)))
        (ast-expr-cons
          (ast-expr-cast (tltest-text-length-expr) (AstTyI32))
          AstExprNil)))))

(define (tltest-print-runtime-print-decl) : AstDecl
  (ast-decl-def-fn
    "__tl_test_print_error"
    (tltest-text-param-list)
    (AstTyUnit)
    (ast-node-push
      (AstExprBegin
        (ast-expr-cons
          (tltest-print-runtime-write-call)
          (ast-expr-cons
            (ast-node-push (AstExprLiteral (AstLitUnit)))
            AstExprNil))))))

(define (tltest-program-with-print-runtime
  [program : AstProgram]
  [target : CompilerBackendTarget]) : AstProgram
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-program
          (match target
            [(BackendTargetLinux)
              (ast-decl-cons
                (tltest-print-runtime-write-decl target)
                (ast-decl-cons (tltest-print-runtime-print-decl) decls))]
            [(BackendTargetWindows)
              (ast-decl-cons
                (tltest-windows-get-std-handle-decl)
                (ast-decl-cons
                  (tltest-windows-write-file-decl)
                  (ast-decl-cons
                    (tltest-print-runtime-write-decl target)
                    (ast-decl-cons (tltest-print-runtime-print-decl) decls))))])))]))

(define (tltest-paths-with-print-runtime-count
  [count : i64]
  [paths : AstDeclPathList]) : AstDeclPathList
  (if (<= count 0)
    paths
    (ast-decl-path-cons
      "<generated test runtime>"
      (tltest-paths-with-print-runtime-count (- count 1) paths))))

(define (tltest-paths-with-print-runtime
  [target : CompilerBackendTarget]
  [paths : AstDeclPathList]) : AstDeclPathList
  (match target
    [(BackendTargetLinux) (tltest-paths-with-print-runtime-count 2 paths)]
    [(BackendTargetWindows) (tltest-paths-with-print-runtime-count 4 paths)]))

(define (tltest-main-exprs-from
  [tests : (Array InlineTest)]
  [index : i64]
  [out : AstExprList]) : AstExprList
  (if (< index 0)
    out
    (let
      [test : InlineTest (array-ref tests index)]
      (match test
        [(InlineTest _ _ _ _ private-name)
          (tltest-main-exprs-from
            tests
            (- index 1)
            (ast-expr-cons
              (tltest-print-expr (tltest-running-line test))
              (ast-expr-cons
                (tltest-call-expr private-name)
                (ast-expr-cons (tltest-print-expr (tltest-ok-line test)) out))))]))))

(define (tltest-main-exprs [tests : (Array InlineTest)]) : AstExprList
  (let
    [count : i64 (array-length tests)]
    (tltest-main-exprs-from
      tests
      (- count 1)
      (ast-expr-cons
        (tltest-print-expr (tltest-summary-line count))
        (ast-expr-cons
          (ast-node-push (AstExprLiteral (AstLitInt 0)))
          AstExprNil)))))

(define (tltest-test-decls-onto
  [tests : (Array InlineTest)]
  [index : i64]
  [out : AstDeclList]) : AstDeclList
  (if (< index 0)
    out
    (let
      [test : InlineTest (array-ref tests index)]
      (match test
        [(InlineTest _ _ _ body private-name)
          (tltest-test-decls-onto
            tests
            (- index 1)
            (ast-decl-cons
              (ast-decl-def-fn private-name AstParamNil (AstTyUnit) body)
              out))]))))

(define (tltest-test-paths-onto
  [tests : (Array InlineTest)]
  [index : i64]
  [out : AstDeclPathList]) : AstDeclPathList
  (if (< index 0)
    out
    (let
      [test : InlineTest (array-ref tests index)]
      (match test
        [(InlineTest _ path _ _ _)
          (tltest-test-paths-onto
            tests
            (- index 1)
            (ast-decl-path-cons path out))]))))

(define (tltest-main-decl [tests : (Array InlineTest)]) : AstDecl
  (ast-decl-def-fn
    "main"
    AstParamNil
    (AstTyI64)
    (ast-node-push (AstExprBegin (tltest-main-exprs tests)))))

(define (tltest-empty-main-decl) : AstDecl
  (tltest-main-decl (make-array InlineTest 0)))

(define (tltest-reach-mark-name [names : StringI64Map] [name : String]) : StringI64Map
  (if (string-i64-map-contains? names name)
    names
    (string-i64-map-put names name 1)))

(define (tltest-reach-mark-expr-list
  [exprs : AstExprList]
  [names : StringI64Map]) : StringI64Map
  (match exprs
    [(AstExprNil) names]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (tltest-reach-mark-expr-list rest (tltest-reach-mark-expr head names)))]))

(define (tltest-reach-mark-let-bindings
  [bindings : AstLetBindingList]
  [names : StringI64Map]) : StringI64Map
  (match bindings
    [(AstLetBindingNil) names]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ _ value-box)
            (let
              [value : AstExpr (ast-node-get value-box)]
              (tltest-reach-mark-let-bindings
                rest
                (tltest-reach-mark-expr value names)))]))]))

(define (tltest-reach-mark-resource-bindings
  [bindings : AstResourceBindingList]
  [names : StringI64Map]) : StringI64Map
  (match bindings
    [(AstResourceBindingNil) names]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding _ init-box cleanup-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              [cleanup : AstExpr (ast-node-get cleanup-box)]
              (tltest-reach-mark-resource-bindings
                rest
                (tltest-reach-mark-expr
                  cleanup
                  (tltest-reach-mark-expr init names))))]))]))

(define (tltest-reach-mark-match-arms
  [arms : AstMatchArmList]
  [names : StringI64Map]) : StringI64Map
  (match arms
    [(AstMatchArmNil) names]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm _ body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (tltest-reach-mark-match-arms
                rest
                (tltest-reach-mark-expr body names)))]))]))

(define (tltest-reach-mark-expr [expr : AstExpr] [names : StringI64Map]) : StringI64Map
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprLiteral _) names]
    [(AstExprVar name) (tltest-reach-mark-name names (intern-str name))]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (tltest-reach-mark-expr right (tltest-reach-mark-expr left names)))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (tltest-reach-mark-expr-list args (tltest-reach-mark-expr func names)))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (tltest-reach-mark-expr
          else-branch
          (tltest-reach-mark-expr
            then-branch
            (tltest-reach-mark-expr cond names))))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (tltest-reach-mark-expr
          body
          (tltest-reach-mark-let-bindings bindings names)))]
    [(AstExprLambda _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (tltest-reach-mark-expr body names))]
    [(AstExprTuple exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprTupleRef tuple-box _)
      (let
        [tuple : AstExpr (ast-node-get tuple-box)]
        (tltest-reach-mark-expr tuple names))]
    [(AstExprArray exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprMakeArray _ len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (tltest-reach-mark-expr len names))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (tltest-reach-mark-expr index (tltest-reach-mark-expr array names)))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr
          value
          (tltest-reach-mark-expr index (tltest-reach-mark-expr array names))))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-expr array names)))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (tltest-reach-mark-expr index (tltest-reach-mark-expr text names)))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (tltest-reach-mark-expr body (tltest-reach-mark-expr cond names)))]
    [(AstExprBegin exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprUnsafe exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr
          value
          (tltest-reach-mark-name names (intern-str name))))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprBorrow _ _ place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (tltest-reach-mark-expr place names))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (ast-node-get scrutinee-box)]
        (tltest-reach-mark-match-arms
          arms
          (tltest-reach-mark-expr scrutinee names)))]
    [(AstExprForeach _ _ start-box end-box body-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [body : AstExpr (ast-node-get body-box)]
        (tltest-reach-mark-expr
          body
          (tltest-reach-mark-expr end (tltest-reach-mark-expr start names))))]
    [(AstExprSpmdReduce _ _ _ start-box end-box init-box value-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [init : AstExpr (ast-node-get init-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr
          value
          (tltest-reach-mark-expr
            init
            (tltest-reach-mark-expr end (tltest-reach-mark-expr start names)))))]
    [(AstExprStructGet receiver-box _)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (tltest-reach-mark-expr receiver names))]
    [(AstExprWithRegion _ body) (tltest-reach-mark-expr-list body names)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (tltest-reach-mark-expr-list
          body
          (tltest-reach-mark-expr scratch names)))]
    [(AstExprWithResource bindings body)
      (tltest-reach-mark-expr-list
        body
        (tltest-reach-mark-resource-bindings bindings names))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprBorrow _ _ place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (tltest-reach-mark-expr place names))]
    [(AstExprTypeLiteral _) names]
    [(AstExprInit _) names]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprQuote _) names]
    [(AstExprQuasiquote _) names]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprPtrNull _) names]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprPtrAddrOf _) names]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-expr ptr names)))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (tltest-reach-mark-expr offset (tltest-reach-mark-expr ptr names)))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr value names))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (tltest-reach-mark-expr len (tltest-reach-mark-expr ptr names)))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExprProgramArgc) names]
    [(AstExprProgramArgv) names]
    [(AstExprProgramEnvp) names]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (tltest-reach-mark-expr index names))]
    [(AstExprSyscall args) (tltest-reach-mark-expr-list args names)]))

(define (tltest-reach-mark-tests-from
  [tests : (Array InlineTest)]
  [index : i64]
  [names : StringI64Map]) : StringI64Map
  (if (< index 0)
    names
    (let
      [test : InlineTest (array-ref tests index)]
      (match test
        [(InlineTest _ _ _ body _)
          (tltest-reach-mark-tests-from
            tests
            (- index 1)
            (tltest-reach-mark-expr (ast-node-get body) names))]))))

(define (tltest-reach-mark-tests
  [tests : (Array InlineTest)]
  [names : StringI64Map]) : StringI64Map
  (tltest-reach-mark-tests-from tests (- (array-length tests) 1) names))

(define (tltest-reach-mark-decl [decl : AstDecl] [names : StringI64Map]) : StringI64Map
  (match decl
    [(AstDeclDef name _ expr-box)
      (let
        [expr : AstExpr (ast-node-get expr-box)]
        (if (string-i64-map-contains? names (intern-str name))
          (tltest-reach-mark-expr expr names)
          names))]
    [(AstDeclDefFn name _ _ body-box export)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match export
          [(AstFnExport _)
            (tltest-reach-mark-expr
              body
              (tltest-reach-mark-name names (intern-str name)))]
          [(AstFnNoExport)
            (if (string-i64-map-contains? names (intern-str name))
              (tltest-reach-mark-expr body names)
              names)]))]
    [(AstDeclDefMacro _ _ _ _) names]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-reach-mark-decl inner names))]
    [_ names]))

(define (tltest-reach-mark-decls-from
  [decls : (Array AstDecl)]
  [index : i64]
  [names : StringI64Map]) : StringI64Map
  (if (>= index (array-length decls))
    names
    (tltest-reach-mark-decls-from
      decls
      (+ index 1)
      (tltest-reach-mark-decl (array-ref decls index) names))))

;; Iterate the reachability marker to a fixpoint. The reachable-name set only
;; ever grows (marking is monotonic and dedup'd), so a pass that adds no new
;; names means we have converged and can stop. `fuel` (the decl count) stays as
;; a safety bound, but convergence normally takes only a handful of passes -
;; avoiding the previous unconditional O(decls^2) full-program walks.
(define (tltest-reach-fixed
  [decls : (Array AstDecl)]
  [fuel : i64]
  [names : StringI64Map]) : StringI64Map
  (if (<= fuel 0)
    names
    (let
      [before : i64 (string-i64-map-len names)]
      [next : StringI64Map (tltest-reach-mark-decls-from decls 0 names)]
      (if (= (string-i64-map-len next) before)
        next
        (tltest-reach-fixed decls (- fuel 1) next)))))

(define (tltest-reachable-names
  [decls : (Array AstDecl)]
  [tests : (Array InlineTest)]) : StringI64Map
  (tltest-reach-fixed
    decls
    (array-length decls)
    (tltest-reach-mark-tests tests (string-i64-map-with-capacity 64))))

(define (tltest-reachable-runtime-decl? [decl : AstDecl] [names : StringI64Map]) : bool
  (match decl
    [(AstDeclDef name _ _) (string-i64-map-contains? names (intern-str name))]
    [(AstDeclDefFn name _ _ _ export)
      (match export
        [(AstFnExport _) true]
        [(AstFnNoExport) (string-i64-map-contains? names (intern-str name))])]
    [(AstDeclExtern name _ _ _)
      (string-i64-map-contains? names (intern-str name))]
    [(AstDeclDefMacro _ _ _ _) true]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-reachable-runtime-decl? inner names))]
    [_ true]))

(define (tltest-prune-runtime-decls-in
  [decls : (Array AstDecl)]
  [paths : (Array String)]
  [index : i64]
  [names : StringI64Map]
  [out-decls : (Array AstDecl)]
  [out-paths : (Array String)]) : InlineRuntimeDecls
  (if (>= index (array-length decls))
    (InlineRuntimeDecls out-decls out-paths)
    (let
      [decl : AstDecl (array-ref decls index)]
      [decl-path : String (array-ref paths index)]
      (if (tltest-reachable-runtime-decl? decl names)
        (begin
          (array-push! out-decls decl)
          (array-push! out-paths decl-path)
          (tltest-prune-runtime-decls-in
            decls
            paths
            (+ index 1)
            names
            out-decls
            out-paths))
        (tltest-prune-runtime-decls-in
          decls
          paths
          (+ index 1)
          names
          out-decls
          out-paths)))))

(define (tltest-prune-runtime-decls
  [decls : (Array AstDecl)]
  [paths : (Array String)]
  [tests : (Array InlineTest)]) : InlineRuntimeDecls
  (tltest-prune-runtime-decls-in
    decls
    paths
    0
    (tltest-reachable-names decls tests)
    (make-array AstDecl 0)
    (make-array String 0)))

(define (tltest-build-harness
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : InlineHarness
  (match (tltest-collect decls paths)
    [(InlineCollect runtime-decls runtime-paths tests)
      (match (tltest-prune-runtime-decls runtime-decls runtime-paths tests)
        [(InlineRuntimeDecls pruned-decls pruned-paths)
          (let
            [count : i64 (array-length tests)]
            (InlineHarness
              (ast-program
                (tltest-decls-onto
                  pruned-decls
                  (- (array-length pruned-decls) 1)
                  (tltest-test-decls-onto
                    tests
                    (- count 1)
                    (ast-decl-cons (tltest-main-decl tests) AstDeclNil))))
              (tltest-paths-onto
                pruned-paths
                (- (array-length pruned-paths) 1)
                (tltest-test-paths-onto
                  tests
                  (- count 1)
                  (ast-decl-path-cons source AstDeclPathNil)))
              count))])]))

(define (tltest-path-at [paths : AstDeclPathList] [index : i64]) : String
  (match paths
    [(AstDeclPathNil) ""]
    [(AstDeclPathCons path rest)
      (if (= index 0)
        path
        (tltest-path-at (box-get rest) (- index 1)))]))

(define (tltest-decl-name [decl : AstDecl]) : String
  (match decl
    [(AstDeclDef name _ _) (intern-str name)]
    [(AstDeclDefFn name _ _ _ _) (intern-str name)]
    [(AstDeclExtern name _ _ _) (intern-str name)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-decl-name inner))]
    [(AstDeclComptimeDecl _ inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-decl-name inner))]
    [_ ""]))

(define (tltest-decl-name-at [decls : AstDeclList] [index : i64]) : String
  (match decls
    [(AstDeclNil) ""]
    [(AstDeclCons decl rest)
      (if (= index 0)
        (tltest-decl-name decl)
        (tltest-decl-name-at (box-get rest) (- index 1)))]))

(define (tltest-vector-builders-self-test?) : bool
  (let
    [helper-name : String "__tl_fixture_helper"]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        helper-name
        AstParamNil
        (AstTyUnit)
        (ast-node-push (AstExprLiteral (AstLitUnit))))]
    [first-span : AstSourceSpan (AstSourceSpan 11 1 11 1)]
    [second-span : AstSourceSpan (AstSourceSpan 22 1 22 1)]
    [decls : AstDeclList
      (ast-decl-cons
        helper-decl
        (ast-decl-cons
          (ast-decl-test "first" (tltest-call-expr helper-name) first-span)
          (ast-decl-cons
            (ast-decl-test "second" (tltest-call-expr helper-name) second-span)
            AstDeclNil)))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "runtime.tl"
        (ast-decl-path-cons
          "one.tl"
          (ast-decl-path-cons "two.tl" AstDeclPathNil)))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness program harness-paths count)
        (match program
          [(AstProgram harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 2)
                (and
                  (string-eq (tltest-decl-name-at harness-decls 0) helper-name)
                  (and
                    (string-eq
                      (tltest-decl-name-at harness-decls 1)
                      "__tl_inline_test_0")
                    (and
                      (string-eq
                        (tltest-decl-name-at harness-decls 2)
                        "__tl_inline_test_1")
                      (and
                        (string-eq (tltest-decl-name-at harness-decls 3) "main")
                        (and
                          (string-eq
                            (tltest-path-at harness-paths 0)
                            "runtime.tl")
                          (and
                            (string-eq
                              (tltest-path-at harness-paths 1)
                              "one.tl")
                            (and
                              (string-eq
                                (tltest-path-at harness-paths 2)
                                "two.tl")
                              (string-eq
                                (tltest-path-at harness-paths 3)
                                "driver.tl"))))))))))])])))

(test
  test-cli-vector-builders-preserve-order
  (if (tltest-vector-builders-self-test?)
    unit
    (panic "test CLI vector builder order mismatch")))

(define (tltest-import-alias-preserved? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclImport
        (AstImportSpec _ (AstSomeModuleName module) (AstSomeImportAlias alias)))
      (and (string-eq module "stdlib.core-macros") (string-eq alias "core"))]
    [_ false]))

(define (tltest-import-alias-preserved-self-test?) : bool
  (let
    [import-decl : AstDecl
      (AstDeclImport
        (AstImportSpec
          "stdlib/core_macros.tl"
          (AstSomeModuleName "stdlib.core-macros")
          (AstSomeImportAlias "core")))]
    [span : AstSourceSpan (AstSourceSpan 9 1 9 1)]
    [decls : AstDeclList
      (ast-decl-cons
        import-decl
        (ast-decl-cons
          (ast-decl-test
            "uses-qualified-macro-alias"
            (ast-node-push (AstExprLiteral (AstLitUnit)))
            span)
          AstDeclNil))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "alias.tl"
        (ast-decl-path-cons "alias.tl" AstDeclPathNil))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness program _ count)
        (match program
          [(AstProgram harness-decls-box)
            (match (box-get harness-decls-box)
              [(AstDeclCons first _)
                (and (= count 1) (tltest-import-alias-preserved? first))]
              [_ false])])])))

(test
  test-cli-inline-harness-preserves-import-aliases
  (if (tltest-import-alias-preserved-self-test?)
    unit
    (panic "test CLI inline harness dropped import alias")))

(define (tltest-check-only
  [program : AstProgram]
  [paths : AstDeclPathList]
  [count : i64]
  [target : CompilerBackendTarget]) : i64
  (match (typecheck-compiler-program-with-paths
    (tltest-program-with-print-runtime program target)
    (tltest-paths-with-print-runtime target paths))
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
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [temp-dir : String]) : i64
  (let
    [asm-path : String (source-tool-asm-path temp-dir source)]
    [obj-path : String (source-tool-obj-path temp-dir source target)]
    [bin-path : String (source-tool-temp-bin-path temp-dir source target)]
    (match (lower-compiler-program-with-decl-paths entry-path program paths)
      [(OkCompilerLower ir spans)
        (match (compiler-driver-emit-lowered-with-level
          source
          ir
          spans
          target
          true
          opt-level)
          [(OkCompilerDriver asm)
            (match (source-tool-lowered-object-or-assembly-and-link
              source
              ir
              spans
              target
              opt-level
              (source-tool-link-inputs-empty)
              asm-path
              obj-path
              bin-path
              (source-tool-augment-assembly-for-target asm target)
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
                        ;; FAILURE, not a host crash: report the raw status
                        ;; above, but exit cleanly with 1 so CI does not retry
                        ;; it as a transient #1204 segfault.
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
                          (string-append "': " (process-error-message error))))
                      (source-tool-clean-temp
                        temp-dir
                        asm-path
                        obj-path
                        bin-path
                        true)
                      1)])])]
          [(ErrCompilerDriver diag)
            (begin
              (print-error (compiler-diagnostic-render diag))
              (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
              1)])]
      [(ErrCompilerLower diag)
        (begin
          (print-error (compiler-diagnostic-render diag))
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          1)])))

(define (tltest-run-direct-with-entry
  [source : String]
  [entry-path : String]
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
            entry-path
            (tltest-program-with-print-runtime program backend-target)
            (tltest-paths-with-print-runtime backend-target paths)
            backend-target
            opt-level
            temp-dir)]
        [(ErrSourceToolString message)
          (begin
            (print-error
              (string-append "test: failed to create temp dir: " message))
            1)])]))

(define (tltest-run-direct
  [source : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [target : String]
  [opt-level : i64]) : i64
  (tltest-run-direct-with-entry source source program paths target opt-level))

(define (tltest-no-tests-check [decls : AstDeclList] [paths : AstDeclPathList]) : i64
  (match (typecheck-compiler-program-with-paths (ast-program decls) paths)
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
    (ast-program (ast-decl-cons (tltest-empty-main-decl) AstDeclNil))
    (ast-decl-path-cons source AstDeclPathNil)
    target
    opt-level))

(define (tltest-source-prefix-space? [c : char]) : bool
  (or (= c #\space') (= c #\tab')))

(define (tltest-source-line-break? [c : char]) : bool
  (or (= c #\newline') (= c #\return')))

(define (tltest-inline-marker-boundary? [source : String] [idx : i64] [n : i64]) : bool
  (if (>= idx n)
    true
    (let
      [c : char (string-ref source idx)]
      (or
        (tltest-source-prefix-space? c)
        (or (tltest-source-line-break? c) (= c #)'))))))

(define (tltest-inline-marker-at? [source : String] [idx : i64] [n : i64]) : bool
  (and
    (<= (+ idx 5) n)
    (and
      (= (string-ref source idx) #(')
      (and
        (= (string-ref source (+ idx 1)) #t')
        (and
          (= (string-ref source (+ idx 2)) #e')
          (and
            (= (string-ref source (+ idx 3)) #s')
            (and
              (= (string-ref source (+ idx 4)) #t')
              (tltest-inline-marker-boundary? source (+ idx 5) n))))))))

(define (tltest-source-has-inline-tests-from
  [source : String]
  [idx : i64]
  [n : i64]
  [line-open : bool]) : bool
  (let
    [i : i64 idx]
    [open : bool line-open]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (let
          [c : char (string-ref source i)]
          (core/cond
            (and open (tltest-source-line-break? c))
            (begin
              (set! i (+ i 1))
              (set! open true))
            (and open (tltest-source-prefix-space? c))
            (begin
              (set! i (+ i 1))
              (set! open true))
            (and open (tltest-inline-marker-at? source i n))
            (set! found true)
            (tltest-source-line-break? c)
            (begin
              (set! i (+ i 1))
              (set! open true))
            (begin
              (set! i (+ i 1))
              (set! open false)))))
      found)))

(define (tltest-source-has-inline-tests? [source : String]) : bool
  (let
    [text : String (read-file source)]
    (tltest-source-has-inline-tests-from text 0 (string-length text) true)))

(define (tltest-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (> prefix-len text-len)
      false
      (string-eq (substring text 0 prefix-len) prefix))))

(define (tltest-package-tests-prefix [manifest-dir : String]) : String
  (string-append
    (compiler-load-normalize-path
      (package-source-root-join manifest-dir "tests"))
    "/"))

(define (tltest-package-test-source? [source : String] [tests-prefix : String]) : bool
  (tltest-string-prefix? (compiler-load-normalize-path source) tests-prefix))

(define (tltest-decls-have-main? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (if (tltest-main-decl? decl)
        true
        (tltest-decls-have-main? (box-get rest)))]))

(define (tltest-package-source-line [source : String] [count : i64]) : String
  (string-append
    "TypeLisp test file: "
    (string-append
      source
      (string-append " (" (string-append (int->string count) " test(s))\n")))))

(define (tltest-package-summary-line
  [mode : TestMode]
  [file-count : i64]
  [test-count : i64]) : String
  (match mode
    [(TestModeCheck)
      (string-append
        "TypeLisp package test typecheck passed: "
        (string-append
          (int->string test-count)
          (string-append
            " test(s) in "
            (string-append (int->string file-count) " file(s)\n"))))]
    [(TestModeRun)
      (string-append
        "TypeLisp package tests passed: "
        (string-append
          (int->string test-count)
          (string-append
            " test(s) in "
            (string-append (int->string file-count) " file(s)\n"))))]))

(define (tltest-package-run-one
  [source : String]
  [target : String]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultTestPackageTotals
  (match (tltest-build-harness source decls paths)
    [(InlineHarness program harness-paths count)
      (if (= count 0)
        (begin
          (print-error
            (string-append
              "test: discovered inline test marker but no inline tests in "
              (string-append source "\n")))
          (ErrTestPackageTotals 1))
        (begin
          (print-string (tltest-package-source-line source count))
          (let
            [status : i64
              (match test-mode
                [(TestModeCheck)
                  (tltest-check-only program harness-paths count backend-target)]
                [(TestModeRun)
                  (tltest-run-direct
                    source
                    program
                    harness-paths
                    target
                    opt-level)])]
            (if (= status 0)
              (OkTestPackageTotals 1 count)
              (ErrTestPackageTotals status)))))]))

(define (tltest-package-integration-line [source : String]) : String
  (string-append "TypeLisp integration test file: " (string-append source "\n")))

(define (tltest-package-integration-missing-main [source : String]) : String
  (string-append
    "test: integration test file has no main: "
    (string-append source "\n")))

(define (tltest-package-integration-check
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultTestPackageTotals
  (begin
    (print-string (tltest-package-integration-line source))
    (if (tltest-decls-have-main? decls)
      (match (typecheck-compiler-program-with-paths (ast-program decls) paths)
        [(OkCompilerTypecheck _) (OkTestPackageTotals 1 1)]
        [(ErrCompilerTypecheck diag)
          (begin
            (print-error (compiler-diagnostic-render diag))
            (ErrTestPackageTotals 1))])
      (begin
        (print-error (tltest-package-integration-missing-main source))
        (ErrTestPackageTotals 1)))))

(define (tltest-package-integration-run
  [source : String]
  [target : String]
  [opt-level : i64]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultTestPackageTotals
  (begin
    (print-string (tltest-package-integration-line source))
    (if (tltest-decls-have-main? decls)
      (let
        [status : i64
          (tltest-run-direct-with-entry
            source
            ""
            (ast-program decls)
            paths
            target
            opt-level)]
        (if (= status 0)
          (OkTestPackageTotals 1 1)
          (ErrTestPackageTotals status)))
      (begin
        (print-error (tltest-package-integration-missing-main source))
        (ErrTestPackageTotals 1)))))

(define (tltest-package-run-integration-source
  [source : String]
  [target : String]
  [roots : StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]) : ResultTestPackageTotals
  (match (compiler-driver-load-package-file-with-runtime-owned
    source
    backend-target
    roots
    manifest-dir
    package-owner
    deps
    true)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match test-mode
        [(TestModeCheck) (tltest-package-integration-check source decls paths)]
        [(TestModeRun)
          (tltest-package-integration-run source target opt-level decls paths)])]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (print-error
          (string-append "test: integration test source failed: " source))
        (print-error (compiler-diagnostic-render diag))
        (ErrTestPackageTotals 1))]))

(define (tltest-package-run-source
  [source : String]
  [target : String]
  [roots : StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]) : ResultTestPackageTotals
  (if (tltest-source-has-inline-tests? source)
    (match (compiler-driver-load-package-file-with-runtime-owned
      source
      backend-target
      roots
      manifest-dir
      package-owner
      deps
      true)
      [(OkCompilerLoadWithPaths decls paths _ _)
        (tltest-package-run-one
          source
          target
          opt-level
          test-mode
          backend-target
          decls
          paths)]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (print-error (string-append "test: package source failed: " source))
          (print-error (compiler-diagnostic-render diag))
          (ErrTestPackageTotals 1))])
    (OkTestPackageTotals 0 0)))

(define (tltest-package-run-sources
  [sources : StringList]
  [tests-prefix : String]
  [target : String]
  [roots : StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (match sources
    [(StringNil) (OkTestPackageTotals file-count test-count)]
    [(StringCons source rest)
      (if (tltest-package-test-source? source tests-prefix)
        (tltest-package-run-sources
          (box-get rest)
          tests-prefix
          target
          roots
          opt-level
          test-mode
          backend-target
          manifest-dir
          package-owner
          deps
          file-count
          test-count)
        (match (tltest-package-run-source
          source
          target
          roots
          opt-level
          test-mode
          backend-target
          manifest-dir
          package-owner
          deps)
          [(ErrTestPackageTotals status) (ErrTestPackageTotals status)]
          [(OkTestPackageTotals source-files source-tests)
            (tltest-package-run-sources
              (box-get rest)
              tests-prefix
              target
              roots
              opt-level
              test-mode
              backend-target
              manifest-dir
              package-owner
              deps
              (+ file-count source-files)
              (+ test-count source-tests))]))]))

(define (tltest-package-run-integration-sources
  [sources : StringList]
  [target : String]
  [roots : StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (match sources
    [(StringNil) (OkTestPackageTotals file-count test-count)]
    [(StringCons source rest)
      (match (tltest-package-run-integration-source
        source
        target
        roots
        opt-level
        test-mode
        backend-target
        manifest-dir
        package-owner
        deps)
        [(ErrTestPackageTotals status) (ErrTestPackageTotals status)]
        [(OkTestPackageTotals source-files source-tests)
          (tltest-package-run-integration-sources
            (box-get rest)
            target
            roots
            opt-level
            test-mode
            backend-target
            manifest-dir
            package-owner
            deps
            (+ file-count source-files)
            (+ test-count source-tests))])]))

(define (tltest-run-package
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [roots : StringVec]
  [opt-level : i64]
  [test-mode : TestMode]) : i64
  (match (source-tool-target target)
    [(ErrSourceToolTarget _)
      (begin
        (print-error (tltest-unknown-target target))
        1)]
    [(OkSourceToolTarget backend-target)
      (match (package-source-discover-for "test" manifest-path has-manifest)
        [(ErrPackageSourceSet message)
          (begin
            (print-error message)
            1)]
        [(OkPackageSourceSet source-set)
          (let
            [manifest : CompilerPkgManifest (struct-get source-set manifest)]
            [manifest-dir : String (struct-get source-set manifest-dir)]
            [package-owner : String (struct-get manifest name)]
            [tests-prefix : String (tltest-package-tests-prefix manifest-dir)]
            (match (package-source-discover-tests-for "test" source-set)
              [(ErrPackageSourceList message)
                (begin
                  (print-error message)
                  1)]
              [(OkPackageSourceList integration-sources)
                (match (tltest-package-run-sources
                  (struct-get source-set sources)
                  tests-prefix
                  target
                  roots
                  opt-level
                  test-mode
                  backend-target
                  manifest-dir
                  package-owner
                  (struct-get manifest deps)
                  0
                  0)
                  [(ErrTestPackageTotals status) status]
                  [(OkTestPackageTotals inline-file-count inline-test-count)
                    (match (tltest-package-run-integration-sources
                      integration-sources
                      target
                      roots
                      opt-level
                      test-mode
                      backend-target
                      manifest-dir
                      package-owner
                      (struct-get manifest deps)
                      0
                      0)
                      [(ErrTestPackageTotals status) status]
                      [(OkTestPackageTotals
                          integration-file-count
                          integration-test-count)
                        (begin
                          (print-string
                            (tltest-package-summary-line
                              test-mode
                              (+ inline-file-count integration-file-count)
                              (+ inline-test-count integration-test-count)))
                          0)])])]))])]))

(define (tltest-check-file-loaded
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [backend-target : CompilerBackendTarget]) : ResultTestFileCheck
  (match (tltest-build-harness source decls paths)
    [(InlineHarness program harness-paths count)
      (begin
        (print-string (tltest-package-source-line source count))
        (let
          [status : i64
            (if (= count 0)
              (tltest-no-tests-check decls paths)
              (tltest-check-only program harness-paths count backend-target))]
          (if (= status 0)
            (OkTestFileCheck count)
            (ErrTestFileCheck status))))]))

(define (tltest-check-file-source
  [source : String]
  [roots : StringVec]
  [backend-target : CompilerBackendTarget]) : ResultTestFileCheck
  (match (compiler-driver-load-file-with-runtime
    source
    roots
    (compiler-driver-target-cfgs backend-target (compiler-cfg-empty)))
    [(OkCompilerLoadWithPaths decls paths _ _)
      (tltest-check-file-loaded source decls paths backend-target)]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        (ErrTestFileCheck 1))]))

(define (tltest-batch-summary-line [file-count : i64] [test-count : i64]) : String
  (string-append
    "TypeLisp test batch typecheck passed: "
    (string-append
      (int->string test-count)
      (string-append
        " test(s) in "
        (string-append (int->string file-count) " file(s)\n")))))

(define (tltest-run-batch-check-paths
  [paths : StringVec]
  [index : i64]
  [roots : StringVec]
  [backend-target : CompilerBackendTarget]
  [file-count : i64]
  [test-count : i64]) : i64
  (if (>= index (string-vec-len paths))
    (begin
      (print-string (tltest-batch-summary-line file-count test-count))
      0)
    (let
      [source : String (string-vec-get paths index "")]
      (match (tltest-check-file-source source roots backend-target)
        [(ErrTestFileCheck status)
          (begin
            (print-error (string-append "test: batch source failed: " source))
            (print-error "\n")
            status)]
        [(OkTestFileCheck count)
          (tltest-run-batch-check-paths
            paths
            (+ index 1)
            roots
            backend-target
            (+ file-count 1)
            (+ test-count count))]))))

(define (tltest-run-batch-check
  [paths : StringVec]
  [target : String]
  [roots : StringVec]) : i64
  (match (source-tool-target target)
    [(ErrSourceToolTarget _)
      (begin
        (print-error (tltest-unknown-target target))
        1)]
    [(OkSourceToolTarget backend-target)
      (tltest-run-batch-check-paths paths 0 roots backend-target 0 0)]))

(define (tltest-run-config [config : TestConfig]) : i64
  (match config
    [(TestFileConfig source target mode roots opt-level test-mode)
      (match (source-tool-target target)
        [(ErrSourceToolTarget _)
          (begin
            (print-error (tltest-unknown-target target))
            1)]
        [(OkSourceToolTarget backend-target)
          (match (compiler-driver-load-file-with-runtime
            source
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
                1)])])]
    [(TestBatchConfig paths target _ roots _ _)
      (tltest-run-batch-check paths target roots)]
    [(TestPackageConfig
        manifest-path
        has-manifest
        target
        _
        roots
        opt-level
        test-mode)
      (tltest-run-package
        manifest-path
        has-manifest
        target
        roots
        opt-level
        test-mode)]))

;; Run the `test` command over arguments starting at `start`.
(define (tltest-run-from [start : i64] [count : i64]) : i64
  (match (tltest-config-from start count)
    [(OkTestConfig config) (tltest-run-config config)]
    [(ErrTestConfig message)
      (begin
        (print-error message)
        1)]))