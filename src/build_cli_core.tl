;; build_cli_core.tl - Selfhost build command logic (#622, #1339).
;;
;; Source-file builds assemble and link in-process through stdlib fs/process
;; helpers. Package builds are handled in-process by the selfhost compiler:
;; parse/discover `typelisp.pkg`, emit assembly for the manifest entry, and
;; produce the package artifact selected by manifest kind.
(import "../stdlib/fs.tl")

(import "../stdlib/env.tl")

(import "../stdlib/io.tl")

(import "../stdlib/list.tl")

(import "../stdlib/string.tl")

(import "../stdlib/str_cat.tl")

(import "host_plan.tl")

(import "build_run_core.tl")

(import "doc_test.tl")

(import "package_source_core.tl")

(import "package_cache_core.tl")

(import "package_lock_core.tl")

(import "compiler_diagnostic.tl")

(import "compiler_driver_core.tl")

(import "tlci_core.tl")

(defenum BuildConfig
  (BuildSourceConfig String bool String bool String String String String)
  (BuildPackageConfig
    String
    bool
    String
    bool
    String
    BuildProfile
    bool
    i64
    BuildPackageLockPolicy
    StringVec))

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
    CompilerBackendMode
    StringVec
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

(defstruct BuildPackageGraphNode
  (manifest-path String)
  (manifest CompilerPkgManifest))

(defstruct BuildPackageGraphNodeVec
  (slots (Array BuildPackageGraphNode))
  (len i64))

(defstruct BuildPackageGraph
  (order BuildPackageGraphNodeVec))

(defstruct BuildPackageGraphState
  (seen StringI64Map)
  (order BuildPackageGraphNodeVec))

(defenum ResultBuildPackageGraph
  (OkBuildPackageGraph BuildPackageGraph)
  (ErrBuildPackageGraph String))

(defenum ResultBuildPackageGraphState
  (OkBuildPackageGraphState BuildPackageGraphState)
  (ErrBuildPackageGraphState String))

(defenum ResultBuildPackageGraphNode
  (OkBuildPackageGraphNode BuildPackageGraphNode)
  (ErrBuildPackageGraphNode String))

(defenum ResultBuildPkgDep
  (OkBuildPkgDep CompilerPkgDep)
  (ErrBuildPkgDep String))

(defenum ResultBuildPkgDepList
  (OkBuildPkgDepList CompilerPkgDepList)
  (ErrBuildPkgDepList String))

(defstruct BuildGitDependency
  (remote String)
  (pin-kind String)
  (pin-value String))

(defstruct BuildResolvedGitDependency
  (dep-root String)
  (lock-entry PackageLockEntry))

(defenum ResultBuildGitDependency
  (OkBuildGitDependency BuildGitDependency)
  (ErrBuildGitDependency String))

(defenum ResultBuildResolvedGitDependency
  (OkBuildResolvedGitDependency BuildResolvedGitDependency)
  (ErrBuildResolvedGitDependency String))

(defenum ResultBuildString
  (OkBuildString String)
  (ErrBuildString String))

(defenum BuildMaybeLockEntry
  (BuildNoLockEntry)
  (BuildSomeLockEntry PackageLockEntry))

(defstruct BuildPackageLockState
  (path String)
  (entries PackageLockEntryList)
  (has-lock bool))

(defenum ResultBuildPackageLockState
  (OkBuildPackageLockState BuildPackageLockState)
  (ErrBuildPackageLockState String))

(defstruct BuildResolvedPkgDep
  (dep CompilerPkgDep)
  (lock-entry BuildMaybeLockEntry))

(defenum ResultBuildResolvedPkgDep
  (OkBuildResolvedPkgDep BuildResolvedPkgDep)
  (ErrBuildResolvedPkgDep String))

(defstruct BuildResolvedPkgDeps
  (deps CompilerPkgDepList)
  (lock-entries PackageLockEntryList)
  (has-remote bool))

(defenum ResultBuildResolvedPkgDeps
  (OkBuildResolvedPkgDeps BuildResolvedPkgDeps)
  (ErrBuildResolvedPkgDeps String))

(defenum BuildPackagePathList
  (BuildPackagePathNil)
  (BuildPackagePathCons String (Box BuildPackagePathList)))

(defstruct BuildPackageWorkerConfig
  (manifest-path String)
  (has-manifest bool)
  (target CompilerBackendTarget)
  (mode CompilerBackendMode)
  (profile BuildProfile)
  (opt-level i64)
  (lock-policy BuildPackageLockPolicy)
  (stdlib-roots StringVec))

(defenum ResultBuildPackageWorkerConfig
  (OkBuildPackageWorkerConfig BuildPackageWorkerConfig)
  (ErrBuildPackageWorkerConfig String))

(defstruct BuildPackageGraphWorker
  (node BuildPackageGraphNode)
  (child ProcessChild))

(defenum ResultBuildPackageGraphWorker
  (OkBuildPackageGraphWorker BuildPackageGraphWorker)
  (ErrBuildPackageGraphWorker String))

(defstruct BuildPackageGraphWorkerVec
  (slots (Array BuildPackageGraphWorker))
  (len i64))

(defstruct BuildPackageSchedulePass
  (scheduled StringI64Map)
  (workers BuildPackageGraphWorkerVec))

(defenum ResultBuildPackageSchedulePass
  (OkBuildPackageSchedulePass BuildPackageSchedulePass)
  (ErrBuildPackageSchedulePass String))

(defenum ResultBuildPackageWait
  (OkBuildPackageWait StringI64Map)
  (ErrBuildPackageWait i64))

(defenum BuildProfile
  (BuildProfileDev)
  (BuildProfileRelease))

(defenum BuildPackageLockPolicy
  (BuildPackageLockDefault)
  (BuildPackageLockLocked)
  (BuildPackageLockUpdate))

(defenum BuildPackageLockEntryStatus
  (BuildPackageLockEntryMatched PackageLockEntry)
  (BuildPackageLockEntryMissing)
  (BuildPackageLockEntryStale))

(defenum ResultBuildProfile
  (OkBuildProfile BuildProfile)
  (ErrBuildProfile String))

(define build-default-opt-level : i64
  1)

(define build-package-release-opt-level : i64
  2)

(define build-package-visit-visiting : i64
  1)

(define build-package-visit-done : i64
  2)

(define build-status-ok : i64
  0)

(define build-status-already-exists : i64
  17)

(define (build-invalid-manifest-message [diag : CompilerDiagnostic]) : String
  (str-cat
    "invalid package manifest '"
    (compiler-diagnostic-path diag)
    (string-append "': " (compiler-diagnostic-message diag))))

(define (build-unknown-target [value : String]) : String
  (str-cat "build: unknown target " value ""))

(define (build-unknown-mode [value : String]) : String
  (str-cat "build: unknown backend mode " value ""))

(define (build-unknown-opt-level [value : String]) : String
  (str-cat "build: unknown opt level '" value "'; expected 0, 1, or 2"))

(define (build-unknown-profile [value : String]) : String
  (str-cat "build: unknown profile '" value "'; expected dev or release"))

(define (build-default-profile) : BuildProfile
  (BuildProfileRelease))

(define (build-profile-name [profile : BuildProfile]) : String
  (match profile
    [(BuildProfileDev) "dev"]
    [(BuildProfileRelease) "release"]))

(define (build-backend-mode-name [mode : CompilerBackendMode]) : String
  (match mode
    [(BackendModeScalar) "scalar"]
    [(BackendModeAvx2) "avx2"]
    [(BackendModeAvx512) "avx512"]))

(define (build-profile-default-opt-level [profile : BuildProfile]) : i64
  (match profile
    [(BuildProfileDev) 0]
    [(BuildProfileRelease) build-package-release-opt-level]))

(define (build-package-default-opt-level) : i64
  (build-profile-default-opt-level (build-default-profile)))

(define (build-package-profile-opt-level-smoke-ok?) : bool
  (and
    (= (build-profile-default-opt-level (BuildProfileRelease)) 2)
    (= (build-profile-default-opt-level (BuildProfileDev)) 0)
    (= (build-package-default-opt-level) 2)))

(test
  build-package-profile-opt-level-smoke
  (unless
    (build-package-profile-opt-level-smoke-ok?)
    (panic "build package profile opt-level smoke failed")))

(define (build-parse-profile [value : String]) : ResultBuildProfile
  (cond
    (string-eq value "dev")
    (OkBuildProfile (BuildProfileDev))
    (string-eq value "release")
    (OkBuildProfile (BuildProfileRelease))
    (ErrBuildProfile (build-unknown-profile value))))

(define (build-package-lock-policy-provided? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(BuildPackageLockDefault) false]
    [_ true]))

(define (build-package-lock-policy-locked? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(BuildPackageLockLocked) true]
    [_ false]))

(define (build-package-lock-policy-update? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(BuildPackageLockUpdate) true]
    [_ false]))

(define (build-package-lock-policy-option-error) : String
  "build: package lock policy was provided more than once")

(define (build-package-lock-policy-arg
  [args : ProcessStringList]
  [policy : BuildPackageLockPolicy]) : ProcessStringList
  (match policy
    [(BuildPackageLockLocked) (source-tool-args-append args "--locked")]
    [(BuildPackageLockUpdate) (source-tool-args-append args "--update-lock")]
    [(BuildPackageLockDefault) args]))

(define (build-append-stdlib [stdlib-lines : String] [root : String]) : String
  (string-append stdlib-lines (host-plan-netline "stdlib-root" root)))

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
    (string-eq value "0")
    0
    (string-eq value "1")
    1
    (string-eq value "2")
    2
    -1))

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
  [profile : BuildProfile]
  [has-profile : bool]
  [opt-level : i64]
  [has-opt-level : bool]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-lines : String]
  [stdlib-roots : StringVec]) : ResultBuildConfig
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
              profile
              has-opt-level
              (if has-opt-level
                opt-level
                (build-profile-default-opt-level profile))
              lock-policy
              stdlib-roots)))))
    (let
      [current : String (arg idx)]
      (cond
        (string-eq current "-o")
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
              profile
              has-profile
              opt-level
              has-opt-level
              lock-policy
              stdlib-lines
              stdlib-roots)))
        (string-eq current "--manifest-path")
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
              profile
              has-profile
              opt-level
              has-opt-level
              lock-policy
              stdlib-lines
              stdlib-roots)))
        (string-eq current "--stdlib-root")
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
            profile
            has-profile
            opt-level
            has-opt-level
            lock-policy
            (build-append-stdlib stdlib-lines (arg (+ idx 1)))
            (string-vec-push stdlib-roots (arg (+ idx 1)))))
        (string-eq current "--target")
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
                profile
                has-profile
                opt-level
                has-opt-level
                lock-policy
                stdlib-lines
                stdlib-roots)
              (ErrBuildConfig (build-unknown-target value)))))
        (string-eq current "--backend-mode")
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
                profile
                has-profile
                opt-level
                has-opt-level
                lock-policy
                stdlib-lines
                stdlib-roots)
              (ErrBuildConfig (build-unknown-mode value)))))
        (string-eq current "--profile")
        (if (>= (+ idx 1) count)
          (ErrBuildConfig "build: --profile requires a value")
          (if has-profile
            (ErrBuildConfig "build: profile was provided more than once")
            (match (build-parse-profile (arg (+ idx 1)))
              [(ErrBuildProfile message) (ErrBuildConfig message)]
              [(OkBuildProfile parsed-profile)
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
                  parsed-profile
                  true
                  opt-level
                  has-opt-level
                  lock-policy
                  stdlib-lines
                  stdlib-roots)])))
        (string-eq current "--release")
        (if has-profile
          (ErrBuildConfig "build: profile was provided more than once")
          (build-parse-options
            (+ idx 1)
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
            (BuildProfileRelease)
            true
            opt-level
            has-opt-level
            lock-policy
            stdlib-lines
            stdlib-roots))
        (string-eq current "--opt-level")
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
                  profile
                  has-profile
                  parsed
                  true
                  lock-policy
                  stdlib-lines
                  stdlib-roots)))))
        (string-eq current "--locked")
        (if (build-package-lock-policy-provided? lock-policy)
          (ErrBuildConfig (build-package-lock-policy-option-error))
          (build-parse-options
            (+ idx 1)
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
            profile
            has-profile
            opt-level
            has-opt-level
            (BuildPackageLockLocked)
            stdlib-lines
            stdlib-roots))
        (string-eq current "--update-lock")
        (if (build-package-lock-policy-provided? lock-policy)
          (ErrBuildConfig (build-package-lock-policy-option-error))
          (build-parse-options
            (+ idx 1)
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
            profile
            has-profile
            opt-level
            has-opt-level
            (BuildPackageLockUpdate)
            stdlib-lines
            stdlib-roots))
        (host-plan-flag? current)
        (ErrBuildConfig (string-append "build: unknown flag " current))
        has-source
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
          profile
          has-profile
          opt-level
          has-opt-level
          lock-policy
          stdlib-lines
          stdlib-roots)))))

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
    (build-default-profile)
    false
    (build-package-default-opt-level)
    false
    (BuildPackageLockDefault)
    ""
    (string-vec-new)))

