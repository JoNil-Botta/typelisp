;; test_cli_core.tl - Selfhost test command logic.
;;
;; Discovers source-owned `(test name body...)` declarations through the
;; selfhost loader, lowers them into private unit-returning functions plus a
;; generated `main`, then assembles, links, and runs that generated harness
;; directly. Imported files provide runtime declarations but do not contribute
;; their own tests to this source's harness. Normal compile paths ignore
;; `AstDecl.Test`.
(import stdlib.io)
(import stdlib.arena)
(import stdlib.process)
(import stdlib.hashmap)
(import stdlib.vector)
(import "build_run_core.tl")
(import "compiler_backend.tl")
(import "compiler_load.tl")
(import "package_source_core.tl")
(import "compiler_optimize.tl")
(import "compiler_typecheck.tl")
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import sym_i64_env)

(defenum TestMode
  (Run)
  (Check))

(defenum TestConfig
  (File String String String vector.StringVec i64 TestMode)
  (Batch vector.StringVec String String vector.StringVec i64 TestMode)
  (Package String bool String String vector.StringVec i64 TestMode))

(defenum ResultTestConfig
  (Ok TestConfig)
  (Err String))

(defenum TestMaybeString
  (No)
  (Some String))

(defenum ResultTestBatchPaths
  (Ok vector.StringVec)
  (Err String))

(defenum InlineTest
  (Case String String i64 i64 String))

(defenum InlineCollect
  (Collect AstDeclList AstDeclPathList (Array InlineTest)))

(defenum InlineHarness
  (Harness AstProgram AstDeclPathList i64))

(defenum InlineRuntimeDecls
  (Decls AstDeclList AstDeclPathList))

(defenum ResultTestPackageTotals
  (Ok i64 i64)
  (Err i64))

(defenum ResultTestFileCheck
  (Ok i64)
  (Err i64))

(define tltest-prefix-cache-stats : bool
  false)

(define (tltest-unknown-target [value : String]) : String
  (str_cat.str-cat "test: unknown target " value ""))

(define (tltest-unknown-mode [value : String]) : String
  (str_cat.str-cat "test: unknown backend mode " value ""))

(define (tltest-unsupported-mode [value : String]) : String
  (str_cat.str-cat "test: backend mode " value " is not implemented"))

(define (tltest-invalid-opt-level [value : String]) : String
  (str_cat.str-cat "test: invalid --opt-level " value "; expected 0, 1, or 2"))

(define (tltest-batch-line-end [text : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (or
            (= (string.string-ref text i) '\n')
            (= (string.string-ref text i) '\r'))
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
      [c : char (string.string-ref text line-end)]
      (begin
        (unless (= c '\r') (return (+ line-end 1)))
        (unless (< (+ line-end 1) n) (return (+ line-end 1)))
        (if (= (string.string-ref text (+ line-end 1)) '\n')
          (+ line-end 2)
          (+ line-end 1))))))

(define (tltest-batch-paths-from-text-from
  [text : String]
  [start : i64]
  [n : i64]
  [paths : vector.StringVec]) : vector.StringVec
  (if (>= start n)
    paths
    (let
      [line-end : i64 (tltest-batch-line-end text start n)]
      [next-start : i64 (tltest-batch-next-line-start text line-end n)]
      (if (= start line-end)
        (tltest-batch-paths-from-text-from text next-start n paths)
        (tltest-batch-paths-from-text-from
          text
          next-start
          n
          (vector.string-vec-push
            paths
            (string.substring text start (- line-end start))))))))

(define (tltest-batch-paths-from-text [text : String]) : vector.StringVec
  (tltest-batch-paths-from-text-from
    text
    0
    (string.string-length text)
    (vector.string-vec-new)))

(define (tltest-batch-paths-from-text-self-test?) : bool
  (let
    [paths : vector.StringVec
      (tltest-batch-paths-from-text "a.tl\n\nb.tl\r\nc.tl")]
    (and
      (= (vector.string-vec-len paths) 3)
      (string.eq (vector.string-vec-get paths 0 "") "a.tl")
      (string.eq (vector.string-vec-get paths 1 "") "b.tl")
      (string.eq (vector.string-vec-get paths 2 "") "c.tl"))))

(test
  test-batch-paths-vector-preserves-order
  (if (tltest-batch-paths-from-text-self-test?)
    unit
    (io.panic "test: batch path vector self-test mismatch")))

(define (tltest-batch-paths [list-path : String]) : ResultTestBatchPaths
  (match (io.try-read-file (& list-path))
    [(io.OkIoString text)
      (ResultTestBatchPaths.Ok (tltest-batch-paths-from-text text))]
    [(io.ErrIoString error)
      (ResultTestBatchPaths.Err
        (string.append
          "test: failed to read --batch list file: "
          (io.error-message error)))]))

(define (tltest-config-finish
  [source : String]
  [has-source : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [mode : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [batch-list : TestMaybeString]) : ResultTestConfig
  (match batch-list
    [(TestMaybeString.Some list-path)
      (if has-manifest
        (ResultTestConfig.Err
          "test: cannot combine --batch with --manifest-path")
        (if has-source
          (ResultTestConfig.Err "test: cannot combine input paths with --batch")
          (match test-mode
            [(TestMode.Run)
              (ResultTestConfig.Err "test: --batch requires --check")]
            [(TestMode.Check)
              (match (tltest-batch-paths list-path)
                [(ResultTestBatchPaths.Ok paths)
                  (if (vector.string-vec-is-empty? paths)
                    (ResultTestConfig.Err "test: --batch list is empty")
                    (ResultTestConfig.Ok
                      (TestConfig.Batch
                        paths
                        target
                        mode
                        roots
                        opt-level
                        test-mode)))]
                [(ResultTestBatchPaths.Err message)
                  (ResultTestConfig.Err message)])])))]
    [(TestMaybeString.No)
      (if tltest-prefix-cache-stats
        (ResultTestConfig.Err "test: --prefix-cache-stats requires --batch")
        (if has-source
          (if has-manifest
            (ResultTestConfig.Err
              "test: cannot combine source path with --manifest-path")
            (ResultTestConfig.Ok
              (TestConfig.File source target mode roots opt-level test-mode)))
          (ResultTestConfig.Ok
            (TestConfig.Package
              manifest-path
              has-manifest
              target
              mode
              roots
              opt-level
              test-mode))))]))

(define (tltest-target-valid? [value : String]) : bool
  (match (source-tool-target value)
    [(ResultSourceToolTarget.Ok _) true]
    [(ResultSourceToolTarget.Err _) false]))

(define (tltest-backend-mode-valid? [value : String]) : bool
  (or
    (string.eq value "scalar")
    (string.eq value "avx2")
    (string.eq value "avx512")))

(define (tltest-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [mode : String]
  [roots : vector.StringVec]
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
      [current : String (io.arg idx)]
      (cond
        [(string.eq current "--check")
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
            TestMode.Check
            batch-list)]
        [(string.eq current "--target")
          (if (>= (+ idx 1) count)
            (ResultTestConfig.Err "test: --target requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
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
                (ResultTestConfig.Err (tltest-unknown-target value)))))]
        [(string.eq current "--backend-mode")
          (if (>= (+ idx 1) count)
            (ResultTestConfig.Err "test: --backend-mode requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (if (tltest-backend-mode-valid? value)
                (if (string.eq value "scalar")
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
                  (ResultTestConfig.Err (tltest-unsupported-mode value)))
                (ResultTestConfig.Err (tltest-unknown-mode value)))))]
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultTestConfig.Err "test: --stdlib-root requires a value")
            (tltest-parse-options
              (+ idx 2)
              count
              source
              has-source
              manifest-path
              has-manifest
              target
              mode
              (vector.string-vec-push roots (io.arg (+ idx 1)))
              has-opt-level
              opt-level
              test-mode
              batch-list))]
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultTestConfig.Err "test: --manifest-path requires a value")
            (if has-manifest
              (ResultTestConfig.Err "test: duplicate --manifest-path")
              (tltest-parse-options
                (+ idx 2)
                count
                source
                has-source
                (io.arg (+ idx 1))
                true
                target
                mode
                roots
                has-opt-level
                opt-level
                test-mode
                batch-list)))]
        [(string.eq current "--batch")
          (if (>= (+ idx 1) count)
            (ResultTestConfig.Err "test: --batch requires a value")
            (match batch-list
              [(TestMaybeString.Some _)
                (ResultTestConfig.Err "test: duplicate --batch")]
              [(TestMaybeString.No)
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
                  (TestMaybeString.Some (io.arg (+ idx 1))))]))]
        [(string.eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ResultTestConfig.Err "test: --opt-level requires a value")
            (if has-opt-level
              (ResultTestConfig.Err
                "test: --opt-level was provided more than once")
              (let
                [value : String (io.arg (+ idx 1))]
                (match (compiler-optimize-parse-level value)
                  [(ResultCompilerOptimizeLevel.Ok parsed-level)
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
                  [(ResultCompilerOptimizeLevel.Err)
                    (ResultTestConfig.Err (tltest-invalid-opt-level value))]))))]
        [(string.eq current "--prefix-cache-stats")
          (begin
            (set! tltest-prefix-cache-stats true)
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
              test-mode
              batch-list))]
        [(source-tool-flag? current)
          (ResultTestConfig.Err (string.append "test: unknown flag " current))]
        [has-source (ResultTestConfig.Err "test: accepts only one source file")]
        [else
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
            batch-list)]))))

;; Parse the `test` config from arguments starting at `start` (the index of the
;; first argument after any subcommand name). `count` is `(arg-count)`.
(define (tltest-config-from [start : i64] [count : i64]) : ResultTestConfig
  (begin
    (set! tltest-prefix-cache-stats false)
    (tltest-parse-options
      start
      count
      ""
      false
      ""
      false
      (source-tool-default-target-name)
      "scalar"
      (vector.string-vec-new)
      false
      (compiler-optimize-default-level)
      TestMode.Run
      (TestMaybeString.No))))

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

(define (tltest-decl-list-reverse-onto
  [items : AstDeclList]
  [out : AstDeclList]) : AstDeclList
  (let
    [cur : AstDeclList items]
    [result : AstDeclList out]
    [done : bool false]
    (begin
      (while (not done)
        (match cur
          [(AstDeclList.Nil) (set! done true)]
          [(AstDeclList.Cons decl rest)
            (begin
              (set! result (ast-decl-cons decl result))
              (set! cur (box-get rest)))]))
      result)))

(define (tltest-path-list-reverse-onto
  [items : AstDeclPathList]
  [out : AstDeclPathList]) : AstDeclPathList
  (let
    [cur : AstDeclPathList items]
    [result : AstDeclPathList out]
    [done : bool false]
    (begin
      (while (not done)
        (match cur
          [(AstDeclPathList.Nil) (set! done true)]
          [(AstDeclPathList.Cons path rest)
            (begin
              (set! result (ast-decl-path-cons path result))
              (set! cur (box-get rest)))]))
      result)))

(define (tltest-decl-list-count [items : AstDeclList]) : i64
  (let
    [cur : AstDeclList items]
    [count : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (match cur
          [(AstDeclList.Nil) (set! done true)]
          [(AstDeclList.Cons _ rest)
            (begin
              (set! count (+ count 1))
              (set! cur (box-get rest)))]))
      count)))

(define (tltest-main-decl? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Def name _ _) (= name (intern "main"))]
    [(AstDecl.DefFn name _ _ _ _) (= name (intern "main"))]
    [(AstDecl.DefMacro _ _ _ _) false]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-main-decl? inner))]
    [_ false]))

(define (tltest-source-line [span : AstSourceSpan]) : i64
  (struct-get span start-line))

(define (tltest-private-name [idx : i64]) : String
  (string.append "__tl_inline_test_" (string.int->string idx)))

(define (tltest-owned-test-path? [target-path : String] [decl-path : String]) : bool
  (string.eq target-path (compiler-load-normalize-path decl-path)))

