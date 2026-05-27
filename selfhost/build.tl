;; build.tl - Selfhost build driver (#622, #1339).
;;
;; Source-file builds still emit a private `typelisp-host-plan v1` build-source
;; plan for Rust's `typelisp debug host-action` boundary. Package builds are
;; handled in-process by the selfhost compiler: parse/discover `typelisp.pkg`,
;; emit assembly for the manifest entry, and write target/typelisp/<name>/<name>.s.
;; `--direct` builds source files with stdlib fs/process helpers.
(import "host_plan.tl")

(import "build_run_core.tl")

(import "compiler_driver_core.tl")

(defenum BuildConfig
  (BuildSourceConfig String bool String bool String String String String)
  (BuildPackageConfig
    String
    bool
    String
    bool
    String
    bool
    i64
    CompilerLoadRootList))

(defenum ResultBuildConfig
  (OkBuildConfig BuildConfig)
  (ErrBuildConfig String))

(defenum BuildCliConfig
  (BuildCliConfig
    String
    bool
    String
    bool
    CompilerBackendTarget
    CompilerLoadRootList
    i64))

(defenum ResultBuildCliConfig
  (OkBuildCliConfig BuildCliConfig)
  (ErrBuildCliConfig String))

(defenum ResultBuildTarget
  (OkBuildTarget CompilerBackendTarget)
  (ErrBuildTarget String))

(defenum ResultBuildManifest
  (OkBuildManifest CompilerPkgManifest)
  (ErrBuildManifest String))

(define build-default-opt-level : i64
  2)

(define build-status-ok : i64
  0)

(define build-status-already-exists : i64
  17)

(define (build-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (build-unknown-target [value : String]) : String
  (build-cat3 "build: unknown target " value ""))

(define (build-unknown-mode [value : String]) : String
  (build-cat3 "build: unknown backend mode " value ""))

(define (build-unknown-opt-level [value : String]) : String
  (build-cat3 "build: unknown opt level '" value "'; expected 0, 1, 2, or 3"))

(define (build-append-stdlib [stdlib-lines : String] [root : String]) : String
  (string-append stdlib-lines (host-plan-netline "stdlib-root" root)))

(define (build-root-list-append [roots : CompilerLoadRootList] [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadRootCons root CompilerLoadRootNil)]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons head (build-root-list-append rest root))]))

(define (build-parse-target [value : String]) : ResultBuildTarget
  (if (or (string-eq value "linux-x86_64") (string-eq value "linux_x86_64"))
    (OkBuildTarget (BackendTargetLinux))
    (if (or
      (string-eq value "windows-x86_64")
      (string-eq value "windows_x86_64"))
      (OkBuildTarget (BackendTargetWindows))
      (ErrBuildTarget (build-unknown-target value)))))

(define (build-parse-opt-level [value : String]) : i64
  (if (string-eq value "0")
    0
    (if (string-eq value "1")
      1
      (if (string-eq value "2")
        2
        (if (string-eq value "3")
          3
          -1)))))