(define (build-package-worker-parse-options
  [idx : i64]
  [count : i64]
  [manifest-path : String]
  [has-manifest : bool]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [profile : BuildProfile]
  [opt-level : i64]
  [has-opt-level : bool]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : ResultBuildPackageWorkerConfig
  (if (>= idx count)
    (if has-manifest
      (OkBuildPackageWorkerConfig
        (BuildPackageWorkerConfig
          manifest-path
          has-manifest
          target
          mode
          profile
          opt-level
          lock-policy
          stdlib-roots))
      (ErrBuildPackageWorkerConfig
        "build: --package-worker requires --manifest-path"))
    (let
      [current : String (arg idx)]
      (cond
        (string-eq current "--manifest-path")
        (if (>= (+ idx 1) count)
          (ErrBuildPackageWorkerConfig
            "build: --manifest-path requires a value")
          (build-package-worker-parse-options
            (+ idx 2)
            count
            (arg (+ idx 1))
            true
            target
            mode
            profile
            opt-level
            has-opt-level
            lock-policy
            stdlib-roots))
        (string-eq current "--target")
        (if (>= (+ idx 1) count)
          (ErrBuildPackageWorkerConfig "build: --target requires a value")
          (let
            [value : String (arg (+ idx 1))]
            (match (source-tool-target value)
              [(OkSourceToolTarget parsed-target)
                (build-package-worker-parse-options
                  (+ idx 2)
                  count
                  manifest-path
                  has-manifest
                  parsed-target
                  mode
                  profile
                  opt-level
                  has-opt-level
                  lock-policy
                  stdlib-roots)]
              [(ErrSourceToolTarget _)
                (ErrBuildPackageWorkerConfig (build-cli-unknown-target value))])))
        (string-eq current "--backend-mode")
        (if (>= (+ idx 1) count)
          (ErrBuildPackageWorkerConfig "build: --backend-mode requires a value")
          (let
            [value : String (arg (+ idx 1))]
            (match (source-tool-backend-mode "build" value)
              [(OkSourceToolBackendMode parsed-mode)
                (build-package-worker-parse-options
                  (+ idx 2)
                  count
                  manifest-path
                  has-manifest
                  target
                  parsed-mode
                  profile
                  opt-level
                  has-opt-level
                  lock-policy
                  stdlib-roots)]
              [(ErrSourceToolBackendMode message)
                (ErrBuildPackageWorkerConfig message)])))
        (string-eq current "--profile")
        (if (>= (+ idx 1) count)
          (ErrBuildPackageWorkerConfig "build: --profile requires a value")
          (match (build-parse-profile (arg (+ idx 1)))
            [(ErrBuildProfile message) (ErrBuildPackageWorkerConfig message)]
            [(OkBuildProfile parsed-profile)
              (let
                [next-opt-level : i64
                  (if has-opt-level
                    opt-level
                    (build-profile-default-opt-level parsed-profile))]
                (build-package-worker-parse-options
                  (+ idx 2)
                  count
                  manifest-path
                  has-manifest
                  target
                  mode
                  parsed-profile
                  next-opt-level
                  has-opt-level
                  lock-policy
                  stdlib-roots))]))
        (string-eq current "--release")
        (build-package-worker-parse-options
          (+ idx 1)
          count
          manifest-path
          has-manifest
          target
          mode
          (BuildProfileRelease)
          (if has-opt-level
            opt-level
            (build-profile-default-opt-level (BuildProfileRelease)))
          has-opt-level
          lock-policy
          stdlib-roots)
        (string-eq current "--opt-level")
        (if (>= (+ idx 1) count)
          (ErrBuildPackageWorkerConfig "build: --opt-level requires a value")
          (let
            [value : String (arg (+ idx 1))]
            (if (source-tool-opt-level-valid? value)
              (build-package-worker-parse-options
                (+ idx 2)
                count
                manifest-path
                has-manifest
                target
                mode
                profile
                (string->int value)
                true
                lock-policy
                stdlib-roots)
              (ErrBuildPackageWorkerConfig (build-unknown-opt-level value)))))
        (string-eq current "--locked")
        (if (build-package-lock-policy-provided? lock-policy)
          (ErrBuildPackageWorkerConfig (build-package-lock-policy-option-error))
          (build-package-worker-parse-options
            (+ idx 1)
            count
            manifest-path
            has-manifest
            target
            mode
            profile
            opt-level
            has-opt-level
            (BuildPackageLockLocked)
            stdlib-roots))
        (string-eq current "--update-lock")
        (if (build-package-lock-policy-provided? lock-policy)
          (ErrBuildPackageWorkerConfig (build-package-lock-policy-option-error))
          (build-package-worker-parse-options
            (+ idx 1)
            count
            manifest-path
            has-manifest
            target
            mode
            profile
            opt-level
            has-opt-level
            (BuildPackageLockUpdate)
            stdlib-roots))
        (string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ErrBuildPackageWorkerConfig "build: --stdlib-root requires a value")
          (build-package-worker-parse-options
            (+ idx 2)
            count
            manifest-path
            has-manifest
            target
            mode
            profile
            opt-level
            has-opt-level
            lock-policy
            (string-vec-push stdlib-roots (arg (+ idx 1)))))
        (host-plan-flag? current)
        (ErrBuildPackageWorkerConfig
          (string-append "build: unknown package worker flag " current))
        (ErrBuildPackageWorkerConfig
          (string-append "build: unexpected package worker argument " current))))))

(define (build-package-worker-config-from [idx : i64] [count : i64]) : ResultBuildPackageWorkerConfig
  (build-package-worker-parse-options
    idx
    count
    ""
    false
    (source-tool-default-target)
    (BackendModeScalar)
    (build-default-profile)
    (build-package-default-opt-level)
    false
    (BuildPackageLockDefault)
    (string-vec-new)))

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
    (match (compiler-load-parse-manifest-diagnostic-infer-kind
      manifest-path
      (read-file manifest-path))
      [(OkCompilerPkgManifestDiagnostic manifest) (OkBuildManifest manifest)]
      [(ErrCompilerPkgManifestDiagnostic diag)
        (ErrBuildManifest (build-invalid-manifest-message diag))])
    (ErrBuildManifest
      (str-cat "cannot read package manifest '" manifest-path "'"))))

(define (build-package-output-dir [manifest-dir : String] [name : String]) : String
  (build-package-output-dir-profile manifest-dir name (build-default-profile)))

(define (build-package-output-dir-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : String
  (compiler-load-join-root-path
    (compiler-load-join-root-path manifest-dir "target")
    (build-profile-name profile)))

(define (build-package-asm-path [manifest-dir : String] [name : String]) : String
  (build-package-asm-path-profile manifest-dir name (build-default-profile)))

(define (build-package-asm-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : String
  (compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir name profile)
    (string-append name ".s")))

(define (build-package-obj-path
  [manifest-dir : String]
  [name : String]
  [target : CompilerBackendTarget]) : String
  (build-package-obj-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-obj-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : String
  (compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir name profile)
    (string-append
      name
      (string-append "." (source-tool-object-extension target)))))

(define (build-package-bin-path
  [manifest-dir : String]
  [name : String]
  [target : CompilerBackendTarget]) : String
  (build-package-bin-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-bin-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : String
  (compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir name profile)
    (string-append name (source-tool-executable-extension target))))

(define (build-package-lib-path
  [manifest-dir : String]
  [name : String]
  [target : CompilerBackendTarget]) : String
  (build-package-lib-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-lib-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : String
  (compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir name profile)
    (source-tool-static-library-filename name target)))

(define (build-package-tlci-path [manifest-dir : String] [name : String]) : String
  (build-package-tlci-path-profile manifest-dir name (build-default-profile)))

(define (build-package-tlci-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : String
  (compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir name profile)
    (string-append name ".tlci")))

(define (build-package-artifact-path
  [manifest-dir : String]
  [name : String]
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]) : String
  (build-package-artifact-path-profile
    manifest-dir
    name
    kind
    (build-default-profile)
    target))

(define (build-package-artifact-path-profile
  [manifest-dir : String]
  [name : String]
  [kind : CompilerPkgKind]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : String
  (match kind
    [(CompilerPkgKindBin)
      (build-package-bin-path-profile manifest-dir name profile target)]
    [(CompilerPkgKindLib)
      (build-package-lib-path-profile manifest-dir name profile target)]))

(define (build-package-path-layout-smoke-ok?) : bool
  (and
    (string-eq
      (build-package-output-dir-profile "root/app" "pkg" (BuildProfileRelease))
      "root/app/target/release")
    (string-eq
      (build-package-asm-path-profile "root/app" "pkg" (BuildProfileDev))
      "root/app/target/dev/pkg.s")
    (string-eq
      (build-package-bin-path-profile
        "root/app"
        "pkg"
        (BuildProfileRelease)
        (BackendTargetWindows))
      "root/app/target/release/pkg.exe")
    (string-eq
      (build-package-lib-path-profile
        "root/app"
        "pkg"
        (BuildProfileRelease)
        (BackendTargetLinux))
      "root/app/target/release/libpkg.a")
    (string-eq
      (build-package-tlci-path-profile "root/app" "pkg" (BuildProfileDev))
      "root/app/target/dev/pkg.tlci")))

(test
  build-package-path-layout-smoke
  (unless
    (build-package-path-layout-smoke-ok?)
    (panic "build package path layout smoke failed")))

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
  (compiler-load-normalize-path
    (compiler-load-join-root-path
      (build-package-dep-root manifest-dir dep)
      "typelisp.pkg")))

(define (build-string-index-from
  [s : String]
  [needle : char]
  [i : i64]
  [n : i64]) : i64
  (if (>= i n)
    -1
    (if (= (string-ref s i) needle)
      i
      (build-string-index-from s needle (+ i 1) n))))

(define (build-github-dep-relative-root [alias : String]) : String
  (compiler-load-join-root-path
    (compiler-load-join-root-path
      (compiler-load-join-root-path "target" "typelisp")
      "git-deps")
    alias))

(define (build-github-dep-cache-root [manifest-dir : String] [alias : String]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path
      manifest-dir
      (build-github-dep-relative-root alias))))

(define (build-github-dep-cache-manifest-path
  [manifest-dir : String]
  [alias : String]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path
      (build-github-dep-cache-root manifest-dir alias)
      "typelisp.pkg")))

(define (build-git-dep-error [alias : String] [message : String]) : String
  (string-append
    "build: GitHub dependency `"
    (string-append alias (string-append "` " message))))