(define (tltest-collect-in
  [target-path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [runtime-decls : AstDeclList]
  [runtime-paths : AstDeclPathList]
  [tests : (Array InlineTest)]) : InlineCollect
  (let
    [cur-decls : AstDeclList decls]
    [cur-paths : AstDeclPathList paths]
    [runtime-decls-out : AstDeclList runtime-decls]
    [runtime-paths-out : AstDeclPathList runtime-paths]
    [test-items : (Array InlineTest) tests]
    [done : bool false]
    (begin
      (while (not done)
        (match cur-decls
          [(AstDeclList.Nil) (set! done true)]
          [(AstDeclList.Cons decl rest)
            (let
              [rest-decls : AstDeclList (box-get rest)]
              [decl-path : String
                (match cur-paths
                  [(AstDeclPathList.Cons path _) path]
                  [(AstDeclPathList.Nil) ""])]
              [rest-paths : AstDeclPathList
                (match cur-paths
                  [(AstDeclPathList.Cons _ path-rest)
                    (let
                      [path-rest : AstDeclPathList (box-get path-rest)]
                      path-rest)]
                  [(AstDeclPathList.Nil) AstDeclPathList.Nil])]
              (begin
                (match decl
                  [(AstDecl.Test name body-box span)
                    (if (tltest-owned-test-path? target-path decl-path)
                      (let
                        [body : i64 body-box]
                        [test-count : i64 (array-length test-items)]
                        (array-push!
                          test-items
                          (InlineTest.Case
                            (intern-str name)
                            decl-path
                            (tltest-source-line span)
                            body
                            (tltest-private-name test-count))))
                      unit)]
                  [(AstDecl.Import _)
                    (begin
                      (set!
                        runtime-decls-out
                        (ast-decl-cons decl runtime-decls-out))
                      (set!
                        runtime-paths-out
                        (ast-decl-path-cons decl-path runtime-paths-out)))]
                  [(AstDecl.IncludeStr _ _) unit]
                  [(AstDecl.IncludeBin _ _) unit]
                  [_
                    (if (tltest-main-decl? decl)
                      unit
                      (begin
                        (set!
                          runtime-decls-out
                          (ast-decl-cons decl runtime-decls-out))
                        (set!
                          runtime-paths-out
                          (ast-decl-path-cons decl-path runtime-paths-out))))])
                (set! cur-decls rest-decls)
                (set! cur-paths rest-paths)))]))
      (InlineCollect.Collect
        (tltest-decl-list-reverse-onto runtime-decls-out AstDeclList.Nil)
        (tltest-path-list-reverse-onto runtime-paths-out AstDeclPathList.Nil)
        test-items))))

(define (tltest-collect
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : InlineCollect
  (tltest-collect-in
    (compiler-load-normalize-path source)
    decls
    paths
    AstDeclList.Nil
    AstDeclPathList.Nil
    (make-array InlineTest 0)))

(define (tltest-print-expr [text : String]) : i64
  (ast-expr-call
    (ast-node-push (AstExpr.Var (intern "__tl_test_print_error")))
    (ast-expr-cons
      (ast-node-push (AstExpr.Literal (AstLiteral.String text)))
      (ast-expr-cons
        (ast-expr-cast
          (ast-node-push
            (AstExpr.Literal (ast-lit-int (string.string-length text))))
          (AstType.I32))
        AstExprList.Nil))))

(define (tltest-call-expr [name : String]) : i64
  (ast-expr-call (ast-node-push (AstExpr.Var (intern name))) AstExprList.Nil))

(define (tltest-location [path : String] [line : i64]) : String
  (if (string.eq path "")
    (string.append "<unknown>:" (string.int->string line))
    (string.append path (string.append ":" (string.int->string line)))))

(define (tltest-running-line [test : InlineTest]) : String
  (match test
    [(InlineTest.Case name path line _ _)
      (string.append
        "test "
        (string.append
          name
          (string.append " " (string.append (tltest-location path line) "\n"))))]))

(define (tltest-ok-line [test : InlineTest]) : String
  (match test
    [(InlineTest.Case name _ _ _ _)
      (string.append "ok " (string.append name "\n"))]))

(define (tltest-summary-line [count : i64]) : String
  (string.append
    "TypeLisp tests passed: "
    (string.append (string.int->string count) " test(s)\n")))

(define (tltest-print-runtime-write-params) : AstParamList
  (ast-param-cons
    (ast-param "fd" (AstType.I32) false)
    (ast-param-cons
      (ast-param "buf" (ast-ty-ptr (AstType.U8)) false)
      (ast-param-cons (ast-param "n" (AstType.I32) false) AstParamList.Nil))))

(define (tltest-linux-write-ptr-arg) : i64
  (ast-node-push
    (AstExpr.Unsafe
      (ast-expr-cons
        (ast-expr-cast
          (ast-expr-ptr-to-int (ast-node-push (AstExpr.Var (intern "buf"))))
          (AstType.I64))
        AstExprList.Nil))))

(define (tltest-linux-write-syscall) : i64
  (ast-node-push
    (AstExpr.Unsafe
      (ast-expr-cons
        (ast-expr-syscall
          (ast-expr-cons
            (ast-node-push (AstExpr.Literal (ast-lit-int 1)))
            (ast-expr-cons
              (ast-expr-cast
                (ast-node-push (AstExpr.Var (intern "fd")))
                (AstType.I64))
              (ast-expr-cons
                (tltest-linux-write-ptr-arg)
                (ast-expr-cons
                  (ast-expr-cast
                    (ast-node-push (AstExpr.Var (intern "n")))
                    (AstType.I64))
                  AstExprList.Nil)))))
        AstExprList.Nil))))

(define (tltest-linux-print-runtime-write-decl) : AstDecl
  (ast-decl-def-fn
    "__tl_test_write"
    (tltest-print-runtime-write-params)
    (AstType.I32)
    (ast-expr-cast (tltest-linux-write-syscall) (AstType.I32))))

(define (tltest-windows-get-std-handle-decl) : AstDecl
  (ast-decl-extern
    "__tl_test_get_std_handle"
    (AstExternKind.Function)
    (AstExternMetadata.Metadata
      (AstExternAbi.C)
      "GetStdHandle"
      AstExternLinkInputList.Nil
      true)
    (ast-ty-func (ast-type-cons (AstType.I32) AstTypeList.Nil) (AstType.I64))))

(define (tltest-windows-write-file-decl) : AstDecl
  (ast-decl-extern
    "__tl_test_write_file"
    (AstExternKind.Function)
    (AstExternMetadata.Metadata
      (AstExternAbi.C)
      "WriteFile"
      AstExternLinkInputList.Nil
      true)
    (ast-ty-func
      (ast-type-cons
        (AstType.I64)
        (ast-type-cons
          (ast-ty-ptr (AstType.U8))
          (ast-type-cons
            (AstType.I32)
            (ast-type-cons
              (ast-ty-mut-ptr (AstType.I32))
              (ast-type-cons (AstType.I64) AstTypeList.Nil)))))
      (AstType.I32))))

(define (tltest-windows-get-stderr-handle-expr) : i64
  (ast-expr-call
    (ast-node-push (AstExpr.Var (intern "__tl_test_get_std_handle")))
    (ast-expr-cons
      (ast-expr-cast
        (ast-node-push (AstExpr.Literal (ast-lit-int -12)))
        (AstType.I32))
      AstExprList.Nil)))

(define (tltest-windows-write-file-call) : i64
  (ast-expr-call
    (ast-node-push (AstExpr.Var (intern "__tl_test_write_file")))
    (ast-expr-cons
      (ast-node-push (AstExpr.Var (intern "handle")))
      (ast-expr-cons
        (ast-node-push (AstExpr.Var (intern "buf")))
        (ast-expr-cons
          (ast-node-push (AstExpr.Var (intern "n")))
          (ast-expr-cons
            (ast-node-push (AstExpr.PtrNull (ast-ty-mut-ptr (AstType.I32))))
            (ast-expr-cons
              (ast-node-push (AstExpr.Literal (ast-lit-int 0)))
              AstExprList.Nil)))))))

(define (tltest-windows-write-body) : i64
  (ast-expr-let
    (ast-let-binding-cons
      (ast-let-binding
        "handle"
        (AstMaybeType.Some (AstType.I64))
        (tltest-windows-get-stderr-handle-expr))
      (ast-let-binding-cons
        (ast-let-binding
          "ok"
          (AstMaybeType.Some (AstType.I32))
          (tltest-windows-write-file-call))
        AstLetBindingList.Nil))
    (ast-expr-if
      (ast-expr-binary
        (AstBinOp.Eq)
        (ast-node-push (AstExpr.Var (intern "ok")))
        (ast-expr-cast
          (ast-node-push (AstExpr.Literal (ast-lit-int 0)))
          (AstType.I32)))
      (ast-expr-cast
        (ast-node-push (AstExpr.Literal (ast-lit-int -1)))
        (AstType.I32))
      (ast-node-push (AstExpr.Var (intern "n"))))))

(define (tltest-windows-print-runtime-write-decl) : AstDecl
  (ast-decl-def-fn
    "__tl_test_write"
    (tltest-print-runtime-write-params)
    (AstType.I32)
    (tltest-windows-write-body)))

(define (tltest-print-runtime-write-decl [target : CompilerBackendTarget]) : AstDecl
  (match target
    [(CompilerBackendTarget.Linux) (tltest-linux-print-runtime-write-decl)]
    [(CompilerBackendTarget.Windows) (tltest-windows-print-runtime-write-decl)]))

(define (tltest-print-param-list) : AstParamList
  (ast-param-cons
    (ast-param "text" (AstType.String) false)
    (ast-param-cons (ast-param "n" (AstType.I32) false) AstParamList.Nil)))

(define (tltest-print-runtime-write-call) : i64
  (ast-expr-call
    (ast-node-push (AstExpr.Var (intern "__tl_test_write")))
    (ast-expr-cons
      (ast-expr-cast
        (ast-node-push (AstExpr.Literal (ast-lit-int 2)))
        (AstType.I32))
      (ast-expr-cons
        (ast-node-push
          (AstExpr.Unsafe
            (ast-expr-cons
              (ast-expr-string-data
                (ast-node-push (AstExpr.Var (intern "text"))))
              AstExprList.Nil)))
        (ast-expr-cons
          (ast-node-push (AstExpr.Var (intern "n")))
          AstExprList.Nil)))))

(define (tltest-print-runtime-print-decl) : AstDecl
  (ast-decl-def-fn
    "__tl_test_print_error"
    (tltest-print-param-list)
    (AstType.Unit)
    (ast-node-push
      (AstExpr.Begin
        (ast-expr-cons
          (tltest-print-runtime-write-call)
          (ast-expr-cons
            (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))
            AstExprList.Nil))))))

(define (tltest-program-with-print-runtime
  [program : AstProgram]
  [target : CompilerBackendTarget]) : AstProgram
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-program
          (match target
            [(CompilerBackendTarget.Linux)
              (ast-decl-cons
                (tltest-print-runtime-write-decl target)
                (ast-decl-cons (tltest-print-runtime-print-decl) decls))]
            [(CompilerBackendTarget.Windows)
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
    [(CompilerBackendTarget.Linux)
      (tltest-paths-with-print-runtime-count 2 paths)]
    [(CompilerBackendTarget.Windows)
      (tltest-paths-with-print-runtime-count 4 paths)]))

(define (tltest-main-exprs-from
  [tests : (Array InlineTest)]
  [index : i64]
  [out : AstExprList]) : AstExprList
  (if (< index 0)
    out
    (let
      [test : InlineTest (array-ref tests index)]
      (match test
        [(InlineTest.Case _ _ _ _ private-name)
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
          (ast-node-push (AstExpr.Literal (ast-lit-int 0)))
          AstExprList.Nil)))))

(define (tltest-test-decls-onto
  [tests : (Array InlineTest)]
  [index : i64]
  [out : AstDeclList]) : AstDeclList
  (if (< index 0)
    out
    (let
      [test : InlineTest (array-ref tests index)]
      (match test
        [(InlineTest.Case _ _ _ body private-name)
          (tltest-test-decls-onto
            tests
            (- index 1)
            (ast-decl-cons
              (ast-decl-def-fn
                private-name
                AstParamList.Nil
                (AstType.Unit)
                body)
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
        [(InlineTest.Case _ path _ _ _)
          (tltest-test-paths-onto
            tests
            (- index 1)
            (ast-decl-path-cons path out))]))))

(define (tltest-main-decl [tests : (Array InlineTest)]) : AstDecl
  (ast-decl-def-fn
    "main"
    AstParamList.Nil
    (AstType.I64)
    (ast-node-push (AstExpr.Begin (tltest-main-exprs tests)))))

(define (tltest-empty-main-decl) : AstDecl
  (tltest-main-decl (make-array InlineTest 0)))

(define (tltest-reach-mark-name [names : hashmap.StringI64Map] [name : String]) : hashmap.StringI64Map
  (if (hashmap.string-i64-map-contains? names name)
    names
    (hashmap.string-i64-map-put names name 1)))

;; The leaf of an alias-qualified source name (`io.panic` -> `panic`). Source
;; calls write the importing module's alias dot-form; the callee function is
;; declared under its bare leaf name, so reachability must mark the leaf too.
;; Returns the input unchanged when there is no interior `.`.
(define (tltest-reach-name-dot-leaf [name : String]) : String
  (let
    [i : i64 0]
    [last-dot : i64 -1]
    [n : i64 (string.string-length name)]
    (begin
      (while (< i n)
        (begin
          (if (string.char-eq (string.string-ref name i) '.')
            (set! last-dot i)
            unit)
          (set! i (+ i 1))))
      (if (and (>= last-dot 0) (< last-dot (- n 1)))
        (string.substring name (+ last-dot 1) (- n (+ last-dot 1)))
        name))))

(define (tltest-reach-mark-source-name
  [names : hashmap.StringI64Map]
  [name : String]) : hashmap.StringI64Map
  (let
    [marked : hashmap.StringI64Map (tltest-reach-mark-name names name)]
    [with-slash-base : hashmap.StringI64Map
      (if (tc-name-qualified? name)
        (tltest-reach-mark-name marked (tc-qualified-name-base name))
        marked)]
    ;; Alias-qualified source calls (`io.panic`) are not slash-qualified, so the
    ;; base extraction above leaves them whole. Mark the dot-leaf so the callee
    ;; (`panic`) survives runtime-decl pruning (everything is exported by
    ;; default: there is no longer an export list to seed it as a root).
    [leaf : String (tltest-reach-name-dot-leaf name)]
    (if (string.eq leaf name)
      with-slash-base
      (tltest-reach-mark-name with-slash-base leaf))))

(define (tltest-reachable-name-marked?
  [names : hashmap.StringI64Map]
  [name : String]) : bool
  (or
    (hashmap.string-i64-map-contains? names name)
    (if (tc-name-qualified? name)
      (hashmap.string-i64-map-contains? names (tc-qualified-name-base name))
      false)
    (let
      [leaf : String (tltest-reach-name-dot-leaf name)]
      (if (string.eq leaf name)
        false
        (hashmap.string-i64-map-contains? names leaf)))))

(define (tltest-generated-comptime-decl? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.ComptimeDecl meta inner-box)
      (match meta
        [(AstGeneratedDeclMeta.Some _ _ _ _) true]
        [(AstGeneratedDeclMeta.No)
          (tltest-generated-comptime-decl? (box-get inner-box))])]
    [(AstDecl.Unsafe inner-box)
      (tltest-generated-comptime-decl? (box-get inner-box))]
    [_ false]))

(define (tltest-reach-mark-string-snapshot-runtime
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  ;; Harness pruning runs before lowering emits raw `tl_substring` helper calls,
  ;; so keep the TypeLisp runtime body whenever a reachable test path may
  ;; synthesize a String snapshot or source substring call.
  (tltest-reach-mark-name names "tl-runtime-substring"))

(define (tltest-reach-mark-str-view-runtime [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (tltest-reach-mark-name names "tl-runtime-str-view"))

(define (tltest-bytes-view-from-parts-name? [name : String]) : bool
  (or
    (string.eq name "tl_bytes_view_from_str_parts")
    (string.eq name "tl_bytes_view_from_buf_parts")
    (string.eq name "tl_bytes_mut_view_from_buf_parts")
    (string.eq name "tl_bytes_view_from_bytes_parts")
    (string.eq name "tl_bytes_mut_view_from_bytes_parts")))

(define (tltest-reach-mark-lowered-runtime-for-call
  [name : String]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (cond
    [(or
        (string.eq name "clone")
        (string.eq name "substring")
        (string.eq name "string-slice"))
      (tltest-reach-mark-string-snapshot-runtime names)]
    [(or
        (string.eq name "tl_str_view")
        (tltest-bytes-view-from-parts-name? name))
      (tltest-reach-mark-str-view-runtime names)]
    [else names]))

(define (tltest-reach-mark-expr-list
  [exprs : AstExprList]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match exprs
    [(AstExprList.Nil) names]
    [(AstExprList.Cons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (tltest-reach-mark-expr-list rest (tltest-reach-mark-expr head names)))]))

(define (tltest-reach-mark-let-bindings
  [bindings : AstLetBindingList]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match bindings
    [(AstLetBindingList.Nil) names]
    [(AstLetBindingList.Cons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding.Binding _ _ value-box)
            (let
              [value : AstExpr (ast-node-get value-box)]
              (tltest-reach-mark-let-bindings
                rest
                (tltest-reach-mark-expr value names)))]))]))

(define (tltest-reach-mark-resource-bindings
  [bindings : AstResourceBindingList]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match bindings
    [(AstResourceBindingList.Nil) names]
    [(AstResourceBindingList.Cons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding.Binding _ init-box cleanup-box)
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
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (tltest-reach-mark-match-arms-at (& arms) names 0))

(define (tltest-reach-mark-match-arms-at
  [arms : (& arms AstMatchArmList)]
  [names : hashmap.StringI64Map]
  [index : i64]) : hashmap.StringI64Map
  (if (>= index (ast-match-arm-list-len arms))
    names
    (match (ast-match-arm-list-get arms index (ast-match-arm-fallback))
      [(AstMatchArm.Arm _ body-box)
        (let
          [body : AstExpr (ast-node-get body-box)]
          (tltest-reach-mark-match-arms-at
            arms
            (tltest-reach-mark-expr body names)
            (+ index 1)))])))

(define (tltest-reach-mark-expr [expr : AstExpr] [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Literal _) names]
    [(AstExpr.Var name) (tltest-reach-mark-source-name names (intern-str name))]
    [(AstExpr.Binary _ left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (tltest-reach-mark-expr right (tltest-reach-mark-expr left names)))]
    [(AstExpr.Unary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        [called-names : hashmap.StringI64Map
          (tltest-reach-mark-expr func names)]
        [runtime-names : hashmap.StringI64Map
          (match (ast-expr-unspan func)
            [(AstExpr.Var name)
              (tltest-reach-mark-lowered-runtime-for-call
                (intern-str name)
                called-names)]
            [_ called-names])]
        (tltest-reach-mark-expr-list args runtime-names))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (tltest-reach-mark-expr
          else-branch
          (tltest-reach-mark-expr
            then-branch
            (tltest-reach-mark-expr cond names))))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (tltest-reach-mark-expr
              body
              (tltest-reach-mark-let-bindings bindings names)))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda _ _ body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (tltest-reach-mark-expr
              body
              (tltest-reach-mark-string-snapshot-runtime names)))])]
    [(AstExpr.Tuple exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExpr.TupleRef tuple-box _)
      (let
        [tuple : AstExpr (ast-node-get tuple-box)]
        (tltest-reach-mark-expr tuple names))]
    [(AstExpr.Array exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExpr.MakeArray _ len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (tltest-reach-mark-expr len names))]
    [(AstExpr.ArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (tltest-reach-mark-expr index (tltest-reach-mark-expr array names)))]
    [(AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr
          value
          (tltest-reach-mark-expr index (tltest-reach-mark-expr array names))))]
    [(AstExpr.ArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-expr array names)))]
    [(AstExpr.StringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (tltest-reach-mark-expr index (tltest-reach-mark-expr text names)))]
    [(AstExpr.While cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (tltest-reach-mark-expr body (tltest-reach-mark-expr cond names)))]
    [(AstExpr.Begin exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExpr.Unsafe exprs) (tltest-reach-mark-expr-list exprs names)]
    [(AstExpr.Set name value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr
          value
          (tltest-reach-mark-source-name names (intern-str name))))]
    [(AstExpr.Ann inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Cast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Borrow _ _ place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (tltest-reach-mark-expr place names))]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (tltest-reach-mark-match-arms
              arms
              (tltest-reach-mark-expr scrutinee names)))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach _ _ start-box end-box body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [body : AstExpr (ast-node-get body-box)]
            (tltest-reach-mark-expr
              body
              (tltest-reach-mark-expr end (tltest-reach-mark-expr start names))))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce _ _ _ start-box end-box init-box value-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            (tltest-reach-mark-expr
              value
              (tltest-reach-mark-expr
                init
                (tltest-reach-mark-expr
                  end
                  (tltest-reach-mark-expr start names)))))])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan
            _
            _
            _
            start-box
            end-box
            _
            _
            init-box
            value-box
            body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            [body : AstExpr (ast-node-get body-box)]
            (tltest-reach-mark-expr
              body
              (tltest-reach-mark-expr
                value
                (tltest-reach-mark-expr
                  init
                  (tltest-reach-mark-expr
                    end
                    (tltest-reach-mark-expr start names))))))])]
    [(AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (tltest-reach-mark-expr lane (tltest-reach-mark-expr value names)))]
    [(AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (tltest-reach-mark-expr lane (tltest-reach-mark-expr value names)))]
    [(AstExpr.StructGet receiver-box _)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (tltest-reach-mark-expr receiver names))]
    [(AstExpr.StructSet receiver-box _ value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-expr receiver names)))]
    [(AstExpr.WithRegion _ body) (tltest-reach-mark-expr-list body names)]
    [(AstExpr.WithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (tltest-reach-mark-expr-list
          body
          (tltest-reach-mark-expr
            scratch
            (tltest-reach-mark-string-snapshot-runtime names))))]
    [(AstExpr.WithScratch body)
      (tltest-reach-mark-expr-list
        body
        (tltest-reach-mark-string-snapshot-runtime names))]
    [(AstExpr.InArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (tltest-reach-mark-expr-list body (tltest-reach-mark-expr arena names)))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (tltest-reach-mark-expr-list
            body
            (tltest-reach-mark-resource-bindings bindings names))])]
    [(AstExpr.Box inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.BoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.BoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.BoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-expr inner names)))]
    [(AstExpr.Borrow _ _ place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (tltest-reach-mark-expr place names))]
    [(AstExpr.TypeLiteral _) names]
    [(AstExpr.Init _) names]
    [(AstExpr.Comptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Quote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Quasiquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Unquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.BracketClause items) (tltest-reach-mark-expr-list items names)]
    [(AstExpr.Try inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Return inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.Break) names]
    [(AstExpr.Continue) names]
    [(AstExpr.PtrNull _) names]
    [(AstExpr.PtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.PtrAddrOf _) names]
    [(AstExpr.PtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr value (tltest-reach-mark-expr ptr names)))]
    [(AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (tltest-reach-mark-expr offset (tltest-reach-mark-expr ptr names)))]
    [(AstExpr.PtrCast ptr-box _)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExpr.PtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (tltest-reach-mark-expr ptr names))]
    [(AstExpr.IntToPtr value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (tltest-reach-mark-expr value names))]
    [(AstExpr.StringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (tltest-reach-mark-expr len (tltest-reach-mark-expr ptr names)))]
    [(AstExpr.ArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (tltest-reach-mark-expr inner names))]
    [(AstExpr.BinaryData _) names]
    [(AstExpr.SpmdProgramIndex) names]
    [(AstExpr.SpmdProgramCount) names]
    [(AstExpr.ProgramArgc) names]
    [(AstExpr.ProgramArgv) names]
    [(AstExpr.ProgramEnvp) names]
    [(AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (tltest-reach-mark-expr subleaf (tltest-reach-mark-expr leaf names)))]
    [(AstExpr.Xgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (tltest-reach-mark-expr index names))]
    [(AstExpr.Syscall args) (tltest-reach-mark-expr-list args names)]))

