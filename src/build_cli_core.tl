;; build_cli_core.tl - Selfhost build command logic.
;;
;; Source-file builds assemble and link in-process through stdlib fs/process
;; helpers. Package builds are handled in-process by the selfhost compiler:
;; parse/discover `typelisp.pkg`, emit assembly for the manifest entry, and
;; produce the package artifact selected by manifest kind.
(import stdlib.fs)
(import stdlib.env)
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.hashmap)
(import stdlib.vector)
(import (hashmap String i64) as build_string_i64_map)
(import (vector.vector String) as cli_svec)
(import "host_plan.tl")
(import "build_run_core.tl")
(import "doc_test.tl")
(import "test_cli_core.tl")
(import "package_source_core.tl")
(import "package_cache_core.tl")
(import "package_lock_core.tl")
(import (vector.vector PackageLockEntry core) as package_lock_entry_vec)
(import "compiler_diagnostic.tl")
(import "compiler_parse_core.tl")
(import "compiler_driver_core.tl")
(import "compiler_typecheck_api.tl")
(import "tlci_core.tl")
(import sym_i64_env)

(defenum BuildConfig
  (Source String bool String bool String String String String)
  (Package
    String
    bool
    String
    bool
    String
    BuildProfile
    bool
    i64
    BuildPackageLockPolicy
    cli_svec.Vec))

(defenum ResultBuildConfig
  (Ok BuildConfig)
  (Err String))

(defenum BuildCliConfig
  (Config
    String
    bool
    String
    bool
    CompilerBackendTarget
    CompilerBackendMode
    cli_svec.Vec
    i64
    SourceToolLinkInputs))

(defenum ResultBuildCliConfig
  (Ok BuildCliConfig)
  (Err String))

(defenum ResultBuildTarget
  (Ok CompilerBackendTarget)
  (Err String))

(defenum ResultBuildManifest
  (Ok CompilerPkgManifest)
  (Err String))

(defstruct BuildPackageGraphNode
  (manifest-path String)
  (manifest CompilerPkgManifest))

(defstruct BuildPackageArtifactPaths
  (runtime String)
  (tlci String))

(defenum BuildPackageArtifactState
  (Clean)
  (Missing)
  (Stale String))

(defstruct BuildPackageGraphNodeVec
  (slots (Array BuildPackageGraphNode))
  (len i64))

(defstruct BuildPackageGraph
  (order BuildPackageGraphNodeVec))

(defstruct BuildPackageGraphState
  (seen build_string_i64_map.Map)
  (order BuildPackageGraphNodeVec))

(defenum ResultBuildPackageGraph
  (Ok BuildPackageGraph)
  (Err String))

(defenum ResultBuildPackageGraphState
  (Ok BuildPackageGraphState)
  (Err String))

(defenum ResultBuildPackageGraphNode
  (Ok BuildPackageGraphNode)
  (Err String))

(defenum ResultBuildPkgDep
  (Ok CompilerPkgDep)
  (Err String))

(defenum ResultBuildPkgDepList
  (Ok CompilerPkgDepList)
  (Err String))

(defstruct BuildGitDependency
  (remote String)
  (pin-kind String)
  (pin-value String))

(defstruct BuildResolvedGitDependency
  (dep-root String)
  (lock-entry PackageLockEntry))

(defenum ResultBuildGitDependency
  (Ok BuildGitDependency)
  (Err String))

(defenum ResultBuildResolvedGitDependency
  (Ok BuildResolvedGitDependency)
  (Err String))

(defenum ResultBuildString
  (Ok String)
  (Err String))

(defenum BuildMaybeLockEntry
  (No)
  (Some PackageLockEntry))

(defstruct BuildPackageLockState
  (path String)
  (entries package_lock_entry_vec.Vec)
  (has-lock bool))

(defenum ResultBuildPackageLockState
  (Ok BuildPackageLockState)
  (Err String))

(defstruct BuildResolvedPkgDep
  (dep CompilerPkgDep)
  (lock-entry BuildMaybeLockEntry))

(defenum ResultBuildResolvedPkgDep
  (Ok BuildResolvedPkgDep)
  (Err String))

(defstruct BuildResolvedPkgDeps
  (deps CompilerPkgDepList)
  (lock-entries package_lock_entry_vec.Vec)
  (has-remote bool))

(defenum ResultBuildResolvedPkgDeps
  (Ok BuildResolvedPkgDeps)
  (Err String))

;; This remains a recursive list intentionally: it is a DFS call stack used
;; only for cycle diagnostics, where push/pop follows recursion depth rather
;; than append-heavy builder behavior.
(defenum BuildPackagePathList
  (Nil)
  (Cons String (Box BuildPackagePathList)))

(defstruct BuildPackageWorkerConfig
  (manifest-path String)
  (has-manifest bool)
  (target CompilerBackendTarget)
  (mode CompilerBackendMode)
  (profile BuildProfile)
  (opt-level i64)
  (lock-policy BuildPackageLockPolicy)
  (stdlib-roots cli_svec.Vec)
  (resolved-deps CompilerPkgDepList))

(defenum ResultBuildPackageWorkerConfig
  (Ok BuildPackageWorkerConfig)
  (Err String))

(defstruct BuildPackageGraphWorker
  (node BuildPackageGraphNode)
  (artifacts BuildPackageArtifactPaths)
  (child process.ProcessChild))

(defenum ResultBuildPackageGraphWorker
  (Ok BuildPackageGraphWorker)
  (Err String))

(defstruct BuildPackageGraphWorkerVec
  (slots (Array BuildPackageGraphWorker))
  (len i64))

(defstruct BuildPackageSchedulePass
  (scheduled build_string_i64_map.Map)
  (workers BuildPackageGraphWorkerVec))

(defenum ResultBuildPackageSchedulePass
  (Ok BuildPackageSchedulePass)
  (Err String))

(defenum ResultBuildPackageWait
  (Ok build_string_i64_map.Map)
  (Err i64))

(defenum BuildProfile
  (Dev)
  (Release))

(defenum BuildPackageLockPolicy
  (Default)
  (Locked)
  (Update))

(defenum BuildPackageLockEntryStatus
  (Matched PackageLockEntry)
  (Missing)
  (Stale))

(defenum ResultBuildProfile
  (Ok BuildProfile)
  (Err String))

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

(define (build-string-i64-map-put
  [map : build_string_i64_map.Map]
  [key : String]
  [value : i64]) : build_string_i64_map.Map
  (let
    [out : build_string_i64_map.Map map]
    (begin
      (build_string_i64_map.insert-ref! (&mut out) key value)
      out)))

(define (build-invalid-manifest-message [diag : CompilerDiagnostic]) : String
  (str_cat.str-cat
    "invalid package manifest '"
    (compiler-diagnostic-path diag)
    "': "
    (compiler-diagnostic-message diag)))

(define (build-unknown-target [value : String]) : String
  (str_cat.str-cat "build: unknown target " value ""))

(define (build-unknown-mode [value : String]) : String
  (str_cat.str-cat "build: unknown backend mode " value ""))

(define (build-unknown-opt-level [value : String]) : String
  (str_cat.str-cat "build: unknown opt level '" value "'; expected 0, 1, or 2"))

(define (build-unknown-profile [value : String]) : String
  (str_cat.str-cat
    "build: unknown profile '"
    value
    "'; expected dev or release"))

(define (build-default-profile) : BuildProfile
  (BuildProfile.Release))

(define (build-profile-name [profile : BuildProfile]) : String
  (match profile
    [(BuildProfile.Dev) "dev"]
    [(BuildProfile.Release) "release"]))

(define (build-backend-mode-name [mode : CompilerBackendMode]) : String
  (match mode
    [(CompilerBackendMode.Scalar) "scalar"]
    [(CompilerBackendMode.Avx2) "avx2"]
    [(CompilerBackendMode.Avx512) "avx512"]))

(define (build-profile-default-opt-level [profile : BuildProfile]) : i64
  (match profile
    [(BuildProfile.Dev) 0]
    [(BuildProfile.Release) build-package-release-opt-level]))

(define (build-package-default-opt-level) : i64
  (build-profile-default-opt-level (build-default-profile)))

(define (build-package-profile-opt-level-smoke-ok?) : bool
  (and
    (= (build-profile-default-opt-level (BuildProfile.Release)) 2)
    (= (build-profile-default-opt-level (BuildProfile.Dev)) 0)
    (= (build-package-default-opt-level) 2)))

(test
  build-package-profile-opt-level-smoke
  (unless
    (build-package-profile-opt-level-smoke-ok?)
    (io.panic "build package profile opt-level smoke failed")))

(define (build-parse-profile [value : String]) : ResultBuildProfile
  (if (string.eq value "dev")
    (ResultBuildProfile.Ok (BuildProfile.Dev))
    (if (string.eq value "release")
      (ResultBuildProfile.Ok (BuildProfile.Release))
      (ResultBuildProfile.Err (build-unknown-profile value)))))

(define (build-package-lock-policy-provided? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(BuildPackageLockPolicy.Default) false]
    [_ true]))

(define (build-package-lock-policy-locked? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(BuildPackageLockPolicy.Locked) true]
    [_ false]))

(define (build-package-lock-policy-update? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(BuildPackageLockPolicy.Update) true]
    [_ false]))

(define (build-package-lock-policy-option-error) : String
  "build: package lock policy was provided more than once")

(define (build-package-lock-policy-arg
  [args : process.ProcessStringList]
  [policy : BuildPackageLockPolicy]) : process.ProcessStringList
  (match policy
    [(BuildPackageLockPolicy.Locked) (source-tool-args-append args "--locked")]
    [(BuildPackageLockPolicy.Update)
      (source-tool-args-append args "--update-lock")]
    [(BuildPackageLockPolicy.Default) args]))

(define (build-append-stdlib [stdlib-lines : String] [root : String]) : String
  (str_cat.str-cat stdlib-lines (host-plan-netline "stdlib-root" root)))

(define (build-parse-target [value : String]) : ResultBuildTarget
  (if (or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
    (ResultBuildTarget.Ok (CompilerBackendTarget.Linux))
    (if (or
      (string.eq value "windows-x86_64")
      (string.eq value "windows_x86_64"))
      (ResultBuildTarget.Ok (CompilerBackendTarget.Windows))
      (ResultBuildTarget.Err (build-unknown-target value)))))

(define (build-parse-opt-level [value : String]) : i64
  (cond
    [(string.eq value "0") 0]
    [(string.eq value "1") 1]
    [(string.eq value "2") 2]
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
  [profile : BuildProfile]
  [has-profile : bool]
  [opt-level : i64]
  [has-opt-level : bool]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-lines : String]
  [stdlib-roots : cli_svec.Vec]) : ResultBuildConfig
  (if (>= idx count)
    (if has-source
      (begin
        (when
          has-manifest
          (return
            (ResultBuildConfig.Err
              "build: cannot combine a source file with --manifest-path")))
        (ResultBuildConfig.Ok
          (BuildConfig.Source
            source
            has-source
            output
            has-output
            target
            mode
            (if has-opt-level
              (string.int->string opt-level)
              "")
            stdlib-lines)))
      (begin
        (when
          has-output
          (return
            (ResultBuildConfig.Err "build: -o requires a source file argument")))
        (ResultBuildConfig.Ok
          (BuildConfig.Package
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
            stdlib-roots))))
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.eq current "-o")
          (if (>= (+ idx 1) count)
            (ResultBuildConfig.Err "build: -o requires a value")
            (if has-output
              (ResultBuildConfig.Err "build: -o was provided more than once")
              (build-parse-options
                (+ idx 2)
                count
                source
                has-source
                (io.arg (+ idx 1))
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
                stdlib-roots)))]
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultBuildConfig.Err "build: --manifest-path requires a value")
            (if has-manifest
              (ResultBuildConfig.Err
                "build: --manifest-path was provided more than once")
              (build-parse-options
                (+ idx 2)
                count
                source
                has-source
                output
                has-output
                (io.arg (+ idx 1))
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
                stdlib-roots)))]
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultBuildConfig.Err "build: --stdlib-root requires a value")
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
              (build-append-stdlib stdlib-lines (io.arg (+ idx 1)))
              (let
                [next-roots : cli_svec.Vec stdlib-roots]
                (begin
                  (cli_svec.push (&mut next-roots) (io.arg (+ idx 1)))
                  next-roots))))]
        [(string.eq current "--target")
          (if (>= (+ idx 1) count)
            (ResultBuildConfig.Err "build: --target requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
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
                (ResultBuildConfig.Err (build-unknown-target value)))))]
        [(string.eq current "--backend-mode")
          (if (>= (+ idx 1) count)
            (ResultBuildConfig.Err "build: --backend-mode requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
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
                (ResultBuildConfig.Err (build-unknown-mode value)))))]
        [(string.eq current "--profile")
          (if (>= (+ idx 1) count)
            (ResultBuildConfig.Err "build: --profile requires a value")
            (if has-profile
              (ResultBuildConfig.Err
                "build: profile was provided more than once")
              (match (build-parse-profile (io.arg (+ idx 1)))
                [(ResultBuildProfile.Err message)
                  (ResultBuildConfig.Err message)]
                [(ResultBuildProfile.Ok parsed-profile)
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
                    stdlib-roots)])))]
        [(string.eq current "--release")
          (if has-profile
            (ResultBuildConfig.Err "build: profile was provided more than once")
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
              (BuildProfile.Release)
              true
              opt-level
              has-opt-level
              lock-policy
              stdlib-lines
              stdlib-roots))]
        [(string.eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ResultBuildConfig.Err "build: --opt-level requires a value")
            (if has-opt-level
              (ResultBuildConfig.Err
                "build: --opt-level was provided more than once")
              (let
                [value : String (io.arg (+ idx 1))]
                [parsed : i64 (build-parse-opt-level value)]
                (if (< parsed 0)
                  (ResultBuildConfig.Err (build-unknown-opt-level value))
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
                    stdlib-roots)))))]
        [(string.eq current "--locked")
          (if (build-package-lock-policy-provided? lock-policy)
            (ResultBuildConfig.Err (build-package-lock-policy-option-error))
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
              (BuildPackageLockPolicy.Locked)
              stdlib-lines
              stdlib-roots))]
        [(string.eq current "--update-lock")
          (if (build-package-lock-policy-provided? lock-policy)
            (ResultBuildConfig.Err (build-package-lock-policy-option-error))
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
              (BuildPackageLockPolicy.Update)
              stdlib-lines
              stdlib-roots))]
        [(host-plan-flag? current)
          (ResultBuildConfig.Err
            (str_cat.str-cat "build: unknown flag " current))]
        [else
          (if has-source
            (ResultBuildConfig.Err "build: accepts only one source file")
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
              stdlib-roots))]))))

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
    (BuildPackageLockPolicy.Default)
    ""
    (cli_svec.new)))

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
  [stdlib-roots : cli_svec.Vec]
  [resolved-deps : CompilerPkgDepList]) : ResultBuildPackageWorkerConfig
  (if (>= idx count)
    (if has-manifest
      (ResultBuildPackageWorkerConfig.Ok
        (BuildPackageWorkerConfig
          manifest-path
          has-manifest
          target
          mode
          profile
          opt-level
          lock-policy
          stdlib-roots
          (build-package-dep-list-reverse resolved-deps)))
      (ResultBuildPackageWorkerConfig.Err
        "build: --package-worker requires --manifest-path"))
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultBuildPackageWorkerConfig.Err
              "build: --manifest-path requires a value")
            (build-package-worker-parse-options
              (+ idx 2)
              count
              (io.arg (+ idx 1))
              true
              target
              mode
              profile
              opt-level
              has-opt-level
              lock-policy
              stdlib-roots
              resolved-deps))]
        [(string.eq current "--target")
          (if (>= (+ idx 1) count)
            (ResultBuildPackageWorkerConfig.Err
              "build: --target requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (match (source-tool-target value)
                [(ResultSourceToolTarget.Ok parsed-target)
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
                    stdlib-roots
                    resolved-deps)]
                [(ResultSourceToolTarget.Err _)
                  (ResultBuildPackageWorkerConfig.Err
                    (build-cli-unknown-target value))])))]
        [(string.eq current "--backend-mode")
          (if (>= (+ idx 1) count)
            (ResultBuildPackageWorkerConfig.Err
              "build: --backend-mode requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (match (source-tool-backend-mode "build" value)
                [(ResultSourceToolBackendMode.Ok parsed-mode)
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
                    stdlib-roots
                    resolved-deps)]
                [(ResultSourceToolBackendMode.Err message)
                  (ResultBuildPackageWorkerConfig.Err message)])))]
        [(string.eq current "--profile")
          (if (>= (+ idx 1) count)
            (ResultBuildPackageWorkerConfig.Err
              "build: --profile requires a value")
            (match (build-parse-profile (io.arg (+ idx 1)))
              [(ResultBuildProfile.Err message)
                (ResultBuildPackageWorkerConfig.Err message)]
              [(ResultBuildProfile.Ok parsed-profile)
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
                    stdlib-roots
                    resolved-deps))]))]
        [(string.eq current "--release")
          (build-package-worker-parse-options
            (+ idx 1)
            count
            manifest-path
            has-manifest
            target
            mode
            (BuildProfile.Release)
            (if has-opt-level
              opt-level
              (build-profile-default-opt-level (BuildProfile.Release)))
            has-opt-level
            lock-policy
            stdlib-roots
            resolved-deps)]
        [(string.eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ResultBuildPackageWorkerConfig.Err
              "build: --opt-level requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (if (source-tool-opt-level-valid? value)
                (build-package-worker-parse-options
                  (+ idx 2)
                  count
                  manifest-path
                  has-manifest
                  target
                  mode
                  profile
                  (string.>int value)
                  true
                  lock-policy
                  stdlib-roots
                  resolved-deps)
                (ResultBuildPackageWorkerConfig.Err
                  (build-unknown-opt-level value)))))]
        [(string.eq current "--locked")
          (if (build-package-lock-policy-provided? lock-policy)
            (ResultBuildPackageWorkerConfig.Err
              (build-package-lock-policy-option-error))
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
              (BuildPackageLockPolicy.Locked)
              stdlib-roots
              resolved-deps))]
        [(string.eq current "--update-lock")
          (if (build-package-lock-policy-provided? lock-policy)
            (ResultBuildPackageWorkerConfig.Err
              (build-package-lock-policy-option-error))
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
              (BuildPackageLockPolicy.Update)
              stdlib-roots
              resolved-deps))]
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultBuildPackageWorkerConfig.Err
              "build: --stdlib-root requires a value")
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
              (let
                [next-roots : cli_svec.Vec stdlib-roots]
                (begin
                  (cli_svec.push (&mut next-roots) (io.arg (+ idx 1)))
                  next-roots))
              resolved-deps))]
        [(string.eq current "--resolved-dep")
          (if (>= (+ idx 2) count)
            (ResultBuildPackageWorkerConfig.Err
              "build: --resolved-dep requires alias and path")
            (build-package-worker-parse-options
              (+ idx 3)
              count
              manifest-path
              has-manifest
              target
              mode
              profile
              opt-level
              has-opt-level
              lock-policy
              stdlib-roots
              (CompilerPkgDepCons
                (CompilerPkgDep (io.arg (+ idx 1)) (io.arg (+ idx 2)))
                (box resolved-deps))))]
        [(host-plan-flag? current)
          (ResultBuildPackageWorkerConfig.Err
            (str_cat.str-cat "build: unknown package worker flag " current))]
        [else
          (ResultBuildPackageWorkerConfig.Err
            (str_cat.str-cat
              "build: unexpected package worker argument "
              current))]))))

