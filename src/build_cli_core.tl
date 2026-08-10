;; build_cli_core.tl - Selfhost build command logic.
;;
;; Source-file builds assemble and link in-process through stdlib fs/process
;; helpers. Package builds are handled in-process by the selfhost compiler:
;; parse/discover `typelisp.pkg`, emit assembly for the manifest entry, and
;; produce the package artifact selected by manifest kind.
(import stdlib.fs)
(import stdlib.array)
(import stdlib.byte_buf)
(import stdlib.env)
(import stdlib.io)
(import stdlib.io_core)
(import stdlib.process)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.hashmap)
(import stdlib.vector)
(import compiler_builtin_ids as cbi)
(import (hashmap.hashmap String i64) as build_string_i64_map)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import host_plan)
(import build_run_core)
(import compiler_backend as backend)
(import compiler_ast_types as ast)
(import compiler_load as load)
(import compiler_symbols as csym)
(import compiler_intern as ci)
(import compiler_ir_types as ir)
(import compiler_lower as lower)
(import compiler_optimize as opt)
(import compiler_object as cobj)
(import compiler_windows_coff_core)
(import doc_test)
(import test_cli_core)
(import package_source_core)
(import package_cache_core)
(import package_lock_core)
(import (vector.vector package_lock_core.PackageLockEntry core) as package_lock_entry_vec)
(import compiler_diagnostic)
(import compiler_parse_core)
(import compiler_driver_core)
(import tlci_core as tlci)
(import compiler_tlci_native_producer)
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
    backend.CompilerBackendTarget
    backend.CompilerBackendMode
    cli_svec.Vec
    i64
    build_run_core.SourceToolLinkInputs))

(defenum ResultBuildCliConfig
  (Ok BuildCliConfig)
  (Err String))

(defenum ResultBuildTarget
  (Ok backend.CompilerBackendTarget)
  (Err String))

(defenum BuildPackageSideAssembly
  (Regenerate)
  (Prepared String))

(defenum ResultBuildPackagePreparedRuntime
  (DirectObject String BuildPackageSideAssembly)
  (Assembly String String)
  (Unavailable String)
  (Err String))

(defenum ResultBuildManifest
  (Ok load.CompilerPkgManifest)
  (Err String))

(defstruct BuildPackageCompileContext
  (root-compiler bool)
  (error String))

(defstruct BuildPackageGraphNode
  (manifest-path String)
  (manifest load.CompilerPkgManifest))

(defstruct BuildPackageArtifactPaths
  (runtime String)
  (tlci String))

(defstruct BuildPackageCommitFile
  (final-path String)
  (staged-path String)
  (backup-path String)
  (had-old bool))

(defstruct BuildPackageCommitPlan
  (files (__tl_dyn-array BuildPackageCommitFile))
  (len i64))

(defstruct BuildPackageStagePaths
  (dir String)
  (asm String)
  (obj String)
  (artifact String)
  (fingerprint String)
  (tlci String))

(defenum ResultBuildPackageStagePaths
  (Ok BuildPackageStagePaths)
  (Err String))

(defenum ResultBuildPackageFileDigest
  (Ok String)
  (Err String))

(defenum BuildPackageArtifactState
  (Clean)
  (Missing)
  (Stale String))

(defstruct BuildPackageGraphNodeVec
  (slots (__tl_dyn-array BuildPackageGraphNode))
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
  (Ok load.CompilerPkgDep)
  (Err String))

(defstruct BuildGitDependency
  (remote String)
  (pin-kind String)
  (pin-value String))

(defstruct BuildResolvedGitDependency
  (dep-root String)
  (lock-entry package_lock_core.PackageLockEntry))

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
  (Some package_lock_core.PackageLockEntry))

(defstruct BuildPackageLockState
  (path String)
  (entries package_lock_entry_vec.Vec)
  (has-lock bool))

(defenum ResultBuildPackageLockState
  (Ok BuildPackageLockState)
  (Err String))

(defstruct BuildResolvedPkgDep
  (dep load.CompilerPkgDep)
  (lock-entry BuildMaybeLockEntry))

(defenum ResultBuildResolvedPkgDep
  (Ok BuildResolvedPkgDep)
  (Err String))

(defstruct BuildResolvedPkgDeps
  (deps load.CompilerPkgDepList)
  (lock-entries package_lock_entry_vec.Vec)
  (has-remote bool))

(defenum ResultBuildResolvedPkgDeps
  (Ok BuildResolvedPkgDeps)
  (Err String))

;; DFS call stack used only for cycle diagnostics. Pushes follow recursion
;; depth and siblings keep the shallower stack alive, so each descent
;; right-sizes a fresh array rather than sharing one growable buffer.
(defstruct BuildPackagePathSeq
  (slots (__tl_dyn-array String))
  (len i64))

(defstruct BuildPackageWorkerConfig
  (manifest-path String)
  (has-manifest bool)
  (target backend.CompilerBackendTarget)
  (mode backend.CompilerBackendMode)
  (profile BuildProfile)
  (opt-level i64)
  (lock-policy BuildPackageLockPolicy)
  (stdlib-roots cli_svec.Vec)
  (resolved-deps load.CompilerPkgDepList))

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
  (slots (__tl_dyn-array BuildPackageGraphWorker))
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
  (Matched package_lock_core.PackageLockEntry)
  (Missing)
  (Stale))

(defenum ResultBuildProfile
  (Ok BuildProfile)
  (Err String))

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

(define (build-string-index-map-put
  [map : build_string_i64_map.Map (:consume)]
  [key : String]
  [value : i64]) : build_string_i64_map.Map
  (let
    [out : build_string_i64_map.Map map]
    (begin
      (build_string_i64_map.insert-ref! (&mut out) key value)
      out)))

(define (build-string-index-map-put!
  [map : (&mut map build_string_i64_map.Map)]
  [key : String]
  [value : i64]) : unit
  (build_string_i64_map.insert-ref! map key value))

(define (build-invalid-manifest-message
  [diag : compiler_diagnostic.CompilerDiagnostic]) : String
  (str_cat.str-cat
    "invalid package manifest '"
    (compiler_diagnostic.compiler-diagnostic-path diag)
    "': "
    (compiler_diagnostic.compiler-diagnostic-message diag)))

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

(define (build-backend-mode-name [mode : backend.CompilerBackendMode]) : String
  (match mode
    [(backend.CompilerBackendMode.Scalar) "scalar"]
    [(backend.CompilerBackendMode.Avx2) "avx2"]
    [(backend.CompilerBackendMode.Avx512) "avx512"]))

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
    [(BuildPackageLockPolicy.Locked)
      (build_run_core.source-tool-args-append args "--locked")]
    [(BuildPackageLockPolicy.Update)
      (build_run_core.source-tool-args-append args "--update-lock")]
    [(BuildPackageLockPolicy.Default) args]))

(define (build-append-stdlib [stdlib-lines : String] [root : String]) : String
  (str_cat.str-cat
    stdlib-lines
    (host_plan.host-plan-netline "stdlib-root" root)))

(define (build-parse-target [value : String]) : ResultBuildTarget
  (if (or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
    (ResultBuildTarget.Ok (backend.CompilerBackendTarget.Linux))
    (if (or
      (string.eq value "windows-x86_64")
      (string.eq value "windows_x86_64"))
      (ResultBuildTarget.Ok (backend.CompilerBackendTarget.Windows))
      (ResultBuildTarget.Err (build-unknown-target value)))))

(define (build-parse-opt-level [value : String]) : i64
  (cond
    [(string.eq value "0") 0]
    [(string.eq value "1") 1]
    [(string.eq value "2") 2]
    [else -1]))

(define (build-parse-common-option
  [kind : cli_option.CliCommonOptionKind]
  [value : String]
  [next-idx : i64]
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
  [stdlib-roots : cli_svec.Vec (:consume)]) : ResultBuildConfig
  (match kind
    [(cli_option.CliCommonOptionKind.StdlibRoot)
      (build-parse-options
        next-idx
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
        (build-append-stdlib stdlib-lines value)
        (let
          [next-roots : cli_svec.Vec stdlib-roots]
          (begin
            (cli_svec.push (&mut next-roots) value)
            next-roots)))]
    [(cli_option.CliCommonOptionKind.Target)
      (if (host_plan.host-plan-target-valid? value)
        (build-parse-options
          next-idx
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
        (ResultBuildConfig.Err (build-unknown-target value)))]
    [(cli_option.CliCommonOptionKind.OptLevel)
      (if has-opt-level
        (ResultBuildConfig.Err "build: --opt-level was provided more than once")
        (let
          [parsed : i64 (build-parse-opt-level value)]
          (if (< parsed 0)
            (ResultBuildConfig.Err (build-unknown-opt-level value))
            (build-parse-options
              next-idx
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
              stdlib-roots))))]
    [(cli_option.CliCommonOptionKind.Cfg)
      (ResultBuildConfig.Err "build: internal unsupported common option")]))

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
      (match (cli_option.cli-common-option-parse
        current
        idx
        count
        cli_option.cli-common-option-build)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultBuildConfig.Err
            (cli_option.cli-common-option-missing-message "build" kind))]
        [(cli_option.CliCommonOption.Value kind value next-idx)
          (build-parse-common-option
            kind
            value
            next-idx
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
            stdlib-lines
            stdlib-roots)]
        [(cli_option.CliCommonOption.NotCommon)
          (cond
            [(or (string.eq current "--debug") (string.eq current "-g"))
              (begin
                (ir.compiler-debug-info-set-enabled! true)
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
                  lock-policy
                  stdlib-lines
                  stdlib-roots))]
            [(string.eq current "-o")
              (if (>= (+ idx 1) count)
                (ResultBuildConfig.Err "build: -o requires a value")
                (if has-output
                  (ResultBuildConfig.Err
                    "build: -o was provided more than once")
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
                (ResultBuildConfig.Err
                  "build: --manifest-path requires a value")
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
            [(string.eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ResultBuildConfig.Err "build: --backend-mode requires a value")
                (let
                  [value : String (io.arg (+ idx 1))]
                  (if (host_plan.host-plan-backend-mode-valid? value)
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
                (ResultBuildConfig.Err
                  "build: profile was provided more than once")
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
            [(host_plan.host-plan-flag? current)
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
                  stdlib-roots))])]))))

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
    (host_plan.host-plan-default-target)
    false
    "scalar"
    (build-default-profile)
    false
    (build-package-default-opt-level)
    false
    (BuildPackageLockPolicy.Default)
    ""
    (cli_svec.new)))

(define (build-package-worker-parse-common-option
  [kind : cli_option.CliCommonOptionKind]
  [value : String]
  [next-idx : i64]
  [count : i64]
  [manifest-path : String]
  [has-manifest : bool]
  [target : backend.CompilerBackendTarget]
  [mode : backend.CompilerBackendMode]
  [profile : BuildProfile]
  [opt-level : i64]
  [has-opt-level : bool]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec (:consume)]
  [resolved-deps : load.CompilerPkgDepList]) : ResultBuildPackageWorkerConfig
  (match kind
    [(cli_option.CliCommonOptionKind.StdlibRoot)
      (build-package-worker-parse-options
        next-idx
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
            (cli_svec.push (&mut next-roots) value)
            next-roots))
        resolved-deps)]
    [(cli_option.CliCommonOptionKind.Target)
      (match (build_run_core.source-tool-target value)
        [(build_run_core.ResultSourceToolTarget.Ok parsed-target)
          (build-package-worker-parse-options
            next-idx
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
        [(build_run_core.ResultSourceToolTarget.Err _)
          (ResultBuildPackageWorkerConfig.Err (build-cli-unknown-target value))])]
    [(cli_option.CliCommonOptionKind.OptLevel)
      (if (build_run_core.source-tool-opt-level-valid? value)
        (build-package-worker-parse-options
          next-idx
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
        (ResultBuildPackageWorkerConfig.Err (build-unknown-opt-level value)))]
    [(cli_option.CliCommonOptionKind.Cfg)
      (ResultBuildPackageWorkerConfig.Err
        "build: internal unsupported common option")]))

(define (build-package-worker-parse-options
  [idx : i64]
  [count : i64]
  [manifest-path : String]
  [has-manifest : bool]
  [target : backend.CompilerBackendTarget]
  [mode : backend.CompilerBackendMode]
  [profile : BuildProfile]
  [opt-level : i64]
  [has-opt-level : bool]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [resolved-deps : load.CompilerPkgDepList]) : ResultBuildPackageWorkerConfig
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
          resolved-deps))
      (ResultBuildPackageWorkerConfig.Err
        "build: --package-worker requires --manifest-path"))
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        current
        idx
        count
        cli_option.cli-common-option-build)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultBuildPackageWorkerConfig.Err
            (cli_option.cli-common-option-missing-message "build" kind))]
        [(cli_option.CliCommonOption.Value kind value next-idx)
          (build-package-worker-parse-common-option
            kind
            value
            next-idx
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
            resolved-deps)]
        [(cli_option.CliCommonOption.NotCommon)
          (cond
            [(or (string.eq current "--debug") (string.eq current "-g"))
              (begin
                (ir.compiler-debug-info-set-enabled! true)
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
                  lock-policy
                  stdlib-roots
                  resolved-deps))]
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
            [(string.eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ResultBuildPackageWorkerConfig.Err
                  "build: --backend-mode requires a value")
                (let
                  [value : String (io.arg (+ idx 1))]
                  (match (build_run_core.source-tool-backend-mode "build" value)
                    [(build_run_core.ResultSourceToolBackendMode.Ok parsed-mode)
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
                    [(build_run_core.ResultSourceToolBackendMode.Err message)
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
                  (load.compiler-pkg-dep-list-push
                    resolved-deps
                    (load.CompilerPkgDep (io.arg (+ idx 1)) (io.arg (+ idx 2))))))]
            [(host_plan.host-plan-flag? current)
              (ResultBuildPackageWorkerConfig.Err
                (str_cat.str-cat "build: unknown package worker flag " current))]
            [else
              (ResultBuildPackageWorkerConfig.Err
                (str_cat.str-cat
                  "build: unexpected package worker argument "
                  current))])]))))

(define (build-package-worker-config-from [idx : i64] [count : i64]) : ResultBuildPackageWorkerConfig
  (build-package-worker-parse-options
    idx
    count
    ""
    false
    (build_run_core.source-tool-default-target)
    (backend.CompilerBackendMode.Scalar)
    (build-default-profile)
    (build-package-default-opt-level)
    false
    (BuildPackageLockPolicy.Default)
    (cli_svec.new)
    (load.compiler-pkg-dep-list-empty)))

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
        (host_plan.host-plan-header)
        (host_plan.host-plan-word-line "action" "build-source")
        (host_plan.host-plan-netline "source" source)
        (if has-output
          (host_plan.host-plan-netline "output" output)
          "")
        (host_plan.host-plan-word-line "target" target)
        (host_plan.host-plan-word-line "backend-mode" mode)
        (if (string.eq opt-level "")
          ""
          (host_plan.host-plan-word-line "opt-level" opt-level))
        stdlib-lines
        "end\n")]
    [_ ""]))

(define (build-discover-manifest-up [prefix : String] [fuel : i64]) : load.CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (str_cat.str-cat prefix "typelisp.pkg")]
      (if (io.file-exists? candidate)
        (CompilerLoadSomePath candidate)
        (build-discover-manifest-up (str_cat.str-cat prefix "../") (- fuel 1))))))

(define (build-load-manifest [manifest-path : String]) : ResultBuildManifest
  (if (io.file-exists? manifest-path)
    (match (load.compiler-load-parse-manifest-diagnostic-infer-kind
      manifest-path
      (byte_buf.to-string (io.read-file manifest-path)))
      [(load.ResultCompilerPkgManifestDiagnostic.Ok manifest)
        (ResultBuildManifest.Ok manifest)]
      [(load.ResultCompilerPkgManifestDiagnostic.Err diag)
        (ResultBuildManifest.Err
          (build-invalid-manifest-message (__tl-box-place diag)))])
    (ResultBuildManifest.Err
      (str_cat.str-cat "cannot read package manifest '" manifest-path "'"))))

(define (build-package-output-dir [manifest-dir : String] [name : String]) : String
  (build-package-output-dir-profile manifest-dir name (build-default-profile)))

(define (build-package-output-dir-profile
  [manifest-dir : String]
  [_name : (& name str)]
  [profile : BuildProfile]) : String
  (load.compiler-load-join-root-path
    (load.compiler-load-join-root-path manifest-dir "target")
    (build-profile-name profile)))

(define (build-package-asm-path [manifest-dir : String] [name : String]) : String
  (build-package-asm-path-profile manifest-dir name (build-default-profile)))

(define (build-package-asm-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat name ".s")))

(define (build-package-obj-path
  [manifest-dir : String]
  [name : String]
  [target : backend.CompilerBackendTarget]) : String
  (build-package-obj-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-obj-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : backend.CompilerBackendTarget]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat
      name
      "."
      (build_run_core.source-tool-object-extension target))))

(define (build-package-bin-path
  [manifest-dir : String]
  [name : String]
  [target : backend.CompilerBackendTarget]) : String
  (build-package-bin-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-bin-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : backend.CompilerBackendTarget]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat
      name
      (build_run_core.source-tool-executable-extension target))))

(define (build-package-lib-path
  [manifest-dir : String]
  [name : String]
  [target : backend.CompilerBackendTarget]) : String
  (build-package-lib-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-lib-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : backend.CompilerBackendTarget]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (build_run_core.source-tool-static-library-filename name target)))

(define (build-package-tlci-path [manifest-dir : String] [name : String]) : String
  (build-package-tlci-path-profile manifest-dir name (build-default-profile)))

(define (build-package-tlci-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat name ".tlci")))

(define (build-package-artifact-path-profile
  [manifest-dir : String]
  [name : String]
  [kind : load.CompilerPkgKind]
  [profile : BuildProfile]
  [target : backend.CompilerBackendTarget]) : String
  (match kind
    [(CompilerPkgKindBin)
      (build-package-bin-path-profile manifest-dir name profile target)]
    [(CompilerPkgKindLib)
      (build-package-lib-path-profile manifest-dir name profile target)]))

;; The v2 tlci image follows the build host: it is the host comptime
;; interface (metadata-only or code-bearing), separate from the
;; runtime-target artifact, which still carries the selected target through
;; its filename/extension.
(define (build-package-artifact-paths
  [manifest-dir : String]
  [name : String]
  [kind : load.CompilerPkgKind]
  [profile : BuildProfile]
  [target : backend.CompilerBackendTarget]) : BuildPackageArtifactPaths
  (BuildPackageArtifactPaths
    (build-package-artifact-path-profile manifest-dir name kind profile target)
    (build-package-tlci-path-profile manifest-dir name profile)))

(define (build-package-runtime-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  artifacts.runtime)

(define (build-package-host-tlci-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  artifacts.tlci)

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
        (backend.CompilerBackendTarget.Windows))
      "root/app/target/release/pkg.exe")
    (string.eq
      (build-package-lib-path-profile
        "root/app"
        "pkg"
        (BuildProfile.Release)
        (backend.CompilerBackendTarget.Linux))
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
          (backend.CompilerBackendTarget.Windows)))
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

(define (build-package-kind-lib? [kind : load.CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindLib) true]
    [_ false]))

(define (build-package-kind-entry? [kind : load.CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (build-package-dep-root
  [manifest-dir : String]
  [dep : load.CompilerPkgDep]) : String
  (load.compiler-load-normalize-path
    (load.compiler-load-join-root-path manifest-dir dep.path)))

(define (build-package-dep-manifest-path
  [manifest-dir : String]
  [dep : load.CompilerPkgDep]) : String
  (load.compiler-load-normalize-path
    (load.compiler-load-join-root-path
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
  (load.compiler-load-normalize-path
    (load.compiler-load-join-root-path
      manifest-dir
      (build-github-dep-relative-root alias))))

(define (build-github-dep-cache-manifest-path
  [manifest-dir : String]
  [alias : String]) : String
  (load.compiler-load-normalize-path
    (load.compiler-load-join-root-path
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
              (if (load.compiler-load-github-pin-kind-valid? kind-for-check)
                (ResultBuildGitDependency.Ok
                  (BuildGitDependency remote kind value))
                (ResultBuildGitDependency.Err
                  (build-git-dep-error alias "has invalid pin kind"))))))))))