(define (build-parse-git-dependency [alias : String] [path : String]) : ResultBuildGitDependency
  (let
    [n : i64 (string-length path)]
    [hash : i64 (build-string-index-from path ##' 0 n)]
    (if (<= hash 0)
      (ErrBuildGitDependency
        (build-git-dep-error alias "has invalid normalized path"))
      (let
        [remote : String (substring path 0 hash)]
        [pin : String (substring path (+ hash 1) (- n (+ hash 1)))]
        [pin-len : i64 (string-length pin)]
        [eq : i64 (build-string-index-from pin #=' 0 pin-len)]
        (if (<= eq 0)
          (ErrBuildGitDependency (build-git-dep-error alias "has invalid pin"))
          (let
            [kind : String (substring pin 0 eq)]
            [value : String (substring pin (+ eq 1) (- pin-len (+ eq 1)))]
            (if (= (string-length value) 0)
              (ErrBuildGitDependency
                (build-git-dep-error alias "has empty pin"))
              (if (compiler-load-github-pin-kind-valid? kind)
                (OkBuildGitDependency (BuildGitDependency remote kind value))
                (ErrBuildGitDependency
                  (build-git-dep-error alias "has invalid pin kind"))))))))))

(define (build-git-dep-pin-kind [alias : String] [dep : BuildGitDependency]) : ResultPackageCachePinKind
  (let
    [kind : String (struct-get dep pin-kind)]
    (cond
      (string-eq kind "rev")
      (OkPackageCachePinKind (PackageCachePinRev))
      (string-eq kind "tag")
      (OkPackageCachePinKind (PackageCachePinTag))
      (string-eq kind "branch")
      (OkPackageCachePinKind (PackageCachePinBranch))
      (ErrPackageCachePinKind
        (build-git-dep-error alias "has invalid pin kind")))))

(define (build-package-lock-path [manifest-dir : String]) : String
  (compiler-load-join-root-path manifest-dir "typelisp.lock"))

(define (build-load-package-lock [manifest-dir : String]) : ResultBuildPackageLockState
  (let
    [path : String (build-package-lock-path manifest-dir)]
    (if (file-exists? path)
      (match (try-read-file (& path))
        [(ErrIoString error)
          (ErrBuildPackageLockState
            (str-cat
              "build: cannot read package lock '"
              path
              (string-append "': " (io-error-message error))))]
        [(OkIoString source)
          (match (package-lock-parse source)
            [(ErrPackageLockFile message)
              (ErrBuildPackageLockState
                (str-cat
                  "build: invalid package lock '"
                  path
                  (string-append "': " message)))]
            [(OkPackageLockFile lock)
              (OkBuildPackageLockState
                (BuildPackageLockState path (struct-get lock entries) true))])])
      (OkBuildPackageLockState
        (BuildPackageLockState path PackageLockEntryNil false)))))

(define (build-write-package-lock
  [state : BuildPackageLockState]
  [entries : PackageLockEntryList]) : ResultBuildString
  (let
    [lock : PackageLockFile (PackageLockFile package-lock-version entries)]
    [text : String (package-lock-emit lock)]
    [path : String (struct-get state path)]
    (match (try-write-file (& path) (& text))
      [(OkIoUnit) (OkBuildString path)]
      [(ErrIoUnit error)
        (ErrBuildString
          (str-cat
            "build: cannot write package lock '"
            path
            (string-append "': " (io-error-message error))))])))

(define (build-package-lock-entry-matches?
  [entry : PackageLockEntry]
  [alias : String]
  [dep : BuildGitDependency]) : bool
  (match (build-git-dep-pin-kind alias dep)
    [(ErrPackageCachePinKind _) false]
    [(OkPackageCachePinKind kind)
      (and
        (string-eq (struct-get entry alias) alias)
        (string-eq (struct-get entry url) (struct-get dep remote))
        (package-cache-pin-kind-eq? (struct-get entry pin-kind) kind)
        (string-eq (struct-get entry pin-value) (struct-get dep pin-value)))]))

(define (build-package-lock-matching-entry
  [entries : PackageLockEntryList]
  [alias : String]
  [dep : BuildGitDependency]) : BuildMaybeLockEntry
  (match (package-lock-entry-list-lookup entries alias)
    [(PackageLockNoEntry) (BuildNoLockEntry)]
    [(PackageLockSomeEntry entry)
      (if (build-package-lock-entry-matches? entry alias dep)
        (BuildSomeLockEntry entry)
        (BuildNoLockEntry))]))

(define (build-package-lock-entry-status
  [entries : PackageLockEntryList]
  [alias : String]
  [dep : BuildGitDependency]) : BuildPackageLockEntryStatus
  (match (package-lock-entry-list-lookup entries alias)
    [(PackageLockNoEntry) (BuildPackageLockEntryMissing)]
    [(PackageLockSomeEntry entry)
      (if (build-package-lock-entry-matches? entry alias dep)
        (BuildPackageLockEntryMatched entry)
        (BuildPackageLockEntryStale))]))

(define (build-package-lock-missing-message [alias : String]) : String
  (str-cat
    "build: --locked requires typelisp.lock entry for remote dependency `"
    alias
    "`; run with --update-lock to refresh typelisp.lock"))

(define (build-package-lock-stale-message [alias : String]) : String
  (str-cat
    "build: package lock entry for remote dependency `"
    alias
    "` is stale; run with --update-lock to refresh typelisp.lock"))

(define (build-package-lock-entry
  [alias : String]
  [dep : BuildGitDependency]
  [commit : String]) : ResultPackageLockEntry
  (match (build-git-dep-pin-kind alias dep)
    [(ErrPackageCachePinKind message) (ErrPackageLockEntry message)]
    [(OkPackageCachePinKind kind)
      (OkPackageLockEntry
        (PackageLockEntry
          alias
          (struct-get dep remote)
          kind
          (struct-get dep pin-value)
          commit))]))

(define (build-git-dependency-at-commit
  [dep : BuildGitDependency]
  [commit : String]) : BuildGitDependency
  (BuildGitDependency (struct-get dep remote) "rev" commit))

(define (build-git-checkout-ref [dep : BuildGitDependency]) : String
  (if (string-eq (struct-get dep pin-kind) "branch")
    (string-append "origin/" (struct-get dep pin-value))
    (struct-get dep pin-value)))

(define (build-git-executable) : String
  (source-tool-resolve-command "git"))

(define (build-process-output-detail [output : ProcessOutput]) : String
  (let
    [stderr : String (process-output-stderr output)]
    [stdout : String (process-output-stdout output)]
    (if (> (string-length stderr) 0)
      (string-append ": " stderr)
      (if (> (string-length stdout) 0)
        (string-append ": " stdout)
        ""))))

(define (build-run-captured [context : String] [command : ProcessCommand]) : ResultBuildString
  (match (process-output command)
    [(OkProcessOutput output)
      (if (process-success? output)
        (OkBuildString (process-output-stdout output))
        (ErrBuildString
          (string-append
            context
            (string-append
              " failed with status "
              (string-append
                (int->string (process-output-status output))
                (build-process-output-detail output))))))]
    [(ErrProcessOutput error)
      (ErrBuildString
        (string-append
          context
          (string-append ": " (process-error-message error))))]))

(define (build-git-clone-command [remote : String] [root : String]) : ProcessCommand
  (process-command
    (build-git-executable)
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append
          (source-tool-args-append
            (source-tool-args-append (process-args-empty) "-c")
            "core.longpaths=true")
          "clone")
        remote)
      root)))

(define (build-git-checkout-command [root : String] [checkout-ref : String]) : ProcessCommand
  (process-command
    (build-git-executable)
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append
          (source-tool-args-append
            (source-tool-args-append
              (source-tool-args-append
                (source-tool-args-append (process-args-empty) "-c")
                "core.longpaths=true")
              "-C")
            root)
          "checkout")
        "--detach")
      checkout-ref)))

(define (build-git-rev-parse-command [root : String]) : ProcessCommand
  (process-command
    (build-git-executable)
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append
          (source-tool-args-append
            (source-tool-args-append
              (source-tool-args-append (process-args-empty) "-c")
              "core.longpaths=true")
            "-C")
          root)
        "rev-parse")
      "HEAD")))

(define (build-trim-command-output [output : String]) : String
  (string-trim (& output)))

(define (build-resolve-git-head [alias : String] [root : String]) : ResultBuildString
  (match (build-run-captured
    (build-git-dep-error alias "git rev-parse")
    (build-git-rev-parse-command root))
    [(ErrBuildString message) (ErrBuildString message)]
    [(OkBuildString output)
      (let
        [commit : String (build-trim-command-output output)]
        (if (= (string-length commit) 0)
          (ErrBuildString
            (build-git-dep-error alias "resolved commit is empty"))
          (OkBuildString commit)))]))

(define (build-absolute-dep-root [manifest-dir : String] [dep-root : String]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path manifest-dir dep-root)))

(define (build-ensure-github-cache-parent
  [manifest-dir : String]
  [alias : String]) : ResultBuildString
  (let
    [target-dir : String (compiler-load-join-root-path manifest-dir "target")]
    [typelisp-dir : String (compiler-load-join-root-path target-dir "typelisp")]
    [deps-dir : String (compiler-load-join-root-path typelisp-dir "git-deps")]
    (cond
      (not (build-mkdir-ok? target-dir))
      (ErrBuildString
        (build-git-dep-error alias "could not create target directory"))
      (not (build-mkdir-ok? typelisp-dir))
      (ErrBuildString
        (build-git-dep-error alias "could not create target/typelisp directory"))
      (not (build-mkdir-ok? deps-dir))
      (ErrBuildString
        (build-git-dep-error
          alias
          "could not create target/typelisp/git-deps directory"))
      (OkBuildString deps-dir))))

(define (build-github-cache-git-dir [manifest-dir : String] [alias : String]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path
      (build-github-dep-cache-root manifest-dir alias)
      ".git")))

(define (build-github-cache-needs-git? [manifest-dir : String] [alias : String]) : bool
  (or
    (not
      (file-exists? (build-github-dep-cache-manifest-path manifest-dir alias)))
    (file-exists? (build-github-cache-git-dir manifest-dir alias))))

(define (build-git-dep-rev? [dep : BuildGitDependency]) : bool
  (string-eq (struct-get dep pin-kind) "rev"))

(define (build-package-cache-relative-root) : String
  (compiler-load-join-root-path
    (compiler-load-join-root-path
      (compiler-load-join-root-path
        (compiler-load-join-root-path "target" "typelisp")
        "cache")
      "packages")
    package-cache-version))

(define (build-package-cache-manifest-path [entry-path : String]) : String
  (compiler-load-join-root-path entry-path "typelisp.pkg"))

(define (build-ensure-package-cache-root
  [manifest-dir : String]
  [alias : String]) : ResultBuildString
  (let
    [target-dir : String (compiler-load-join-root-path manifest-dir "target")]
    [typelisp-dir : String (compiler-load-join-root-path target-dir "typelisp")]
    [cache-dir : String (compiler-load-join-root-path typelisp-dir "cache")]
    [packages-dir : String (compiler-load-join-root-path cache-dir "packages")]
    [root : String (package-cache-default-root manifest-dir)]
    (cond
      (not (build-mkdir-ok? target-dir))
      (ErrBuildString
        (build-git-dep-error alias "could not create target directory"))
      (not (build-mkdir-ok? typelisp-dir))
      (ErrBuildString
        (build-git-dep-error alias "could not create target/typelisp directory"))
      (not (build-mkdir-ok? cache-dir))
      (ErrBuildString
        (build-git-dep-error
          alias
          "could not create target/typelisp/cache directory"))
      (not (build-mkdir-ok? packages-dir))
      (ErrBuildString
        (build-git-dep-error
          alias
          "could not create target/typelisp/cache/packages directory"))
      (not (build-mkdir-ok? root))
      (ErrBuildString
        (build-git-dep-error
          alias
          "could not create target/typelisp/cache/packages/v1 directory"))
      (OkBuildString root))))

(define (build-package-cache-io-error
  [alias : String]
  [action : String]
  [error : IoError]) : String
  (build-git-dep-error
    alias
    (string-append action (string-append ": " (io-error-message error)))))

(define (build-package-cache-staging-path
  [alias : String]
  [root : String]
  [key : PackageCacheKey]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 16)
    (ErrBuildString
      (build-git-dep-error alias "package cache has no free staging path"))
    (let
      [staged : String (package-cache-staging-path root key attempt)]
      (if (file-exists? staged)
        (build-package-cache-staging-path alias root key (+ attempt 1))
        (OkBuildString staged)))))

(define (build-package-cache-conflict-backup-path
  [entry-path : String]
  [attempt : i64]) : String
  (string-append entry-path (string-append ".corrupt." (int->string attempt))))

(define (build-package-cache-move-conflict-attempt
  [alias : String]
  [entry-path : String]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 16)
    (ErrBuildString
      (build-git-dep-error
        alias
        "package cache has no free corrupt backup path"))
    (let
      [backup : String
        (build-package-cache-conflict-backup-path entry-path attempt)]
      (if (file-exists? backup)
        (build-package-cache-move-conflict-attempt
          alias
          entry-path
          (+ attempt 1))
        (match (try-rename (& entry-path) (& backup))
          [(OkIoUnit) (OkBuildString backup)]
          [(ErrIoUnit error)
            (ErrBuildString
              (build-package-cache-io-error
                alias
                "package cache move corrupt entry"
                error))])))))

(define (build-package-cache-move-conflict
  [alias : String]
  [entry-path : String]) : ResultBuildString
  (if (file-exists? entry-path)
    (build-package-cache-move-conflict-attempt alias entry-path 1)
    (OkBuildString entry-path)))

(define (build-package-cache-hit-result
  [alias : String]
  [entry-path : String]
  [relative-entry-root : String]) : ResultBuildString
  (if (file-exists? (build-package-cache-manifest-path entry-path))
    (OkBuildString relative-entry-root)
    (ErrBuildString
      (build-git-dep-error alias "cached package is missing typelisp.pkg"))))

(define (build-package-cache-finalize-staged
  [alias : String]
  [staged-path : String]
  [entry-path : String]
  [relative-entry-root : String]
  [key : PackageCacheKey]) : ResultBuildString
  (match (package-cache-finalize-staged staged-path entry-path)
    [(OkIoUnit) (OkBuildString relative-entry-root)]
    [(ErrIoUnit error)
      (match (package-cache-entry-state entry-path key)
        [(PackageCacheCompleteHit _)
          (build-package-cache-hit-result alias entry-path relative-entry-root)]
        [_
          (ErrBuildString
            (build-package-cache-io-error alias "package cache finalize" error))])]))

(define (build-package-cache-write-marker
  [alias : String]
  [staged-path : String]
  [key : PackageCacheKey]) : ResultBuildString
  (match (package-cache-write-complete-marker staged-path key)
    [(OkIoUnit) (OkBuildString staged-path)]
    [(ErrIoUnit error)
      (ErrBuildString
        (build-package-cache-io-error alias "package cache write marker" error))]))

