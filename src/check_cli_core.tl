;; check_cli_core.tl - Self-hosted `check` (typecheck) command logic.
;;
;; Factored out of `check.tl` so the unified `cli.tl` dispatcher and the
;; retained check compatibility/coverage driver share the command without a
;; duplicate `main`.
(import "../stdlib/io.tl")
(import "../stdlib/vector.tl")
(import "compiler_check_core.tl")
(import "doc_test.tl")
(import "package_source_core.tl")
(import "../stdlib/string.tl")

(defenum SelfhostCheckConfig
  (SelfhostCheckFileConfig String StringVec)
  (SelfhostCheckPackageConfig String bool StringVec))

(defenum ResultSelfhostCheckConfig
  (OkSelfhostCheckConfig SelfhostCheckConfig)
  (ErrSelfhostCheckConfig String))

(define (selfhost-check-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (selfhost-check-config-finish
  [input-path : String]
  [has-input : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]) : ResultSelfhostCheckConfig
  (if has-input
    (if has-manifest
      (ErrSelfhostCheckConfig
        "selfhost-check: cannot combine input path with --manifest-path")
      (OkSelfhostCheckConfig (SelfhostCheckFileConfig input-path stdlib-roots)))
    (OkSelfhostCheckConfig
      (SelfhostCheckPackageConfig manifest-path has-manifest stdlib-roots))))

(define (selfhost-check-parse-args
  [idx : i64]
  [count : i64]
  [input-path : String]
  [has-input : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]) : ResultSelfhostCheckConfig
  (if (>= idx count)
    (selfhost-check-config-finish
      input-path
      has-input
      manifest-path
      has-manifest
      stdlib-roots)
    (let
      [current : String (arg idx)]
      (cond
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrSelfhostCheckConfig
              "selfhost-check: --stdlib-root requires a value")
            (selfhost-check-parse-args
              (+ idx 2)
              count
              input-path
              has-input
              manifest-path
              has-manifest
              (string-vec-push stdlib-roots (arg (+ idx 1)))))]
        [(string-eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ErrSelfhostCheckConfig
              "selfhost-check: --manifest-path requires a value")
            (if has-manifest
              (ErrSelfhostCheckConfig
                "selfhost-check: duplicate --manifest-path")
              (selfhost-check-parse-args
                (+ idx 2)
                count
                input-path
                has-input
                (arg (+ idx 1))
                true
                stdlib-roots)))]
        [(selfhost-check-flag? current)
          (ErrSelfhostCheckConfig
            (string-append "selfhost-check: unknown flag " current))]
        [has-input
          (ErrSelfhostCheckConfig
            (string-append "selfhost-check: unexpected argument " current))]
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
  (selfhost-check-parse-args start count "" false "" false (string-vec-new)))

(define (selfhost-check-doctest-report [report : DocTestRunReport]) : i64
  (if (doc-test-run-report-ok? report)
    0
    (begin
      (print-error (doc-test-run-report-render report))
      1)))

(define (selfhost-check-file-doctests
  [input-path : String]
  [stdlib-roots : StringVec]) : i64
  (selfhost-check-doctest-report
    (doc-test-typecheck-file-with-roots input-path stdlib-roots)))

(define (selfhost-check-package-doctests
  [paths : AstDeclPathList]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : i64
  (selfhost-check-doctest-report
    (doc-test-typecheck-package-paths-with-roots
      paths
      stdlib-roots
      manifest-dir
      deps)))

(define (selfhost-check-file [input-path : String] [stdlib-roots : StringVec]) : i64
  (match (compiler-check-file-with-roots input-path stdlib-roots)
    [(OkCompilerCheck _)
      (let
        [doctest-status : i64
          (selfhost-check-file-doctests input-path stdlib-roots)]
        (if (= doctest-status 0)
          (begin
            (print-string "Type checking passed!\n")
            0)
          doctest-status))]
    [(ErrCompilerCheck diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
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
  [stdlib-roots : StringVec]) : i64
  (match (package-source-resolve-manifest "check" manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (print-error message)
        1)]
    [(OkPackageSourceSet source-set)
      (let
        [manifest : CompilerPkgManifest (struct-get source-set manifest)]
        [manifest-dir : String (struct-get source-set manifest-dir)]
        [entry-path : String
          (selfhost-check-package-entry-path manifest-dir manifest)]
        (match (compiler-check-package-entry-file-with-roots
          entry-path
          stdlib-roots
          manifest-dir
          (struct-get manifest deps)
          (selfhost-check-package-kind-entry? (struct-get manifest kind)))
          [(OkCompilerCheckWithPaths _ paths)
            (let
              [doctest-status : i64
                (selfhost-check-package-doctests
                  paths
                  stdlib-roots
                  manifest-dir
                  (struct-get manifest deps))]
              (if (= doctest-status 0)
                (begin
                  (print-string "Type checking passed!\n")
                  0)
                doctest-status))]
          [(ErrCompilerCheckWithPaths diag)
            (begin
              (print-error (compiler-diagnostic-render diag))
              1)]))]))

;; Run the `check` command over arguments starting at `start`.
(define (selfhost-check-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-check-config-from start count)
    [(OkSelfhostCheckConfig config)
      (match config
        [(SelfhostCheckFileConfig input-path stdlib-roots)
          (selfhost-check-file input-path stdlib-roots)]
        [(SelfhostCheckPackageConfig manifest-path has-manifest stdlib-roots)
          (selfhost-check-package manifest-path has-manifest stdlib-roots)])]
    [(ErrSelfhostCheckConfig message)
      (begin
        (print-error message)
        1)]))