(define (build-git-dep-pin-kind
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : package_cache_core.ResultPackageCachePinKind
  (let
    [kind : String (string.copy (& dep.pin-kind))]
    (cond
      [(string.eq kind "rev")
        (package_cache_core.ResultPackageCachePinKind.Ok
          (package_cache_core.PackageCachePinKind.Rev))]
      [(string.eq kind "tag")
        (package_cache_core.ResultPackageCachePinKind.Ok
          (package_cache_core.PackageCachePinKind.Tag))]
      [(string.eq kind "branch")
        (package_cache_core.ResultPackageCachePinKind.Ok
          (package_cache_core.PackageCachePinKind.Branch))]
      [else
        (package_cache_core.ResultPackageCachePinKind.Err
          (build-git-dep-error alias "has invalid pin kind"))])))

(define (build-package-lock-path [manifest-dir : String]) : String
  (load.compiler-load-join-root-path manifest-dir "typelisp.lock"))

(define (build-load-package-lock [manifest-dir : String]) : ResultBuildPackageLockState
  (let
    [path : String (build-package-lock-path manifest-dir)]
    (if (io.file-exists? path)
      (match (io.try-read-file (& path))
        [(io.ErrIoBytes error)
          (ResultBuildPackageLockState.Err
            (str_cat.str-cat
              "build: cannot read package lock '"
              path
              "': "
              (io.error-message error)))]
        [(io.OkIoBytes source)
          (match (package_lock_core.package-lock-parse
            (byte_buf.to-string source))
            [(package_lock_core.ResultPackageLockFile.Err message)
              (ResultBuildPackageLockState.Err
                (str_cat.str-cat
                  "build: invalid package lock '"
                  path
                  "': "
                  message))]
            [(package_lock_core.ResultPackageLockFile.Ok lock)
              (ResultBuildPackageLockState.Ok
                (BuildPackageLockState path lock.entries true))])])
      (ResultBuildPackageLockState.Ok
        (BuildPackageLockState path (package_lock_entry_vec.new) false)))))

(define (build-write-package-lock
  [state : BuildPackageLockState]
  [entries : package_lock_entry_vec.Vec]) : ResultBuildString
  (let
    [lock : package_lock_core.PackageLockFile
      (package_lock_core.PackageLockFile
        (package_lock_core.package-lock-version-shared-view)
        entries)]
    [text : String (package_lock_core.package-lock-emit lock)]
    [path : String state.path]
    (match (io.try-write-file (& path) (byte_buf.str-as-bytes (& text)))
      [(io.OkIoUnit) (ResultBuildString.Ok path)]
      [(io.ErrIoUnit error)
        (ResultBuildString.Err
          (str_cat.str-cat
            "build: cannot write package lock '"
            path
            "': "
            (io.error-message error)))])))

(define (build-package-lock-entry-matches?
  [entry : package_lock_core.PackageLockEntry]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : bool
  (match (build-git-dep-pin-kind alias dep)
    [(package_cache_core.ResultPackageCachePinKind.Err _) false]
    [(package_cache_core.ResultPackageCachePinKind.Ok kind)
      (and
        (string.eq (& entry.alias) alias)
        (string.eq (& entry.url) (& dep.remote))
        (package_cache_core.package-cache-pin-kind-eq? entry.pin-kind kind)
        (string.eq (& entry.pin-value) (& dep.pin-value)))]))

(define (build-package-lock-matching-entry
  [entries : package_lock_entry_vec.Vec]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : BuildMaybeLockEntry
  (match (package_lock_core.package-lock-entry-list-lookup entries alias)
    [(package_lock_core.PackageLockMaybeEntry.No) (BuildMaybeLockEntry.No)]
    [(package_lock_core.PackageLockMaybeEntry.Some entry)
      (if (build-package-lock-entry-matches? entry alias dep)
        (BuildMaybeLockEntry.Some entry)
        (BuildMaybeLockEntry.No))]))

(define (build-package-lock-entry-status
  [entries : package_lock_entry_vec.Vec]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : BuildPackageLockEntryStatus
  (match (package_lock_core.package-lock-entry-list-lookup entries alias)
    [(package_lock_core.PackageLockMaybeEntry.No)
      (BuildPackageLockEntryStatus.Missing)]
    [(package_lock_core.PackageLockMaybeEntry.Some entry)
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
  [commit : String]) : package_lock_core.ResultPackageLockEntry
  (match (build-git-dep-pin-kind alias dep)
    [(package_cache_core.ResultPackageCachePinKind.Err message)
      (package_lock_core.ResultPackageLockEntry.Err message)]
    [(package_cache_core.ResultPackageCachePinKind.Ok kind)
      (package_lock_core.ResultPackageLockEntry.Ok
        (package_lock_core.PackageLockEntry
          alias
          (string.copy (& dep.remote))
          kind
          (string.copy (& dep.pin-value))
          commit))]))

(define (build-git-dependency-at-commit
  [dep : (& dep BuildGitDependency)]
  [commit : String]) : BuildGitDependency
  (BuildGitDependency (string.copy (& dep.remote)) "rev" commit))

(define (build-git-checkout-ref [dep : (& dep BuildGitDependency)]) : String
  (let
    [kind : String (string.copy (& dep.pin-kind))]
    (if (string.eq kind "branch")
      (str_cat.str-cat "origin/" (string.copy (& dep.pin-value)))
      (string.copy (& dep.pin-value)))))

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
  (build_run_core.source-tool-git-clone-command remote root))

(define (build-git-checkout-command [root : String] [checkout-ref : String]) : process.ProcessCommand
  (build_run_core.source-tool-git-checkout-command root checkout-ref))

(define (build-git-rev-parse-command [root : String]) : process.ProcessCommand
  (build_run_core.source-tool-git-rev-parse-command root))

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
  (load.compiler-load-normalize-path
    (load.compiler-load-join-root-path manifest-dir dep-root)))

(define (build-ensure-github-cache-parent
  [manifest-dir : String]
  [alias : String]) : ResultBuildString
  (let
    [target-dir : String
      (load.compiler-load-join-root-path (string.copy manifest-dir) "target")]
    [typelisp-dir : String
      (load.compiler-load-join-root-path (string.copy target-dir) "typelisp")]
    [deps-dir : String
      (load.compiler-load-join-root-path (string.copy typelisp-dir) "git-deps")]
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
  (load.compiler-load-normalize-path
    (load.compiler-load-join-root-path
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
  (string.eq (& dep.pin-kind) "rev"))

(define (build-package-cache-relative-root) : String
  "target/typelisp/cache/packages/v1")

(define (build-package-cache-manifest-path [entry-path : (& entry-path str)]) : String
  (string.append entry-path "/typelisp.pkg"))

(define (build-ensure-package-cache-root
  [manifest-dir : String]
  [alias : String]) : ResultBuildString
  (let
    [target-dir : String
      (load.compiler-load-join-root-path (string.copy manifest-dir) "target")]
    [typelisp-dir : String
      (load.compiler-load-join-root-path (string.copy target-dir) "typelisp")]
    [cache-dir : String
      (load.compiler-load-join-root-path (string.copy typelisp-dir) "cache")]
    [packages-dir : String
      (load.compiler-load-join-root-path (string.copy cache-dir) "packages")]
    [root : String (package_cache_core.package-cache-default-root manifest-dir)]
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
  [key : (& key package_cache_core.PackageCacheKey)]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 16)
    (ResultBuildString.Err
      (build-git-dep-error alias "package cache has no free staging path"))
    (let
      [staged : String
        (package_cache_core.package-cache-staging-path root key attempt)]
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
  [key : (& key package_cache_core.PackageCacheKey)]) : ResultBuildString
  (match (package_cache_core.package-cache-finalize-staged
    staged-path
    entry-path)
    [(io.OkIoUnit) (ResultBuildString.Ok relative-entry-root)]
    [(io.ErrIoUnit error)
      (match (package_cache_core.package-cache-entry-state entry-path key)
        [(package_cache_core.PackageCacheEntryState.CompleteHit _)
          (build-package-cache-hit-result alias entry-path relative-entry-root)]
        [_
          (ResultBuildString.Err
            (build-package-cache-io-error alias "package cache finalize" error))])]))

(define (build-package-cache-write-marker
  [alias : String]
  [staged-path : String]
  [key : (& key package_cache_core.PackageCacheKey)]) : ResultBuildString
  (match (package_cache_core.package-cache-write-complete-marker
    staged-path
    key)
    [(io.OkIoUnit) (ResultBuildString.Ok staged-path)]
    [(io.ErrIoUnit error)
      (ResultBuildString.Err
        (build-package-cache-io-error alias "package cache write marker" error))]))

(define (build-package-cache-prepare-entry-parents-result
  [alias : String]
  [root : String]
  [key : (& key package_cache_core.PackageCacheKey)]) : ResultBuildString
  (match (package_cache_core.package-cache-prepare-entry-parents root key)
    [(io.OkIoUnit) (ResultBuildString.Ok root)]
    [(io.ErrIoUnit error)
      (ResultBuildString.Err
        (build-package-cache-io-error alias "package cache prepare entry" error))]))

(define (build-package-cache-fetch-staged
  [alias : String]
  [dep : (& dep BuildGitDependency)]
  [root : String]
  [key : (& key package_cache_core.PackageCacheKey)]
  [entry-path : String]
  [relative-entry-root : String]
  [replace-existing : bool]) : ResultBuildString
  (match (package_cache_core.package-cache-prepare-staging-parents root key)
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
            (build-git-clone-command (string.copy (& dep.remote)) staged-path))
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
    [remote : String (string.copy (& dep.remote))]
    [pin-value : String (string.copy (& dep.pin-value))]
    [key : package_cache_core.PackageCacheKey
      (package_cache_core.PackageCacheKey remote pin-value)]
    [root : String (package_cache_core.package-cache-default-root manifest-dir)]
    [entry-path : String
      (package_cache_core.package-cache-entry-path root (& key))]
    [relative-root : String (build-package-cache-relative-root)]
    [relative-entry-root : String
      (load.compiler-load-normalize-path
        (package_cache_core.package-cache-entry-path (& relative-root) (& key)))]
    [state : package_cache_core.PackageCacheEntryState
      (package_cache_core.package-cache-entry-state entry-path (& key))]
    (match state
      [(package_cache_core.PackageCacheEntryState.CompleteHit _)
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
      [(package_cache_core.PackageCacheEntryState.Miss _)
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
      [(package_cache_core.PackageCacheEntryState.PartialOrCorrupt _ _)
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
      (build-git-clone-command (string.copy (& dep.remote)) root))))

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
  [entry : package_lock_core.PackageLockEntry]) : ResultBuildResolvedGitDependency
  (let
    [locked-commit : String entry.commit]
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
            (ResultBuildString.Ok (string.copy (& dep.pin-value)))
            (build-resolve-git-head
              alias
              (build-absolute-dep-root manifest-dir dep-root)))]
        (match commit-result
          [(ResultBuildString.Err message)
            (ResultBuildResolvedGitDependency.Err message)]
          [(ResultBuildString.Ok commit)
            (match (build-package-lock-entry alias (& dep) commit)
              [(package_lock_core.ResultPackageLockEntry.Err message)
                (ResultBuildResolvedGitDependency.Err message)]
              [(package_lock_core.ResultPackageLockEntry.Ok entry)
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
  [dep : load.CompilerPkgDep]) : ResultBuildResolvedPkgDep
  (let
    [path : String dep.path]
    [alias : String dep.alias]
    [path-for-kind : String (string.copy (& path))]
    (if (load.compiler-load-github-dependency-path? path-for-kind)
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
                    (load.CompilerPkgDep alias resolved.dep-root)
                    (BuildMaybeLockEntry.Some resolved.lock-entry)))])]))
      (ResultBuildResolvedPkgDep.Ok
        (BuildResolvedPkgDep
          (load.CompilerPkgDep alias path)
          (BuildMaybeLockEntry.No))))))

(define (build-package-resolve-dep
  [manifest-dir : String]
  [dep : load.CompilerPkgDep]) : ResultBuildPkgDep
  (match (build-package-resolve-dep-with-lock
    manifest-dir
    (package_lock_entry_vec.new)
    (BuildPackageLockPolicy.Default)
    dep)
    [(ResultBuildResolvedPkgDep.Err message) (ResultBuildPkgDep.Err message)]
    [(ResultBuildResolvedPkgDep.Ok resolved)
      (ResultBuildPkgDep.Ok resolved.dep)]))

(define (build-package-lock-entry-list-add
  [entries : package_lock_entry_vec.Vec]
  [maybe-entry : BuildMaybeLockEntry]) : package_lock_core.ResultPackageLockEntryList
  (match maybe-entry
    [(BuildMaybeLockEntry.No)
      (package_lock_core.ResultPackageLockEntryList.Ok entries)]
    [(BuildMaybeLockEntry.Some entry)
      (package_lock_core.package-lock-entry-list-insert entries entry)]))

(define (build-package-lock-list-has-exact-entry?
  [entries : package_lock_entry_vec.Vec]
  [entry : package_lock_core.PackageLockEntry]) : bool
  (package_lock_core.package-lock-list-has-entry?
    entries
    entry.alias
    entry.url
    entry.pin-kind
    entry.pin-value
    entry.commit))

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
          (package_lock_core.package-lock-entry-list-fallback)))
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
    (if (and resolved.has-remote (not lock-state.has-lock))
      (ResultBuildString.Err
        "build: --locked requires typelisp.lock for remote dependencies; run with --update-lock to refresh typelisp.lock")
      (if (and
        lock-state.has-lock
        (not
          (build-package-lock-list-eq? lock-state.entries resolved.lock-entries)))
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
    (or resolved.has-remote lock-state.has-lock))
    (build-write-package-lock lock-state resolved.lock-entries)
    (ResultBuildString.Ok "")))

(define (build-package-resolve-deps-with-lock
  [manifest-dir : String]
  [lock-entries : package_lock_entry_vec.Vec]
  [lock-policy : BuildPackageLockPolicy]
  [deps : load.CompilerPkgDepList]
  [index : i64]) : ResultBuildResolvedPkgDeps
  (if (>= index (load.compiler-pkg-dep-list-count deps))
    (ResultBuildResolvedPkgDeps.Ok
      (BuildResolvedPkgDeps
        (load.compiler-pkg-dep-list-empty)
        (package_lock_entry_vec.new)
        false))
    (match (build-package-resolve-dep-with-lock
      manifest-dir
      lock-entries
      lock-policy
      (load.compiler-pkg-dep-list-at deps index))
      [(ResultBuildResolvedPkgDep.Err message)
        (ResultBuildResolvedPkgDeps.Err message)]
      [(ResultBuildResolvedPkgDep.Ok resolved-dep)
        (match (build-package-resolve-deps-with-lock
          manifest-dir
          lock-entries
          lock-policy
          deps
          (+ index 1))
          [(ResultBuildResolvedPkgDeps.Err message)
            (ResultBuildResolvedPkgDeps.Err message)]
          [(ResultBuildResolvedPkgDeps.Ok resolved-rest)
            (match (build-package-lock-entry-list-add
              resolved-rest.lock-entries
              resolved-dep.lock-entry)
              [(package_lock_core.ResultPackageLockEntryList.Err message)
                (ResultBuildResolvedPkgDeps.Err message)]
              [(package_lock_core.ResultPackageLockEntryList.Ok
                  next-lock-entries)
                (ResultBuildResolvedPkgDeps.Ok
                  (BuildResolvedPkgDeps
                    (load.compiler-pkg-dep-list-cons
                      resolved-dep.dep
                      resolved-rest.deps)
                    next-lock-entries
                    (or
                      resolved-rest.has-remote
                      (match resolved-dep.lock-entry
                        [(BuildMaybeLockEntry.No) false]
                        [(BuildMaybeLockEntry.Some _) true]))))])])])))

(define (build-package-resolve-manifest-deps
  [manifest-path : String]
  [manifest : load.CompilerPkgManifest]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildManifest
  (let
    [manifest-dir : String (load.compiler-load-dirname manifest-path)]
    (match (build-load-package-lock manifest-dir)
      [(ResultBuildPackageLockState.Err message)
        (ResultBuildManifest.Err message)]
      [(ResultBuildPackageLockState.Ok lock-state)
        (match (build-package-resolve-deps-with-lock
          manifest-dir
          lock-state.entries
          lock-policy
          (load.compiler-pkg-deps-list manifest.deps)
          0)
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
                      (load.CompilerPkgManifest
                        manifest.name
                        manifest.version
                        manifest.kind
                        manifest.entry
                        (load.compiler-pkg-deps-from-list resolved.deps)
                        manifest.link))])])])])))

(define (build-package-normalize-manifest-path [manifest-path : String]) : String
  (load.compiler-load-normalize-path manifest-path))

(define (build-package-path-seq-push
  [paths : BuildPackagePathSeq]
  [path : String]) : BuildPackagePathSeq
  (let
    [count : i64 paths.len]
    [slots : (__tl_dyn-array String) (make-array String (+ count 1))]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (array-ref paths.slots index))
          (set! index (+ index 1))))
      (set! (array-ref slots count) path)
      (BuildPackagePathSeq slots (+ count 1)))))

(define (build-package-path-seq-render [paths : BuildPackagePathSeq]) : String
  (let
    [out : String ""]
    [index : i64 0]
    (begin
      (while (< index paths.len)
        (let
          [path : String (array-ref paths.slots index)]
          (begin
            (set!
              out
              (if (= index 0)
                path
                (str_cat.str-cat out " -> " path)))
            (set! index (+ index 1)))))
      out)))

(define (build-package-cycle-message
  [stack : BuildPackagePathSeq]
  [manifest-path : String]) : String
  (str_cat.str-cat
    "build: dependency cycle: "
    (build-package-path-seq-render stack)
    " -> "
    manifest-path))

(define (build-package-graph-node-vec-len [v : BuildPackageGraphNodeVec]) : i64
  v.len)

(define (build-package-graph-node-vec-capacity [v : BuildPackageGraphNodeVec]) : i64
  (array-length v.slots))

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
  (array-ref v.slots index))

(define (build-package-graph-node-vec-copy-range!
  [dst : (__tl_dyn-array BuildPackageGraphNode)]
  [src : (__tl_dyn-array BuildPackageGraphNode)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (build-package-graph-node-vec-grow [v : BuildPackageGraphNodeVec]) : BuildPackageGraphNodeVec
  (let
    [count : i64 (build-package-graph-node-vec-len v)]
    [bigger : (__tl_dyn-array BuildPackageGraphNode)
      (make-array
        BuildPackageGraphNode
        (* (build-package-graph-node-vec-capacity v) 2))]
    (begin
      (build-package-graph-node-vec-copy-range! bigger v.slots count)
      (BuildPackageGraphNodeVec bigger count))))

(define (build-package-graph-node-vec-push
  [v : BuildPackageGraphNodeVec]
  [node : BuildPackageGraphNode]) : BuildPackageGraphNodeVec
  (if (<
    (build-package-graph-node-vec-len v)
    (build-package-graph-node-vec-capacity v))
    (let
      [slots : (__tl_dyn-array BuildPackageGraphNode) v.slots]
      (begin
        (set! (array-ref slots (build-package-graph-node-vec-len v)) node)
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
    (build-string-index-map-put state.seen manifest-path mark)
    state.order))

(define (build-package-graph-state-add-order
  [state : BuildPackageGraphState]
  [node : BuildPackageGraphNode]) : BuildPackageGraphState
  (BuildPackageGraphState
    state.seen
    (build-package-graph-node-vec-push state.order node)))

(define (build-package-load-dep-node
  [manifest-dir : String]
  [dep : load.CompilerPkgDep]
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
              (str_cat.str-cat "dependency `" resolved-dep.alias "`: " message))]
          [(ResultBuildManifest.Ok dep-manifest)
            (match (build-package-resolve-manifest-deps
              dep-manifest-path
              dep-manifest
              lock-policy)
              [(ResultBuildManifest.Err message)
                (ResultBuildPackageGraphNode.Err message)]
              [(ResultBuildManifest.Ok resolved-manifest)
                (if (not (build-package-kind-lib? resolved-manifest.kind))
                  (ResultBuildPackageGraphNode.Err
                    (str_cat.str-cat
                      "build: dependency `"
                      resolved-dep.alias
                      "` at "
                      dep-manifest-path
                      " must be a staticlib package"))
                  (ResultBuildPackageGraphNode.Ok
                    (BuildPackageGraphNode dep-manifest-path resolved-manifest)))])]))]))