(define (build-package-worker-config-from [idx : i64] [count : i64]) : ResultBuildPackageWorkerConfig
  (build-package-worker-parse-options
    idx
    count
    ""
    false
    (source-tool-default-target)
    (CompilerBackendMode.Scalar)
    (build-default-profile)
    (build-package-default-opt-level)
    false
    (BuildPackageLockPolicy.Default)
    (cli_svec.new)
    CompilerPkgDepNil))

(define (build-source-plan-render [config : BuildConfig]) : String
  (match config
    [(BuildConfig.Source
        source
        _
        output
        has-output
        target
        mode
        opt-level
        stdlib-lines)
      (str_cat.str-cat
        (host-plan-header)
        (host-plan-word-line "action" "build-source")
        (host-plan-netline "source" source)
        (if has-output
          (host-plan-netline "output" output)
          "")
        (host-plan-word-line "target" target)
        (host-plan-word-line "backend-mode" mode)
        (if (string.eq opt-level "")
          ""
          (host-plan-word-line "opt-level" opt-level))
        stdlib-lines
        "end\n")]
    [_ ""]))

(define (build-discover-manifest-up [prefix : String] [fuel : i64]) : CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (str_cat.str-cat prefix "typelisp.pkg")]
      (if (io.file-exists? candidate)
        (CompilerLoadSomePath candidate)
        (build-discover-manifest-up (str_cat.str-cat prefix "../") (- fuel 1))))))

(define (build-load-manifest [manifest-path : String]) : ResultBuildManifest
  (if (io.file-exists? manifest-path)
    (match (compiler-load-parse-manifest-diagnostic-infer-kind
      manifest-path
      (io.read-file manifest-path))
      [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
        (ResultBuildManifest.Ok manifest)]
      [(ResultCompilerPkgManifestDiagnostic.Err diag)
        (ResultBuildManifest.Err
          (build-invalid-manifest-message (box-get diag)))])
    (ResultBuildManifest.Err
      (str_cat.str-cat "cannot read package manifest '" manifest-path "'"))))

(define (build-package-output-dir [manifest-dir : String] [name : String]) : String
  (build-package-output-dir-profile manifest-dir name (build-default-profile)))

(define (build-package-output-dir-profile
  [manifest-dir : String]
  [_name : (& name str)]
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
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat name ".s")))

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
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat name "." (source-tool-object-extension target))))

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
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat name (source-tool-executable-extension target))))

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
    (build-package-output-dir-profile manifest-dir "" profile)
    (source-tool-static-library-filename name target)))

(define (build-package-tlci-path [manifest-dir : String] [name : String]) : String
  (build-package-tlci-path-profile manifest-dir name (build-default-profile)))

(define (build-package-tlci-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : String
  (compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat name ".tlci")))

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

