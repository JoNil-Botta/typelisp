;; build_cli_core.tl - Selfhost build command logic (#622, #1339).
;;
;; Source-file builds assemble and link in-process through stdlib fs/process
;; helpers. Package builds are handled in-process by the selfhost compiler:
;; parse/discover `typelisp.pkg`, emit assembly for the manifest entry, and
;; produce the package artifact selected by manifest kind.
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
    i64
    SourceToolLinkInputs))

(defenum ResultBuildCliConfig
  (OkBuildCliConfig BuildCliConfig)
  (ErrBuildCliConfig String))

(defenum ResultBuildTarget
  (OkBuildTarget CompilerBackendTarget)
  (ErrBuildTarget String))

(defenum ResultBuildManifest
  (OkBuildManifest CompilerPkgManifest)
  (ErrBuildManifest String))

(defenum ResultBuildLibs
  (OkBuildLibs ProcessStringList)
  (ErrBuildLibs String))

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
  (cond
    [(string-eq value "0") 0]
    [(string-eq value "1") 1]
    [(string-eq value "2") 2]
    [(string-eq value "3") 3]
    [else -1]))

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
    (begin
      (if has-source
        (begin
          (when
            has-manifest
            (return
              (ErrBuildConfig
                "build: cannot combine a source file with --manifest-path")))
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
        (begin
          (when
            has-output
            (return
              (ErrBuildConfig "build: -o requires a source file argument")))
          (OkBuildConfig
            (BuildPackageConfig
              manifest
              has-manifest
              target
              has-target
              mode
              has-opt-level
              opt-level
              stdlib-roots)))))
    (let
      [current : String (arg idx)]
      (cond
        [(string-eq current "-o")
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
                stdlib-roots)))]
        [(string-eq current "--manifest-path")
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
                stdlib-roots)))]
        [(string-eq current "--stdlib-root")
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
              (build-root-list-append stdlib-roots (arg (+ idx 1)))))]
        [(string-eq current "--target")
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
                (ErrBuildConfig (build-unknown-target value)))))]
        [(string-eq current "--backend-mode")
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
                (ErrBuildConfig (build-unknown-mode value)))))]
        [(string-eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ErrBuildConfig "build: --opt-level requires a value")
            (if has-opt-level
              (ErrBuildConfig "build: --opt-level was provided more than once")
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
                    stdlib-roots)))))]
        [(host-plan-flag? current)
          (ErrBuildConfig (string-append "build: unknown flag " current))]
        [has-source (ErrBuildConfig "build: accepts only one source file")]
        [else
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
            stdlib-roots)]))))

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

(define (build-package-asm-path [manifest-dir : String] [name : String]) : String
  (compiler-load-join-root-path
    (build-package-output-dir manifest-dir name)
    (string-append name ".s")))

(define (build-package-obj-path
  [manifest-dir : String]
  [name : String]
  [target : CompilerBackendTarget]) : String
  (compiler-load-join-root-path
    (build-package-output-dir manifest-dir name)
    (string-append
      name
      (string-append "." (source-tool-object-extension target)))))

(define (build-package-bin-path
  [manifest-dir : String]
  [name : String]
  [target : CompilerBackendTarget]) : String
  (compiler-load-join-root-path
    (build-package-output-dir manifest-dir name)
    (string-append name (source-tool-executable-extension target))))

(define (build-package-lib-path
  [manifest-dir : String]
  [name : String]
  [target : CompilerBackendTarget]) : String
  (compiler-load-join-root-path
    (build-package-output-dir manifest-dir name)
    (source-tool-static-library-filename name target)))

(define (build-package-artifact-path
  [manifest-dir : String]
  [name : String]
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]) : String
  (match kind
    [(CompilerPkgKindBin) (build-package-bin-path manifest-dir name target)]
    [(CompilerPkgKindLib) (build-package-lib-path manifest-dir name target)]))

(define (build-package-kind-lib? [kind : CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindLib) true]
    [_ false]))