(define (build-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [output : String]
  [has-output : bool]
  [manifest : String]
  [has-manifest : bool]
  [target : String]
  [has-target : bool]
  [mode : String]
  [opt-level : i64]
  [has-opt-level : bool]
  [stdlib-lines : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultBuildConfig
  (if (>= idx count)
    (if has-source
      (if has-manifest
        (ErrBuildConfig
          "build: cannot combine a source file with --manifest-path")
        (OkBuildConfig
          (BuildSourceConfig
            source
            has-source
            output
            has-output
            target
            mode
            (if has-opt-level
              (int->string opt-level)
              "")
            stdlib-lines)))
      (if has-output
        (ErrBuildConfig "build: -o requires a source file argument")
        (OkBuildConfig
          (BuildPackageConfig
            manifest
            has-manifest
            target
            has-target
            mode
            has-opt-level
            opt-level
            stdlib-roots))))
    (let
      [current : String (arg idx)]
      (if (string-eq current "-o")
        (if (>= (+ idx 1) count)
          (ErrBuildConfig "build: -o requires a value")
          (if has-output
            (ErrBuildConfig "build: -o was provided more than once")
            (build-parse-options
              (+ idx 2)
              count
              source
              has-source
              (arg (+ idx 1))
              true
              manifest
              has-manifest
              target
              has-target
              mode
              opt-level
              has-opt-level
              stdlib-lines
              stdlib-roots)))
        (if (string-eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ErrBuildConfig "build: --manifest-path requires a value")
            (if has-manifest
              (ErrBuildConfig
                "build: --manifest-path was provided more than once")
              (build-parse-options
                (+ idx 2)
                count
                source
                has-source
                output
                has-output
                (arg (+ idx 1))
                true
                target
                has-target
                mode
                opt-level
                has-opt-level
                stdlib-lines
                stdlib-roots)))
          (if (string-eq current "--stdlib-root")
            (if (>= (+ idx 1) count)
              (ErrBuildConfig "build: --stdlib-root requires a value")
              (build-parse-options
                (+ idx 2)
                count
                source
                has-source
                output
                has-output
                manifest
                has-manifest
                target
                has-target
                mode
                opt-level
                has-opt-level
                (build-append-stdlib stdlib-lines (arg (+ idx 1)))
                (build-root-list-append stdlib-roots (arg (+ idx 1)))))
            (if (string-eq current "--target")
              (if (>= (+ idx 1) count)
                (ErrBuildConfig "build: --target requires a value")
                (let
                  [value : String (arg (+ idx 1))]
                  (if (host-plan-target-valid? value)
                    (build-parse-options
                      (+ idx 2)
                      count
                      source
                      has-source
                      output
                      has-output
                      manifest
                      has-manifest
                      value
                      true
                      mode
                      opt-level
                      has-opt-level
                      stdlib-lines
                      stdlib-roots)
                    (ErrBuildConfig (build-unknown-target value)))))
              (if (string-eq current "--backend-mode")
                (if (>= (+ idx 1) count)
                  (ErrBuildConfig "build: --backend-mode requires a value")
                  (let
                    [value : String (arg (+ idx 1))]
                    (if (host-plan-backend-mode-valid? value)
                      (build-parse-options
                        (+ idx 2)
                        count
                        source
                        has-source
                        output
                        has-output
                        manifest
                        has-manifest
                        target
                        has-target
                        value
                        opt-level
                        has-opt-level
                        stdlib-lines
                        stdlib-roots)
                      (ErrBuildConfig (build-unknown-mode value)))))
                (if (string-eq current "--opt-level")
                  (if (>= (+ idx 1) count)
                    (ErrBuildConfig "build: --opt-level requires a value")
                    (if has-opt-level
                      (ErrBuildConfig
                        "build: --opt-level was provided more than once")
                      (let
                        [value : String (arg (+ idx 1))]
                        [parsed : i64 (build-parse-opt-level value)]
                        (if (< parsed 0)
                          (ErrBuildConfig (build-unknown-opt-level value))
                          (build-parse-options
                            (+ idx 2)
                            count
                            source
                            has-source
                            output
                            has-output
                            manifest
                            has-manifest
                            target
                            has-target
                            mode
                            parsed
                            true
                            stdlib-lines
                            stdlib-roots)))))
                  (if (host-plan-flag? current)
                    (ErrBuildConfig
                      (string-append "build: unknown flag " current))
                    (if has-source
                      (ErrBuildConfig "build: accepts only one source file")
                      (build-parse-options
                        (+ idx 1)
                        count
                        current
                        true
                        output
                        has-output
                        manifest
                        has-manifest
                        target
                        has-target
                        mode
                        opt-level
                        has-opt-level
                        stdlib-lines
                        stdlib-roots))))))))))))

(define (build-config [count : i64]) : ResultBuildConfig
  (build-config-from 1 count))

(define (build-config-from [idx : i64] [count : i64]) : ResultBuildConfig
  (build-parse-options
    idx
    count
    ""
    false
    ""
    false
    ""
    false
    (host-plan-default-target)
    false
    "scalar"
    build-default-opt-level
    false
    ""
    CompilerLoadRootNil))

(define (build-source-plan-render [config : BuildConfig]) : String
  (match config
    [(BuildSourceConfig
        source
        _
        output
        has-output
        target
        mode
        opt-level
        stdlib-lines)
      (string-append
        (host-plan-header)
        (string-append
          (host-plan-word-line "action" "build-source")
          (string-append
            (host-plan-netline "source" source)
            (string-append
              (if has-output
                (host-plan-netline "output" output)
                "")
              (string-append
                (host-plan-word-line "target" target)
                (string-append
                  (host-plan-word-line "backend-mode" mode)
                  (string-append
                    (if (string-eq opt-level "")
                      ""
                      (host-plan-word-line "opt-level" opt-level))
                    (string-append stdlib-lines "end\n"))))))))]
    [_ ""]))

(define (build-discover-manifest-up [prefix : String] [fuel : i64]) : CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (string-append prefix "typelisp.pkg")]
      (if (file-exists? candidate)
        (CompilerLoadSomePath candidate)
        (build-discover-manifest-up (string-append prefix "../") (- fuel 1))))))