;; The v1 tlci path is target-independent because package images are
;; metadata-only host compile-time interfaces. Runtime artifacts still
;; carry the selected target through their filename/extension.
(define (build-package-artifact-paths
  [manifest-dir : String]
  [name : String]
  [kind : CompilerPkgKind]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : BuildPackageArtifactPaths
  (BuildPackageArtifactPaths
    (build-package-artifact-path-profile manifest-dir name kind profile target)
    (build-package-tlci-path-profile manifest-dir name profile)))

(define (build-package-runtime-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  (struct-get artifacts runtime))

(define (build-package-host-tlci-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  (struct-get artifacts tlci))

(define (build-package-path-layout-smoke-ok?) : bool
  (and
    (string.eq
      (build-package-output-dir-profile "root/app" "pkg" (BuildProfile.Release))
      "root/app/target/release")
    (string.eq
      (build-package-asm-path-profile "root/app" "pkg" (BuildProfile.Dev))
      "root/app/target/dev/pkg.s")
    (string.eq
      (build-package-bin-path-profile
        "root/app"
        "pkg"
        (BuildProfile.Release)
        (CompilerBackendTarget.Windows))
      "root/app/target/release/pkg.exe")
    (string.eq
      (build-package-lib-path-profile
        "root/app"
        "pkg"
        (BuildProfile.Release)
        (CompilerBackendTarget.Linux))
      "root/app/target/release/libpkg.a")
    (string.eq
      (build-package-tlci-path-profile "root/app" "pkg" (BuildProfile.Dev))
      "root/app/target/dev/pkg.tlci")
    (string.eq
      (build-package-host-tlci-artifact-path
        (build-package-artifact-paths
          "root/app"
          "pkg"
          (CompilerPkgKindBin)
          (BuildProfile.Dev)
          (CompilerBackendTarget.Windows)))
      "root/app/target/dev/pkg.tlci")))

(test
  build-package-path-layout-smoke
  (unless
    (build-package-path-layout-smoke-ok?)
    (io.panic "build package path layout smoke failed")))

(define (build-package-artifact-state-dirty?
  [state : BuildPackageArtifactState]) : bool
  (match state
    [(BuildPackageArtifactState.Clean) false]
    [_ true]))

(define (build-package-artifact-state-render
  [state : BuildPackageArtifactState]) : String
  (match state
    [(BuildPackageArtifactState.Clean) "clean"]
    [(BuildPackageArtifactState.Missing) "missing"]
    [(BuildPackageArtifactState.Stale reason) reason]))

(define (build-package-artifact-file-state [path : String]) : BuildPackageArtifactState
  (let
    [path-text : String path]
    (match (fs.try-file-metadata (& path-text))
      [(fs.OkFsMetadata metadata)
        (if (fs.file-kind-regular? (fs.metadata-kind metadata))
          (BuildPackageArtifactState.Clean)
          (BuildPackageArtifactState.Stale "not a regular file"))]
      [(fs.ErrFsMetadata _) (BuildPackageArtifactState.Missing)])))

(define (build-package-artifact-status-error-message
  [package-name : String]
  [role-name : String]
  [path : String]
  [state : BuildPackageArtifactState]) : String
  (str_cat.str-cat
    "build: package dependency `"
    package-name
    "` did not produce "
    role-name
    " artifact "
    path
    ": "
    (build-package-artifact-state-render state)))

(cfg
  test
  (define (build-package-artifact-status-smoke-ok?) : bool
    (and
      (not
        (build-package-artifact-state-dirty? (BuildPackageArtifactState.Clean)))
      (build-package-artifact-state-dirty? (BuildPackageArtifactState.Missing))
      (build-package-artifact-state-dirty?
        (BuildPackageArtifactState.Stale "metadata changed"))
      (string.eq
        (build-package-artifact-state-render
          (BuildPackageArtifactState.Stale "metadata changed"))
        "metadata changed"))))

(cfg
  test
  (test
    build-package-artifact-status-smoke
    (unless
      (build-package-artifact-status-smoke-ok?)
      (io.panic "build package artifact status smoke failed"))))

(define (build-package-kind-lib? [kind : CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindLib) true]
    [_ false]))

(define (build-package-kind-entry? [kind : CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (build-package-dep-list-reverse-onto
  [deps : CompilerPkgDepList]
  [acc : CompilerPkgDepList]) : CompilerPkgDepList
  (match deps
    [(CompilerPkgDepNil) acc]
    [(CompilerPkgDepCons dep rest)
      (build-package-dep-list-reverse-onto
        (box-get rest)
        (CompilerPkgDepCons dep (box acc)))]))

(define (build-package-dep-list-reverse [deps : CompilerPkgDepList]) : CompilerPkgDepList
  (build-package-dep-list-reverse-onto deps CompilerPkgDepNil))

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
  [s : (& s str)]
  [needle : char]
  [i : i64]
  [n : i64]) : i64
  (let
    [pos : i64 (string.index-of-byte s i (cast needle : u8))]
    (if (and (>= pos 0) (< pos n))
      pos
      -1)))

(define (build-github-dep-relative-root [alias : String]) : String
  (str_cat.str-cat "target/typelisp/git-deps/" alias))

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

(defmacro (build-git-dep-error [alias : Expr] [message : Expr]) : Expr
  `(str_cat.str-cat
    "build: GitHub dependency `"
    (string.substring ,alias 0 (string.string-length ,alias))
    "` "
    ,message))

(define (build-parse-git-dependency [alias : String] [path : String]) : ResultBuildGitDependency
  (let
    [n : i64 (string.string-length path)]
    [hash : i64 (build-string-index-from (& path) '#' 0 n)]
    (if (<= hash 0)
      (ResultBuildGitDependency.Err
        (build-git-dep-error alias "has invalid normalized path"))
      (let
        [remote : String (string.substring (& path) 0 hash)]
        [pin : String (string.substring (& path) (+ hash 1) (- n (+ hash 1)))]
        [pin-len : i64 (string.string-length pin)]
        [eq : i64 (build-string-index-from (& pin) '=' 0 pin-len)]
        (if (<= eq 0)
          (ResultBuildGitDependency.Err
            (build-git-dep-error alias "has invalid pin"))
          (let
            [kind : String (string.substring (& pin) 0 eq)]
            [value : String
              (string.substring (& pin) (+ eq 1) (- pin-len (+ eq 1)))]
            [kind-for-check : String (string.copy (& kind))]
            (if (= (string.string-length value) 0)
              (ResultBuildGitDependency.Err
                (build-git-dep-error alias "has empty pin"))
              (if (compiler-load-github-pin-kind-valid? kind-for-check)
                (ResultBuildGitDependency.Ok
                  (BuildGitDependency remote kind value))
                (ResultBuildGitDependency.Err
                  (build-git-dep-error alias "has invalid pin kind"))))))))))

(define (build-git-dep-pin-kind
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : ResultPackageCachePinKind
  (let
    [kind : String (string.copy (& (struct-get dep pin-kind)))]
    (cond
      [(string.eq kind "rev")
        (ResultPackageCachePinKind.Ok (PackageCachePinKind.Rev))]
      [(string.eq kind "tag")
        (ResultPackageCachePinKind.Ok (PackageCachePinKind.Tag))]
      [(string.eq kind "branch")
        (ResultPackageCachePinKind.Ok (PackageCachePinKind.Branch))]
      [else
        (ResultPackageCachePinKind.Err
          (build-git-dep-error alias "has invalid pin kind"))])))

(define (build-package-lock-path [manifest-dir : String]) : String
  (compiler-load-join-root-path manifest-dir "typelisp.lock"))

(define (build-load-package-lock [manifest-dir : String]) : ResultBuildPackageLockState
  (let
    [path : String (build-package-lock-path manifest-dir)]
    (if (io.file-exists? path)
      (match (io.try-read-file (& path))
        [(io.ErrIoString error)
          (ResultBuildPackageLockState.Err
            (str_cat.str-cat
              "build: cannot read package lock '"
              path
              "': "
              (io.error-message error)))]
        [(io.OkIoString source)
          (match (package-lock-parse source)
            [(ResultPackageLockFile.Err message)
              (ResultBuildPackageLockState.Err
                (str_cat.str-cat
                  "build: invalid package lock '"
                  path
                  "': "
                  message))]
            [(ResultPackageLockFile.Ok lock)
              (ResultBuildPackageLockState.Ok
                (BuildPackageLockState path (struct-get lock entries) true))])])
      (ResultBuildPackageLockState.Ok
        (BuildPackageLockState path (package_lock_entry_vec.new) false)))))

(define (build-write-package-lock
  [state : BuildPackageLockState]
  [entries : package_lock_entry_vec.Vec]) : ResultBuildString
  (let
    [lock : PackageLockFile (PackageLockFile package-lock-version entries)]
    [text : String (package-lock-emit lock)]
    [path : String (struct-get state path)]
    (match (io.try-write-file (& path) (& text))
      [(io.OkIoUnit) (ResultBuildString.Ok path)]
      [(io.ErrIoUnit error)
        (ResultBuildString.Err
          (str_cat.str-cat
            "build: cannot write package lock '"
            path
            "': "
            (io.error-message error)))])))

(define (build-package-lock-entry-matches?
  [entry : PackageLockEntry]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : bool
  (match (build-git-dep-pin-kind alias dep)
    [(ResultPackageCachePinKind.Err _) false]
    [(ResultPackageCachePinKind.Ok kind)
      (and
        (string.eq (& (struct-get entry alias)) alias)
        (string.eq (& (struct-get entry url)) (& (struct-get dep remote)))
        (package-cache-pin-kind-eq? (struct-get entry pin-kind) kind)
        (string.eq
          (& (struct-get entry pin-value))
          (& (struct-get dep pin-value))))]))

(define (build-package-lock-matching-entry
  [entries : package_lock_entry_vec.Vec]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : BuildMaybeLockEntry
  (match (package-lock-entry-list-lookup entries alias)
    [(PackageLockMaybeEntry.No) (BuildMaybeLockEntry.No)]
    [(PackageLockMaybeEntry.Some entry)
      (if (build-package-lock-entry-matches? entry alias dep)
        (BuildMaybeLockEntry.Some entry)
        (BuildMaybeLockEntry.No))]))

(define (build-package-lock-entry-status
  [entries : package_lock_entry_vec.Vec]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : BuildPackageLockEntryStatus
  (match (package-lock-entry-list-lookup entries alias)
    [(PackageLockMaybeEntry.No) (BuildPackageLockEntryStatus.Missing)]
    [(PackageLockMaybeEntry.Some entry)
      (if (build-package-lock-entry-matches? entry alias dep)
        (BuildPackageLockEntryStatus.Matched entry)
        (BuildPackageLockEntryStatus.Stale))]))

(define (build-package-lock-missing-message [alias : String]) : String
  (str_cat.str-cat
    "build: --locked requires typelisp.lock entry for remote dependency `"
    alias
    "`; run with --update-lock to refresh typelisp.lock"))

(define (build-package-lock-stale-message [alias : String]) : String
  (str_cat.str-cat
    "build: package lock entry for remote dependency `"
    alias
    "` is stale; run with --update-lock to refresh typelisp.lock"))

(define (build-package-lock-entry
  [alias : String]
  [dep : (& dep BuildGitDependency)]
  [commit : String]) : ResultPackageLockEntry
  (match (build-git-dep-pin-kind alias dep)
    [(ResultPackageCachePinKind.Err message)
      (ResultPackageLockEntry.Err message)]
    [(ResultPackageCachePinKind.Ok kind)
      (ResultPackageLockEntry.Ok
        (PackageLockEntry
          alias
          (string.copy (& (struct-get dep remote)))
          kind
          (string.copy (& (struct-get dep pin-value)))
          commit))]))

(define (build-git-dependency-at-commit
  [dep : (& dep BuildGitDependency)]
  [commit : String]) : BuildGitDependency
  (BuildGitDependency (string.copy (& (struct-get dep remote))) "rev" commit))

(define (build-git-checkout-ref [dep : (& dep BuildGitDependency)]) : String
  (let
    [kind : String (string.copy (& (struct-get dep pin-kind)))]
    (if (string.eq kind "branch")
      (str_cat.str-cat "origin/" (string.copy (& (struct-get dep pin-value))))
      (string.copy (& (struct-get dep pin-value))))))

(define (build-process-output-detail [output : process.ProcessOutput]) : String
  (let
    [stderr : String (process.output-stderr output)]
    [stdout : String (process.output-stdout output)]
    (if (> (string.string-length stderr) 0)
      (str_cat.str-cat ": " stderr)
      (if (> (string.string-length stdout) 0)
        (str_cat.str-cat ": " stdout)
        ""))))

(define (build-run-captured
  [context : String]
  [command : process.ProcessCommand]) : ResultBuildString
  (match (process.output command)
    [(process.OkProcessOutput output)
      (if (process.success? output)
        (ResultBuildString.Ok (process.output-stdout output))
        (ResultBuildString.Err
          (str_cat.str-cat
            context
            " failed with status "
            (string.int->string (process.output-status output))
            (build-process-output-detail output))))]
    [(process.ErrProcessOutput error)
      (ResultBuildString.Err
        (str_cat.str-cat context ": " (process.error-message error)))]))

(define (build-git-clone-command [remote : String] [root : String]) : process.ProcessCommand
  (source-tool-git-clone-command remote root))

(define (build-git-checkout-command [root : String] [checkout-ref : String]) : process.ProcessCommand
  (source-tool-git-checkout-command root checkout-ref))

(define (build-git-rev-parse-command [root : String]) : process.ProcessCommand
  (source-tool-git-rev-parse-command root))

(define (build-trim-command-output [output : String]) : String
  (string.trim (& output)))

(define (build-resolve-git-head [alias : String] [root : String]) : ResultBuildString
  (match (build-run-captured
    (build-git-dep-error alias "git rev-parse")
    (build-git-rev-parse-command root))
    [(ResultBuildString.Err message) (ResultBuildString.Err message)]
    [(ResultBuildString.Ok output)
      (let
        [commit : String (build-trim-command-output output)]
        (if (= (string.string-length commit) 0)
          (ResultBuildString.Err
            (build-git-dep-error alias "resolved commit is empty"))
          (ResultBuildString.Ok commit)))]))

(define (build-absolute-dep-root [manifest-dir : String] [dep-root : String]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path manifest-dir dep-root)))

(define (build-ensure-github-cache-parent
  [manifest-dir : String]
  [alias : String]) : ResultBuildString
  (let
    [target-dir : String
      (compiler-load-join-root-path (string.copy manifest-dir) "target")]
    [typelisp-dir : String
      (compiler-load-join-root-path (string.copy target-dir) "typelisp")]
    [deps-dir : String
      (compiler-load-join-root-path (string.copy typelisp-dir) "git-deps")]
    (cond
      [(not (build-mkdir-ok-owned? (string.copy target-dir)))
        (ResultBuildString.Err
          (build-git-dep-error alias "could not create target directory"))]
      [(not (build-mkdir-ok-owned? (string.copy typelisp-dir)))
        (ResultBuildString.Err
          (build-git-dep-error
            alias
            "could not create target/typelisp directory"))]
      [(not (build-mkdir-ok-owned? (string.copy deps-dir)))
        (ResultBuildString.Err
          (build-git-dep-error
            alias
            "could not create target/typelisp/git-deps directory"))]
      [else (ResultBuildString.Ok deps-dir)])))

(define (build-github-cache-git-dir [manifest-dir : String] [alias : String]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path
      (build-github-dep-cache-root manifest-dir alias)
      ".git")))

(define (build-github-cache-needs-git? [manifest-dir : String] [alias : String]) : bool
  (or
    (not
      (io.file-exists?
        (build-github-dep-cache-manifest-path
          (string.copy manifest-dir)
          (string.copy alias))))
    (io.file-exists? (build-github-cache-git-dir manifest-dir alias))))

(define (build-git-dep-rev? [dep : (& dep BuildGitDependency)]) : bool
  (string.eq (& (struct-get dep pin-kind)) "rev"))

(define (build-package-cache-relative-root) : String
  "target/typelisp/cache/packages/v1")

(define (build-package-cache-manifest-path [entry-path : (& entry-path str)]) : String
  (string.append entry-path "/typelisp.pkg"))

(define (build-ensure-package-cache-root
  [manifest-dir : String]
  [alias : String]) : ResultBuildString
  (let
    [target-dir : String
      (compiler-load-join-root-path (string.copy manifest-dir) "target")]
    [typelisp-dir : String
      (compiler-load-join-root-path (string.copy target-dir) "typelisp")]
    [cache-dir : String
      (compiler-load-join-root-path (string.copy typelisp-dir) "cache")]
    [packages-dir : String
      (compiler-load-join-root-path (string.copy cache-dir) "packages")]
    [root : String (package-cache-default-root manifest-dir)]
    (cond
      [(not (build-mkdir-ok-owned? (string.copy target-dir)))
        (ResultBuildString.Err
          (build-git-dep-error alias "could not create target directory"))]
      [(not (build-mkdir-ok-owned? (string.copy typelisp-dir)))
        (ResultBuildString.Err
          (build-git-dep-error
            alias
            "could not create target/typelisp directory"))]
      [(not (build-mkdir-ok-owned? (string.copy cache-dir)))
        (ResultBuildString.Err
          (build-git-dep-error
            alias
            "could not create target/typelisp/cache directory"))]
      [(not (build-mkdir-ok-owned? (string.copy packages-dir)))
        (ResultBuildString.Err
          (build-git-dep-error
            alias
            "could not create target/typelisp/cache/packages directory"))]
      [(not (build-mkdir-ok-owned? (string.copy root)))
        (ResultBuildString.Err
          (build-git-dep-error
            alias
            "could not create target/typelisp/cache/packages/v1 directory"))]
      [else (ResultBuildString.Ok root)])))

(define (build-package-cache-io-error
  [alias : String]
  [action : String]
  [error : io.IoError]) : String
  (build-git-dep-error
    alias
    (str_cat.str-cat action ": " (io.error-message error))))

(define (build-package-cache-staging-path
  [alias : String]
  [root : String]
  [key : (& key PackageCacheKey)]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 16)
    (ResultBuildString.Err
      (build-git-dep-error alias "package cache has no free staging path"))
    (let
      [staged : String (package-cache-staging-path root key attempt)]
      (if (io.file-exists? staged)
        (build-package-cache-staging-path alias root key (+ attempt 1))
        (ResultBuildString.Ok staged)))))

(define (build-package-cache-conflict-backup-path
  [entry-path : String]
  [attempt : i64]) : String
  (str_cat.str-cat entry-path ".corrupt." (string.int->string attempt)))

(define (build-package-cache-move-conflict-attempt
  [alias : String]
  [entry-path : String]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 16)
    (ResultBuildString.Err
      (build-git-dep-error
        alias
        "package cache has no free corrupt backup path"))
    (let
      [backup : String
        (build-package-cache-conflict-backup-path entry-path attempt)]
      (if (io.file-exists? backup)
        (build-package-cache-move-conflict-attempt
          alias
          entry-path
          (+ attempt 1))
        (match (fs.try-rename (& entry-path) (& backup))
          [(io.OkIoUnit) (ResultBuildString.Ok backup)]
          [(io.ErrIoUnit error)
            (ResultBuildString.Err
              (build-package-cache-io-error
                alias
                "package cache move corrupt entry"
                error))])))))

(define (build-package-cache-move-conflict
  [alias : String]
  [entry-path : String]) : ResultBuildString
  (if (io.file-exists? entry-path)
    (build-package-cache-move-conflict-attempt alias entry-path 1)
    (ResultBuildString.Ok entry-path)))

(define (build-package-cache-hit-result
  [alias : String]
  [entry-path : String]
  [relative-entry-root : String]) : ResultBuildString
  (if (io.file-exists? (build-package-cache-manifest-path (& entry-path)))
    (ResultBuildString.Ok relative-entry-root)
    (ResultBuildString.Err
      (build-git-dep-error alias "cached package is missing typelisp.pkg"))))

(define (build-package-cache-finalize-staged
  [alias : String]
  [staged-path : String]
  [entry-path : String]
  [relative-entry-root : String]
  [key : (& key PackageCacheKey)]) : ResultBuildString
  (match (package-cache-finalize-staged staged-path entry-path)
    [(io.OkIoUnit) (ResultBuildString.Ok relative-entry-root)]
    [(io.ErrIoUnit error)
      (match (package-cache-entry-state entry-path key)
        [(PackageCacheEntryState.CompleteHit _)
          (build-package-cache-hit-result alias entry-path relative-entry-root)]
        [_
          (ResultBuildString.Err
            (build-package-cache-io-error alias "package cache finalize" error))])]))

(define (build-package-cache-write-marker
  [alias : String]
  [staged-path : String]
  [key : (& key PackageCacheKey)]) : ResultBuildString
  (match (package-cache-write-complete-marker staged-path key)
    [(io.OkIoUnit) (ResultBuildString.Ok staged-path)]
    [(io.ErrIoUnit error)
      (ResultBuildString.Err
        (build-package-cache-io-error alias "package cache write marker" error))]))

(define (build-package-cache-prepare-entry-parents-result
  [alias : String]
  [root : String]
  [key : (& key PackageCacheKey)]) : ResultBuildString
  (match (package-cache-prepare-entry-parents root key)
    [(io.OkIoUnit) (ResultBuildString.Ok root)]
    [(io.ErrIoUnit error)
      (ResultBuildString.Err
        (build-package-cache-io-error alias "package cache prepare entry" error))]))

(define (build-package-cache-fetch-staged
  [alias : String]
  [dep : (& dep BuildGitDependency)]
  [root : String]
  [key : (& key PackageCacheKey)]
  [entry-path : String]
  [relative-entry-root : String]
  [replace-existing : bool]) : ResultBuildString
  (match (package-cache-prepare-staging-parents root key)
    [(io.ErrIoUnit error)
      (ResultBuildString.Err
        (build-package-cache-io-error
          alias
          "package cache prepare staging"
          error))]
    [(io.OkIoUnit)
      (match (build-package-cache-staging-path alias root key 1)
        [(ResultBuildString.Err message) (ResultBuildString.Err message)]
        [(ResultBuildString.Ok staged-path)
          (match (build-run-captured
            (build-git-dep-error alias "git clone")
            (build-git-clone-command
              (string.copy (& (struct-get dep remote)))
              staged-path))
            [(ResultBuildString.Err message) (ResultBuildString.Err message)]
            [(ResultBuildString.Ok _)
              (match (build-run-captured
                (build-git-dep-error alias "git checkout")
                (build-git-checkout-command
                  staged-path
                  (build-git-checkout-ref dep)))
                [(ResultBuildString.Err message)
                  (ResultBuildString.Err message)]
                [(ResultBuildString.Ok _)
                  (match (build-run-captured
                    (build-git-dep-error alias "git rev-parse")
                    (build-git-rev-parse-command staged-path))
                    [(ResultBuildString.Err message)
                      (ResultBuildString.Err message)]
                    [(ResultBuildString.Ok _)
                      (if (not
                        (io.file-exists?
                          (build-package-cache-manifest-path (& staged-path))))
                        (ResultBuildString.Err
                          (build-git-dep-error
                            alias
                            "fetched package is missing typelisp.pkg"))
                        (match (build-package-cache-write-marker
                          alias
                          staged-path
                          key)
                          [(ResultBuildString.Err message)
                            (ResultBuildString.Err message)]
                          [(ResultBuildString.Ok _)
                            (match (build-package-cache-prepare-entry-parents-result
                              alias
                              root
                              key)
                              [(ResultBuildString.Err message)
                                (ResultBuildString.Err message)]
                              [(ResultBuildString.Ok _)
                                (match (if replace-existing
                                  (build-package-cache-move-conflict
                                    alias
                                    entry-path)
                                  (ResultBuildString.Ok entry-path))
                                  [(ResultBuildString.Err message)
                                    (ResultBuildString.Err message)]
                                  [(ResultBuildString.Ok _)
                                    (build-package-cache-finalize-staged
                                      alias
                                      staged-path
                                      entry-path
                                      relative-entry-root
                                      key)])])]))])])])])]))

(define (build-fetch-github-dependency-cached
  [manifest-dir : String]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : ResultBuildString
  (let
    [remote : String (string.copy (& (struct-get dep remote)))]
    [pin-value : String (string.copy (& (struct-get dep pin-value)))]
    [key : PackageCacheKey (PackageCacheKey remote pin-value)]
    [root : String (package-cache-default-root manifest-dir)]
    [entry-path : String (package-cache-entry-path root (& key))]
    [relative-root : String (build-package-cache-relative-root)]
    [relative-entry-root : String
      (compiler-load-normalize-path
        (package-cache-entry-path (& relative-root) (& key)))]
    [state : PackageCacheEntryState
      (package-cache-entry-state entry-path (& key))]
    (match state
      [(PackageCacheEntryState.CompleteHit _)
        (if (io.file-exists? (build-package-cache-manifest-path (& entry-path)))
          (ResultBuildString.Ok relative-entry-root)
          (match (build-ensure-package-cache-root manifest-dir alias)
            [(ResultBuildString.Err message) (ResultBuildString.Err message)]
            [(ResultBuildString.Ok _)
              (build-package-cache-fetch-staged
                alias
                dep
                root
                (& key)
                entry-path
                relative-entry-root
                true)]))]
      [(PackageCacheEntryState.Miss _)
        (match (build-ensure-package-cache-root manifest-dir alias)
          [(ResultBuildString.Err message) (ResultBuildString.Err message)]
          [(ResultBuildString.Ok _)
            (build-package-cache-fetch-staged
              alias
              dep
              root
              (& key)
              entry-path
              relative-entry-root
              false)])]
      [(PackageCacheEntryState.PartialOrCorrupt _ _)
        (match (build-ensure-package-cache-root manifest-dir alias)
          [(ResultBuildString.Err message) (ResultBuildString.Err message)]
          [(ResultBuildString.Ok _)
            (build-package-cache-fetch-staged
              alias
              dep
              root
              (& key)
              entry-path
              relative-entry-root
              true)])])))

(define (build-git-clone-if-needed
  [manifest-dir : String]
  [alias : String]
  [dep : (& dep BuildGitDependency)]
  [root : String]) : ResultBuildString
  (if (io.file-exists? (build-github-cache-git-dir manifest-dir alias))
    (ResultBuildString.Ok root)
    (build-run-captured
      (build-git-dep-error alias "git clone")
      (build-git-clone-command (string.copy (& (struct-get dep remote))) root))))

(define (build-fetch-github-dependency-legacy
  [manifest-dir : String]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : ResultBuildString
  (let
    [root : String (build-github-dep-cache-root manifest-dir alias)]
    [manifest-path : String
      (build-github-dep-cache-manifest-path manifest-dir alias)]
    (if (not (build-github-cache-needs-git? manifest-dir alias))
      (ResultBuildString.Ok manifest-path)
      (match (build-ensure-github-cache-parent manifest-dir alias)
        [(ResultBuildString.Err message) (ResultBuildString.Err message)]
        [(ResultBuildString.Ok _)
          (match (build-git-clone-if-needed manifest-dir alias dep root)
            [(ResultBuildString.Err message) (ResultBuildString.Err message)]
            [(ResultBuildString.Ok _)
              (match (build-run-captured
                (build-git-dep-error alias "git checkout")
                (build-git-checkout-command root (build-git-checkout-ref dep)))
                [(ResultBuildString.Err message)
                  (ResultBuildString.Err message)]
                [(ResultBuildString.Ok _)
                  (match (build-run-captured
                    (build-git-dep-error alias "git rev-parse")
                    (build-git-rev-parse-command root))
                    [(ResultBuildString.Err message)
                      (ResultBuildString.Err message)]
                    [(ResultBuildString.Ok _)
                      (if (io.file-exists? manifest-path)
                        (ResultBuildString.Ok
                          (build-github-dep-relative-root alias))
                        (ResultBuildString.Err
                          (build-git-dep-error
                            alias
                            "fetched package is missing typelisp.pkg")))])])])]))))

(define (build-fetch-github-dependency
  [manifest-dir : String]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : ResultBuildString
  (if (not (build-github-cache-needs-git? manifest-dir alias))
    (ResultBuildString.Ok (build-github-dep-relative-root alias))
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
      (build-git-dependency-at-commit (& dep) locked-commit)]
    (match (build-fetch-github-dependency-cached
      manifest-dir
      alias
      (& locked-dep))
      [(ResultBuildString.Err message)
        (ResultBuildResolvedGitDependency.Err message)]
      [(ResultBuildString.Ok dep-root)
        (ResultBuildResolvedGitDependency.Ok
          (BuildResolvedGitDependency dep-root entry))])))

(define (build-resolve-github-dependency-without-lock
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]) : ResultBuildResolvedGitDependency
  (match (build-fetch-github-dependency manifest-dir alias (& dep))
    [(ResultBuildString.Err message)
      (ResultBuildResolvedGitDependency.Err message)]
    [(ResultBuildString.Ok dep-root)
      (let
        [commit-result : ResultBuildString
          (if (build-git-dep-rev? (& dep))
            (ResultBuildString.Ok (string.copy (& (struct-get dep pin-value))))
            (build-resolve-git-head
              alias
              (build-absolute-dep-root manifest-dir dep-root)))]
        (match commit-result
          [(ResultBuildString.Err message)
            (ResultBuildResolvedGitDependency.Err message)]
          [(ResultBuildString.Ok commit)
            (match (build-package-lock-entry alias (& dep) commit)
              [(ResultPackageLockEntry.Err message)
                (ResultBuildResolvedGitDependency.Err message)]
              [(ResultPackageLockEntry.Ok entry)
                (ResultBuildResolvedGitDependency.Ok
                  (BuildResolvedGitDependency dep-root entry))])]))]))

(define (build-resolve-github-dependency
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]
  [lock-entries : package_lock_entry_vec.Vec]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildResolvedGitDependency
  (if (build-package-lock-policy-update? lock-policy)
    (build-resolve-github-dependency-without-lock manifest-dir alias dep)
    (if (build-package-lock-policy-locked? lock-policy)
      (match (build-package-lock-entry-status lock-entries alias (& dep))
        [(BuildPackageLockEntryStatus.Matched entry)
          (build-resolve-github-dependency-from-lock
            manifest-dir
            alias
            dep
            entry)]
        [(BuildPackageLockEntryStatus.Missing)
          (ResultBuildResolvedGitDependency.Err
            (build-package-lock-missing-message alias))]
        [(BuildPackageLockEntryStatus.Stale)
          (ResultBuildResolvedGitDependency.Err
            (build-package-lock-stale-message alias))])
      (match (build-package-lock-matching-entry lock-entries alias (& dep))
        [(BuildMaybeLockEntry.Some entry)
          (build-resolve-github-dependency-from-lock
            manifest-dir
            alias
            dep
            entry)]
        [(BuildMaybeLockEntry.No)
          (build-resolve-github-dependency-without-lock manifest-dir alias dep)]))))

(define (build-package-resolve-dep-with-lock
  [manifest-dir : String]
  [lock-entries : package_lock_entry_vec.Vec]
  [lock-policy : BuildPackageLockPolicy]
  [dep : CompilerPkgDep]) : ResultBuildResolvedPkgDep
  (let
    [path : String (struct-get dep path)]
    [alias : String (struct-get dep alias)]
    [path-for-kind : String (string.copy (& path))]
    (if (compiler-load-github-dependency-path? path-for-kind)
      (let
        [parse-alias : String
          (string.substring alias 0 (string.string-length alias))]
        [parse-path : String (string.copy (& path))]
        (match (build-parse-git-dependency parse-alias parse-path)
          [(ResultBuildGitDependency.Err message)
            (ResultBuildResolvedPkgDep.Err message)]
          [(ResultBuildGitDependency.Ok git-dep)
            (match (build-resolve-github-dependency
              manifest-dir
              alias
              git-dep
              lock-entries
              lock-policy)
              [(ResultBuildResolvedGitDependency.Err message)
                (ResultBuildResolvedPkgDep.Err message)]
              [(ResultBuildResolvedGitDependency.Ok resolved)
                (ResultBuildResolvedPkgDep.Ok
                  (BuildResolvedPkgDep
                    (CompilerPkgDep alias (struct-get resolved dep-root))
                    (BuildMaybeLockEntry.Some (struct-get resolved lock-entry))))])]))
      (ResultBuildResolvedPkgDep.Ok
        (BuildResolvedPkgDep
          (CompilerPkgDep alias path)
          (BuildMaybeLockEntry.No))))))

(define (build-package-resolve-dep
  [manifest-dir : String]
  [dep : CompilerPkgDep]) : ResultBuildPkgDep
  (match (build-package-resolve-dep-with-lock
    manifest-dir
    (package_lock_entry_vec.new)
    (BuildPackageLockPolicy.Default)
    dep)
    [(ResultBuildResolvedPkgDep.Err message) (ResultBuildPkgDep.Err message)]
    [(ResultBuildResolvedPkgDep.Ok resolved)
      (ResultBuildPkgDep.Ok (struct-get resolved dep))]))

(define (build-package-lock-entry-list-add
  [entries : package_lock_entry_vec.Vec]
  [maybe-entry : BuildMaybeLockEntry]) : ResultPackageLockEntryList
  (match maybe-entry
    [(BuildMaybeLockEntry.No) (ResultPackageLockEntryList.Ok entries)]
    [(BuildMaybeLockEntry.Some entry)
      (package-lock-entry-list-insert entries entry)]))

(define (build-package-lock-list-has-exact-entry?
  [entries : package_lock_entry_vec.Vec]
  [entry : PackageLockEntry]) : bool
  (package-lock-list-has-entry?
    entries
    (struct-get entry alias)
    (struct-get entry url)
    (struct-get entry pin-kind)
    (struct-get entry pin-value)
    (struct-get entry commit)))

(define (build-package-lock-list-contains-all?
  [haystack : package_lock_entry_vec.Vec]
  [needles : package_lock_entry_vec.Vec]) : bool
  (build-package-lock-list-contains-all-from haystack (& needles) 0))

(define (build-package-lock-list-contains-all-from
  [haystack : package_lock_entry_vec.Vec]
  [needles : (& needles package_lock_entry_vec.Vec)]
  [index : i64]) : bool
  (if (>= index (package_lock_entry_vec.len needles))
    true
    (and
      (build-package-lock-list-has-exact-entry?
        haystack
        (package_lock_entry_vec.get
          needles
          index
          (package-lock-entry-list-fallback)))
      (build-package-lock-list-contains-all-from haystack needles (+ index 1)))))

(define (build-package-lock-list-eq?
  [left : package_lock_entry_vec.Vec]
  [right : package_lock_entry_vec.Vec]) : bool
  (and
    (=
      (package_lock_entry_vec.len (& left))
      (package_lock_entry_vec.len (& right)))
    (build-package-lock-list-contains-all? left right)))

(define (build-package-lock-policy-check
  [policy : BuildPackageLockPolicy]
  [lock-state : BuildPackageLockState]
  [resolved : BuildResolvedPkgDeps]) : ResultBuildString
  (if (build-package-lock-policy-locked? policy)
    (if (and
      (struct-get resolved has-remote)
      (not (struct-get lock-state has-lock)))
      (ResultBuildString.Err
        "build: --locked requires typelisp.lock for remote dependencies; run with --update-lock to refresh typelisp.lock")
      (if (and
        (struct-get lock-state has-lock)
        (not
          (build-package-lock-list-eq?
            (struct-get lock-state entries)
            (struct-get resolved lock-entries))))
        (ResultBuildString.Err
          "build: package lock is stale; run with --update-lock to refresh typelisp.lock")
        (ResultBuildString.Ok "")))
    (ResultBuildString.Ok "")))

(define (build-package-maybe-write-lock
  [policy : BuildPackageLockPolicy]
  [lock-state : BuildPackageLockState]
  [resolved : BuildResolvedPkgDeps]) : ResultBuildString
  (if (and
    (not (build-package-lock-policy-locked? policy))
    (or (struct-get resolved has-remote) (struct-get lock-state has-lock)))
    (build-write-package-lock lock-state (struct-get resolved lock-entries))
    (ResultBuildString.Ok "")))

(define (build-package-resolve-deps-with-lock
  [manifest-dir : String]
  [lock-entries : package_lock_entry_vec.Vec]
  [lock-policy : BuildPackageLockPolicy]
  [deps : CompilerPkgDepList]) : ResultBuildResolvedPkgDeps
  (match deps
    [(CompilerPkgDepNil)
      (ResultBuildResolvedPkgDeps.Ok
        (BuildResolvedPkgDeps
          CompilerPkgDepNil
          (package_lock_entry_vec.new)
          false))]
    [(CompilerPkgDepCons dep rest)
      (match (build-package-resolve-dep-with-lock
        manifest-dir
        lock-entries
        lock-policy
        dep)
        [(ResultBuildResolvedPkgDep.Err message)
          (ResultBuildResolvedPkgDeps.Err message)]
        [(ResultBuildResolvedPkgDep.Ok resolved-dep)
          (match (build-package-resolve-deps-with-lock
            manifest-dir
            lock-entries
            lock-policy
            (box-get rest))
            [(ResultBuildResolvedPkgDeps.Err message)
              (ResultBuildResolvedPkgDeps.Err message)]
            [(ResultBuildResolvedPkgDeps.Ok resolved-rest)
              (match (build-package-lock-entry-list-add
                (struct-get resolved-rest lock-entries)
                (struct-get resolved-dep lock-entry))
                [(ResultPackageLockEntryList.Err message)
                  (ResultBuildResolvedPkgDeps.Err message)]
                [(ResultPackageLockEntryList.Ok next-lock-entries)
                  (ResultBuildResolvedPkgDeps.Ok
                    (BuildResolvedPkgDeps
                      (CompilerPkgDepCons
                        (struct-get resolved-dep dep)
                        (box (struct-get resolved-rest deps)))
                      next-lock-entries
                      (or
                        (struct-get resolved-rest has-remote)
                        (match (struct-get resolved-dep lock-entry)
                          [(BuildMaybeLockEntry.No) false]
                          [(BuildMaybeLockEntry.Some _) true]))))])])])]))

(define (build-package-resolve-manifest-deps
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildManifest
  (let
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    (match (build-load-package-lock manifest-dir)
      [(ResultBuildPackageLockState.Err message)
        (ResultBuildManifest.Err message)]
      [(ResultBuildPackageLockState.Ok lock-state)
        (match (build-package-resolve-deps-with-lock
          manifest-dir
          (struct-get lock-state entries)
          lock-policy
          (compiler-pkg-deps-list (struct-get manifest deps)))
          [(ResultBuildResolvedPkgDeps.Err message)
            (ResultBuildManifest.Err message)]
          [(ResultBuildResolvedPkgDeps.Ok resolved)
            (match (build-package-lock-policy-check
              lock-policy
              lock-state
              resolved)
              [(ResultBuildString.Err message)
                (ResultBuildManifest.Err message)]
              [(ResultBuildString.Ok _)
                (match (build-package-maybe-write-lock
                  lock-policy
                  lock-state
                  resolved)
                  [(ResultBuildString.Err message)
                    (ResultBuildManifest.Err message)]
                  [(ResultBuildString.Ok _)
                    (ResultBuildManifest.Ok
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
    [(BuildPackagePathList.Nil) ""]
    [(BuildPackagePathList.Cons path rest)
      (let
        [tail : String (build-package-path-list-render (box-get rest))]
        (if (= (string.string-length tail) 0)
          path
          (str_cat.str-cat tail " -> " path)))]))

(define (build-package-cycle-message
  [stack : BuildPackagePathList]
  [manifest-path : String]) : String
  (str_cat.str-cat
    "build: dependency cycle: "
    (build-package-path-list-render stack)
    " -> "
    manifest-path))

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
    (build-string-i64-map-put (struct-get state seen) manifest-path mark)
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
    [(ResultBuildPkgDep.Err message) (ResultBuildPackageGraphNode.Err message)]
    [(ResultBuildPkgDep.Ok resolved-dep)
      (let
        [dep-manifest-path : String
          (build-package-dep-manifest-path manifest-dir resolved-dep)]
        (match (build-load-manifest dep-manifest-path)
          [(ResultBuildManifest.Err message)
            (ResultBuildPackageGraphNode.Err
              (str_cat.str-cat
                "dependency `"
                (struct-get resolved-dep alias)
                "`: "
                message))]
          [(ResultBuildManifest.Ok dep-manifest)
            (match (build-package-resolve-manifest-deps
              dep-manifest-path
              dep-manifest
              lock-policy)
              [(ResultBuildManifest.Err message)
                (ResultBuildPackageGraphNode.Err message)]
              [(ResultBuildManifest.Ok resolved-manifest)
                (if (not
                  (build-package-kind-lib? (struct-get resolved-manifest kind)))
                  (ResultBuildPackageGraphNode.Err
                    (str_cat.str-cat
                      "build: dependency `"
                      (struct-get resolved-dep alias)
                      "` at "
                      dep-manifest-path
                      " must be a staticlib package"))
                  (ResultBuildPackageGraphNode.Ok
                    (BuildPackageGraphNode dep-manifest-path resolved-manifest)))])]))]))

(define (build-package-graph-add-node
  [node : BuildPackageGraphNode]
  [state : BuildPackageGraphState]
  [stack : BuildPackagePathList]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildPackageGraphState
  (let
    [manifest-path : String (struct-get node manifest-path)]
    (match (build_string_i64_map.get (& (struct-get state seen)) manifest-path)
      [(build_string_i64_map.LookupFound mark)
        (if (= mark build-package-visit-visiting)
          (ResultBuildPackageGraphState.Err
            (build-package-cycle-message stack manifest-path))
          (ResultBuildPackageGraphState.Ok state))]
      [(build_string_i64_map.LookupMissing)
        (let
          [visiting : BuildPackageGraphState
            (build-package-graph-state-mark
              state
              manifest-path
              build-package-visit-visiting)]
          [manifest : CompilerPkgManifest (struct-get node manifest)]
          [manifest-dir : String (compiler-load-dirname manifest-path)]
          [next-stack : BuildPackagePathList
            (BuildPackagePathList.Cons manifest-path (box stack))]
          (match (build-package-graph-add-deps
            manifest-dir
            (compiler-pkg-deps-list (struct-get manifest deps))
            visiting
            next-stack
            lock-policy)
            [(ResultBuildPackageGraphState.Err message)
              (ResultBuildPackageGraphState.Err message)]
            [(ResultBuildPackageGraphState.Ok with-deps)
              (ResultBuildPackageGraphState.Ok
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
    [(CompilerPkgDepNil) (ResultBuildPackageGraphState.Ok state)]
    [(CompilerPkgDepCons dep rest)
      (match (build-package-load-dep-node manifest-dir dep lock-policy)
        [(ResultBuildPackageGraphNode.Err message)
          (ResultBuildPackageGraphState.Err message)]
        [(ResultBuildPackageGraphNode.Ok node)
          (match (build-package-graph-add-node node state stack lock-policy)
            [(ResultBuildPackageGraphState.Err message)
              (ResultBuildPackageGraphState.Err message)]
            [(ResultBuildPackageGraphState.Ok next-state)
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
        (build-string-i64-map-put
          (build_string_i64_map.with-capacity 32)
          root-path
          build-package-visit-visiting)
        (build-package-graph-node-vec-new))]
    [stack : BuildPackagePathList
      (BuildPackagePathList.Cons root-path (box BuildPackagePathList.Nil))]
    (match (build-package-graph-add-deps
      root-dir
      (compiler-pkg-deps-list (struct-get manifest deps))
      initial
      stack
      lock-policy)
      [(ResultBuildPackageGraphState.Err message)
        (ResultBuildPackageGraph.Err message)]
      [(ResultBuildPackageGraphState.Ok state)
        (ResultBuildPackageGraph.Ok
          (BuildPackageGraph (struct-get state order)))])))

(define (build-mkdir-ok? [path : (& path str)]) : bool
  (let
    [status : i64 (fs.mkdir-status path)]
    (or (= status build-status-ok) (= status build-status-already-exists))))

(define (build-mkdir-ok-owned? [path : String]) : bool
  (let
    [status : i64 (fs.mkdir-status-owned path)]
    (or (= status build-status-ok) (= status build-status-already-exists))))

(define (build-ensure-package-output-dirs
  [manifest-dir : String]
  [_name : String]
  [profile : BuildProfile]) : bool
  (let
    [target-dir : String (compiler-load-join-root-path manifest-dir "target")]
    [profile-dir : String
      (compiler-load-join-root-path
        (string.copy target-dir)
        (build-profile-name profile))]
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
  [vec : (& vec fs.FsStringVector)]
  [idx : i64]) : SourceToolLinkInputs
  (if (>= idx (fs.string-vector-len vec))
    inputs
    (build-package-link-add-libs
      (source-tool-link-inputs-add-ast
        inputs
        (AstExternLinkInput.Lib (fs.string-vector-get vec idx "")))
      vec
      (+ idx 1))))

(define (build-package-link-add-search-paths
  [inputs : SourceToolLinkInputs]
  [manifest-dir : String]
  [vec : (& vec fs.FsStringVector)]
  [idx : i64]) : SourceToolLinkInputs
  (if (>= idx (fs.string-vector-len vec))
    inputs
    (build-package-link-add-search-paths
      (source-tool-link-inputs-add-ast
        inputs
        (AstExternLinkInput.Search
          (build-package-link-resolve-search-path
            manifest-dir
            (fs.string-vector-get vec idx ""))))
      manifest-dir
      vec
      (+ idx 1))))

(define (build-package-link-add-args
  [inputs : SourceToolLinkInputs]
  [vec : (& vec fs.FsStringVector)]
  [idx : i64]) : SourceToolLinkInputs
  (if (>= idx (fs.string-vector-len vec))
    inputs
    (build-package-link-add-args
      (source-tool-link-inputs-add-ast
        inputs
        (AstExternLinkInput.Arg (fs.string-vector-get vec idx "")))
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
      (build-package-link-add-libs inputs (& (struct-get set libraries)) 0)
      manifest-dir
      (& (struct-get set search-paths))
      0)
    (& (struct-get set args))
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
      [(CompilerBackendTarget.Linux) (struct-get link linux)]
      [(CompilerBackendTarget.Windows) (struct-get link windows)])))

(define (build-package-artifact-status
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : SourceToolLinkInputs]
  [direct-status : SourceToolDirectObjectStatus]) : SourceToolCommandStatus
  (match direct-status
    [(SourceToolDirectObjectStatus.Ok) SourceToolCommandStatus.Ok]
    [(SourceToolDirectObjectStatus.Err message)
      (SourceToolCommandStatus.Err message)]
    [(SourceToolDirectObjectStatus.Unavailable _)
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
  (match (build-package-try-render-linux-direct-object
    kind
    target
    opt-level
    mode
    emit-entry
    crt-entry
    decls
    paths)
    [(ResultSourceToolString.Ok obj)
      (build-package-write-linux-direct-object-artifact
        kind
        target
        obj-path
        artifact-path
        link-inputs
        obj)]
    [(ResultSourceToolString.Err message)
      (SourceToolDirectObjectStatus.Unavailable message)]))

(define (build-package-direct-object-mode? [mode : CompilerBackendMode]) : bool
  (match mode
    [(CompilerBackendMode.Scalar) true]
    [_ false]))

(define (build-package-direct-object-owned-path-budget) : i64
  ;; Large package direct-object emission duplicates enough object/ELF state to
  ;; exceed CI memory; keep it for small no-assembler package smokes.
  512)

(define (build-package-direct-object-owned-path-count [paths : AstDeclPathList]) : i64
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Nil) 0]
    [(AstDeclPathListStep.Cons path rest)
      (let
        [tail : AstDeclPathList rest]
        (+
          (if (> (string.string-length path) 0)
            1
            0)
          (build-package-direct-object-owned-path-count tail)))]))

(define (build-package-direct-object-within-budget? [paths : AstDeclPathList]) : bool
  (<=
    (build-package-direct-object-owned-path-count paths)
    (build-package-direct-object-owned-path-budget)))

(define (build-package-direct-object-size-ok? [paths : AstDeclPathList]) : bool
  (or
    (source-tool-linux-direct-object-enabled?)
    (build-package-direct-object-within-budget? paths)))

(cfg
  test
  (define (build-package-direct-object-test-paths
    [count : i64]
    [path : String]
    [out : AstDeclPathList]) : AstDeclPathList
    (if (<= count 0)
      out
      (build-package-direct-object-test-paths
        (- count 1)
        path
        (ast-decl-path-list-prepend-builder path out)))))

(cfg
  test
  (define (build-package-direct-object-size-smoke-ok?) : bool
    (let
      [budget : i64 (build-package-direct-object-owned-path-budget)]
      [within : AstDeclPathList
        (build-package-direct-object-test-paths
          budget
          "pkg.tl"
          (ast-decl-path-list-new))]
      [over : AstDeclPathList
        (build-package-direct-object-test-paths
          (+ budget 1)
          "pkg.tl"
          (ast-decl-path-list-new))]
      [mixed : AstDeclPathList
        (ast-decl-path-cons
          ""
          (ast-decl-path-cons "pkg.tl" (ast-decl-path-list-new)))]
      (and
        (= (build-package-direct-object-owned-path-count mixed) 1)
        (build-package-direct-object-within-budget? within)
        (not (build-package-direct-object-within-budget? over))))))

(cfg
  test
  (test
    build-package-direct-object-size-smoke
    (unless
      (build-package-direct-object-size-smoke-ok?)
      (io.panic "build package direct object size smoke failed"))))

(define (build-package-try-render-linux-direct-object
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultSourceToolString
  (if (and
    (compiler-backend-target-linux? target)
    (build-package-direct-object-mode? mode)
    (build-package-direct-object-size-ok? paths))
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
      [(ResultCompilerDriverObject.Ok image)
        (build-package-render-linux-direct-object kind image)]
      [(ResultCompilerDriverObject.Err diag)
        (ResultSourceToolString.Err (compiler-diagnostic-render (box-get diag)))])
    (ResultSourceToolString.Err "linux direct object disabled")))

(define (build-package-graph-node-artifact-paths
  [node : BuildPackageGraphNode]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : BuildPackageArtifactPaths
  (let
    [manifest-path : String (struct-get node manifest-path)]
    [manifest : CompilerPkgManifest (struct-get node manifest)]
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    (build-package-artifact-paths
      manifest-dir
      (struct-get manifest name)
      (struct-get manifest kind)
      profile
      target)))

(define (build-package-graph-node-artifact-path
  [node : BuildPackageGraphNode]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : String
  (build-package-runtime-artifact-path
    (build-package-graph-node-artifact-paths node profile target)))

(define (build-package-graph-node-tlci-path
  [node : BuildPackageGraphNode]
  [profile : BuildProfile]) : String
  (let
    [manifest-path : String (struct-get node manifest-path)]
    [manifest : CompilerPkgManifest (struct-get node manifest)]
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    (build-package-tlci-path-profile
      manifest-dir
      (struct-get manifest name)
      profile)))

(define (build-package-graph-link-libs
  [nodes : BuildPackageGraphNodeVec]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : process.ProcessStringList
  (let
    [index : i64 (- (build-package-graph-node-vec-len nodes) 1)]
    [libs : process.ProcessStringList (process.args-empty)]
    (begin
      (while (>= index 0)
        (begin
          (set!
            libs
            (process.args-append
              libs
              (process.args-single
                (build-package-graph-node-artifact-path
                  (build-package-graph-node-vec-at nodes index)
                  profile
                  target))))
          (set! index (- index 1))))
      libs)))

(define (build-package-graph-tlci-paths
  [nodes : BuildPackageGraphNodeVec]
  [profile : BuildProfile]) : process.ProcessStringList
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [paths : process.ProcessStringList (process.args-empty)]
    (begin
      (while (< index count)
        (begin
          (set!
            paths
            (process.args-append
              paths
              (process.args-single
                (build-package-graph-node-tlci-path
                  (build-package-graph-node-vec-at nodes index)
                  profile))))
          (set! index (+ index 1))))
      paths)))

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

(define (build-package-graph-test-link-arg-target
  [node : BuildPackageGraphNode]
  [target : CompilerBackendTarget]) : process.ProcessStringList
  (process.args-single
    (build-package-graph-node-artifact-path node (BuildProfile.Release) target)))

(define (build-package-graph-test-link-arg [node : BuildPackageGraphNode]) : process.ProcessStringList
  (build-package-graph-test-link-arg-target node (CompilerBackendTarget.Linux)))

(define (build-package-graph-test-tlci-arg [node : BuildPackageGraphNode]) : process.ProcessStringList
  (process.args-single
    (build-package-graph-node-tlci-path node (BuildProfile.Release))))

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
    [libs : process.ProcessStringList
      (build-package-graph-link-libs
        nodes
        (BuildProfile.Release)
        (CompilerBackendTarget.Linux))]
    [windows-libs : process.ProcessStringList
      (build-package-graph-link-libs
        nodes
        (BuildProfile.Release)
        (CompilerBackendTarget.Windows))]
    [tlcis : process.ProcessStringList
      (build-package-graph-tlci-paths nodes (BuildProfile.Release))]
    [expected : process.ProcessStringList
      (process.args-append
        (process.args-append
          (build-package-graph-test-link-arg third)
          (build-package-graph-test-link-arg second))
        (build-package-graph-test-link-arg first))]
    [expected-tlcis : process.ProcessStringList
      (process.args-append
        (process.args-append
          (build-package-graph-test-tlci-arg first)
          (build-package-graph-test-tlci-arg second))
        (build-package-graph-test-tlci-arg third))]
    [expected-windows : process.ProcessStringList
      (process.args-append
        (process.args-append
          (build-package-graph-test-link-arg-target
            third
            (CompilerBackendTarget.Windows))
          (build-package-graph-test-link-arg-target
            second
            (CompilerBackendTarget.Windows)))
        (build-package-graph-test-link-arg-target
          first
          (CompilerBackendTarget.Windows)))]
    (and
      (= (build-package-graph-node-vec-len nodes) 3)
      (string.eq
        (struct-get (build-package-graph-node-vec-at nodes 0) manifest-path)
        "root/first/typelisp.pkg")
      (source-tool-string-list-eq? libs expected)
      (source-tool-string-list-eq? windows-libs expected-windows)
      (source-tool-string-list-eq? tlcis expected-tlcis))))

(cfg
  test
  (define (build-package-graph-artifact-paths-smoke-ok?) : bool
    (let
      [bin-manifest : CompilerPkgManifest
        (CompilerPkgManifest
          "app"
          "0.1.0"
          (CompilerPkgKindBin)
          "src/main.tl"
          (compiler-pkg-deps-empty)
          (compiler-pkg-link-empty))]
      [bin-node : BuildPackageGraphNode
        (BuildPackageGraphNode "root/app/typelisp.pkg" bin-manifest)]
      [dep-node : BuildPackageGraphNode
        (build-package-graph-test-node "root/dep/typelisp.pkg" "dep")]
      [bin-artifacts : BuildPackageArtifactPaths
        (build-package-graph-node-artifact-paths
          bin-node
          (BuildProfile.Dev)
          (CompilerBackendTarget.Windows))]
      [dep-artifacts : BuildPackageArtifactPaths
        (build-package-graph-node-artifact-paths
          dep-node
          (BuildProfile.Release)
          (CompilerBackendTarget.Linux))]
      (and
        (string.eq
          (build-package-runtime-artifact-path bin-artifacts)
          "root/app/target/dev/app.exe")
        (string.eq
          (build-package-host-tlci-artifact-path bin-artifacts)
          "root/app/target/dev/app.tlci")
        (string.eq
          (build-package-runtime-artifact-path dep-artifacts)
          "root/dep/target/release/libdep.a")
        (string.eq
          (build-package-host-tlci-artifact-path dep-artifacts)
          "root/dep/target/release/dep.tlci")))))

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
      (build_string_i64_map.with-capacity 4)
      (build_string_i64_map.with-capacity 4)
      (CompilerBackendTarget.Linux)
      0
      (BuildProfile.Release)
      (CompilerBackendMode.Scalar)
      (BuildPackageLockPolicy.Default)
      (cli_svec.new)
      (build-package-graph-worker-vec-new))
      [(ResultBuildPackageSchedulePass.Err _) false]
      [(ResultBuildPackageSchedulePass.Ok pass)
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
    (io.panic "build package graph vector smoke failed")))

(cfg
  test
  (test
    build-package-graph-artifact-paths-smoke
    (unless
      (build-package-graph-artifact-paths-smoke-ok?)
      (io.panic "build package graph artifact paths smoke failed"))))

(define build-package-tlci-compiler-build-hash : String
  "typelisp-selfhost-v1")

(define (build-package-tlci-owner-stdlib-path? [owner : String] [path : String]) : bool
  (if (= (string.string-length owner) 0)
    false
    (let
      [prefix : String (str_cat.str-cat owner "/stdlib/")]
      [prefix-len : i64 (string.string-length prefix)]
      (and
        (>= (string.string-length path) prefix-len)
        (string.eq (string.substring path 0 prefix-len) prefix)))))

(define (build-package-tlci-stdlib-path? [owner : String] [path : String]) : bool
  (or
    (compiler-load-stdlib-import? path)
    (build-package-tlci-owner-stdlib-path? owner path)))

(define (build-package-tlci-metadata
  [manifest : CompilerPkgManifest]
  [callables : TlciSpmdCallableList]) : TlciMetadata
  (match callables
    [(TlciSpmdCallableList.Nil)
      (tlci-make-metadata
        "v1"
        (struct-get manifest name)
        (struct-get manifest version))]
    [(TlciSpmdCallableList.Cons _ _)
      (tlci-make-metadata-v2
        (struct-get manifest name)
        (struct-get manifest version)
        callables)]))

(defstruct BuildPackageTlciCallableCollector
  (items TlciSpmdCallableList)
  (error String))

(define (build-package-tlci-specialization-insert
  [item : TlciSpmdSpecialization]
  [items : TlciSpmdSpecializationList]) : TlciSpmdSpecializationList
  (match items
    [(TlciSpmdSpecializationList.Nil)
      (tlci-spmd-specialization-list-cons item items)]
    [(TlciSpmdSpecializationList.Cons head rest)
      (let
        [order : i64 (tlci-spmd-specialization-compare item head)]
        (cond
          [(< order 0) (tlci-spmd-specialization-list-cons item items)]
          [(= order 0) items]
          [else
            (tlci-spmd-specialization-list-cons
              head
              (build-package-tlci-specialization-insert item (box-get rest)))]))]))

(define (build-package-tlci-callable-insert
  [item : TlciSpmdCallable]
  [items : TlciSpmdCallableList]) : TlciSpmdCallableList
  (match items
    [(TlciSpmdCallableList.Nil) (tlci-spmd-callable-list-cons item items)]
    [(TlciSpmdCallableList.Cons head rest)
      (if (< (tlci-spmd-callable-compare item head) 0)
        (tlci-spmd-callable-list-cons item items)
        (tlci-spmd-callable-list-cons
          head
          (build-package-tlci-callable-insert item (box-get rest))))]))

(define (build-package-tlci-backend [mode : CompilerBackendMode]) : CompilerIrSpmdBackend
  (match mode
    [(CompilerBackendMode.Scalar) CompilerIrSpmdBackend.Scalar]
    [(CompilerBackendMode.Avx2) CompilerIrSpmdBackend.Avx2]
    [(CompilerBackendMode.Avx512) CompilerIrSpmdBackend.Avx512]))

(define (build-package-tlci-specializations-at
  [package-name : String]
  [canonical-name : String]
  [signature : String]
  [ret : AstType]
  [items : (& items AstSpmdSpecializationList)]
  [index : i64]
  [limit : i64]
  [backend : CompilerIrSpmdBackend]
  [out : TlciSpmdSpecializationList]) : TlciSpmdSpecializationList
  (if (or (>= index limit) (>= index (ast-spmd-specialization-list-len items)))
    out
    (let
      [fallback : AstSpmdSpecialization
        (AstSpmdSpecialization
          2
          (box (ast-spmd-param-class-list-new))
          AstSpmdResultClass.Unit
          -1)]
      [specialization : AstSpmdSpecialization
        (ast-spmd-specialization-list-get items index fallback)]
      [classes : AstSpmdParamClassList
        (box-get (struct-get specialization args))]
      [args : String (lower-spmd-ast-param-classes-code classes)]
      [result : String
        (lower-spmd-ast-result-class-code (struct-get specialization result))]
      [lanes : i64
        (match backend
          [(CompilerIrSpmdBackend.Scalar) 1]
          [_ (struct-get specialization lanes)])]
      [index-param : i64 (struct-get specialization index-param)]
      [logical-symbol : String
        (lower-spmd-package-symbol
          package-name
          canonical-name
          signature
          ret
          backend
          lanes
          args
          result
          index-param)]
      [item : TlciSpmdSpecialization
        (tlci-make-spmd-specialization
          "spmd-call-v1"
          (lower-spmd-package-backend-name backend)
          lanes
          args
          result
          index-param
          (compiler-backend-user-symbol logical-symbol))]
      (build-package-tlci-specializations-at
        package-name
        canonical-name
        signature
        ret
        items
        (+ index 1)
        limit
        backend
        (build-package-tlci-specialization-insert item out)))))

(define (build-package-tlci-callable
  [package-name : String]
  [module : String]
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [specializations : AstSpmdSpecializationList]
  [mode : CompilerBackendMode]) : TlciSpmdCallable
  (let
    [canonical-name : String
      (compiler-symbol-module-key
        (if (= (string.string-length module) 0)
          package-name
          module)
        (intern-str name))]
    [signature : String (lower-spmd-source-signature params ret)]
    [backend : CompilerIrSpmdBackend (build-package-tlci-backend mode)]
    [count : i64 (ast-spmd-specialization-list-len (& specializations))]
    (tlci-make-spmd-callable
      canonical-name
      signature
      (build-package-tlci-specializations-at
        package-name
        canonical-name
        signature
        ret
        (& specializations)
        0
        count
        backend
        TlciSpmdSpecializationList.Nil))))

(cfg
  test
  (define (build-package-tlci-callable-smoke-ok?) : bool
    (let
      [first-classes : AstSpmdParamClassList (ast-spmd-param-class-list-new)]
      [second-classes : AstSpmdParamClassList (ast-spmd-param-class-list-new)]
      [specializations : AstSpmdSpecializationList
        (ast-spmd-specialization-list-new)]
      (begin
        (ast-spmd-param-class-list-push
          (&mut first-classes)
          AstSpmdParamClass.Varying)
        (ast-spmd-param-class-list-push
          (&mut first-classes)
          AstSpmdParamClass.Uniform)
        (ast-spmd-param-class-list-push
          (&mut second-classes)
          AstSpmdParamClass.Uniform)
        (ast-spmd-param-class-list-push
          (&mut second-classes)
          AstSpmdParamClass.Varying)
        (ast-spmd-specialization-list-push
          (&mut specializations)
          (AstSpmdSpecialization
            8
            (box first-classes)
            AstSpmdResultClass.Varying
            0))
        (ast-spmd-specialization-list-push
          (&mut specializations)
          (AstSpmdSpecialization
            8
            (box second-classes)
            AstSpmdResultClass.Varying
            1))
        (let
          [callable : TlciSpmdCallable
            (build-package-tlci-callable
              "pkg"
              "pkg"
              (intern "helper")
              (ast-param-cons
                (ast-param "x" (AstType.I64) false)
                (ast-param-cons
                  (ast-param "scale" (AstType.I64) false)
                  (ast-param-list-new)))
              (AstType.I64)
              specializations
              (CompilerBackendMode.Scalar))]
          [ordinary-metadata : TlciMetadata
            (build-package-tlci-metadata
              (build-package-graph-test-manifest "pkg")
              TlciSpmdCallableList.Nil)]
          (and
            (string.eq (struct-get ordinary-metadata version) "v1")
            (match (struct-get ordinary-metadata spmd-callables)
              [(TlciSpmdCallableList.Nil) true]
              [_ false])
            (string.eq (struct-get callable name) "pkg/helper")
            (string.eq (struct-get callable signature) "(-> i64 i64 i64)")
            (match (struct-get callable specializations)
              [(TlciSpmdSpecializationList.Cons item rest)
                (and
                  (string.eq (struct-get item abi) "spmd-call-v1")
                  (string.eq (struct-get item backend) "scalar")
                  (= (struct-get item lanes) 1)
                  (string.eq (struct-get item args) "uv")
                  (string.eq (struct-get item result) "v")
                  (= (struct-get item index-param) 1)
                  (string.eq
                    (struct-get item symbol)
                    (compiler-backend-user-symbol
                      (lower-spmd-package-symbol
                        "pkg"
                        "pkg/helper"
                        "(-> i64 i64 i64)"
                        (AstType.I64)
                        CompilerIrSpmdBackend.Scalar
                        1
                        "uv"
                        "v"
                        1)))
                  (match (box-get rest)
                    [(TlciSpmdSpecializationList.Cons next tail)
                      (and
                        (string.eq (struct-get next args) "vu")
                        (= (struct-get next index-param) 0)
                        (match (box-get tail)
                          [(TlciSpmdSpecializationList.Nil) true]
                          [_ false]))]
                    [_ false]))]
              [_ false])))))))

(cfg
  test
  (define (build-package-tlci-scalar-collapse-smoke-ok?) : bool
    (let
      [first-classes : AstSpmdParamClassList (ast-spmd-param-class-list-new)]
      [second-classes : AstSpmdParamClassList (ast-spmd-param-class-list-new)]
      [specializations : AstSpmdSpecializationList
        (ast-spmd-specialization-list-new)]
      (begin
        (ast-spmd-param-class-list-push
          (&mut first-classes)
          AstSpmdParamClass.Uniform)
        (ast-spmd-param-class-list-push
          (&mut second-classes)
          AstSpmdParamClass.Uniform)
        (ast-spmd-specialization-list-push
          (&mut specializations)
          (AstSpmdSpecialization
            8
            (box first-classes)
            AstSpmdResultClass.Uniform
            -1))
        (ast-spmd-specialization-list-push
          (&mut specializations)
          (AstSpmdSpecialization
            16
            (box second-classes)
            AstSpmdResultClass.Uniform
            -1))
        (match (struct-get
          (build-package-tlci-callable
            "pkg"
            "pkg"
            (intern "helper")
            (ast-param-cons
              (ast-param "x" (AstType.I64) false)
              (ast-param-list-new))
            (AstType.I64)
            specializations
            (CompilerBackendMode.Scalar))
          specializations)
          [(TlciSpmdSpecializationList.Cons item rest)
            (and
              (= (struct-get item lanes) 1)
              (string.eq (struct-get item args) "u")
              (string.eq (struct-get item result) "u")
              (= (struct-get item index-param) -1)
              (match (box-get rest)
                [(TlciSpmdSpecializationList.Nil) true]
                [_ false]))]
          [_ false])))))

(cfg
  test
  (test
    build-package-tlci-callable-smoke
    (unless
      (and
        (build-package-tlci-callable-smoke-ok?)
        (build-package-tlci-scalar-collapse-smoke-ok?))
      (io.panic "build package TLCI callable smoke failed"))))

(define (build-package-tlci-collect-decl-callable
  [decl : AstDecl]
  [owned-path : String]
  [module : String]
  [package-name : String]
  [mode : CompilerBackendMode]
  [collector : BuildPackageTlciCallableCollector]) : BuildPackageTlciCallableCollector
  (match decl
    [(AstDecl.DefFn name params ret _ metadata)
      (if (= (string.string-length owned-path) 0)
        collector
        (match (ast-fn-metadata-spmd-callable metadata)
          [(AstSpmdCallable.No) collector]
          [(AstSpmdCallable.Callable specializations)
            (if (match mode
              [(CompilerBackendMode.Avx2) true]
              [_ false])
              (BuildPackageTlciCallableCollector
                (struct-get collector items)
                "build: :spmd-callable is not supported with --backend-mode avx2")
              (BuildPackageTlciCallableCollector
                (build-package-tlci-callable-insert
                  (build-package-tlci-callable
                    package-name
                    module
                    name
                    params
                    ret
                    specializations
                    mode)
                  (struct-get collector items))
                (struct-get collector error)))]))]
    [(AstDecl.Unsafe inner-box)
      (build-package-tlci-collect-decl-callable
        (box-get inner-box)
        owned-path
        module
        package-name
        mode
        collector)]
    [(AstDecl.ComptimeDecl _ inner-box)
      (build-package-tlci-collect-decl-callable
        (box-get inner-box)
        owned-path
        module
        package-name
        mode
        collector)]
    [_ collector]))

(define (build-package-tlci-push-macro-name!
  [out : (&mut out cli_svec.Vec)]
  [name : String]) : unit
  (let
    [index : i64 0]
    [present : bool false]
    (begin
      (while (and (not present) (< index (cli_svec.len out)))
        (if (string.eq (cli_svec.get out index "") name)
          (set! present true)
          (set! index (+ index 1))))
      (if present
        unit
        (cli_svec.push out name)))))

(define (build-package-tlci-collect-decl-macro!
  [decl : AstDecl]
  [owned-path : String]
  [module : String]
  [package-name : String]
  [owned-sources : build_string_i64_map.Map]
  [out : (&mut out cli_svec.Vec)]) : unit
  (match decl
    [(AstDecl.DefMacro name _ _ _)
      (if (= (string.string-length owned-path) 0)
        unit
        (build-package-tlci-push-macro-name!
          out
          (compiler-symbol-module-key
            (if (= (string.string-length module) 0)
              package-name
              module)
            (intern-str name))))]
    [(AstDecl.Unsafe inner-box)
      (build-package-tlci-collect-decl-macro!
        (box-get inner-box)
        owned-path
        module
        package-name
        owned-sources
        out)]
    [(AstDecl.ComptimeDecl _ inner-box)
      (build-package-tlci-collect-decl-macro!
        (box-get inner-box)
        owned-path
        module
        package-name
        owned-sources
        out)]
    [(AstDecl.ModuleBody nested-module body-box)
      (build-package-tlci-collect-macros-into!
        (box-get body-box)
        (ast-decl-path-list-new)
        owned-path
        (intern-str nested-module)
        package-name
        owned-sources
        out)]
    [_ unit]))

(define (build-package-tlci-source-map [sources : cli_svec.Vec]) : build_string_i64_map.Map
  (let
    [out : build_string_i64_map.Map
      (build_string_i64_map.with-capacity
        (+ (* (cli_svec.len (& sources)) 2) 4))]
    [index : i64 0]
    (begin
      (while (< index (cli_svec.len (& sources)))
        (begin
          (build_string_i64_map.insert-ref!
            (&mut out)
            (compiler-load-normalize-path (cli_svec.get (& sources) index ""))
            1)
          (set! index (+ index 1))))
      out)))

(define (build-package-tlci-source-owned?
  [owned-sources : build_string_i64_map.Map]
  [path : String]) : bool
  (match (build_string_i64_map.get
    (& owned-sources)
    (compiler-load-normalize-path path))
    [(build_string_i64_map.LookupFound _) true]
    [(build_string_i64_map.LookupMissing) false]))

(define (build-package-tlci-collect-macros-into!
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [fallback-path : String]
  [initial-module : String]
  [package-name : String]
  [owned-sources : build_string_i64_map.Map]
  [out : (&mut out cli_svec.Vec)]) : unit
  (let
    [decl-cursor : AstDeclList decls]
    [path-cursor : AstDeclPathList paths]
    [module : String initial-module]
    [done : bool false]
    (while (not done)
      (match (ast-decl-list-step decl-cursor)
        [(AstDeclListStep.Nil) (set! done true)]
        [(AstDeclListStep.Cons decl rest)
          (let
            [decl-path : String
              (match (ast-decl-path-list-step path-cursor)
                [(AstDeclPathListStep.Nil) fallback-path]
                [(AstDeclPathListStep.Cons path _) path])]
            [owned-path : String
              (if (build-package-tlci-source-owned? owned-sources decl-path)
                decl-path
                "")]
            (begin
              (match decl
                [(AstDecl.Module name) (set! module (intern-str name))]
                [_
                  (build-package-tlci-collect-decl-macro!
                    decl
                    owned-path
                    module
                    package-name
                    owned-sources
                    out)])
              (set! decl-cursor rest)
              (match (ast-decl-path-list-step path-cursor)
                [(AstDeclPathListStep.Nil) unit]
                [(AstDeclPathListStep.Cons _ path-rest)
                  (set! path-cursor path-rest)])))]))))

(define (build-package-tlci-macro-names
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : (Array String)
  (let
    [out : cli_svec.Vec (cli_svec.new)]
    (begin
      (match (package-source-discover-for "build" manifest-path true)
        [(ResultPackageSourceSet.Err _) unit]
        [(ResultPackageSourceSet.Ok source-set)
          (let
            [owned-sources : build_string_i64_map.Map
              (build-package-tlci-source-map (struct-get source-set sources))]
            (build-package-tlci-collect-macros-into!
              decls
              paths
              ""
              ""
              (struct-get manifest name)
              owned-sources
              (&mut out)))])
      (cli_svec.to-array (& out)))))

(define (build-package-tlci-collect-callables-into!
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [fallback-path : String]
  [initial-module : String]
  [package-name : String]
  [mode : CompilerBackendMode]
  [owned-sources : build_string_i64_map.Map]
  [collector : BuildPackageTlciCallableCollector]) : BuildPackageTlciCallableCollector
  (let
    [decl-cursor : AstDeclList decls]
    [path-cursor : AstDeclPathList paths]
    [module : String initial-module]
    [done : bool false]
    [current : BuildPackageTlciCallableCollector collector]
    (begin
      (while (and
        (not done)
        (= (string.string-length (struct-get current error)) 0))
        (match (ast-decl-list-step decl-cursor)
          [(AstDeclListStep.Nil) (set! done true)]
          [(AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (match (ast-decl-path-list-step path-cursor)
                  [(AstDeclPathListStep.Nil) fallback-path]
                  [(AstDeclPathListStep.Cons path _) path])]
              [owned-path : String
                (if (build-package-tlci-source-owned? owned-sources decl-path)
                  decl-path
                  "")]
              (begin
                (match decl
                  [(AstDecl.Module name) (set! module (intern-str name))]
                  [(AstDecl.ModuleBody nested-module body-box)
                    (set!
                      current
                      (build-package-tlci-collect-callables-into!
                        (box-get body-box)
                        (ast-decl-path-list-new)
                        owned-path
                        (intern-str nested-module)
                        package-name
                        mode
                        owned-sources
                        current))]
                  [_
                    (set!
                      current
                      (build-package-tlci-collect-decl-callable
                        decl
                        owned-path
                        module
                        package-name
                        mode
                        current))])
                (set! decl-cursor rest)
                (match (ast-decl-path-list-step path-cursor)
                  [(AstDeclPathListStep.Nil) unit]
                  [(AstDeclPathListStep.Cons _ path-rest)
                    (set! path-cursor path-rest)])))]))
      current)))

(define (build-package-tlci-callable-collector
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [mode : CompilerBackendMode]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : BuildPackageTlciCallableCollector
  (match (package-source-discover-for "build" manifest-path true)
    [(ResultPackageSourceSet.Err message)
      (BuildPackageTlciCallableCollector TlciSpmdCallableList.Nil message)]
    [(ResultPackageSourceSet.Ok source-set)
      (let
        [owned-sources : build_string_i64_map.Map
          (build-package-tlci-source-map (struct-get source-set sources))]
        (build-package-tlci-collect-callables-into!
          decls
          paths
          ""
          ""
          (struct-get manifest name)
          mode
          owned-sources
          (BuildPackageTlciCallableCollector TlciSpmdCallableList.Nil "")))]))

(define (build-package-tlci-image [metadata : TlciMetadata]) : TlciImage
  (TlciImage
    tlci-host-arch-x86-64
    tlci-callback-abi-version
    build-package-tlci-compiler-build-hash
    metadata
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)
    (tlci-empty-bytes)))

(defenum ResultBuildPackageTlciText
  (Ok String)
  (Err String))

(define (build-package-tlci-text
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [mode : CompilerBackendMode]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultBuildPackageTlciText
  (let
    [collector : BuildPackageTlciCallableCollector
      (build-package-tlci-callable-collector
        manifest-path
        manifest
        mode
        decls
        paths)]
    [macro-names : (Array String)
      (build-package-tlci-macro-names manifest-path manifest decls paths)]
    (if (> (string.string-length (struct-get collector error)) 0)
      (ResultBuildPackageTlciText.Err (struct-get collector error))
      (let
        [metadata : TlciMetadata
          (build-package-tlci-metadata manifest (struct-get collector items))]
        [emitted : ResultTlciBytes
          (if (= (array-length macro-names) 0)
            (tlci-emit-image (build-package-tlci-image metadata))
            (tlci-emit-code-bearing-package-image
              metadata
              build-package-tlci-compiler-build-hash
              macro-names
              (cfg windows true false)))]
        (match emitted
          [(ResultTlciBytes.Err message)
            (ResultBuildPackageTlciText.Err
              (str_cat.str-cat "build: failed to emit package tlci: " message))]
          [(ResultTlciBytes.Ok bytes)
            (ResultBuildPackageTlciText.Ok
              (tlci-bytes->string bytes 0 (array-length bytes)))])))))

(define (build-package-write-tlci [path : String] [text : String]) : SourceToolCommandStatus
  (source-tool-write-file path text "build: failed to write package tlci"))

(define (build-package-finish-built-artifact
  [artifact-path : String]
  [tlci-path : String]
  [tlci-text : String]
  [announce : bool]) : i64
  (match (build-package-write-tlci tlci-path tlci-text)
    [(SourceToolCommandStatus.Err message)
      (begin
        (io.print-error message)
        1)]
    [(SourceToolCommandStatus.Ok)
      (if announce
        (begin
          (io.print-string (str_cat.str-cat "Built " artifact-path "\n"))
          (io.print-string (str_cat.str-cat "Built " tlci-path "\n"))
          0)
        0)]))

(define (build-package-write-assembly
  [path : String]
  [asm : String]
  [target : CompilerBackendTarget]) : SourceToolCommandStatus
  (match (source-tool-write-file
    path
    asm
    "build: failed to write package assembly")
    [(SourceToolCommandStatus.Err message)
      (SourceToolCommandStatus.Err message)]
    [(SourceToolCommandStatus.Ok)
      (let
        [haystack : String asm]
        [needle : String ".note.GNU-stack"]
        [note : String (source-tool-noexecstack-note)]
        (if (and
          (compiler-backend-target-linux? target)
          (not (string.contains (& haystack) (& needle))))
          (match (io.try-append-file (& path) (& note))
            [(io.OkIoUnit) SourceToolCommandStatus.Ok]
            [(io.ErrIoUnit error)
              (SourceToolCommandStatus.Err
                (str_cat.str-cat
                  "build: failed to write package assembly: "
                  (io.error-message error)))])
          SourceToolCommandStatus.Ok))]))

(define (build-package-finish-artifacts
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : SourceToolLinkInputs]
  [tlci-path : String]
  [tlci-text : String]
  [asm : String]
  [direct-object : ResultSourceToolString]
  [announce : bool]) : i64
  (match (build-package-write-assembly asm-path asm target)
    [(SourceToolCommandStatus.Err message)
      (begin
        (io.print-error message)
        1)]
    [(SourceToolCommandStatus.Ok)
      (let
        [direct-status : SourceToolDirectObjectStatus
          (match direct-object
            [(ResultSourceToolString.Ok obj)
              (build-package-write-linux-direct-object-artifact
                kind
                target
                obj-path
                artifact-path
                link-inputs
                obj)]
            [(ResultSourceToolString.Err message)
              (SourceToolDirectObjectStatus.Unavailable message)])]
        (match (build-package-artifact-status
          kind
          target
          asm-path
          obj-path
          artifact-path
          link-inputs
          direct-status)
          [(SourceToolCommandStatus.Err message)
            (begin
              (io.print-error message)
              1)]
          [(SourceToolCommandStatus.Ok)
            (build-package-finish-built-artifact
              artifact-path
              tlci-path
              tlci-text
              announce)]))]))

(define (build-package-emit-assembly-fallback
  [kind : CompilerPkgKind]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : AstDeclList]
  [owned-paths : AstDeclPathList]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [effective-link-inputs : SourceToolLinkInputs]
  [tlci-path : String]
  [tlci-text : String]
  [direct-message : String]
  [announce : bool]) : i64
  (match (compiler-driver-emit-package-loaded
    ""
    target
    true
    opt-level
    mode
    emit-entry
    crt-entry
    decls
    owned-paths)
    [(ResultCompilerDriver.Err diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]
    [(ResultCompilerDriver.Ok asm)
      (begin
        (compiler-driver-release-lower-arenas-after-emit!)
        (compiler-driver-reset-file-state!)
        (build-package-finish-artifacts
          kind
          target
          asm-path
          obj-path
          artifact-path
          effective-link-inputs
          tlci-path
          tlci-text
          asm
          (ResultSourceToolString.Err direct-message)
          announce))]))

(define (build-package-write-side-assembly
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : AstDeclList]
  [owned-paths : AstDeclPathList]
  [asm-path : String]) : SourceToolCommandStatus
  (match (compiler-driver-emit-package-loaded
    ""
    target
    true
    opt-level
    mode
    emit-entry
    crt-entry
    decls
    owned-paths)
    [(ResultCompilerDriver.Err diag)
      (SourceToolCommandStatus.Err (compiler-diagnostic-render (box-get diag)))]
    [(ResultCompilerDriver.Ok asm)
      (begin
        (compiler-driver-release-lower-arenas-after-emit!)
        (build-package-write-assembly asm-path asm target))]))

(define (build-package-doctest-paths [owner : String] [paths : AstDeclPathList]) : AstDeclPathList
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Nil) (ast-decl-path-list-new)]
    [(AstDeclPathListStep.Cons path rest)
      (let
        [tail : AstDeclPathList (build-package-doctest-paths owner rest)]
        (if (build-package-tlci-stdlib-path? owner path)
          tail
          (ast-decl-path-list-prepend-builder path tail)))]))

(define (build-package-closure-doctest-status
  [owner : String]
  [entry-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]) : i64
  (match (compiler-driver-load-package-file-with-runtime
    entry-path
    target
    stdlib-roots
    manifest-dir
    deps
    emit-entry)
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]
    [(ResultCompilerLoadWithPaths.Ok _ paths _ _)
      (build-doctest-typecheck-package-paths
        (build-package-doctest-paths owner paths)
        stdlib-roots
        manifest-dir
        deps)]))

(define (build-inline-test-typecheck-package-sources
  [manifest-path : String]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [name : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : i64
  (match (package-source-discover-for "build" manifest-path true)
    [(ResultPackageSourceSet.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultPackageSourceSet.Ok source-set)
      (tltest-inline-typecheck-package-sources-with-cfg
        (struct-get source-set sources)
        stdlib-roots
        manifest-dir
        name
        deps
        cfgs
        "typecheck-prefix-inline-build-package")]))

(define (build-package-emit-one
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [dep-libs : process.ProcessStringList]
  [announce : bool]) : i64
  (let
    ;; Windows package DAG nodes are serial same-process compiles; keep only
    ;; persistent cache floors between dependency and root emits.
    [_ : unit (cfg windows (compiler-driver-reset-file-state!) unit)]
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    [entry-path : String
      (compiler-load-join-root-path manifest-dir (struct-get manifest entry))]
    [name : String (struct-get manifest name)]
    [_spmd-package-name : unit (lower-spmd-set-package-name! name)]
    [kind : CompilerPkgKind (struct-get manifest kind)]
    [asm-path : String
      (build-package-asm-path-profile manifest-dir name profile)]
    [obj-path : String
      (build-package-obj-path-profile manifest-dir name profile target)]
    [artifact-paths : BuildPackageArtifactPaths
      (build-package-artifact-paths manifest-dir name kind profile target)]
    [artifact-path : String
      (build-package-runtime-artifact-path artifact-paths)]
    [tlci-path : String (build-package-host-tlci-artifact-path artifact-paths)]
    [_reset-file-state : unit (compiler-driver-reset-file-state!)]
    (if (not (build-ensure-package-output-dirs manifest-dir name profile))
      (begin
        (io.print-error
          (str_cat.str-cat
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
        [inline-test-status : i64
          (build-inline-test-typecheck-package-sources
            manifest-path
            stdlib-roots
            manifest-dir
            name
            (struct-get manifest deps)
            (compiler-driver-target-cfgs target (compiler-cfg-empty)))]
        [_reset-after-inline-tests : unit
          (if (= inline-test-status 0)
            (begin
              (compiler-driver-reset-file-state!)
              (intern-persistent-arena-reset!))
            unit)]
        (if (= inline-test-status 0)
          (let
            [pre-emit-doctest-status : i64
              (build-package-run-doctest-worker-or-inline
                name
                entry-path
                manifest-path
                target
                opt-level
                profile
                mode
                lock-policy
                (struct-get manifest deps)
                (compiler-pkg-deps-list (struct-get manifest deps))
                stdlib-roots
                manifest-dir
                emit-entry)]
            [_reset-after-pre-emit-doctests : unit
              (begin
                (compiler-driver-reset-file-state!)
                (intern-persistent-arena-reset!))]
            (if (= pre-emit-doctest-status 0)
              (match (compiler-driver-load-package-file-with-runtime
                entry-path
                target
                stdlib-roots
                manifest-dir
                (struct-get manifest deps)
                emit-entry)
                [(ResultCompilerLoadWithPaths.Err diag)
                  (begin
                    (io.print-error (compiler-diagnostic-render (box-get diag)))
                    1)]
                [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
                  (let
                    [owned-paths : AstDeclPathList
                      (compiler-load-package-owned-paths-for-decls
                        name
                        manifest-dir
                        stdlib-roots
                        entry-path
                        decls
                        paths)]
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
                        (source-tool-linux-crt-entry?
                          target
                          effective-link-inputs))]
                    (match (build-package-tlci-text
                      manifest-path
                      manifest
                      mode
                      decls
                      paths)
                      [(ResultBuildPackageTlciText.Err message)
                        (begin
                          (io.print-error message)
                          1)]
                      [(ResultBuildPackageTlciText.Ok tlci-text)
                        (let
                          ;; Emit linkable ELF before assembly so memory-tight
                          ;; selfhost package builds do not fork `as` while
                          ;; holding the full package assembly string.
                          [direct-status : SourceToolDirectObjectStatus
                            (build-package-try-linux-direct-object
                              kind
                              target
                              opt-level
                              mode
                              emit-entry
                              crt-entry
                              decls
                              owned-paths
                              obj-path
                              artifact-path
                              effective-link-inputs)]
                          (match direct-status
                            [(SourceToolDirectObjectStatus.Ok)
                              (match (build-package-write-side-assembly
                                target
                                opt-level
                                mode
                                emit-entry
                                crt-entry
                                decls
                                owned-paths
                                asm-path)
                                [(SourceToolCommandStatus.Err message)
                                  (begin
                                    (io.print-error message)
                                    1)]
                                [(SourceToolCommandStatus.Ok)
                                  (begin
                                    (compiler-driver-reset-file-state!)
                                    (build-package-finish-built-artifact
                                      artifact-path
                                      tlci-path
                                      tlci-text
                                      announce))])]
                            [(SourceToolDirectObjectStatus.Err message)
                              (begin
                                (io.print-error message)
                                1)]
                            [(SourceToolDirectObjectStatus.Unavailable message)
                              (build-package-emit-assembly-fallback
                                kind
                                target
                                opt-level
                                mode
                                emit-entry
                                crt-entry
                                decls
                                owned-paths
                                asm-path
                                obj-path
                                artifact-path
                                effective-link-inputs
                                tlci-path
                                tlci-text
                                message
                                announce)]))]))])
              pre-emit-doctest-status))
          inline-test-status)))))

(define (build-package-worker-unified-cli?) : bool
  (and
    (> (arg-count) 1)
    (or (string.eq (io.arg 1) "build") (string.eq (io.arg 1) "run"))))

(define (build-package-worker-command-prefix [args : process.ProcessStringList]) : process.ProcessStringList
  (if (build-package-worker-unified-cli?)
    (source-tool-args-append args "build")
    args))

(define (build-package-worker-append-option
  [args : process.ProcessStringList]
  [flag : String]
  [value : String]) : process.ProcessStringList
  (source-tool-args-append (source-tool-args-append args flag) value))

(define (build-package-worker-append-stdlib-roots
  [args : process.ProcessStringList]
  [roots : cli_svec.Vec]) : process.ProcessStringList
  (let
    [i : i64 0]
    [n : i64 (cli_svec.len (& roots))]
    [out : process.ProcessStringList args]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (build-package-worker-append-option
              out
              "--stdlib-root"
              (cli_svec.get (& roots) i "")))
          (set! i (+ i 1))))
      out)))

(define (build-package-worker-append-resolved-deps
  [args : process.ProcessStringList]
  [deps : CompilerPkgDepList]) : process.ProcessStringList
  (match deps
    [(CompilerPkgDepNil) args]
    [(CompilerPkgDepCons dep rest)
      (build-package-worker-append-resolved-deps
        (source-tool-args-append
          (source-tool-args-append
            (source-tool-args-append args "--resolved-dep")
            (struct-get dep alias))
          (struct-get dep path))
        (box-get rest))]))

(define (build-package-worker-resolved-deps-args-smoke-ok?) : bool
  (let
    [remote : CompilerPkgDep
      (CompilerPkgDep "remote" "target/typelisp/git-deps/remote")]
    [local : CompilerPkgDep (CompilerPkgDep "local" "../local")]
    [deps : CompilerPkgDepList
      (CompilerPkgDepCons
        remote
        (box (CompilerPkgDepCons local (box CompilerPkgDepNil))))]
    [actual : process.ProcessStringList
      (build-package-worker-append-resolved-deps (process.args-empty) deps)]
    [expected0 : process.ProcessStringList
      (source-tool-args-append (process.args-empty) "--resolved-dep")]
    [expected1 : process.ProcessStringList
      (source-tool-args-append expected0 "remote")]
    [expected2 : process.ProcessStringList
      (source-tool-args-append expected1 "target/typelisp/git-deps/remote")]
    [expected3 : process.ProcessStringList
      (source-tool-args-append expected2 "--resolved-dep")]
    [expected4 : process.ProcessStringList
      (source-tool-args-append expected3 "local")]
    [expected : process.ProcessStringList
      (source-tool-args-append expected4 "../local")]
    (source-tool-string-list-eq? actual expected)))

(test
  build-package-worker-resolved-deps-args-smoke
  (unless
    (build-package-worker-resolved-deps-args-smoke-ok?)
    (io.panic "build package worker resolved deps args smoke failed")))

(define (build-package-worker-args-with-flag
  [worker-flag : String]
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [resolved-deps : CompilerPkgDepList]
  [stdlib-roots : cli_svec.Vec]) : process.ProcessStringList
  (let
    [args0 : process.ProcessStringList
      (build-package-worker-command-prefix (process.args-empty))]
    [args1 : process.ProcessStringList
      (source-tool-args-append args0 worker-flag)]
    [args2 : process.ProcessStringList
      (build-package-worker-append-option args1 "--manifest-path" manifest-path)]
    [args3 : process.ProcessStringList
      (build-package-worker-append-option
        args2
        "--target"
        (source-tool-target-name target))]
    [args4 : process.ProcessStringList
      (build-package-worker-append-option
        args3
        "--backend-mode"
        (build-backend-mode-name mode))]
    [args5 : process.ProcessStringList
      (build-package-worker-append-option
        args4
        "--profile"
        (build-profile-name profile))]
    [args6 : process.ProcessStringList
      (build-package-worker-append-option
        args5
        "--opt-level"
        (string.int->string opt-level))]
    [args7 : process.ProcessStringList
      (build-package-lock-policy-arg args6 lock-policy)]
    [args8 : process.ProcessStringList
      (build-package-worker-append-resolved-deps args7 resolved-deps)]
    (build-package-worker-append-stdlib-roots args8 stdlib-roots)))

(define (build-package-worker-args
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]) : process.ProcessStringList
  (build-package-worker-args-with-flag
    "--package-worker"
    manifest-path
    target
    opt-level
    profile
    mode
    lock-policy
    CompilerPkgDepNil
    stdlib-roots))

(define (build-package-worker-command
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]) : process.ProcessCommand
  (process.command
    (io.arg 0)
    (build-package-worker-args
      manifest-path
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots)))

(define (build-package-doctest-worker-command
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [resolved-deps : CompilerPkgDepList]
  [stdlib-roots : cli_svec.Vec]) : process.ProcessCommand
  (process.command
    (io.arg 0)
    (build-package-worker-args-with-flag
      "--package-doctest-worker"
      manifest-path
      target
      opt-level
      profile
      mode
      lock-policy
      resolved-deps
      stdlib-roots)))

(define (build-package-worker-spawn-supported?) : bool
  (match (process.output
    (process.command
      (io.arg 0)
      (source-tool-args-append (process.args-empty) "--version")))
    [(process.OkProcessOutput output) (= (process.output-status output) 0)]
    [(process.ErrProcessOutput _) false]))

(define (build-package-run-doctest-worker-or-inline
  [owner : String]
  [entry-path : String]
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [deps : CompilerPkgDeps]
  [resolved-deps : CompilerPkgDepList]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [emit-entry : bool]) : i64
  (match (process.output
    (build-package-doctest-worker-command
      manifest-path
      target
      opt-level
      profile
      mode
      lock-policy
      resolved-deps
      stdlib-roots))
    [(process.OkProcessOutput output)
      (begin
        (source-tool-forward-output output)
        (process.output-status output))]
    [(process.ErrProcessOutput error)
      (if (or
        (process.error-spawn-failed? error)
        (process.error-unsupported? error))
        (begin
          (compiler-driver-reset-file-state!)
          (build-package-closure-doctest-status
            owner
            entry-path
            target
            stdlib-roots
            manifest-dir
            deps
            emit-entry))
        (begin
          (io.print-error
            (str_cat.str-cat
              "build: failed to run package doctest worker: "
              (process.error-message error)))
          1))]))

(define (build-package-worker-run-from [idx : i64] [count : i64]) : i64
  (match (build-package-worker-config-from idx count)
    [(ResultBuildPackageWorkerConfig.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultBuildPackageWorkerConfig.Ok config)
      (let
        [manifest-path : String (struct-get config manifest-path)]
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-load-manifest normalized-path)
          [(ResultBuildManifest.Err message)
            (begin
              (io.print-error (str_cat.str-cat "Error: " message))
              1)]
          [(ResultBuildManifest.Ok manifest)
            (let
              [resolved-deps : CompilerPkgDepList
                (struct-get config resolved-deps)]
              [resolved-manifest-result : ResultBuildManifest
                (match resolved-deps
                  [(CompilerPkgDepNil)
                    (build-package-resolve-manifest-deps
                      normalized-path
                      manifest
                      (struct-get config lock-policy))]
                  [_
                    (ResultBuildManifest.Ok
                      (CompilerPkgManifest
                        (struct-get manifest name)
                        (struct-get manifest version)
                        (struct-get manifest kind)
                        (struct-get manifest entry)
                        (compiler-pkg-deps-from-list resolved-deps)
                        (struct-get manifest link)))])]
              (match resolved-manifest-result
                [(ResultBuildManifest.Err message)
                  (begin
                    (io.print-error message)
                    1)]
                [(ResultBuildManifest.Ok resolved-manifest)
                  (if (build-package-kind-lib?
                    (struct-get resolved-manifest kind))
                    (build-package-emit-one
                      normalized-path
                      resolved-manifest
                      (struct-get config target)
                      (struct-get config opt-level)
                      (struct-get config profile)
                      (struct-get config mode)
                      (struct-get config lock-policy)
                      (struct-get config stdlib-roots)
                      (process.args-empty)
                      true)
                    (begin
                      (io.print-error
                        "build: package worker can only build staticlib packages")
                      1))]))]))]))

(define (build-package-doctest-worker-run-from [idx : i64] [count : i64]) : i64
  (match (build-package-worker-config-from idx count)
    [(ResultBuildPackageWorkerConfig.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultBuildPackageWorkerConfig.Ok config)
      (let
        [manifest-path : String (struct-get config manifest-path)]
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-load-manifest normalized-path)
          [(ResultBuildManifest.Err message)
            (begin
              (io.print-error (str_cat.str-cat "Error: " message))
              1)]
          [(ResultBuildManifest.Ok manifest)
            (let
              [resolved-deps : CompilerPkgDepList
                (struct-get config resolved-deps)]
              [resolved-manifest-result : ResultBuildManifest
                (match resolved-deps
                  [(CompilerPkgDepNil)
                    (build-package-resolve-manifest-deps
                      normalized-path
                      manifest
                      (struct-get config lock-policy))]
                  [_
                    (ResultBuildManifest.Ok
                      (CompilerPkgManifest
                        (struct-get manifest name)
                        (struct-get manifest version)
                        (struct-get manifest kind)
                        (struct-get manifest entry)
                        (compiler-pkg-deps-from-list resolved-deps)
                        (struct-get manifest link)))])]
              (match resolved-manifest-result
                [(ResultBuildManifest.Err message)
                  (begin
                    (io.print-error message)
                    1)]
                [(ResultBuildManifest.Ok resolved-manifest)
                  (let
                    [manifest-dir : String
                      (compiler-load-dirname normalized-path)]
                    [entry-path : String
                      (compiler-load-join-root-path
                        manifest-dir
                        (struct-get resolved-manifest entry))]
                    [kind : CompilerPkgKind (struct-get resolved-manifest kind)]
                    (build-package-closure-doctest-status
                      (struct-get resolved-manifest name)
                      entry-path
                      (struct-get config target)
                      (struct-get config stdlib-roots)
                      manifest-dir
                      (struct-get resolved-manifest deps)
                      (build-package-kind-entry? kind)))]))]))]))

(define (build-package-async-process-supported?) : bool
  (not (string.eq (env.path-list-separator) ";")))

(define (build-package-deps-built?
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [built : build_string_i64_map.Map]) : bool
  (match deps
    [(CompilerPkgDepNil) true]
    [(CompilerPkgDepCons dep rest)
      (let
        [dep-manifest-path : String
          (build-package-dep-manifest-path manifest-dir dep)]
        (match (build_string_i64_map.get (& built) dep-manifest-path)
          [(build_string_i64_map.LookupFound _)
            (build-package-deps-built? manifest-dir (box-get rest) built)]
          [(build_string_i64_map.LookupMissing) false]))]))

(define (build-package-node-ready?
  [node : BuildPackageGraphNode]
  [built : build_string_i64_map.Map]) : bool
  (let
    [manifest-path : String (struct-get node manifest-path)]
    [manifest-dir : String (compiler-load-dirname manifest-path)]
    [manifest : CompilerPkgManifest (struct-get node manifest)]
    (build-package-deps-built?
      manifest-dir
      (compiler-pkg-deps-list (struct-get manifest deps))
      built)))

(define (build-package-node-scheduled?
  [scheduled : build_string_i64_map.Map]
  [manifest-path : String]) : bool
  (match (build_string_i64_map.get (& scheduled) manifest-path)
    [(build_string_i64_map.LookupFound _) true]
    [(build_string_i64_map.LookupMissing) false]))

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
  [stdlib-roots : cli_svec.Vec]) : ResultBuildPackageGraphWorker
  (let
    [manifest-path : String (struct-get node manifest-path)]
    [manifest : CompilerPkgManifest (struct-get node manifest)]
    [name : String (struct-get manifest name)]
    [artifacts : BuildPackageArtifactPaths
      (build-package-graph-node-artifact-paths node profile target)]
    [command : process.ProcessCommand
      (build-package-worker-command
        manifest-path
        target
        opt-level
        profile
        mode
        lock-policy
        stdlib-roots)]
    (match (process.start command)
      [(process.OkProcessChild child)
        (ResultBuildPackageGraphWorker.Ok
          (BuildPackageGraphWorker node artifacts child))]
      [(process.ErrProcessChild error)
        (ResultBuildPackageGraphWorker.Err
          (str_cat.str-cat
            "build: failed to start package dependency `"
            name
            "`: "
            (process.error-message error)))])))