(define (build-package-cache-prepare-entry-parents-result
  [alias : String]
  [root : String]
  [key : PackageCacheKey]) : ResultBuildString
  (match (package-cache-prepare-entry-parents root key)
    [(OkIoUnit) (OkBuildString root)]
    [(ErrIoUnit error)
      (ErrBuildString
        (build-package-cache-io-error alias "package cache prepare entry" error))]))

(define (build-package-cache-fetch-staged
  [alias : String]
  [dep : BuildGitDependency]
  [root : String]
  [key : PackageCacheKey]
  [entry-path : String]
  [relative-entry-root : String]
  [replace-existing : bool]) : ResultBuildString
  (match (package-cache-prepare-staging-parents root key)
    [(ErrIoUnit error)
      (ErrBuildString
        (build-package-cache-io-error
          alias
          "package cache prepare staging"
          error))]
    [(OkIoUnit)
      (match (build-package-cache-staging-path alias root key 1)
        [(ErrBuildString message) (ErrBuildString message)]
        [(OkBuildString staged-path)
          (match (build-run-captured
            (build-git-dep-error alias "git clone")
            (build-git-clone-command (struct-get dep remote) staged-path))
            [(ErrBuildString message) (ErrBuildString message)]
            [(OkBuildString _)
              (match (build-run-captured
                (build-git-dep-error alias "git checkout")
                (build-git-checkout-command
                  staged-path
                  (build-git-checkout-ref dep)))
                [(ErrBuildString message) (ErrBuildString message)]
                [(OkBuildString _)
                  (match (build-run-captured
                    (build-git-dep-error alias "git rev-parse")
                    (build-git-rev-parse-command staged-path))
                    [(ErrBuildString message) (ErrBuildString message)]
                    [(OkBuildString _)
                      (if (not
                        (file-exists?
                          (build-package-cache-manifest-path staged-path)))
                        (ErrBuildString
                          (build-git-dep-error
                            alias
                            "fetched package is missing typelisp.pkg"))
                        (match (build-package-cache-write-marker
                          alias
                          staged-path
                          key)
                          [(ErrBuildString message) (ErrBuildString message)]
                          [(OkBuildString _)
                            (match (build-package-cache-prepare-entry-parents-result
                              alias
                              root
                              key)
                              [(ErrBuildString message)
                                (ErrBuildString message)]
                              [(OkBuildString _)
                                (match (if replace-existing
                                  (build-package-cache-move-conflict
                                    alias
                                    entry-path)
                                  (OkBuildString entry-path))
                                  [(ErrBuildString message)
                                    (ErrBuildString message)]
                                  [(OkBuildString _)
                                    (build-package-cache-finalize-staged
                                      alias
                                      staged-path
                                      entry-path
                                      relative-entry-root
                                      key)])])]))])])])])]))

(define (build-fetch-github-dependency-cached
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]) : ResultBuildString
  (let
    [key : PackageCacheKey
      (PackageCacheKey (struct-get dep remote) (struct-get dep pin-value))]
    [root : String (package-cache-default-root manifest-dir)]
    [entry-path : String (package-cache-entry-path root key)]
    [relative-entry-root : String
      (compiler-load-normalize-path
        (package-cache-entry-path (build-package-cache-relative-root) key))]
    [state : PackageCacheEntryState (package-cache-entry-state entry-path key)]
    (match state
      [(PackageCacheCompleteHit _)
        (if (file-exists? (build-package-cache-manifest-path entry-path))
          (OkBuildString relative-entry-root)
          (match (build-ensure-package-cache-root manifest-dir alias)
            [(ErrBuildString message) (ErrBuildString message)]
            [(OkBuildString _)
              (build-package-cache-fetch-staged
                alias
                dep
                root
                key
                entry-path
                relative-entry-root
                true)]))]
      [(PackageCacheMiss _)
        (match (build-ensure-package-cache-root manifest-dir alias)
          [(ErrBuildString message) (ErrBuildString message)]
          [(OkBuildString _)
            (build-package-cache-fetch-staged
              alias
              dep
              root
              key
              entry-path
              relative-entry-root
              false)])]
      [(PackageCachePartialOrCorrupt _ _)
        (match (build-ensure-package-cache-root manifest-dir alias)
          [(ErrBuildString message) (ErrBuildString message)]
          [(OkBuildString _)
            (build-package-cache-fetch-staged
              alias
              dep
              root
              key
              entry-path
              relative-entry-root
              true)])])))

(define (build-git-clone-if-needed
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]
  [root : String]) : ResultBuildString
  (if (file-exists? (build-github-cache-git-dir manifest-dir alias))
    (OkBuildString root)
    (build-run-captured
      (build-git-dep-error alias "git clone")
      (build-git-clone-command (struct-get dep remote) root))))

(define (build-fetch-github-dependency-legacy
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]) : ResultBuildString
  (let
    [root : String (build-github-dep-cache-root manifest-dir alias)]
    [manifest-path : String
      (build-github-dep-cache-manifest-path manifest-dir alias)]
    (if (not (build-github-cache-needs-git? manifest-dir alias))
      (OkBuildString manifest-path)
      (match (build-ensure-github-cache-parent manifest-dir alias)
        [(ErrBuildString message) (ErrBuildString message)]
        [(OkBuildString _)
          (match (build-git-clone-if-needed manifest-dir alias dep root)
            [(ErrBuildString message) (ErrBuildString message)]
            [(OkBuildString _)
              (match (build-run-captured
                (build-git-dep-error alias "git checkout")
                (build-git-checkout-command root (build-git-checkout-ref dep)))
                [(ErrBuildString message) (ErrBuildString message)]
                [(OkBuildString _)
                  (match (build-run-captured
                    (build-git-dep-error alias "git rev-parse")
                    (build-git-rev-parse-command root))
                    [(ErrBuildString message) (ErrBuildString message)]
                    [(OkBuildString _)
                      (if (file-exists? manifest-path)
                        (OkBuildString (build-github-dep-relative-root alias))
                        (ErrBuildString
                          (build-git-dep-error
                            alias
                            "fetched package is missing typelisp.pkg")))])])])]))))

(define (build-fetch-github-dependency
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]) : ResultBuildString
  (if (not (build-github-cache-needs-git? manifest-dir alias))
    (OkBuildString (build-github-dep-relative-root alias))
    (if (build-git-dep-rev? dep)
      (build-fetch-github-dependency-cached manifest-dir alias dep)
      (build-fetch-github-dependency-legacy manifest-dir alias dep))))

(define (build-resolve-github-dependency-from-lock
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]
  [entry : PackageLockEntry]) : ResultBuildResolvedGitDependency
  (let
    [locked-commit : String (struct-get entry commit)]
    [locked-dep : BuildGitDependency
      (build-git-dependency-at-commit dep locked-commit)]
    (match (build-fetch-github-dependency-cached manifest-dir alias locked-dep)
      [(ErrBuildString message) (ErrBuildResolvedGitDependency message)]
      [(OkBuildString dep-root)
        (OkBuildResolvedGitDependency
          (BuildResolvedGitDependency dep-root entry))])))

(define (build-resolve-github-dependency-without-lock
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]) : ResultBuildResolvedGitDependency
  (match (build-fetch-github-dependency manifest-dir alias dep)
    [(ErrBuildString message) (ErrBuildResolvedGitDependency message)]
    [(OkBuildString dep-root)
      (let
        [commit-result : ResultBuildString
          (if (build-git-dep-rev? dep)
            (OkBuildString (struct-get dep pin-value))
            (build-resolve-git-head
              alias
              (build-absolute-dep-root manifest-dir dep-root)))]
        (match commit-result
          [(ErrBuildString message) (ErrBuildResolvedGitDependency message)]
          [(OkBuildString commit)
            (match (build-package-lock-entry alias dep commit)
              [(ErrPackageLockEntry message)
                (ErrBuildResolvedGitDependency message)]
              [(OkPackageLockEntry entry)
                (OkBuildResolvedGitDependency
                  (BuildResolvedGitDependency dep-root entry))])]))]))

(define (build-resolve-github-dependency
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]
  [lock-entries : PackageLockEntryList]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildResolvedGitDependency
  (if (build-package-lock-policy-update? lock-policy)
    (build-resolve-github-dependency-without-lock manifest-dir alias dep)
    (if (build-package-lock-policy-locked? lock-policy)
      (match (build-package-lock-entry-status lock-entries alias dep)
        [(BuildPackageLockEntryMatched entry)
          (build-resolve-github-dependency-from-lock
            manifest-dir
            alias
            dep
            entry)]
        [(BuildPackageLockEntryMissing)
          (ErrBuildResolvedGitDependency
            (build-package-lock-missing-message alias))]
        [(BuildPackageLockEntryStale)
          (ErrBuildResolvedGitDependency
            (build-package-lock-stale-message alias))])
      (match (build-package-lock-matching-entry lock-entries alias dep)
        [(BuildSomeLockEntry entry)
          (build-resolve-github-dependency-from-lock
            manifest-dir
            alias
            dep
            entry)]
        [(BuildNoLockEntry)
          (build-resolve-github-dependency-without-lock manifest-dir alias dep)]))))

(define (build-package-resolve-dep-with-lock
  [manifest-dir : String]
  [lock-entries : PackageLockEntryList]
  [lock-policy : BuildPackageLockPolicy]
  [dep : CompilerPkgDep]) : ResultBuildResolvedPkgDep
  (let
    [path : String (struct-get dep path)]
    [alias : String (struct-get dep alias)]
    (if (compiler-load-github-dependency-path? path)
      (match (build-parse-git-dependency alias path)
        [(ErrBuildGitDependency message) (ErrBuildResolvedPkgDep message)]
        [(OkBuildGitDependency git-dep)
          (match (build-resolve-github-dependency
            manifest-dir
            alias
            git-dep
            lock-entries
            lock-policy)
            [(ErrBuildResolvedGitDependency message)
              (ErrBuildResolvedPkgDep message)]
            [(OkBuildResolvedGitDependency resolved)
              (OkBuildResolvedPkgDep
                (BuildResolvedPkgDep
                  (CompilerPkgDep alias (struct-get resolved dep-root))
                  (BuildSomeLockEntry (struct-get resolved lock-entry))))])])
      (OkBuildResolvedPkgDep (BuildResolvedPkgDep dep (BuildNoLockEntry))))))

(define (build-package-resolve-dep
  [manifest-dir : String]
  [dep : CompilerPkgDep]) : ResultBuildPkgDep
  (match (build-package-resolve-dep-with-lock
    manifest-dir
    PackageLockEntryNil
    (BuildPackageLockDefault)
    dep)
    [(ErrBuildResolvedPkgDep message) (ErrBuildPkgDep message)]
    [(OkBuildResolvedPkgDep resolved) (OkBuildPkgDep (struct-get resolved dep))]))

(define (build-package-lock-entry-list-add
  [entries : PackageLockEntryList]
  [maybe-entry : BuildMaybeLockEntry]) : ResultPackageLockEntryList
  (match maybe-entry
    [(BuildNoLockEntry) (OkPackageLockEntryList entries)]
    [(BuildSomeLockEntry entry) (package-lock-entry-list-insert entries entry)]))

(define (build-package-lock-list-has-exact-entry?
  [entries : PackageLockEntryList]
  [entry : PackageLockEntry]) : bool
  (package-lock-list-has-entry?
    entries
    (struct-get entry alias)
    (struct-get entry url)
    (struct-get entry pin-kind)
    (struct-get entry pin-value)
    (struct-get entry commit)))

(define (build-package-lock-list-contains-all?
  [haystack : PackageLockEntryList]
  [needles : PackageLockEntryList]) : bool
  (match needles
    [(PackageLockEntryNil) true]
    [(PackageLockEntryCons entry rest)
      (and
        (build-package-lock-list-has-exact-entry? haystack entry)
        (build-package-lock-list-contains-all? haystack (box-get rest)))]))

(define (build-package-lock-list-eq?
  [left : PackageLockEntryList]
  [right : PackageLockEntryList]) : bool
  (and
    (=
      (package-lock-entry-list-count left)
      (package-lock-entry-list-count right))
    (build-package-lock-list-contains-all? left right)))

(define (build-package-lock-policy-check
  [policy : BuildPackageLockPolicy]
  [lock-state : BuildPackageLockState]
  [resolved : BuildResolvedPkgDeps]) : ResultBuildString
  (if (build-package-lock-policy-locked? policy)
    (if (and
      (struct-get resolved has-remote)
      (not (struct-get lock-state has-lock)))
      (ErrBuildString
        "build: --locked requires typelisp.lock for remote dependencies; run with --update-lock to refresh typelisp.lock")
      (if (and
        (struct-get lock-state has-lock)
        (not
          (build-package-lock-list-eq?
            (struct-get lock-state entries)
            (struct-get resolved lock-entries))))
        (ErrBuildString
          "build: package lock is stale; run with --update-lock to refresh typelisp.lock")
        (OkBuildString "")))
    (OkBuildString "")))