(define (build-package-graph-add-node
  [node : BuildPackageGraphNode]
  [state : BuildPackageGraphState]
  [stack : BuildPackagePathSeq]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildPackageGraphState
  (let
    [manifest-path : String node.manifest-path]
    (match (build_string_i64_map.get (& state.seen) manifest-path)
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
          [manifest : load.CompilerPkgManifest node.manifest]
          [manifest-dir : String (load.compiler-load-dirname manifest-path)]
          [next-stack : BuildPackagePathSeq
            (build-package-path-seq-push stack manifest-path)]
          (match (build-package-graph-add-deps
            manifest-dir
            (load.compiler-pkg-deps-list manifest.deps)
            0
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
  [deps : load.CompilerPkgDepList]
  [index : i64]
  [state : BuildPackageGraphState]
  [stack : BuildPackagePathSeq]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildPackageGraphState
  (if (>= index (load.compiler-pkg-dep-list-count deps))
    (ResultBuildPackageGraphState.Ok state)
    (match (build-package-load-dep-node
      manifest-dir
      (load.compiler-pkg-dep-list-at deps index)
      lock-policy)
      [(ResultBuildPackageGraphNode.Err message)
        (ResultBuildPackageGraphState.Err message)]
      [(ResultBuildPackageGraphNode.Ok node)
        (match (build-package-graph-add-node node state stack lock-policy)
          [(ResultBuildPackageGraphState.Err message)
            (ResultBuildPackageGraphState.Err message)]
          [(ResultBuildPackageGraphState.Ok next-state)
            (build-package-graph-add-deps
              manifest-dir
              deps
              (+ index 1)
              next-state
              stack
              lock-policy)])])))

(define (build-package-dependency-graph
  [manifest-path : String]
  [manifest : load.CompilerPkgManifest]
  [lock-policy : BuildPackageLockPolicy]) : ResultBuildPackageGraph
  (let
    [root-path : String (build-package-normalize-manifest-path manifest-path)]
    [root-dir : String (load.compiler-load-dirname root-path)]
    [initial : BuildPackageGraphState
      (BuildPackageGraphState
        (build-string-index-map-put
          (build_string_i64_map.with-capacity 32)
          root-path
          build-package-visit-visiting)
        (build-package-graph-node-vec-new))]
    [stack : BuildPackagePathSeq
      (build-package-path-seq-push
        (BuildPackagePathSeq (make-array String 0) 0)
        root-path)]
    (match (build-package-graph-add-deps
      root-dir
      (load.compiler-pkg-deps-list manifest.deps)
      0
      initial
      stack
      lock-policy)
      [(ResultBuildPackageGraphState.Err message)
        (ResultBuildPackageGraph.Err message)]
      [(ResultBuildPackageGraphState.Ok state)
        (ResultBuildPackageGraph.Ok (BuildPackageGraph state.order))])))

(define (build-mkdir-ok? [path : (& path str)]) : bool
  (let
    [status : i64 (fs.mkdir-status path)]
    (or (= status build-status-ok) (= status build-status-already-exists))))

(define (build-mkdir-ok-owned? [path : String]) : bool
  (let
    [status : i64 (fs.mkdir-status-owned path)]
    (or (= status build-status-ok) (= status build-status-already-exists))))

(define (build-package-root-compiler?
  [manifest-dir : String]
  [manifest : load.CompilerPkgManifest]) : bool
  ;; Keep the compiler-only cfg out of ordinary packages. The source marker
  ;; also prevents an unrelated package named `typelisp` from opting in.
  (and
    (string.eq manifest.name "typelisp")
    (string.eq manifest.entry "src/main.tl")
    (io.file-exists?
      (load.compiler-load-join-root-path
        manifest-dir
        "src/compiler_build_identity.tl"))))

(define (build-package-refresh-root-compiler-identity [manifest-dir : String]) : ResultBuildString
  ;; Always resolve and overwrite the generated input. Reading a pre-existing
  ;; bootstrap stamp here could silently give package-built compilers a stale
  ;; producer identity.
  (let
    [repo-root : String
      (if (= (string.string-length manifest-dir) 0)
        "."
        manifest-dir)]
    [target-dir : String
      (load.compiler-load-join-root-path manifest-dir "target")]
    [identity-dir : String
      (load.compiler-load-join-root-path
        (string.copy target-dir)
        "build-stage0")]
    [identity-path : String
      (load.compiler-load-join-root-path
        (string.copy identity-dir)
        "git-hash.txt")]
    (match (build-run-captured
      "build: cannot resolve root compiler source identity"
      (build_run_core.source-tool-git-rev-parse-command repo-root))
      [(ResultBuildString.Err message) (ResultBuildString.Err message)]
      [(ResultBuildString.Ok output)
        (let
          [identity : String (build-trim-command-output output)]
          (cond
            [(not (tlci.tlci-producer-identity-valid? identity))
              (ResultBuildString.Err
                "build: root compiler source identity is not a full Git object name")]
            [(not (build-mkdir-ok-owned? (string.copy target-dir)))
              (ResultBuildString.Err
                (str_cat.str-cat
                  "build: failed to create root compiler identity directory "
                  target-dir))]
            [(not (build-mkdir-ok-owned? (string.copy identity-dir)))
              (ResultBuildString.Err
                (str_cat.str-cat
                  "build: failed to create root compiler identity directory "
                  identity-dir))]
            [else
              (match (build_run_core.source-tool-write-file
                identity-path
                identity
                "build: failed to write root compiler identity")
                [(build_run_core.SourceToolCommandStatus.Err message)
                  (ResultBuildString.Err message)]
                [(build_run_core.SourceToolCommandStatus.Ok)
                  (ResultBuildString.Ok identity)])]))])))

(define (build-package-compile-context
  [manifest-dir : String]
  [manifest : load.CompilerPkgManifest]) : BuildPackageCompileContext
  (if (build-package-root-compiler? manifest-dir manifest)
    (match (build-package-refresh-root-compiler-identity manifest-dir)
      [(ResultBuildString.Err message)
        (BuildPackageCompileContext true message)]
      [(ResultBuildString.Ok _) (BuildPackageCompileContext true "")])
    (BuildPackageCompileContext false "")))

(define (build-package-compile-cfgs
  [target : backend.CompilerBackendTarget]
  [root-compiler : bool]) : sym_i64_env.SymI64Env
  (let
    [cfgs : sym_i64_env.SymI64Env
      (compiler_driver_core.compiler-driver-target-cfgs
        target
        (compiler_parse_core.compiler-cfg-empty))]
    (if root-compiler
      (compiler_parse_core.compiler-cfg-enable cfgs "compiler-build-identity")
      cfgs)))

(define (build-ensure-package-output-dirs
  [manifest-dir : String]
  [_name : String]
  [profile : BuildProfile]) : bool
  (let
    [target-dir : String
      (load.compiler-load-join-root-path manifest-dir "target")]
    [profile-dir : String
      (load.compiler-load-join-root-path
        (string.copy target-dir)
        (build-profile-name profile))]
    (and (build-mkdir-ok? target-dir) (build-mkdir-ok? profile-dir))))

;: Resolve a manifest `search-paths` value against the manifest directory.
;: Relative paths are joined and normalized so package builds do not depend on
;: the caller's working directory; absolute paths are left as written.
(define (build-package-link-resolve-search-path
  [manifest-dir : String]
  [value : String]) : String
  (if (load.compiler-load-absolute-path? value)
    value
    (load.compiler-load-normalize-path
      (load.compiler-load-join-root-path manifest-dir value))))

(define (build-package-link-add-libs
  [inputs : build_run_core.SourceToolLinkInputs]
  [vec : (& vec fs.FsStringVector)]
  [idx : i64]) : build_run_core.SourceToolLinkInputs
  (if (>= idx (fs.string-vector-len vec))
    inputs
    (build-package-link-add-libs
      (build_run_core.source-tool-link-inputs-add-ast
        inputs
        (ast.AstExternLinkInput.Lib (fs.string-vector-get vec idx "")))
      vec
      (+ idx 1))))

(define (build-package-link-add-search-paths
  [inputs : build_run_core.SourceToolLinkInputs]
  [manifest-dir : String]
  [vec : (& vec fs.FsStringVector)]
  [idx : i64]) : build_run_core.SourceToolLinkInputs
  (if (>= idx (fs.string-vector-len vec))
    inputs
    (build-package-link-add-search-paths
      (build_run_core.source-tool-link-inputs-add-ast
        inputs
        (ast.AstExternLinkInput.Search
          (build-package-link-resolve-search-path
            manifest-dir
            (fs.string-vector-get vec idx ""))))
      manifest-dir
      vec
      (+ idx 1))))

(define (build-package-link-add-args
  [inputs : build_run_core.SourceToolLinkInputs]
  [vec : (& vec fs.FsStringVector)]
  [idx : i64]) : build_run_core.SourceToolLinkInputs
  (if (>= idx (fs.string-vector-len vec))
    inputs
    (build-package-link-add-args
      (build_run_core.source-tool-link-inputs-add-ast
        inputs
        (ast.AstExternLinkInput.Arg (fs.string-vector-get vec idx "")))
      vec
      (+ idx 1))))

;: Add one link scope set (libraries, then search paths, then raw args) onto
;: `inputs`. The three classes are stored separately, so intra-set ordering
;: across classes does not affect the emitted command.
(define (build-package-link-add-set
  [inputs : build_run_core.SourceToolLinkInputs]
  [manifest-dir : String]
  [set : load.CompilerPkgLinkSet]) : build_run_core.SourceToolLinkInputs
  (build-package-link-add-args
    (build-package-link-add-search-paths
      (build-package-link-add-libs inputs (& set.libraries) 0)
      manifest-dir
      (& set.search-paths)
      0)
    (& set.args)
    0))

;: Convert a manifest `(link ...)` section into link inputs for `target`:
;: all-target inputs first, then the per-target (linux / windows) inputs,
;: preserving first-seen order and dropping exact duplicates within each class.
(define (build-package-manifest-link-inputs
  [link : load.CompilerPkgLink]
  [manifest-dir : String]
  [target : backend.CompilerBackendTarget]) : build_run_core.SourceToolLinkInputs
  (build-package-link-add-set
    (build-package-link-add-set
      (build_run_core.source-tool-link-inputs-empty)
      manifest-dir
      link.all)
    manifest-dir
    (match target
      [(backend.CompilerBackendTarget.Linux) link.linux]
      [(backend.CompilerBackendTarget.Windows) link.windows])))

(define (build-package-artifact-status
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [direct-status : build_run_core.SourceToolDirectObjectStatus]) : build_run_core.SourceToolCommandStatus
  (match direct-status
    [(build_run_core.SourceToolDirectObjectStatus.Ok)
      build_run_core.SourceToolCommandStatus.Ok]
    [(build_run_core.SourceToolDirectObjectStatus.Err message)
      (build_run_core.SourceToolCommandStatus.Err message)]
    [(build_run_core.SourceToolDirectObjectStatus.Unavailable _)
      (match kind
        [(CompilerPkgKindBin)
          (build_run_core.source-tool-assemble-and-link
            target
            asm-path
            obj-path
            artifact-path
            link-inputs)]
        [(CompilerPkgKindLib)
          (build_run_core.source-tool-assemble-and-archive
            target
            asm-path
            obj-path
            artifact-path)])]))

(define (build-package-render-linux-direct-object
  [kind : load.CompilerPkgKind]
  [image : cobj.CompilerObjectImage]) : build_run_core.ResultSourceToolString
  (match kind
    [(CompilerPkgKindBin)
      (build_run_core.source-tool-render-linkable-linux-elf-object image)]
    [(CompilerPkgKindLib)
      (build_run_core.source-tool-render-archivable-linux-elf-object image)]))

(define (build-package-write-direct-object-artifact
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [obj : String]) : build_run_core.SourceToolDirectObjectStatus
  (match kind
    [(CompilerPkgKindBin)
      (build_run_core.source-tool-write-direct-object-and-link
        obj-path
        artifact-path
        target
        link-inputs
        obj
        "build: failed to write package direct object artifact")]
    [(CompilerPkgKindLib)
      (build_run_core.source-tool-write-direct-object-and-archive
        obj-path
        artifact-path
        target
        obj
        "build: failed to write package direct object artifact")]))

(define (build-package-direct-object-mode? [mode : backend.CompilerBackendMode]) : bool
  (match mode
    [(backend.CompilerBackendMode.Scalar) true]
    [_ false]))

(define (build-package-decl-has-spmd-callable? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.DefFn _ _ _ _ _ metadata)
      (match (ast.ast-fn-metadata-spmd-callable metadata)
        [(ast.AstSpmdCallable.No) false]
        [(ast.AstSpmdCallable.Callable _) true])]
    [(ast.AstDecl.Unsafe inner)
      (build-package-decl-has-spmd-callable? (__tl-box-place inner))]
    [_ false]))

(define (build-package-decls-have-spmd-callable? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (or
        (build-package-decl-has-spmd-callable? decl)
        (build-package-decls-have-spmd-callable? rest))]))

(define (build-package-direct-object-owned-path-budget) : i64
  ;; Large package direct-object emission duplicates enough object/ELF state to
  ;; exceed CI memory; keep it for small no-assembler package smokes.
  512)

(define (build-package-direct-object-owned-path-count
  [paths : ast.AstDeclPathList]) : i64
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Nil) 0]
    [(ast.AstDeclPathListStep.Cons path rest)
      (let
        [tail : ast.AstDeclPathList rest]
        (+
          (if (> (string.string-length path) 0)
            1
            0)
          (build-package-direct-object-owned-path-count tail)))]))

(define (build-package-direct-object-within-budget?
  [paths : ast.AstDeclPathList]) : bool
  (<=
    (build-package-direct-object-owned-path-count paths)
    (build-package-direct-object-owned-path-budget)))

(define (build-package-direct-object-size-ok?
  [target : backend.CompilerBackendTarget]
  [paths : ast.AstDeclPathList]) : bool
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (or
        (build_run_core.source-tool-linux-direct-object-enabled?)
        (build-package-direct-object-within-budget? paths))]
    [(backend.CompilerBackendTarget.Windows)
      (build-package-direct-object-within-budget? paths)]))

(cfg
  test
  (define (build-package-direct-object-test-paths
    [count : i64]
    [path : String]
    [out : ast.AstDeclPathList]) : ast.AstDeclPathList
    (if (<= count 0)
      out
      (build-package-direct-object-test-paths
        (- count 1)
        path
        (ast.ast-decl-path-list-prepend-builder-with-owner-id
          path
          cbi.compiler-builtin-id-fix-empty
          out)))))

(cfg
  test
  (define (build-package-direct-object-size-smoke-ok?) : bool
    (let
      [budget : i64 (build-package-direct-object-owned-path-budget)]
      [ordinary-decl : ast.AstDecl
        (ast.ast-decl-def-fn-id
          (ci.intern "direct-object-ordinary")
          (ast.ast-param-list-new)
          (ast.AstType.I64)
          cbi.compiler-builtin-id-fix-empty)]
      [spmd-decl : ast.AstDecl
        (ast.ast-decl-def-fn-metadata-id
          (ci.intern "direct-object-spmd")
          (ast.ast-param-list-new)
          (ast.AstType.I64)
          cbi.compiler-builtin-id-fix-empty
          (ast.ast-fn-metadata-full
            ast.AstFnExport.No
            (ast.AstSpmdCallable.Callable
              (ast.ast-spmd-specialization-list-new))))]
      [within : ast.AstDeclPathList
        (build-package-direct-object-test-paths
          budget
          "pkg.tl"
          (ast.ast-decl-path-list-new))]
      [over : ast.AstDeclPathList
        (build-package-direct-object-test-paths
          (+ budget 1)
          "pkg.tl"
          (ast.ast-decl-path-list-new))]
      [mixed : ast.AstDeclPathList
        (ast.ast-decl-root-path-cons
          ""
          (ast.ast-decl-root-path-cons "pkg.tl" (ast.ast-decl-path-list-new)))]
      (and
        (not (build-package-decl-has-spmd-callable? ordinary-decl))
        (build-package-decl-has-spmd-callable? spmd-decl)
        (build-package-decls-have-spmd-callable?
          (ast.ast-decl-cons spmd-decl (ast.ast-decl-list-new)))
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

(define (build-package-kind-supports-direct-object?
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]) : bool
  (match target
    [(backend.CompilerBackendTarget.Linux) true]
    ;; COFF archive production remains on the assembler path. Package bins can
    ;; link the existing backend-owned object directly.
    [(backend.CompilerBackendTarget.Windows)
      (match kind
        [(CompilerPkgKindBin) true]
        [(CompilerPkgKindLib) false])]))

(define (build-package-try-prepare-direct-runtime
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ResultBuildPackagePreparedRuntime
  (if (and
    (build-package-kind-supports-direct-object? kind target)
    ;; Structured object images do not carry source-line/unwind debug records.
    ;; Preserve --debug package behavior through the assembly path.
    (not (ir.compiler-debug-info-enabled?))
    (build-package-direct-object-mode? mode)
    ;; Direct object emission does not yet preserve scalar f32/f64 parameter
    ;; and return registers for generated private SPMD helpers. Use the
    ;; assembler path so runtime artifacts carry the same ABI as side assembly.
    (not (build-package-decls-have-spmd-callable? decls))
    (build-package-direct-object-size-ok? target paths))
    (match target
      [(backend.CompilerBackendTarget.Linux)
        (match (compiler_driver_core.compiler-driver-emit-package-loaded-object-image
          ""
          target
          true
          opt-level
          mode
          emit-entry
          crt-entry
          decls
          paths)
          [(compiler_driver_core.ResultCompilerDriverObject.Ok image)
            (match (build-package-render-linux-direct-object kind image)
              [(build_run_core.ResultSourceToolString.Ok object)
                (ResultBuildPackagePreparedRuntime.DirectObject
                  object
                  BuildPackageSideAssembly.Regenerate)]
              [(build_run_core.ResultSourceToolString.Err message)
                (ResultBuildPackagePreparedRuntime.Unavailable message)])]
          [(compiler_driver_core.ResultCompilerDriverObject.Err diag)
            (ResultBuildPackagePreparedRuntime.Unavailable
              (compiler_driver_core.compiler-driver-render-source-diagnostic
                (__tl-box-place diag)))])]
      [(backend.CompilerBackendTarget.Windows)
        ;; The shared Windows batch emitter owns the semantic gate as well as
        ;; the COFF encoding/linkability checks. Its Assembly result is an
        ;; intentional, stable fallback rather than a compilation failure.
        (match (compiler_windows_coff_core.compiler-windows-batch-emit-lowered-result
          ""
          (compiler_driver_core.compiler-driver-lower-package-loaded
            ""
            target
            mode
            decls
            paths)
          mode
          opt-level
          false
          true)
          [(compiler_windows_coff_core.ResultCompilerWindowsBatchArtifact.CoffObject
              object
              side-assembly)
            (match side-assembly
              [(compiler_windows_coff_core.CompilerWindowsBatchSideAssembly.None)
                (ResultBuildPackagePreparedRuntime.DirectObject
                  object
                  BuildPackageSideAssembly.Regenerate)]
              [(compiler_windows_coff_core.CompilerWindowsBatchSideAssembly.Some
                  asm)
                (ResultBuildPackagePreparedRuntime.DirectObject
                  object
                  (BuildPackageSideAssembly.Prepared asm))])]
          [(compiler_windows_coff_core.ResultCompilerWindowsBatchArtifact.Assembly
              asm
              category)
            (ResultBuildPackagePreparedRuntime.Assembly
              (text_buf.render asm)
              category)]
          [(compiler_windows_coff_core.ResultCompilerWindowsBatchArtifact.Err
              diag)
            (ResultBuildPackagePreparedRuntime.Err
              (compiler_driver_core.compiler-driver-render-source-diagnostic
                (__tl-box-place diag)))])])
    (ResultBuildPackagePreparedRuntime.Unavailable
      "package direct object disabled")))

(define (build-package-graph-node-artifact-paths
  [node : BuildPackageGraphNode]
  [profile : BuildProfile]
  [target : backend.CompilerBackendTarget]) : BuildPackageArtifactPaths
  (let
    [manifest-path : String node.manifest-path]
    [manifest : load.CompilerPkgManifest node.manifest]
    [manifest-dir : String (load.compiler-load-dirname manifest-path)]
    (build-package-artifact-paths
      manifest-dir
      manifest.name
      manifest.kind
      profile
      target)))

(define (build-package-graph-node-artifact-path
  [node : BuildPackageGraphNode]
  [profile : BuildProfile]
  [target : backend.CompilerBackendTarget]) : String
  (build-package-runtime-artifact-path
    (build-package-graph-node-artifact-paths node profile target)))

(define (build-package-graph-node-tlci-path
  [node : BuildPackageGraphNode]
  [profile : BuildProfile]) : String
  (let
    [manifest-path : String node.manifest-path]
    [manifest : load.CompilerPkgManifest node.manifest]
    [manifest-dir : String (load.compiler-load-dirname manifest-path)]
    (build-package-tlci-path-profile manifest-dir manifest.name profile)))

(define (build-package-graph-link-libs
  [nodes : BuildPackageGraphNodeVec]
  [profile : BuildProfile]
  [target : backend.CompilerBackendTarget]) : process.ProcessStringList
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

(define (build-package-graph-test-manifest [name : String]) : load.CompilerPkgManifest
  (load.CompilerPkgManifest
    name
    "0.1.0"
    (CompilerPkgKindLib)
    "src/lib.tl"
    (load.compiler-pkg-deps-empty)
    (load.compiler-pkg-link-empty)))

(define (build-package-graph-test-manifest-with-deps
  [name : String]
  [deps : load.CompilerPkgDepList]) : load.CompilerPkgManifest
  (load.CompilerPkgManifest
    name
    "0.1.0"
    (CompilerPkgKindLib)
    "src/lib.tl"
    (load.compiler-pkg-deps-from-list deps)
    (load.compiler-pkg-link-empty)))

(define (build-package-graph-test-node [manifest-path : String] [name : String]) : BuildPackageGraphNode
  (BuildPackageGraphNode manifest-path (build-package-graph-test-manifest name)))

(define (build-package-graph-test-link-arg-target
  [node : BuildPackageGraphNode]
  [target : backend.CompilerBackendTarget]) : process.ProcessStringList
  (process.args-single
    (build-package-graph-node-artifact-path node (BuildProfile.Release) target)))

(define (build-package-graph-test-link-arg [node : BuildPackageGraphNode]) : process.ProcessStringList
  (build-package-graph-test-link-arg-target
    node
    (backend.CompilerBackendTarget.Linux)))

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
        (backend.CompilerBackendTarget.Linux))]
    [windows-libs : process.ProcessStringList
      (build-package-graph-link-libs
        nodes
        (BuildProfile.Release)
        (backend.CompilerBackendTarget.Windows))]
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
            (backend.CompilerBackendTarget.Windows))
          (build-package-graph-test-link-arg-target
            second
            (backend.CompilerBackendTarget.Windows)))
        (build-package-graph-test-link-arg-target
          first
          (backend.CompilerBackendTarget.Windows)))]
    (and
      (= (build-package-graph-node-vec-len nodes) 3)
      (string.eq
        (__tl-project-field
          (build-package-graph-node-vec-at nodes 0)
          manifest-path)
        "root/first/typelisp.pkg")
      (build_run_core.source-tool-string-list-eq? libs expected)
      (build_run_core.source-tool-string-list-eq? windows-libs expected-windows)
      (build_run_core.source-tool-string-list-eq? tlcis expected-tlcis))))