(define (build-package-schedule-pass
  [nodes : BuildPackageGraphNodeVec]
  [scheduled : build_string_i64_map.Map]
  [built : build_string_i64_map.Map]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [workers : BuildPackageGraphWorkerVec]) : ResultBuildPackageSchedulePass
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [next-scheduled : build_string_i64_map.Map scheduled]
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
                  [(ResultBuildPackageGraphWorker.Err message)
                    (begin
                      (set! ok false)
                      (set! error-message message))]
                  [(ResultBuildPackageGraphWorker.Ok worker)
                    (begin
                      (set!
                        next-scheduled
                        (build-string-i64-map-put
                          next-scheduled
                          manifest-path
                          1))
                      (set!
                        next-workers
                        (build-package-graph-worker-vec-push
                          next-workers
                          worker)))])
                unit))
            (set! index (+ index 1)))))
      (if ok
        (ResultBuildPackageSchedulePass.Ok
          (BuildPackageSchedulePass next-scheduled next-workers))
        (ResultBuildPackageSchedulePass.Err error-message)))))

(define (build-package-all-built?
  [nodes : BuildPackageGraphNodeVec]
  [built : build_string_i64_map.Map]) : bool
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
            (match (build_string_i64_map.get (& built) manifest-path)
              [(build_string_i64_map.LookupFound _) unit]
              [(build_string_i64_map.LookupMissing) (set! all-built false)])
            (set! index (+ index 1)))))
      all-built)))