(define (build-package-kind-entry? [kind : CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (build-package-dep-root [manifest-dir : String] [dep : CompilerPkgDep]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path manifest-dir (struct-get dep path))))

(define (build-package-dep-manifest-path
  [manifest-dir : String]
  [dep : CompilerPkgDep]) : String
  (compiler-load-join-root-path
    (build-package-dep-root manifest-dir dep)
    "typelisp.pkg"))

(define (build-package-dep-artifact
  [manifest-dir : String]
  [dep : CompilerPkgDep]
  [target : CompilerBackendTarget]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [stdlib-roots : CompilerLoadRootList]
  [fuel : i64]) : ResultBuildLibs
  (if (<= fuel 0)
    (ErrBuildLibs "build: dependency graph is too deep or cyclic")
    (let
      [dep-manifest-path : String
        (build-package-dep-manifest-path manifest-dir dep)]
      (match (build-load-manifest dep-manifest-path)
        [(ErrBuildManifest message)
          (ErrBuildLibs
            (string-append
              "dependency `"
              (string-append
                (struct-get dep alias)
                (string-append "`: " message))))]
        [(OkBuildManifest dep-manifest)
          (let
            [dep-kind : CompilerPkgKind (struct-get dep-manifest kind)]
            (if (not (build-package-kind-lib? dep-kind))
              (ErrBuildLibs
                (string-append
                  "build: dependency `"
                  (string-append
                    (struct-get dep alias)
                    "` must be a lib package")))
              (let
                [dep-dir : String (compiler-load-dirname dep-manifest-path)]
                [dep-name : String (struct-get dep-manifest name)]
                [dep-artifact : String
                  (build-package-artifact-path dep-dir dep-name dep-kind target)]
                [dep-status : i64
                  (build-package-emit-with-fuel
                    dep-manifest-path
                    dep-manifest
                    target-text
                    has-target
                    opt-level
                    stdlib-roots
                    (- fuel 1))]
                (if (= dep-status 0)
                  (OkBuildLibs (process-args-single dep-artifact))
                  (ErrBuildLibs
                    (string-append
                      "build: dependency `"
                      (string-append (struct-get dep alias) "` failed")))))))]))))

(define (build-package-deps-artifacts
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [target : CompilerBackendTarget]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [stdlib-roots : CompilerLoadRootList]
  [fuel : i64]) : ResultBuildLibs
  (match deps
    [(CompilerPkgDepNil) (OkBuildLibs (process-args-empty))]
    [(CompilerPkgDepCons dep rest)
      (match (build-package-dep-artifact
        manifest-dir
        dep
        target
        target-text
        has-target
        opt-level
        stdlib-roots
        fuel)
        [(ErrBuildLibs message) (ErrBuildLibs message)]
        [(OkBuildLibs dep-libs)
          (match (build-package-deps-artifacts
            manifest-dir
            rest
            target
            target-text
            has-target
            opt-level
            stdlib-roots
            fuel)
            [(ErrBuildLibs message) (ErrBuildLibs message)]
            [(OkBuildLibs rest-libs)
              (OkBuildLibs (process-args-append dep-libs rest-libs))])])]))

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

(define (build-package-artifact-status
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [dep-libs : ProcessStringList]) : SourceToolCommandStatus
  (match kind
    [(CompilerPkgKindBin)
      (source-tool-assemble-and-link
        target
        asm-path
        obj-path
        artifact-path
        (source-tool-link-inputs-from-archives dep-libs))]
    [(CompilerPkgKindLib)
      (source-tool-assemble-and-archive target asm-path obj-path artifact-path)]))

(define (build-package-emit-with-fuel
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [stdlib-roots : CompilerLoadRootList]
  [fuel : i64]) : i64
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
        [kind : CompilerPkgKind (struct-get manifest kind)]
        [asm-path : String (build-package-asm-path manifest-dir name)]
        [obj-path : String (build-package-obj-path manifest-dir name target)]
        [artifact-path : String
          (build-package-artifact-path manifest-dir name kind target)]
        (if (not (build-ensure-package-output-dirs manifest-dir name))
          (begin
            (print-error
              (string-append
                "build: failed to create package output directory "
                (build-package-output-dir manifest-dir name)))
            1)
          (match (build-package-deps-artifacts
            manifest-dir
            (struct-get manifest deps)
            target
            target-text
            has-target
            opt-level
            stdlib-roots
            fuel)
            [(ErrBuildLibs message)
              (begin
                (print-error message)
                1)]
            [(OkBuildLibs dep-libs)
              (match (source-tool-emit-package-assembly
                entry-path
                target
                stdlib-roots
                opt-level
                manifest-dir
                (struct-get manifest deps)
                (build-package-kind-entry? kind))
                [(ErrSourceToolString message)
                  (begin
                    (print-error message)
                    1)]
                [(OkSourceToolString asm)
                  (match (source-tool-write-file
                    asm-path
                    asm
                    "build: failed to write package assembly")
                    [(SourceToolCommandErr message)
                      (begin
                        (print-error message)
                        1)]
                    [(SourceToolCommandOk)
                      (match (build-package-artifact-status
                        kind
                        target
                        asm-path
                        obj-path
                        artifact-path
                        dep-libs)
                        [(SourceToolCommandErr message)
                          (begin
                            (print-error message)
                            1)]
                        [(SourceToolCommandOk)
                          (begin
                            (print-string
                              (string-append "Generated: " artifact-path))
                            0)])])])])))]))