(define (tltest-reach-mark-tests-from
  [tests : (Array InlineTest)]
  [index : i64]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (if (< index 0)
    names
    (let
      [test : InlineTest (array-ref tests index)]
      (match test
        [(InlineTest.Case _ _ _ body _)
          (tltest-reach-mark-tests-from
            tests
            (- index 1)
            (tltest-reach-mark-expr (ast-node-get body) names))]))))

(define (tltest-reach-mark-tests
  [tests : (Array InlineTest)]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (tltest-reach-mark-tests-from tests (- (array-length tests) 1) names))

(define (tltest-runtime-string-helper-impl-name? [name : String]) : bool
  (or
    (string.eq name "tl-runtime-int-to-string")
    (string.eq name "tl-runtime-substring")
    (string.eq name "tl-runtime-str-view")
    (string.eq name "tl-runtime-string-concat")
    (string.eq name "tl-runtime-string-concat3")
    (string.eq name "tl-runtime-string-concat4")
    (string.eq name "tl-runtime-string-concat5")
    (string.eq name "eq")
    (string.eq name "string-concat-all")
    (string.eq name "string-concat-all-pack-part")
    (string.eq name "string-concat3")
    (string.eq name "string-concat4")
    (string.eq name "string-concat5")))

(define (tltest-reach-mark-runtime-helper-root
  [decl : AstDecl]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match decl
    [(AstDecl.DefFn name _ _ _ _)
      (let
        [name-str : String (intern-str name)]
        (if (tltest-runtime-string-helper-impl-name? name-str)
          (tltest-reach-mark-name names name-str)
          names))]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-reach-mark-runtime-helper-root inner names))]
    [(AstDecl.ComptimeDecl _ inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-reach-mark-runtime-helper-root inner names))]
    [_ names]))

(define (tltest-reach-mark-runtime-helper-roots
  [decls : AstDeclList]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (let
    [cur : AstDeclList decls]
    [result : hashmap.StringI64Map names]
    [done : bool false]
    (begin
      (while (not done)
        (match cur
          [(AstDeclList.Nil) (set! done true)]
          [(AstDeclList.Cons decl rest)
            (begin
              (set! result (tltest-reach-mark-runtime-helper-root decl result))
              (set! cur (box-get rest)))]))
      result)))

(define (tltest-reach-mark-struct-cleanup
  [cleanup : AstStructCleanup]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match cleanup
    [(AstStructCleanup.Fn name)
      (tltest-reach-mark-name names (intern-str name))]
    [(AstStructCleanup.No) names]))

(define (tltest-reach-mark-enum-cleanup
  [cleanup : AstEnumCleanup]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match cleanup
    [(AstEnumCleanup.Fn name) (tltest-reach-mark-name names (intern-str name))]
    [(AstEnumCleanup.No) names]))

(define (tltest-reach-mark-field-cleanup
  [cleanup : AstFieldCleanup]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match cleanup
    [(AstFieldCleanup.Fn name) (tltest-reach-mark-name names (intern-str name))]
    [_ names]))

(define (tltest-reach-mark-field-cleanups
  [fields : AstFieldDefList]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (tltest-reach-mark-field-cleanups-at (& fields) names 0))

(define (tltest-reach-mark-field-cleanups-at
  [fields : (& fields AstFieldDefList)]
  [names : hashmap.StringI64Map]
  [index : i64]) : hashmap.StringI64Map
  (if (>= index (ast-field-def-list-len fields))
    names
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ _ cleanup)
        (tltest-reach-mark-field-cleanups-at
          fields
          (tltest-reach-mark-field-cleanup cleanup names)
          (+ index 1))])))

(define (tltest-reach-mark-variant-payload-cleanup
  [cleanup : AstVariantPayloadCleanup]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match cleanup
    [(AstVariantPayloadCleanup.Fn name)
      (tltest-reach-mark-name names (intern-str name))]
    [_ names]))

(define (tltest-reach-mark-variant-payload-cleanups
  [cleanups : AstVariantPayloadCleanupList]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match cleanups
    [(AstVariantPayloadCleanupList.Nil) names]
    [(AstVariantPayloadCleanupList.Cons cleanup rest)
      (tltest-reach-mark-variant-payload-cleanups
        (box-get rest)
        (tltest-reach-mark-variant-payload-cleanup cleanup names))]))

(define (tltest-reach-mark-variant-cleanups
  [variants : AstVariantDefList]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match variants
    [(AstVariantDefList.Nil) names]
    [(AstVariantDefList.Cons variant rest)
      (match variant
        [(AstVariantDef.Def _ _ cleanups)
          (tltest-reach-mark-variant-cleanups
            (box-get rest)
            (tltest-reach-mark-variant-payload-cleanups cleanups names))])]))

(define (tltest-reach-mark-decl [decl : AstDecl] [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match decl
    [(AstDecl.Def name _ expr-box)
      (let
        [expr : AstExpr (ast-node-get expr-box)]
        (if (tltest-reachable-name-marked? names (intern-str name))
          (tltest-reach-mark-expr expr names)
          names))]
    [(AstDecl.DefFn name _ _ body-box export)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match export
          [(AstFnExport.Export _)
            (tltest-reach-mark-expr
              body
              (tltest-reach-mark-name names (intern-str name)))]
          [(AstFnExport.No)
            (if (tltest-reachable-name-marked? names (intern-str name))
              (tltest-reach-mark-expr body names)
              names)]))]
    [(AstDecl.DefMacro _ _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (tltest-reach-mark-expr body names))]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-reach-mark-decl inner names))]
    [(AstDecl.ComptimeDecl _ inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-reach-mark-decl inner names))]
    [(AstDecl.DefStruct _ _ cleanup fields)
      (tltest-reach-mark-field-cleanups
        fields
        (tltest-reach-mark-struct-cleanup cleanup names))]
    [(AstDecl.DefStructLifetimes _ _ _ cleanup fields)
      (tltest-reach-mark-field-cleanups
        fields
        (tltest-reach-mark-struct-cleanup cleanup names))]
    [(AstDecl.DefEnum _ cleanup variants)
      (tltest-reach-mark-variant-cleanups
        variants
        (tltest-reach-mark-enum-cleanup cleanup names))]
    [(AstDecl.DefEnumLifetimes _ _ cleanup variants)
      (tltest-reach-mark-variant-cleanups
        variants
        (tltest-reach-mark-enum-cleanup cleanup names))]
    [_ names]))