(define (build-load-manifest [manifest-path : String]) : ResultBuildManifest
  (if (file-exists? manifest-path)
    (match (compiler-load-parse-manifest (read-file manifest-path))
      [(OkCompilerPkgManifest manifest) (OkBuildManifest manifest)]
      [(ErrCompilerPkgManifest message)
        (ErrBuildManifest
          (build-cat3
            "invalid package manifest '"
            manifest-path
            (string-append "': " message)))])
    (ErrBuildManifest
      (build-cat3 "cannot read package manifest '" manifest-path "'"))))

(define (build-package-output-dir [manifest-dir : String] [name : String]) : String
  (compiler-load-join-root-path
    (compiler-load-join-root-path
      (compiler-load-join-root-path manifest-dir "target")
      "typelisp")
    name))

(define (build-package-output-path [manifest-dir : String] [name : String]) : String
  (compiler-load-join-root-path
    (build-package-output-dir manifest-dir name)
    (string-append name ".s")))

(define (build-mkdir-ok? [path : String]) : bool
  (let
    [status : i64 (fs-mkdir-status path)]
    (or (= status build-status-ok) (= status build-status-already-exists))))

(define (build-ensure-package-output-dirs
  [manifest-dir : String]
  [name : String]) : bool
  (let
    [target-dir : String (compiler-load-join-root-path manifest-dir "target")]
    [typelisp-dir : String (compiler-load-join-root-path target-dir "typelisp")]
    [package-dir : String (compiler-load-join-root-path typelisp-dir name)]
    (and
      (build-mkdir-ok? target-dir)
      (and (build-mkdir-ok? typelisp-dir) (build-mkdir-ok? package-dir)))))

(define (build-package-mode-ok? [mode : String]) : bool
  (string-eq mode "scalar"))

(define (build-package-mode-error [mode : String]) : String
  (build-cat3
    "build: --backend-mode "
    mode
    " requires the Rust build driver until selfhost SIMD support (#1014)"))