(define (build-package-maybe-write-lock
  [policy : BuildPackageLockPolicy]
  [lock-state : BuildPackageLockState]
  [resolved : BuildResolvedPkgDeps]) : ResultBuildString
  (if (and
    (not (build-package-lock-policy-locked? policy))
    (or (struct-get resolved has-remote) (struct-get lock-state has-lock)))
    (build-write-package-lock lock-state (struct-get resolved lock-entries))
    (OkBuildString "")))

(define (build-package-resolve-deps-with-lock
  [manifest-dir : String]
  [lock-entries : PackageLockEntryList]
  [lock-policy : BuildPackageLockPolicy]
  [deps : CompilerPkgDepList]) : ResultBuildResolvedPkgDeps
  (match deps
    [(CompilerPkgDepNil)
      (OkBuildResolvedPkgDeps
        (BuildResolvedPkgDeps CompilerPkgDepNil PackageLockEntryNil false))]
    [(CompilerPkgDepCons dep rest)
      (match (build-package-resolve-dep-with-lock
        manifest-dir
        lock-entries
        lock-policy
        dep)
        [(ErrBuildResolvedPkgDep message) (ErrBuildResolvedPkgDeps message)]
        [(OkBuildResolvedPkgDep resolved-dep)
          (match (build-package-resolve-deps-with-lock
            manifest-dir
            lock-entries
            lock-policy
            (box-get rest))
            [(ErrBuildResolvedPkgDeps message)
              (ErrBuildResolvedPkgDeps message)]
            [(OkBuildResolvedPkgDeps resolved-rest)
              (match (build-package-lock-entry-list-add
                (struct-get resolved-rest lock-entries)
                (struct-get resolved-dep lock-entry))
                [(ErrPackageLockEntryList message)
                  (ErrBuildResolvedPkgDeps message)]
                [(OkPackageLockEntryList next-lock-entries)
                  (OkBuildResolvedPkgDeps
                    (BuildResolvedPkgDeps
                      (CompilerPkgDepCons
                        (struct-get resolved-dep dep)
                        (box (struct-get resolved-rest deps)))
                      next-lock-entries
                      (or
                        (struct-get resolved-rest has-remote)
                        (match (struct-get resolved-dep lock-entry)
                          [(BuildNoLockEntry) false]
                          [(BuildSomeLockEntry _) true]))))])])])]))

(define (build-package-resolve-deps
  [manifest-dir : String]
  [deps : CompilerPkgDepList]) : ResultBuildPkgDepList
  (match (build-package-resolve-deps-with-lock
    manifest-dir
    PackageLockEntryNil
    (BuildPackageLockDefault)
    deps)
    [(ErrBuildResolvedPkgDeps message) (ErrBuildPkgDepList message)]
    [(OkBuildResolvedPkgDeps resolved)
      (OkBuildPkgDepList (struct-get resolved deps))]))

(define (build-package-resolve-manifest-deps
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildManifest
  (let
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    (match (build-load-package-lock manifest-dir)
      [(ErrBuildPackageLockState message) (ErrBuildManifest message)]
      [(OkBuildPackageLockState lock-state)
        (match (build-package-resolve-deps-with-lock
          manifest-dir
          (struct-get lock-state entries)
          lock-policy
          (compiler-pkg-deps-list (struct-get manifest deps)))
          [(ErrBuildResolvedPkgDeps message) (ErrBuildManifest message)]
          [(OkBuildResolvedPkgDeps resolved)
            (match (build-package-lock-policy-check
              lock-policy
              lock-state
              resolved)
              [(ErrBuildString message) (ErrBuildManifest message)]
              [(OkBuildString _)
                (match (build-package-maybe-write-lock
                  lock-policy
                  lock-state
                  resolved)
                  [(ErrBuildString message) (ErrBuildManifest message)]
                  [(OkBuildString _)
                    (OkBuildManifest
                      (CompilerPkgManifest
                        (struct-get manifest name)
                        (struct-get manifest version)
                        (struct-get manifest kind)
                        (struct-get manifest entry)
                        (compiler-pkg-deps-from-list (struct-get resolved deps))
                        (struct-get manifest link)))])])])])))

(define (build-package-normalize-manifest-path [manifest-path : String]) : String
  (compiler-load-normalize-path manifest-path))

(define (build-package-path-list-render [paths : BuildPackagePathList]) : String
  (match paths
    [(BuildPackagePathNil) ""]
    [(BuildPackagePathCons path rest)
      (let
        [tail : String (build-package-path-list-render (box-get rest))]
        (if (= (string-length tail) 0)
          path
          (string-append tail (string-append " -> " path))))]))

(define (build-package-cycle-message
  [stack : BuildPackagePathList]
  [manifest-path : String]) : String
  (string-append
    "build: dependency cycle: "
    (string-append
      (build-package-path-list-render stack)
      (string-append " -> " manifest-path))))

(define (build-package-graph-node-vec-len [v : BuildPackageGraphNodeVec]) : i64
  (struct-get v len))

(define (build-package-graph-node-vec-capacity [v : BuildPackageGraphNodeVec]) : i64
  (array-length (struct-get v slots)))

(define (build-package-graph-node-vec-with-capacity [capacity : i64]) : BuildPackageGraphNodeVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (BuildPackageGraphNodeVec (make-array BuildPackageGraphNode cap) 0)))

(define (build-package-graph-node-vec-new) : BuildPackageGraphNodeVec
  (build-package-graph-node-vec-with-capacity 4))

(define (build-package-graph-node-vec-at
  [v : BuildPackageGraphNodeVec]
  [index : i64]) : BuildPackageGraphNode
  (array-ref (struct-get v slots) index))