(define (tltest-reach-mark-decls-from
  [decls : AstDeclList]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (let
    [cur : AstDeclList decls]
    [result : hashmap.StringI64Map names]
    [done : bool false]
    (begin
      (while (not done)
        (match cur
          [(AstDeclList.Nil) (set! done true)]
          [(AstDeclList.Cons decl rest)
            (begin
              (set! result (tltest-reach-mark-decl decl result))
              (set! cur (box-get rest)))]))
      result)))

;; Iterate the reachability marker to a fixpoint. The reachable-name set only
;; ever grows (marking is monotonic and dedup'd), so a pass that adds no new
;; names means we have converged and can stop. `fuel` (the decl count) stays as
;; a safety bound, but convergence normally takes only a handful of passes -
;; avoiding the previous unconditional O(decls^2) full-program walks.
(define (tltest-reach-fixed
  [decls : AstDeclList]
  [fuel : i64]
  [names : hashmap.StringI64Map]) : hashmap.StringI64Map
  (let
    [remaining : i64 fuel]
    [result : hashmap.StringI64Map names]
    [done : bool false]
    (begin
      (while (and (not done) (> remaining 0))
        (let
          [before : i64 (hashmap.string-i64-map-len result)]
          [next : hashmap.StringI64Map
            (tltest-reach-mark-decls-from decls result)]
          (begin
            (set! result next)
            (if (= (hashmap.string-i64-map-len result) before)
              (set! done true)
              (set! remaining (- remaining 1))))))
      result)))

(define (tltest-reachable-names
  [decls : AstDeclList]
  [tests : (Array InlineTest)]) : hashmap.StringI64Map
  (tltest-reach-fixed
    decls
    (tltest-decl-list-count decls)
    (tltest-reach-mark-runtime-helper-roots
      decls
      (tltest-reach-mark-tests tests (hashmap.string-i64-map-with-capacity 64)))))

(define (tltest-reachable-runtime-decl?
  [decl : AstDecl]
  [names : hashmap.StringI64Map]) : bool
  (match decl
    [(AstDecl.Def name _ _)
      (let
        [name-str : String (intern-str name)]
        [marked : bool (tltest-reachable-name-marked? names name-str)]
        marked)]
    [(AstDecl.DefFn name _ _ _ export)
      (let
        [name-str : String (intern-str name)]
        [marked : bool (tltest-reachable-name-marked? names name-str)]
        (match export
          [(AstFnExport.Export _) true]
          [(AstFnExport.No) marked]))]
    [(AstDecl.Extern name _ _ _)
      (let
        [name-str : String (intern-str name)]
        [marked : bool (tltest-reachable-name-marked? names name-str)]
        marked)]
    [(AstDecl.DefMacro _ _ _ _) true]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-reachable-runtime-decl? inner names))]
    [(AstDecl.ComptimeDecl _ inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-reachable-runtime-decl? inner names))]
    [_ true]))

(define (tltest-prune-runtime-decls-in
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [target-path : String]
  [names : hashmap.StringI64Map]
  [out-decls : AstDeclList]
  [out-paths : AstDeclPathList]) : InlineRuntimeDecls
  (let
    [cur-decls : AstDeclList decls]
    [cur-paths : AstDeclPathList paths]
    [result-decls : AstDeclList out-decls]
    [result-paths : AstDeclPathList out-paths]
    [done : bool false]
    (begin
      (while (not done)
        (match cur-decls
          [(AstDeclList.Nil) (set! done true)]
          [(AstDeclList.Cons decl rest)
            (match cur-paths
              [(AstDeclPathList.Nil)
                (begin
                  (set! cur-decls (box-get rest))
                  (set! cur-paths AstDeclPathList.Nil))]
              [(AstDeclPathList.Cons decl-path path-rest)
                (begin
                  ;; Keep imported generated helpers: macro-expanded bodies can
                  ;; reference them in ways the lightweight source reachability walk
                  ;; cannot always see. Local generated helpers and ordinary imported
                  ;; functions/values still go through reachability pruning so tiny
                  ;; inline harnesses stay small.
                  (if (or
                    (tltest-reachable-runtime-decl? decl names)
                    (and
                      (not (tltest-owned-test-path? target-path decl-path))
                      (tltest-generated-comptime-decl? decl)))
                    (begin
                      (set! result-decls (ast-decl-cons decl result-decls))
                      (set!
                        result-paths
                        (ast-decl-path-cons decl-path result-paths)))
                    unit)
                  (set! cur-decls (box-get rest))
                  (set! cur-paths (box-get path-rest)))])]))
      (InlineRuntimeDecls.Decls
        (tltest-decl-list-reverse-onto result-decls AstDeclList.Nil)
        (tltest-path-list-reverse-onto result-paths AstDeclPathList.Nil)))))

(define (tltest-prune-runtime-decls
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [tests : (Array InlineTest)]) : InlineRuntimeDecls
  (tltest-prune-runtime-decls-in
    decls
    paths
    (compiler-load-normalize-path source)
    (tltest-reachable-names decls tests)
    AstDeclList.Nil
    AstDeclPathList.Nil))

(define (tltest-build-harness
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : InlineHarness
  (match (tltest-collect source decls paths)
    [(InlineCollect.Collect runtime-decls runtime-paths tests)
      (match (tltest-prune-runtime-decls
        source
        runtime-decls
        runtime-paths
        tests)
        [(InlineRuntimeDecls.Decls pruned-decls pruned-paths)
          (let
            [count : i64 (array-length tests)]
            (InlineHarness.Harness
              (ast-program
                (compiler-load-decl-list-append
                  pruned-decls
                  (tltest-test-decls-onto
                    tests
                    (- count 1)
                    (ast-decl-cons (tltest-main-decl tests) AstDeclList.Nil))))
              (compiler-load-decl-path-list-append
                pruned-paths
                (tltest-test-paths-onto
                  tests
                  (- count 1)
                  (ast-decl-path-cons source AstDeclPathList.Nil)))
              count))])]))

(define (tltest-inline-typecheck-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-cfg-enable cfgs "test"))

(define (tltest-inline-typecheck-program
  [decls : AstDeclList]
  [tests : (Array InlineTest)]) : AstProgram
  (ast-program
    (compiler-load-decl-list-append
      decls
      (tltest-test-decls-onto tests (- (array-length tests) 1) AstDeclList.Nil))))

(define (tltest-inline-typecheck-paths
  [paths : AstDeclPathList]
  [tests : (Array InlineTest)]) : AstDeclPathList
  (compiler-load-decl-path-list-append
    paths
    (tltest-test-paths-onto
      tests
      (- (array-length tests) 1)
      AstDeclPathList.Nil)))

(define (tltest-inline-typecheck-loaded
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (match (tltest-collect source decls paths)
    [(InlineCollect.Collect runtime-decls runtime-paths tests)
      (let
        [count : i64 (array-length tests)]
        (if (= count 0)
          0
          (match (tltest-prune-runtime-decls
            source
            runtime-decls
            runtime-paths
            tests)
            [(InlineRuntimeDecls.Decls pruned-decls pruned-paths)
              (match (typecheck-compiler-program-with-paths-cache
                (tltest-inline-typecheck-program pruned-decls tests)
                (tltest-inline-typecheck-paths pruned-paths tests)
                roots
                (compiler-typecheck-prefix-cache-scope
                  cache-scope-prefix
                  roots
                  cfgs))
                [(ResultCompilerTypecheck.Ok _) 0]
                [(ResultCompilerTypecheck.Err diag)
                  (begin
                    (io.print-error
                      (compiler-diagnostic-render
                        (tltest-diagnostic-with-source-fallback
                          source
                          (box-get diag))))
                    1)])])))]))

(define (tltest-inline-stdlib-source?
  [source : String]
  [roots : vector.StringVec]) : bool
  (let
    [normalized : String (compiler-load-normalize-path source)]
    [stdlib-path : String
      (if (compiler-load-stdlib-import? normalized)
        normalized
        (compiler-load-stdlib-owned-path-from-roots normalized roots))]
    (compiler-load-stdlib-import? stdlib-path)))

(define (tltest-inline-clear-load-only-caches!) : unit
  (begin
    (compiler-load-program-cache-clear!)
    (compiler-load-runtime-prelude-cache-clear!)
    (tc-prefix-snapshot-cache-clear!)))

(define (tltest-inline-clear-load-caches!) : unit
  (begin
    (tltest-inline-clear-load-only-caches!)
    (compiler-driver-reset-analysis-state!)))

(define (tltest-inline-reset-load-state!) : unit
  (begin
    ;; Inline preflight runs after ordinary check/doctest phases in some CLI
    ;; commands. Drop cached loaded ASTs so the test-cfg load cannot reuse decl
    ;; nodes owned by a previous phase. Reset AST/type pools between package
    ;; sources to keep large packages bounded, but keep interns live because
    ;; callers may have already constructed cfg maps and path strings.
    (tltest-inline-clear-load-caches!)
    (compiler-load-session-reset-pools!)
    (compiler-driver-reset-analysis-state!)))

(define (tltest-inline-typecheck-file-with-cfg
  [source : String]
  [roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (if (or
    (tltest-inline-stdlib-source? source roots)
    (not (io.file-exists? source))
    (not (tltest-source-has-inline-tests? source)))
    0
    (let
      [test-cfgs : sym_i64_env.SymI64Env (tltest-inline-typecheck-cfgs cfgs)]
      (begin
        (tltest-inline-reset-load-state!)
        (match (compiler-driver-load-file-with-runtime source roots test-cfgs)
          [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (tltest-inline-typecheck-loaded
              source
              decls
              paths
              roots
              test-cfgs
              cache-scope-prefix)]
          [(ResultCompilerLoadWithPaths.Err diag)
            (begin
              (io.print-error
                (compiler-diagnostic-render
                  (tltest-diagnostic-with-source-fallback source (box-get diag))))
              1)])))))

(define (tltest-inline-typecheck-package-source-with-cfg
  [source : String]
  [roots : vector.StringVec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (if (tltest-source-has-inline-tests? source)
    (let
      [test-cfgs : sym_i64_env.SymI64Env (tltest-inline-typecheck-cfgs cfgs)]
      (match (compiler-driver-load-package-file-with-runtime-owned-cfg
        source
        roots
        manifest-dir
        package-owner
        deps
        true
        test-cfgs)
        [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (tltest-inline-typecheck-loaded
            (compiler-load-package-owned-path
              package-owner
              manifest-dir
              roots
              source)
            decls
            paths
            roots
            test-cfgs
            cache-scope-prefix)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (begin
            (io.print-error
              (compiler-diagnostic-render
                (tltest-diagnostic-with-source-fallback source (box-get diag))))
            1)]))
    0))

(defenum TltestCfgNameList
  (Nil)
  (Cons String i64 (Box TltestCfgNameList)))

(define (tltest-cfg-name-list-from-env [cfgs : sym_i64_env.SymI64Env]) : TltestCfgNameList
  (match cfgs
    [(sym_i64_env.SymI64Nil) (TltestCfgNameList.Nil)]
    [(sym_i64_env.SymI64Bind key value rest)
      (TltestCfgNameList.Cons
        (intern-str key)
        value
        (box (tltest-cfg-name-list-from-env (box-get rest))))]))

(define (tltest-cfg-name-list-to-env [names : TltestCfgNameList]) : sym_i64_env.SymI64Env
  (match names
    [(TltestCfgNameList.Nil) (sym_i64_env.sym-i64-empty)]
    [(TltestCfgNameList.Cons name value rest)
      (sym_i64_env.sym-i64-bind
        (tltest-cfg-name-list-to-env (box-get rest))
        name
        value)]))

(define (tltest-inline-typecheck-package-sources-from
  [sources : PackageSourceList]
  [index : i64]
  [roots : vector.StringVec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (let
    [count : i64 (package-source-list-len sources)]
    [cursor : i64 index]
    [status : i64 0]
    [cfg-names : TltestCfgNameList (tltest-cfg-name-list-from-env cfgs)]
    (begin
      (while (and (= status 0) (< cursor count))
        (let
          [source : String (package-source-list-get sources cursor "")]
          [has-inline-tests : bool (tltest-source-has-inline-tests? source)]
          (begin
            (if has-inline-tests
              (begin
                (tltest-inline-clear-load-caches!)
                (set!
                  status
                  ;; Match package `test --check`: isolate each inline preflight
                  ;; source so package builds do not retain every loaded/test AST
                  ;; until the end of the package. The full file reset refreshes
                  ;; interns, so rebuild cfg ids from the saved string snapshot.
                  (with-scratch
                    (begin
                      (tltest-inline-clear-load-only-caches!)
                      (compiler-driver-reset-file-state!)
                      (tltest-inline-typecheck-package-source-with-cfg
                        source
                        roots
                        manifest-dir
                        package-owner
                        deps
                        (tltest-cfg-name-list-to-env cfg-names)
                        cache-scope-prefix))))
                (tltest-inline-clear-load-caches!))
              (set! status 0))
            (if (= status 0)
              unit
              (io.print-error
                (string.append "test: package inline preflight failed: " source)))
            (set! cursor (+ cursor 1)))))
      (begin
        (begin
          (tltest-inline-clear-load-only-caches!)
          (compiler-driver-reset-file-state!))
        status))))

(define (tltest-inline-typecheck-package-sources-with-cfg
  [sources : PackageSourceList]
  [roots : vector.StringVec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope-prefix : String]) : i64
  (tltest-inline-typecheck-package-sources-from
    sources
    0
    roots
    manifest-dir
    package-owner
    deps
    cfgs
    cache-scope-prefix))

(define (tltest-path-at [paths : AstDeclPathList] [index : i64]) : String
  (match paths
    [(AstDeclPathList.Nil) ""]
    [(AstDeclPathList.Cons path rest)
      (if (= index 0)
        path
        (tltest-path-at (box-get rest) (- index 1)))]))

(define (tltest-decl-name [decl : AstDecl]) : String
  (match decl
    [(AstDecl.Def name _ _) (intern-str name)]
    [(AstDecl.DefFn name _ _ _ _) (intern-str name)]
    [(AstDecl.DefMacro name _ _ _) (intern-str name)]
    [(AstDecl.Extern name _ _ _) (intern-str name)]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-decl-name inner))]
    [(AstDecl.ComptimeDecl _ inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tltest-decl-name inner))]
    [_ ""]))

(define (tltest-decl-name-at [decls : AstDeclList] [index : i64]) : String
  (match decls
    [(AstDeclList.Nil) ""]
    [(AstDeclList.Cons decl rest)
      (if (= index 0)
        (tltest-decl-name decl)
        (tltest-decl-name-at (box-get rest) (- index 1)))]))

(define (tltest-decl-list-has-name? [decls : AstDeclList] [name : String]) : bool
  (match decls
    [(AstDeclList.Nil) false]
    [(AstDeclList.Cons decl rest)
      (if (string.eq (tltest-decl-name decl) name)
        true
        (tltest-decl-list-has-name? (box-get rest) name))]))

(define (tltest-import-alias-call-retained-self-test?) : bool
  (let
    [span : AstSourceSpan (AstSourceSpan 1 1 1 1)]
    [dep-path : String "stdlib/string.tl"]
    [source : String "stdlib/args.tl"]
    [dep-fn : AstDecl
      (ast-decl-def-fn
        "eq"
        AstParamList.Nil
        (AstType.Bool)
        (ast-node-push (AstExpr.Literal (AstLiteral.Bool true))))]
    [source-import : AstDecl
      (AstDecl.Import
        (AstImportSpec.Spec
          (AstImportKind.Module)
          dep-path
          (AstMaybeModuleName.Some "stdlib.string")
          (AstMaybeImportAlias.Some "string")
          span))]
    [decls : AstDeclList
      (ast-decl-cons
        (ast-decl-module "stdlib.string")
        (ast-decl-cons
          dep-fn
          (ast-decl-cons
            (ast-decl-module "stdlib.args")
            (ast-decl-cons
              source-import
              (ast-decl-cons
                (ast-decl-test "owned" (tltest-call-expr "string.eq") span)
                AstDeclList.Nil)))))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        dep-path
        (ast-decl-path-cons
          dep-path
          (ast-decl-path-cons
            source
            (ast-decl-path-cons
              source
              (ast-decl-path-cons source AstDeclPathList.Nil)))))]
    (match (tltest-build-harness source decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (and
              (= count 1)
              (tltest-decl-list-has-name? (box-get harness-decls-box) "eq"))])])))

(test
  test-cli-inline-harness-keeps-alias-qualified-base
  (if (tltest-import-alias-call-retained-self-test?)
    unit
    (io.panic "test CLI alias-qualified reachability mismatch")))

(define (tltest-vector-builders-self-test?) : bool
  (let
    [helper-name : String "__tl_fixture_helper"]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        helper-name
        AstParamList.Nil
        (AstType.Unit)
        (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))]
    [first-span : AstSourceSpan (AstSourceSpan 11 1 11 1)]
    [second-span : AstSourceSpan (AstSourceSpan 22 1 22 1)]
    [decls : AstDeclList
      (ast-decl-cons
        helper-decl
        (ast-decl-cons
          (ast-decl-test "first" (tltest-call-expr helper-name) first-span)
          (ast-decl-cons
            (ast-decl-test "second" (tltest-call-expr helper-name) second-span)
            AstDeclList.Nil)))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "runtime.tl"
        (ast-decl-path-cons
          "driver.tl"
          (ast-decl-path-cons "driver.tl" AstDeclPathList.Nil)))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness.Harness program harness-paths count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 2)
                (string.eq (tltest-decl-name-at harness-decls 0) helper-name)
                (string.eq
                  (tltest-decl-name-at harness-decls 1)
                  "__tl_inline_test_0")
                (string.eq
                  (tltest-decl-name-at harness-decls 2)
                  "__tl_inline_test_1")
                (string.eq (tltest-decl-name-at harness-decls 3) "main")
                (string.eq (tltest-path-at harness-paths 0) "runtime.tl")
                (string.eq (tltest-path-at harness-paths 1) "driver.tl")
                (string.eq (tltest-path-at harness-paths 2) "driver.tl")
                (string.eq (tltest-path-at harness-paths 3) "driver.tl")))])])))