(define (build-package-failure-status [failed-status : i64] [status : i64]) : i64
  (if (= failed-status 0)
    status
    failed-status))

(define (build-package-wait-workers-with
  [workers : BuildPackageGraphWorkerVec]
  [built : build_string_i64_map.Map]
  [announce : bool]
  [failed-status : i64]) : ResultBuildPackageWait
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-worker-vec-len workers)]
    [next-built : build_string_i64_map.Map built]
    [next-failed-status : i64 failed-status]
    (begin
      (while (< index count)
        (let
          [worker : BuildPackageGraphWorker
            (build-package-graph-worker-vec-at workers index)]
          [node : BuildPackageGraphNode (struct-get worker node)]
          [artifacts : BuildPackageArtifactPaths (struct-get worker artifacts)]
          [manifest-path : String (struct-get node manifest-path)]
          [manifest : CompilerPkgManifest (struct-get node manifest)]
          [name : String (struct-get manifest name)]
          [result : process.ResultProcessOutput
            (process.wait (struct-get worker child))]
          (begin
            (match result
              [(process.OkProcessOutput output)
                (begin
                  (if (or announce (not (process.success? output)))
                    (source-tool-forward-output output)
                    unit)
                  (if (process.success? output)
                    (let
                      [runtime-path : String (struct-get artifacts runtime)]
                      [runtime-state : BuildPackageArtifactState
                        (build-package-artifact-file-state runtime-path)]
                      (if (build-package-artifact-state-dirty? runtime-state)
                        (begin
                          (io.print-error
                            (build-package-artifact-status-error-message
                              name
                              "target runtime"
                              runtime-path
                              runtime-state))
                          (set!
                            next-failed-status
                            (build-package-failure-status next-failed-status 1)))
                        (let
                          [tlci-path : String (struct-get artifacts tlci)]
                          [tlci-state : BuildPackageArtifactState
                            (build-package-artifact-file-state tlci-path)]
                          (if (build-package-artifact-state-dirty? tlci-state)
                            (begin
                              (io.print-error
                                (build-package-artifact-status-error-message
                                  name
                                  "host tlci"
                                  tlci-path
                                  tlci-state))
                              (set!
                                next-failed-status
                                (build-package-failure-status
                                  next-failed-status
                                  1)))
                            (set!
                              next-built
                              (build-string-i64-map-put
                                next-built
                                manifest-path
                                1))))))
                    (let
                      [status : i64 (process.output-status output)]
                      (begin
                        (io.print-error
                          (str_cat.str-cat
                            "build: package dependency `"
                            name
                            "` failed with status "
                            (string.int->string status)))
                        (set!
                          next-failed-status
                          (build-package-failure-status
                            next-failed-status
                            status))))))]
              [(process.ErrProcessOutput error)
                (begin
                  (io.print-error
                    (str_cat.str-cat
                      "build: failed to wait for package dependency `"
                      name
                      "`: "
                      (process.error-message error)))
                  (set!
                    next-failed-status
                    (build-package-failure-status next-failed-status 1)))])
            (set! index (+ index 1)))))
      (if (= next-failed-status 0)
        (ResultBuildPackageWait.Ok next-built)
        (ResultBuildPackageWait.Err next-failed-status)))))