(define (build-package-emit
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (build-package-emit-with-fuel
    manifest-path
    manifest
    target-text
    has-target
    opt-level
    stdlib-roots
    64))

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

(defenum BuildCliOption
  (BuildCliOptionOutput)
  (BuildCliOptionStdlibRoot)
  (BuildCliOptionTarget)
  (BuildCliOptionBackendMode)
  (BuildCliOptionOptLevel)
  (BuildCliOptionLinkLib)
  (BuildCliOptionLinkSearch)
  (BuildCliOptionLinkArg)
  (BuildCliOptionManifestPath)
  (BuildCliOptionOther))

(define (build-cli-option-rest6 [current : String]) : BuildCliOption
  (if (string-eq current "--link-arg")
    (BuildCliOptionLinkArg)
    (if (string-eq current "--manifest-path")
      (BuildCliOptionManifestPath)
      (BuildCliOptionOther))))

(define (build-cli-option-rest5 [current : String]) : BuildCliOption
  (if (string-eq current "--link-search")
    (BuildCliOptionLinkSearch)
    (build-cli-option-rest6 current)))

(define (build-cli-option-rest4 [current : String]) : BuildCliOption
  (if (string-eq current "--link-lib")
    (BuildCliOptionLinkLib)
    (build-cli-option-rest5 current)))

(define (build-cli-option-rest3 [current : String]) : BuildCliOption
  (if (string-eq current "--opt-level")
    (BuildCliOptionOptLevel)
    (build-cli-option-rest4 current)))

(define (build-cli-option-rest2 [current : String]) : BuildCliOption
  (if (string-eq current "--backend-mode")
    (BuildCliOptionBackendMode)
    (build-cli-option-rest3 current)))

(define (build-cli-option-rest1 [current : String]) : BuildCliOption
  (if (string-eq current "--target")
    (BuildCliOptionTarget)
    (build-cli-option-rest2 current)))

(define (build-cli-option-rest0 [current : String]) : BuildCliOption
  (if (string-eq current "--stdlib-root")
    (BuildCliOptionStdlibRoot)
    (build-cli-option-rest1 current)))

(define (build-cli-option [current : String]) : BuildCliOption
  (if (string-eq current "-o")
    (BuildCliOptionOutput)
    (build-cli-option-rest0 current)))

(define (build-args-have-source? [idx : i64] [count : i64]) : bool
  (if (>= idx count)
    false
    (let
      [current : String (arg idx)]
      (match (build-cli-option current)
        [(BuildCliOptionOther)
          (if (source-tool-flag? current)
            (build-args-have-source? (+ idx 1) count)
            true)]
        [_ (build-args-have-source? (+ idx 2) count)]))))

(define (build-cli-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]) : ResultBuildCliConfig
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
          opt-level
          link-inputs))
      (if has-output
        (ErrBuildCliConfig "build: -o requires a source file argument")
        (ErrBuildCliConfig "build: expected source path")))
    (let
      [current : String (arg idx)]
      (match (build-cli-option current)
        [(BuildCliOptionOutput)
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
                opt-level
                link-inputs)))]
        [(BuildCliOptionStdlibRoot)
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
              opt-level
              link-inputs))]
        [(BuildCliOptionTarget)
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
                    opt-level
                    link-inputs)]
                [(ErrSourceToolTarget _)
                  (ErrBuildCliConfig (build-cli-unknown-target value))])))]
        [(BuildCliOptionBackendMode)
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
                    opt-level
                    link-inputs)]
                [(ErrSourceToolBackendMode message) (ErrBuildCliConfig message)])))]
        [(BuildCliOptionOptLevel)
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
                  (string->int value)
                  link-inputs)
                (ErrBuildCliConfig (build-cli-unknown-opt-level value)))))]
        [(BuildCliOptionLinkLib)
          (if (>= (+ idx 1) count)
            (ErrBuildCliConfig "build: --link-lib requires a value")
            (build-cli-parse-options
              (+ idx 2)
              count
              source
              has-source
              output
              has-output
              target
              stdlib-roots
              opt-level
              (source-tool-link-inputs-add-lib link-inputs (arg (+ idx 1)))))]
        [(BuildCliOptionLinkSearch)
          (if (>= (+ idx 1) count)
            (ErrBuildCliConfig "build: --link-search requires a value")
            (build-cli-parse-options
              (+ idx 2)
              count
              source
              has-source
              output
              has-output
              target
              stdlib-roots
              opt-level
              (source-tool-link-inputs-add-search-dir
                link-inputs
                (arg (+ idx 1)))))]
        [(BuildCliOptionLinkArg)
          (if (>= (+ idx 1) count)
            (ErrBuildCliConfig "build: --link-arg requires a value")
            (build-cli-parse-options
              (+ idx 2)
              count
              source
              has-source
              output
              has-output
              target
              stdlib-roots
              opt-level
              (source-tool-link-inputs-add-raw-arg link-inputs (arg (+ idx 1)))))]
        [(BuildCliOptionManifestPath)
          (if (>= (+ idx 1) count)
            (ErrBuildCliConfig "build: --manifest-path requires a value")
            (ErrBuildCliConfig
              "build: --manifest-path is handled by Rust typelisp build; selfhost build tool expects a source file"))]
        [(BuildCliOptionOther)
          (if (source-tool-flag? current)
            (ErrBuildCliConfig (string-append "build: unknown flag " current))
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
                opt-level
                link-inputs)))]))))

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
    (compiler-optimize-default-level)
    (source-tool-link-inputs-empty)))

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
            opt-level
            link-inputs)
          (source-tool-build-source
            source
            output
            has-output
            target
            stdlib-roots
            opt-level
            link-inputs)])]
    [(ErrBuildCliConfig message)
      (begin
        (print-error message)
        1)]))

;; Build a source file directly. Manifest builds use the older package parser so
;; `typelisp build` can still discover `typelisp.pkg` from the working tree.
(define (build-source-direct-from [idx : i64] [count : i64]) : i64
  (match (build-cli-config-from idx count)
    [(OkBuildCliConfig config)
      (match config
        [(BuildCliConfig
            source
            _
            output
            has-output
            target
            stdlib-roots
            opt-level
            link-inputs)
          (source-tool-build-source
            source
            output
            has-output
            target
            stdlib-roots
            opt-level
            link-inputs)])]
    [(ErrBuildCliConfig message)
      (begin
        (print-error message)
        1)]))

(define (build-direct-from [start : i64] [count : i64]) : i64
  (if (or
    (build-args-contain-manifest? start count)
    (not (build-args-have-source? start count)))
    (build-main-from start)
    (build-source-direct-from start count)))

;; Run the `build` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name). `--direct` remains accepted as a
;; compatibility no-op; the bare form also builds in-process.
(define (build-run-from [start : i64] [count : i64]) : i64
  (if (and (> count start) (string-eq (arg start) "--direct"))
    (build-direct-from (+ start 1) count)
    (build-direct-from start count)))