(test
  test-cli-vector-builders-preserve-order
  (if (tltest-vector-builders-self-test?)
    unit
    (io.panic "test CLI vector builder order mismatch")))

(define (tltest-generated-runtime-reachability-self-test?) : bool
  (let
    [unit-expr : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))]
    [substring-decl : AstDecl
      (ast-decl-def-fn
        "tl-runtime-substring"
        AstParamList.Nil
        (AstType.Unit)
        unit-expr)]
    [str-view-decl : AstDecl
      (ast-decl-def-fn
        "tl-runtime-str-view"
        AstParamList.Nil
        (AstType.Unit)
        unit-expr)]
    [helper-body : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons
            (ast-expr-with-scratch (ast-expr-cons unit-expr AstExprList.Nil))
            (ast-expr-cons
              (tltest-call-expr "tl_bytes_view_from_str_parts")
              (ast-expr-cons unit-expr AstExprList.Nil)))))]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        "__tl_generated_runtime_helper"
        AstParamList.Nil
        (AstType.Unit)
        helper-body)]
    [span : AstSourceSpan (AstSourceSpan 17 1 17 1)]
    [decls : AstDeclList
      (ast-decl-cons
        substring-decl
        (ast-decl-cons
          str-view-decl
          (ast-decl-cons
            helper-decl
            (ast-decl-cons
              (ast-decl-test
                "keeps-generated-runtime"
                (tltest-call-expr "__tl_generated_runtime_helper")
                span)
              AstDeclList.Nil))))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "stdlib/runtime.tl"
        (ast-decl-path-cons
          "stdlib/runtime.tl"
          (ast-decl-path-cons
            "driver.tl"
            (ast-decl-path-cons "driver.tl" AstDeclPathList.Nil))))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 1)
                (string.eq
                  (tltest-decl-name-at harness-decls 0)
                  "tl-runtime-substring")
                (string.eq
                  (tltest-decl-name-at harness-decls 1)
                  "tl-runtime-str-view")
                (string.eq
                  (tltest-decl-name-at harness-decls 2)
                  "__tl_generated_runtime_helper")))])])))

(test
  test-cli-inline-harness-keeps-lowered-runtime-helpers
  (if (tltest-generated-runtime-reachability-self-test?)
    unit
    (io.panic "test CLI inline harness dropped lowered runtime helper")))

(define (tltest-generated-runtime-lambda-reachability-self-test?) : bool
  (let
    [unit-expr : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))]
    [substring-decl : AstDecl
      (ast-decl-def-fn
        "tl-runtime-substring"
        AstParamList.Nil
        (AstType.Unit)
        unit-expr)]
    [lambda-expr : i64
      (ast-expr-lambda AstParamList.Nil AstMaybeType.No unit-expr)]
    [helper-body : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons lambda-expr (ast-expr-cons unit-expr AstExprList.Nil))))]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        "__tl_generated_lambda_helper"
        AstParamList.Nil
        (AstType.Unit)
        helper-body)]
    [span : AstSourceSpan (AstSourceSpan 18 1 18 1)]
    [decls : AstDeclList
      (ast-decl-cons
        substring-decl
        (ast-decl-cons
          helper-decl
          (ast-decl-cons
            (ast-decl-test
              "keeps-generated-lambda-runtime"
              (tltest-call-expr "__tl_generated_lambda_helper")
              span)
            AstDeclList.Nil)))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "stdlib/runtime.tl"
        (ast-decl-path-cons
          "driver.tl"
          (ast-decl-path-cons "driver.tl" AstDeclPathList.Nil)))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 1)
                (string.eq
                  (tltest-decl-name-at harness-decls 0)
                  "tl-runtime-substring")
                (string.eq
                  (tltest-decl-name-at harness-decls 1)
                  "__tl_generated_lambda_helper")))])])))

(test
  test-cli-inline-harness-keeps-lambda-runtime-helper
  (if (tltest-generated-runtime-lambda-reachability-self-test?)
    unit
    (io.panic "test CLI inline harness dropped lambda runtime helper")))

(define (tltest-generated-runtime-substring-reachability-self-test?) : bool
  (let
    [unit-expr : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))]
    [substring-decl : AstDecl
      (ast-decl-def-fn
        "tl-runtime-substring"
        AstParamList.Nil
        (AstType.Unit)
        unit-expr)]
    [helper-body : i64
      (ast-node-push
        (AstExpr.Begin
          (ast-expr-cons
            (tltest-call-expr "substring")
            (ast-expr-cons unit-expr AstExprList.Nil))))]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        "__tl_generated_substring_helper"
        AstParamList.Nil
        (AstType.Unit)
        helper-body)]
    [span : AstSourceSpan (AstSourceSpan 19 1 19 1)]
    [decls : AstDeclList
      (ast-decl-cons
        substring-decl
        (ast-decl-cons
          helper-decl
          (ast-decl-cons
            (ast-decl-test
              "keeps-generated-substring-runtime"
              (tltest-call-expr "__tl_generated_substring_helper")
              span)
            AstDeclList.Nil)))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "stdlib/runtime.tl"
        (ast-decl-path-cons
          "driver.tl"
          (ast-decl-path-cons "driver.tl" AstDeclPathList.Nil)))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 1)
                (string.eq
                  (tltest-decl-name-at harness-decls 0)
                  "tl-runtime-substring")
                (string.eq
                  (tltest-decl-name-at harness-decls 1)
                  "__tl_generated_substring_helper")))])])))

(test
  test-cli-inline-harness-keeps-substring-runtime-helper
  (if (tltest-generated-runtime-substring-reachability-self-test?)
    unit
    (io.panic "test CLI inline harness dropped substring runtime helper")))

(define (tltest-imported-tests-skipped-self-test?) : bool
  (let
    [helper-name : String "__tl_imported_skip_helper"]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        helper-name
        AstParamList.Nil
        (AstType.Unit)
        (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))]
    [owned-span : AstSourceSpan (AstSourceSpan 5 1 5 1)]
    [imported-span : AstSourceSpan (AstSourceSpan 9 1 9 1)]
    [decls : AstDeclList
      (ast-decl-cons
        helper-decl
        (ast-decl-cons
          (ast-decl-test "owned" (tltest-call-expr helper-name) owned-span)
          (ast-decl-cons
            (ast-decl-test
              "imported"
              (tltest-call-expr helper-name)
              imported-span)
            AstDeclList.Nil)))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "driver.tl"
        (ast-decl-path-cons
          "driver.tl"
          (ast-decl-path-cons "imported.tl" AstDeclPathList.Nil)))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness.Harness program harness-paths count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 1)
                (string.eq (tltest-decl-name-at harness-decls 0) helper-name)
                (string.eq
                  (tltest-decl-name-at harness-decls 1)
                  "__tl_inline_test_0")
                (string.eq (tltest-decl-name-at harness-decls 2) "main")
                (string.eq (tltest-path-at harness-paths 0) "driver.tl")
                (string.eq (tltest-path-at harness-paths 1) "driver.tl")
                (string.eq (tltest-path-at harness-paths 2) "driver.tl")))])])))

(test
  test-cli-inline-harness-skips-imported-tests
  (if (tltest-imported-tests-skipped-self-test?)
    unit
    (io.panic "test CLI inline harness kept imported test")))

(define (tltest-import-alias-preserved? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Import
        (AstImportSpec.Spec
          _
          _
          (AstMaybeModuleName.Some module)
          (AstMaybeImportAlias.Some alias)
          _))
      (and (string.eq module "stdlib.core_macros") (string.eq alias "core"))]
    [_ false]))

(define (tltest-import-alias-preserved-self-test?) : bool
  (let
    [import-decl : AstDecl
      (AstDecl.Import
        (AstImportSpec.Spec
          (AstImportKind.Path)
          "stdlib/core_macros.tl"
          (AstMaybeModuleName.Some "stdlib.core_macros")
          (AstMaybeImportAlias.Some "core")
          (AstSourceSpan 0 0 0 0)))]
    [span : AstSourceSpan (AstSourceSpan 9 1 9 1)]
    [decls : AstDeclList
      (ast-decl-cons
        import-decl
        (ast-decl-cons
          (ast-decl-test
            "uses-qualified-macro-alias"
            (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))
            span)
          AstDeclList.Nil))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "alias.tl"
        (ast-decl-path-cons "alias.tl" AstDeclPathList.Nil))]
    (match (tltest-build-harness "alias.tl" decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (match (box-get harness-decls-box)
              [(AstDeclList.Cons first _)
                (and (= count 1) (tltest-import-alias-preserved? first))]
              [_ false])])])))

(test
  test-cli-inline-harness-preserves-import-aliases
  (if (tltest-import-alias-preserved-self-test?)
    unit
    (io.panic "test CLI inline harness dropped import alias")))

(define (tltest-runtime-string-helper-roots-self-test?) : bool
  (let
    [dep-name : String "__tl_runtime_helper_dep"]
    [helper-name : String "tl-runtime-substring"]
    [eq-dep-name : String "__tl_runtime_eq_dep"]
    [eq-name : String "eq"]
    [dep-decl : AstDecl
      (ast-decl-def-fn
        dep-name
        AstParamList.Nil
        (AstType.Unit)
        (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        helper-name
        AstParamList.Nil
        (AstType.Unit)
        (tltest-call-expr dep-name))]
    [eq-dep-decl : AstDecl
      (ast-decl-def-fn
        eq-dep-name
        AstParamList.Nil
        (AstType.Unit)
        (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))]
    [eq-decl : AstDecl
      (ast-decl-def-fn
        eq-name
        AstParamList.Nil
        (AstType.Unit)
        (tltest-call-expr eq-dep-name))]
    [span : AstSourceSpan (AstSourceSpan 13 1 13 1)]
    [decls : AstDeclList
      (ast-decl-cons
        dep-decl
        (ast-decl-cons
          helper-decl
          (ast-decl-cons
            eq-dep-decl
            (ast-decl-cons
              eq-decl
              (ast-decl-cons
                (ast-decl-test
                  "runtime-helper-not-called-by-test"
                  (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))
                  span)
                AstDeclList.Nil)))))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "stdlib/runtime.tl"
        (ast-decl-path-cons
          "stdlib/runtime.tl"
          (ast-decl-path-cons
            "stdlib/string.tl"
            (ast-decl-path-cons
              "stdlib/string.tl"
              (ast-decl-path-cons "driver.tl" AstDeclPathList.Nil)))))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 1)
                (tltest-decl-list-has-name? harness-decls helper-name)
                (tltest-decl-list-has-name? harness-decls dep-name)
                (tltest-decl-list-has-name? harness-decls eq-name)
                (tltest-decl-list-has-name? harness-decls eq-dep-name)))])])))

(test
  test-cli-inline-harness-keeps-runtime-string-helper-roots
  (if (tltest-runtime-string-helper-roots-self-test?)
    unit
    (io.panic "test CLI inline harness pruned runtime string helper root")))

(define (tltest-generated-wrapper [item : String] [decl : AstDecl]) : AstDecl
  (ast-decl-comptime-decl-with-meta
    (AstGeneratedDeclMeta.Some "tltest-generated" item AstExprList.Nil "tltest")
    decl))