(define (build-package-emit
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (match (build-parse-target target-text)
    [(ErrBuildTarget message)
      (begin
        (print-error message)
        1)]
    [(OkBuildTarget target)
      (let
        [manifest-dir : String (compiler-load-dirname manifest-path)]
        [entry-path : String
          (compiler-load-join-root-path
            manifest-dir
            (struct-get manifest entry))]
        [name : String (struct-get manifest name)]
        [output-path : String (build-package-output-path manifest-dir name)]
        (if (not (build-ensure-package-output-dirs manifest-dir name))
          (begin
            (print-error
              (string-append
                "build: failed to create package output directory "
                (build-package-output-dir manifest-dir name)))
            1)
          (match (compiler-driver-emit-file-with-target-roots-and-level
            entry-path
            target
            has-target
            stdlib-roots
            opt-level)
            [(ErrCompilerDriver diag)
              (begin
                (print-error (compiler-diagnostic-render diag))
                1)]
            [(OkCompilerDriver asm)
              (begin
                (write-file output-path asm)
                (print-string (string-append "Generated: " output-path))
                0)])))]))

(define (build-package-from-path
  [manifest-path : String]
  [target-text : String]
  [has-target : bool]
  [mode : String]
  [opt-level : i64]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (if (not (build-package-mode-ok? mode))
    (begin
      (print-error (build-package-mode-error mode))
      1)
    (match (build-load-manifest manifest-path)
      [(ErrBuildManifest message)
        (begin
          (print-error (string-append "Error: " message))
          1)]
      [(OkBuildManifest manifest)
        (build-package-emit
          manifest-path
          manifest
          target-text
          has-target
          opt-level
          stdlib-roots)])))

(define (build-package [config : BuildConfig]) : i64
  (match config
    [(BuildPackageConfig
        manifest-path
        has-manifest
        target-text
        has-target
        mode
        _
        opt-level
        stdlib-roots)
      (let
        [resolved-manifest : CompilerLoadMaybePath
          (if has-manifest
            (CompilerLoadSomePath manifest-path)
            (build-discover-manifest-up "" 256))]
        (match resolved-manifest
          [(CompilerLoadNoPath)
            (begin
              (print-error
                "could not find typelisp.pkg from '.' or any parent directory")
              1)]
          [(CompilerLoadSomePath path)
            (build-package-from-path
              path
              target-text
              has-target
              mode
              opt-level
              stdlib-roots)]))]
    [_ 1]))

(define (build-main-from [idx : i64]) : i64
  (match (build-config-from idx (arg-count))
    [(OkBuildConfig config)
      (match config
        [(BuildSourceConfig _ _ _ _ _ _ _ _)
          (begin
            (print-string (build-source-plan-render config))
            0)]
        [(BuildPackageConfig _ _ _ _ _ _ _ _) (build-package config)])]
    [(ErrBuildConfig message)
      (begin
        (print-error message)
        1)]))

(define (build-args-contain-manifest? [idx : i64] [count : i64]) : bool
  (if (>= idx count)
    false
    (if (string-eq (arg idx) "--manifest-path")
      true
      (build-args-contain-manifest? (+ idx 1) count))))

(define (build-cli-unknown-target [value : String]) : String
  (source-tool-cat3 "build: unknown target " value ""))

(define (build-cli-unknown-opt-level [value : String]) : String
  (source-tool-cat3 "build: unknown opt level " value ""))

(define (build-cli-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultBuildCliConfig
  (if (>= idx count)
    (if has-source
      (OkBuildCliConfig
        (BuildCliConfig
          source
          has-source
          output
          has-output
          target
          stdlib-roots
          opt-level))
      (if has-output
        (ErrBuildCliConfig "build: -o requires a source file argument")
        (ErrBuildCliConfig "build: expected source path")))
    (let
      [current : String (arg idx)]
      (if (string-eq current "-o")
        (if (>= (+ idx 1) count)
          (ErrBuildCliConfig "build: -o requires a value")
          (if has-output
            (ErrBuildCliConfig "build: -o was provided more than once")
            (build-cli-parse-options
              (+ idx 2)
              count
              source
              has-source
              (arg (+ idx 1))
              true
              target
              stdlib-roots
              opt-level)))
        (if (string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrBuildCliConfig "build: --stdlib-root requires a value")
            (build-cli-parse-options
              (+ idx 2)
              count
              source
              has-source
              output
              has-output
              target
              (source-tool-root-list-append stdlib-roots (arg (+ idx 1)))
              opt-level))
          (if (string-eq current "--target")
            (if (>= (+ idx 1) count)
              (ErrBuildCliConfig "build: --target requires a value")
              (let
                [value : String (arg (+ idx 1))]
                (match (source-tool-target value)
                  [(OkSourceToolTarget parsed-target)
                    (build-cli-parse-options
                      (+ idx 2)
                      count
                      source
                      has-source
                      output
                      has-output
                      parsed-target
                      stdlib-roots
                      opt-level)]
                  [(ErrSourceToolTarget _)
                    (ErrBuildCliConfig (build-cli-unknown-target value))])))
            (if (string-eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ErrBuildCliConfig "build: --backend-mode requires a value")
                (let
                  [value : String (arg (+ idx 1))]
                  (match (source-tool-backend-mode "build" value)
                    [(OkSourceToolBackendMode)
                      (build-cli-parse-options
                        (+ idx 2)
                        count
                        source
                        has-source
                        output
                        has-output
                        target
                        stdlib-roots
                        opt-level)]
                    [(ErrSourceToolBackendMode message)
                      (ErrBuildCliConfig message)])))
              (if (string-eq current "--opt-level")
                (if (>= (+ idx 1) count)
                  (ErrBuildCliConfig "build: --opt-level requires a value")
                  (let
                    [value : String (arg (+ idx 1))]
                    (if (source-tool-opt-level-valid? value)
                      (build-cli-parse-options
                        (+ idx 2)
                        count
                        source
                        has-source
                        output
                        has-output
                        target
                        stdlib-roots
                        (string->int value))
                      (ErrBuildCliConfig (build-cli-unknown-opt-level value)))))
                (if (string-eq current "--manifest-path")
                  (if (>= (+ idx 1) count)
                    (ErrBuildCliConfig
                      "build: --manifest-path requires a value")
                    (ErrBuildCliConfig
                      "build: --manifest-path is handled by Rust typelisp build; selfhost build tool expects a source file"))
                  (if (source-tool-flag? current)
                    (ErrBuildCliConfig
                      (string-append "build: unknown flag " current))
                    (if has-source
                      (ErrBuildCliConfig "build: accepts only one source file")
                      (build-cli-parse-options
                        (+ idx 1)
                        count
                        current
                        true
                        output
                        has-output
                        target
                        stdlib-roots
                        opt-level))))))))))))

(define (build-cli-config [count : i64]) : ResultBuildCliConfig
  (build-cli-config-from 1 count))

(define (build-cli-config-from [idx : i64] [count : i64]) : ResultBuildCliConfig
  (build-cli-parse-options
    idx
    count
    ""
    false
    ""
    false
    (source-tool-default-target)
    CompilerLoadRootNil
    (compiler-optimize-default-level)))

(define (build-cli-main) : i64
  (match (build-cli-config (arg-count))
    [(OkBuildCliConfig config)
      (match config
        [(BuildCliConfig
            source
            _
            output
            has-output
            target
            stdlib-roots
            opt-level)
          (source-tool-build-source
            source
            output
            has-output
            target
            stdlib-roots
            opt-level)])]
    [(ErrBuildCliConfig message)
      (begin
        (print-error message)
        1)]))

(define (main) : i64
  (if (and (> (arg-count) 1) (string-eq (arg 1) "--direct"))
    (if (build-args-contain-manifest? 2 (arg-count))
      (build-main-from 2)
      (match (build-cli-config-from 2 (arg-count))
        [(OkBuildCliConfig config)
          (match config
            [(BuildCliConfig
                source
                _
                output
                has-output
                target
                stdlib-roots
                opt-level)
              (source-tool-build-source
                source
                output
                has-output
                target
                stdlib-roots
                opt-level)])]
        [(ErrBuildCliConfig message)
          (begin
            (print-error message)
            1)]))
    (if (and (> (arg-count) 1) (string-eq (arg 1) "--host-plan"))
      (build-main-from 2)
      (build-main-from 1))))