(cfg
  test
  (define (build-package-graph-artifact-paths-smoke-ok?) : bool
    (let
      [bin-manifest : load.CompilerPkgManifest
        (load.CompilerPkgManifest
          "app"
          "0.1.0"
          (CompilerPkgKindBin)
          "src/main.tl"
          (load.compiler-pkg-deps-empty)
          (load.compiler-pkg-link-empty))]
      [bin-node : BuildPackageGraphNode
        (BuildPackageGraphNode "root/app/typelisp.pkg" bin-manifest)]
      [dep-node : BuildPackageGraphNode
        (build-package-graph-test-node "root/dep/typelisp.pkg" "dep")]
      [bin-artifacts : BuildPackageArtifactPaths
        (build-package-graph-node-artifact-paths
          bin-node
          (BuildProfile.Dev)
          (backend.CompilerBackendTarget.Windows))]
      [dep-artifacts : BuildPackageArtifactPaths
        (build-package-graph-node-artifact-paths
          dep-node
          (BuildProfile.Release)
          (backend.CompilerBackendTarget.Linux))]
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
    [dep : load.CompilerPkgDep (load.CompilerPkgDep "dep" "../dep")]
    [deps : load.CompilerPkgDepList
      (load.compiler-pkg-dep-list-push (load.compiler-pkg-dep-list-empty) dep)]
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
      (backend.CompilerBackendTarget.Linux)
      0
      (BuildProfile.Release)
      (backend.CompilerBackendMode.Scalar)
      (BuildPackageLockPolicy.Default)
      (cli_svec.new)
      (build-package-graph-worker-vec-new))
      [(ResultBuildPackageSchedulePass.Err _) false]
      [(ResultBuildPackageSchedulePass.Ok pass)
        (and
          (build-package-graph-worker-vec-empty? pass.workers)
          (not
            (build-package-node-scheduled?
              pass.scheduled
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
    (load.compiler-load-stdlib-import? path)
    (build-package-tlci-owner-stdlib-path? owner path)))

(define (build-package-tlci-metadata
  [manifest : load.CompilerPkgManifest]
  [callables : tlci.TlciSpmdCallables]) : tlci.TlciMetadata
  (if (= (tlci.tlci-spmd-callables-len callables) 0)
    (tlci.tlci-make-metadata "v1" manifest.name manifest.version)
    (tlci.tlci-make-metadata-v2 manifest.name manifest.version callables)))

(defstruct BuildPackageTlciCallableCollector
  (items tlci.TlciSpmdCallables)
  (error String))

;; Ordered insert that drops an exact duplicate. Rebuild the consumed input
;; into one right-sized dense sequence at the located slot.
(define (build-package-tlci-specialization-insert
  [item : tlci.TlciSpmdSpecialization]
  [items : tlci.TlciSpmdSpecializations]) : tlci.TlciSpmdSpecializations
  (let
    [count : i64 (tlci.tlci-spmd-specializations-len items)]
    [position : i64 count]
    [scan : i64 0]
    [duplicate : bool false]
    (begin
      (while (< scan count)
        (let
          [order : i64
            (tlci.tlci-spmd-specialization-compare
              item
              (tlci.tlci-spmd-specializations-ref items scan))]
          (cond
            [(= order 0)
              (begin
                (set! duplicate true)
                (set! scan count))]
            [(< order 0)
              (begin
                (set! position scan)
                (set! scan count))]
            [else (set! scan (+ scan 1))])))
      (if duplicate
        items
        (let
          [dst : tlci.TlciSpmdSpecializations
            (tlci.tlci-spmd-specializations-with-capacity (+ count 1))]
          [cursor : i64 0]
          (begin
            (while (< cursor position)
              (begin
                (tlci.tlci-spmd-specializations-push!
                  (&mut dst)
                  (tlci.tlci-spmd-specializations-ref items cursor))
                (set! cursor (+ cursor 1))))
            (tlci.tlci-spmd-specializations-push! (&mut dst) item)
            (while (< cursor count)
              (begin
                (tlci.tlci-spmd-specializations-push!
                  (&mut dst)
                  (tlci.tlci-spmd-specializations-ref items cursor))
                (set! cursor (+ cursor 1))))
            dst))))))

(define (build-package-tlci-callable-insert
  [item : tlci.TlciSpmdCallable]
  [items : tlci.TlciSpmdCallables]) : tlci.TlciSpmdCallables
  (let
    [count : i64 (tlci.tlci-spmd-callables-len items)]
    [position : i64 count]
    [scan : i64 0]
    [dst : tlci.TlciSpmdCallables
      (tlci.tlci-spmd-callables-with-capacity (+ count 1))]
    [cursor : i64 0]
    (begin
      (while (< scan count)
        (if (<
          (tlci.tlci-spmd-callable-compare
            item
            (tlci.tlci-spmd-callables-ref items scan))
          0)
          (begin
            (set! position scan)
            (set! scan count))
          (set! scan (+ scan 1))))
      (while (< cursor position)
        (begin
          (tlci.tlci-spmd-callables-push!
            (&mut dst)
            (tlci.tlci-spmd-callables-ref items cursor))
          (set! cursor (+ cursor 1))))
      (tlci.tlci-spmd-callables-push! (&mut dst) item)
      (while (< cursor count)
        (begin
          (tlci.tlci-spmd-callables-push!
            (&mut dst)
            (tlci.tlci-spmd-callables-ref items cursor))
          (set! cursor (+ cursor 1))))
      dst)))

(define (build-package-tlci-backend [mode : backend.CompilerBackendMode]) : ir.CompilerIrSpmdBackend
  (match mode
    [(backend.CompilerBackendMode.Scalar) ir.CompilerIrSpmdBackend.Scalar]
    [(backend.CompilerBackendMode.Avx2) ir.CompilerIrSpmdBackend.Avx2]
    [(backend.CompilerBackendMode.Avx512) ir.CompilerIrSpmdBackend.Avx512]))

(define (build-package-tlci-specializations-at
  [package-name : String]
  [canonical-name : String]
  [signature : String]
  [ret : ast.AstType]
  [items : (& items ast.AstSpmdSpecializationList)]
  [index : i64]
  [limit : i64]
  [spmd-backend : ir.CompilerIrSpmdBackend]
  [out : tlci.TlciSpmdSpecializations]) : tlci.TlciSpmdSpecializations
  (if (or
    (>= index limit)
    (>= index (ast.ast-spmd-specialization-list-len items)))
    out
    (let
      [fallback : ast.AstSpmdSpecialization
        (ast.AstSpmdSpecialization
          2
          (box (ast.ast-spmd-param-class-list-new))
          ast.AstSpmdResultClass.Unit
          -1)]
      [specialization : ast.AstSpmdSpecialization
        (ast.ast-spmd-specialization-list-get items index fallback)]
      [classes : ast.AstSpmdParamClassList (__tl-box-place specialization.args)]
      [args : String (lower.lower-spmd-ast-param-classes-code classes)]
      [result : String
        (lower.lower-spmd-ast-result-class-code specialization.result)]
      [lanes : i64
        (match spmd-backend
          [(ir.CompilerIrSpmdBackend.Scalar) 1]
          [_ specialization.lanes])]
      [index-param : i64 specialization.index-param]
      [logical-symbol : String
        (lower.lower-spmd-package-symbol
          package-name
          canonical-name
          signature
          ret
          spmd-backend
          lanes
          args
          result
          index-param)]
      [logical-symbol-id : i64
        (ci.intern-generated-canonical-name logical-symbol)]
      [item : tlci.TlciSpmdSpecialization
        (tlci.tlci-make-spmd-specialization
          "spmd-call-v1"
          (lower.lower-spmd-package-backend-name spmd-backend)
          lanes
          args
          result
          index-param
          (backend.compiler-backend-user-symbol-id logical-symbol-id))]
      (build-package-tlci-specializations-at
        package-name
        canonical-name
        signature
        ret
        items
        (+ index 1)
        limit
        spmd-backend
        (build-package-tlci-specialization-insert item out)))))

(define (build-package-tlci-callable
  [package-name : String]
  [module : String]
  [name : i64]
  [params : ast.AstParamList]
  [ret : ast.AstType]
  [specializations : ast.AstSpmdSpecializationList]
  [mode : backend.CompilerBackendMode]) : tlci.TlciSpmdCallable
  (let
    [canonical-name : String
      (csym.compiler-symbol-module-key
        (if (= (string.string-length module) 0)
          package-name
          module)
        (ci.intern-str name))]
    [signature : String (lower.lower-spmd-source-signature params ret)]
    [spmd-backend : ir.CompilerIrSpmdBackend (build-package-tlci-backend mode)]
    [count : i64 (ast.ast-spmd-specialization-list-len (& specializations))]
    (tlci.tlci-make-spmd-callable
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
        spmd-backend
        (tlci.tlci-spmd-specializations-empty)))))

(cfg
  test
  (define (build-package-tlci-callable-smoke-ok?) : bool
    (let
      [first-classes : ast.AstSpmdParamClassList
        (ast.ast-spmd-param-class-list-new)]
      [second-classes : ast.AstSpmdParamClassList
        (ast.ast-spmd-param-class-list-new)]
      [specializations : ast.AstSpmdSpecializationList
        (ast.ast-spmd-specialization-list-new)]
      [helper-id : i64 (ci.intern-generated-canonical-name "helper")]
      [x-id : i64 (ci.intern-generated-canonical-name "x")]
      [scale-id : i64 (ci.intern-generated-canonical-name "scale")]
      (begin
        (ast.ast-spmd-param-class-list-push
          (&mut first-classes)
          ast.AstSpmdParamClass.Varying)
        (ast.ast-spmd-param-class-list-push
          (&mut first-classes)
          ast.AstSpmdParamClass.Uniform)
        (ast.ast-spmd-param-class-list-push
          (&mut second-classes)
          ast.AstSpmdParamClass.Uniform)
        (ast.ast-spmd-param-class-list-push
          (&mut second-classes)
          ast.AstSpmdParamClass.Varying)
        (ast.ast-spmd-specialization-list-push
          (&mut specializations)
          (ast.AstSpmdSpecialization
            8
            (box first-classes)
            ast.AstSpmdResultClass.Varying
            0))
        (ast.ast-spmd-specialization-list-push
          (&mut specializations)
          (ast.AstSpmdSpecialization
            8
            (box second-classes)
            ast.AstSpmdResultClass.Varying
            1))
        (let
          [callable : tlci.TlciSpmdCallable
            (build-package-tlci-callable
              "pkg"
              "pkg"
              helper-id
              (ast.ast-param-cons
                (ast.ast-param-id x-id (ast.AstType.I64) false)
                (ast.ast-param-cons
                  (ast.ast-param-id scale-id (ast.AstType.I64) false)
                  (ast.ast-param-list-new)))
              (ast.AstType.I64)
              specializations
              (backend.CompilerBackendMode.Scalar))]
          [ordinary-metadata : tlci.TlciMetadata
            (build-package-tlci-metadata
              (build-package-graph-test-manifest "pkg")
              (tlci.tlci-spmd-callables-empty))]
          [emitted : tlci.TlciSpmdSpecializations callable.specializations]
          (and
            (string.eq ordinary-metadata.version "v1")
            (=
              (tlci.tlci-spmd-callables-len ordinary-metadata.spmd-callables)
              0)
            (string.eq callable.name "pkg/helper")
            (string.eq callable.signature "(-> i64 i64 i64)")
            (= (tlci.tlci-spmd-specializations-len emitted) 2)
            (let
              [item : tlci.TlciSpmdSpecialization
                (tlci.tlci-spmd-specializations-ref emitted 0)]
              [next : tlci.TlciSpmdSpecialization
                (tlci.tlci-spmd-specializations-ref emitted 1)]
              (and
                (string.eq item.abi "spmd-call-v1")
                (string.eq item.backend "scalar")
                (= item.lanes 1)
                (string.eq item.args "uv")
                (string.eq item.result "v")
                (= item.index-param 1)
                (string.eq
                  item.symbol
                  (backend.compiler-backend-user-symbol-uncached
                    (ci.intern-str
                      (ci.intern-generated-canonical-name
                        (lower.lower-spmd-package-symbol
                          "pkg"
                          "pkg/helper"
                          "(-> i64 i64 i64)"
                          (ast.AstType.I64)
                          ir.CompilerIrSpmdBackend.Scalar
                          1
                          "uv"
                          "v"
                          1)))))
                (string.eq next.args "vu")
                (= next.index-param 0)))))))))

(cfg
  test
  (define (build-package-tlci-scalar-collapse-smoke-ok?) : bool
    (let
      [first-classes : ast.AstSpmdParamClassList
        (ast.ast-spmd-param-class-list-new)]
      [second-classes : ast.AstSpmdParamClassList
        (ast.ast-spmd-param-class-list-new)]
      [specializations : ast.AstSpmdSpecializationList
        (ast.ast-spmd-specialization-list-new)]
      [helper-id : i64 (ci.intern-generated-canonical-name "helper")]
      [x-id : i64 (ci.intern-generated-canonical-name "x")]
      (begin
        (ast.ast-spmd-param-class-list-push
          (&mut first-classes)
          ast.AstSpmdParamClass.Uniform)
        (ast.ast-spmd-param-class-list-push
          (&mut second-classes)
          ast.AstSpmdParamClass.Uniform)
        (ast.ast-spmd-specialization-list-push
          (&mut specializations)
          (ast.AstSpmdSpecialization
            8
            (box first-classes)
            ast.AstSpmdResultClass.Uniform
            -1))
        (ast.ast-spmd-specialization-list-push
          (&mut specializations)
          (ast.AstSpmdSpecialization
            16
            (box second-classes)
            ast.AstSpmdResultClass.Uniform
            -1))
        (let
          [emitted : tlci.TlciSpmdSpecializations
            (__tl-project-field
              (build-package-tlci-callable
                "pkg"
                "pkg"
                helper-id
                (ast.ast-param-cons
                  (ast.ast-param-id x-id (ast.AstType.I64) false)
                  (ast.ast-param-list-new))
                (ast.AstType.I64)
                specializations
                (backend.CompilerBackendMode.Scalar))
              specializations)]
          (and
            (= (tlci.tlci-spmd-specializations-len emitted) 1)
            (let
              [item : tlci.TlciSpmdSpecialization
                (tlci.tlci-spmd-specializations-ref emitted 0)]
              (and
                (= item.lanes 1)
                (string.eq item.args "u")
                (string.eq item.result "u")
                (= item.index-param -1)))))))))

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
  [decl : ast.AstDecl]
  [owned-path : String]
  [module : String]
  [package-name : String]
  [mode : backend.CompilerBackendMode]
  [collector : BuildPackageTlciCallableCollector]) : BuildPackageTlciCallableCollector
  (match decl
    [(ast.AstDecl.DefFn decl-meta name params ret _ metadata)
      (if (= (string.string-length owned-path) 0)
        collector
        (match (ast.ast-fn-metadata-spmd-callable metadata)
          [(ast.AstSpmdCallable.No) collector]
          [(ast.AstSpmdCallable.Callable specializations)
            (if (match mode
              [(backend.CompilerBackendMode.Avx2) true]
              [_ false])
              (BuildPackageTlciCallableCollector
                collector.items
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
                  collector.items)
                collector.error))]))]
    [(ast.AstDecl.Unsafe inner-box)
      (build-package-tlci-collect-decl-callable
        (__tl-box-place inner-box)
        owned-path
        module
        package-name
        mode
        collector)]
    [_ collector]))

(define (build-package-tlci-push-macro-name!
  [out : (&mut out cli_svec.Vec)]
  [name : String]) : bool
  (let
    [index : i64 0]
    [present : bool false]
    (begin
      (while (and (not present) (< index (cli_svec.len out)))
        (if (string.eq (cli_svec.get out index "") name)
          (set! present true)
          (set! index (+ index 1))))
      (if present
        false
        (begin
          (cli_svec.push out name)
          true)))))

(defstruct BuildPackageTlciMacroCollector
  (names (__tl_dyn-array String))
  (captures compiler_tlci_native_producer.TlciNativeMacroCaptures))

(define (build-package-tlci-sort-macro-catalog!
  [catalog : (&mut catalog (__tl_dyn-array String))]) : unit
  (let
    [count : i64 (array-length catalog)]
    [index : i64 1]
    (while (< index count)
      (let
        [value : String (clone (array-ref catalog index))]
        [slot : i64 index]
        (begin
          (while (if (> slot 0)
            (package_source_core.package-source-string-less?
              (clone value)
              (clone (array-ref catalog (- slot 1))))
            false)
            (begin
              (set!
                (array-ref catalog slot)
                (clone (array-ref catalog (- slot 1))))
              (set! slot (- slot 1))))
          (set! (array-ref catalog slot) value)
          (set! index (+ index 1)))))))

(define (build-package-tlci-finish-macro-collector
  [names : (&mut names cli_svec.Vec)]
  [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures]) : BuildPackageTlciMacroCollector
  (let
    [count : i64 (cli_svec.len names)]
    [catalog (make-array String count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref catalog index) (cli_svec.get names index ""))
          (set! index (+ index 1))))
      (build-package-tlci-sort-macro-catalog! (&mut catalog))
      (BuildPackageTlciMacroCollector catalog captures))))

(define (build-package-tlci-collect-decl-macro!
  [decl : ast.AstDecl]
  [owned-path : String]
  [module : String]
  [package-name : String]
  [owned-sources : build_string_i64_map.Map]
  [out : (&mut out cli_svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (match decl
    [(ast.AstDecl.DefMacro decl-meta name params _ body)
      (if (= (string.string-length owned-path) 0)
        unit
        (let
          [identity : String
            (csym.compiler-symbol-module-key
              (if (= (string.string-length module) 0)
                package-name
                module)
              (ci.intern-str name))]
          (when
            (build-package-tlci-push-macro-name! out identity)
            (compiler_tlci_native_producer.tlci-native-macro-captures-push!
              captures
              (compiler_tlci_native_producer.TlciNativeMacroCapture
                identity
                params
                body)))))]
    [(ast.AstDecl.Unsafe inner-box)
      (build-package-tlci-collect-decl-macro!
        (__tl-box-place inner-box)
        owned-path
        module
        package-name
        owned-sources
        out
        captures)]
    [(ast.AstDecl.ModuleBody nested-module body-box)
      (build-package-tlci-collect-macros-into!
        (__tl-box-place body-box)
        (ast.ast-decl-path-list-new)
        owned-path
        (ci.intern-str nested-module)
        package-name
        owned-sources
        out
        captures)]
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
            (load.compiler-load-normalize-path
              (cli_svec.get (& sources) index ""))
            1)
          (set! index (+ index 1))))
      out)))

(define (build-package-tlci-source-owned?
  [owned-sources : build_string_i64_map.Map]
  [path : String]) : bool
  (match (build_string_i64_map.get
    (& owned-sources)
    (load.compiler-load-normalize-path path))
    [(build_string_i64_map.LookupFound _) true]
    [(build_string_i64_map.LookupMissing) false]))

(define (build-package-tlci-collect-macros-into!
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [initial-module : String]
  [package-name : String]
  [owned-sources : build_string_i64_map.Map]
  [out : (&mut out cli_svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (let
    [decl-cursor : ast.AstDeclList decls]
    [path-cursor : ast.AstDeclPathList paths]
    [module : String initial-module]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step decl-cursor)
        [(ast.AstDeclListStep.Nil) (set! done true)]
        [(ast.AstDeclListStep.Cons decl rest)
          (let
            [decl-path : String
              (match (ast.ast-decl-path-list-step path-cursor)
                [(ast.AstDeclPathListStep.Nil) fallback-path]
                [(ast.AstDeclPathListStep.Cons path _) path])]
            [owned-path : String
              (if (build-package-tlci-source-owned? owned-sources decl-path)
                decl-path
                "")]
            (begin
              (match decl
                [(ast.AstDecl.Module name) (set! module (ci.intern-str name))]
                [_
                  (build-package-tlci-collect-decl-macro!
                    decl
                    owned-path
                    module
                    package-name
                    owned-sources
                    out
                    captures)])
              (set! decl-cursor rest)
              (match (ast.ast-decl-path-list-step path-cursor)
                [(ast.AstDeclPathListStep.Nil) unit]
                [(ast.AstDeclPathListStep.Cons _ path-rest)
                  (set! path-cursor path-rest)])))]))))