(define (build-package-wait-workers
  [workers : BuildPackageGraphWorkerVec]
  [built : build_string_i64_map.Map]
  [announce : bool]) : ResultBuildPackageWait
  (build-package-wait-workers-with workers built announce 0))

(define (build-package-emit-graph-nodes-parallel-loop
  [nodes : BuildPackageGraphNodeVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [announce : bool]
  [scheduled : build_string_i64_map.Map]
  [built : build_string_i64_map.Map]) : i64
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
      [(ResultBuildPackageSchedulePass.Err message)
        (begin
          (io.print-error message)
          1)]
      [(ResultBuildPackageSchedulePass.Ok pass)
        (let
          [workers : BuildPackageGraphWorkerVec (struct-get pass workers)]
          (if (build-package-graph-worker-vec-empty? workers)
            (begin
              (io.print-error
                "build: package dependency scheduler made no progress")
              1)
            (match (build-package-wait-workers workers built announce)
              [(ResultBuildPackageWait.Err status) status]
              [(ResultBuildPackageWait.Ok next-built)
                (build-package-emit-graph-nodes-parallel-loop
                  nodes
                  target
                  opt-level
                  profile
                  mode
                  lock-policy
                  stdlib-roots
                  announce
                  (struct-get pass scheduled)
                  next-built)])))])))