(define (tltest-generated-reachability-self-test?) : bool
  (let
    [dep-name : String "__tl_generated_reachable_dep"]
    [live-name : String "__tl_generated_reachable_live"]
    [dead-name : String "__tl_generated_reachable_dead"]
    [dep-decl : AstDecl
      (tltest-generated-wrapper
        dep-name
        (ast-decl-def-fn
          dep-name
          AstParamList.Nil
          (AstType.Unit)
          (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))))]
    [live-decl : AstDecl
      (tltest-generated-wrapper
        live-name
        (ast-decl-def-fn
          live-name
          AstParamList.Nil
          (AstType.Unit)
          (tltest-call-expr dep-name)))]
    [dead-decl : AstDecl
      (tltest-generated-wrapper
        dead-name
        (ast-decl-def-fn
          dead-name
          AstParamList.Nil
          (AstType.Unit)
          (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))))]
    [span : AstSourceSpan (AstSourceSpan 23 1 23 1)]
    [decls : AstDeclList
      (ast-decl-cons
        dep-decl
        (ast-decl-cons
          live-decl
          (ast-decl-cons
            dead-decl
            (ast-decl-cons
              (ast-decl-test
                "uses-generated-live"
                (tltest-call-expr live-name)
                span)
              AstDeclList.Nil))))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "driver.tl"
        (ast-decl-path-cons
          "driver.tl"
          (ast-decl-path-cons
            "driver.tl"
            (ast-decl-path-cons "driver.tl" AstDeclPathList.Nil))))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 1)
                (tltest-decl-list-has-name? harness-decls live-name)
                (tltest-decl-list-has-name? harness-decls dep-name)
                (not (tltest-decl-list-has-name? harness-decls dead-name))))])])))

(test
  test-cli-inline-harness-prunes-generated-wrappers
  (if (tltest-generated-reachability-self-test?)
    unit
    (panic "test CLI inline harness generated reachability mismatch")))

(define (tltest-imported-generated-retained-self-test?) : bool
  (let
    [dead-name : String "__tl_imported_generated_dead"]
    [ordinary-name : String "__tl_imported_ordinary_dead"]
    [dead-decl : AstDecl
      (tltest-generated-wrapper
        dead-name
        (ast-decl-def-fn
          dead-name
          AstParamList.Nil
          (AstType.Unit)
          (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))))]
    [ordinary-decl : AstDecl
      (ast-decl-def-fn
        ordinary-name
        AstParamList.Nil
        (AstType.Unit)
        (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))]
    [span : AstSourceSpan (AstSourceSpan 29 1 29 1)]
    [decls : AstDeclList
      (ast-decl-cons
        dead-decl
        (ast-decl-cons
          ordinary-decl
          (ast-decl-cons
            (ast-decl-test
              "keeps-imported-generated"
              (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))
              span)
            AstDeclList.Nil)))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "generated.tl"
        (ast-decl-path-cons
          "generated.tl"
          (ast-decl-path-cons "driver.tl" AstDeclPathList.Nil)))]
    (match (tltest-build-harness "driver.tl" decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 1)
                (tltest-decl-list-has-name? harness-decls dead-name)
                (not (tltest-decl-list-has-name? harness-decls ordinary-name))))])])))

(test
  test-cli-inline-harness-keeps-imported-generated-wrappers
  (if (tltest-imported-generated-retained-self-test?)
    unit
    (panic "test CLI inline harness pruned imported generated wrapper")))

(define (tltest-macro-quasiquote-deps-self-test?) : bool
  (let
    [helper-name : String "__tl_macro_generated_helper"]
    [macro-name : String "__tl_macro_generated_call"]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        helper-name
        AstParamList.Nil
        (AstType.Unit)
        (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))]
    [macro-decl : AstDecl
      (ast-decl-def-macro
        macro-name
        AstMacroParamList.Nil
        (AstType.Expr)
        (ast-expr-quasiquote (tltest-call-expr helper-name)))]
    [span : AstSourceSpan (AstSourceSpan 31 1 31 1)]
    [decls : AstDeclList
      (ast-decl-cons
        helper-decl
        (ast-decl-cons
          macro-decl
          (ast-decl-cons
            (ast-decl-test
              "uses-macro-generated-helper"
              (tltest-call-expr macro-name)
              span)
            AstDeclList.Nil)))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "macro-deps.tl"
        (ast-decl-path-cons
          "macro-deps.tl"
          (ast-decl-path-cons "macro-deps.tl" AstDeclPathList.Nil)))]
    (match (tltest-build-harness "macro-deps.tl" decls paths)
      [(InlineHarness.Harness program _ count)
        (match program
          [(AstProgram.Program harness-decls-box)
            (let
              [harness-decls : AstDeclList (box-get harness-decls-box)]
              (and
                (= count 1)
                (string.eq (tltest-decl-name-at harness-decls 0) helper-name)
                (string.eq (tltest-decl-name-at harness-decls 1) macro-name)
                (string.eq
                  (tltest-decl-name-at harness-decls 2)
                  "__tl_inline_test_0")
                (string.eq (tltest-decl-name-at harness-decls 3) "main")))])])))

(test
  test-cli-inline-harness-keeps-macro-quasiquote-deps
  (if (tltest-macro-quasiquote-deps-self-test?)
    unit
    (io.panic "test CLI inline harness dropped macro quasiquote dependency")))