(define (build-package-graph-node-vec-copy-range!
  [dst : (Array BuildPackageGraphNode)]
  [src : (Array BuildPackageGraphNode)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (build-package-graph-node-vec-grow [v : BuildPackageGraphNodeVec]) : BuildPackageGraphNodeVec
  (let
    [count : i64 (build-package-graph-node-vec-len v)]
    [bigger : (Array BuildPackageGraphNode)
      (make-array
        BuildPackageGraphNode
        (* (build-package-graph-node-vec-capacity v) 2))]
    (begin
      (build-package-graph-node-vec-copy-range!
        bigger
        (struct-get v slots)
        count)
      (BuildPackageGraphNodeVec bigger count))))

(define (build-package-graph-node-vec-push
  [v : BuildPackageGraphNodeVec]
  [node : BuildPackageGraphNode]) : BuildPackageGraphNodeVec
  (if (<
    (build-package-graph-node-vec-len v)
    (build-package-graph-node-vec-capacity v))
    (let
      [slots : (Array BuildPackageGraphNode) (struct-get v slots)]
      (begin
        (array-set! slots (build-package-graph-node-vec-len v) node)
        (BuildPackageGraphNodeVec
          slots
          (+ (build-package-graph-node-vec-len v) 1))))
    (build-package-graph-node-vec-push
      (build-package-graph-node-vec-grow v)
      node)))

(define (build-package-graph-state-mark
  [state : BuildPackageGraphState]
  [manifest-path : String]
  [mark : i64]) : BuildPackageGraphState
  (BuildPackageGraphState
    (string-i64-map-put (struct-get state seen) manifest-path mark)
    (struct-get state order)))

(define (build-package-graph-state-add-order
  [state : BuildPackageGraphState]
  [node : BuildPackageGraphNode]) : BuildPackageGraphState
  (BuildPackageGraphState
    (struct-get state seen)
    (build-package-graph-node-vec-push (struct-get state order) node)))

(define (build-package-load-dep-node
  [manifest-dir : String]
  [dep : CompilerPkgDep]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildPackageGraphNode
  (match (build-package-resolve-dep manifest-dir dep)
    [(ErrBuildPkgDep message) (ErrBuildPackageGraphNode message)]
    [(OkBuildPkgDep resolved-dep)
      (let
        [dep-manifest-path : String
          (build-package-dep-manifest-path manifest-dir resolved-dep)]
        (match (build-load-manifest dep-manifest-path)
          [(ErrBuildManifest message)
            (ErrBuildPackageGraphNode
              (string-append
                "dependency `"
                (string-append
                  (struct-get resolved-dep alias)
                  (string-append "`: " message))))]
          [(OkBuildManifest dep-manifest)
            (match (build-package-resolve-manifest-deps
              dep-manifest-path
              dep-manifest
              lock-policy)
              [(ErrBuildManifest message) (ErrBuildPackageGraphNode message)]
              [(OkBuildManifest resolved-manifest)
                (if (not
                  (build-package-kind-lib? (struct-get resolved-manifest kind)))
                  (ErrBuildPackageGraphNode
                    (string-append
                      "build: dependency `"
                      (string-append
                        (struct-get resolved-dep alias)
                        (string-append
                          "` at "
                          (string-append
                            dep-manifest-path
                            " must be a staticlib package")))))
                  (OkBuildPackageGraphNode
                    (BuildPackageGraphNode dep-manifest-path resolved-manifest)))])]))]))

(define (build-package-graph-add-node
  [node : BuildPackageGraphNode]
  [state : BuildPackageGraphState]
  [stack : BuildPackagePathList]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildPackageGraphState
  (let
    [manifest-path : String (struct-get node manifest-path)]
    (match (string-i64-map-get (struct-get state seen) manifest-path)
      [(StringI64MapFound mark)
        (if (= mark build-package-visit-visiting)
          (ErrBuildPackageGraphState
            (build-package-cycle-message stack manifest-path))
          (OkBuildPackageGraphState state))]
      [(StringI64MapMissing)
        (let
          [visiting : BuildPackageGraphState
            (build-package-graph-state-mark
              state
              manifest-path
              build-package-visit-visiting)]
          [manifest : CompilerPkgManifest (struct-get node manifest)]
          [manifest-dir : String (compiler-load-dirname manifest-path)]
          [next-stack : BuildPackagePathList
            (BuildPackagePathCons manifest-path (box stack))]
          (match (build-package-graph-add-deps
            manifest-dir
            (compiler-pkg-deps-list (struct-get manifest deps))
            visiting
            next-stack
            lock-policy)
            [(ErrBuildPackageGraphState message)
              (ErrBuildPackageGraphState message)]
            [(OkBuildPackageGraphState with-deps)
              (OkBuildPackageGraphState
                (build-package-graph-state-add-order
                  (build-package-graph-state-mark
                    with-deps
                    manifest-path
                    build-package-visit-done)
                  node))]))])))

(define (build-package-graph-add-deps
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [state : BuildPackageGraphState]
  [stack : BuildPackagePathList]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildPackageGraphState
  (match deps
    [(CompilerPkgDepNil) (OkBuildPackageGraphState state)]
    [(CompilerPkgDepCons dep rest)
      (match (build-package-load-dep-node manifest-dir dep lock-policy)
        [(ErrBuildPackageGraphNode message) (ErrBuildPackageGraphState message)]
        [(OkBuildPackageGraphNode node)
          (match (build-package-graph-add-node node state stack lock-policy)
            [(ErrBuildPackageGraphState message)
              (ErrBuildPackageGraphState message)]
            [(OkBuildPackageGraphState next-state)
              (build-package-graph-add-deps
                manifest-dir
                (box-get rest)
                next-state
                stack
                lock-policy)])])]))

(define (build-package-dependency-graph
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildPackageGraph
  (let
    [root-path : String (build-package-normalize-manifest-path manifest-path)]
    [root-dir : String (compiler-load-dirname root-path)]
    [initial : BuildPackageGraphState
      (BuildPackageGraphState
        (string-i64-map-put
          (string-i64-map-with-capacity 32)
          root-path
          build-package-visit-visiting)
        (build-package-graph-node-vec-new))]
    [stack : BuildPackagePathList
      (BuildPackagePathCons root-path (box BuildPackagePathNil))]
    (match (build-package-graph-add-deps
      root-dir
      (compiler-pkg-deps-list (struct-get manifest deps))
      initial
      stack
      lock-policy)
      [(ErrBuildPackageGraphState message) (ErrBuildPackageGraph message)]
      [(OkBuildPackageGraphState state)
        (OkBuildPackageGraph (BuildPackageGraph (struct-get state order)))])))

(define (build-mkdir-ok? [path : String]) : bool
  (let
    [status : i64 (fs-mkdir-status (& path))]
    (or (= status build-status-ok) (= status build-status-already-exists))))

(define (build-ensure-package-output-dirs
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : bool
  (let
    [target-dir : String (compiler-load-join-root-path manifest-dir "target")]
    [profile-dir : String
      (compiler-load-join-root-path target-dir (build-profile-name profile))]
    (and (build-mkdir-ok? target-dir) (build-mkdir-ok? profile-dir))))

;: Resolve a manifest `search-paths` value against the manifest directory.
;: Relative paths are joined and normalized so package builds do not depend on
;: the caller's working directory; absolute paths are left as written.
(define (build-package-link-resolve-search-path
  [manifest-dir : String]
  [value : String]) : String
  (if (compiler-load-absolute-path? value)
    value
    (compiler-load-normalize-path
      (compiler-load-join-root-path manifest-dir value))))

(define (build-package-link-add-libs
  [inputs : SourceToolLinkInputs]
  [vec : StringVec]
  [idx : i64]) : SourceToolLinkInputs
  (if (>= idx (string-vec-len vec))
    inputs
    (build-package-link-add-libs
      (source-tool-link-inputs-add-ast
        inputs
        (AstExternLinkLib (string-vec-get vec idx "")))
      vec
      (+ idx 1))))

(define (build-package-link-add-search-paths
  [inputs : SourceToolLinkInputs]
  [manifest-dir : String]
  [vec : StringVec]
  [idx : i64]) : SourceToolLinkInputs
  (if (>= idx (string-vec-len vec))
    inputs
    (build-package-link-add-search-paths
      (source-tool-link-inputs-add-ast
        inputs
        (AstExternLinkSearch
          (build-package-link-resolve-search-path
            manifest-dir
            (string-vec-get vec idx ""))))
      manifest-dir
      vec
      (+ idx 1))))

(define (build-package-link-add-args
  [inputs : SourceToolLinkInputs]
  [vec : StringVec]
  [idx : i64]) : SourceToolLinkInputs
  (if (>= idx (string-vec-len vec))
    inputs
    (build-package-link-add-args
      (source-tool-link-inputs-add-ast
        inputs
        (AstExternLinkArg (string-vec-get vec idx "")))
      vec
      (+ idx 1))))

;: Add one link scope set (libraries, then search paths, then raw args) onto
;: `inputs`. The three classes are stored separately, so intra-set ordering
;: across classes does not affect the emitted command.
(define (build-package-link-add-set
  [inputs : SourceToolLinkInputs]
  [manifest-dir : String]
  [set : CompilerPkgLinkSet]) : SourceToolLinkInputs
  (build-package-link-add-args
    (build-package-link-add-search-paths
      (build-package-link-add-libs inputs (struct-get set libraries) 0)
      manifest-dir
      (struct-get set search-paths)
      0)
    (struct-get set args)
    0))

;: Convert a manifest `(link ...)` section into link inputs for `target`:
;: all-target inputs first, then the per-target (linux / windows) inputs,
;: preserving first-seen order and dropping exact duplicates within each class.
(define (build-package-manifest-link-inputs
  [link : CompilerPkgLink]
  [manifest-dir : String]
  [target : CompilerBackendTarget]) : SourceToolLinkInputs
  (build-package-link-add-set
    (build-package-link-add-set
      (source-tool-link-inputs-empty)
      manifest-dir
      (struct-get link all))
    manifest-dir
    (match target
      [(BackendTargetLinux) (struct-get link linux)]
      [(BackendTargetWindows) (struct-get link windows)])))

(define (build-package-artifact-status
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : SourceToolLinkInputs]
  [direct-status : SourceToolDirectObjectStatus]) : SourceToolCommandStatus
  (match direct-status
    [(SourceToolDirectObjectOk) SourceToolCommandOk]
    [(SourceToolDirectObjectErr message) (SourceToolCommandErr message)]
    [(SourceToolDirectObjectUnavailable _)
      (match kind
        [(CompilerPkgKindBin)
          (source-tool-assemble-and-link
            target
            asm-path
            obj-path
            artifact-path
            link-inputs)]
        [(CompilerPkgKindLib)
          (source-tool-assemble-and-archive
            target
            asm-path
            obj-path
            artifact-path)])]))

(define (build-package-render-linux-direct-object
  [kind : CompilerPkgKind]
  [image : CompilerObjectImage]) : ResultSourceToolString
  (match kind
    [(CompilerPkgKindBin) (source-tool-render-linkable-linux-elf-object image)]
    [(CompilerPkgKindLib)
      (source-tool-render-archivable-linux-elf-object image)]))

(define (build-package-write-linux-direct-object-artifact
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : SourceToolLinkInputs]
  [obj : String]) : SourceToolDirectObjectStatus
  (match kind
    [(CompilerPkgKindBin)
      (source-tool-write-direct-object-and-link
        obj-path
        artifact-path
        target
        link-inputs
        obj
        "build: failed to write package direct object artifact")]
    [(CompilerPkgKindLib)
      (source-tool-write-direct-object-and-archive
        obj-path
        artifact-path
        target
        obj
        "build: failed to write package direct object artifact")]))

(define (build-package-try-linux-direct-object
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : SourceToolLinkInputs]) : SourceToolDirectObjectStatus
  (if (and
    (source-tool-linux-direct-object-enabled?)
    (compiler-backend-target-linux? target))
    (match (compiler-driver-emit-package-loaded-object-image
      ""
      target
      true
      opt-level
      mode
      emit-entry
      crt-entry
      decls
      paths)
      [(OkCompilerDriverObject image)
        (match (build-package-render-linux-direct-object kind image)
          [(OkSourceToolString obj)
            (build-package-write-linux-direct-object-artifact
              kind
              target
              obj-path
              artifact-path
              link-inputs
              obj)]
          [(ErrSourceToolString message)
            (SourceToolDirectObjectUnavailable message)])]
      [(ErrCompilerDriverObject diag)
        (SourceToolDirectObjectUnavailable (compiler-diagnostic-render diag))])
    (SourceToolDirectObjectUnavailable "linux direct object disabled")))

(define (build-package-graph-node-artifact-path
  [node : BuildPackageGraphNode]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : String
  (let
    [manifest-path : String (struct-get node manifest-path)]
    [manifest : CompilerPkgManifest (struct-get node manifest)]
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    (build-package-artifact-path-profile
      manifest-dir
      (struct-get manifest name)
      (struct-get manifest kind)
      profile
      target)))

(define (build-package-graph-link-libs
  [nodes : BuildPackageGraphNodeVec]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : ProcessStringList
  (let
    [index : i64 (- (build-package-graph-node-vec-len nodes) 1)]
    [libs : ProcessStringList (process-args-empty)]
    (begin
      (while (>= index 0)
        (begin
          (set!
            libs
            (process-args-append
              libs
              (process-args-single
                (build-package-graph-node-artifact-path
                  (build-package-graph-node-vec-at nodes index)
                  profile
                  target))))
          (set! index (- index 1))))
      libs)))

(define (build-package-graph-test-manifest [name : String]) : CompilerPkgManifest
  (CompilerPkgManifest
    name
    "0.1.0"
    (CompilerPkgKindLib)
    "src/lib.tl"
    (compiler-pkg-deps-empty)
    (compiler-pkg-link-empty)))

(define (build-package-graph-test-manifest-with-deps
  [name : String]
  [deps : CompilerPkgDepList]) : CompilerPkgManifest
  (CompilerPkgManifest
    name
    "0.1.0"
    (CompilerPkgKindLib)
    "src/lib.tl"
    (compiler-pkg-deps-from-list deps)
    (compiler-pkg-link-empty)))

(define (build-package-graph-test-node [manifest-path : String] [name : String]) : BuildPackageGraphNode
  (BuildPackageGraphNode manifest-path (build-package-graph-test-manifest name)))

(define (build-package-graph-test-link-arg [node : BuildPackageGraphNode]) : ProcessStringList
  (process-args-single
    (build-package-graph-node-artifact-path
      node
      (BuildProfileRelease)
      (BackendTargetLinux))))

(define (build-package-graph-vector-smoke-ok?) : bool
  (let
    [first : BuildPackageGraphNode
      (build-package-graph-test-node "root/first/typelisp.pkg" "first")]
    [second : BuildPackageGraphNode
      (build-package-graph-test-node "root/second/typelisp.pkg" "second")]
    [third : BuildPackageGraphNode
      (build-package-graph-test-node "root/third/typelisp.pkg" "third")]
    [nodes : BuildPackageGraphNodeVec
      (build-package-graph-node-vec-push
        (build-package-graph-node-vec-push
          (build-package-graph-node-vec-push
            (build-package-graph-node-vec-with-capacity 1)
            first)
          second)
        third)]
    [libs : ProcessStringList
      (build-package-graph-link-libs
        nodes
        (BuildProfileRelease)
        (BackendTargetLinux))]
    [expected : ProcessStringList
      (process-args-append
        (process-args-append
          (build-package-graph-test-link-arg third)
          (build-package-graph-test-link-arg second))
        (build-package-graph-test-link-arg first))]
    (and
      (= (build-package-graph-node-vec-len nodes) 3)
      (string-eq
        (struct-get (build-package-graph-node-vec-at nodes 0) manifest-path)
        "root/first/typelisp.pkg")
      (source-tool-string-list-eq? libs expected))))

(define (build-package-graph-scheduler-no-progress-smoke-ok?) : bool
  (let
    [dep : CompilerPkgDep (CompilerPkgDep "dep" "../dep")]
    [deps : CompilerPkgDepList (CompilerPkgDepCons dep (box CompilerPkgDepNil))]
    [node : BuildPackageGraphNode
      (BuildPackageGraphNode
        "root/app/typelisp.pkg"
        (build-package-graph-test-manifest-with-deps "app" deps))]
    [nodes : BuildPackageGraphNodeVec
      (build-package-graph-node-vec-push
        (build-package-graph-node-vec-new)
        node)]
    (match (build-package-schedule-pass
      nodes
      (string-i64-map-with-capacity 4)
      (string-i64-map-with-capacity 4)
      (BackendTargetLinux)
      0
      (BuildProfileRelease)
      (BackendModeScalar)
      (BuildPackageLockDefault)
      (string-vec-new)
      (build-package-graph-worker-vec-new))
      [(ErrBuildPackageSchedulePass _) false]
      [(OkBuildPackageSchedulePass pass)
        (and
          (build-package-graph-worker-vec-empty? (struct-get pass workers))
          (not
            (build-package-node-scheduled?
              (struct-get pass scheduled)
              "root/app/typelisp.pkg")))])))

(test
  build-package-graph-vector-smoke
  (unless
    (and
      (build-package-graph-vector-smoke-ok?)
      (build-package-graph-scheduler-no-progress-smoke-ok?))
    (panic "build package graph vector smoke failed")))

(define build-package-tlci-compiler-build-hash : String
  "typelisp-selfhost-v1")

(define (build-package-tlci-metadata [manifest : CompilerPkgManifest]) : TlciMetadata
  (TlciMetadata
    tlci-metadata-version
    (struct-get manifest name)
    (struct-get manifest version)
    TlciExportNil))

(define (build-package-tlci-image [manifest : CompilerPkgManifest]) : TlciImage
  (TlciImage
    tlci-host-arch-x86-64
    tlci-callback-abi-version
    build-package-tlci-compiler-build-hash
    (build-package-tlci-metadata manifest)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)))

(define (build-package-write-tlci
  [path : String]
  [manifest : CompilerPkgManifest]) : SourceToolCommandStatus
  (match (tlci-emit-image (build-package-tlci-image manifest))
    [(ErrTlciBytes message)
      (SourceToolCommandErr
        (str-cat "build: failed to emit package tlci: " message))]
    [(OkTlciBytes bytes)
      (source-tool-write-file
        path
        (tlci-bytes->string bytes 0 (array-length bytes))
        "build: failed to write package tlci")]))

(define (build-package-emit-one
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : StringVec]
  [dep-libs : ProcessStringList]) : i64
  (let
    ;; Windows package DAG nodes are serial same-process compiles; keep only
    ;; persistent cache floors between dependency and root emits.
    [_ : unit (cfg windows (compiler-driver-reset-file-state!) unit)]
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    [entry-path : String
      (compiler-load-join-root-path manifest-dir (struct-get manifest entry))]
    [name : String (struct-get manifest name)]
    [kind : CompilerPkgKind (struct-get manifest kind)]
    [asm-path : String
      (build-package-asm-path-profile manifest-dir name profile)]
    [obj-path : String
      (build-package-obj-path-profile manifest-dir name profile target)]
    [artifact-path : String
      (build-package-artifact-path-profile
        manifest-dir
        name
        kind
        profile
        target)]
    [tlci-path : String
      (build-package-tlci-path-profile manifest-dir name profile)]
    [reset-file-state : unit (compiler-driver-reset-file-state!)]
    (if (not (build-ensure-package-output-dirs manifest-dir name profile))
      (begin
        (print-error
          (string-append
            "build: failed to create package output directory "
            (build-package-output-dir-profile manifest-dir name profile)))
        1)
      (let
        [manifest-link-inputs : SourceToolLinkInputs
          (build-package-manifest-link-inputs
            (struct-get manifest link)
            manifest-dir
            target)]
        [dep-link-inputs : SourceToolLinkInputs
          (source-tool-link-inputs-from-archives dep-libs)]
        [emit-entry : bool (build-package-kind-entry? kind)]
        (match (compiler-driver-load-package-file-with-runtime-owned
          entry-path
          target
          stdlib-roots
          manifest-dir
          name
          (struct-get manifest deps)
          emit-entry)
          [(ErrCompilerLoadWithPaths diag)
            (begin
              (print-error (compiler-diagnostic-render diag))
              1)]
          [(OkCompilerLoadWithPaths decls paths _ _)
            (let
              [metadata-link-inputs : SourceToolLinkInputs
                (source-tool-link-inputs-from-decls
                  decls
                  (source-tool-link-inputs-empty))]
              ;; Merge order: manifest all-target/target inputs, source extern
              ;; metadata, then dependency archives (kept positional after the
              ;; requested libraries/args).
              [effective-link-inputs : SourceToolLinkInputs
                (source-tool-link-inputs-merge
                  (source-tool-link-inputs-merge
                    manifest-link-inputs
                    metadata-link-inputs)
                  dep-link-inputs)]
              [crt-entry : bool
                (and
                  emit-entry
                  (source-tool-linux-crt-entry? target effective-link-inputs))]
              (match (compiler-driver-emit-package-loaded
                ""
                target
                true
                opt-level
                mode
                emit-entry
                crt-entry
                decls
                paths)
                [(ErrCompilerDriver diag)
                  (begin
                    (print-error (compiler-diagnostic-render diag))
                    1)]
                [(OkCompilerDriver asm)
                  (match (source-tool-write-file
                    asm-path
                    (source-tool-augment-assembly-for-target asm target)
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
                        effective-link-inputs
                        (build-package-try-linux-direct-object
                          kind
                          target
                          opt-level
                          mode
                          emit-entry
                          crt-entry
                          decls
                          paths
                          obj-path
                          artifact-path
                          effective-link-inputs))
                        [(SourceToolCommandErr message)
                          (begin
                            (print-error message)
                            1)]
                        [(SourceToolCommandOk)
                          (match (build-package-write-tlci tlci-path manifest)
                            [(SourceToolCommandErr message)
                              (begin
                                (print-error message)
                                1)]
                            [(SourceToolCommandOk)
                              (begin
                                (print-string
                                  (string-append
                                    "Built "
                                    (string-append artifact-path "\n")))
                                (print-string
                                  (string-append
                                    "Built "
                                    (string-append tlci-path "\n")))
                                0)])])])]))])))))

(define (build-package-worker-unified-cli?) : bool
  (and (> (arg-count) 1) (string-eq (arg 1) "build")))

(define (build-package-worker-command-prefix [args : ProcessStringList]) : ProcessStringList
  (if (build-package-worker-unified-cli?)
    (source-tool-args-append args "build")
    args))

(define (build-package-worker-append-option
  [args : ProcessStringList]
  [flag : String]
  [value : String]) : ProcessStringList
  (source-tool-args-append (source-tool-args-append args flag) value))

(define (build-package-worker-append-stdlib-roots
  [args : ProcessStringList]
  [roots : StringVec]) : ProcessStringList
  (let
    [i : i64 0]
    [n : i64 (string-vec-len roots)]
    [out : ProcessStringList args]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (build-package-worker-append-option
              out
              "--stdlib-root"
              (string-vec-get roots i "")))
          (set! i (+ i 1))))
      out)))