(define (build-package-emit-graph-nodes-parallel
  [nodes : BuildPackageGraphNodeVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [announce : bool]
  [stdlib-roots : cli_svec.Vec]) : i64
  (build-package-emit-graph-nodes-parallel-loop
    nodes
    target
    opt-level
    profile
    mode
    lock-policy
    stdlib-roots
    announce
    (build_string_i64_map.with-capacity 32)
    (build_string_i64_map.with-capacity 32)))

(define (build-package-emit-graph-nodes-serial
  [nodes : BuildPackageGraphNodeVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [announce : bool]) : i64
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
              lock-policy
              stdlib-roots
              (process.args-empty)
              announce)]
          (if (= node-status 0)
            (set! index (+ index 1))
            (begin
              (io.print-error
                (str_cat.str-cat
                  "build: package dependency `"
                  (struct-get manifest name)
                  "` failed with status "
                  (string.int->string node-status)))
              (set! status node-status)))))
      status)))

(define (build-package-emit-graph-nodes
  [nodes : BuildPackageGraphNodeVec]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [announce : bool]) : i64
  (if (and
    (build-package-async-process-supported?)
    (build-package-worker-spawn-supported?))
    (build-package-emit-graph-nodes-parallel
      nodes
      target
      opt-level
      profile
      mode
      lock-policy
      announce
      stdlib-roots)
    (build-package-emit-graph-nodes-serial
      nodes
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots
      announce)))