(define (build-package-tlci-macro-collector
  [source-set : package_source_core.PackageSourceSet]
  [manifest : load.CompilerPkgManifest]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : BuildPackageTlciMacroCollector
  (let
    [out : cli_svec.Vec (cli_svec.new)]
    [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
      (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
    [owned-sources : build_string_i64_map.Map
      (build-package-tlci-source-map source-set.sources)]
    (begin
      (build-package-tlci-collect-macros-into!
        decls
        paths
        ""
        ""
        manifest.name
        owned-sources
        (&mut out)
        (&mut captures))
      (build-package-tlci-finish-macro-collector (&mut out) captures))))

(cfg
  test
  (define (build-package-tlci-macro-capture-smoke-ok?) : bool
    (let
      [source : String
        "(module z.macros)\n(defmacro (wrap [value : Expr]) : Expr `(identity ,value))\n(module dep.macros)\n(defmacro (foreign [value : Expr]) : Expr `(foreign ,value))\n(module a.macros)\n(defmacro (fold [items : Expr ...]) : bool (comptime.expr-list-fold-if items (comptime.expr-bool true) (comptime.expr-bool false) true))\n"]
      (match (compiler_parse_core.parse-ast-source source)
        [(compiler_parse_core.ResultAstProgram.Err _) false]
        [(compiler_parse_core.ResultAstProgram.Ok program)
          (match program
            [(ast.AstProgram.Program decls-box)
              (let
                [decls : ast.AstDeclList (__tl-box-place decls-box)]
                [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
                [owned-sources : build_string_i64_map.Map
                  (build_string_i64_map.with-capacity 4)]
                [names : cli_svec.Vec (cli_svec.new)]
                [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
                  (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
                (begin
                  (build_string_i64_map.insert-ref!
                    (&mut owned-sources)
                    (load.compiler-load-normalize-path "pkg/src/macros.tl")
                    1)
                  (ast.ast-decl-path-list-push-with-owner-id
                    (&mut paths)
                    "pkg/src/macros.tl"
                    cbi.compiler-builtin-id-fix-empty)
                  (ast.ast-decl-path-list-push-with-owner-id
                    (&mut paths)
                    "pkg/src/macros.tl"
                    cbi.compiler-builtin-id-fix-empty)
                  (ast.ast-decl-path-list-push-with-owner-id
                    (&mut paths)
                    "dep/src/lib.tl"
                    cbi.compiler-builtin-id-fix-empty)
                  (ast.ast-decl-path-list-push-with-owner-id
                    (&mut paths)
                    "dep/src/lib.tl"
                    cbi.compiler-builtin-id-fix-empty)
                  (ast.ast-decl-path-list-push-with-owner-id
                    (&mut paths)
                    "pkg/src/macros.tl"
                    cbi.compiler-builtin-id-fix-empty)
                  (ast.ast-decl-path-list-push-with-owner-id
                    (&mut paths)
                    "pkg/src/macros.tl"
                    cbi.compiler-builtin-id-fix-empty)
                  (build-package-tlci-collect-macros-into!
                    decls
                    paths
                    ""
                    ""
                    "pkg"
                    owned-sources
                    (&mut names)
                    (&mut captures))
                  (let
                    [collector : BuildPackageTlciMacroCollector
                      (build-package-tlci-finish-macro-collector
                        (&mut names)
                        captures)]
                    [catalog : (__tl_dyn-array String) collector.names]
                    [_source : String
                      (compiler_tlci_native_producer.embedded-native-source
                        catalog
                        (& collector.captures))]
                    (and
                      (= (array-length catalog) 2)
                      (string.eq (array-ref catalog 0) "a.macros/fold")
                      (string.eq (array-ref catalog 1) "z.macros/wrap")
                      (= collector.captures.len 2)
                      (>=
                        (compiler_tlci_native_producer.tlci-native-macro-capture-slot
                          (& collector.captures)
                          "a.macros/fold")
                        0)
                      (>=
                        (compiler_tlci_native_producer.tlci-native-macro-capture-slot
                          (& collector.captures)
                          "z.macros/wrap")
                        0)
                      (<
                        (compiler_tlci_native_producer.tlci-native-macro-capture-slot
                          (& collector.captures)
                          "dep.macros/foreign")
                        0)
                      (=
                        (array-ref
                          compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-count
                          0)
                        2)))))])]))))

(cfg
  test
  (test
    build-package-tlci-macro-capture
    (unless
      (build-package-tlci-macro-capture-smoke-ok?)
      (io.panic "build package tlci macro capture smoke failed"))))

(define (build-package-tlci-collect-callables-into!
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [initial-module : String]
  [package-name : String]
  [mode : backend.CompilerBackendMode]
  [owned-sources : build_string_i64_map.Map]
  [collector : BuildPackageTlciCallableCollector]) : BuildPackageTlciCallableCollector
  (let
    [decl-cursor : ast.AstDeclList decls]
    [path-cursor : ast.AstDeclPathList paths]
    [module : String initial-module]
    [done : bool false]
    [current : BuildPackageTlciCallableCollector collector]
    (begin
      (while (and (not done) (= (string.string-length current.error) 0))
        (match (ast.ast-decl-list-step decl-cursor)
          [(ast.AstDeclListStep.Nil) (set! done true)]
          [(ast.AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (match (ast.ast-decl-path-list-step path-cursor)
                  [(ast.AstDeclPathListStep.Nil) fallback-path]
                  [(ast.AstDeclPathListStep.Cons path _) path])]
              [owned-path : String
                (if (build-package-tlci-source-owned? owned-sources decl-path)
                  decl-path
                  "")]
              (begin
                (match decl
                  [(ast.AstDecl.Module name) (set! module (ci.intern-str name))]
                  [(ast.AstDecl.ModuleBody nested-module body-box)
                    (set!
                      current
                      (build-package-tlci-collect-callables-into!
                        (__tl-box-place body-box)
                        (ast.ast-decl-path-list-new)
                        owned-path
                        (ci.intern-str nested-module)
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
                (match (ast.ast-decl-path-list-step path-cursor)
                  [(ast.AstDeclPathListStep.Nil) unit]
                  [(ast.AstDeclPathListStep.Cons _ path-rest)
                    (set! path-cursor path-rest)])))]))
      current)))

(define (build-package-tlci-callable-collector
  [source-set : package_source_core.PackageSourceSet]
  [manifest : load.CompilerPkgManifest]
  [mode : backend.CompilerBackendMode]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : BuildPackageTlciCallableCollector
  (let
    [owned-sources : build_string_i64_map.Map
      (build-package-tlci-source-map source-set.sources)]
    (build-package-tlci-collect-callables-into!
      decls
      paths
      ""
      ""
      manifest.name
      mode
      owned-sources
      (BuildPackageTlciCallableCollector (tlci.tlci-spmd-callables-empty) ""))))

(define (build-package-tlci-image
  [metadata : tlci.TlciMetadata]
  [producer-identity : String]
  [rodata : (__tl_dyn-array u8)]) : tlci.TlciImage
  (tlci.TlciImage
    tlci.tlci-host-arch-x86-64
    tlci.tlci-callback-abi-version
    producer-identity
    metadata
    rodata
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)
    (tlci.tlci-empty-bytes)))

(defenum ResultBuildPackageTlciText
  (Ok String)
  (Err String))

(define (build-package-tlci-source-binding-rodata [digest : i64]) : tlci.ResultTlciAuxBytes
  (let
    [sections : (__tl_dyn-array tlci.TlciAuxSection)
      (array.make-array tlci.TlciAuxSection 1)]
    (begin
      (set!
        (array-ref sections 0)
        (tlci.tlci-package-source-binding-section digest))
      (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections))))

(define (build-package-tlci-text
  [manifest-path : String]
  [manifest : load.CompilerPkgManifest]
  [mode : backend.CompilerBackendMode]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [producer-identity : String]) : ResultBuildPackageTlciText
  (if (not (tlci.tlci-producer-identity-valid? producer-identity))
    (ResultBuildPackageTlciText.Err
      "build: exact producer compiler identity is unavailable")
    (match (package_source_core.package-source-discover-for
      "build"
      manifest-path
      true)
      [(package_source_core.ResultPackageSourceSet.Err message)
        (ResultBuildPackageTlciText.Err message)]
      [(package_source_core.ResultPackageSourceSet.Ok source-set)
        (match (package_source_core.package-source-set-digest source-set)
          [(package_source_core.ResultPackageSourceDigest.Err message)
            (ResultBuildPackageTlciText.Err
              (str_cat.str-cat
                "build: failed to compute package source digest: "
                message))]
          [(package_source_core.ResultPackageSourceDigest.Ok digest)
            (match (build-package-tlci-source-binding-rodata digest)
              [(tlci.ResultTlciAuxBytes.Err message)
                (ResultBuildPackageTlciText.Err
                  (str_cat.str-cat
                    "build: failed to pack package source binding: "
                    message))]
              [(tlci.ResultTlciAuxBytes.Ok rodata)
                (let
                  [collector : BuildPackageTlciCallableCollector
                    (build-package-tlci-callable-collector
                      source-set
                      manifest
                      mode
                      decls
                      paths)]
                  [macro-collector : BuildPackageTlciMacroCollector
                    (build-package-tlci-macro-collector
                      source-set
                      manifest
                      decls
                      paths)]
                  [macro-names : (__tl_dyn-array String) macro-collector.names]
                  (if (> (string.string-length collector.error) 0)
                    (ResultBuildPackageTlciText.Err collector.error)
                    (let
                      [metadata : tlci.TlciMetadata
                        (build-package-tlci-metadata manifest collector.items)]
                      (if (= (array-length macro-names) 0)
                        (match (tlci.tlci-emit-image
                          (build-package-tlci-image
                            metadata
                            producer-identity
                            rodata))
                          [(tlci.ResultTlciBytes.Err message)
                            (ResultBuildPackageTlciText.Err
                              (str_cat.str-cat
                                "build: failed to emit package tlci: "
                                message))]
                          [(tlci.ResultTlciBytes.Ok bytes)
                            (ResultBuildPackageTlciText.Ok
                              (tlci.tlci-bytes->string
                                bytes
                                0
                                (array-length bytes)))])
                        (match (compiler_tlci_native_producer.embedded-native-emit-package
                          (tlci.tlci-metadata-emit metadata)
                          producer-identity
                          (cfg windows true false)
                          rodata
                          macro-names
                          (& macro-collector.captures))
                          [(compiler_tlci_native_producer.ResultProducerBytes.Err
                              message)
                            (ResultBuildPackageTlciText.Err
                              (str_cat.str-cat
                                "build: failed to emit package tlci: "
                                message))]
                          [(compiler_tlci_native_producer.ResultProducerBytes.Ok
                              bytes)
                            (ResultBuildPackageTlciText.Ok
                              (tlci.tlci-bytes->string
                                bytes
                                0
                                (array-length bytes)))])))))])])])))

;; This producer load is disposable; only the caller-owned TLCI text crosses
;; the reset before the final lowering load.
(define (build-package-tlci-text-loaded
  [manifest-path : String]
  [manifest : load.CompilerPkgManifest]
  [mode : backend.CompilerBackendMode]
  [entry-path : String]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [deps : load.CompilerPkgDeps]
  [emit-entry : bool]
  [compile-cfgs : sym_i64_env.SymI64Env]
  [producer-identity : String]) : ResultBuildPackageTlciText
  (match (compiler_driver_core.compiler-driver-load-package-file-with-runtime-cfg
    entry-path
    stdlib-roots
    manifest-dir
    deps
    emit-entry
    compile-cfgs)
    [(load.ResultCompilerLoadWithPaths.Err diag)
      (ResultBuildPackageTlciText.Err
        (compiler_driver_core.compiler-driver-render-source-diagnostic
          (__tl-box-place diag)))]
    [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (build-package-tlci-text
        manifest-path
        manifest
        mode
        decls
        paths
        producer-identity)]))

(define (build-package-runtime-fingerprint-path [artifact-path : String]) : String
  (str_cat.str-cat artifact-path ".runtime-inputs"))

(define (build-package-file-regular? [path : String]) : bool
  (match (build-package-artifact-file-state path)
    [(BuildPackageArtifactState.Clean) true]
    [_ false]))

(define (build-package-file-text-eq? [path : String] [expected : String]) : bool
  (if (not (build-package-file-regular? path))
    false
    (match (io.try-read-file (& path))
      [(io.OkIoBytes contents)
        (string.eq (byte_buf.to-string contents) expected)]
      [(io.ErrIoBytes _) false])))

(define (build-package-file-digest [path : String] [context : String]) : ResultBuildPackageFileDigest
  (match (io.try-read-file (& path))
    [(io.ErrIoBytes error)
      (ResultBuildPackageFileDigest.Err
        (str_cat.str-cat context ": " (io.error-message error)))]
    [(io.OkIoBytes contents)
      (let
        [bytes : (__tl_dyn-array u8) (byte_buf.to-array contents)]
        [count : i64 (array-length bytes)]
        [hash-a : i64
          (package_source_core.package-source-binding-hash-bytes
            (package_source_core.package-source-binding-hash-u64 17 count)
            bytes)]
        [hash-b : i64
          (package_source_core.package-source-binding-hash-bytes
            (package_source_core.package-source-binding-hash-u64 97 count)
            bytes)]
        (ResultBuildPackageFileDigest.Ok
          (str_cat.str-cat
            (string.int->string count)
            ":"
            (string.int->string hash-a)
            ":"
            (string.int->string hash-b))))]))

(define (build-package-sampled-file-digest-text
  [size : i64]
  [first : (__tl_dyn-array u8)]
  [last : (__tl_dyn-array u8)]) : String
  (let
    [first-count : i64 (array-length first)]
    [last-count : i64 (array-length last)]
    [hash-a0 : i64
      (package_source_core.package-source-binding-hash-u64 17 size)]
    [hash-a1 : i64
      (package_source_core.package-source-binding-hash-bytes
        (package_source_core.package-source-binding-hash-u64
          hash-a0
          first-count)
        first)]
    [hash-a : i64
      (package_source_core.package-source-binding-hash-bytes
        (package_source_core.package-source-binding-hash-u64 hash-a1 last-count)
        last)]
    [hash-b0 : i64
      (package_source_core.package-source-binding-hash-u64 97 size)]
    [hash-b1 : i64
      (package_source_core.package-source-binding-hash-bytes
        (package_source_core.package-source-binding-hash-u64
          hash-b0
          first-count)
        first)]
    [hash-b : i64
      (package_source_core.package-source-binding-hash-bytes
        (package_source_core.package-source-binding-hash-u64 hash-b1 last-count)
        last)]
    (str_cat.str-cat
      (string.int->string size)
      ":"
      (string.int->string hash-a)
      ":"
      (string.int->string hash-b))))

(define (build-package-tool-file-digest [path : String] [context : String]) : ResultBuildPackageFileDigest
  (match (fs.try-file-metadata (& path))
    [(fs.ErrFsMetadata error)
      (ResultBuildPackageFileDigest.Err
        (str_cat.str-cat context ": " (io.error-message error)))]
    [(fs.OkFsMetadata metadata)
      (let
        [size : i64 (fs.metadata-size metadata)]
        [sample-size : i64 65536]
        (match (io.file-open (& path) (io.OpenMode.OpenRead))
          [(io.ErrIoFile error)
            (ResultBuildPackageFileDigest.Err
              (str_cat.str-cat context ": " (io.error-message error)))]
          [(io.OkIoFile handle)
            (let
              [first : (__tl_dyn-array u8) (make-array u8 0)]
              [last : (__tl_dyn-array u8) (make-array u8 0)]
              [ok : bool true]
              [error-message : String ""]
              (begin
                (match (io.file-read-chunk handle sample-size)
                  [(io.ErrIoRead error)
                    (begin
                      (set! ok false)
                      (set! error-message (io.error-message error)))]
                  [(io.OkIoRead read)
                    (set! first (byte_buf.to-array (io.file-read-bytes read)))])
                (if (and ok (> size sample-size))
                  (if (<
                    (io.platform-lseek
                      (io_core.io-file-i64-ref
                        (io_core.io-file-fds-ptr)
                        handle.id)
                      (- size sample-size)
                      0)
                    0)
                    (begin
                      (set! ok false)
                      (set! error-message "seek failed"))
                    (match (io.file-read-chunk handle sample-size)
                      [(io.ErrIoRead error)
                        (begin
                          (set! ok false)
                          (set! error-message (io.error-message error)))]
                      [(io.OkIoRead read)
                        (set!
                          last
                          (byte_buf.to-array (io.file-read-bytes read)))]))
                  unit)
                (io.file-close handle)
                (if ok
                  (ResultBuildPackageFileDigest.Ok
                    (build-package-sampled-file-digest-text size first last))
                  (ResultBuildPackageFileDigest.Err
                    (str_cat.str-cat context ": " error-message)))))]))]))

(define (build-package-transcript-field [name : String] [value : String]) : String
  (str_cat.str-cat
    name
    " "
    (string.int->string (string.string-length value))
    ":"
    value
    "\n"))

(define (build-package-command-args-transcript
  [args : process.ProcessStringList]) : String
  (let
    [index : i64 0]
    [count : i64 (process.args-count args)]
    [out : String
      (build-package-transcript-field "argc" (string.int->string count))]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (string.append
              out
              (build-package-transcript-field
                "arg"
                (process.args-ref args index))))
          (set! index (+ index 1))))
      out)))

(define (build-package-command-env-transcript [items : process.ProcessEnvList]) : String
  (let
    [index : i64 0]
    [count : i64 (process.env-count items)]
    [out : String
      (build-package-transcript-field "envc" (string.int->string count))]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (build-package-transcript-field
                "env-name"
                (process.env-name-ref items index))
              (build-package-transcript-field
                "env-value"
                (process.env-value-ref items index))))
          (set! index (+ index 1))))
      out)))

(define (build-package-command-transcript
  [role : String]
  [command : process.ProcessCommand]) : ResultBuildString
  (let
    [executable : String
      (build_run_core.source-tool-resolve-command
        (process.command-executable command))]
    (if (not (build-package-file-regular? executable))
      (ResultBuildString.Err
        (str_cat.str-cat
          "build: cannot fingerprint "
          role
          " executable "
          executable))
      (match (build-package-tool-file-digest
        executable
        (str_cat.str-cat "build: cannot fingerprint " role " executable"))
        [(ResultBuildPackageFileDigest.Err message)
          (ResultBuildString.Err message)]
        [(ResultBuildPackageFileDigest.Ok digest)
          (ResultBuildString.Ok
            (str_cat.str-cat
              (build-package-transcript-field "tool-role" role)
              (build-package-transcript-field "tool-path" executable)
              (build-package-transcript-field "tool-digest" digest)
              (build-package-command-args-transcript
                (process.command-argv command))
              (build-package-command-env-transcript
                (process.command-env command))))]))))

(define (build-package-env-transcript-one [name : String]) : String
  (match (env.get (& name))
    [(env.EnvNoString)
      (build-package-transcript-field
        (str_cat.str-cat "inherited-env-" name)
        "<unset>")]
    [(env.EnvSomeString value)
      (build-package-transcript-field
        (str_cat.str-cat "inherited-env-" name)
        value)]))

(define (build-package-runtime-inherited-env-transcript) : String
  (str_cat.str-cat
    (build-package-transcript-field "working-directory" (fs.current-dir))
    (build-package-env-transcript-one "PATH")
    (build-package-env-transcript-one "LIB")
    (build-package-env-transcript-one "LIBPATH")
    (build-package-env-transcript-one "LIBRARY_PATH")
    (build-package-env-transcript-one "LD_LIBRARY_PATH")
    (build-package-env-transcript-one "COMPILER_PATH")
    (build-package-env-transcript-one "GCC_EXEC_PREFIX")
    (build-package-env-transcript-one "SDKROOT")))

(define (build-package-link-path-transcript [path : String]) : ResultBuildString
  (if (build-package-file-regular? path)
    (match (build-package-file-digest
      path
      "build: cannot fingerprint native link input")
      [(ResultBuildPackageFileDigest.Err message)
        (ResultBuildString.Err message)]
      [(ResultBuildPackageFileDigest.Ok digest)
        (ResultBuildString.Ok
          (str_cat.str-cat
            (build-package-transcript-field "link-file-path" path)
            (build-package-transcript-field "link-file-digest" digest)))])
    (ResultBuildString.Ok "")))

