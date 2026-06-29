;; check_cli_core.tl - Self-hosted `check` (typecheck) command logic.
;;
;; Factored out of `check.tl` so the unified `cli.tl` dispatcher and the
;; retained check compatibility/coverage driver share the command without a
;; duplicate `main`.
(import stdlib.io)
(import stdlib.vector)
(import "compiler_check_core.tl")
(import "doc_test.tl")
(import "package_source_core.tl")
(import "test_cli_core.tl")
(import stdlib.string)

(defenum SelfhostCheckConfig
  (File String vector.StringVec)
  (Package String bool vector.StringVec))

(defenum ResultSelfhostCheckConfig
  (Ok SelfhostCheckConfig)
  (Err String))

(define (selfhost-check-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (selfhost-check-config-finish
  [input-path : String]
  [has-input : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]) : ResultSelfhostCheckConfig
  (if has-input
    (if has-manifest
      (ResultSelfhostCheckConfig.Err
        "selfhost-check: cannot combine input path with --manifest-path")
      (ResultSelfhostCheckConfig.Ok
        (SelfhostCheckConfig.File input-path stdlib-roots)))
    (ResultSelfhostCheckConfig.Ok
      (SelfhostCheckConfig.Package manifest-path has-manifest stdlib-roots))))

(define (selfhost-check-parse-args
  [idx : i64]
  [count : i64]
  [input-path : String]
  [has-input : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]) : ResultSelfhostCheckConfig
  (if (>= idx count)
    (selfhost-check-config-finish
      input-path
      has-input
      manifest-path
      has-manifest
      stdlib-roots)
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultSelfhostCheckConfig.Err
              "selfhost-check: --stdlib-root requires a value")
            (selfhost-check-parse-args
              (+ idx 2)
              count
              input-path
              has-input
              manifest-path
              has-manifest
              (vector.string-vec-push stdlib-roots (io.arg (+ idx 1)))))]
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultSelfhostCheckConfig.Err
              "selfhost-check: --manifest-path requires a value")
            (if has-manifest
              (ResultSelfhostCheckConfig.Err
                "selfhost-check: duplicate --manifest-path")
              (selfhost-check-parse-args
                (+ idx 2)
                count
                input-path
                has-input
                (io.arg (+ idx 1))
                true
                stdlib-roots)))]
        [(selfhost-check-flag? current)
          (ResultSelfhostCheckConfig.Err
            (string.append "selfhost-check: unknown flag " current))]
        [has-input
          (ResultSelfhostCheckConfig.Err
            (string.append "selfhost-check: unexpected argument " current))]
        [else
          (selfhost-check-parse-args
            (+ idx 1)
            count
            current
            true
            manifest-path
            has-manifest
            stdlib-roots)]))))

;; Parse the `check` config from arguments starting at `start`. `count` is
;; `(arg-count)`.
(define (selfhost-check-config-from [start : i64] [count : i64]) : ResultSelfhostCheckConfig
  (selfhost-check-parse-args
    start
    count
    ""
    false
    ""
    false
    (vector.string-vec-new)))

(define (selfhost-check-doctest-report [report : DocTestRunReport]) : i64
  (if (doc-test-run-report-ok? report)
    0
    (begin
      (io.print-error (doc-test-run-report-render report))
      1)))

(define (selfhost-check-file-doctests
  [input-path : String]
  [stdlib-roots : vector.StringVec]) : i64
  (selfhost-check-doctest-report
    (doc-test-typecheck-file-with-roots input-path stdlib-roots)))

(define (selfhost-check-package-doctests
  [paths : AstDeclPathList]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : i64
  (selfhost-check-doctest-report
    (doc-test-typecheck-package-paths-with-roots
      paths
      stdlib-roots
      manifest-dir
      deps)))

(define (selfhost-check-file
  [input-path : String]
  [stdlib-roots : vector.StringVec]) : i64
  (match (compiler-check-file-with-roots input-path stdlib-roots)
    [(ResultCompilerCheck.Ok _)
      (let
        [inline-test-status : i64
          (tltest-inline-typecheck-file-with-cfg
            input-path
            stdlib-roots
            (compiler-check-language-cfgs)
            "typecheck-prefix-inline-check")]
        (if (= inline-test-status 0)
          (let
            [doctest-status : i64
              (selfhost-check-file-doctests input-path stdlib-roots)]
            (if (= doctest-status 0)
              (begin
                (io.print-string "Type checking passed!\n")
                0)
              doctest-status))
          inline-test-status))]
    [(ResultCompilerCheck.Err diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]))

(define (selfhost-check-package-kind-entry? [kind : CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (selfhost-check-package-entry-path
  [manifest-dir : String]
  [manifest : CompilerPkgManifest]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path manifest-dir (struct-get manifest entry))))

(define (selfhost-check-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]) : i64
  (match (package-source-discover-for "check" manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultPackageSourceSet.Ok source-set)
      (let
        [manifest : CompilerPkgManifest (struct-get source-set manifest)]
        [manifest-dir : String (struct-get source-set manifest-dir)]
        [name : String (struct-get manifest name)]
        [entry-path : String
          (selfhost-check-package-entry-path manifest-dir manifest)]
        [emit-entry : bool
          (selfhost-check-package-kind-entry? (struct-get manifest kind))]
        (match (compiler-check-package-entry-file-with-roots
          entry-path
          stdlib-roots
          manifest-dir
          (struct-get manifest deps)
          emit-entry)
          [(ResultCompilerCheckWithPaths.Ok _ paths)
            (let
              [inline-test-status : i64
                (tltest-inline-typecheck-package-sources-with-cfg
                  (struct-get source-set sources)
                  stdlib-roots
                  manifest-dir
                  name
                  (struct-get manifest deps)
                  (compiler-check-language-cfgs)
                  "typecheck-prefix-inline-check-package")]
              (if (= inline-test-status 0)
                (let
                  [doctest-status : i64
                    (selfhost-check-package-doctests
                      paths
                      stdlib-roots
                      manifest-dir
                      (struct-get manifest deps))]
                  (if (= doctest-status 0)
                    (begin
                      (io.print-string "Type checking passed!\n")
                      0)
                    doctest-status))
                inline-test-status))]
          [(ResultCompilerCheckWithPaths.Err diag)
            (begin
              (io.print-error (compiler-diagnostic-render (box-get diag)))
              1)]))]))

;; Run the `check` command over arguments starting at `start`.
(define (selfhost-check-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-check-config-from start count)
    [(ResultSelfhostCheckConfig.Ok config)
      (match config
        [(SelfhostCheckConfig.File input-path stdlib-roots)
          (selfhost-check-file input-path stdlib-roots)]
        [(SelfhostCheckConfig.Package manifest-path has-manifest stdlib-roots)
          (selfhost-check-package manifest-path has-manifest stdlib-roots)])]
    [(ResultSelfhostCheckConfig.Err message)
      (begin
        (io.print-error message)
        1)]))