(define (build-doctest-report [report : DocTestRunReport]) : i64
  (if (doc-test-run-report-ok? report)
    0
    (begin
      (io.print-error (doc-test-run-report-render report))
      1)))

(define (build-doctest-typecheck-file
  [source : String]
  [stdlib-roots : cli_svec.Vec]) : i64
  (match (io.try-read-file (& source))
    [(io.ErrIoString _) 0]
    [(io.OkIoString text)
      (build-doctest-report
        (doc-test-typecheck-source-with-roots source text stdlib-roots))]))

(define (build-doctest-typecheck-package-paths
  [paths : AstDeclPathList]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : i64
  (build-doctest-report
    (doc-test-typecheck-package-paths-with-roots
      paths
      stdlib-roots
      manifest-dir
      deps)))

(define (build-doctest-build-source
  [source : String]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : i64
  (let
    [doctest-status : i64 (build-doctest-typecheck-file source stdlib-roots)]
    (if (= doctest-status 0)
      (let
        [inline-test-status : i64
          (tltest-inline-typecheck-file-with-cfg
            source
            stdlib-roots
            (compiler-driver-target-cfgs target (compiler-cfg-empty))
            "typecheck-prefix-inline-build")]
        (if (= inline-test-status 0)
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
          inline-test-status))
      doctest-status)))

(define (build-package-emit
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target-text : String]
  [_has-target : bool]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [announce : bool]) : i64
  (match (build-parse-target target-text)
    [(ResultBuildTarget.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultBuildTarget.Ok target)
      (let
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-package-resolve-manifest-deps
          normalized-path
          manifest
          lock-policy)
          [(ResultBuildManifest.Err message)
            (begin
              (io.print-error message)
              1)]
          [(ResultBuildManifest.Ok resolved-manifest)
            (match (build-package-dependency-graph
              normalized-path
              resolved-manifest
              lock-policy)
              [(ResultBuildPackageGraph.Err message)
                (begin
                  (io.print-error message)
                  1)]
              [(ResultBuildPackageGraph.Ok graph)
                (let
                  [nodes : BuildPackageGraphNodeVec (struct-get graph order)]
                  [dep-status : i64
                    (build-package-emit-graph-nodes
                      nodes
                      target
                      opt-level
                      profile
                      mode
                      lock-policy
                      stdlib-roots
                      announce)]
                  (if (= dep-status 0)
                    (build-package-emit-one
                      normalized-path
                      resolved-manifest
                      target
                      opt-level
                      profile
                      mode
                      lock-policy
                      stdlib-roots
                      (build-package-graph-link-libs nodes profile target)
                      announce)
                    dep-status))])]))]))

(define (build-package-from-path-announce
  [manifest-path : String]
  [target-text : String]
  [has-target : bool]
  [mode : String]
  [opt-level : i64]
  [profile : BuildProfile]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [announce : bool]) : i64
  (match (source-tool-backend-mode "build" mode)
    [(ResultSourceToolBackendMode.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultSourceToolBackendMode.Ok backend-mode)
      (match (build-load-manifest manifest-path)
        [(ResultBuildManifest.Err message)
          (begin
            (io.print-error (str_cat.str-cat "Error: " message))
            1)]
        [(ResultBuildManifest.Ok manifest)
          (build-package-emit
            manifest-path
            manifest
            target-text
            has-target
            opt-level
            profile
            backend-mode
            lock-policy
            stdlib-roots
            announce)])]))

(define (build-package-from-path
  [manifest-path : String]
  [target-text : String]
  [has-target : bool]
  [mode : String]
  [opt-level : i64]
  [profile : BuildProfile]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]) : i64
  (build-package-from-path-announce
    manifest-path
    target-text
    has-target
    mode
    opt-level
    profile
    lock-policy
    stdlib-roots
    true))

(define (build-package [config : BuildConfig]) : i64
  (match config
    [(BuildConfig.Package
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
              (io.print-error
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
    [(ResultBuildConfig.Ok config)
      (match config
        [(BuildConfig.Source _ _ _ _ _ _ _ _)
          (begin
            (io.print-string (build-source-plan-render config))
            0)]
        [(BuildConfig.Package _ _ _ _ _ _ _ _ _ _) (build-package config)])]
    [(ResultBuildConfig.Err message)
      (begin
        (io.print-error message)
        1)]))

(define (build-args-contain-manifest? [idx : i64] [count : i64]) : bool
  (if (>= idx count)
    false
    (if (string.eq (io.arg idx) "--manifest-path")
      true
      (build-args-contain-manifest? (+ idx 1) count))))

(define (build-cli-unknown-target [value : String]) : String
  (str_cat.str-cat "build: unknown target " value ""))

(define (build-cli-unknown-opt-level [value : String]) : String
  (str_cat.str-cat "build: unknown opt level " value "; expected 0, 1, or 2"))

(defenum BuildCliOption
  (Output)
  (StdlibRoot)
  (Target)
  (BackendMode)
  (OptLevel)
  (Profile)
  (Release)
  (LinkLib)
  (LinkSearch)
  (LinkArg)
  (ManifestPath)
  (Locked)
  (UpdateLock)
  (Other))

(define (build-cli-option-rest6 [current : String]) : BuildCliOption
  (cond
    [(string.eq current "--link-arg") (BuildCliOption.LinkArg)]
    [(string.eq current "--manifest-path") (BuildCliOption.ManifestPath)]
    [(string.eq current "--locked") (BuildCliOption.Locked)]
    [(string.eq current "--update-lock") (BuildCliOption.UpdateLock)]
    [else (BuildCliOption.Other)]))

(define (build-cli-option-rest5 [current : String]) : BuildCliOption
  (if (string.eq current "--link-search")
    (BuildCliOption.LinkSearch)
    (build-cli-option-rest6 current)))

(define (build-cli-option-rest4 [current : String]) : BuildCliOption
  (if (string.eq current "--link-lib")
    (BuildCliOption.LinkLib)
    (build-cli-option-rest5 current)))

(define (build-cli-option-rest3 [current : String]) : BuildCliOption
  (if (string.eq current "--release")
    (BuildCliOption.Release)
    (build-cli-option-rest4 current)))

(define (build-cli-option-rest-profile [current : String]) : BuildCliOption
  (if (string.eq current "--profile")
    (BuildCliOption.Profile)
    (build-cli-option-rest3 current)))

(define (build-cli-option-rest-opt [current : String]) : BuildCliOption
  (if (string.eq current "--opt-level")
    (BuildCliOption.OptLevel)
    (build-cli-option-rest-profile current)))

(define (build-cli-option-rest2 [current : String]) : BuildCliOption
  (if (string.eq current "--backend-mode")
    (BuildCliOption.BackendMode)
    (build-cli-option-rest-opt current)))

(define (build-cli-option-rest1 [current : String]) : BuildCliOption
  (if (string.eq current "--target")
    (BuildCliOption.Target)
    (build-cli-option-rest2 current)))

(define (build-cli-option-rest0 [current : String]) : BuildCliOption
  (if (string.eq current "--stdlib-root")
    (BuildCliOption.StdlibRoot)
    (build-cli-option-rest1 current)))

(define (build-cli-option [current : String]) : BuildCliOption
  (if (string.eq current "-o")
    (BuildCliOption.Output)
    (build-cli-option-rest0 current)))

(define (build-args-have-source? [idx : i64] [count : i64]) : bool
  (if (>= idx count)
    false
    (let
      [current : String (io.arg idx)]
      (match (build-cli-option current)
        [(BuildCliOption.Other)
          (if (source-tool-flag? current)
            (build-args-have-source? (+ idx 1) count)
            true)]
        [(BuildCliOption.Release) (build-args-have-source? (+ idx 1) count)]
        [(BuildCliOption.Locked) (build-args-have-source? (+ idx 1) count)]
        [(BuildCliOption.UpdateLock) (build-args-have-source? (+ idx 1) count)]
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
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]) : ResultBuildCliConfig
  (if (>= idx count)
    (if has-source
      (ResultBuildCliConfig.Ok
        (BuildCliConfig.Config
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
        (ResultBuildCliConfig.Err "build: -o requires a source file argument")
        (ResultBuildCliConfig.Err "build: expected source path")))
    (let
      [current : String (io.arg idx)]
      (match (build-cli-option current)
        [(BuildCliOption.Output)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: -o requires a value")
            (if has-output
              (ResultBuildCliConfig.Err "build: -o was provided more than once")
              (build-cli-parse-options
                (+ idx 2)
                count
                source
                has-source
                (io.arg (+ idx 1))
                true
                target
                mode
                stdlib-roots
                opt-level
                link-inputs)))]
        [(BuildCliOption.StdlibRoot)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: --stdlib-root requires a value")
            (build-cli-parse-options
              (+ idx 2)
              count
              source
              has-source
              output
              has-output
              target
              mode
              (let
                [next-roots : cli_svec.Vec stdlib-roots]
                (begin
                  (cli_svec.push (&mut next-roots) (io.arg (+ idx 1)))
                  next-roots))
              opt-level
              link-inputs))]
        [(BuildCliOption.Target)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: --target requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (match (source-tool-target value)
                [(ResultSourceToolTarget.Ok parsed-target)
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
                [(ResultSourceToolTarget.Err _)
                  (ResultBuildCliConfig.Err (build-cli-unknown-target value))])))]
        [(BuildCliOption.BackendMode)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: --backend-mode requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (match (source-tool-backend-mode "build" value)
                [(ResultSourceToolBackendMode.Ok parsed-mode)
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
                [(ResultSourceToolBackendMode.Err message)
                  (ResultBuildCliConfig.Err message)])))]
        [(BuildCliOption.OptLevel)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: --opt-level requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
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
                  (string.>int value)
                  link-inputs)
                (ResultBuildCliConfig.Err (build-cli-unknown-opt-level value)))))]
        [(BuildCliOption.Profile)
          (ResultBuildCliConfig.Err
            "build: --profile is only valid for package builds")]
        [(BuildCliOption.Release)
          (ResultBuildCliConfig.Err
            "build: --release is only valid for package builds")]
        [(BuildCliOption.Locked)
          (ResultBuildCliConfig.Err
            "build: --locked is only valid for package builds")]
        [(BuildCliOption.UpdateLock)
          (ResultBuildCliConfig.Err
            "build: --update-lock is only valid for package builds")]
        [(BuildCliOption.LinkLib)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: --link-lib requires a value")
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
              (source-tool-link-inputs-add-lib link-inputs (io.arg (+ idx 1)))))]
        [(BuildCliOption.LinkSearch)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: --link-search requires a value")
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
                (io.arg (+ idx 1)))))]
        [(BuildCliOption.LinkArg)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: --link-arg requires a value")
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
              (source-tool-link-inputs-add-raw-arg
                link-inputs
                (io.arg (+ idx 1)))))]
        [(BuildCliOption.ManifestPath)
          (if (>= (+ idx 1) count)
            (ResultBuildCliConfig.Err "build: --manifest-path requires a value")
            (ResultBuildCliConfig.Err
              "build: --manifest-path is handled by Rust typelisp build; selfhost build tool expects a source file"))]
        [(BuildCliOption.Other)
          (if (source-tool-flag? current)
            (ResultBuildCliConfig.Err
              (str_cat.str-cat "build: unknown flag " current))
            (if has-source
              (ResultBuildCliConfig.Err "build: accepts only one source file")
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

(define (build-cli-config-from [idx : i64] [count : i64]) : ResultBuildCliConfig
  (build-cli-parse-options
    idx
    count
    ""
    false
    ""
    false
    (source-tool-default-target)
    (CompilerBackendMode.Scalar)
    (cli_svec.new)
    (compiler-optimize-default-level)
    (source-tool-link-inputs-empty)))

;; Build a source file directly. Manifest builds use the older package parser so
;; `typelisp build` can still discover `typelisp.pkg` from the working tree.
(define (build-source-direct-from [idx : i64] [count : i64]) : i64
  (match (build-cli-config-from idx count)
    [(ResultBuildCliConfig.Ok config)
      (match config
        [(BuildCliConfig.Config
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
    [(ResultBuildCliConfig.Err message)
      (begin
        (io.print-error message)
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
    [(and (> count start) (string.eq (io.arg start) "--package-worker"))
      (build-package-worker-run-from (+ start 1) count)]
    [(and (> count start) (string.eq (io.arg start) "--package-doctest-worker"))
      (build-package-doctest-worker-run-from (+ start 1) count)]
    [(and (> count start) (string.eq (io.arg start) "--direct"))
      (build-direct-from (+ start 1) count)]
    [else (build-direct-from start count)]))