(define (build-package-link-raw-file-transcript
  [inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildString
  (let
    [args : process.ProcessStringList
      (build_run_core.source-tool-link-inputs-raw-args inputs)]
    [index : i64 0]
    [count : i64 (process.args-count args)]
    [out : String ""]
    [ok : bool true]
    [error : String ""]
    (begin
      (while (and ok (< index count))
        (let
          [path : String (process.args-ref args index)]
          (begin
            (match (build-package-link-path-transcript path)
              [(ResultBuildString.Err message)
                (begin
                  (set! ok false)
                  (set! error message))]
              [(ResultBuildString.Ok text) (set! out (string.append out text))])
            (set! index (+ index 1)))))
      (if ok
        (ResultBuildString.Ok out)
        (ResultBuildString.Err error)))))

(define (build-package-link-library-candidate [dir : String] [name : String]) : String
  (if (= (string.string-length dir) 0)
    name
    (load.compiler-load-join-root-path dir name)))

(define (build-package-link-library-file-transcript
  [target : backend.CompilerBackendTarget]
  [dir : String]
  [library : String]) : ResultBuildString
  (let
    [direct : String (build-package-link-library-candidate dir library)]
    [first : String
      (build-package-link-library-candidate
        dir
        (match target
          [(backend.CompilerBackendTarget.Linux)
            (str_cat.str-cat "lib" library ".a")]
          [(backend.CompilerBackendTarget.Windows)
            (string.append library ".lib")]))]
    [second : String
      (build-package-link-library-candidate
        dir
        (match target
          [(backend.CompilerBackendTarget.Linux)
            (str_cat.str-cat "lib" library ".so")]
          [(backend.CompilerBackendTarget.Windows) ""]))]
    (match (build-package-link-path-transcript direct)
      [(ResultBuildString.Err message) (ResultBuildString.Err message)]
      [(ResultBuildString.Ok direct-text)
        (match (build-package-link-path-transcript first)
          [(ResultBuildString.Err message) (ResultBuildString.Err message)]
          [(ResultBuildString.Ok first-text)
            (if (= (string.string-length second) 0)
              (ResultBuildString.Ok (string.append direct-text first-text))
              (match (build-package-link-path-transcript second)
                [(ResultBuildString.Err message)
                  (ResultBuildString.Err message)]
                [(ResultBuildString.Ok second-text)
                  (ResultBuildString.Ok
                    (str_cat.str-cat direct-text first-text second-text))]))])])))

(define (build-package-link-library-files-transcript
  [target : backend.CompilerBackendTarget]
  [inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildString
  (let
    [libraries : process.ProcessStringList
      (build_run_core.source-tool-link-inputs-libs inputs)]
    [dirs : process.ProcessStringList
      (build_run_core.source-tool-link-inputs-search-dirs inputs)]
    [library-index : i64 0]
    [library-count : i64 (process.args-count libraries)]
    [out : String ""]
    [ok : bool true]
    [error : String ""]
    (begin
      (while (and ok (< library-index library-count))
        (let
          [library : String (process.args-ref libraries library-index)]
          [dir-index : i64 0]
          [dir-count : i64 (process.args-count dirs)]
          (begin
            (if (= dir-count 0)
              (match (build-package-link-library-file-transcript
                target
                ""
                library)
                [(ResultBuildString.Err message)
                  (begin
                    (set! ok false)
                    (set! error message))]
                [(ResultBuildString.Ok text)
                  (set! out (string.append out text))])
              (while (and ok (< dir-index dir-count))
                (begin
                  (match (build-package-link-library-file-transcript
                    target
                    (process.args-ref dirs dir-index)
                    library)
                    [(ResultBuildString.Err message)
                      (begin
                        (set! ok false)
                        (set! error message))]
                    [(ResultBuildString.Ok text)
                      (set! out (string.append out text))])
                  (set! dir-index (+ dir-index 1)))))
            (set! library-index (+ library-index 1)))))
      (if ok
        (ResultBuildString.Ok out)
        (ResultBuildString.Err error)))))

(define (build-package-link-file-transcript
  [target : backend.CompilerBackendTarget]
  [inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildString
  (match (build-package-link-raw-file-transcript inputs)
    [(ResultBuildString.Err message) (ResultBuildString.Err message)]
    [(ResultBuildString.Ok raw-text)
      (match (build-package-link-library-files-transcript target inputs)
        [(ResultBuildString.Err message) (ResultBuildString.Err message)]
        [(ResultBuildString.Ok library-text)
          (ResultBuildString.Ok (string.append raw-text library-text))])]))

(define (build-package-assembler-command-for
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]) : build_run_core.ResultSourceToolCommand
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (build_run_core.ResultSourceToolCommand.Ok
        (build_run_core.source-tool-assembler-command asm-path obj-path))]
    [(backend.CompilerBackendTarget.Windows)
      (build_run_core.ResultSourceToolCommand.Ok
        (build_run_core.source-tool-windows-assembler-command asm-path obj-path))]))

(define (build-package-artifact-command-for
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]) : build_run_core.ResultSourceToolCommand
  (match kind
    [(CompilerPkgKindBin)
      (match target
        [(backend.CompilerBackendTarget.Linux)
          (build_run_core.ResultSourceToolCommand.Ok
            (build_run_core.source-tool-linker-command
              obj-path
              artifact-path
              link-inputs))]
        [(backend.CompilerBackendTarget.Windows)
          (build_run_core.source-tool-windows-linker-command
            obj-path
            artifact-path
            link-inputs)])]
    [(CompilerPkgKindLib)
      (match target
        [(backend.CompilerBackendTarget.Linux)
          (build_run_core.ResultSourceToolCommand.Ok
            (build_run_core.source-tool-archiver-command obj-path artifact-path))]
        [(backend.CompilerBackendTarget.Windows)
          (build_run_core.source-tool-windows-archiver-command
            obj-path
            artifact-path)])]))

(define (build-package-runtime-input-transcript-after-assembler
  [base : String]
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildString
  (match (build-package-artifact-command-for
    kind
    target
    obj-path
    artifact-path
    link-inputs)
    [(build_run_core.ResultSourceToolCommand.Err message)
      (ResultBuildString.Err message)]
    [(build_run_core.ResultSourceToolCommand.Ok command)
      (match (build-package-command-transcript "runtime artifact tool" command)
        [(ResultBuildString.Err message) (ResultBuildString.Err message)]
        [(ResultBuildString.Ok command-text)
          (match kind
            [(CompilerPkgKindLib)
              (ResultBuildString.Ok
                (str_cat.str-cat
                  base
                  command-text
                  (build-package-runtime-inherited-env-transcript)))]
            [(CompilerPkgKindBin)
              (match (build-package-link-file-transcript target link-inputs)
                [(ResultBuildString.Err message)
                  (ResultBuildString.Err message)]
                [(ResultBuildString.Ok link-file-text)
                  (ResultBuildString.Ok
                    (str_cat.str-cat
                      base
                      command-text
                      link-file-text
                      (build-package-runtime-inherited-env-transcript)))])])])]))

(define (build-package-runtime-input-transcript
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [opt-level : i64]
  [producer-identity : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [direct-object : bool]) : ResultBuildString
  (let
    [base : String
      (str_cat.str-cat
        "typelisp-package-runtime-inputs-v1\n"
        (build-package-transcript-field "producer" producer-identity)
        (build-package-transcript-field
          "target"
          (build_run_core.source-tool-target-name target))
        (build-package-transcript-field "profile" (build-profile-name profile))
        (build-package-transcript-field
          "backend"
          (build-backend-mode-name mode))
        (build-package-transcript-field
          "opt-level"
          (string.int->string opt-level))
        (build-package-transcript-field
          "debug"
          (if (ir.compiler-debug-info-enabled?)
            "true"
            "false"))
        (build-package-transcript-field
          "kind"
          (match kind
            [(CompilerPkgKindBin) "bin"]
            [(CompilerPkgKindLib) "lib"]))
        (build-package-transcript-field
          "direct-object"
          (if direct-object
            "true"
            "false")))]
    (if direct-object
      (build-package-runtime-input-transcript-after-assembler
        base
        kind
        target
        obj-path
        artifact-path
        link-inputs)
      (match (build-package-assembler-command-for target asm-path obj-path)
        [(build_run_core.ResultSourceToolCommand.Err message)
          (ResultBuildString.Err message)]
        [(build_run_core.ResultSourceToolCommand.Ok assembler)
          (match (build-package-command-transcript "assembler" assembler)
            [(ResultBuildString.Err message) (ResultBuildString.Err message)]
            [(ResultBuildString.Ok assembler-text)
              (build-package-runtime-input-transcript-after-assembler
                (string.append base assembler-text)
                kind
                target
                obj-path
                artifact-path
                link-inputs)])]))))

(define (build-package-runtime-output-fingerprint
  [input-transcript : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]) : ResultBuildString
  (match (build-package-file-digest
    asm-path
    "build: cannot fingerprint package assembly")
    [(ResultBuildPackageFileDigest.Err message) (ResultBuildString.Err message)]
    [(ResultBuildPackageFileDigest.Ok asm-digest)
      (match (build-package-file-digest
        obj-path
        "build: cannot fingerprint package object")
        [(ResultBuildPackageFileDigest.Err message)
          (ResultBuildString.Err message)]
        [(ResultBuildPackageFileDigest.Ok obj-digest)
          (match (build-package-file-digest
            artifact-path
            "build: cannot fingerprint package runtime artifact")
            [(ResultBuildPackageFileDigest.Err message)
              (ResultBuildString.Err message)]
            [(ResultBuildPackageFileDigest.Ok artifact-digest)
              (ResultBuildString.Ok
                (str_cat.str-cat
                  input-transcript
                  (build-package-transcript-field "assembly-output" asm-digest)
                  (build-package-transcript-field "object-output" obj-digest)
                  (build-package-transcript-field
                    "runtime-output"
                    artifact-digest)))])])]))

(define (build-package-runtime-outputs-regular?
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [fingerprint-path : String]) : bool
  (and
    (build-package-file-regular? asm-path)
    (build-package-file-regular? obj-path)
    (build-package-file-regular? artifact-path)
    (build-package-file-regular? fingerprint-path)))

(define (build-package-runtime-fingerprint-fresh?
  [input-transcript : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [fingerprint-path : String]) : bool
  (if (not
    (build-package-runtime-outputs-regular?
      asm-path
      obj-path
      artifact-path
      fingerprint-path))
    false
    (match (build-package-runtime-output-fingerprint
      input-transcript
      asm-path
      obj-path
      artifact-path)
      [(ResultBuildString.Err _) false]
      [(ResultBuildString.Ok expected)
        (build-package-file-text-eq? fingerprint-path expected)])))

(define (build-package-runtime-direct-fresh?
  [input-transcript : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [fingerprint-path : String]
  [object-text : String]) : bool
  (and
    (build-package-file-text-eq? obj-path object-text)
    (build-package-runtime-fingerprint-fresh?
      input-transcript
      asm-path
      obj-path
      artifact-path
      fingerprint-path)))

(define (build-package-runtime-assembly-fresh?
  [input-transcript : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [fingerprint-path : String]
  [asm : String]) : bool
  (and
    (build-package-file-text-eq? asm-path asm)
    (build-package-runtime-fingerprint-fresh?
      input-transcript
      asm-path
      obj-path
      artifact-path
      fingerprint-path)))

(define (build-package-path-present? [path : String]) : bool
  (match (fs.try-file-metadata (& path))
    [(fs.OkFsMetadata _) true]
    [(fs.ErrFsMetadata _) false]))

(define (build-package-stage-dir-attempt
  [output-dir : String]
  [_name : String]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 64)
    (ResultBuildString.Err "build: package artifact staging has no free path")
    (let
      [candidate : String
        (load.compiler-load-join-root-path
          output-dir
          (str_cat.str-cat ".t" (string.int->string attempt)))]
      (if (build-package-path-present? candidate)
        (build-package-stage-dir-attempt output-dir _name (+ attempt 1))
        (if (build-mkdir-ok-owned? candidate)
          (ResultBuildString.Ok candidate)
          (ResultBuildString.Err
            (str_cat.str-cat
              "build: failed to create package artifact staging directory "
              candidate)))))))

(define (build-package-stage-file
  [dir : String]
  [stem : String]
  [final-path : String]) : String
  (let
    [extension : String (fs.extension (& final-path))]
    (load.compiler-load-join-root-path
      dir
      (if (= (string.string-length extension) 0)
        stem
        (str_cat.str-cat stem "." extension)))))

(define (build-package-stage-paths
  [output-dir : String]
  [name : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [fingerprint-path : String]
  [tlci-path : String]) : ResultBuildPackageStagePaths
  (match (build-package-stage-dir-attempt output-dir name 1)
    [(ResultBuildString.Err message) (ResultBuildPackageStagePaths.Err message)]
    [(ResultBuildString.Ok dir)
      (ResultBuildPackageStagePaths.Ok
        (BuildPackageStagePaths
          dir
          (build-package-stage-file dir "a" asm-path)
          (build-package-stage-file dir "o" obj-path)
          (build-package-stage-file dir "r" artifact-path)
          (build-package-stage-file dir "f" fingerprint-path)
          (build-package-stage-file dir "t" tlci-path)))]))

(define (build-package-remove-staged-file [path : String]) : unit
  (begin
    (fs.try-remove-file-if-exists (& path))
    (let
      [backup : String (string.append path ".previous")]
      (fs.try-remove-file-if-exists (& backup)))
    unit))

(define (build-package-clean-stage [paths : BuildPackageStagePaths]) : unit
  (begin
    (build-package-remove-staged-file paths.asm)
    (build-package-remove-staged-file paths.obj)
    (build-package-remove-staged-file paths.artifact)
    (build-package-remove-staged-file paths.fingerprint)
    (build-package-remove-staged-file paths.tlci)
    (let
      [dir : String paths.dir]
      (fs.try-remove-dir-if-exists (& dir)))
    unit))

(define (build-package-commit-plan-new) : BuildPackageCommitPlan
  (BuildPackageCommitPlan (make-array BuildPackageCommitFile 5) 0))

(define (build-package-commit-plan-add
  [plan : BuildPackageCommitPlan]
  [final-path : String]
  [staged-path : String]) : BuildPackageCommitPlan
  (let
    [files : (__tl_dyn-array BuildPackageCommitFile) plan.files]
    [index : i64 plan.len]
    (begin
      (set!
        (array-ref files index)
        (BuildPackageCommitFile
          final-path
          staged-path
          (string.append staged-path ".previous")
          false))
      (BuildPackageCommitPlan files (+ index 1)))))

(define (build-package-commit-plan-set-had-old!
  [plan : BuildPackageCommitPlan]
  [index : i64]) : unit
  (let
    [files : (__tl_dyn-array BuildPackageCommitFile) plan.files]
    [item : BuildPackageCommitFile (array-ref files index)]
    (set!
      (array-ref files index)
      (BuildPackageCommitFile
        item.final-path
        item.staged-path
        item.backup-path
        true))))

(define (build-package-commit-plan-preflight [plan : BuildPackageCommitPlan]) : ResultBuildString
  (let
    [index : i64 0]
    [count : i64 plan.len]
    [ok : bool true]
    [error : String ""]
    (begin
      (while (and ok (< index count))
        (let
          [item : BuildPackageCommitFile (array-ref plan.files index)]
          [final-state : BuildPackageArtifactState
            (build-package-artifact-file-state item.final-path)]
          (begin
            (if (not (build-package-file-regular? item.staged-path))
              (begin
                (set! ok false)
                (set!
                  error
                  (str_cat.str-cat
                    "build: staged package artifact is missing or non-regular: "
                    item.staged-path)))
              (match final-state
                [(BuildPackageArtifactState.Stale reason)
                  (begin
                    (set! ok false)
                    (set!
                      error
                      (str_cat.str-cat
                        "build: cannot replace package artifact "
                        item.final-path
                        ": "
                        reason)))]
                [_ unit]))
            (set! index (+ index 1)))))
      (if ok
        (ResultBuildString.Ok "")
        (ResultBuildString.Err error)))))

(define (build-package-commit-plan-rollback
  [plan : BuildPackageCommitPlan]
  [installed : i64]
  [backed-up : i64]) : unit
  (let
    [index : i64 (- installed 1)]
    (begin
      (while (>= index 0)
        (let
          [item : BuildPackageCommitFile (array-ref plan.files index)]
          (begin
            (let
              [path : String item.final-path]
              (fs.try-remove-file-if-exists (& path)))
            (set! index (- index 1)))))
      (set! index (- backed-up 1))
      (while (>= index 0)
        (let
          [item : BuildPackageCommitFile (array-ref plan.files index)]
          (begin
            (if item.had-old
              (let
                [backup : String item.backup-path]
                [final-path : String item.final-path]
                (fs.try-rename (& backup) (& final-path)))
              io.OkIoUnit)
            (set! index (- index 1)))))
      unit)))

(define (build-package-commit-plan-run [plan : BuildPackageCommitPlan]) : ResultBuildString
  (match (build-package-commit-plan-preflight plan)
    [(ResultBuildString.Err message) (ResultBuildString.Err message)]
    [(ResultBuildString.Ok _)
      (let
        [index : i64 0]
        [count : i64 plan.len]
        [backed-up : i64 0]
        [installed : i64 0]
        [ok : bool true]
        [error : String ""]
        (begin
          (while (and ok (< index count))
            (let
              [item : BuildPackageCommitFile (array-ref plan.files index)]
              [state : BuildPackageArtifactState
                (build-package-artifact-file-state item.final-path)]
              (begin
                (match state
                  [(BuildPackageArtifactState.Clean)
                    (let
                      [from : String item.final-path]
                      [to : String item.backup-path]
                      (match (fs.try-rename (& from) (& to))
                        [(io.OkIoUnit)
                          (build-package-commit-plan-set-had-old! plan index)]
                        [(io.ErrIoUnit io-error)
                          (begin
                            (set! ok false)
                            (set!
                              error
                              (str_cat.str-cat
                                "build: failed to stage previous package artifact: "
                                (io.error-message io-error))))]))]
                  [(BuildPackageArtifactState.Missing) unit]
                  [(BuildPackageArtifactState.Stale reason)
                    (begin
                      (set! ok false)
                      (set! error reason))])
                (if ok
                  (set! backed-up (+ backed-up 1))
                  unit)
                (set! index (+ index 1)))))
          (set! index 0)
          (while (and ok (< index count))
            (let
              [item : BuildPackageCommitFile (array-ref plan.files index)]
              [from : String item.staged-path]
              [to : String item.final-path]
              (begin
                (match (fs.try-rename (& from) (& to))
                  [(io.OkIoUnit) (set! installed (+ installed 1))]
                  [(io.ErrIoUnit io-error)
                    (begin
                      (set! ok false)
                      (set!
                        error
                        (str_cat.str-cat
                          "build: failed to commit package artifact: "
                          (io.error-message io-error))))])
                (set! index (+ index 1)))))
          (if ok
            (begin
              (set! index 0)
              (while (< index count)
                (let
                  [item : BuildPackageCommitFile (array-ref plan.files index)]
                  (begin
                    (if item.had-old
                      (let
                        [backup : String item.backup-path]
                        (fs.try-remove-file-if-exists (& backup)))
                      io.OkIoUnit)
                    (set! index (+ index 1)))))
              (ResultBuildString.Ok ""))
            (begin
              (build-package-commit-plan-rollback plan installed backed-up)
              (ResultBuildString.Err error)))))]))

(define (build-package-write-tlci [path : String] [text : String]) : build_run_core.SourceToolCommandStatus
  (build_run_core.source-tool-write-file
    path
    text
    "build: failed to write package tlci"))

(define (build-package-write-assembly
  [path : String]
  [asm : String]
  [target : backend.CompilerBackendTarget]) : build_run_core.SourceToolCommandStatus
  (match (build_run_core.source-tool-write-file
    path
    asm
    "build: failed to write package assembly")
    [(build_run_core.SourceToolCommandStatus.Err message)
      (build_run_core.SourceToolCommandStatus.Err message)]
    [(build_run_core.SourceToolCommandStatus.Ok)
      (let
        [haystack : String asm]
        [needle : String ".note.GNU-stack"]
        [note : String (build_run_core.source-tool-noexecstack-note)]
        (if (and
          (backend.compiler-backend-target-linux? target)
          (not (string.contains (& haystack) (& needle))))
          (match (io.try-append-file (& path) (byte_buf.str-as-bytes (& note)))
            [(io.OkIoUnit) build_run_core.SourceToolCommandStatus.Ok]
            [(io.ErrIoUnit error)
              (build_run_core.SourceToolCommandStatus.Err
                (str_cat.str-cat
                  "build: failed to write package assembly: "
                  (io.error-message error)))])
          build_run_core.SourceToolCommandStatus.Ok))]))

(define (build-package-write-side-assembly
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : ast.AstDeclList]
  [owned-paths : ast.AstDeclPathList]
  [asm-path : String]) : build_run_core.SourceToolCommandStatus
  (match (compiler_driver_core.compiler-driver-emit-package-loaded
    ""
    target
    true
    opt-level
    mode
    emit-entry
    crt-entry
    decls
    owned-paths)
    [(compiler_driver_core.ResultCompilerDriver.Err diag)
      (build_run_core.SourceToolCommandStatus.Err
        (compiler_driver_core.compiler-driver-render-source-diagnostic
          (__tl-box-place diag)))]
    [(compiler_driver_core.ResultCompilerDriver.Ok asm)
      (begin
        (compiler_driver_core.compiler-driver-release-lower-arenas-after-emit!)
        (build-package-write-assembly asm-path asm target))]))

(define (build-package-announce-freshness
  [artifact-path : String]
  [tlci-path : String]
  [runtime-dirty : bool]
  [tlci-dirty : bool]
  [announce : bool]) : i64
  (if announce
    (begin
      (io.print-string
        (str_cat.str-cat
          (if runtime-dirty
            "Built "
            "Fresh ")
          artifact-path
          "\n"))
      (io.print-string
        (str_cat.str-cat
          (if tlci-dirty
            "Built "
            "Fresh ")
          tlci-path
          "\n"))
      0)
    0))

(define (build-package-commit-generated-artifacts
  [stage : BuildPackageStagePaths]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [fingerprint-path : String]
  [tlci-path : String]
  [tlci-text : String]
  [input-transcript : String]
  [runtime-dirty : bool]
  [tlci-dirty : bool]
  [announce : bool]) : i64
  (let
    [ok : bool true]
    [error : String ""]
    [plan : BuildPackageCommitPlan (build-package-commit-plan-new)]
    (begin
      (if runtime-dirty
        (match (build-package-runtime-output-fingerprint
          input-transcript
          stage.asm
          stage.obj
          stage.artifact)
          [(ResultBuildString.Err message)
            (begin
              (set! ok false)
              (set! error message))]
          [(ResultBuildString.Ok fingerprint)
            (match (build_run_core.source-tool-write-file
              stage.fingerprint
              fingerprint
              "build: failed to stage package runtime fingerprint")
              [(build_run_core.SourceToolCommandStatus.Err message)
                (begin
                  (set! ok false)
                  (set! error message))]
              [(build_run_core.SourceToolCommandStatus.Ok)
                (begin
                  (set!
                    plan
                    (build-package-commit-plan-add plan asm-path stage.asm))
                  (set!
                    plan
                    (build-package-commit-plan-add plan obj-path stage.obj))
                  (set!
                    plan
                    (build-package-commit-plan-add
                      plan
                      artifact-path
                      stage.artifact))
                  (set!
                    plan
                    (build-package-commit-plan-add
                      plan
                      fingerprint-path
                      stage.fingerprint)))])])
        unit)
      (if (and ok tlci-dirty)
        (match (build-package-write-tlci stage.tlci tlci-text)
          [(build_run_core.SourceToolCommandStatus.Err message)
            (begin
              (set! ok false)
              (set! error message))]
          [(build_run_core.SourceToolCommandStatus.Ok)
            (set!
              plan
              (build-package-commit-plan-add plan tlci-path stage.tlci))])
        unit)
      (if ok
        (match (build-package-commit-plan-run plan)
          [(ResultBuildString.Err message)
            (begin
              (build-package-clean-stage stage)
              (io.print-error message)
              1)]
          [(ResultBuildString.Ok _)
            (begin
              (build-package-clean-stage stage)
              (build-package-announce-freshness
                artifact-path
                tlci-path
                runtime-dirty
                tlci-dirty
                announce))])
        (begin
          (build-package-clean-stage stage)
          (io.print-error error)
          1)))))

(define (build-package-finish-direct-fresh-artifacts
  [name : String]
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [producer-identity : String]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : ast.AstDeclList]
  [owned-paths : ast.AstDeclPathList]
  [output-dir : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [tlci-path : String]
  [tlci-text : String]
  [object-text : String]
  [side-assembly : BuildPackageSideAssembly]
  [announce : bool]) : i64
  (let
    [fingerprint-path : String
      (build-package-runtime-fingerprint-path artifact-path)]
    [tlci-dirty : bool (not (build-package-file-text-eq? tlci-path tlci-text))]
    (match (build-package-runtime-input-transcript
      kind
      target
      profile
      mode
      opt-level
      producer-identity
      asm-path
      obj-path
      artifact-path
      link-inputs
      true)
      [(ResultBuildString.Err message)
        (begin
          (io.print-error message)
          1)]
      [(ResultBuildString.Ok input-transcript)
        (let
          [runtime-dirty : bool
            (not
              (build-package-runtime-direct-fresh?
                input-transcript
                asm-path
                obj-path
                artifact-path
                fingerprint-path
                object-text))]
          (if (and (not runtime-dirty) (not tlci-dirty))
            (begin
              (compiler_driver_core.compiler-driver-release-lower-arenas-after-emit!)
              (compiler_driver_core.compiler-driver-reset-file-state!)
              (build-package-announce-freshness
                artifact-path
                tlci-path
                false
                false
                announce))
            (match (build-package-stage-paths
              output-dir
              name
              asm-path
              obj-path
              artifact-path
              fingerprint-path
              tlci-path)
              [(ResultBuildPackageStagePaths.Err message)
                (begin
                  (io.print-error message)
                  1)]
              [(ResultBuildPackageStagePaths.Ok stage)
                (let
                  [runtime-status : build_run_core.SourceToolDirectObjectStatus
                    (if runtime-dirty
                      (build-package-write-direct-object-artifact
                        kind
                        target
                        stage.obj
                        stage.artifact
                        link-inputs
                        object-text)
                      build_run_core.SourceToolDirectObjectStatus.Ok)]
                  (match runtime-status
                    [(build_run_core.SourceToolDirectObjectStatus.Err message)
                      (begin
                        (build-package-clean-stage stage)
                        (io.print-error message)
                        1)]
                    [(build_run_core.SourceToolDirectObjectStatus.Unavailable
                        message)
                      (begin
                        (build-package-clean-stage stage)
                        (io.print-error message)
                        1)]
                    [(build_run_core.SourceToolDirectObjectStatus.Ok)
                      (let
                        [asm-status : build_run_core.SourceToolCommandStatus
                          (if runtime-dirty
                            (match side-assembly
                              [(BuildPackageSideAssembly.Regenerate)
                                (build-package-write-side-assembly
                                  target
                                  opt-level
                                  mode
                                  emit-entry
                                  crt-entry
                                  decls
                                  owned-paths
                                  stage.asm)]
                              [(BuildPackageSideAssembly.Prepared asm)
                                (build-package-write-assembly
                                  stage.asm
                                  asm
                                  target)])
                            build_run_core.SourceToolCommandStatus.Ok)]
                        (match asm-status
                          [(build_run_core.SourceToolCommandStatus.Err message)
                            (begin
                              (build-package-clean-stage stage)
                              (io.print-error message)
                              1)]
                          [(build_run_core.SourceToolCommandStatus.Ok)
                            (begin
                              (if runtime-dirty
                                unit
                                (compiler_driver_core.compiler-driver-release-lower-arenas-after-emit!))
                              (compiler_driver_core.compiler-driver-reset-file-state!)
                              (build-package-commit-generated-artifacts
                                stage
                                asm-path
                                obj-path
                                artifact-path
                                fingerprint-path
                                tlci-path
                                tlci-text
                                input-transcript
                                runtime-dirty
                                tlci-dirty
                                announce))]))]))])))])))

(define (build-package-finish-assembly-fresh-artifacts
  [name : String]
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [producer-identity : String]
  [output-dir : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [tlci-path : String]
  [tlci-text : String]
  [asm : String]
  [announce : bool]) : i64
  (let
    [fingerprint-path : String
      (build-package-runtime-fingerprint-path artifact-path)]
    [augmented-asm : String
      (build_run_core.source-tool-augment-assembly-for-target asm target)]
    [tlci-dirty : bool (not (build-package-file-text-eq? tlci-path tlci-text))]
    [_release-lower : unit
      (compiler_driver_core.compiler-driver-release-lower-arenas-after-emit!)]
    (match (build-package-runtime-input-transcript
      kind
      target
      profile
      mode
      opt-level
      producer-identity
      asm-path
      obj-path
      artifact-path
      link-inputs
      false)
      [(ResultBuildString.Err message)
        (begin
          (io.print-error message)
          1)]
      [(ResultBuildString.Ok input-transcript)
        (let
          [runtime-dirty : bool
            (not
              (build-package-runtime-assembly-fresh?
                input-transcript
                asm-path
                obj-path
                artifact-path
                fingerprint-path
                augmented-asm))]
          (if (and (not runtime-dirty) (not tlci-dirty))
            (begin
              (compiler_driver_core.compiler-driver-reset-file-state!)
              (build-package-announce-freshness
                artifact-path
                tlci-path
                false
                false
                announce))
            (match (build-package-stage-paths
              output-dir
              name
              asm-path
              obj-path
              artifact-path
              fingerprint-path
              tlci-path)
              [(ResultBuildPackageStagePaths.Err message)
                (begin
                  (io.print-error message)
                  1)]
              [(ResultBuildPackageStagePaths.Ok stage)
                (let
                  [runtime-status : build_run_core.SourceToolCommandStatus
                    (if runtime-dirty
                      (match (build-package-write-assembly
                        stage.asm
                        augmented-asm
                        target)
                        [(build_run_core.SourceToolCommandStatus.Err message)
                          (build_run_core.SourceToolCommandStatus.Err message)]
                        [(build_run_core.SourceToolCommandStatus.Ok)
                          (build-package-artifact-status
                            kind
                            target
                            stage.asm
                            stage.obj
                            stage.artifact
                            link-inputs
                            (build_run_core.SourceToolDirectObjectStatus.Unavailable
                              "freshness fallback"))])
                      build_run_core.SourceToolCommandStatus.Ok)]
                  (match runtime-status
                    [(build_run_core.SourceToolCommandStatus.Err message)
                      (begin
                        (build-package-clean-stage stage)
                        (io.print-error message)
                        1)]
                    [(build_run_core.SourceToolCommandStatus.Ok)
                      (begin
                        (compiler_driver_core.compiler-driver-reset-file-state!)
                        (build-package-commit-generated-artifacts
                          stage
                          asm-path
                          obj-path
                          artifact-path
                          fingerprint-path
                          tlci-path
                          tlci-text
                          input-transcript
                          runtime-dirty
                          tlci-dirty
                          announce))]))])))])))

(define (build-package-finish-fresh-artifacts
  [name : String]
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [producer-identity : String]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : ast.AstDeclList]
  [owned-paths : ast.AstDeclPathList]
  [output-dir : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [tlci-path : String]
  [tlci-text : String]
  [announce : bool]) : i64
  (match (build-package-try-prepare-direct-runtime
    kind
    target
    opt-level
    mode
    emit-entry
    crt-entry
    decls
    owned-paths)
    [(ResultBuildPackagePreparedRuntime.DirectObject object-text side-assembly)
      (build-package-finish-direct-fresh-artifacts
        name
        kind
        target
        opt-level
        profile
        mode
        producer-identity
        emit-entry
        crt-entry
        decls
        owned-paths
        output-dir
        asm-path
        obj-path
        artifact-path
        link-inputs
        tlci-path
        tlci-text
        object-text
        side-assembly
        announce)]
    [(ResultBuildPackagePreparedRuntime.Assembly asm _)
      (build-package-finish-assembly-fresh-artifacts
        name
        kind
        target
        opt-level
        profile
        mode
        producer-identity
        output-dir
        asm-path
        obj-path
        artifact-path
        link-inputs
        tlci-path
        tlci-text
        asm
        announce)]
    [(ResultBuildPackagePreparedRuntime.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultBuildPackagePreparedRuntime.Unavailable _)
      (match (compiler_driver_core.compiler-driver-emit-package-loaded
        ""
        target
        true
        opt-level
        mode
        emit-entry
        crt-entry
        decls
        owned-paths)
        [(compiler_driver_core.ResultCompilerDriver.Err diag)
          (begin
            (io.print-error
              (compiler_driver_core.compiler-driver-render-source-diagnostic
                (__tl-box-place diag)))
            1)]
        [(compiler_driver_core.ResultCompilerDriver.Ok asm)
          (build-package-finish-assembly-fresh-artifacts
            name
            kind
            target
            opt-level
            profile
            mode
            producer-identity
            output-dir
            asm-path
            obj-path
            artifact-path
            link-inputs
            tlci-path
            tlci-text
            asm
            announce)])]))

(define (build-package-doctest-paths
  [owner : String]
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [owner-id : i64
      (ast.ast-decl-path-list-owner-id
        (& paths)
        0
        cbi.compiler-builtin-id-fix-empty)]
    (match (ast.ast-decl-path-list-step paths)
      [(ast.AstDeclPathListStep.Nil) (ast.ast-decl-path-list-new)]
      [(ast.AstDeclPathListStep.Cons path rest)
        (let
          [tail : ast.AstDeclPathList (build-package-doctest-paths owner rest)]
          (if (build-package-tlci-stdlib-path? owner path)
            tail
            (ast.ast-decl-path-list-prepend-builder-with-owner-id
              path
              owner-id
              tail)))])))

(define (build-package-closure-doctest-status
  [owner : String]
  [entry-path : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [deps : load.CompilerPkgDeps]
  [emit-entry : bool]) : i64
  (match (compiler_driver_core.compiler-driver-load-package-file-with-runtime
    entry-path
    target
    stdlib-roots
    manifest-dir
    deps
    emit-entry)
    [(load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (io.print-error
          (compiler_driver_core.compiler-driver-render-source-diagnostic
            (__tl-box-place diag)))
        1)]
    [(load.ResultCompilerLoadWithPaths.Ok _ paths _ _)
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
  [deps : load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : i64
  (match (package_source_core.package-source-discover-for
    "build"
    manifest-path
    true)
    [(package_source_core.ResultPackageSourceSet.Err message)
      (begin
        (io.print-error message)
        1)]
    [(package_source_core.ResultPackageSourceSet.Ok source-set)
      (test_cli_core.tltest-inline-typecheck-package-sources-with-cfg
        source-set.sources
        stdlib-roots
        manifest-dir
        name
        deps
        cfgs
        "typecheck-prefix-inline-build-package")]))

(define (build-package-emit-one
  [manifest-path : String]
  [manifest : load.CompilerPkgManifest]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [dep-libs : process.ProcessStringList]
  [producer-identity : String]
  [announce : bool]) : i64
  (let
    ;; Windows package DAG nodes are serial same-process compiles; keep only
    ;; persistent cache floors between dependency and root emits.
    [_ : unit
      (cfg
        windows
        (compiler_driver_core.compiler-driver-reset-file-state!)
        unit)]
    [manifest-dir : String (load.compiler-load-dirname manifest-path)]
    [compile-context : BuildPackageCompileContext
      (build-package-compile-context manifest-dir manifest)]
    [entry-path : String
      (load.compiler-load-join-root-path manifest-dir manifest.entry)]
    [name : String manifest.name]
    [_spmd-package-name : unit (lower.lower-spmd-set-package-name! name)]
    [_package-artifact-profile : unit
      (load.compiler-load-set-package-artifact-profile!
        (build-profile-name profile))]
    [kind : load.CompilerPkgKind manifest.kind]
    [asm-path : String
      (build-package-asm-path-profile manifest-dir name profile)]
    [obj-path : String
      (build-package-obj-path-profile manifest-dir name profile target)]
    [artifact-paths : BuildPackageArtifactPaths
      (build-package-artifact-paths manifest-dir name kind profile target)]
    [artifact-path : String
      (build-package-runtime-artifact-path artifact-paths)]
    [tlci-path : String (build-package-host-tlci-artifact-path artifact-paths)]
    [_reset-file-state : unit
      (compiler_driver_core.compiler-driver-reset-file-state!)]
    (if (or
      (> (string.string-length compile-context.error) 0)
      (not (build-ensure-package-output-dirs manifest-dir name profile)))
      (let
        [message : String
          (if (> (string.string-length compile-context.error) 0)
            compile-context.error
            (str_cat.str-cat
              "build: failed to create package output directory "
              (build-package-output-dir-profile manifest-dir name profile)))]
        (begin
          (io.print-error message)
          1))
      (let
        [manifest-link-inputs : build_run_core.SourceToolLinkInputs
          (build-package-manifest-link-inputs manifest.link manifest-dir target)]
        [dep-link-inputs : build_run_core.SourceToolLinkInputs
          (build_run_core.source-tool-link-inputs-from-archives dep-libs)]
        [emit-entry : bool (build-package-kind-entry? kind)]
        [inline-test-status : i64
          (build-inline-test-typecheck-package-sources
            manifest-path
            stdlib-roots
            manifest-dir
            name
            manifest.deps
            (build-package-compile-cfgs target compile-context.root-compiler))]
        [_reset-after-inline-tests : unit
          (if (= inline-test-status 0)
            (begin
              (compiler_driver_core.compiler-driver-reset-file-state!)
              (ci.intern-persistent-arena-reset!))
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
                manifest.deps
                (load.compiler-pkg-deps-list manifest.deps)
                stdlib-roots
                manifest-dir
                emit-entry)]
            [_reset-after-pre-emit-doctests : unit
              (begin
                (compiler_driver_core.compiler-driver-reset-file-state!)
                (ci.intern-persistent-arena-reset!))]
            (if (= pre-emit-doctest-status 0)
              (match (build-package-tlci-text-loaded
                manifest-path
                manifest
                mode
                entry-path
                stdlib-roots
                manifest-dir
                manifest.deps
                emit-entry
                (build-package-compile-cfgs
                  target
                  compile-context.root-compiler)
                producer-identity)
                [(ResultBuildPackageTlciText.Err message)
                  (begin
                    (io.print-error message)
                    1)]
                [(ResultBuildPackageTlciText.Ok tlci-text)
                  (begin
                    ;; Producer-created intern ids must not remain live into
                    ;; lowering; tlci-text is allocated in the caller arena.
                    (compiler_driver_core.compiler-driver-reset-file-state!)
                    (ci.intern-persistent-arena-reset!)
                    (match (compiler_driver_core.compiler-driver-load-package-file-with-runtime-cfg
                      entry-path
                      stdlib-roots
                      manifest-dir
                      manifest.deps
                      emit-entry
                      (build-package-compile-cfgs
                        target
                        compile-context.root-compiler))
                      [(load.ResultCompilerLoadWithPaths.Err diag)
                        (begin
                          (io.print-error
                            (compiler_driver_core.compiler-driver-render-source-diagnostic
                              (__tl-box-place diag)))
                          1)]
                      [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
                        (let
                          [owned-paths : ast.AstDeclPathList
                            (load.compiler-load-package-owned-paths-for-decls
                              name
                              manifest-dir
                              stdlib-roots
                              entry-path
                              decls
                              paths)]
                          [metadata-link-inputs : build_run_core.SourceToolLinkInputs
                            (build_run_core.source-tool-link-inputs-from-decls
                              decls
                              (build_run_core.source-tool-link-inputs-empty))]
                          ;; Merge order: manifest all-target/target inputs, source extern
                          ;; metadata, then dependency archives (kept positional after the
                          ;; requested libraries/args).
                          [effective-link-inputs : build_run_core.SourceToolLinkInputs
                            (build_run_core.source-tool-link-inputs-merge
                              (build_run_core.source-tool-link-inputs-merge
                                manifest-link-inputs
                                metadata-link-inputs)
                              dep-link-inputs)]
                          [crt-entry : bool
                            (and
                              emit-entry
                              (build_run_core.source-tool-linux-crt-entry?
                                target
                                effective-link-inputs))]
                          (build-package-finish-fresh-artifacts
                            name
                            kind
                            target
                            opt-level
                            profile
                            mode
                            producer-identity
                            emit-entry
                            crt-entry
                            decls
                            owned-paths
                            (build-package-output-dir-profile
                              manifest-dir
                              name
                              profile)
                            asm-path
                            obj-path
                            artifact-path
                            effective-link-inputs
                            tlci-path
                            tlci-text
                            announce))]))])
              pre-emit-doctest-status))
          inline-test-status)))))

(define (build-package-worker-unified-cli?) : bool
  (and
    (> (io.arg-count) 1)
    (or (string.eq (io.arg 1) "build") (string.eq (io.arg 1) "run"))))

(define (build-package-worker-command-prefix [args : process.ProcessStringList]) : process.ProcessStringList
  (if (build-package-worker-unified-cli?)
    (build_run_core.source-tool-args-append args "build")
    args))

(define (build-package-worker-append-option
  [args : process.ProcessStringList]
  [flag : String]
  [value : String]) : process.ProcessStringList
  (build_run_core.source-tool-args-append
    (build_run_core.source-tool-args-append args flag)
    value))

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
  [deps : load.CompilerPkgDepList]
  [index : i64]) : process.ProcessStringList
  (if (>= index (load.compiler-pkg-dep-list-count deps))
    args
    (let
      [dep : load.CompilerPkgDep (load.compiler-pkg-dep-list-at deps index)]
      (build-package-worker-append-resolved-deps
        (build_run_core.source-tool-args-append
          (build_run_core.source-tool-args-append
            (build_run_core.source-tool-args-append args "--resolved-dep")
            dep.alias)
          dep.path)
        deps
        (+ index 1)))))

(define (build-package-worker-resolved-deps-args-smoke-ok?) : bool
  (let
    [remote : load.CompilerPkgDep
      (load.CompilerPkgDep "remote" "target/typelisp/git-deps/remote")]
    [local : load.CompilerPkgDep (load.CompilerPkgDep "local" "../local")]
    [deps : load.CompilerPkgDepList
      (load.compiler-pkg-dep-list-push
        (load.compiler-pkg-dep-list-push
          (load.compiler-pkg-dep-list-empty)
          remote)
        local)]
    [actual : process.ProcessStringList
      (build-package-worker-append-resolved-deps (process.args-empty) deps 0)]
    [expected0 : process.ProcessStringList
      (build_run_core.source-tool-args-append
        (process.args-empty)
        "--resolved-dep")]
    [expected1 : process.ProcessStringList
      (build_run_core.source-tool-args-append expected0 "remote")]
    [expected2 : process.ProcessStringList
      (build_run_core.source-tool-args-append
        expected1
        "target/typelisp/git-deps/remote")]
    [expected3 : process.ProcessStringList
      (build_run_core.source-tool-args-append expected2 "--resolved-dep")]
    [expected4 : process.ProcessStringList
      (build_run_core.source-tool-args-append expected3 "local")]
    [expected : process.ProcessStringList
      (build_run_core.source-tool-args-append expected4 "../local")]
    (build_run_core.source-tool-string-list-eq? actual expected)))

(test
  build-package-worker-resolved-deps-args-smoke
  (unless
    (build-package-worker-resolved-deps-args-smoke-ok?)
    (io.panic "build package worker resolved deps args smoke failed")))

(define (build-package-worker-args-with-flag
  [worker-flag : String]
  [manifest-path : String]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [resolved-deps : load.CompilerPkgDepList]
  [stdlib-roots : cli_svec.Vec]) : process.ProcessStringList
  (let
    [args0 : process.ProcessStringList
      (build-package-worker-command-prefix (process.args-empty))]
    [args1 : process.ProcessStringList
      (build_run_core.source-tool-args-append args0 worker-flag)]
    [args2 : process.ProcessStringList
      (build-package-worker-append-option args1 "--manifest-path" manifest-path)]
    [args3 : process.ProcessStringList
      (build-package-worker-append-option
        args2
        "--target"
        (build_run_core.source-tool-target-name target))]
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
    [debug-args : process.ProcessStringList
      (if (ir.compiler-debug-info-enabled?)
        (build_run_core.source-tool-args-append args6 "--debug")
        args6)]
    [args7 : process.ProcessStringList
      (build-package-lock-policy-arg debug-args lock-policy)]
    [args8 : process.ProcessStringList
      (build-package-worker-append-resolved-deps args7 resolved-deps 0)]
    (build-package-worker-append-stdlib-roots args8 stdlib-roots)))

(define (build-package-worker-args
  [manifest-path : String]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
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
    (load.compiler-pkg-dep-list-empty)
    stdlib-roots))

(define (build-package-worker-command
  [manifest-path : String]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
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
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [resolved-deps : load.CompilerPkgDepList]
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
      (build_run_core.source-tool-args-append (process.args-empty) "--version")))
    [(process.OkProcessOutput output) (= (process.output-status output) 0)]
    [(process.ErrProcessOutput _) false]))

(define (build-package-run-doctest-worker-or-inline
  [owner : String]
  [entry-path : String]
  [manifest-path : String]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [deps : load.CompilerPkgDeps]
  [resolved-deps : load.CompilerPkgDepList]
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
        (build_run_core.source-tool-forward-output output)
        (process.output-status output))]
    [(process.ErrProcessOutput error)
      (if (or
        (process.error-spawn-failed? error)
        (process.error-unsupported? error))
        (begin
          (compiler_driver_core.compiler-driver-reset-file-state!)
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

(define (build-package-worker-run-from
  [idx : i64]
  [count : i64]
  [producer-identity : String]) : i64
  (match (build-package-worker-config-from idx count)
    [(ResultBuildPackageWorkerConfig.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ResultBuildPackageWorkerConfig.Ok config)
      (let
        [manifest-path : String config.manifest-path]
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-load-manifest normalized-path)
          [(ResultBuildManifest.Err message)
            (begin
              (io.print-error (str_cat.str-cat "Error: " message))
              1)]
          [(ResultBuildManifest.Ok manifest)
            (let
              [resolved-deps : load.CompilerPkgDepList config.resolved-deps]
              [resolved-manifest-result : ResultBuildManifest
                (if (= (load.compiler-pkg-dep-list-count resolved-deps) 0)
                  (build-package-resolve-manifest-deps
                    normalized-path
                    manifest
                    config.lock-policy)
                  (ResultBuildManifest.Ok
                    (load.CompilerPkgManifest
                      manifest.name
                      manifest.version
                      manifest.kind
                      manifest.entry
                      (load.compiler-pkg-deps-from-list resolved-deps)
                      manifest.link)))]
              (match resolved-manifest-result
                [(ResultBuildManifest.Err message)
                  (begin
                    (io.print-error message)
                    1)]
                [(ResultBuildManifest.Ok resolved-manifest)
                  (if (build-package-kind-lib? resolved-manifest.kind)
                    (build-package-emit-one
                      normalized-path
                      resolved-manifest
                      config.target
                      config.opt-level
                      config.profile
                      config.mode
                      config.lock-policy
                      config.stdlib-roots
                      (process.args-empty)
                      producer-identity
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
        [manifest-path : String config.manifest-path]
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-load-manifest normalized-path)
          [(ResultBuildManifest.Err message)
            (begin
              (io.print-error (str_cat.str-cat "Error: " message))
              1)]
          [(ResultBuildManifest.Ok manifest)
            (let
              [resolved-deps : load.CompilerPkgDepList config.resolved-deps]
              [resolved-manifest-result : ResultBuildManifest
                (if (= (load.compiler-pkg-dep-list-count resolved-deps) 0)
                  (build-package-resolve-manifest-deps
                    normalized-path
                    manifest
                    config.lock-policy)
                  (ResultBuildManifest.Ok
                    (load.CompilerPkgManifest
                      manifest.name
                      manifest.version
                      manifest.kind
                      manifest.entry
                      (load.compiler-pkg-deps-from-list resolved-deps)
                      manifest.link)))]
              (match resolved-manifest-result
                [(ResultBuildManifest.Err message)
                  (begin
                    (io.print-error message)
                    1)]
                [(ResultBuildManifest.Ok resolved-manifest)
                  (let
                    [manifest-dir : String
                      (load.compiler-load-dirname normalized-path)]
                    [entry-path : String
                      (load.compiler-load-join-root-path
                        manifest-dir
                        resolved-manifest.entry)]
                    [kind : load.CompilerPkgKind resolved-manifest.kind]
                    (build-package-closure-doctest-status
                      resolved-manifest.name
                      entry-path
                      config.target
                      config.stdlib-roots
                      manifest-dir
                      resolved-manifest.deps
                      (build-package-kind-entry? kind)))]))]))]))

(define (build-package-async-process-supported?) : bool
  (not (string.eq (env.path-list-separator) ";")))

(define (build-package-deps-built?
  [manifest-dir : String]
  [deps : load.CompilerPkgDepList]
  [index : i64]
  [built : build_string_i64_map.Map]) : bool
  (if (>= index (load.compiler-pkg-dep-list-count deps))
    true
    (let
      [dep-manifest-path : String
        (build-package-dep-manifest-path
          manifest-dir
          (load.compiler-pkg-dep-list-at deps index))]
      (match (build_string_i64_map.get (& built) dep-manifest-path)
        [(build_string_i64_map.LookupFound _)
          (build-package-deps-built? manifest-dir deps (+ index 1) built)]
        [(build_string_i64_map.LookupMissing) false]))))

(define (build-package-node-ready?
  [node : BuildPackageGraphNode]
  [built : build_string_i64_map.Map]) : bool
  (let
    [manifest-path : String node.manifest-path]
    [manifest-dir : String (load.compiler-load-dirname manifest-path)]
    [manifest : load.CompilerPkgManifest node.manifest]
    (build-package-deps-built?
      manifest-dir
      (load.compiler-pkg-deps-list manifest.deps)
      0
      built)))

(define (build-package-node-scheduled?
  [scheduled : build_string_i64_map.Map]
  [manifest-path : String]) : bool
  (match (build_string_i64_map.get (& scheduled) manifest-path)
    [(build_string_i64_map.LookupFound _) true]
    [(build_string_i64_map.LookupMissing) false]))

(define (build-package-graph-worker-vec-len [v : BuildPackageGraphWorkerVec]) : i64
  v.len)

(define (build-package-graph-worker-vec-capacity
  [v : BuildPackageGraphWorkerVec]) : i64
  (array-length v.slots))

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
  (array-ref v.slots index))

(define (build-package-graph-worker-vec-copy-range!
  [dst : (__tl_dyn-array BuildPackageGraphWorker)]
  [src : (__tl_dyn-array BuildPackageGraphWorker)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (build-package-graph-worker-vec-grow [v : BuildPackageGraphWorkerVec]) : BuildPackageGraphWorkerVec
  (let
    [count : i64 (build-package-graph-worker-vec-len v)]
    [bigger : (__tl_dyn-array BuildPackageGraphWorker)
      (make-array
        BuildPackageGraphWorker
        (* (build-package-graph-worker-vec-capacity v) 2))]
    (begin
      (build-package-graph-worker-vec-copy-range! bigger v.slots count)
      (BuildPackageGraphWorkerVec bigger count))))

(define (build-package-graph-worker-vec-push
  [v : BuildPackageGraphWorkerVec]
  [worker : BuildPackageGraphWorker]) : BuildPackageGraphWorkerVec
  (if (<
    (build-package-graph-worker-vec-len v)
    (build-package-graph-worker-vec-capacity v))
    (let
      [slots : (__tl_dyn-array BuildPackageGraphWorker) v.slots]
      (begin
        (set! (array-ref slots (build-package-graph-worker-vec-len v)) worker)
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
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]) : ResultBuildPackageGraphWorker
  (let
    [manifest-path : String node.manifest-path]
    [manifest : load.CompilerPkgManifest node.manifest]
    [name : String manifest.name]
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
  [scheduled : build_string_i64_map.Map (:consume)]
  [built : build_string_i64_map.Map]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
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
          [manifest-path : String node.manifest-path]
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
                      (build-string-index-map-put!
                        (&mut next-scheduled)
                        manifest-path
                        1)
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
          [manifest-path : String node.manifest-path]
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
  [built : build_string_i64_map.Map (:consume)]
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
          [node : BuildPackageGraphNode worker.node]
          [artifacts : BuildPackageArtifactPaths worker.artifacts]
          [manifest-path : String node.manifest-path]
          [manifest : load.CompilerPkgManifest node.manifest]
          [name : String manifest.name]
          [result : process.ResultProcessOutput (process.wait worker.child)]
          (begin
            (match result
              [(process.OkProcessOutput output)
                (begin
                  (if (or announce (not (process.success? output)))
                    (build_run_core.source-tool-forward-output output)
                    unit)
                  (if (process.success? output)
                    (let
                      [runtime-path : String artifacts.runtime]
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
                          [tlci-path : String artifacts.tlci]
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
                            (build-string-index-map-put!
                              (&mut next-built)
                              manifest-path
                              1)))))
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
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
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
          [workers : BuildPackageGraphWorkerVec pass.workers]
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
                  pass.scheduled
                  next-built)])))])))

(define (build-package-emit-graph-nodes-parallel
  [nodes : BuildPackageGraphNodeVec]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
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
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [producer-identity : String]
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
          [manifest-path : String node.manifest-path]
          [manifest : load.CompilerPkgManifest node.manifest]
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
              producer-identity
              announce)]
          (if (= node-status 0)
            (set! index (+ index 1))
            (begin
              (io.print-error
                (str_cat.str-cat
                  "build: package dependency `"
                  manifest.name
                  "` failed with status "
                  (string.int->string node-status)))
              (set! status node-status)))))
      status)))

(define (build-package-emit-graph-nodes
  [nodes : BuildPackageGraphNodeVec]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [producer-identity : String]
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
      producer-identity
      announce)))

(define (build-doctest-report [report : doc_test.DocTestRunReport]) : i64
  (if (doc_test.doc-test-run-report-ok? report)
    0
    (begin
      (io.print-error (doc_test.doc-test-run-report-render report))
      1)))

(define (build-doctest-typecheck-file
  [source : String]
  [stdlib-roots : cli_svec.Vec]) : i64
  (match (io.try-read-file (& source))
    [(io.ErrIoBytes _) 0]
    [(io.OkIoBytes contents)
      (build-doctest-report
        (doc_test.doc-test-typecheck-source-with-roots
          source
          (byte_buf.to-string contents)
          stdlib-roots))]))

(define (build-doctest-typecheck-package-paths
  [paths : ast.AstDeclPathList]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [deps : load.CompilerPkgDeps]) : i64
  (build-doctest-report
    (doc_test.doc-test-typecheck-package-paths-with-roots
      paths
      stdlib-roots
      manifest-dir
      deps)))

(define (build-doctest-build-source
  [source : String]
  [output : String]
  [has-output : bool]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : build_run_core.SourceToolLinkInputs]) : i64
  (let
    [doctest-status : i64 (build-doctest-typecheck-file source stdlib-roots)]
    (if (= doctest-status 0)
      (let
        [inline-test-status : i64
          (test_cli_core.tltest-inline-typecheck-file-with-cfg
            source
            stdlib-roots
            (compiler_driver_core.compiler-driver-target-cfgs
              target
              (compiler_parse_core.compiler-cfg-empty))
            "typecheck-prefix-inline-build")]
        (if (= inline-test-status 0)
          (begin
            (compiler_driver_core.compiler-driver-reset-file-state!)
            (build_run_core.source-tool-build-source
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
  [manifest : load.CompilerPkgManifest]
  [target-text : String]
  [_has-target : bool]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [producer-identity : String]
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
                  [nodes : BuildPackageGraphNodeVec graph.order]
                  [dep-status : i64
                    (build-package-emit-graph-nodes
                      nodes
                      target
                      opt-level
                      profile
                      mode
                      lock-policy
                      stdlib-roots
                      producer-identity
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
                      producer-identity
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
  [producer-identity : String]
  [announce : bool]) : i64
  (match (build_run_core.source-tool-backend-mode "build" mode)
    [(build_run_core.ResultSourceToolBackendMode.Err message)
      (begin
        (io.print-error message)
        1)]
    [(build_run_core.ResultSourceToolBackendMode.Ok backend-mode)
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
            producer-identity
            announce)])]))

(define (build-package-from-path
  [manifest-path : String]
  [target-text : String]
  [has-target : bool]
  [mode : String]
  [opt-level : i64]
  [profile : BuildProfile]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [producer-identity : String]) : i64
  (build-package-from-path-announce
    manifest-path
    target-text
    has-target
    mode
    opt-level
    profile
    lock-policy
    stdlib-roots
    producer-identity
    true))

(define (build-package [config : BuildConfig] [producer-identity : String]) : i64
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
        [resolved-manifest : load.CompilerLoadMaybePath
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
              stdlib-roots
              producer-identity)]))]
    [_ 1]))

