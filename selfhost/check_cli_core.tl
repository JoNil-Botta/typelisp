;; check_cli_core.tl - Self-hosted `check` (typecheck) command logic.
;;
;; Factored out of `check.tl` so the unified `cli.tl` dispatcher and the
;; retained check compatibility/coverage driver share the command without a
;; duplicate `main`.
(import "../stdlib/core_macros.tl" module stdlib.core-macros as core)

(import "../stdlib/io.tl")

(import "../stdlib/list.tl")

(import "compiler_check_core.tl")

(import "package_source_core.tl")

(import "../stdlib/string.tl")

(defenum SelfhostCheckConfig
  (SelfhostCheckFileConfig String StringVec)
  (SelfhostCheckPackageConfig String bool StringVec))

(defenum ResultSelfhostCheckConfig
  (OkSelfhostCheckConfig SelfhostCheckConfig)
  (ErrSelfhostCheckConfig String))

(define (selfhost-check-flag? [value : String]) : bool
  (core/and (> (string-length value) 0) (= (string-ref value 0) #-')))

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
      (core/cond
        (string-eq current "--stdlib-root")
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
            (string-vec-push stdlib-roots (arg (+ idx 1)))))
        (string-eq current "--manifest-path")
        (if (>= (+ idx 1) count)
          (ErrSelfhostCheckConfig
            "selfhost-check: --manifest-path requires a value")
          (if has-manifest
            (ErrSelfhostCheckConfig "selfhost-check: duplicate --manifest-path")
            (selfhost-check-parse-args
              (+ idx 2)
              count
              input-path
              has-input
              (arg (+ idx 1))
              true
              stdlib-roots)))
        (selfhost-check-flag? current)
        (ErrSelfhostCheckConfig
          (string-append "selfhost-check: unknown flag " current))
        has-input
        (ErrSelfhostCheckConfig
          (string-append "selfhost-check: unexpected argument " current))
        (selfhost-check-parse-args
          (+ idx 1)
          count
          current
          true
          manifest-path
          has-manifest
          stdlib-roots)))))

;; Parse the `check` config from arguments starting at `start`. `count` is
;; `(arg-count)`.
(define (selfhost-check-config-from [start : i64] [count : i64]) : ResultSelfhostCheckConfig
  (selfhost-check-parse-args start count "" false "" false (string-vec-new)))

(define (selfhost-check-file [input-path : String] [stdlib-roots : StringVec]) : i64
  (match (compiler-check-file-with-roots input-path stdlib-roots)
    [(OkCompilerCheck _)
      (begin
        (print-string "Type checking passed!\n")
        0)]
    [(ErrCompilerCheck diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (selfhost-check-package-source
  [input-path : String]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : i64
  (match (compiler-check-package-file-with-roots
    input-path
    stdlib-roots
    manifest-dir
    deps)
    [(OkCompilerCheck _) 0]
    [(ErrCompilerCheck diag)
      (begin
        (print-error
          (string-append "check: package source failed: " input-path))
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (selfhost-check-package-sources
  [sources : StringList]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : i64
  (match sources
    [(StringNil) 0]
    [(StringCons source rest)
      (let
        [status : i64
          (selfhost-check-package-source source stdlib-roots manifest-dir deps)]
        (if (= status 0)
          (selfhost-check-package-sources
            (box-get rest)
            stdlib-roots
            manifest-dir
            deps)
          status))]))

(define (selfhost-check-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]) : i64
  (match (package-source-discover manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (print-error message)
        1)]
    [(OkPackageSourceSet source-set)
      (let
        [manifest : CompilerPkgManifest (struct-get source-set manifest)]
        [status : i64
          (selfhost-check-package-sources
            (struct-get source-set sources)
            stdlib-roots
            (struct-get source-set manifest-dir)
            (struct-get manifest deps))]
        (if (= status 0)
          (begin
            (print-string "Type checking passed!\n")
            0)
          status))]))

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