(define (tltest-nested-module-macro-vector-source) : String
  "(import stdlib.vector)
(import stdlib.vector_slice)

(defstruct Pair
  (value i64))

(defmacro (slice-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append \"generated.slice_user.\" (type-key T)))]
    `(begin
      (module ,module-name)
      (import (vector ,T) as vec)
      (import (stdlib.vector_slice.slice ,T) as slice)
      (define (score [first : ,T] [fallback : ,T]) : i64
        (let
          [items : vec.Vec (vec.new)]
        (begin
          (vec.push (&mut items) first)
          (let
            [has-one : bool
              (let
                [view : (slice.Slice items) (slice.all-vec (& items))]
                (= (slice.len view) 1))]
            (if has-one
              (match (vec.pop (&mut items))
                [(vec.Pop.Ok _) 42]
                [(vec.Pop.Empty) 0])
              0))))))))

(import (slice-user i64) as user)
(import (slice-user Pair) as pair-user)

(test
  generated-module-body-imports-slice-module-macro-i64
  (begin
    (user.score 7 0)
    unit))

(test
  generated-module-body-imports-slice-module-macro-struct
  (begin
    (pair-user.score (Pair 7) (Pair 0))
    unit))

(cfg test
  (test
    generated-module-body-file-cfg-enabled
    unit))")

(define (tltest-nested-module-macro-vector-typecheck-ok?
  [program : AstProgram]
  [harness-paths : AstDeclPathList]
  [roots : vector.StringVec]
  [target : CompilerBackendTarget]) : bool
  (match (typecheck-compiler-program-with-paths-cache
    (tltest-program-with-print-runtime program target)
    (tltest-paths-with-print-runtime target harness-paths)
    roots
    (tltest-typecheck-cache-scope roots target))
    [(ResultCompilerTypecheck.Ok _) true]
    [(ResultCompilerTypecheck.Err diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        false)]))

(define (tltest-function-base-defined?
  [funcs : CompilerIrFunctionList]
  [base : String]) : bool
  (match funcs
    [(CompilerIrFunctionList.Nil) false]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function name _ _ _ _)
          (if (string.contains (& name) (& base))
            true
            (tltest-function-base-defined? (box-get rest) base))])]
    [(CompilerIrFunctionList.Array seq)
      (tltest-function-base-defined?
        (compiler-ir-function-seq-to-list seq)
        base)]))

(define (tltest-nested-module-macro-vector-lower-roots-ok?
  [source : String]
  [program : AstProgram]
  [harness-paths : AstDeclPathList]
  [roots : vector.StringVec]
  [target : CompilerBackendTarget]) : bool
  (match (lower-compiler-program-with-decl-paths-mode-cache
    source
    (tltest-program-with-print-runtime program target)
    (tltest-paths-with-print-runtime target harness-paths)
    (CompilerLowerMode.Scalar)
    roots
    (tltest-typecheck-cache-scope roots target))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (tltest-function-base-defined? functions "clone$Pair")])]
    [(ResultCompilerLower.Err _) false]))

(define (tltest-nested-module-macro-vector-loaded-ok?
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [roots : vector.StringVec]
  [target : CompilerBackendTarget]) : bool
  (match (tltest-build-harness source decls paths)
    [(InlineHarness.Harness program harness-paths count)
      (begin
        (unless (= count 3) (return false))
        (unless
          (tltest-nested-module-macro-vector-typecheck-ok?
            program
            harness-paths
            roots
            target)
          (begin
            (io.print-error
              "nested module macro vector fixture failed typecheck")
            (return false)))
        (unless
          (tltest-nested-module-macro-vector-lower-roots-ok?
            source
            program
            harness-paths
            roots
            target)
          (begin
            (io.print-error
              "nested module macro vector fixture did not emit clone$Pair")
            (return false)))
        true)]))

(define (tltest-nested-module-macro-vector-self-test?) : bool
  (match (source-tool-create-temp-dir "tltest-nested-module-macro-vector")
    [(ResultSourceToolString.Err _) false]
    [(ResultSourceToolString.Ok dir)
      (let
        [source : String (source-tool-fs-path-join dir "nested_vector.tl")]
        [roots : vector.StringVec (tltest-roots-for-self-test)]
        [target : CompilerBackendTarget (CompilerBackendTarget.Linux)]
        (begin
          (io.write-file source (tltest-nested-module-macro-vector-source))
          (match (compiler-driver-load-file-with-runtime
            source
            roots
            (tltest-cfgs target))
            [(ResultCompilerLoadWithPaths.Err _) false]
            [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
              (tltest-nested-module-macro-vector-loaded-ok?
                source
                decls
                paths
                roots
                target)])))]))

(test
  test-cli-inline-harness-nested-module-macro-vector-import
  (if (tltest-nested-module-macro-vector-self-test?)
    unit
    (io.panic "test CLI nested module macro vector import mismatch")))

(test
  test-cli-enables-test-cfg
  (cfg test unit (io.panic "test CLI did not enable test cfg")))

(define (tltest-cfgs [backend-target : CompilerBackendTarget]) : sym_i64_env.SymI64Env
  (compiler-cfg-enable
    (compiler-driver-target-cfgs backend-target (compiler-cfg-empty))
    "test"))

(define (tltest-roots-for-self-test) : vector.StringVec
  (vector.string-vec-push
    (vector.string-vec-push (vector.string-vec-new) "stdlib")
    "src"))

(define (tltest-package-cfg-inline-load-self-test?) : bool
  (match (source-tool-create-temp-dir "tltest-package-cfg")
    [(ResultSourceToolString.Err _) false]
    [(ResultSourceToolString.Ok dir)
      (let
        [source : String (source-tool-fs-path-join dir "cfg_inline.tl")]
        [roots : vector.StringVec (tltest-roots-for-self-test)]
        (begin
          (io.write-file source "(cfg test (test package-cfg-inline unit))\n")
          (match (compiler-driver-load-package-file-with-runtime-owned-cfg
            source
            roots
            "."
            "tltest"
            (compiler-pkg-deps-empty)
            true
            (tltest-cfgs (CompilerBackendTarget.Linux)))
            [(ResultCompilerLoadWithPaths.Err _) false]
            [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
              (let
                [owned-source : String
                  (compiler-load-package-owned-path "tltest" "." roots source)]
                (match (tltest-build-harness owned-source decls paths)
                  [(InlineHarness.Harness _ _ count) (= count 1)]))])))]))

(test
  test-cli-package-loader-enables-test-cfg
  (unless
    (tltest-package-cfg-inline-load-self-test?)
    (io.panic "test CLI package loader did not enable test cfg")))

(define (tltest-stdlib-io-string-helper-lower-self-test?) : bool
  (match (source-tool-create-temp-dir "tltest-stdlib-io-lower")
    [(ResultSourceToolString.Err _) false]
    [(ResultSourceToolString.Ok dir)
      (let
        [source : String (source-tool-fs-path-join dir "io_run.tl")]
        [roots : vector.StringVec (tltest-roots-for-self-test)]
        [target : CompilerBackendTarget (CompilerBackendTarget.Linux)]
        (begin
          (tltest-inline-reset-load-state!)
          (io.write-file
            source
            "(import \"stdlib/io.tl\")

(define (main) : i64
  (begin
    (let [text : String \"ok\"] (stdout-write (& text)))
    0))
")
          (match (compiler-driver-load-file-with-runtime
            source
            roots
            (tltest-cfgs target))
            [(ResultCompilerLoadWithPaths.Err diag)
              (begin
                (io.print-error (compiler-diagnostic-render (box-get diag)))
                false)]
            [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
              (match (lower-compiler-program-with-decl-paths-mode-cache
                source
                (ast-program decls)
                paths
                (CompilerLowerMode.Scalar)
                roots
                (tltest-typecheck-cache-scope roots target))
                [(ResultCompilerLower.Ok _ _) true]
                [(ResultCompilerLower.Err diag)
                  (begin
                    (io.print-error
                      (compiler-diagnostic-render
                        (tltest-diagnostic-with-source-fallback
                          source
                          (box-get diag))))
                    false)])])))]))

(test
  test-cli-stdlib-io-import-lowers-string-helper
  (unless
    (tltest-stdlib-io-string-helper-lower-self-test?)
    (io.panic "stdlib/io imported stdout-write failed to lower string helper")))

(define (tltest-typecheck-cache-scope
  [roots : vector.StringVec]
  [backend-target : CompilerBackendTarget]) : String
  (compiler-typecheck-prefix-cache-scope
    "typecheck-prefix-test-cli"
    roots
    (tltest-cfgs backend-target)))

(define (tltest-check-only
  [program : AstProgram]
  [paths : AstDeclPathList]
  [count : i64]
  [target : CompilerBackendTarget]
  [roots : vector.StringVec]) : i64
  (match (typecheck-compiler-program-with-paths-cache
    (tltest-program-with-print-runtime program target)
    (tltest-paths-with-print-runtime target paths)
    roots
    (tltest-typecheck-cache-scope roots target))
    [(ResultCompilerTypecheck.Ok _)
      (begin
        (io.print-string
          (string.append
            "TypeLisp test typecheck passed: "
            (string.append (string.int->string count) " test(s)\n")))
        0)]
    [(ResultCompilerTypecheck.Err diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]))

(define (tltest-stderr-ends-with-newline? [text : String]) : bool
  (let
    [n : i64 (string.string-length text)]
    (if (= n 0)
      true
      (let
        [last : char (string.string-ref text (- n 1))]
        (or (= last '\n') (= last '\r'))))))

(define (tltest-report-child-status [output : process.ProcessOutput]) : unit
  (begin
    (if (tltest-stderr-ends-with-newline? (process.output-stderr output))
      unit
      (io.print-error "\n"))
    (io.print-error
      (string.append
        "typelisp test: test executable exited with exit status: "
        (string.append (string.int->string (process.output-status output)) "\n")))))

(define (tltest-diagnostic-with-source-fallback
  [source : String]
  [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (if (= (string.string-length (compiler-diagnostic-path diag)) 0)
    (compiler-diagnostic-with-path diag source)
    diag))

(define (tltest-executable-spawn-detail [bin-path : String]) : String
  (match (source-tool-try-file-exists? bin-path)
    [(io.OkIoBool exists)
      (if exists
        "test executable exists; child-process spawn failed"
        "test executable is missing after link")]
    [(io.ErrIoBool error)
      (string.append
        "could not inspect test executable: "
        (io.error-message error))]))

(define (tltest-run-executable-error-message
  [bin-path : String]
  [temp-dir : String]
  [error : process.ProcessError]) : String
  (string.append
    (string.append
      (string.append
        (string.append "Error: failed to run test executable '" bin-path)
        (string.append "': " (process.error-message error)))
      (string.append " (" (tltest-executable-spawn-detail bin-path)))
    (string.append
      (string.append "); preserving test artifacts in '" temp-dir)
      "'\n")))

(define (tltest-run-executable-error-message-self-test?) : bool
  (let
    [bin-path : String "target/typelisp-missing-test-executable-2619.exe"]
    [temp-dir : String "target/typelisp-test-2619"]
    [message : String
      (tltest-run-executable-error-message
        bin-path
        temp-dir
        (process.ProcessSpawnFailed "process: spawn failed"))]
    [missing-detail : String "test executable is missing after link"]
    [preserve-detail : String
      "preserving test artifacts in 'target/typelisp-test-2619'"]
    (and
      (string.contains (& message) (& missing-detail))
      (string.contains (& message) (& preserve-detail)))))

(test
  test-cli-spawn-error-preserves-artifacts
  (unless
    (tltest-run-executable-error-message-self-test?)
    (io.panic "test CLI spawn error diagnostic did not preserve artifacts")))

(define (tltest-stdlib-env-fixture-source? [source : String]) : bool
  (let
    [normalized : String (compiler-load-normalize-path source)]
    (or
      (string.eq normalized "stdlib/env.tl")
      (string.eq normalized "stdlib/tests/env_api.tl"))))

(define (tltest-stdlib-env-fixture-path [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "one;two;three"
    "one:two:three"))

(define (tltest-stdlib-env-fixture-env [target : CompilerBackendTarget]) : process.ProcessEnvList
  (process.env-cons
    "TYPELISP_STDLIB_TEST_EMPTY"
    ""
    (process.env-cons
      "TYPELISP_STDLIB_TEST_VALUE"
      "env-value-854"
      (process.env-cons
        "TYPELISP_STDLIB_TEST_PATH"
        (tltest-stdlib-env-fixture-path target)
        (process.ProcessEnvNil)))))

(define (tltest-run-harness-output
  [source : String]
  [bin-path : String]
  [target : CompilerBackendTarget]) : process.ResultProcessOutput
  (if (tltest-stdlib-env-fixture-source? source)
    (process.output
      (source-tool-command-for-target
        target
        (process.command-with-env-list
          (process.command bin-path (process.args-empty))
          (tltest-stdlib-env-fixture-env target))))
    (source-tool-run-executable bin-path target (process.args-empty))))

(define (tltest-stdlib-env-fixture-self-test?) : bool
  (and
    (tltest-stdlib-env-fixture-source? "stdlib/env.tl")
    (tltest-stdlib-env-fixture-source? "stdlib\\env.tl")
    (tltest-stdlib-env-fixture-source? "stdlib/tests/env_api.tl")
    (tltest-stdlib-env-fixture-source? "stdlib\\tests\\env_api.tl")
    (not (tltest-stdlib-env-fixture-source? "stdlib/process.tl"))
    (string.eq
      (tltest-stdlib-env-fixture-path (CompilerBackendTarget.Windows))
      "one;two;three")
    (string.eq
      (tltest-stdlib-env-fixture-path (CompilerBackendTarget.Linux))
      "one:two:three")))

(test
  test-cli-stdlib-env-fixture-is-target-aware
  (unless
    (tltest-stdlib-env-fixture-self-test?)
    (io.panic "test CLI stdlib/env fixture routing mismatch")))

(define (tltest-run-harness-in-temp
  [source : String]
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [roots : vector.StringVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [temp-dir : String]) : i64
  (let
    [asm-path : String (source-tool-asm-path temp-dir source)]
    [obj-path : String (source-tool-obj-path temp-dir source target)]
    [bin-path : String (source-tool-temp-bin-path temp-dir source target)]
    (match (lower-compiler-program-with-decl-paths-mode-cache
      entry-path
      program
      paths
      (CompilerLowerMode.Scalar)
      roots
      (tltest-typecheck-cache-scope roots target))
      [(ResultCompilerLower.Ok ir spans)
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
          "test: failed to write assembly artifact")
          [(SourceToolCommandStatus.Err message)
            (begin
              (io.print-error message)
              (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
              1)]
          [(SourceToolCommandStatus.Ok)
            (begin
              (compiler-driver-reset-analysis-state!)
              (match (tltest-run-harness-output source bin-path target)
                [(process.OkProcessOutput output)
                  (let
                    [status : i64 (process.output-status output)]
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
                [(process.ErrProcessOutput error)
                  (begin
                    (io.print-error
                      (tltest-run-executable-error-message
                        bin-path
                        temp-dir
                        error))
                    1)]))])]
      [(ResultCompilerLower.Err diag)
        (begin
          (io.print-error
            (compiler-diagnostic-render
              (tltest-diagnostic-with-source-fallback source (box-get diag))))
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          1)])))

(define (tltest-run-direct-with-entry
  [source : String]
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [roots : vector.StringVec]
  [target : String]
  [opt-level : i64]) : i64
  (match (source-tool-target target)
    [(ResultSourceToolTarget.Err _)
      (begin
        (io.print-error (tltest-unknown-target target))
        1)]
    [(ResultSourceToolTarget.Ok backend-target)
      (match (source-tool-create-temp-dir "typelisp-test")
        [(ResultSourceToolString.Ok temp-dir)
          (tltest-run-harness-in-temp
            source
            entry-path
            (tltest-program-with-print-runtime program backend-target)
            (tltest-paths-with-print-runtime backend-target paths)
            roots
            backend-target
            opt-level
            temp-dir)]
        [(ResultSourceToolString.Err message)
          (begin
            (io.print-error
              (string.append "test: failed to create temp dir: " message))
            1)])]))

(define (tltest-run-direct
  [source : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [roots : vector.StringVec]
  [target : String]
  [opt-level : i64]) : i64
  (tltest-run-direct-with-entry
    source
    source
    program
    paths
    roots
    target
    opt-level))

(define (tltest-no-tests-check
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [roots : vector.StringVec]
  [target : CompilerBackendTarget]) : i64
  (match (typecheck-compiler-program-with-paths-cache
    (ast-program decls)
    paths
    roots
    (tltest-typecheck-cache-scope roots target))
    [(ResultCompilerTypecheck.Ok _)
      (begin
        (io.print-string "TypeLisp test typecheck passed: 0 test(s)\n")
        0)]
    [(ResultCompilerTypecheck.Err diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]))

(define (tltest-no-tests-run
  [source : String]
  [target : String]
  [_mode : String]
  [roots : vector.StringVec]
  [opt-level : i64]) : i64
  ;; With no inline tests there is no source harness to validate here. `test
  ;; --check` owns source typechecking; run mode only needs the zero-test runner.
  (tltest-run-direct
    source
    (ast-program (ast-decl-cons (tltest-empty-main-decl) AstDeclList.Nil))
    (ast-decl-path-cons source AstDeclPathList.Nil)
    roots
    target
    opt-level))

(define (tltest-source-prefix-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

(define (tltest-source-line-break? [c : char]) : bool
  (or (= c '\n') (= c '\r')))

(define (tltest-inline-marker-boundary? [source : String] [idx : i64] [n : i64]) : bool
  (if (>= idx n)
    true
    (let
      [c : char (string.string-ref source idx)]
      (or
        (tltest-source-prefix-space? c)
        (tltest-source-line-break? c)
        (= c ')')))))

(define (tltest-inline-marker-at? [source : String] [idx : i64] [n : i64]) : bool
  (and
    (<= (+ idx 5) n)
    (= (string.string-ref source idx) '(')
    (= (string.string-ref source (+ idx 1)) 't')
    (= (string.string-ref source (+ idx 2)) 'e')
    (= (string.string-ref source (+ idx 3)) 's')
    (= (string.string-ref source (+ idx 4)) 't')
    (tltest-inline-marker-boundary? source (+ idx 5) n)))

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
          [c : char (string.string-ref source i)]
          (cond
            [(and open (tltest-source-line-break? c))
              (begin
                (set! i (+ i 1))
                (set! open true))]
            [(and open (tltest-source-prefix-space? c))
              (begin
                (set! i (+ i 1))
                (set! open true))]
            [(and open (tltest-inline-marker-at? source i n)) (set! found true)]
            [(tltest-source-line-break? c)
              (begin
                (set! i (+ i 1))
                (set! open true))]
            [else
              (begin
                (set! i (+ i 1))
                (set! open false))])))
      found)))

(define (tltest-source-has-inline-tests? [source : String]) : bool
  (let
    [text : String (io.read-file source)]
    (tltest-source-has-inline-tests-from
      text
      0
      (string.string-length text)
      true)))

(define (tltest-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (> prefix-len text-len)
      false
      (string.eq (string.substring text 0 prefix-len) prefix))))

(define (tltest-package-tests-prefix [manifest-dir : String]) : String
  (string.append
    (compiler-load-normalize-path
      (package-source-root-join manifest-dir "tests"))
    "/"))

(define (tltest-package-test-source? [source : String] [tests-prefix : String]) : bool
  (tltest-string-prefix? (compiler-load-normalize-path source) tests-prefix))

(define (tltest-package-tests-subdir-prefix
  [tests-prefix : String]
  [name : String]) : String
  (string.append tests-prefix (string.append name "/")))

(define (tltest-package-manifest-managed-integration? [tests-prefix : String]) : bool
  (let
    [integration-prefix : String
      (tltest-package-tests-subdir-prefix tests-prefix "integration")]
    (or
      (io.file-exists?
        (string.append integration-prefix "native-linux.manifest"))
      (io.file-exists?
        (string.append integration-prefix "native-windows.manifest")))))

(define (tltest-package-manifest-managed-integration-source-with?
  [normalized : String]
  [tests-prefix : String]
  [manifest-managed : bool]) : bool
  (and
    manifest-managed
    (tltest-string-prefix?
      normalized
      (tltest-package-tests-subdir-prefix tests-prefix "integration"))))

(define (tltest-package-manifest-managed-integration-source?
  [normalized : String]
  [tests-prefix : String]) : bool
  (tltest-package-manifest-managed-integration-source-with?
    normalized
    tests-prefix
    (tltest-package-manifest-managed-integration? tests-prefix)))

(define (tltest-package-reserved-fixture-source?
  [source : String]
  [tests-prefix : String]) : bool
  (let
    [normalized : String (compiler-load-normalize-path source)]
    (or
      (tltest-package-manifest-managed-integration-source?
        normalized
        tests-prefix)
      (tltest-string-prefix?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "diagnostics"))
      (tltest-string-prefix?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "format_golden"))
      (tltest-string-prefix?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "golden"))
      (tltest-string-prefix?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "inline"))
      (tltest-string-prefix?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "no-libc"))
      (tltest-string-prefix?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "public-tools"))
      (tltest-string-prefix?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "safety"))
      (tltest-string-prefix?
        normalized
        (tltest-package-tests-subdir-prefix tests-prefix "spmd")))))

(define (tltest-package-integration-source?
  [source : String]
  [tests-prefix : String]) : bool
  (not (tltest-package-reserved-fixture-source? source tests-prefix)))

(define (tltest-package-integration-filter-self-test?) : bool
  (let
    [tests-prefix : String (tltest-package-tests-prefix "repo")]
    [integration-source : String
      (compiler-load-normalize-path "repo/tests/integration/hello.tl")]
    (and
      (tltest-package-manifest-managed-integration-source-with?
        integration-source
        tests-prefix
        true)
      (not
        (tltest-package-manifest-managed-integration-source-with?
          integration-source
          tests-prefix
          false))
      (not
        (tltest-package-integration-source?
          "repo/tests/diagnostics/backend/quote_runtime_value.tl"
          tests-prefix))
      (not
        (tltest-package-integration-source?
          "repo/tests/format_golden/char_literal.tl"
          tests-prefix))
      (not
        (tltest-package-integration-source?
          "repo/tests/golden/tl_emit_program.tl"
          tests-prefix))
      (not
        (tltest-package-integration-source?
          "repo/tests/inline/auto_discovery.tl"
          tests-prefix))
      (not
        (tltest-package-integration-source?
          "repo/tests/no-libc/probe.tl"
          tests-prefix))
      (not
        (tltest-package-integration-source?
          "repo/tests/public-tools/fixture.tl"
          tests-prefix))
      (not
        (tltest-package-integration-source?
          "repo/tests/safety/array_bounds_trap.tl"
          tests-prefix))
      (not
        (tltest-package-integration-source?
          "repo/tests/spmd/masked_if_i64.tl"
          tests-prefix))
      (tltest-package-integration-source?
        "repo/tests/integration/hello.tl"
        tests-prefix)
      (tltest-package-integration-source? "repo/tests/basic.tl" tests-prefix)
      (tltest-package-integration-source?
        "repo/tests/nested/more.tl"
        tests-prefix)
      (tltest-package-integration-source?
        "repo/tests/diagnostics_extra/example.tl"
        tests-prefix))))

(test
  test-cli-package-integration-skips-diagnostics-fixtures
  (if (tltest-package-integration-filter-self-test?)
    unit
    (io.panic "test CLI package integration filter mismatch")))

(define (tltest-decls-have-main? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclList.Nil) false]
    [(AstDeclList.Cons decl rest)
      (if (tltest-main-decl? decl)
        true
        (tltest-decls-have-main? (box-get rest)))]))

(define (tltest-package-source-line [source : String] [count : i64]) : String
  (string.append
    "TypeLisp test file: "
    (string.append
      source
      (string.append
        " ("
        (string.append (string.int->string count) " test(s))\n")))))

(define (tltest-package-summary-line
  [mode : TestMode]
  [file-count : i64]
  [test-count : i64]) : String
  (match mode
    [(TestMode.Check)
      (string.append
        "TypeLisp package test typecheck passed: "
        (string.append
          (string.int->string test-count)
          (string.append
            " test(s) in "
            (string.append (string.int->string file-count) " file(s)\n"))))]
    [(TestMode.Run)
      (string.append
        "TypeLisp package tests passed: "
        (string.append
          (string.int->string test-count)
          (string.append
            " test(s) in "
            (string.append (string.int->string file-count) " file(s)\n"))))]))

(define (tltest-package-run-one
  [source : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultTestPackageTotals
  (match (tltest-build-harness source decls paths)
    [(InlineHarness.Harness program harness-paths count)
      (if (= count 0)
        (begin
          (io.print-error
            (string.append
              "test: discovered inline test marker but no inline tests in "
              (string.append source "\n")))
          (ResultTestPackageTotals.Err 1))
        (begin
          (io.print-string (tltest-package-source-line source count))
          (let
            [status : i64
              (match test-mode
                [(TestMode.Check)
                  (tltest-check-only
                    program
                    harness-paths
                    count
                    backend-target
                    roots)]
                [(TestMode.Run)
                  (tltest-run-direct
                    source
                    program
                    harness-paths
                    roots
                    target
                    opt-level)])]
            (if (= status 0)
              (ResultTestPackageTotals.Ok 1 count)
              (ResultTestPackageTotals.Err status)))))]))

(define (tltest-package-integration-line [source : String]) : String
  (string.append "TypeLisp integration test file: " (string.append source "\n")))

(define (tltest-package-integration-missing-main [source : String]) : String
  (string.append
    "test: integration test file has no main: "
    (string.append source "\n")))

(define (tltest-package-integration-check
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [roots : vector.StringVec]
  [target : CompilerBackendTarget]) : ResultTestPackageTotals
  (begin
    (io.print-string (tltest-package-integration-line source))
    (if (tltest-decls-have-main? decls)
      (match (typecheck-compiler-program-with-paths-cache
        (ast-program decls)
        paths
        roots
        (tltest-typecheck-cache-scope roots target))
        [(ResultCompilerTypecheck.Ok _) (ResultTestPackageTotals.Ok 1 1)]
        [(ResultCompilerTypecheck.Err diag)
          (begin
            (io.print-error (compiler-diagnostic-render (box-get diag)))
            (ResultTestPackageTotals.Err 1))])
      (begin
        (io.print-error (tltest-package-integration-missing-main source))
        (ResultTestPackageTotals.Err 1)))))

(define (tltest-package-integration-run
  [source : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultTestPackageTotals
  (begin
    (io.print-string (tltest-package-integration-line source))
    (if (tltest-decls-have-main? decls)
      (let
        [status : i64
          (tltest-run-direct-with-entry
            source
            ""
            (ast-program decls)
            paths
            roots
            target
            opt-level)]
        (if (= status 0)
          (ResultTestPackageTotals.Ok 1 1)
          (ResultTestPackageTotals.Err status)))
      (begin
        (io.print-error (tltest-package-integration-missing-main source))
        (ResultTestPackageTotals.Err 1)))))

(define (tltest-package-run-integration-source
  [source : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]) : ResultTestPackageTotals
  (match (compiler-driver-load-package-file-with-runtime-owned-cfg
    source
    roots
    manifest-dir
    package-owner
    deps
    true
    (tltest-cfgs backend-target))
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (match test-mode
        [(TestMode.Check)
          (tltest-package-integration-check
            source
            decls
            paths
            roots
            backend-target)]
        [(TestMode.Run)
          (tltest-package-integration-run
            source
            target
            roots
            opt-level
            decls
            paths)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (io.print-error
          (string.append "test: integration test source failed: " source))
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        (ResultTestPackageTotals.Err 1))]))

(define (tltest-package-run-integration-source-isolated-count
  [source : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]) : i64
  (with-scratch
    (begin
      (compiler-driver-reset-file-state!)
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
        [(ResultTestPackageTotals.Err status) (- 0 status)]
        [(ResultTestPackageTotals.Ok _ tests) tests]))))

(define (tltest-package-run-source
  [source : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]) : ResultTestPackageTotals
  (if (tltest-source-has-inline-tests? source)
    (match (compiler-driver-load-package-file-with-runtime-owned-cfg
      source
      roots
      manifest-dir
      package-owner
      deps
      true
      (tltest-cfgs backend-target))
      [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (let
          [owned-source : String
            (compiler-load-package-owned-path
              package-owner
              manifest-dir
              roots
              source)]
          (tltest-package-run-one
            owned-source
            target
            roots
            opt-level
            test-mode
            backend-target
            decls
            paths))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (io.print-error
            (string.append "test: package source failed: " source))
          (io.print-error (compiler-diagnostic-render (box-get diag)))
          (ResultTestPackageTotals.Err 1))])
    (ResultTestPackageTotals.Ok 0 0)))

(define (tltest-package-run-source-isolated-count
  [source : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]) : i64
  (with-scratch
    (begin
      (compiler-driver-reset-file-state!)
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
        [(ResultTestPackageTotals.Err status) (- 0 status)]
        [(ResultTestPackageTotals.Ok _ tests) tests]))))

(define (tltest-package-run-sources-from
  [sources : PackageSourceList]
  [index : i64]
  [tests-prefix : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (if (>= index (package-source-list-len sources))
    (ResultTestPackageTotals.Ok file-count test-count)
    (let
      [source : String (package-source-list-get sources index "")]
      (if (tltest-package-test-source? source tests-prefix)
        (tltest-package-run-sources-from
          sources
          (+ index 1)
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
        (let
          [source-tests : i64
            (tltest-package-run-source-isolated-count
              source
              target
              roots
              opt-level
              test-mode
              backend-target
              manifest-dir
              package-owner
              deps)]
          (if (< source-tests 0)
            (ResultTestPackageTotals.Err (- 0 source-tests))
            (tltest-package-run-sources-from
              sources
              (+ index 1)
              tests-prefix
              target
              roots
              opt-level
              test-mode
              backend-target
              manifest-dir
              package-owner
              deps
              (if (= source-tests 0)
                file-count
                (+ file-count 1))
              (+ test-count source-tests))))))))

(define (tltest-package-run-sources
  [sources : PackageSourceList]
  [tests-prefix : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (tltest-package-run-sources-from
    sources
    0
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
    test-count))

(define (tltest-package-run-integration-sources-from
  [sources : PackageSourceList]
  [index : i64]
  [tests-prefix : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (if (>= index (package-source-list-len sources))
    (ResultTestPackageTotals.Ok file-count test-count)
    (let
      [source : String (package-source-list-get sources index "")]
      (if (tltest-package-integration-source? source tests-prefix)
        (let
          [source-tests : i64
            (tltest-package-run-integration-source-isolated-count
              source
              target
              roots
              opt-level
              test-mode
              backend-target
              manifest-dir
              package-owner
              deps)]
          (if (< source-tests 0)
            (ResultTestPackageTotals.Err (- 0 source-tests))
            (tltest-package-run-integration-sources-from
              sources
              (+ index 1)
              tests-prefix
              target
              roots
              opt-level
              test-mode
              backend-target
              manifest-dir
              package-owner
              deps
              (+ file-count 1)
              (+ test-count source-tests))))
        (tltest-package-run-integration-sources-from
          sources
          (+ index 1)
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
          test-count)))))

(define (tltest-package-run-integration-sources
  [sources : PackageSourceList]
  [tests-prefix : String]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]
  [backend-target : CompilerBackendTarget]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [file-count : i64]
  [test-count : i64]) : ResultTestPackageTotals
  (tltest-package-run-integration-sources-from
    sources
    0
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
    test-count))

(define (tltest-run-package
  [manifest-path : String]
  [has-manifest : bool]
  [target : String]
  [roots : vector.StringVec]
  [opt-level : i64]
  [test-mode : TestMode]) : i64
  (match (source-tool-target target)
    [(ResultSourceToolTarget.Err _)
      (begin
        (io.print-error (tltest-unknown-target target))
        1)]
    [(ResultSourceToolTarget.Ok backend-target)
      (match (package-source-discover-for "test" manifest-path has-manifest)
        [(ResultPackageSourceSet.Err message)
          (begin
            (io.print-error message)
            1)]
        [(ResultPackageSourceSet.Ok source-set)
          (let
            [manifest : CompilerPkgManifest (struct-get source-set manifest)]
            [manifest-dir : String (struct-get source-set manifest-dir)]
            [package-owner : String (struct-get manifest name)]
            [tests-prefix : String (tltest-package-tests-prefix manifest-dir)]
            (match (package-source-discover-tests-for "test" source-set)
              [(ResultPackageSourceList.Err message)
                (begin
                  (io.print-error message)
                  1)]
              [(ResultPackageSourceList.Ok integration-sources)
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
                  [(ResultTestPackageTotals.Err status) status]
                  [(ResultTestPackageTotals.Ok
                      inline-file-count
                      inline-test-count)
                    (match (tltest-package-run-integration-sources
                      integration-sources
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
                      [(ResultTestPackageTotals.Err status) status]
                      [(ResultTestPackageTotals.Ok
                          integration-file-count
                          integration-test-count)
                        (begin
                          (io.print-string
                            (tltest-package-summary-line
                              test-mode
                              (+ inline-file-count integration-file-count)
                              (+ inline-test-count integration-test-count)))
                          0)])])]))])]))

(define (tltest-check-file-loaded
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [backend-target : CompilerBackendTarget]
  [roots : vector.StringVec]) : ResultTestFileCheck
  (match (tltest-build-harness source decls paths)
    [(InlineHarness.Harness program harness-paths count)
      (begin
        (io.print-string (tltest-package-source-line source count))
        (let
          [status : i64
            (if (= count 0)
              (tltest-no-tests-check decls paths roots backend-target)
              (tltest-check-only
                program
                harness-paths
                count
                backend-target
                roots))]
          (if (= status 0)
            (ResultTestFileCheck.Ok count)
            (ResultTestFileCheck.Err status))))]))

(define (tltest-check-file-source
  [source : String]
  [roots : vector.StringVec]
  [backend-target : CompilerBackendTarget]) : ResultTestFileCheck
  (match (compiler-driver-load-file-with-runtime
    source
    roots
    (tltest-cfgs backend-target))
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (tltest-check-file-loaded source decls paths backend-target roots)]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        (ResultTestFileCheck.Err 1))]))

(define (tltest-batch-summary-line [file-count : i64] [test-count : i64]) : String
  (string.append
    "TypeLisp test batch typecheck passed: "
    (string.append
      (string.int->string test-count)
      (string.append
        " test(s) in "
        (string.append (string.int->string file-count) " file(s)\n")))))

(define (tltest-run-batch-check-path
  [source : String]
  [roots : vector.StringVec]
  [backend-target : CompilerBackendTarget]) : i64
  (with-scratch
    (begin
      (compiler-driver-reset-file-state!)
      (match (tltest-check-file-source source roots backend-target)
        [(ResultTestFileCheck.Err status) (- 0 status)]
        [(ResultTestFileCheck.Ok count) count]))))

(define (tltest-run-batch-check-paths-from
  [paths : vector.StringVec]
  [index : i64]
  [roots : vector.StringVec]
  [backend-target : CompilerBackendTarget]
  [file-count : i64]
  [test-count : i64]) : i64
  (let
    [count : i64 (vector.string-vec-len paths)]
    [cursor : i64 index]
    [files : i64 file-count]
    [tests : i64 test-count]
    [status : i64 0]
    (begin
      (while (and (= status 0) (< cursor count))
        (let
          [source : String (vector.string-vec-get paths cursor "")]
          ;; Match compile --batch: isolate each entry in a destroyable scratch
          ;; arena. Lexical arena rewind keeps overflow chunks retired until the
          ;; owning arena is destroyed (#2441), so destroying the entry arena is
          ;; required for long one-process batches to stay bounded.
          [entry-result : i64
            (tltest-run-batch-check-path source roots backend-target)]
          (if (< entry-result 0)
            (begin
              (io.print-error
                (string.append "test: batch source failed: " source))
              (io.print-error "\n")
              (set! status (- 0 entry-result)))
            (begin
              (set! files (+ files 1))
              (set! tests (+ tests entry-result))
              (set! cursor (+ cursor 1))))))
      (if (= status 0)
        (begin
          (io.print-string (tltest-batch-summary-line files tests))
          0)
        status))))

(define (tltest-run-batch-check-paths
  [paths : vector.StringVec]
  [roots : vector.StringVec]
  [backend-target : CompilerBackendTarget]
  [file-count : i64]
  [test-count : i64]) : i64
  (tltest-run-batch-check-paths-from
    paths
    0
    roots
    backend-target
    file-count
    test-count))

(define (tltest-run-batch-check
  [paths : vector.StringVec]
  [target : String]
  [roots : vector.StringVec]) : i64
  (begin
    (compiler-load-session-cache-enable!)
    (compiler-load-session-program-cache-disable!)
    (match (source-tool-target target)
      [(ResultSourceToolTarget.Err _)
        (begin
          (io.print-error (tltest-unknown-target target))
          1)]
      [(ResultSourceToolTarget.Ok backend-target)
        (let
          [status : i64
            (begin
              (if tltest-prefix-cache-stats
                (tc-prefix-snapshot-cache-clear!)
                unit)
              (tltest-run-batch-check-paths paths roots backend-target 0 0))]
          (begin
            (if tltest-prefix-cache-stats
              (tc-prefix-snapshot-cache-print-stats "test-check-batch")
              unit)
            status))])))

(define (tltest-run-config [config : TestConfig]) : i64
  (match config
    [(TestConfig.File source target mode roots opt-level test-mode)
      (match (source-tool-target target)
        [(ResultSourceToolTarget.Err _)
          (begin
            (io.print-error (tltest-unknown-target target))
            1)]
        [(ResultSourceToolTarget.Ok backend-target)
          (match (compiler-driver-load-file-with-runtime
            source
            roots
            (tltest-cfgs backend-target))
            [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
              (match (tltest-build-harness source decls paths)
                [(InlineHarness.Harness program harness-paths count)
                  (if (= count 0)
                    (match test-mode
                      [(TestMode.Check)
                        (tltest-no-tests-check decls paths roots backend-target)]
                      [(TestMode.Run)
                        (tltest-no-tests-run source target mode roots opt-level)])
                    (match test-mode
                      [(TestMode.Check)
                        (tltest-check-only
                          program
                          harness-paths
                          count
                          backend-target
                          roots)]
                      [(TestMode.Run)
                        (tltest-run-direct
                          source
                          program
                          harness-paths
                          roots
                          target
                          opt-level)]))])]
            [(ResultCompilerLoadWithPaths.Err diag)
              (begin
                (io.print-error (compiler-diagnostic-render (box-get diag)))
                1)])])]
    [(TestConfig.Batch paths target _ roots _ _)
      (tltest-run-batch-check paths target roots)]
    [(TestConfig.Package
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
    [(ResultTestConfig.Ok config) (tltest-run-config config)]
    [(ResultTestConfig.Err message)
      (begin
        (io.print-error message)
        1)]))