(define (build-main-from [idx : i64] [producer-identity : String]) : i64
  (match (build-config-from idx (io.arg-count))
    [(ResultBuildConfig.Ok config)
      (match config
        [(BuildConfig.Source _ _ _ _ _ _ _ _)
          (begin
            (io.print-string (build-source-plan-render config))
            0)]
        [(BuildConfig.Package _ _ _ _ _ _ _ _ _ _)
          (build-package config producer-identity)])]
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
  (Debug)
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
  (cond
    [(string.eq current "-o") (BuildCliOption.Output)]
    [(or (string.eq current "--debug") (string.eq current "-g"))
      (BuildCliOption.Debug)]
    [else (build-cli-option-rest0 current)]))

(define (build-args-have-source? [idx : i64] [count : i64]) : bool
  (if (>= idx count)
    false
    (let
      [current : String (io.arg idx)]
      (match (build-cli-option current)
        [(BuildCliOption.Other)
          (if (build_run_core.source-tool-flag? current)
            (build-args-have-source? (+ idx 1) count)
            true)]
        [(BuildCliOption.Release) (build-args-have-source? (+ idx 1) count)]
        [(BuildCliOption.Locked) (build-args-have-source? (+ idx 1) count)]
        [(BuildCliOption.UpdateLock) (build-args-have-source? (+ idx 1) count)]
        [(BuildCliOption.Debug) (build-args-have-source? (+ idx 1) count)]
        [_ (build-args-have-source? (+ idx 2) count)]))))

(define (build-cli-parse-common-option
  [kind : cli_option.CliCommonOptionKind]
  [value : String]
  [next-idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [output : String]
  [has-output : bool]
  [target : backend.CompilerBackendTarget]
  [mode : backend.CompilerBackendMode]
  [stdlib-roots : cli_svec.Vec (:consume)]
  [opt-level : i64]
  [link-inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildCliConfig
  (match kind
    [(cli_option.CliCommonOptionKind.StdlibRoot)
      (build-cli-parse-options
        next-idx
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
            (cli_svec.push (&mut next-roots) value)
            next-roots))
        opt-level
        link-inputs)]
    [(cli_option.CliCommonOptionKind.Target)
      (match (build_run_core.source-tool-target value)
        [(build_run_core.ResultSourceToolTarget.Ok parsed-target)
          (build-cli-parse-options
            next-idx
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
        [(build_run_core.ResultSourceToolTarget.Err _)
          (ResultBuildCliConfig.Err (build-cli-unknown-target value))])]
    [(cli_option.CliCommonOptionKind.OptLevel)
      (if (build_run_core.source-tool-opt-level-valid? value)
        (build-cli-parse-options
          next-idx
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
        (ResultBuildCliConfig.Err (build-cli-unknown-opt-level value)))]
    [(cli_option.CliCommonOptionKind.Cfg)
      (ResultBuildCliConfig.Err "build: internal unsupported common option")]))

(define (build-cli-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [output : String]
  [has-output : bool]
  [target : backend.CompilerBackendTarget]
  [mode : backend.CompilerBackendMode]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [link-inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildCliConfig
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
      (match (cli_option.cli-common-option-parse
        current
        idx
        count
        cli_option.cli-common-option-build)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultBuildCliConfig.Err
            (cli_option.cli-common-option-missing-message "build" kind))]
        [(cli_option.CliCommonOption.Value kind value next-idx)
          (build-cli-parse-common-option
            kind
            value
            next-idx
            count
            source
            has-source
            output
            has-output
            target
            mode
            stdlib-roots
            opt-level
            link-inputs)]
        [(cli_option.CliCommonOption.NotCommon)
          (match (build-cli-option current)
            [(BuildCliOption.Debug)
              (begin
                (ir.compiler-debug-info-set-enabled! true)
                (build-cli-parse-options
                  (+ idx 1)
                  count
                  source
                  has-source
                  output
                  has-output
                  target
                  mode
                  stdlib-roots
                  opt-level
                  link-inputs))]
            [(BuildCliOption.Output)
              (if (>= (+ idx 1) count)
                (ResultBuildCliConfig.Err "build: -o requires a value")
                (if has-output
                  (ResultBuildCliConfig.Err
                    "build: -o was provided more than once")
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
              (ResultBuildCliConfig.Err
                "build: internal common option dispatch")]
            [(BuildCliOption.Target)
              (ResultBuildCliConfig.Err
                "build: internal common option dispatch")]
            [(BuildCliOption.OptLevel)
              (ResultBuildCliConfig.Err
                "build: internal common option dispatch")]
            [(BuildCliOption.BackendMode)
              (if (>= (+ idx 1) count)
                (ResultBuildCliConfig.Err
                  "build: --backend-mode requires a value")
                (let
                  [value : String (io.arg (+ idx 1))]
                  (match (build_run_core.source-tool-backend-mode "build" value)
                    [(build_run_core.ResultSourceToolBackendMode.Ok parsed-mode)
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
                    [(build_run_core.ResultSourceToolBackendMode.Err message)
                      (ResultBuildCliConfig.Err message)])))]
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
                  (build_run_core.source-tool-link-inputs-add-lib
                    link-inputs
                    (io.arg (+ idx 1)))))]
            [(BuildCliOption.LinkSearch)
              (if (>= (+ idx 1) count)
                (ResultBuildCliConfig.Err
                  "build: --link-search requires a value")
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
                  (build_run_core.source-tool-link-inputs-add-search-dir
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
                  (build_run_core.source-tool-link-inputs-add-raw-arg
                    link-inputs
                    (io.arg (+ idx 1)))))]
            [(BuildCliOption.ManifestPath)
              (if (>= (+ idx 1) count)
                (ResultBuildCliConfig.Err
                  "build: --manifest-path requires a value")
                (ResultBuildCliConfig.Err
                  "build: --manifest-path is handled by Rust typelisp build; selfhost build tool expects a source file"))]
            [(BuildCliOption.Other)
              (if (build_run_core.source-tool-flag? current)
                (ResultBuildCliConfig.Err
                  (str_cat.str-cat "build: unknown flag " current))
                (if has-source
                  (ResultBuildCliConfig.Err
                    "build: accepts only one source file")
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
                    link-inputs)))])]))))

(define (build-cli-config-from [idx : i64] [count : i64]) : ResultBuildCliConfig
  (build-cli-parse-options
    idx
    count
    ""
    false
    ""
    false
    (build_run_core.source-tool-default-target)
    (backend.CompilerBackendMode.Scalar)
    (cli_svec.new)
    (opt.compiler-optimize-default-level)
    (build_run_core.source-tool-link-inputs-empty)))

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

(define (build-direct-from
  [start : i64]
  [count : i64]
  [producer-identity : String]) : i64
  (if (or
    (build-args-contain-manifest? start count)
    (not (build-args-have-source? start count)))
    (build-main-from start producer-identity)
    (build-source-direct-from start count)))

;; Run the `build` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name). `--direct` remains accepted as a
;; compatibility no-op; the bare form also builds in-process.
(define (build-run-from
  [start : i64]
  [count : i64]
  [producer-identity : String]) : i64
  (begin
    (ir.compiler-debug-info-set-enabled! false)
    (cond
      [(and (> count start) (string.eq (io.arg start) "--package-worker"))
        (build-package-worker-run-from (+ start 1) count producer-identity)]
      [(and
          (> count start)
          (string.eq (io.arg start) "--package-doctest-worker"))
        (build-package-doctest-worker-run-from (+ start 1) count)]
      [(and (> count start) (string.eq (io.arg start) "--direct"))
        (build-direct-from (+ start 1) count producer-identity)]
      [else (build-direct-from start count producer-identity)])))