(define (build-package-worker-args
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : ProcessStringList
  (let
    [args0 : ProcessStringList
      (build-package-worker-command-prefix (process-args-empty))]
    [args1 : ProcessStringList
      (source-tool-args-append args0 "--package-worker")]
    [args2 : ProcessStringList
      (build-package-worker-append-option args1 "--manifest-path" manifest-path)]
    [args3 : ProcessStringList
      (build-package-worker-append-option
        args2
        "--target"
        (source-tool-target-name target))]
    [args4 : ProcessStringList
      (build-package-worker-append-option
        args3
        "--backend-mode"
        (build-backend-mode-name mode))]
    [args5 : ProcessStringList
      (build-package-worker-append-option
        args4
        "--profile"
        (build-profile-name profile))]
    [args6 : ProcessStringList
      (build-package-worker-append-option
        args5
        "--opt-level"
        (int->string opt-level))]
    [args7 : ProcessStringList
      (build-package-lock-policy-arg args6 lock-policy)]
    (build-package-worker-append-stdlib-roots args7 stdlib-roots)))

(define (build-package-worker-command
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : ProcessCommand
  (process-command
    (arg 0)
    (build-package-worker-args
      manifest-path
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots)))

(define (build-package-worker-run-from [idx : i64] [count : i64]) : i64
  (match (build-package-worker-config-from idx count)
    [(ErrBuildPackageWorkerConfig message)
      (begin
        (print-error message)
        1)]
    [(OkBuildPackageWorkerConfig config)
      (let
        [manifest-path : String (struct-get config manifest-path)]
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-load-manifest normalized-path)
          [(ErrBuildManifest message)
            (begin
              (print-error (string-append "Error: " message))
              1)]
          [(OkBuildManifest manifest)
            (match (build-package-resolve-manifest-deps
              normalized-path
              manifest
              (struct-get config lock-policy))
              [(ErrBuildManifest message)
                (begin
                  (print-error message)
                  1)]
              [(OkBuildManifest resolved-manifest)
                (if (build-package-kind-lib?
                  (struct-get resolved-manifest kind))
                  (build-package-emit-one
                    normalized-path
                    resolved-manifest
                    (struct-get config target)
                    (struct-get config opt-level)
                    (struct-get config profile)
                    (struct-get config mode)
                    (struct-get config stdlib-roots)
                    (process-args-empty))
                  (begin
                    (print-error
                      "build: package worker can only build staticlib packages")
                    1))])]))]))

(define (build-package-async-process-supported?) : bool
  (not (string-eq (env-path-list-separator) ";")))

(define (build-package-deps-built?
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [built : StringI64Map]) : bool
  (match deps
    [(CompilerPkgDepNil) true]
    [(CompilerPkgDepCons dep rest)
      (let
        [dep-manifest-path : String
          (build-package-dep-manifest-path manifest-dir dep)]
        (match (string-i64-map-get built dep-manifest-path)
          [(StringI64MapFound _)
            (build-package-deps-built? manifest-dir (box-get rest) built)]
          [(StringI64MapMissing) false]))]))

(define (build-package-node-ready?
  [node : BuildPackageGraphNode]
  [built : StringI64Map]) : bool
  (let
    [manifest-path : String (struct-get node manifest-path)]
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    [manifest : CompilerPkgManifest (struct-get node manifest)]
    (build-package-deps-built?
      manifest-dir
      (compiler-pkg-deps-list (struct-get manifest deps))
      built)))

(define (build-package-node-scheduled?
  [scheduled : StringI64Map]
  [manifest-path : String]) : bool
  (match (string-i64-map-get scheduled manifest-path)
    [(StringI64MapFound _) true]
    [(StringI64MapMissing) false]))

(define (build-package-graph-worker-vec-len [v : BuildPackageGraphWorkerVec]) : i64
  (struct-get v len))

(define (build-package-graph-worker-vec-capacity
  [v : BuildPackageGraphWorkerVec]) : i64
  (array-length (struct-get v slots)))

(define (build-package-graph-worker-vec-with-capacity [capacity : i64]) : BuildPackageGraphWorkerVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (BuildPackageGraphWorkerVec (make-array BuildPackageGraphWorker cap) 0)))

(define (build-package-graph-worker-vec-new) : BuildPackageGraphWorkerVec
  (build-package-graph-worker-vec-with-capacity 4))

(define (build-package-graph-worker-vec-at
  [v : BuildPackageGraphWorkerVec]
  [index : i64]) : BuildPackageGraphWorker
  (array-ref (struct-get v slots) index))

(define (build-package-graph-worker-vec-copy-range!
  [dst : (Array BuildPackageGraphWorker)]
  [src : (Array BuildPackageGraphWorker)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (build-package-graph-worker-vec-grow [v : BuildPackageGraphWorkerVec]) : BuildPackageGraphWorkerVec
  (let
    [count : i64 (build-package-graph-worker-vec-len v)]
    [bigger : (Array BuildPackageGraphWorker)
      (make-array
        BuildPackageGraphWorker
        (* (build-package-graph-worker-vec-capacity v) 2))]
    (begin
      (build-package-graph-worker-vec-copy-range!
        bigger
        (struct-get v slots)
        count)
      (BuildPackageGraphWorkerVec bigger count))))

(define (build-package-graph-worker-vec-push
  [v : BuildPackageGraphWorkerVec]
  [worker : BuildPackageGraphWorker]) : BuildPackageGraphWorkerVec
  (if (<
    (build-package-graph-worker-vec-len v)
    (build-package-graph-worker-vec-capacity v))
    (let
      [slots : (Array BuildPackageGraphWorker) (struct-get v slots)]
      (begin
        (array-set! slots (build-package-graph-worker-vec-len v) worker)
        (BuildPackageGraphWorkerVec
          slots
          (+ (build-package-graph-worker-vec-len v) 1))))
    (build-package-graph-worker-vec-push
      (build-package-graph-worker-vec-grow v)
      worker)))

(define (build-package-graph-worker-vec-empty?
  [items : BuildPackageGraphWorkerVec]) : bool
  (<= (build-package-graph-worker-vec-len items) 0))

(define (build-package-start-worker
  [node : BuildPackageGraphNode]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : ResultBuildPackageGraphWorker
  (let
    [manifest-path : String (struct-get node manifest-path)]
    [manifest : CompilerPkgManifest (struct-get node manifest)]
    [name : String (struct-get manifest name)]
    [command : ProcessCommand
      (build-package-worker-command
        manifest-path
        target
        opt-level
        profile
        mode
        lock-policy
        stdlib-roots)]
    (match (process-start command)
      [(OkProcessChild child)
        (OkBuildPackageGraphWorker (BuildPackageGraphWorker node child))]
      [(ErrProcessChild error)
        (ErrBuildPackageGraphWorker
          (string-append
            "build: failed to start package dependency `"
            (string-append
              name
              (string-append "`: " (process-error-message error)))))])))

(define (build-package-schedule-pass
  [nodes : BuildPackageGraphNodeVec]
  [scheduled : StringI64Map]
  [built : StringI64Map]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]
  [workers : BuildPackageGraphWorkerVec]) : ResultBuildPackageSchedulePass
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [next-scheduled : StringI64Map scheduled]
    [next-workers : BuildPackageGraphWorkerVec workers]
    [ok : bool true]
    [error-message : String ""]
    (begin
      (while (and ok (< index count))
        (let
          [node : BuildPackageGraphNode
            (build-package-graph-node-vec-at nodes index)]
          [manifest-path : String (struct-get node manifest-path)]
          (begin
            (if (build-package-node-scheduled? next-scheduled manifest-path)
              unit
              (if (build-package-node-ready? node built)
                (match (build-package-start-worker
                  node
                  target
                  opt-level
                  profile
                  mode
                  lock-policy
                  stdlib-roots)
                  [(ErrBuildPackageGraphWorker message)
                    (begin
                      (set! ok false)
                      (set! error-message message))]
                  [(OkBuildPackageGraphWorker worker)
                    (begin
                      (set!
                        next-scheduled
                        (string-i64-map-put next-scheduled manifest-path 1))
                      (set!
                        next-workers
                        (build-package-graph-worker-vec-push
                          next-workers
                          worker)))])
                unit))
            (set! index (+ index 1)))))
      (if ok
        (OkBuildPackageSchedulePass
          (BuildPackageSchedulePass next-scheduled next-workers))
        (ErrBuildPackageSchedulePass error-message)))))

(define (build-package-all-built?
  [nodes : BuildPackageGraphNodeVec]
  [built : StringI64Map]) : bool
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [all-built : bool true]
    (begin
      (while (and all-built (< index count))
        (let
          [node : BuildPackageGraphNode
            (build-package-graph-node-vec-at nodes index)]
          [manifest-path : String (struct-get node manifest-path)]
          (begin
            (match (string-i64-map-get built manifest-path)
              [(StringI64MapFound _) unit]
              [(StringI64MapMissing) (set! all-built false)])
            (set! index (+ index 1)))))
      all-built)))

(define (build-package-failure-status [failed-status : i64] [status : i64]) : i64
  (if (= failed-status 0)
    status
    failed-status))

(define (build-package-wait-workers-with
  [workers : BuildPackageGraphWorkerVec]
  [built : StringI64Map]
  [failed-status : i64]) : ResultBuildPackageWait
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-worker-vec-len workers)]
    [next-built : StringI64Map built]
    [next-failed-status : i64 failed-status]
    (begin
      (while (< index count)
        (let
          [worker : BuildPackageGraphWorker
            (build-package-graph-worker-vec-at workers index)]
          [node : BuildPackageGraphNode (struct-get worker node)]
          [manifest-path : String (struct-get node manifest-path)]
          [manifest : CompilerPkgManifest (struct-get node manifest)]
          [name : String (struct-get manifest name)]
          [result : ResultProcessOutput
            (process-wait (struct-get worker child))]
          (begin
            (match result
              [(OkProcessOutput output)
                (begin
                  (source-tool-forward-output output)
                  (if (process-success? output)
                    (set!
                      next-built
                      (string-i64-map-put next-built manifest-path 1))
                    (let
                      [status : i64 (process-output-status output)]
                      (begin
                        (print-error
                          (string-append
                            "build: package dependency `"
                            (string-append
                              name
                              (string-append
                                "` failed with status "
                                (int->string status)))))
                        (set!
                          next-failed-status
                          (build-package-failure-status
                            next-failed-status
                            status))))))]
              [(ErrProcessOutput error)
                (begin
                  (print-error
                    (string-append
                      "build: failed to wait for package dependency `"
                      (string-append
                        name
                        (string-append "`: " (process-error-message error)))))
                  (set!
                    next-failed-status
                    (build-package-failure-status next-failed-status 1)))])
            (set! index (+ index 1)))))
      (if (= next-failed-status 0)
        (OkBuildPackageWait next-built)
        (ErrBuildPackageWait next-failed-status)))))

(define (build-package-wait-workers
  [workers : BuildPackageGraphWorkerVec]
  [built : StringI64Map]) : ResultBuildPackageWait
  (build-package-wait-workers-with workers built 0))

(define (build-package-emit-graph-nodes-parallel-loop
  [nodes : BuildPackageGraphNodeVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]
  [scheduled : StringI64Map]
  [built : StringI64Map]) : i64
  (if (build-package-all-built? nodes built)
    0
    (match (build-package-schedule-pass
      nodes
      scheduled
      built
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots
      (build-package-graph-worker-vec-with-capacity
        (build-package-graph-node-vec-len nodes)))
      [(ErrBuildPackageSchedulePass message)
        (begin
          (print-error message)
          1)]
      [(OkBuildPackageSchedulePass pass)
        (let
          [workers : BuildPackageGraphWorkerVec (struct-get pass workers)]
          (if (build-package-graph-worker-vec-empty? workers)
            (begin
              (print-error
                "build: package dependency scheduler made no progress")
              1)
            (match (build-package-wait-workers workers built)
              [(ErrBuildPackageWait status) status]
              [(OkBuildPackageWait next-built)
                (build-package-emit-graph-nodes-parallel-loop
                  nodes
                  target
                  opt-level
                  profile
                  mode
                  lock-policy
                  stdlib-roots
                  (struct-get pass scheduled)
                  next-built)])))])))

(define (build-package-emit-graph-nodes-parallel
  [nodes : BuildPackageGraphNodeVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : i64
  (build-package-emit-graph-nodes-parallel-loop
    nodes
    target
    opt-level
    profile
    mode
    lock-policy
    stdlib-roots
    (string-i64-map-with-capacity 32)
    (string-i64-map-with-capacity 32)))

(define (build-package-emit-graph-nodes-serial
  [nodes : BuildPackageGraphNodeVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : i64
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [status : i64 0]
    (begin
      (while (and (= status 0) (< index count))
        (let
          [node : BuildPackageGraphNode
            (build-package-graph-node-vec-at nodes index)]
          [manifest-path : String (struct-get node manifest-path)]
          [manifest : CompilerPkgManifest (struct-get node manifest)]
          [node-status : i64
            (build-package-emit-one
              manifest-path
              manifest
              target
              opt-level
              profile
              mode
              stdlib-roots
              (process-args-empty))]
          (if (= node-status 0)
            (set! index (+ index 1))
            (begin
              (print-error
                (string-append
                  "build: package dependency `"
                  (string-append
                    (struct-get manifest name)
                    (string-append
                      "` failed with status "
                      (int->string node-status)))))
              (set! status node-status)))))
      status)))

(define (build-package-emit-graph-nodes
  [nodes : BuildPackageGraphNodeVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : i64
  (if (build-package-async-process-supported?)
    (build-package-emit-graph-nodes-parallel
      nodes
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots)
    (build-package-emit-graph-nodes-serial
      nodes
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots)))

(define (build-doctest-report [report : DocTestRunReport]) : i64
  (if (doc-test-run-report-ok? report)
    0
    (begin
      (print-error (doc-test-run-report-render report))
      1)))

(define (build-doctest-typecheck-file
  [source : String]
  [stdlib-roots : StringVec]) : i64
  (match (try-read-file (& source))
    [(ErrIoString _) 0]
    [(OkIoString text)
      (build-doctest-report
        (doc-test-typecheck-source-with-roots source text stdlib-roots))]))

(define (build-doctest-typecheck-package-source
  [source : String]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : i64
  (build-doctest-report
    (doc-test-typecheck-package-file-with-roots
      source
      stdlib-roots
      manifest-dir
      deps)))

(define (build-doctest-typecheck-package-sources-from
  [sources : StringVec]
  [index : i64]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : i64
  (if (>= index (string-vec-len sources))
    0
    (let
      [source : String (string-vec-get sources index "")]
      [status : i64
        (build-doctest-typecheck-package-source
          source
          stdlib-roots
          manifest-dir
          deps)]
      (if (= status 0)
        (build-doctest-typecheck-package-sources-from
          sources
          (+ index 1)
          stdlib-roots
          manifest-dir
          deps)
        status))))

(define (build-doctest-typecheck-package-sources
  [sources : StringVec]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : i64
  (build-doctest-typecheck-package-sources-from
    sources
    0
    stdlib-roots
    manifest-dir
    deps))

(define (build-doctest-typecheck-package
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [stdlib-roots : StringVec]) : i64
  (match (package-source-discover-for "build" manifest-path true)
    [(ErrPackageSourceSet message)
      (begin
        (print-error message)
        1)]
    [(OkPackageSourceSet source-set)
      (build-doctest-typecheck-package-sources
        (struct-get source-set sources)
        stdlib-roots
        (struct-get source-set manifest-dir)
        (struct-get manifest deps))]))

(define (build-doctest-build-source
  [source : String]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : i64
  (let
    [doctest-status : i64 (build-doctest-typecheck-file source stdlib-roots)]
    (if (= doctest-status 0)
      (begin
        (compiler-driver-reset-file-state!)
        (source-tool-build-source
          source
          output
          has-output
          target
          stdlib-roots
          opt-level
          mode
          link-inputs))
      doctest-status)))

(define (build-package-emit
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : i64
  (match (build-parse-target target-text)
    [(ErrBuildTarget message)
      (begin
        (print-error message)
        1)]
    [(OkBuildTarget target)
      (let
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-package-resolve-manifest-deps
          normalized-path
          manifest
          lock-policy)
          [(ErrBuildManifest message)
            (begin
              (print-error message)
              1)]
          [(OkBuildManifest resolved-manifest)
            (let
              [doctest-status : i64
                (build-doctest-typecheck-package
                  normalized-path
                  resolved-manifest
                  stdlib-roots)]
              (if (= doctest-status 0)
                (match (build-package-dependency-graph
                  normalized-path
                  resolved-manifest
                  lock-policy)
                  [(ErrBuildPackageGraph message)
                    (begin
                      (print-error message)
                      1)]
                  [(OkBuildPackageGraph graph)
                    (let
                      [nodes : BuildPackageGraphNodeVec
                        (struct-get graph order)]
                      [dep-status : i64
                        (build-package-emit-graph-nodes
                          nodes
                          target
                          opt-level
                          profile
                          mode
                          lock-policy
                          stdlib-roots)]
                      (if (= dep-status 0)
                        (build-package-emit-one
                          normalized-path
                          resolved-manifest
                          target
                          opt-level
                          profile
                          mode
                          stdlib-roots
                          (build-package-graph-link-libs nodes profile target))
                        dep-status))])
                doctest-status))]))]))

(define (build-package-from-path
  [manifest-path : String]
  [target-text : String]
  [has-target : bool]
  [mode : String]
  [opt-level : i64]
  [profile : BuildProfile]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : StringVec]) : i64
  (match (source-tool-backend-mode "build" mode)
    [(ErrSourceToolBackendMode message)
      (begin
        (print-error message)
        1)]
    [(OkSourceToolBackendMode backend-mode)
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
            profile
            backend-mode
            lock-policy
            stdlib-roots)])]))

(define (build-package [config : BuildConfig]) : i64
  (match config
    [(BuildPackageConfig
        manifest-path
        has-manifest
        target-text
        has-target
        mode
        profile
        _
        opt-level
        lock-policy
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
              profile
              lock-policy
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
        [(BuildPackageConfig _ _ _ _ _ _ _ _ _ _) (build-package config)])]
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
  (str-cat "build: unknown target " value ""))

(define (build-cli-unknown-opt-level [value : String]) : String
  (str-cat "build: unknown opt level " value "; expected 0, 1, or 2"))

(defenum BuildCliOption
  (BuildCliOptionOutput)
  (BuildCliOptionStdlibRoot)
  (BuildCliOptionTarget)
  (BuildCliOptionBackendMode)
  (BuildCliOptionOptLevel)
  (BuildCliOptionProfile)
  (BuildCliOptionRelease)
  (BuildCliOptionLinkLib)
  (BuildCliOptionLinkSearch)
  (BuildCliOptionLinkArg)
  (BuildCliOptionManifestPath)
  (BuildCliOptionLocked)
  (BuildCliOptionUpdateLock)
  (BuildCliOptionOther))

(define (build-cli-option-rest6 [current : String]) : BuildCliOption
  (cond
    (string-eq current "--link-arg")
    (BuildCliOptionLinkArg)
    (string-eq current "--manifest-path")
    (BuildCliOptionManifestPath)
    (string-eq current "--locked")
    (BuildCliOptionLocked)
    (string-eq current "--update-lock")
    (BuildCliOptionUpdateLock)
    (BuildCliOptionOther)))

(define (build-cli-option-rest5 [current : String]) : BuildCliOption
  (if (string-eq current "--link-search")
    (BuildCliOptionLinkSearch)
    (build-cli-option-rest6 current)))

(define (build-cli-option-rest4 [current : String]) : BuildCliOption
  (if (string-eq current "--link-lib")
    (BuildCliOptionLinkLib)
    (build-cli-option-rest5 current)))

(define (build-cli-option-rest3 [current : String]) : BuildCliOption
  (if (string-eq current "--release")
    (BuildCliOptionRelease)
    (build-cli-option-rest4 current)))

(define (build-cli-option-rest-profile [current : String]) : BuildCliOption
  (if (string-eq current "--profile")
    (BuildCliOptionProfile)
    (build-cli-option-rest3 current)))

(define (build-cli-option-rest-opt [current : String]) : BuildCliOption
  (if (string-eq current "--opt-level")
    (BuildCliOptionOptLevel)
    (build-cli-option-rest-profile current)))

(define (build-cli-option-rest2 [current : String]) : BuildCliOption
  (if (string-eq current "--backend-mode")
    (BuildCliOptionBackendMode)
    (build-cli-option-rest-opt current)))

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
        [(BuildCliOptionRelease) (build-args-have-source? (+ idx 1) count)]
        [(BuildCliOptionLocked) (build-args-have-source? (+ idx 1) count)]
        [(BuildCliOptionUpdateLock) (build-args-have-source? (+ idx 1) count)]
        [_ (build-args-have-source? (+ idx 2) count)]))))

(define (build-cli-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [stdlib-roots : StringVec]
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
          mode
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
                mode
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
              mode
              (string-vec-push stdlib-roots (arg (+ idx 1)))
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
                    mode
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
                [(OkSourceToolBackendMode parsed-mode)
                  (build-cli-parse-options
                    (+ idx 2)
                    count
                    source
                    has-source
                    output
                    has-output
                    target
                    parsed-mode
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
                  mode
                  stdlib-roots
                  (string->int value)
                  link-inputs)
                (ErrBuildCliConfig (build-cli-unknown-opt-level value)))))]
        [(BuildCliOptionProfile)
          (ErrBuildCliConfig
            "build: --profile is only valid for package builds")]
        [(BuildCliOptionRelease)
          (ErrBuildCliConfig
            "build: --release is only valid for package builds")]
        [(BuildCliOptionLocked)
          (ErrBuildCliConfig "build: --locked is only valid for package builds")]
        [(BuildCliOptionUpdateLock)
          (ErrBuildCliConfig
            "build: --update-lock is only valid for package builds")]
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
              mode
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
              mode
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
              mode
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
                mode
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
    (BackendModeScalar)
    (string-vec-new)
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
            mode
            stdlib-roots
            opt-level
            link-inputs)
          (build-doctest-build-source
            source
            output
            has-output
            target
            stdlib-roots
            opt-level
            mode
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
            mode
            stdlib-roots
            opt-level
            link-inputs)
          (build-doctest-build-source
            source
            output
            has-output
            target
            stdlib-roots
            opt-level
            mode
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
  (cond
    (and (> count start) (string-eq (arg start) "--package-worker"))
    (build-package-worker-run-from (+ start 1) count)
    (and (> count start) (string-eq (arg start) "--direct"))
    (build-direct-from (+ start 1) count)
    (build-direct-from start count)))