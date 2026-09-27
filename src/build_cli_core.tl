;; build_cli_core.tl - Selfhost build command logic.
;;
;; Source-file builds assemble and link in-process through stdlib fs/process
;; helpers. Package builds are handled in-process by the selfhost compiler:
;; parse/discover `typelisp.pkg`, emit assembly for the manifest entry, and
;; produce the package artifact selected by manifest kind.
(import compiler_owned_view as owned_view)
(import stdlib.fs)
(import stdlib.arena)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_cfg_core as cfg_core))
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
(import compiler_dependency_tlci)
(import tlci_core as tlci)
(import compiler_tlci_native_producer)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_package_surface_producer as package_surface))
(import sym_i64_env)

;; The package-build parser's result. `Source` only records that a source-file
;; argument was seen: `build` sends source files to `build-cli-config-from`,
;; and `run` rejects a source that follows run options.
(defenum BuildConfig
  (Source)
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

;; Complete outputs from one runtime preparation. Artifact finishing has no
;; AST inputs and cannot regenerate assembly or invoke the compiler again.
(defenum ResultBuildPackagePreparedRuntime
  (DirectObject String String)
  (Assembly String backend.CompilerDirectObjectFallbackReason)
  (Err String))

(defstruct BuildPackageDirectObjectRequest
  (name String)
  (kind load.CompilerPkgKind)
  (target backend.CompilerBackendTarget)
  (opt-level i64)
  (mode backend.CompilerBackendMode)
  (debug-info bool)
  (path-budget i64)
  (linux-budget-override bool)
  (require-direct-object bool)
  (emit-entry bool)
  (crt-entry bool)
  (decls ast.AstDeclList)
  (paths ast.AstDeclPathList)
  ;; The job's cfg environment: generated declarations are reparsed with it
  ;; while this request is lowered (#7812).
  (cfgs sym_i64_env.SymI64Env))

(define (build-package-direct-object-default-request
  [name : String]
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [cfgs : sym_i64_env.SymI64Env]) : BuildPackageDirectObjectRequest
  (BuildPackageDirectObjectRequest
    name
    kind
    target
    opt-level
    mode
    (ir.compiler-debug-info-enabled?)
    (build-package-direct-object-owned-path-budget)
    (build_run_core.source-tool-linux-direct-object-enabled?)
    false
    emit-entry
    crt-entry
    decls
    paths
    cfgs))

(defenum ResultBuildManifest
  (Ok load.CompilerPkgManifest)
  (Err String))

(defstruct BuildPackageCompileContext
  (root-compiler bool)
  (error String))

(defenum BuildPackageSourceProvenance
  (Local)
  ;; Declared dependency alias followed by its locked physical checkout root.
  (Fetched String String))

(defstruct BuildPackageGraphNode
  (manifest-path String)
  (manifest load.CompilerPkgManifest)
  (provenance BuildPackageSourceProvenance))

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

;; Rollback records every previous artifact it attempted to restore. Retained
;; entries are cleanup capabilities: their `.previous` path must remain owned
;; by the recovery stage until the user has restored it.
(defenum BuildPackageBackupRollback
  (Restored String String)
  (Retained String String String))

(defstruct BuildPackageRollbackDisposition
  (backups (__tl_dyn-array BuildPackageBackupRollback))
  (len i64)
  (errors String))

(defenum ResultBuildPackageCommit
  (Ok)
  (Err String BuildPackageRollbackDisposition))

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
  (has-lock bool)
  (original-source String))

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
  (:cleanup cleanup-build-package-graph-worker)
  (node BuildPackageGraphNode)
  (artifacts BuildPackageArtifactPaths)
  (child process.ProcessChild (:owned)))

(defenum ResultBuildPackageGraphWorker
  (:cleanup cleanup-result-build-package-graph-worker)
  (Ok BuildPackageGraphWorker (:owned))
  (Err String))

(defenum BuildPackageGraphWorkerList
  (:cleanup cleanup-build-package-graph-worker-list)
  (Empty)
  (More
    BuildPackageGraphWorker
    (:owned)
    (Box BuildPackageGraphWorkerList)
    (:cleanup cleanup-build-package-graph-worker-list-tail)))

(define (cleanup-build-package-graph-worker-list-tail
  [tail : (Box BuildPackageGraphWorkerList)]) : unit
  (cleanup-build-package-graph-worker-list (deref tail)))

(defstruct BuildPackageSchedulePass
  (:cleanup cleanup-build-package-schedule-pass)
  (scheduled build_string_i64_map.Map)
  (workers BuildPackageGraphWorkerList (:owned)))

(defenum ResultBuildPackageSchedulePass
  (:cleanup cleanup-result-build-package-schedule-pass)
  (Ok BuildPackageSchedulePass (:owned))
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
(define build-package-commit-file-capacity : i64
  5)
(define build-status-ok : i64
  0)
(define build-status-already-exists : i64
  17)

(define (build-string-index-map-put
  [map : build_string_i64_map.Map]
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

(define (build-parse-target [value : String]) : ResultBuildTarget
  (if (or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
    (ResultBuildTarget.Ok (backend.CompilerBackendTarget.Linux))
    (if (or
      (string.eq value "windows-x86_64")
      (string.eq value "windows_x86_64"))
      (ResultBuildTarget.Ok (backend.CompilerBackendTarget.Windows))
      (ResultBuildTarget.Err (build-unknown-target value)))))

;; Options a package build accepts.
(define (build-package-cli-options) : String
  "--stdlib-root <dir> --target <target> --opt-level <0|1|2>
   --debug|-g|--backtrace -o <exe> --manifest-path <file> --backend-mode <mode>
   --profile <dev|release> --release --locked --update-lock")

(define (build-config-from [idx : i64] [count : i64]) : ResultBuildConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args "build" (build-package-cli-options) idx count)]
    [has-source : bool false]
    [has-output : bool false]
    [manifest : String ""]
    [has-manifest : bool false]
    [target : String (build_run_core.source-tool-default-target-name)]
    [has-target : bool false]
    [mode : String "scalar"]
    [profile : BuildProfile (build-default-profile)]
    [has-profile : bool false]
    [opt-level : i64 (build-package-default-opt-level)]
    [has-opt-level : bool false]
    [lock-policy : BuildPackageLockPolicy (BuildPackageLockPolicy.Default)]
    [stdlib-roots : cli_svec.Vec (cli_svec.new)]
    (begin
      (while (cli_option.cli-args-next! (&mut args))
        (cond
          [(string.eq args.name "--stdlib-root")
            (cli_svec.push-ref!
              (&mut stdlib-roots)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "--target")
            (let
              [value : String (cli_option.cli-args-value (& args))]
              (match (build-parse-target (string.copy (& value)))
                [(ResultBuildTarget.Ok _)
                  (begin
                    (set! target value)
                    (set! has-target true))]
                [(ResultBuildTarget.Err _)
                  (cli_option.cli-args-fail!
                    (&mut args)
                    (build-unknown-target value))]))]
          [(string.eq args.name "--opt-level")
            (let
              [value : String (cli_option.cli-args-value (& args))]
              [level : i64 (cli_option.cli-option-opt-level (& value))]
              (cond
                [has-opt-level
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "build: --opt-level was provided more than once")]
                [(< level 0)
                  (cli_option.cli-args-fail!
                    (&mut args)
                    (build-unknown-opt-level value))]
                [else
                  (begin
                    (set! opt-level level)
                    (set! has-opt-level true))]))]
          [(string.eq args.name "--debug")
            (ir.compiler-debug-info-set-enabled! true)]
          [(string.eq args.name "-o")
            (if has-output
              (cli_option.cli-args-fail!
                (&mut args)
                "build: -o was provided more than once")
              (set! has-output true))]
          [(string.eq args.name "--manifest-path")
            (if has-manifest
              (cli_option.cli-args-fail!
                (&mut args)
                "build: --manifest-path was provided more than once")
              (begin
                (set! manifest (cli_option.cli-args-value (& args)))
                (set! has-manifest true)))]
          [(string.eq args.name "--backend-mode")
            (let
              [value : String (cli_option.cli-args-value (& args))]
              (match (build_run_core.source-tool-backend-mode
                "build"
                (string.copy (& value)))
                [(build_run_core.ResultSourceToolBackendMode.Ok _)
                  (set! mode value)]
                [(build_run_core.ResultSourceToolBackendMode.Err _)
                  (cli_option.cli-args-fail!
                    (&mut args)
                    (build-unknown-mode value))]))]
          [(and
              has-profile
              (or
                (string.eq args.name "--profile")
                (string.eq args.name "--release")))
            (cli_option.cli-args-fail!
              (&mut args)
              "build: profile was provided more than once")]
          [(string.eq args.name "--profile")
            (match (build-parse-profile (cli_option.cli-args-value (& args)))
              [(ResultBuildProfile.Err message)
                (cli_option.cli-args-fail! (&mut args) message)]
              [(ResultBuildProfile.Ok parsed-profile)
                (begin
                  (set! profile parsed-profile)
                  (set! has-profile true))])]
          [(string.eq args.name "--release")
            (begin
              (set! profile (BuildProfile.Release))
              (set! has-profile true))]
          [(or
              (string.eq args.name "--locked")
              (string.eq args.name "--update-lock"))
            (if (build-package-lock-policy-provided? lock-policy)
              (cli_option.cli-args-fail!
                (&mut args)
                (build-package-lock-policy-option-error))
              (set!
                lock-policy
                (if (string.eq args.name "--locked")
                  (BuildPackageLockPolicy.Locked)
                  (BuildPackageLockPolicy.Update))))]
          [(cli_option.cli-flag? args.arg)
            (cli_option.cli-args-fail-arg! (&mut args) "build: unknown flag ")]
          [has-source
            (cli_option.cli-args-fail!
              (&mut args)
              "build: accepts only one source file")]
          [else (set! has-source true)]))
      (cond
        [args.failed (ResultBuildConfig.Err args.error)]
        [(and has-source has-manifest)
          (ResultBuildConfig.Err
            "build: cannot combine a source file with --manifest-path")]
        [has-source (ResultBuildConfig.Ok (BuildConfig.Source))]
        [has-output
          (ResultBuildConfig.Err "build: -o requires a source file argument")]
        [else
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
              stdlib-roots))]))))

;; Parse the private `--package-worker` / `--package-doctest-worker` protocol.
(define (build-package-worker-config-from [idx : i64] [count : i64]) : ResultBuildPackageWorkerConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "build"
        "--stdlib-root <dir> --target <target> --opt-level <0|1|2>
         --debug|-g|--backtrace --manifest-path <file> --backend-mode <mode>
         --profile <dev|release> --release --locked --update-lock --resolved-dep"
        idx
        count)]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [target : backend.CompilerBackendTarget
      (build_run_core.source-tool-default-target)]
    [mode : backend.CompilerBackendMode (backend.CompilerBackendMode.Scalar)]
    [profile : BuildProfile (build-default-profile)]
    [opt-level : i64 (build-package-default-opt-level)]
    [has-opt-level : bool false]
    [lock-policy : BuildPackageLockPolicy (BuildPackageLockPolicy.Default)]
    [stdlib-roots : cli_svec.Vec (cli_svec.new)]
    [resolved-deps : load.CompilerPkgDepList (load.compiler-pkg-dep-list-empty)]
    (begin
      (while (cli_option.cli-args-next! (&mut args))
        (cond
          [(string.eq args.name "--stdlib-root")
            (cli_svec.push-ref!
              (&mut stdlib-roots)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "--target")
            (let
              [value : String (cli_option.cli-args-value (& args))]
              (match (build_run_core.source-tool-target (string.copy (& value)))
                [(build_run_core.ResultSourceToolTarget.Ok parsed-target)
                  (set! target parsed-target)]
                [(build_run_core.ResultSourceToolTarget.Err _)
                  (cli_option.cli-args-fail!
                    (&mut args)
                    (build-cli-unknown-target value))]))]
          [(string.eq args.name "--opt-level")
            (let
              [value : String (cli_option.cli-args-value (& args))]
              [level : i64 (cli_option.cli-option-opt-level (& value))]
              (if (< level 0)
                (cli_option.cli-args-fail!
                  (&mut args)
                  (build-unknown-opt-level value))
                (begin
                  (set! opt-level level)
                  (set! has-opt-level true))))]
          [(string.eq args.name "--debug")
            (ir.compiler-debug-info-set-enabled! true)]
          [(string.eq args.name "--manifest-path")
            (begin
              (set! manifest-path (cli_option.cli-args-value (& args)))
              (set! has-manifest true))]
          [(string.eq args.name "--backend-mode")
            (match (build_run_core.source-tool-backend-mode
              "build"
              (cli_option.cli-args-value (& args)))
              [(build_run_core.ResultSourceToolBackendMode.Ok parsed-mode)
                (set! mode parsed-mode)]
              [(build_run_core.ResultSourceToolBackendMode.Err message)
                (cli_option.cli-args-fail! (&mut args) message)])]
          ;; A profile also selects its default opt level unless --opt-level
          ;; already chose one.
          [(string.eq args.name "--profile")
            (match (build-parse-profile (cli_option.cli-args-value (& args)))
              [(ResultBuildProfile.Err message)
                (cli_option.cli-args-fail! (&mut args) message)]
              [(ResultBuildProfile.Ok parsed-profile)
                (begin
                  (unless
                    has-opt-level
                    (set!
                      opt-level
                      (build-profile-default-opt-level parsed-profile)))
                  (set! profile parsed-profile))])]
          [(string.eq args.name "--release")
            (begin
              (unless
                has-opt-level
                (set!
                  opt-level
                  (build-profile-default-opt-level (BuildProfile.Release))))
              (set! profile (BuildProfile.Release)))]
          [(or
              (string.eq args.name "--locked")
              (string.eq args.name "--update-lock"))
            (if (build-package-lock-policy-provided? lock-policy)
              (cli_option.cli-args-fail!
                (&mut args)
                (build-package-lock-policy-option-error))
              (set!
                lock-policy
                (if (string.eq args.name "--locked")
                  (BuildPackageLockPolicy.Locked)
                  (BuildPackageLockPolicy.Update))))]
          ;; Takes an alias and a path, with its own missing-value wording.
          [(string.eq args.name "--resolved-dep")
            (if (>= (+ args.index 2) count)
              (cli_option.cli-args-fail!
                (&mut args)
                "build: --resolved-dep requires alias and path")
              (begin
                (set!
                  resolved-deps
                  (load.compiler-pkg-dep-list-push
                    resolved-deps
                    (load.CompilerPkgDep
                      (cli_option.cli-args-value-at (& args) 1)
                      (cli_option.cli-args-value-at (& args) 2))))
                (set! args.next (+ args.index 3))))]
          [(cli_option.cli-flag? args.arg)
            (cli_option.cli-args-fail-arg!
              (&mut args)
              "build: unknown package worker flag ")]
          [else
            (cli_option.cli-args-fail-arg!
              (&mut args)
              "build: unexpected package worker argument ")]))
      (cond
        [args.failed (ResultBuildPackageWorkerConfig.Err args.error)]
        [has-manifest
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
              resolved-deps))]
        [else
          (ResultBuildPackageWorkerConfig.Err
            "build: --package-worker requires --manifest-path")]))))

(define (build-discover-manifest-up [prefix : String] [fuel : i64]) : load.CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view prefix)
          "typelisp.pkg")]
      (if (io.file-exists? (owned_view.compiler-owned-shared-view candidate))
        (CompilerLoadSomePath candidate)
        (build-discover-manifest-up (str_cat.str-cat prefix "../") (- fuel 1))))))

(define (build-load-manifest [manifest-path : String]) : ResultBuildManifest
  (if (io.file-exists? (owned_view.compiler-owned-shared-view manifest-path))
    (match (load.compiler-load-parse-manifest-diagnostic-infer-kind
      (owned_view.compiler-owned-shared-view manifest-path)
      (byte_buf.to-string (io.read-file manifest-path)))
      [(load.ResultCompilerPkgManifestDiagnostic.Ok manifest)
        (ResultBuildManifest.Ok manifest)]
      [(load.ResultCompilerPkgManifestDiagnostic.Err diag)
        (ResultBuildManifest.Err (build-invalid-manifest-message (deref diag)))])
    (ResultBuildManifest.Err
      (str_cat.str-cat "cannot read package manifest '" manifest-path "'"))))

(define (build-package-output-dir [manifest-dir : String] [name : (& name str)]) : String
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
    (build-package-artifact-path-profile
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view name)
      kind
      profile
      target)
    (build-package-tlci-path-profile manifest-dir name profile)))

(define (build-package-runtime-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  artifacts.runtime)

(define (build-package-host-tlci-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  artifacts.tlci)

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

(define (build-package-dep-provenance
  [manifest-dir : String]
  [declared : load.CompilerPkgDep]
  [resolved : load.CompilerPkgDep]) : BuildPackageSourceProvenance
  (if (load.compiler-load-github-dependency-path? (string.copy declared.path))
    (BuildPackageSourceProvenance.Fetched
      declared.alias
      (build-package-dep-root manifest-dir resolved))
    (BuildPackageSourceProvenance.Local)))

(define (build-package-validate-fetched-checkout-before-manifest
  [provenance : BuildPackageSourceProvenance]) : ResultBuildString
  (match provenance
    [(BuildPackageSourceProvenance.Local) (ResultBuildString.Ok "")]
    [(BuildPackageSourceProvenance.Fetched alias checkout-root)
      (match (package_source_core.package-source-confined-existing-file
        alias
        "manifest"
        "typelisp.pkg"
        checkout-root)
        [(package_source_core.ResultPackageSourceConfinedPath.Err message)
          (ResultBuildString.Err message)]
        [(package_source_core.ResultPackageSourceConfinedPath.Ok _)
          (ResultBuildString.Ok "")])]))

(define (build-package-validate-fetched-checkout
  [provenance : BuildPackageSourceProvenance]
  [manifest : load.CompilerPkgManifest]) : ResultBuildString
  (match provenance
    [(BuildPackageSourceProvenance.Local) (ResultBuildString.Ok "")]
    [(BuildPackageSourceProvenance.Fetched _ checkout-root)
      (match (package_source_core.package-source-confined-existing-file
        (owned_view.compiler-owned-shared-view manifest.name)
        "entry"
        manifest.entry
        (owned_view.compiler-owned-shared-view checkout-root))
        [(package_source_core.ResultPackageSourceConfinedPath.Err message)
          (ResultBuildString.Err message)]
        [(package_source_core.ResultPackageSourceConfinedPath.Ok _)
          (match (package_source_core.package-source-fetched-checkout-audit
            manifest.name
            checkout-root)
            [(package_source_core.ResultPackageSourceConfinedPath.Err message)
              (ResultBuildString.Err message)]
            [(package_source_core.ResultPackageSourceConfinedPath.Ok _)
              (ResultBuildString.Ok "")])])]))

(define (build-package-validate-graph-node-checkout
  [node : BuildPackageGraphNode]) : ResultBuildString
  (build-package-validate-fetched-checkout node.provenance node.manifest))

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
    (match (package_lock_core.package-lock-transaction-read (string.copy path))
      [(package_lock_core.ResultPackageLockSnapshot.Err message)
        (ResultBuildPackageLockState.Err (str_cat.str-cat "build: " message))]
      [(package_lock_core.ResultPackageLockSnapshot.Ok snapshot)
        (if snapshot.existed
          (match (package_lock_core.package-lock-parse
            (string.copy snapshot.source))
            [(package_lock_core.ResultPackageLockFile.Err message)
              (ResultBuildPackageLockState.Err
                (str_cat.str-cat
                  "build: invalid package lock '"
                  path
                  "': "
                  message))]
            [(package_lock_core.ResultPackageLockFile.Ok lock)
              (ResultBuildPackageLockState.Ok
                (BuildPackageLockState path lock.entries true snapshot.source))])
          (ResultBuildPackageLockState.Ok
            (BuildPackageLockState path (package_lock_entry_vec.new) false "")))])))

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
    [snapshot : package_lock_core.PackageLockSnapshot
      (package_lock_core.PackageLockSnapshot
        (string.copy path)
        state.original-source
        state.has-lock)]
    (match (package_lock_core.package-lock-transaction-commit snapshot text)
      [(package_lock_core.ResultPackageLockCommit.Ok _)
        (ResultBuildString.Ok path)]
      [(package_lock_core.ResultPackageLockCommit.Err message)
        (ResultBuildString.Err (str_cat.str-cat "build: " message))])))

(define (build-package-lock-entry-matches?
  [entry : package_lock_core.PackageLockEntry]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : bool
  (match (build-git-dep-pin-kind
    (owned_view.compiler-owned-shared-view alias)
    dep)
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
      (if (build-package-lock-entry-matches?
        (owned_view.compiler-owned-shared-view entry)
        alias
        dep)
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
      (if (build-package-lock-entry-matches?
        (owned_view.compiler-owned-shared-view entry)
        alias
        dep)
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
  (match (build-git-dep-pin-kind
    (owned_view.compiler-owned-shared-view alias)
    dep)
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
  [manifest-dir : (& manifest-dir str)]
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
  (str_cat.str-cat-scoped entry-path "/typelisp.pkg"))

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
  [root : (& root str)]
  [key : (& key package_cache_core.PackageCacheKey)]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 16)
    (ResultBuildString.Err
      (build-git-dep-error alias "package cache has no free staging path"))
    (let
      [staged : String
        (package_cache_core.package-cache-staging-path root key attempt)]
      (if (io.file-exists? (owned_view.compiler-owned-shared-view staged))
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
        (build-package-cache-conflict-backup-path
          (owned_view.compiler-owned-shared-view entry-path)
          attempt)]
      (if (io.file-exists? (owned_view.compiler-owned-shared-view backup))
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
  (if (io.file-exists? (owned_view.compiler-owned-shared-view entry-path))
    (build-package-cache-move-conflict-attempt alias entry-path 1)
    (ResultBuildString.Ok entry-path)))

(define (build-package-cache-hit-result
  [alias : String]
  [entry-path : (& entry-path str)]
  [relative-entry-root : String]) : ResultBuildString
  (if (io.file-exists? (build-package-cache-manifest-path entry-path))
    (ResultBuildString.Ok relative-entry-root)
    (ResultBuildString.Err
      (build-git-dep-error alias "cached package is missing typelisp.pkg"))))

(define (build-package-cache-finalize-staged
  [alias : String]
  [staged-path : String]
  [entry-path : (& entry-path str)]
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
      (match (build-package-cache-staging-path
        (owned_view.compiler-owned-shared-view alias)
        root
        key
        1)
        [(ResultBuildString.Err message) (ResultBuildString.Err message)]
        [(ResultBuildString.Ok staged-path)
          (match (build-run-captured
            (build-git-dep-error alias "git clone")
            (build-git-clone-command
              (string.copy (& dep.remote))
              (owned_view.compiler-owned-shared-view staged-path)))
            [(ResultBuildString.Err message) (ResultBuildString.Err message)]
            [(ResultBuildString.Ok _)
              (match (build-run-captured
                (build-git-dep-error alias "git checkout")
                (build-git-checkout-command
                  (owned_view.compiler-owned-shared-view staged-path)
                  (build-git-checkout-ref dep)))
                [(ResultBuildString.Err message)
                  (ResultBuildString.Err message)]
                [(ResultBuildString.Ok _)
                  (match (build-run-captured
                    (build-git-dep-error alias "git rev-parse")
                    (build-git-rev-parse-command
                      (owned_view.compiler-owned-shared-view staged-path)))
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
                          (owned_view.compiler-owned-shared-view alias)
                          (owned_view.compiler-owned-shared-view staged-path)
                          key)
                          [(ResultBuildString.Err message)
                            (ResultBuildString.Err message)]
                          [(ResultBuildString.Ok _)
                            (match (build-package-cache-prepare-entry-parents-result
                              (owned_view.compiler-owned-shared-view alias)
                              root
                              key)
                              [(ResultBuildString.Err message)
                                (ResultBuildString.Err message)]
                              [(ResultBuildString.Ok _)
                                (match (if replace-existing
                                  (build-package-cache-move-conflict
                                    (owned_view.compiler-owned-shared-view
                                      alias)
                                    (owned_view.compiler-owned-shared-view
                                      entry-path))
                                  (ResultBuildString.Ok
                                    (owned_view.compiler-owned-shared-view
                                      entry-path)))
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
          (match (build-ensure-package-cache-root
            manifest-dir
            (owned_view.compiler-owned-shared-view alias))
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
        (match (build-ensure-package-cache-root
          manifest-dir
          (owned_view.compiler-owned-shared-view alias))
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
        (match (build-ensure-package-cache-root
          manifest-dir
          (owned_view.compiler-owned-shared-view alias))
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
  (if (io.file-exists?
    (build-github-cache-git-dir
      manifest-dir
      (owned_view.compiler-owned-shared-view alias)))
    (ResultBuildString.Ok root)
    (build-run-captured
      (build-git-dep-error alias "git clone")
      (build-git-clone-command (string.copy (& dep.remote)) root))))

(define (build-fetch-github-dependency-legacy
  [manifest-dir : String]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : ResultBuildString
  (let
    [root : String
      (build-github-dep-cache-root
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view alias))]
    [manifest-path : String
      (build-github-dep-cache-manifest-path
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view alias))]
    (if (not
      (build-github-cache-needs-git?
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view alias)))
      (ResultBuildString.Ok manifest-path)
      (match (build-ensure-github-cache-parent
        manifest-dir
        (owned_view.compiler-owned-shared-view alias))
        [(ResultBuildString.Err message) (ResultBuildString.Err message)]
        [(ResultBuildString.Ok _)
          (match (build-git-clone-if-needed
            manifest-dir
            (owned_view.compiler-owned-shared-view alias)
            dep
            (owned_view.compiler-owned-shared-view root))
            [(ResultBuildString.Err message) (ResultBuildString.Err message)]
            [(ResultBuildString.Ok _)
              (match (build-run-captured
                (build-git-dep-error alias "git checkout")
                (build-git-checkout-command
                  (owned_view.compiler-owned-shared-view root)
                  (build-git-checkout-ref dep)))
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
  (if (not
    (build-github-cache-needs-git?
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view alias)))
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
    [locked-commit : String
      (owned_view.compiler-owned-shared-view entry.commit)]
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
  (match (build-fetch-github-dependency
    (owned_view.compiler-owned-shared-view manifest-dir)
    (owned_view.compiler-owned-shared-view alias)
    (& dep))
    [(ResultBuildString.Err message)
      (ResultBuildResolvedGitDependency.Err message)]
    [(ResultBuildString.Ok dep-root)
      (let
        [commit-result : ResultBuildString
          (if (build-git-dep-rev? (& dep))
            (ResultBuildString.Ok (string.copy (& dep.pin-value)))
            (build-resolve-git-head
              (owned_view.compiler-owned-shared-view alias)
              (build-absolute-dep-root
                manifest-dir
                (owned_view.compiler-owned-shared-view dep-root))))]
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
      (match (build-package-lock-entry-status
        lock-entries
        (owned_view.compiler-owned-shared-view alias)
        (& dep))
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
      (match (build-package-lock-matching-entry
        lock-entries
        (owned_view.compiler-owned-shared-view alias)
        (& dep))
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
              (owned_view.compiler-owned-shared-view alias)
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
  [entries : (& entries package_lock_entry_vec.Vec)]
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
  [needles : (& needles package_lock_entry_vec.Vec)]) : bool
  (build-package-lock-list-contains-all-from haystack (& needles) 0))

(define (build-package-lock-list-contains-all-from
  [haystack : (& haystack package_lock_entry_vec.Vec)]
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
  [right : (& right package_lock_entry_vec.Vec)]) : bool
  (and
    (=
      (package_lock_entry_vec.len (& left))
      (package_lock_entry_vec.len (& right)))
    (build-package-lock-list-contains-all? left right)))

(define (build-package-lock-policy-check
  [policy : BuildPackageLockPolicy]
  [lock-state : BuildPackageLockState]
  [resolved : (& resolved BuildResolvedPkgDeps)]) : ResultBuildString
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
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view lock-entries)
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
              (owned_view.compiler-owned-shared-view resolved-dep.lock-entry))
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
  (match manifest.kind
    [(CompilerPkgKindLib)
      ;; Libraries have no normal dependency resolution or lock contract.
      ;; Validate again here so a future acquired/binary manifest format cannot
      ;; bypass source-manifest validation and trigger a nested fetch.
      (match (load.compiler-pkg-manifest-first-library-dependency (& manifest))
        [(load.CompilerPkgMaybeDependency.NoDependency)
          (ResultBuildManifest.Ok manifest)]
        [(load.CompilerPkgMaybeDependency.Dependency dep)
          (ResultBuildManifest.Err
            (str_cat.str-cat
              "build: "
              (load.compiler-pkg-library-dependency-message
                manifest.name
                dep.alias)))])]
    [(CompilerPkgKindBin)
      (let
        [manifest-dir : String (load.compiler-load-dirname manifest-path)]
        (match (build-load-package-lock
          (owned_view.compiler-owned-shared-view manifest-dir))
          [(ResultBuildPackageLockState.Err message)
            (ResultBuildManifest.Err message)]
          [(ResultBuildPackageLockState.Ok lock-state)
            (match (build-package-resolve-deps-with-lock
              manifest-dir
              (owned_view.compiler-owned-shared-view lock-state.entries)
              lock-policy
              (load.compiler-pkg-deps-list manifest.deps)
              0)
              [(ResultBuildResolvedPkgDeps.Err message)
                (ResultBuildManifest.Err message)]
              [(ResultBuildResolvedPkgDeps.Ok resolved)
                (match (build-package-lock-policy-check
                  lock-policy
                  (owned_view.compiler-owned-shared-view lock-state)
                  resolved)
                  [(ResultBuildString.Err message)
                    (ResultBuildManifest.Err message)]
                  [(ResultBuildString.Ok _)
                    (match (build-package-maybe-write-lock
                      lock-policy
                      lock-state
                      (owned_view.compiler-owned-shared-view resolved))
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
                            manifest.link))])])])]))]))

(define (build-package-normalize-manifest-path [manifest-path : String]) : String
  (load.compiler-load-normalize-path manifest-path))

(define (build-package-graph-node-vec-len [v : (& v BuildPackageGraphNodeVec)]) : i64
  v.len)

(define (build-package-graph-node-vec-capacity
  [v : (& v BuildPackageGraphNodeVec)]) : i64
  (array-length v.slots))

(define (build-package-graph-node-vec-with-capacity [capacity : i64]) : BuildPackageGraphNodeVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (BuildPackageGraphNodeVec (__tl_make-array BuildPackageGraphNode cap) 0)))

(define (build-package-graph-node-vec-new) : BuildPackageGraphNodeVec
  (build-package-graph-node-vec-with-capacity 4))

(define (build-package-graph-node-vec-at
  [v : BuildPackageGraphNodeVec]
  [index : i64]) : BuildPackageGraphNode
  (array-ref v.slots index))

(define (build-package-graph-node-vec-copy-range!
  [dst : (&mut dst (__tl_dyn-array BuildPackageGraphNode))]
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
      (__tl_make-array
        BuildPackageGraphNode
        (* (build-package-graph-node-vec-capacity v) 2))]
    (begin
      (build-package-graph-node-vec-copy-range! (&mut bigger) v.slots count)
      (BuildPackageGraphNodeVec bigger count))))

(define (build-package-graph-node-vec-push
  [v : BuildPackageGraphNodeVec]
  [node : BuildPackageGraphNode]) : BuildPackageGraphNodeVec
  (if (<
    (build-package-graph-node-vec-len v)
    (build-package-graph-node-vec-capacity v))
    (let
      [slots : (__tl_dyn-array BuildPackageGraphNode)
        (owned_view.compiler-owned-shared-view v.slots)]
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
  [declared-dep : load.CompilerPkgDep]
  [resolved-dep : load.CompilerPkgDep]) : ResultBuildPackageGraphNode
  (let
    [provenance : BuildPackageSourceProvenance
      (build-package-dep-provenance
        (owned_view.compiler-owned-shared-view manifest-dir)
        declared-dep
        (owned_view.compiler-owned-shared-view resolved-dep))]
    [dep-manifest-path : String
      (build-package-dep-manifest-path
        manifest-dir
        (owned_view.compiler-owned-shared-view resolved-dep))]
    (match (build-package-validate-fetched-checkout-before-manifest
      (owned_view.compiler-owned-shared-view provenance))
      [(ResultBuildString.Err message)
        (ResultBuildPackageGraphNode.Err message)]
      [(ResultBuildString.Ok _)
        (match (build-load-manifest
          (owned_view.compiler-owned-shared-view dep-manifest-path))
          [(ResultBuildManifest.Err message)
            (ResultBuildPackageGraphNode.Err
              (str_cat.str-cat "dependency `" resolved-dep.alias "`: " message))]
          [(ResultBuildManifest.Ok dep-manifest)
            (match (build-package-validate-fetched-checkout
              (owned_view.compiler-owned-shared-view provenance)
              (owned_view.compiler-owned-shared-view dep-manifest))
              [(ResultBuildString.Err message)
                (ResultBuildPackageGraphNode.Err message)]
              [(ResultBuildString.Ok _)
                (if (not (build-package-kind-lib? dep-manifest.kind))
                  (ResultBuildPackageGraphNode.Err
                    (str_cat.str-cat
                      "build: dependency `"
                      resolved-dep.alias
                      "` at "
                      dep-manifest-path
                      " must be a staticlib package"))
                  ;; Do not resolve or read the acquired library's lock. Its
                  ;; dependency-free invariant is checked when the node enters
                  ;; the graph below.
                  (ResultBuildPackageGraphNode.Ok
                    (BuildPackageGraphNode
                      dep-manifest-path
                      dep-manifest
                      provenance)))])])])))

(define (build-package-acquired-library-dependency-message
  [node : (& node BuildPackageGraphNode)]
  [dep : load.CompilerPkgDep]) : String
  (str_cat.str-cat
    "build: acquired manifest at "
    (string.copy node.manifest-path)
    ": "
    (load.compiler-pkg-library-dependency-message
      (string.copy node.manifest.name)
      dep.alias)))

(define (build-package-graph-add-node
  [node : BuildPackageGraphNode]
  [state : BuildPackageGraphState]) : ResultBuildPackageGraphState
  ;; This second policy boundary is deliberately independent of source
  ;; parsing. Any future acquired manifest representation must still fail
  ;; before it can create a deeper graph edge.
  (match (load.compiler-pkg-manifest-first-library-dependency (& node.manifest))
    [(load.CompilerPkgMaybeDependency.Dependency dep)
      (ResultBuildPackageGraphState.Err
        (build-package-acquired-library-dependency-message (& node) dep))]
    [(load.CompilerPkgMaybeDependency.NoDependency)
      (let
        [manifest-path : String (string.copy node.manifest-path)]
        (match (build_string_i64_map.get
          (& state.seen)
          (owned_view.compiler-owned-shared-view manifest-path))
          [(build_string_i64_map.LookupFound _)
            (ResultBuildPackageGraphState.Ok state)]
          [(build_string_i64_map.LookupMissing)
            (ResultBuildPackageGraphState.Ok
              (build-package-graph-state-add-order
                (build-package-graph-state-mark state manifest-path 1)
                node))]))]))

(define (build-package-graph-add-deps
  [manifest-dir : String]
  [declared-deps : load.CompilerPkgDepList]
  [resolved-deps : load.CompilerPkgDepList]
  [index : i64]
  [state : BuildPackageGraphState]) : ResultBuildPackageGraphState
  (if (>= index (load.compiler-pkg-dep-list-count resolved-deps))
    (ResultBuildPackageGraphState.Ok state)
    (match (build-package-load-dep-node
      (owned_view.compiler-owned-shared-view manifest-dir)
      (load.compiler-pkg-dep-list-at (& declared-deps) index)
      (load.compiler-pkg-dep-list-at (& resolved-deps) index))
      [(ResultBuildPackageGraphNode.Err message)
        (ResultBuildPackageGraphState.Err message)]
      [(ResultBuildPackageGraphNode.Ok node)
        (match (build-package-graph-add-node node state)
          [(ResultBuildPackageGraphState.Err message)
            (ResultBuildPackageGraphState.Err message)]
          [(ResultBuildPackageGraphState.Ok next-state)
            (build-package-graph-add-deps
              manifest-dir
              declared-deps
              resolved-deps
              (+ index 1)
              next-state)])])))

(define (build-package-dependency-graph
  [manifest-path : String]
  [declared-manifest : load.CompilerPkgManifest]
  [resolved-manifest : load.CompilerPkgManifest]) : ResultBuildPackageGraph
  (let
    [root-path : String (build-package-normalize-manifest-path manifest-path)]
    [root-dir : String (load.compiler-load-dirname root-path)]
    [initial : BuildPackageGraphState
      (BuildPackageGraphState
        (build-string-index-map-put
          (build_string_i64_map.with-capacity 32)
          root-path
          1)
        (build-package-graph-node-vec-new))]
    (match (build-package-graph-add-deps
      root-dir
      (load.compiler-pkg-deps-list declared-manifest.deps)
      (load.compiler-pkg-deps-list resolved-manifest.deps)
      0
      initial)
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
  [manifest : (& manifest load.CompilerPkgManifest)]) : bool
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
  [manifest : (& manifest load.CompilerPkgManifest)]) : BuildPackageCompileContext
  (if (build-package-root-compiler?
    (owned_view.compiler-owned-shared-view manifest-dir)
    manifest)
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
      (compiler_parse_core.compiler-cfg-enable
        (compiler_parse_core.compiler-cfg-enable cfgs "compiler-build-identity")
        "compiler-surface-producer")
      cfgs)))

(define (build-ensure-package-output-dirs
  [manifest-dir : String]
  [_name : (& _name str)]
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
            (owned_view.compiler-owned-shared-view manifest-dir)
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
      (owned_view.compiler-owned-shared-view manifest-dir)
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
  [image : cobj.CompilerObjectImage]) : build_run_core.ResultSourceToolLinuxDirectObject
  (build_run_core.source-tool-render-linux-direct-object
    (match kind
      [(CompilerPkgKindBin) backend.CompilerDirectObjectArtifactKind.Bin]
      [(CompilerPkgKindLib) backend.CompilerDirectObjectArtifactKind.StaticLib])
    image))

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
      (match metadata
        [(ast.AstFnMetadata.SpmdCallable _) true]
        [_ false])]
    [(ast.AstDecl.Unsafe inner)
      (build-package-decl-has-spmd-callable?
        (ast.ast-decl-box-shared-view inner))]
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

(define (build-package-direct-object-owned-path-count-from
  [paths : (& paths ast.AstDeclPathList)]
  [index : i64]) : i64
  (if (>= index (ast.ast-decl-path-list-len paths))
    0
    (+
      (if (>
        (string.string-length (ast.ast-decl-path-list-get paths index ""))
        0)
        1
        0)
      (build-package-direct-object-owned-path-count-from paths (+ index 1)))))

(define (build-package-direct-object-owned-path-count
  [paths : (& paths ast.AstDeclPathList)]) : i64
  (build-package-direct-object-owned-path-count-from paths 0))

(define (build-package-direct-object-size-ok?
  [target : backend.CompilerBackendTarget]
  [path-budget : i64]
  [linux-budget-override : bool]
  [paths : (& paths ast.AstDeclPathList)]) : bool
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (or
        linux-budget-override
        (<= (build-package-direct-object-owned-path-count paths) path-budget))]
    [(backend.CompilerBackendTarget.Windows)
      (<= (build-package-direct-object-owned-path-count paths) path-budget)]))

(defenum BuildPackageDirectObjectPreflight
  (Eligible)
  (Fallback backend.CompilerDirectObjectFallbackReason))

(define (build-package-direct-object-preflight
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [mode : backend.CompilerBackendMode]
  [debug-info : bool]
  [path-budget : i64]
  [linux-budget-override : bool]
  [decls : ast.AstDeclList]
  [paths : (& paths ast.AstDeclPathList)]) : BuildPackageDirectObjectPreflight
  (cond
    ;; COFF archive production remains on the assembler path.
    [(match target
        [(backend.CompilerBackendTarget.Linux) false]
        [(backend.CompilerBackendTarget.Windows)
          (match kind
            [(CompilerPkgKindBin) false]
            [(CompilerPkgKindLib) true])])
      (BuildPackageDirectObjectPreflight.Fallback
        (backend.CompilerDirectObjectFallbackReason.ArtifactKindUnavailable
          target
          (match kind
            [(CompilerPkgKindBin) backend.CompilerDirectObjectArtifactKind.Bin]
            [(CompilerPkgKindLib)
              backend.CompilerDirectObjectArtifactKind.StaticLib])))]
    [debug-info
      (BuildPackageDirectObjectPreflight.Fallback
        backend.CompilerDirectObjectFallbackReason.DebugMetadata)]
    [(not (build-package-direct-object-mode? mode))
      (BuildPackageDirectObjectPreflight.Fallback
        backend.CompilerDirectObjectFallbackReason.BackendMode)]
    [(build-package-decls-have-spmd-callable? decls)
      (BuildPackageDirectObjectPreflight.Fallback
        backend.CompilerDirectObjectFallbackReason.PrivateSpmdAbi)]
    [(not
        (build-package-direct-object-size-ok?
          target
          path-budget
          linux-budget-override
          paths))
      (BuildPackageDirectObjectPreflight.Fallback
        (backend.CompilerDirectObjectFallbackReason.ResourceBudget
          (build-package-direct-object-owned-path-count paths)
          path-budget))]
    [else BuildPackageDirectObjectPreflight.Eligible]))

(define (build-package-emit-assembly-fallback
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [lowered : compiler_driver_core.ResultCompilerDriverLowered]
  [reason : backend.CompilerDirectObjectFallbackReason]) : ResultBuildPackagePreparedRuntime
  (match (compiler_driver_core.compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
    ""
    lowered
    target
    true
    mode
    opt-level
    emit-entry
    crt-entry)
    [(compiler_driver_core.ResultCompilerDriver.Err diag advisories)
      (begin
        (compiler_driver_core.compiler-driver-print-advisories (& advisories))
        (ResultBuildPackagePreparedRuntime.Err
          (compiler_driver_core.compiler-driver-render-source-diagnostic
            (deref diag))))]
    [(compiler_driver_core.ResultCompilerDriver.Ok asm advisories)
      (begin
        (compiler_driver_core.compiler-driver-print-advisories (& advisories))
        (ResultBuildPackagePreparedRuntime.Assembly asm reason))]))

;; Route policy is resolved while source declarations are live. Emission owns
;; one lowered result and cannot re-enter package loading or lowering.
(define (build-package-emit-preflighted-runtime
  [kind : load.CompilerPkgKind]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [preflight : BuildPackageDirectObjectPreflight]
  [lowered : compiler_driver_core.ResultCompilerDriverLowered]) : ResultBuildPackagePreparedRuntime
  (match preflight
    [(BuildPackageDirectObjectPreflight.Eligible)
      (match target
        [(backend.CompilerBackendTarget.Linux)
          (match (compiler_driver_core.compiler-driver-emit-lowered-result-package-runtime-with-level-mode-entry-and-crt
            ""
            lowered
            target
            mode
            opt-level
            emit-entry
            crt-entry)
            [(compiler_driver_core.ResultCompilerDriverPackageRuntime.Object
                image
                asm
                advisories)
              (begin
                (compiler_driver_core.compiler-driver-print-advisories
                  (& advisories))
                (match (build-package-render-linux-direct-object kind image)
                  [(build_run_core.ResultSourceToolLinuxDirectObject.Ok object)
                    (ResultBuildPackagePreparedRuntime.DirectObject object asm)]
                  [(build_run_core.ResultSourceToolLinuxDirectObject.Fallback
                      reason)
                    (ResultBuildPackagePreparedRuntime.Assembly asm reason)]))]
            [(compiler_driver_core.ResultCompilerDriverPackageRuntime.Assembly
                asm
                category
                advisories)
              (begin
                (compiler_driver_core.compiler-driver-print-advisories
                  (& advisories))
                (ResultBuildPackagePreparedRuntime.Assembly asm category))]
            [(compiler_driver_core.ResultCompilerDriverPackageRuntime.Err
                diag
                advisories)
              (begin
                (compiler_driver_core.compiler-driver-print-advisories
                  (& advisories))
                (ResultBuildPackagePreparedRuntime.Err
                  (compiler_driver_core.compiler-driver-render-source-diagnostic
                    (deref diag))))])]
        [(backend.CompilerBackendTarget.Windows)
          ;; The shared Windows batch emitter owns the semantic gate as well as
          ;; the COFF encoding/linkability checks. Its Assembly result is an
          ;; intentional, stable fallback rather than a compilation failure.
          (match (compiler_windows_coff_core.compiler-windows-batch-emit-lowered-result
            ""
            lowered
            mode
            opt-level
            false
            true)
            [(compiler_windows_coff_core.ResultCompilerWindowsBatchArtifact.CoffObject
                object
                side-assembly
                advisories)
              (begin
                (compiler_driver_core.compiler-driver-print-advisories
                  (& advisories))
                (match side-assembly
                  [(compiler_windows_coff_core.CompilerWindowsBatchSideAssembly.None)
                    (ResultBuildPackagePreparedRuntime.Err
                      "build: package COFF preparation omitted required side assembly")]
                  [(compiler_windows_coff_core.CompilerWindowsBatchSideAssembly.Some
                      asm)
                    (ResultBuildPackagePreparedRuntime.DirectObject object asm)]))]
            [(compiler_windows_coff_core.ResultCompilerWindowsBatchArtifact.Assembly
                asm
                category
                advisories)
              (begin
                (compiler_driver_core.compiler-driver-print-advisories
                  (& advisories))
                (ResultBuildPackagePreparedRuntime.Assembly
                  (text_buf.render asm)
                  category))]
            [(compiler_windows_coff_core.ResultCompilerWindowsBatchArtifact.Err
                diag
                advisories)
              (begin
                (compiler_driver_core.compiler-driver-print-advisories
                  (& advisories))
                (ResultBuildPackagePreparedRuntime.Err
                  (compiler_driver_core.compiler-driver-render-source-diagnostic
                    (deref diag))))])])]
    [(BuildPackageDirectObjectPreflight.Fallback reason)
      (build-package-emit-assembly-fallback
        target
        opt-level
        mode
        emit-entry
        crt-entry
        lowered
        reason)]))

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

(define (build-package-validate-graph-checkouts-from
  [nodes : BuildPackageGraphNodeVec]
  [index : i64]) : ResultBuildString
  (if (>= index (build-package-graph-node-vec-len nodes))
    (ResultBuildString.Ok "")
    (match (build-package-validate-graph-node-checkout
      (build-package-graph-node-vec-at
        (owned_view.compiler-owned-shared-view nodes)
        index))
      [(ResultBuildString.Err message) (ResultBuildString.Err message)]
      [(ResultBuildString.Ok _)
        (build-package-validate-graph-checkouts-from nodes (+ index 1))])))

(define (build-package-validate-graph-checkouts
  [nodes : BuildPackageGraphNodeVec]) : ResultBuildString
  (build-package-validate-graph-checkouts-from nodes 0))

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
                  (build-package-graph-node-vec-at
                    (owned_view.compiler-owned-shared-view nodes)
                    index)
                  profile
                  target))))
          (set! index (- index 1))))
      libs)))

(define (build-package-catalog-dep-root
  [manifest-dir : String]
  [dep : load.CompilerPkgDep]) : String
  (load.compiler-load-canonical-path
    (if (load.compiler-load-absolute-path? dep.path)
      dep.path
      (load.compiler-load-join-root-path manifest-dir dep.path))))

(define (build-package-catalog-deps-contain-root?
  [deps : (& deps load.CompilerPkgDepList)]
  [count : i64]
  [manifest-dir : String]
  [root : (& root str)]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (< index count)
        (begin
          (if (string.eq
            (build-package-catalog-dep-root
              (owned_view.compiler-owned-shared-view manifest-dir)
              (load.compiler-pkg-dep-list-at (& deps) index))
            root)
            (set! found true)
            unit)
          (set! index (+ index 1))))
      found)))

(define (build-package-graph-catalog-deps
  [nodes : BuildPackageGraphNodeVec]
  [manifest-dir : String]
  [direct-deps : load.CompilerPkgDepList]) : load.CompilerPkgDepList
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [direct-count : i64 (load.compiler-pkg-dep-list-count (& direct-deps))]
    [deps : load.CompilerPkgDepList direct-deps]
    (begin
      (while (< index count)
        (let
          [node : BuildPackageGraphNode
            (build-package-graph-node-vec-at
              (owned_view.compiler-owned-shared-view nodes)
              index)]
          [root : String
            (load.compiler-load-canonical-path
              (load.compiler-load-dirname node.manifest-path))]
          (begin
            ;; Graph construction already canonicalizes and deduplicates node
            ;; roots. Only direct manifest requests need comparison here so
            ;; their aliases and duplicate request telemetry stay intact.
            (if (build-package-catalog-deps-contain-root?
              deps
              direct-count
              (owned_view.compiler-owned-shared-view manifest-dir)
              root)
              unit
              (set!
                deps
                (load.compiler-pkg-dep-list-push
                  deps
                  (load.CompilerPkgDep node.manifest.name root))))
            (set! index (+ index 1)))))
      deps)))

(define (build-package-tlci-owner-stdlib-path?
  [owner : String]
  [path : (& path str)]) : bool
  (if (= (string.string-length owner) 0)
    false
    (let
      [prefix : String (str_cat.str-cat owner "/stdlib/")]
      [prefix-len : i64 (string.string-length prefix)]
      (and
        (>= (string.string-length path) prefix-len)
        (string.eq (string.substring path 0 prefix-len) prefix)))))

(define (build-package-tlci-stdlib-path? [owner : String] [path : (& path str)]) : bool
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
      [classes : ast.AstSpmdParamClassList
        (owned_view.compiler-owned-box-shared-view specialization.args)]
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
          (owned_view.compiler-owned-shared-view package-name)
          (owned_view.compiler-owned-shared-view canonical-name)
          (owned_view.compiler-owned-shared-view signature)
          (owned_view.compiler-owned-shared-view ret)
          spmd-backend
          lanes
          (owned_view.compiler-owned-shared-view args)
          (owned_view.compiler-owned-shared-view result)
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
    [signature : String
      (lower.lower-spmd-source-signature
        params
        (owned_view.compiler-owned-shared-view ret))]
    [spmd-backend : ir.CompilerIrSpmdBackend (build-package-tlci-backend mode)]
    [count : i64 (ast.ast-spmd-specialization-list-len (& specializations))]
    (tlci.tlci-make-spmd-callable
      (owned_view.compiler-owned-shared-view canonical-name)
      (owned_view.compiler-owned-shared-view signature)
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
        (ast.ast-decl-box-shared-view inner-box)
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
          (cli_svec.push-ref! out name)
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
        [value : String (string.copy (array-ref catalog index))]
        [slot : i64 index]
        (begin
          (while (if (> slot 0)
            (package_source_core.package-source-string-less?
              (string.copy value)
              (string.copy (array-ref catalog (- slot 1))))
            false)
            (begin
              (set!
                (array-ref catalog slot)
                (string.copy (array-ref catalog (- slot 1))))
              (set! slot (- slot 1))))
          (set! (array-ref catalog slot) value)
          (set! index (+ index 1)))))))

(define (build-package-tlci-finish-macro-collector
  [names : (&mut names cli_svec.Vec)]
  [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures]) : BuildPackageTlciMacroCollector
  (let
    [count : i64 (cli_svec.len names)]
    [catalog (__tl_make-array String count)]
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
  [owned-sources : (& owned-sources build_string_i64_map.Map)]
  [out : (&mut out cli_svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (match decl
    [(ast.AstDecl.DefMacro decl-meta name params ret body)
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
            (build-package-tlci-push-macro-name!
              out
              (owned_view.compiler-owned-shared-view identity))
            (compiler_tlci_native_producer.tlci-native-macro-captures-push!
              captures
              (compiler_tlci_native_producer.TlciNativeMacroCapture
                identity
                params
                (compiler_tlci_native_producer.embedded-native-macro-result-kind
                  ret)
                body)))))]
    [(ast.AstDecl.Unsafe inner-box)
      (build-package-tlci-collect-decl-macro!
        (deref inner-box)
        owned-path
        module
        package-name
        owned-sources
        out
        captures)]
    [(ast.AstDecl.ModuleBody nested-module body-box)
      (build-package-tlci-collect-macros-into!
        (deref body-box)
        (ast.ast-decl-path-list-new)
        owned-path
        (ci.intern-str nested-module)
        package-name
        owned-sources
        out
        captures)]
    [_ unit]))

(define (build-package-tlci-source-map [sources : (& sources cli_svec.Vec)]) : build_string_i64_map.Map
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
  [owned-sources : (& owned-sources build_string_i64_map.Map)]
  [path : (& path str)]) : bool
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
  [owned-sources : (& owned-sources build_string_i64_map.Map)]
  [out : (&mut out cli_svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (let
    [decl-cursor : ast.AstDeclList decls]
    [path-cursor : ast.AstDeclPathList paths]
    [module : String initial-module]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step
        (owned_view.compiler-owned-shared-view decl-cursor))
        [(ast.AstDeclListStep.Nil) (set! done true)]
        [(ast.AstDeclListStep.Cons decl rest)
          (let
            [decl-path : String
              (match (ast.ast-decl-path-list-step
                (owned_view.compiler-owned-shared-view path-cursor))
                [(ast.AstDeclPathListStep.Nil) fallback-path]
                [(ast.AstDeclPathListStep.Cons path _) path])]
            [owned-path : String
              (if (build-package-tlci-source-owned? owned-sources decl-path)
                decl-path
                "")]
            (begin
              (match (owned_view.compiler-owned-shared-view decl)
                [(ast.AstDecl.Module name) (set! module (ci.intern-str name))]
                [_
                  (build-package-tlci-collect-decl-macro!
                    decl
                    owned-path
                    (owned_view.compiler-owned-shared-view module)
                    (owned_view.compiler-owned-shared-view package-name)
                    owned-sources
                    out
                    captures)])
              (set! decl-cursor rest)
              (match (ast.ast-decl-path-list-step
                (owned_view.compiler-owned-shared-view path-cursor))
                [(ast.AstDeclPathListStep.Nil) unit]
                [(ast.AstDeclPathListStep.Cons _ path-rest)
                  (set! path-cursor path-rest)])))]))))

(define (build-package-tlci-macro-collector
  [source-set : (& source-set package_source_core.PackageSourceSet)]
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

(define (build-package-tlci-collect-callables-into!
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [initial-module : String]
  [package-name : String]
  [mode : backend.CompilerBackendMode]
  [owned-sources : (& owned-sources build_string_i64_map.Map)]
  [collector : BuildPackageTlciCallableCollector]) : BuildPackageTlciCallableCollector
  (let
    [decl-cursor : ast.AstDeclList decls]
    [path-cursor : ast.AstDeclPathList paths]
    [module : String initial-module]
    [done : bool false]
    [current : BuildPackageTlciCallableCollector collector]
    (begin
      (while (and (not done) (= (string.string-length current.error) 0))
        (match (ast.ast-decl-list-step
          (owned_view.compiler-owned-shared-view decl-cursor))
          [(ast.AstDeclListStep.Nil) (set! done true)]
          [(ast.AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (match (ast.ast-decl-path-list-step
                  (owned_view.compiler-owned-shared-view path-cursor))
                  [(ast.AstDeclPathListStep.Nil) fallback-path]
                  [(ast.AstDeclPathListStep.Cons path _) path])]
              [owned-path : String
                (if (build-package-tlci-source-owned? owned-sources decl-path)
                  decl-path
                  "")]
              (begin
                (match (owned_view.compiler-owned-shared-view decl)
                  [(ast.AstDecl.Module name) (set! module (ci.intern-str name))]
                  [(ast.AstDecl.ModuleBody nested-module body-box)
                    (set!
                      current
                      (build-package-tlci-collect-callables-into!
                        (ast.ast-decl-list-box-shared-view body-box)
                        (ast.ast-decl-path-list-new)
                        owned-path
                        (ci.intern-str nested-module)
                        (owned_view.compiler-owned-shared-view package-name)
                        mode
                        owned-sources
                        current))]
                  [_
                    (set!
                      current
                      (build-package-tlci-collect-decl-callable
                        decl
                        owned-path
                        (owned_view.compiler-owned-shared-view module)
                        (owned_view.compiler-owned-shared-view package-name)
                        mode
                        current))])
                (set! decl-cursor rest)
                (match (ast.ast-decl-path-list-step
                  (owned_view.compiler-owned-shared-view path-cursor))
                  [(ast.AstDeclPathListStep.Nil) unit]
                  [(ast.AstDeclPathListStep.Cons _ path-rest)
                    (set! path-cursor path-rest)])))]))
      current)))

(define (build-package-tlci-callable-collector
  [source-set : (& source-set package_source_core.PackageSourceSet)]
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
    (tlci.tlci-build-host-platform)
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

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defstruct BuildPackageTlciSourceInputs
    (source-set package_source_core.PackageSourceSet)
    (digest i64)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defenum ResultBuildPackageTlciSourceInputs
    (Ok BuildPackageTlciSourceInputs)
    (Err String)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-tlci-source-inputs
    [manifest-path : String]
    [producer-identity : (& producer-identity str)]) : ResultBuildPackageTlciSourceInputs
    (if (not (tlci.tlci-producer-identity-valid? producer-identity))
      (ResultBuildPackageTlciSourceInputs.Err
        "build: exact producer compiler identity is unavailable")
      (match (package_source_core.package-source-discover-for
        "build"
        manifest-path
        true)
        [(package_source_core.ResultPackageSourceSet.Err message)
          (ResultBuildPackageTlciSourceInputs.Err message)]
        [(package_source_core.ResultPackageSourceSet.Ok source-set)
          (match (package_source_core.package-source-set-digest
            (owned_view.compiler-owned-shared-view source-set))
            [(package_source_core.ResultPackageSourceDigest.Err message)
              (ResultBuildPackageTlciSourceInputs.Err
                (str_cat.str-cat
                  "build: failed to compute package source digest: "
                  message))]
            [(package_source_core.ResultPackageSourceDigest.Ok digest)
              (ResultBuildPackageTlciSourceInputs.Ok
                (BuildPackageTlciSourceInputs source-set digest))])]))))

;; Only canonical text and owned catalog strings cross runtime lowering. Native
;; captures themselves contain AST pool indices and must remain inside capture.
(defenum ResultBuildPackageTlciExports
  (Ok String (__tl_dyn-array String) String)
  (Err String))

(define (build-package-tlci-capture-exports
  [manifest : load.CompilerPkgManifest]
  [mode : backend.CompilerBackendMode]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [source-set : (& source-set package_source_core.PackageSourceSet)]) : ResultBuildPackageTlciExports
  (let
    [home : arena.Arena (arena.current)]
    (with-scratch
      (match (build-package-tlci-collect-exports
        manifest
        mode
        decls
        paths
        source-set)
        [(ResultBuildPackageTlciExports.Err message)
          (in-arena
            home
            (ResultBuildPackageTlciExports.Err (string.copy message)))]
        [(ResultBuildPackageTlciExports.Ok metadata names native-source)
          (in-arena
            home
            (let
              [count : i64 (array-length names)]
              [copied : (__tl_dyn-array String) (__tl_make-array String count)]
              [index : i64 0]
              (begin
                (while (< index count)
                  (begin
                    (set!
                      (array-ref copied index)
                      (string.copy (array-ref names index)))
                    (set! index (+ index 1))))
                (ResultBuildPackageTlciExports.Ok
                  (string.copy metadata)
                  copied
                  (string.copy native-source)))))]))))

(define (build-package-tlci-collect-exports
  [manifest : load.CompilerPkgManifest]
  [mode : backend.CompilerBackendMode]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [source-set : (& source-set package_source_core.PackageSourceSet)]) : ResultBuildPackageTlciExports
  (let
    [collector : BuildPackageTlciCallableCollector
      (build-package-tlci-callable-collector
        source-set
        (owned_view.compiler-owned-shared-view manifest)
        mode
        (owned_view.compiler-owned-shared-view decls)
        (owned_view.compiler-owned-shared-view paths))]
    [macro-collector : BuildPackageTlciMacroCollector
      (build-package-tlci-macro-collector
        source-set
        (owned_view.compiler-owned-shared-view manifest)
        decls
        paths)]
    [names : (__tl_dyn-array String) macro-collector.names]
    (if (> (string.string-length collector.error) 0)
      (ResultBuildPackageTlciExports.Err collector.error)
      (ResultBuildPackageTlciExports.Ok
        (tlci.tlci-metadata-emit
          (build-package-tlci-metadata manifest collector.items))
        (owned_view.compiler-owned-shared-view names)
        (if (= (array-length names) 0)
          ""
          (compiler_tlci_native_producer.embedded-native-source
            names
            (& macro-collector.captures)))))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-tlci-text-with-surface
    [exports : ResultBuildPackageTlciExports]
    [producer-identity : String]
    [source-inputs : BuildPackageTlciSourceInputs]
    [surface : package_surface.PackageSurfacePayloads]) : ResultBuildPackageTlciText
    (match (package_surface.package-surface-pack surface source-inputs.digest)
      [(tlci.ResultTlciAuxBytes.Err message)
        (ResultBuildPackageTlciText.Err
          (str_cat.str-cat
            "build: failed to pack package frontend surface: "
            message))]
      [(tlci.ResultTlciAuxBytes.Ok rodata)
        (match exports
          [(ResultBuildPackageTlciExports.Err message)
            (ResultBuildPackageTlciText.Err message)]
          [(ResultBuildPackageTlciExports.Ok metadata-text names native-source)
            (if (= (array-length names) 0)
              (match (tlci.tlci-metadata-parse metadata-text)
                [(tlci.ResultTlciMetadata.Err message)
                  (ResultBuildPackageTlciText.Err
                    (str_cat.str-cat
                      "build: captured package metadata rejected: "
                      message))]
                [(tlci.ResultTlciMetadata.Ok metadata)
                  (match (tlci.tlci-emit-image
                    (build-package-tlci-image metadata producer-identity rodata))
                    [(tlci.ResultTlciBytes.Err message)
                      (ResultBuildPackageTlciText.Err
                        (str_cat.str-cat
                          "build: failed to emit package tlci: "
                          message))]
                    [(tlci.ResultTlciBytes.Ok bytes)
                      (ResultBuildPackageTlciText.Ok
                        (tlci.tlci-bytes->string bytes 0 (array-length bytes)))])])
              (match (compiler_tlci_native_producer.embedded-native-emit-package-source
                metadata-text
                producer-identity
                (cfg windows true false)
                rodata
                names
                native-source)
                [(compiler_tlci_native_producer.ResultProducerBytes.Err message)
                  (ResultBuildPackageTlciText.Err
                    (str_cat.str-cat
                      "build: failed to emit package tlci: "
                      message))]
                [(compiler_tlci_native_producer.ResultProducerBytes.Ok bytes)
                  (ResultBuildPackageTlciText.Ok
                    (tlci.tlci-bytes->string bytes 0 (array-length bytes)))]))])])))

(define (build-package-runtime-fingerprint-path [artifact-path : String]) : String
  (str_cat.str-cat artifact-path ".runtime-inputs"))

(define (build-package-file-regular? [path : String]) : bool
  (match (build-package-artifact-file-state path)
    [(BuildPackageArtifactState.Clean) true]
    [_ false]))

(define (build-package-file-text-eq? [path : String] [expected : String]) : bool
  (if (not
    (build-package-file-regular? (owned_view.compiler-owned-shared-view path)))
    false
    (match (io.try-read-file (& path))
      [(io.OkIoBytes contents)
        (string.eq (byte_buf.to-string contents) expected)]
      [(io.ErrIoBytes _) false])))

(define (build-package-file-digest [path : (& path str)] [context : String]) : ResultBuildPackageFileDigest
  (match (io.try-read-file path)
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
            (owned_view.compiler-owned-shared-view bytes))]
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
        (owned_view.compiler-owned-shared-view first))]
    [hash-a : i64
      (package_source_core.package-source-binding-hash-bytes
        (package_source_core.package-source-binding-hash-u64 hash-a1 last-count)
        (owned_view.compiler-owned-shared-view last))]
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

(define (build-package-tool-file-digest
  [path : (& path str)]
  [context : String]) : ResultBuildPackageFileDigest
  (match (fs.try-file-metadata path)
    [(fs.ErrFsMetadata error)
      (ResultBuildPackageFileDigest.Err
        (str_cat.str-cat context ": " (io.error-message error)))]
    [(fs.OkFsMetadata metadata)
      (let
        [size : i64 (fs.metadata-size metadata)]
        [sample-size : i64 65536]
        (match (io.file-open path (io.OpenMode.OpenRead))
          [(io.ErrIoFile error)
            (ResultBuildPackageFileDigest.Err
              (str_cat.str-cat context ": " (io.error-message error)))]
          [(io.OkIoFile handle)
            (let
              [first : (__tl_dyn-array u8) (__tl_make-array u8 0)]
              [last : (__tl_dyn-array u8) (__tl_make-array u8 0)]
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
                    (unsafe
                      (io.platform-lseek
                        (io_core.io-file-i64-ref
                          (io_core.io-file-fds-ptr)
                          handle.id)
                        (- size sample-size)
                        0))
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
            (str_cat.str-cat
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
    (if (not
      (build-package-file-regular?
        (owned_view.compiler-owned-shared-view executable)))
      (ResultBuildString.Err
        (str_cat.str-cat
          "build: cannot fingerprint "
          role
          " executable "
          executable))
      (match (build-package-tool-file-digest
        executable
        (str_cat.str-cat
          "build: cannot fingerprint "
          (owned_view.compiler-owned-shared-view role)
          " executable"))
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
  (if (build-package-file-regular? (owned_view.compiler-owned-shared-view path))
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
              [(ResultBuildString.Ok text)
                (set! out (str_cat.str-cat out text))])
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
    [direct : String
      (build-package-link-library-candidate
        (owned_view.compiler-owned-shared-view dir)
        (owned_view.compiler-owned-shared-view library))]
    [first : String
      (build-package-link-library-candidate
        (owned_view.compiler-owned-shared-view dir)
        (match target
          [(backend.CompilerBackendTarget.Linux)
            (str_cat.str-cat
              "lib"
              (owned_view.compiler-owned-shared-view library)
              ".a")]
          [(backend.CompilerBackendTarget.Windows)
            (str_cat.str-cat
              (owned_view.compiler-owned-shared-view library)
              ".lib")]))]
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
              (ResultBuildString.Ok (str_cat.str-cat direct-text first-text))
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
      (build_run_core.source-tool-link-inputs-libs
        (owned_view.compiler-owned-shared-view inputs))]
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
                  (set! out (str_cat.str-cat out text))])
              (while (and ok (< dir-index dir-count))
                (begin
                  (match (build-package-link-library-file-transcript
                    target
                    (process.args-ref dirs dir-index)
                    (owned_view.compiler-owned-shared-view library))
                    [(ResultBuildString.Err message)
                      (begin
                        (set! ok false)
                        (set! error message))]
                    [(ResultBuildString.Ok text)
                      (set! out (str_cat.str-cat out text))])
                  (set! dir-index (+ dir-index 1)))))
            (set! library-index (+ library-index 1)))))
      (if ok
        (ResultBuildString.Ok out)
        (ResultBuildString.Err error)))))

(define (build-package-link-file-transcript
  [target : backend.CompilerBackendTarget]
  [inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildString
  (match (build-package-link-raw-file-transcript
    (owned_view.compiler-owned-shared-view inputs))
    [(ResultBuildString.Err message) (ResultBuildString.Err message)]
    [(ResultBuildString.Ok raw-text)
      (match (build-package-link-library-files-transcript target inputs)
        [(ResultBuildString.Err message) (ResultBuildString.Err message)]
        [(ResultBuildString.Ok library-text)
          (ResultBuildString.Ok (str_cat.str-cat raw-text library-text))])]))

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
    (owned_view.compiler-owned-shared-view link-inputs))
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
      (match (build-package-assembler-command-for
        target
        asm-path
        (owned_view.compiler-owned-shared-view obj-path))
        [(build_run_core.ResultSourceToolCommand.Err message)
          (ResultBuildString.Err message)]
        [(build_run_core.ResultSourceToolCommand.Ok assembler)
          (match (build-package-command-transcript "assembler" assembler)
            [(ResultBuildString.Err message) (ResultBuildString.Err message)]
            [(ResultBuildString.Ok assembler-text)
              (build-package-runtime-input-transcript-after-assembler
                (str_cat.str-cat base assembler-text)
                kind
                target
                obj-path
                artifact-path
                link-inputs)])]))))

(define (build-package-runtime-output-fingerprint
  [input-transcript : String]
  [asm-path : (& asm-path str)]
  [obj-path : (& obj-path str)]
  [artifact-path : (& artifact-path str)]) : ResultBuildString
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
      (owned_view.compiler-owned-shared-view asm-path)
      (owned_view.compiler-owned-shared-view obj-path)
      (owned_view.compiler-owned-shared-view artifact-path)
      (owned_view.compiler-owned-shared-view fingerprint-path)))
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
    (build-package-file-text-eq?
      (owned_view.compiler-owned-shared-view obj-path)
      object-text)
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
    (build-package-file-text-eq?
      (owned_view.compiler-owned-shared-view asm-path)
      asm)
    (build-package-runtime-fingerprint-fresh?
      input-transcript
      asm-path
      obj-path
      artifact-path
      fingerprint-path)))

(define (build-package-path-present? [path : (& path str)]) : bool
  (match (fs.try-file-metadata path)
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
          (owned_view.compiler-owned-shared-view output-dir)
          (str_cat.str-cat ".t" (string.int->string attempt)))]
      (if (build-package-path-present? candidate)
        (build-package-stage-dir-attempt output-dir _name (+ attempt 1))
        (if (build-mkdir-ok-owned?
          (owned_view.compiler-owned-shared-view candidate))
          (ResultBuildString.Ok candidate)
          (ResultBuildString.Err
            (str_cat.str-cat
              "build: failed to create package artifact staging directory "
              candidate)))))))

(define (build-package-stage-file
  [dir : String]
  [stem : String]
  [final-path : (& final-path str)]) : String
  (let
    [extension : String (fs.extension final-path)]
    (load.compiler-load-join-root-path
      dir
      (if (= (string.string-length extension) 0)
        stem
        (str_cat.str-cat stem "." extension)))))

(define (build-package-stage-paths
  [output-dir : String]
  [name : String]
  [asm-path : (& asm-path str)]
  [obj-path : (& obj-path str)]
  [artifact-path : (& artifact-path str)]
  [fingerprint-path : (& fingerprint-path str)]
  [tlci-path : (& tlci-path str)]) : ResultBuildPackageStagePaths
  (match (build-package-stage-dir-attempt output-dir name 1)
    [(ResultBuildString.Err message) (ResultBuildPackageStagePaths.Err message)]
    [(ResultBuildString.Ok dir)
      (ResultBuildPackageStagePaths.Ok
        (BuildPackageStagePaths
          (owned_view.compiler-owned-shared-view dir)
          (build-package-stage-file
            (owned_view.compiler-owned-shared-view dir)
            "a"
            asm-path)
          (build-package-stage-file
            (owned_view.compiler-owned-shared-view dir)
            "o"
            obj-path)
          (build-package-stage-file
            (owned_view.compiler-owned-shared-view dir)
            "r"
            artifact-path)
          (build-package-stage-file
            (owned_view.compiler-owned-shared-view dir)
            "f"
            fingerprint-path)
          (build-package-stage-file dir "t" tlci-path)))]))

(define (build-package-remove-staged-file [path : String]) : unit
  (begin
    (fs.try-remove-file-if-exists (& path))
    (let
      [backup : String (str_cat.str-cat path ".previous")]
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

(define (build-package-rollback-preserves-backup?
  [rollback : (& rollback BuildPackageRollbackDisposition)]
  [backup-path : (& backup-path str)]) : bool
  (let
    [index : i64 0]
    [preserve : bool false]
    (begin
      (while (and (not preserve) (< index rollback.len))
        (begin
          (match (owned_view.compiler-owned-array-element-shared-view
            rollback.backups
            index)
            [(BuildPackageBackupRollback.Retained backup _ _)
              (set! preserve (string.eq backup backup-path))]
            [_ unit])
          (set! index (+ index 1))))
      preserve)))

(define (build-package-remove-staged-file-after-rollback
  [path : String]
  [rollback : (& rollback BuildPackageRollbackDisposition)]) : unit
  (begin
    (fs.try-remove-file-if-exists (& path))
    (let
      [backup : String (str_cat.str-cat path ".previous")]
      (if (build-package-rollback-preserves-backup? rollback backup)
        unit
        (let
          [_ : io.ResultIoUnit (fs.try-remove-file-if-exists (& backup))]
          unit)))
    unit))

(define (build-package-clean-stage-after-rollback
  [paths : BuildPackageStagePaths]
  [rollback : BuildPackageRollbackDisposition]) : unit
  ;; Always discard new staged data. Delete only superseded `.previous` files;
  ;; a retained entry also keeps the containing stage directory recoverable.
  (begin
    (build-package-remove-staged-file-after-rollback paths.asm rollback)
    (build-package-remove-staged-file-after-rollback paths.obj rollback)
    (build-package-remove-staged-file-after-rollback paths.artifact rollback)
    (build-package-remove-staged-file-after-rollback paths.fingerprint rollback)
    (build-package-remove-staged-file-after-rollback paths.tlci rollback)
    (let
      [dir : String paths.dir]
      (if (build-package-rollback-recovery-required? rollback)
        unit
        (let
          [_ : io.ResultIoUnit (fs.try-remove-dir-if-exists (& dir))]
          unit)))
    unit))

(define (build-package-commit-plan-new) : BuildPackageCommitPlan
  (BuildPackageCommitPlan
    (__tl_make-array BuildPackageCommitFile build-package-commit-file-capacity)
    0))

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
          (owned_view.compiler-owned-shared-view staged-path)
          (str_cat.str-cat staged-path ".previous")
          false))
      (BuildPackageCommitPlan files (+ index 1)))))

(define (build-package-commit-plan-set-had-old!
  [plan : BuildPackageCommitPlan]
  [index : i64]) : unit
  (let
    [files : (__tl_dyn-array BuildPackageCommitFile) plan.files]
    [item : BuildPackageCommitFile
      (owned_view.compiler-owned-array-element-shared-view files index)]
    (set!
      (array-ref files index)
      (BuildPackageCommitFile
        item.final-path
        item.staged-path
        item.backup-path
        true))))

(define (build-package-rollback-disposition-new) : BuildPackageRollbackDisposition
  (BuildPackageRollbackDisposition
    (__tl_make-array
      BuildPackageBackupRollback
      build-package-commit-file-capacity)
    0
    ""))

(define (build-package-rollback-disposition-add-backup
  [rollback : BuildPackageRollbackDisposition]
  [backup : BuildPackageBackupRollback]) : BuildPackageRollbackDisposition
  (let
    [backups : (__tl_dyn-array BuildPackageBackupRollback) rollback.backups]
    [index : i64 rollback.len]
    (begin
      (set! (array-ref backups index) backup)
      (BuildPackageRollbackDisposition backups (+ index 1) rollback.errors))))

(define (build-package-rollback-disposition-add-error
  [rollback : BuildPackageRollbackDisposition]
  [message : String]) : BuildPackageRollbackDisposition
  (BuildPackageRollbackDisposition
    rollback.backups
    rollback.len
    (if (= (string.string-length rollback.errors) 0)
      message
      (str_cat.str-cat rollback.errors "\n" message))))

(define (build-package-rollback-recovery-required?
  [rollback : BuildPackageRollbackDisposition]) : bool
  (let
    [index : i64 0]
    [required : bool false]
    (begin
      (while (and (not required) (< index rollback.len))
        (begin
          (match (owned_view.compiler-owned-array-element-shared-view
            rollback.backups
            index)
            [(BuildPackageBackupRollback.Retained _ _ _) (set! required true)]
            [_ unit])
          (set! index (+ index 1))))
      required)))

(define (build-package-commit-error-message
  [primary : String]
  [rollback : BuildPackageRollbackDisposition]
  [stage-dir : String]) : String
  (let
    [with-secondary : String
      (if (= (string.string-length rollback.errors) 0)
        primary
        (str_cat.str-cat
          primary
          "\n"
          (owned_view.compiler-owned-shared-view rollback.errors)))]
    (if (build-package-rollback-recovery-required? rollback)
      (str_cat.str-cat
        with-secondary
        "\nbuild: retained package artifact recovery stage: "
        stage-dir
        "; restore the reported .previous files before removing it")
      with-secondary)))

(define (build-package-commit-plan-preflight
  [plan : (& plan BuildPackageCommitPlan)]) : ResultBuildString
  (let
    [index : i64 0]
    [count : i64 plan.len]
    [ok : bool true]
    [error : String ""]
    (begin
      (while (and ok (< index count))
        (let
          [item : BuildPackageCommitFile
            (owned_view.compiler-owned-array-element-shared-view
              plan.files
              index)]
          [final-state : BuildPackageArtifactState
            (build-package-artifact-file-state
              (owned_view.compiler-owned-shared-view item.final-path))]
          (begin
            (if (not
              (build-package-file-regular?
                (owned_view.compiler-owned-shared-view item.staged-path)))
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
  [backed-up : i64]) : BuildPackageRollbackDisposition
  (let
    [index : i64 (- installed 1)]
    [rollback : BuildPackageRollbackDisposition
      (build-package-rollback-disposition-new)]
    (begin
      (while (>= index 0)
        (let
          [item : BuildPackageCommitFile
            (owned_view.compiler-owned-array-element-shared-view
              plan.files
              index)]
          (begin
            (let
              [path : String item.final-path]
              (match (fs.try-remove-file-if-exists (& path))
                [(io.OkIoUnit) unit]
                [(io.ErrIoUnit io-error)
                  (set!
                    rollback
                    (build-package-rollback-disposition-add-error
                      rollback
                      (str_cat.str-cat
                        "build: rollback failed to remove installed package artifact "
                        path
                        ": "
                        (io.error-message io-error))))]))
            (set! index (- index 1)))))
      (set! index (- backed-up 1))
      (while (>= index 0)
        (let
          [item : BuildPackageCommitFile
            (owned_view.compiler-owned-array-element-shared-view
              plan.files
              index)]
          (begin
            (if item.had-old
              (let
                [backup : String item.backup-path]
                [final-path : String item.final-path]
                (match (fs.try-rename (& backup) (& final-path))
                  [(io.OkIoUnit)
                    (set!
                      rollback
                      (build-package-rollback-disposition-add-backup
                        rollback
                        (BuildPackageBackupRollback.Restored backup final-path)))]
                  [(io.ErrIoUnit io-error)
                    (let
                      [io-message : String (io.error-message io-error)]
                      [failure : String
                        (str_cat.str-cat
                          "build: rollback failed to restore previous package artifact "
                          (owned_view.compiler-owned-shared-view backup)
                          " -> "
                          (owned_view.compiler-owned-shared-view final-path)
                          ": "
                          (owned_view.compiler-owned-shared-view io-message))]
                      (begin
                        (set!
                          rollback
                          (build-package-rollback-disposition-add-error
                            rollback
                            failure))
                        (set!
                          rollback
                          (build-package-rollback-disposition-add-backup
                            rollback
                            (BuildPackageBackupRollback.Retained
                              backup
                              final-path
                              io-message)))))]))
              unit)
            (set! index (- index 1)))))
      rollback)))

(define (build-package-commit-plan-run [plan : BuildPackageCommitPlan]) : ResultBuildPackageCommit
  (match (build-package-commit-plan-preflight plan)
    [(ResultBuildString.Err message)
      (ResultBuildPackageCommit.Err
        message
        (build-package-rollback-disposition-new))]
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
              [item : BuildPackageCommitFile
                (owned_view.compiler-owned-array-element-shared-view
                  plan.files
                  index)]
              [state : BuildPackageArtifactState
                (build-package-artifact-file-state
                  (owned_view.compiler-owned-shared-view item.final-path))]
              (begin
                (match state
                  [(BuildPackageArtifactState.Clean)
                    (let
                      [from : String item.final-path]
                      [to : String item.backup-path]
                      (match (fs.try-rename (& from) (& to))
                        [(io.OkIoUnit)
                          (build-package-commit-plan-set-had-old!
                            (owned_view.compiler-owned-shared-view plan)
                            index)]
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
              [item : BuildPackageCommitFile
                (owned_view.compiler-owned-array-element-shared-view
                  plan.files
                  index)]
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
                  [item : BuildPackageCommitFile
                    (owned_view.compiler-owned-array-element-shared-view
                      plan.files
                      index)]
                  (begin
                    (if item.had-old
                      (let
                        [backup : String item.backup-path]
                        (fs.try-remove-file-if-exists (& backup)))
                      io.OkIoUnit)
                    (set! index (+ index 1)))))
              (ResultBuildPackageCommit.Ok))
            (ResultBuildPackageCommit.Err
              error
              (build-package-commit-plan-rollback plan installed backed-up)))))]))

(define (build-package-write-tlci [path : (& path str)] [text : String]) : build_run_core.SourceToolCommandStatus
  (build_run_core.source-tool-write-file
    path
    text
    "build: failed to write package tlci"))

(define (build-package-write-assembly
  [path : (& path str)]
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
          (match (io.try-append-file path (byte_buf.str-as-bytes (& note)))
            [(io.OkIoUnit) build_run_core.SourceToolCommandStatus.Ok]
            [(io.ErrIoUnit error)
              (build_run_core.SourceToolCommandStatus.Err
                (str_cat.str-cat
                  "build: failed to write package assembly: "
                  (io.error-message error)))])
          build_run_core.SourceToolCommandStatus.Ok))]))

(define (build-package-announce-freshness
  [artifact-path : String]
  [tlci-path : String]
  [runtime-dirty : bool]
  [tlci-dirty : bool]
  [announce : bool]) : i64
  (if announce
    (begin
      (io.print-format
        "{}"
        (str_cat.str-cat
          (if runtime-dirty
            "Built "
            "Fresh ")
          artifact-path
          "\n"))
      (io.print-format
        "{}"
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
                    (build-package-commit-plan-add
                      plan
                      asm-path
                      (owned_view.compiler-owned-shared-view stage.asm)))
                  (set!
                    plan
                    (build-package-commit-plan-add
                      plan
                      obj-path
                      (owned_view.compiler-owned-shared-view stage.obj)))
                  (set!
                    plan
                    (build-package-commit-plan-add
                      plan
                      (owned_view.compiler-owned-shared-view artifact-path)
                      (owned_view.compiler-owned-shared-view stage.artifact)))
                  (set!
                    plan
                    (build-package-commit-plan-add
                      plan
                      fingerprint-path
                      (owned_view.compiler-owned-shared-view stage.fingerprint))))])])
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
              (build-package-commit-plan-add
                plan
                (owned_view.compiler-owned-shared-view tlci-path)
                (owned_view.compiler-owned-shared-view stage.tlci)))])
        unit)
      (if ok
        (match (build-package-commit-plan-run plan)
          [(ResultBuildPackageCommit.Err message rollback)
            (begin
              (build-package-clean-stage-after-rollback
                (owned_view.compiler-owned-shared-view stage)
                (owned_view.compiler-owned-shared-view rollback))
              (io.print-error
                (build-package-commit-error-message message rollback stage.dir))
              1)]
          [(ResultBuildPackageCommit.Ok)
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
  [output-dir : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [tlci-path : String]
  [tlci-text : String]
  [object-text : String]
  [side-assembly : String]
  [announce : bool]) : i64
  (let
    [fingerprint-path : String
      (build-package-runtime-fingerprint-path
        (owned_view.compiler-owned-shared-view artifact-path))]
    [tlci-dirty : bool
      (not
        (build-package-file-text-eq?
          (owned_view.compiler-owned-shared-view tlci-path)
          (owned_view.compiler-owned-shared-view tlci-text)))]
    (match (build-package-runtime-input-transcript
      kind
      target
      profile
      mode
      opt-level
      producer-identity
      (owned_view.compiler-owned-shared-view asm-path)
      (owned_view.compiler-owned-shared-view obj-path)
      (owned_view.compiler-owned-shared-view artifact-path)
      (owned_view.compiler-owned-shared-view link-inputs)
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
                (owned_view.compiler-owned-shared-view input-transcript)
                (owned_view.compiler-owned-shared-view asm-path)
                (owned_view.compiler-owned-shared-view obj-path)
                (owned_view.compiler-owned-shared-view artifact-path)
                (owned_view.compiler-owned-shared-view fingerprint-path)
                (owned_view.compiler-owned-shared-view object-text)))]
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
                        (owned_view.compiler-owned-shared-view stage.obj)
                        (owned_view.compiler-owned-shared-view stage.artifact)
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
                            (build-package-write-assembly
                              stage.asm
                              side-assembly
                              target)
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
      (build-package-runtime-fingerprint-path
        (owned_view.compiler-owned-shared-view artifact-path))]
    [augmented-asm : String
      (build_run_core.source-tool-augment-assembly-for-target asm target)]
    [tlci-dirty : bool
      (not
        (build-package-file-text-eq?
          (owned_view.compiler-owned-shared-view tlci-path)
          (owned_view.compiler-owned-shared-view tlci-text)))]
    [_release-lower : unit
      (compiler_driver_core.compiler-driver-release-lower-arenas-after-emit!)]
    (match (build-package-runtime-input-transcript
      kind
      target
      profile
      mode
      opt-level
      producer-identity
      (owned_view.compiler-owned-shared-view asm-path)
      (owned_view.compiler-owned-shared-view obj-path)
      (owned_view.compiler-owned-shared-view artifact-path)
      (owned_view.compiler-owned-shared-view link-inputs)
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
                (owned_view.compiler-owned-shared-view input-transcript)
                (owned_view.compiler-owned-shared-view asm-path)
                (owned_view.compiler-owned-shared-view obj-path)
                (owned_view.compiler-owned-shared-view artifact-path)
                (owned_view.compiler-owned-shared-view fingerprint-path)
                (owned_view.compiler-owned-shared-view augmented-asm)))]
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
                            (owned_view.compiler-owned-shared-view stage.asm)
                            (owned_view.compiler-owned-shared-view stage.obj)
                            (owned_view.compiler-owned-shared-view
                              stage.artifact)
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

(define (build-package-finish-prepared-runtime
  [prepared : ResultBuildPackagePreparedRuntime]
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
  [announce : bool]) : i64
  (match prepared
    [(ResultBuildPackagePreparedRuntime.DirectObject object-text side-assembly)
      (build-package-finish-direct-fresh-artifacts
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
        1)]))

(define (build-package-require-direct-object
  [prepared : ResultBuildPackagePreparedRuntime]) : ResultBuildPackagePreparedRuntime
  (match prepared
    [(ResultBuildPackagePreparedRuntime.DirectObject object side-assembly)
      (ResultBuildPackagePreparedRuntime.DirectObject object side-assembly)]
    [(ResultBuildPackagePreparedRuntime.Assembly _ reason)
      (ResultBuildPackagePreparedRuntime.Err
        (str_cat.str-cat
          "build: direct object required: "
          (backend.compiler-direct-object-fallback-transcript reason)))]
    [(ResultBuildPackagePreparedRuntime.Err message)
      (ResultBuildPackagePreparedRuntime.Err message)]))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-prepare-owned-runtime
    [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope]
    [request : BuildPackageDirectObjectRequest]) : ResultBuildPackagePreparedRuntime
    (let
      [preflight : BuildPackageDirectObjectPreflight
        (build-package-direct-object-preflight
          request.kind
          request.target
          request.mode
          request.debug-info
          request.path-budget
          request.linux-budget-override
          (owned_view.compiler-owned-shared-view request.decls)
          (& request.paths))]
      [lowered : compiler_driver_core.ResultCompilerDriverLowered
        (compiler_driver_core.compiler-driver-package-runtime-lower
          scope
          request.name
          request.target
          request.mode
          request.decls
          request.paths
          request.cfgs)]
      [prepared : ResultBuildPackagePreparedRuntime
        (build-package-emit-preflighted-runtime
          request.kind
          request.target
          request.opt-level
          request.mode
          request.emit-entry
          request.crt-entry
          preflight
          lowered)]
      (if request.require-direct-object
        (build-package-require-direct-object prepared)
        prepared))))

;; Observe the runtime child while its derived frontend surfaces are live.
;; The later catalog-finish report belongs to the restored parent, which owns
;; admitted mappings but did not perform this runtime's surface hydration.
(define (build-package-runtime-scope-release!
  [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope]) : unit
  (begin
    (cfg
      dependency-tlci-verification
      (unless
        (array-ref scope.released 0)
        (compiler_dependency_tlci.compiler-dependency-tlci-verification-record!
          (owned_view.compiler-owned-shared-view scope.state.load-session)
          "runtime-finished"
          -1)))
    (compiler_driver_core.compiler-driver-package-runtime-scope-release! scope)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-finish-fresh-artifacts-with-surface
    [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope]
    [manifest : load.CompilerPkgManifest]
    [source-inputs : BuildPackageTlciSourceInputs]
    [seen : sym_i64_env.SymI64Env]
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
    [source-paths : ast.AstDeclPathList]
    [owned-paths : ast.AstDeclPathList]
    [output-dir : String]
    [asm-path : String]
    [obj-path : String]
    [artifact-path : String]
    [link-inputs : build_run_core.SourceToolLinkInputs]
    [tlci-path : String]
    [announce : bool]
    [cfgs : sym_i64_env.SymI64Env]) : i64
    (begin
      (package_surface.package-surface-capture-start!
        (package_surface.package-surface-identity-key
          (owned_view.compiler-owned-shared-view name)
          (owned_view.compiler-owned-shared-view owned-paths)
          source-inputs.digest
          (owned_view.compiler-owned-shared-view producer-identity)
          (build_run_core.source-tool-target-name target))
        (sym_i64_env.sym-i64-copy seen))
      (let
        [exports : ResultBuildPackageTlciExports
          (build-package-tlci-capture-exports
            manifest
            mode
            (owned_view.compiler-owned-shared-view decls)
            source-paths
            source-inputs.source-set)]
        [prepared : ResultBuildPackagePreparedRuntime
          (build-package-prepare-owned-runtime
            (owned_view.compiler-owned-shared-view scope)
            (build-package-direct-object-default-request
              (owned_view.compiler-owned-shared-view name)
              kind
              target
              opt-level
              mode
              emit-entry
              crt-entry
              decls
              owned-paths
              cfgs))]
        [_abort : unit
          (match (owned_view.compiler-owned-shared-view prepared)
            [(ResultBuildPackagePreparedRuntime.Err message)
              (package_surface.package-surface-capture-abort! message)]
            [_ unit])]
        [captured : package_surface.ResultPackageSurfacePayloads
          (package_surface.package-surface-capture-take)]
        [_release : unit (build-package-runtime-scope-release! scope)]
        (match (owned_view.compiler-owned-shared-view prepared)
          [(ResultBuildPackagePreparedRuntime.Err message)
            (begin
              (io.print-error message)
              1)]
          [_
            (match captured
              [(package_surface.ResultPackageSurfacePayloads.Err message)
                (begin
                  (io.print-error
                    (str_cat.str-cat
                      "build: failed to capture package frontend surface: "
                      message))
                  1)]
              [(package_surface.ResultPackageSurfacePayloads.Ok surface)
                (match (build-package-tlci-text-with-surface
                  exports
                  (owned_view.compiler-owned-shared-view producer-identity)
                  source-inputs
                  surface)
                  [(ResultBuildPackageTlciText.Err message)
                    (begin
                      (io.print-error message)
                      1)]
                  [(ResultBuildPackageTlciText.Ok tlci-text)
                    (build-package-finish-prepared-runtime
                      prepared
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
                      announce)])])])))))

(define (build-package-doctest-paths
  [owner : String]
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [owner-id : i64
      (ast.ast-decl-path-list-owner-id
        (& paths)
        0
        cbi.compiler-builtin-id-fix-empty)]
    [provenance-id : i64
      (ast.ast-decl-path-list-provenance-id
        (& paths)
        0
        cbi.compiler-builtin-id-fix-empty)]
    (match (ast.ast-decl-path-list-step paths)
      [(ast.AstDeclPathListStep.Nil) (ast.ast-decl-path-list-new)]
      [(ast.AstDeclPathListStep.Cons path rest)
        (let
          [tail : ast.AstDeclPathList
            (build-package-doctest-paths
              (owned_view.compiler-owned-shared-view owner)
              rest)]
          (if (build-package-tlci-stdlib-path? owner path)
            tail
            (ast.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
              path
              owner-id
              provenance-id
              tail)))])))

(define (build-package-closure-doctest-status
  [owner : String]
  [entry-path : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [deps : load.CompilerPkgDeps]
  [emit-entry : bool]) : i64
  (match (compiler_driver_core.compiler-driver-load-package-paths-with-runtime
    entry-path
    target
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view manifest-dir)
    (owned_view.compiler-owned-shared-view deps)
    emit-entry)
    [(compiler_driver_core.ResultCompilerDriverPackagePaths.Err diag)
      (begin
        (io.print-error
          (compiler_driver_core.compiler-driver-render-source-diagnostic
            (deref diag)))
        1)]
    [(compiler_driver_core.ResultCompilerDriverPackagePaths.Ok paths)
      (doc_test.doc-test-report-status
        (doc_test.doc-test-typecheck-package-paths-with-roots
          (build-package-doctest-paths owner paths)
          stdlib-roots
          manifest-dir
          deps))]))

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

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-emit-one-with-surface
    [manifest-path : String]
    [manifest : load.CompilerPkgManifest]
    [target : backend.CompilerBackendTarget]
    [opt-level : i64]
    [profile : BuildProfile]
    [mode : backend.CompilerBackendMode]
    [stdlib-roots : cli_svec.Vec]
    [producer-identity : String]
    [entry-path : String]
    [manifest-dir : String]
    [kind : load.CompilerPkgKind]
    [asm-path : String]
    [obj-path : String]
    [artifact-path : String]
    [tlci-path : String]
    [manifest-link-inputs : build_run_core.SourceToolLinkInputs]
    [dep-link-inputs : build_run_core.SourceToolLinkInputs]
    [emit-entry : bool]
    [compile-cfgs : sym_i64_env.SymI64Env]
    [announce : bool]) : i64
    (let
      [home : arena.Arena (arena.current)]
      [cfg-names : cfg_core.CompilerCfgSnapshot
        (cfg_core.compiler-cfg-snapshot-from-env compile-cfgs)]
      (with-scratch
        (let
          [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope
            (compiler_driver_core.compiler-driver-package-runtime-scope-new
              home)]
          [status : i64
            (in-arena
              home
              (build-package-emit-one-in-runtime-scope
                (owned_view.compiler-owned-shared-view scope)
                manifest-path
                manifest
                target
                opt-level
                profile
                mode
                stdlib-roots
                producer-identity
                entry-path
                manifest-dir
                kind
                asm-path
                obj-path
                artifact-path
                tlci-path
                manifest-link-inputs
                dep-link-inputs
                emit-entry
                (cfg_core.compiler-cfg-snapshot-to-env cfg-names)
                announce))]
          (begin
            (build-package-runtime-scope-release! scope)
            status))))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-emit-one-in-runtime-scope
    [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope]
    [manifest-path : String]
    [manifest : load.CompilerPkgManifest]
    [target : backend.CompilerBackendTarget]
    [opt-level : i64]
    [profile : BuildProfile]
    [mode : backend.CompilerBackendMode]
    [stdlib-roots : cli_svec.Vec]
    [producer-identity : String]
    [entry-path : String]
    [manifest-dir : String]
    [kind : load.CompilerPkgKind]
    [asm-path : String]
    [obj-path : String]
    [artifact-path : String]
    [tlci-path : String]
    [manifest-link-inputs : build_run_core.SourceToolLinkInputs]
    [dep-link-inputs : build_run_core.SourceToolLinkInputs]
    [emit-entry : bool]
    [compile-cfgs : sym_i64_env.SymI64Env]
    [announce : bool]) : i64
    (match (build-package-tlci-source-inputs manifest-path producer-identity)
      [(ResultBuildPackageTlciSourceInputs.Err message)
        (begin
          (io.print-error message)
          1)]
      [(ResultBuildPackageTlciSourceInputs.Ok source-inputs)
        (match (compiler_driver_core.compiler-driver-package-runtime-load
          (owned_view.compiler-owned-shared-view scope)
          (owned_view.compiler-owned-shared-view entry-path)
          (owned_view.compiler-owned-shared-view stdlib-roots)
          (owned_view.compiler-owned-shared-view manifest-dir)
          (owned_view.compiler-owned-shared-view manifest.deps)
          emit-entry
          compile-cfgs)
          [(load.ResultCompilerLoadWithPaths.Err diag)
            (begin
              (io.print-error
                (compiler_driver_core.compiler-driver-render-source-diagnostic
                  (deref diag)))
              1)]
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ seen)
            (let
              [owned-paths : ast.AstDeclPathList
                (load.compiler-load-package-owned-paths-for-decls
                  (owned_view.compiler-owned-shared-view manifest.name)
                  (owned_view.compiler-owned-shared-view manifest-dir)
                  stdlib-roots
                  entry-path
                  (owned_view.compiler-owned-shared-view decls)
                  (owned_view.compiler-owned-shared-view paths))]
              [metadata-link-inputs : build_run_core.SourceToolLinkInputs
                (build_run_core.source-tool-link-inputs-from-decls
                  (owned_view.compiler-owned-shared-view decls)
                  (build_run_core.source-tool-link-inputs-empty))]
              [effective-link-inputs : build_run_core.SourceToolLinkInputs
                (clone
                  (build_run_core.source-tool-link-inputs-merge
                    (build_run_core.source-tool-link-inputs-merge
                      manifest-link-inputs
                      metadata-link-inputs)
                    dep-link-inputs))]
              [crt-entry : bool
                (and
                  emit-entry
                  (build_run_core.source-tool-linux-crt-entry?
                    target
                    effective-link-inputs))]
              (build-package-finish-fresh-artifacts-with-surface
                scope
                (owned_view.compiler-owned-shared-view manifest)
                source-inputs
                seen
                (owned_view.compiler-owned-shared-view manifest.name)
                kind
                target
                opt-level
                profile
                mode
                producer-identity
                emit-entry
                crt-entry
                decls
                paths
                owned-paths
                (build-package-output-dir-profile
                  manifest-dir
                  manifest.name
                  profile)
                asm-path
                obj-path
                artifact-path
                effective-link-inputs
                tlci-path
                announce
                compile-cfgs))])])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
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
    [catalog-deps : load.CompilerPkgDepList]
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
        (build-package-compile-context
          (owned_view.compiler-owned-shared-view manifest-dir)
          manifest)]
      [entry-path : String
        (load.compiler-load-join-root-path
          (owned_view.compiler-owned-shared-view manifest-dir)
          (owned_view.compiler-owned-shared-view manifest.entry))]
      [name : String (owned_view.compiler-owned-shared-view manifest.name)]
      [_package-artifact-profile : unit
        (load.compiler-load-set-package-artifact-profile!
          (build-profile-name profile))]
      [kind : load.CompilerPkgKind manifest.kind]
      [asm-path : String
        (build-package-asm-path-profile
          (owned_view.compiler-owned-shared-view manifest-dir)
          (owned_view.compiler-owned-shared-view name)
          profile)]
      [obj-path : String
        (build-package-obj-path-profile
          (owned_view.compiler-owned-shared-view manifest-dir)
          (owned_view.compiler-owned-shared-view name)
          profile
          target)]
      [artifact-paths : BuildPackageArtifactPaths
        (build-package-artifact-paths
          (owned_view.compiler-owned-shared-view manifest-dir)
          (owned_view.compiler-owned-shared-view name)
          kind
          profile
          target)]
      [artifact-path : String
        (build-package-runtime-artifact-path
          (owned_view.compiler-owned-shared-view artifact-paths))]
      [tlci-path : String
        (build-package-host-tlci-artifact-path artifact-paths)]
      [_reset-file-state : unit
        (compiler_driver_core.compiler-driver-reset-file-state!)]
      [_dependency-catalogs : unit
        (compiler_dependency_tlci.compiler-dependency-tlci-prepare-deps!
          (load.compiler-load-serial-test-session-state)
          (owned_view.compiler-owned-shared-view manifest-dir)
          (load.compiler-pkg-deps-from-list catalog-deps))]
      (if (or
        (> (string.string-length compile-context.error) 0)
        (not
          (build-ensure-package-output-dirs
            (owned_view.compiler-owned-shared-view manifest-dir)
            name
            profile)))
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
            (build-package-manifest-link-inputs
              (owned_view.compiler-owned-shared-view manifest.link)
              (owned_view.compiler-owned-shared-view manifest-dir)
              target)]
          [dep-link-inputs : build_run_core.SourceToolLinkInputs
            (build_run_core.source-tool-link-inputs-from-archives dep-libs)]
          [emit-entry : bool (build-package-kind-entry? kind)]
          [inline-test-status : i64
            (build-inline-test-typecheck-package-sources
              (owned_view.compiler-owned-shared-view manifest-path)
              (owned_view.compiler-owned-shared-view stdlib-roots)
              (owned_view.compiler-owned-shared-view manifest-dir)
              (owned_view.compiler-owned-shared-view name)
              (owned_view.compiler-owned-shared-view manifest.deps)
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
                  (owned_view.compiler-owned-shared-view entry-path)
                  (owned_view.compiler-owned-shared-view manifest-path)
                  target
                  opt-level
                  profile
                  mode
                  lock-policy
                  (owned_view.compiler-owned-shared-view manifest.deps)
                  (load.compiler-pkg-deps-list
                    (owned_view.compiler-owned-shared-view manifest.deps))
                  (owned_view.compiler-owned-shared-view stdlib-roots)
                  (owned_view.compiler-owned-shared-view manifest-dir)
                  emit-entry)]
              [_reset-after-pre-emit-doctests : unit
                (begin
                  (compiler_driver_core.compiler-driver-reset-file-state!)
                  (ci.intern-persistent-arena-reset!))]
              (if (= pre-emit-doctest-status 0)
                (build-package-emit-one-with-surface
                  manifest-path
                  manifest
                  target
                  opt-level
                  profile
                  mode
                  stdlib-roots
                  producer-identity
                  entry-path
                  manifest-dir
                  kind
                  asm-path
                  obj-path
                  artifact-path
                  tlci-path
                  manifest-link-inputs
                  dep-link-inputs
                  emit-entry
                  (build-package-compile-cfgs
                    target
                    compile-context.root-compiler)
                  announce)
                pre-emit-doctest-status))
            inline-test-status))))))

(cfg
  (not
    (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci))
  (define (build-package-emit-one
    [_manifest-path : String]
    [_manifest : load.CompilerPkgManifest]
    [_target : backend.CompilerBackendTarget]
    [_opt-level : i64]
    [_profile : BuildProfile]
    [_mode : backend.CompilerBackendMode]
    [_lock-policy : BuildPackageLockPolicy]
    [_stdlib-roots : cli_svec.Vec]
    [_dep-libs : process.ProcessStringList]
    [_catalog-deps : load.CompilerPkgDepList]
    [_producer-identity : String]
    [_announce : bool]) : i64
    (begin
      (io.print-error
        "build: package emission requires checked frontend surface support")
      1)))

(define (build-package-dependency-catalog-finish [status : i64]) : i64
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    (begin
      (compiler_dependency_tlci.compiler-dependency-tlci-verification-finish!
        (owned_view.compiler-owned-shared-view state))
      (match (load.compiler-load-session-state-dependency-catalog-release!
        state)
        [(load.ResultCompilerLoadDependencyCatalogUnit.Ok) status]
        [(load.ResultCompilerLoadDependencyCatalogUnit.Err message)
          (begin
            (io.print-error
              (str_cat.str-cat
                "build: failed to release dependency catalog mapping: "
                message))
            (if (= status 0)
              1
              status))]))))

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
  [roots : (& roots cli_svec.Vec)]) : process.ProcessStringList
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

(define (build-package-worker-args-with-flag
  [worker-flag : String]
  [manifest-path : String]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [resolved-deps : load.CompilerPkgDepList]
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]) : process.ProcessStringList
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
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]) : process.ProcessStringList
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
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]) : process.ProcessCommand
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
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]) : process.ProcessCommand
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
        (process.error-spawn-failed?
          (owned_view.compiler-owned-shared-view error))
        (process.error-unsupported?
          (owned_view.compiler-owned-shared-view error)))
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
        (match (build-load-manifest
          (owned_view.compiler-owned-shared-view normalized-path))
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
                    (owned_view.compiler-owned-shared-view normalized-path)
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
                    (build-package-dependency-catalog-finish
                      (build-package-emit-one
                        normalized-path
                        (owned_view.compiler-owned-shared-view
                          resolved-manifest)
                        config.target
                        config.opt-level
                        config.profile
                        config.mode
                        config.lock-policy
                        config.stdlib-roots
                        (process.args-empty)
                        (load.compiler-pkg-deps-list resolved-manifest.deps)
                        producer-identity
                        true))
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
        (match (build-load-manifest
          (owned_view.compiler-owned-shared-view normalized-path))
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
                    (owned_view.compiler-owned-shared-view normalized-path)
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
                        (owned_view.compiler-owned-shared-view manifest-dir)
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
  [built : (& built build_string_i64_map.Map)]) : bool
  (if (>= index (load.compiler-pkg-dep-list-count deps))
    true
    (let
      [dep-manifest-path : String
        (build-package-dep-manifest-path
          (owned_view.compiler-owned-shared-view manifest-dir)
          (load.compiler-pkg-dep-list-at deps index))]
      (match (build_string_i64_map.get built dep-manifest-path)
        [(build_string_i64_map.LookupFound _)
          (build-package-deps-built? manifest-dir deps (+ index 1) built)]
        [(build_string_i64_map.LookupMissing) false]))))

(define (build-package-node-ready?
  [node : BuildPackageGraphNode]
  [built : (& built build_string_i64_map.Map)]) : bool
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
  [scheduled : (& scheduled build_string_i64_map.Map)]
  [manifest-path : String]) : bool
  (match (build_string_i64_map.get (& scheduled) manifest-path)
    [(build_string_i64_map.LookupFound _) true]
    [(build_string_i64_map.LookupMissing) false]))

(define (build-package-graph-worker-list-empty?
  [items : (& items BuildPackageGraphWorkerList)]) : bool
  (match items
    [(BuildPackageGraphWorkerList.Empty) true]
    [(BuildPackageGraphWorkerList.More _ _) false]))

(define (build-package-graph-worker-list-reverse-with
  [remaining : BuildPackageGraphWorkerList]
  [out : BuildPackageGraphWorkerList]) : BuildPackageGraphWorkerList
  (match remaining
    [(BuildPackageGraphWorkerList.Empty) out]
    [(BuildPackageGraphWorkerList.More worker tail)
      (build-package-graph-worker-list-reverse-with
        (deref tail)
        (BuildPackageGraphWorkerList.More worker (box out)))]))

(define (build-package-graph-worker-list-reverse
  [workers : BuildPackageGraphWorkerList]) : BuildPackageGraphWorkerList
  (build-package-graph-worker-list-reverse-with
    workers
    (BuildPackageGraphWorkerList.Empty)))

(define (build-package-start-worker
  [node : BuildPackageGraphNode]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]) : ResultBuildPackageGraphWorker
  (let
    [manifest-path : String
      (owned_view.compiler-owned-shared-view node.manifest-path)]
    [manifest : load.CompilerPkgManifest
      (owned_view.compiler-owned-shared-view node.manifest)]
    [name : String manifest.name]
    [artifacts : BuildPackageArtifactPaths
      (build-package-graph-node-artifact-paths
        (owned_view.compiler-owned-shared-view node)
        profile
        target)]
    [command : process.ProcessCommand
      (build-package-worker-command
        manifest-path
        target
        opt-level
        profile
        mode
        lock-policy
        stdlib-roots)]
    (match (build-package-validate-graph-node-checkout
      (owned_view.compiler-owned-shared-view node))
      [(ResultBuildString.Err message)
        (ResultBuildPackageGraphWorker.Err message)]
      [(ResultBuildString.Ok _)
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
                (process.error-message error)))])])))

(define (build-package-schedule-pass-with
  [nodes : BuildPackageGraphNodeVec]
  [scheduled : build_string_i64_map.Map]
  [built : (& built build_string_i64_map.Map)]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [workers : BuildPackageGraphWorkerList]
  [index : i64]
  [count : i64]) : ResultBuildPackageSchedulePass
  (if (>= index count)
    (ResultBuildPackageSchedulePass.Ok
      (BuildPackageSchedulePass
        scheduled
        (build-package-graph-worker-list-reverse workers)))
    (let
      [node : BuildPackageGraphNode
        (build-package-graph-node-vec-at
          (owned_view.compiler-owned-shared-view nodes)
          index)]
      [manifest-path : String
        (owned_view.compiler-owned-shared-view node.manifest-path)]
      (if (or
        (build-package-node-scheduled?
          scheduled
          (owned_view.compiler-owned-shared-view manifest-path))
        (not
          (build-package-node-ready?
            (owned_view.compiler-owned-shared-view node)
            built)))
        (build-package-schedule-pass-with
          nodes
          scheduled
          built
          target
          opt-level
          profile
          mode
          lock-policy
          stdlib-roots
          workers
          (+ index 1)
          count)
        (match (build-package-start-worker
          node
          target
          opt-level
          profile
          mode
          lock-policy
          stdlib-roots)
          [(ResultBuildPackageGraphWorker.Err message)
            (ResultBuildPackageSchedulePass.Err message)]
          [(ResultBuildPackageGraphWorker.Ok worker)
            (begin
              (build-string-index-map-put! (&mut scheduled) manifest-path 1)
              (build-package-schedule-pass-with
                nodes
                scheduled
                built
                target
                opt-level
                profile
                mode
                lock-policy
                stdlib-roots
                (BuildPackageGraphWorkerList.More worker (box workers))
                (+ index 1)
                count))])))))

(define (build-package-schedule-pass
  [nodes : BuildPackageGraphNodeVec]
  [scheduled : build_string_i64_map.Map]
  [built : build_string_i64_map.Map]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]) : ResultBuildPackageSchedulePass
  (let
    [count : i64 (build-package-graph-node-vec-len nodes)]
    (build-package-schedule-pass-with
      nodes
      scheduled
      built
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots
      (BuildPackageGraphWorkerList.Empty)
      0
      count)))

(define (build-package-all-built?
  [nodes : BuildPackageGraphNodeVec]
  [built : (& built build_string_i64_map.Map)]) : bool
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [all-built : bool true]
    (begin
      (while (and all-built (< index count))
        (let
          [node : BuildPackageGraphNode
            (build-package-graph-node-vec-at
              (owned_view.compiler-owned-shared-view nodes)
              index)]
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

(define (build-package-wait-worker
  [worker : (&mut worker BuildPackageGraphWorker)]
  [built : (&mut built build_string_i64_map.Map)]
  [announce : bool]
  [failed-status : (&mut failed-status i64)]) : unit
  (let
    [manifest-path : String (string.copy (& worker.node.manifest-path))]
    [name : String (string.copy (& worker.node.manifest.name))]
    [runtime-path : String (string.copy (& worker.artifacts.runtime))]
    [tlci-path : String (string.copy (& worker.artifacts.tlci))]
    [result : process.ResultProcessOutput (process.wait (&mut worker.child))]
    (match result
      [(process.OkProcessOutput output)
        (begin
          (if (or announce (not (process.success? output)))
            (build_run_core.source-tool-forward-output output)
            unit)
          (if (process.success? output)
            (let
              [runtime-state : BuildPackageArtifactState
                (build-package-artifact-file-state
                  (owned_view.compiler-owned-shared-view runtime-path))]
              (if (build-package-artifact-state-dirty?
                (owned_view.compiler-owned-shared-view runtime-state))
                (begin
                  (io.print-error
                    (build-package-artifact-status-error-message
                      name
                      "target runtime"
                      runtime-path
                      runtime-state))
                  (set!
                    (deref failed-status)
                    (build-package-failure-status (deref failed-status) 1)))
                (let
                  [tlci-state : BuildPackageArtifactState
                    (build-package-artifact-file-state
                      (owned_view.compiler-owned-shared-view tlci-path))]
                  (if (build-package-artifact-state-dirty?
                    (owned_view.compiler-owned-shared-view tlci-state))
                    (begin
                      (io.print-error
                        (build-package-artifact-status-error-message
                          name
                          "host tlci"
                          tlci-path
                          tlci-state))
                      (set!
                        (deref failed-status)
                        (build-package-failure-status (deref failed-status) 1)))
                    (build-string-index-map-put! built manifest-path 1)))))
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
                  (deref failed-status)
                  (build-package-failure-status (deref failed-status) status))))))]
      [(process.ErrProcessOutput error)
        (begin
          (io.print-error
            (str_cat.str-cat
              "build: failed to wait for package dependency `"
              name
              "`: "
              (process.error-message error)))
          (set!
            (deref failed-status)
            (build-package-failure-status (deref failed-status) 1)))])))

(define (build-package-wait-workers-with
  [workers : BuildPackageGraphWorkerList]
  [built : build_string_i64_map.Map]
  [announce : bool]
  [failed-status : i64]) : ResultBuildPackageWait
  (match workers
    [(BuildPackageGraphWorkerList.Empty)
      (if (= failed-status 0)
        (ResultBuildPackageWait.Ok built)
        (ResultBuildPackageWait.Err failed-status))]
    [(BuildPackageGraphWorkerList.More worker tail)
      (let
        [next-built : build_string_i64_map.Map built]
        [next-failed-status : i64 failed-status]
        (begin
          (build-package-wait-worker
            (&mut worker)
            (&mut next-built)
            announce
            (&mut next-failed-status))
          (build-package-wait-workers-with
            (deref tail)
            next-built
            announce
            next-failed-status)))]))

(define (build-package-wait-workers
  [workers : BuildPackageGraphWorkerList]
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
  (if (build-package-all-built?
    (owned_view.compiler-owned-shared-view nodes)
    built)
    0
    (match (build-package-schedule-pass
      (owned_view.compiler-owned-shared-view nodes)
      scheduled
      (owned_view.compiler-owned-shared-view built)
      target
      opt-level
      profile
      mode
      lock-policy
      (owned_view.compiler-owned-shared-view stdlib-roots))
      [(ResultBuildPackageSchedulePass.Err message)
        (begin
          (io.print-error message)
          1)]
      [(ResultBuildPackageSchedulePass.Ok pass)
        (if (build-package-graph-worker-list-empty? (& pass.workers))
          (begin
            (io.print-error
              "build: package dependency scheduler made no progress")
            1)
          (match (build-package-wait-workers pass.workers built announce)
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
                next-built)]))])))

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
            (build-package-graph-node-vec-at
              (owned_view.compiler-owned-shared-view nodes)
              index)]
          [validation : ResultBuildString
            (build-package-validate-graph-node-checkout
              (owned_view.compiler-owned-shared-view node))]
          [manifest-path : String node.manifest-path]
          [manifest : load.CompilerPkgManifest node.manifest]
          [node-status : i64
            (match validation
              [(ResultBuildString.Err message)
                (begin
                  (io.print-error message)
                  1)]
              [(ResultBuildString.Ok _)
                (build-package-emit-one
                  manifest-path
                  (owned_view.compiler-owned-shared-view manifest)
                  target
                  opt-level
                  profile
                  mode
                  lock-policy
                  (owned_view.compiler-owned-shared-view stdlib-roots)
                  (process.args-empty)
                  (load.compiler-pkg-deps-list manifest.deps)
                  (owned_view.compiler-owned-shared-view producer-identity)
                  announce)])]
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
    [doctest-status : i64
      (doc_test.doc-test-typecheck-file-status
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view stdlib-roots))]
    (if (= doctest-status 0)
      (let
        [inline-test-status : i64
          (test_cli_core.tltest-inline-typecheck-file-with-cfg
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view stdlib-roots)
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

(define (build-package-emit-owned
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
          (owned_view.compiler-owned-shared-view normalized-path)
          (owned_view.compiler-owned-shared-view manifest)
          lock-policy)
          [(ResultBuildManifest.Err message)
            (begin
              (io.print-error message)
              1)]
          [(ResultBuildManifest.Ok resolved-manifest)
            (match (build-package-dependency-graph
              (owned_view.compiler-owned-shared-view normalized-path)
              manifest
              (owned_view.compiler-owned-shared-view resolved-manifest))
              [(ResultBuildPackageGraph.Err message)
                (begin
                  (io.print-error message)
                  1)]
              [(ResultBuildPackageGraph.Ok graph)
                (let
                  [nodes : BuildPackageGraphNodeVec graph.order]
                  [dep-status : i64
                    (build-package-emit-graph-nodes
                      (owned_view.compiler-owned-shared-view nodes)
                      target
                      opt-level
                      profile
                      mode
                      lock-policy
                      (owned_view.compiler-owned-shared-view stdlib-roots)
                      (owned_view.compiler-owned-shared-view producer-identity)
                      announce)]
                  (if (= dep-status 0)
                    (match (build-package-validate-graph-checkouts
                      (owned_view.compiler-owned-shared-view nodes))
                      [(ResultBuildString.Err message)
                        (begin
                          (io.print-error message)
                          1)]
                      [(ResultBuildString.Ok _)
                        (build-package-emit-one
                          (owned_view.compiler-owned-shared-view
                            normalized-path)
                          (owned_view.compiler-owned-shared-view
                            resolved-manifest)
                          target
                          opt-level
                          profile
                          mode
                          lock-policy
                          stdlib-roots
                          (build-package-graph-link-libs
                            (owned_view.compiler-owned-shared-view nodes)
                            profile
                            target)
                          (build-package-graph-catalog-deps
                            nodes
                            (load.compiler-load-dirname normalized-path)
                            (load.compiler-pkg-deps-list resolved-manifest.deps))
                          producer-identity
                          announce)])
                    dep-status))])]))]))

(define (build-package-emit
  [manifest-path : String]
  [manifest : load.CompilerPkgManifest]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : backend.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [producer-identity : String]
  [announce : bool]) : i64
  (build-package-dependency-catalog-finish
    (build-package-emit-owned
      manifest-path
      manifest
      target-text
      has-target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots
      producer-identity
      announce)))

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
      (match (build-load-manifest
        (owned_view.compiler-owned-shared-view manifest-path))
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
      (match (owned_view.compiler-owned-shared-view config)
        [(BuildConfig.Source) (build-source-direct-from idx (io.arg-count))]
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

;; Native link options only source builds accept.
(define (build-link-cli-options) : String
  "--link-lib <name> --link-search <dir> --link-arg <arg>")

;; Whether the arguments name a source file: the first argument that is neither
;; a build option, an option value, nor another flag.
(define (build-args-have-source? [idx : i64] [count : i64]) : bool
  (let
    [specs : String
      (str_cat.str-cat (build-package-cli-options) " " (build-link-cli-options))]
    [i : i64 idx]
    [found : bool false]
    (begin
      (while (and (not found) (< i count))
        (let
          [current : String (io.arg i)]
          (match (cli_option.cli-option-lookup (& specs) (& current))
            [(cli_option.CliOptionMatch.Found _ arity)
              (set! i (+ i (+ arity 1)))]
            [(cli_option.CliOptionMatch.None)
              (if (cli_option.cli-flag? (& current))
                (set! i (+ i 1))
                (set! found true))])))
      found)))

(define (build-cli-config-from [idx : i64] [count : i64]) : ResultBuildCliConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "build"
        (str_cat.str-cat
          "--stdlib-root <dir> --target <target> --opt-level <0|1|2>
           --debug|-g|--backtrace -o <exe> --backend-mode <mode>
           --manifest-path <file> --profile --release --locked --update-lock "
          (build-link-cli-options))
        idx
        count)]
    [source : String ""]
    [has-source : bool false]
    [output : String ""]
    [has-output : bool false]
    [target : backend.CompilerBackendTarget
      (build_run_core.source-tool-default-target)]
    [mode : backend.CompilerBackendMode (backend.CompilerBackendMode.Scalar)]
    [stdlib-roots : cli_svec.Vec (cli_svec.new)]
    [opt-level : i64 (opt.compiler-optimize-default-level)]
    [link-inputs : build_run_core.SourceToolLinkInputs
      (build_run_core.source-tool-link-inputs-empty)]
    (begin
      (while (cli_option.cli-args-next! (&mut args))
        (cond
          [(string.eq args.name "--stdlib-root")
            (cli_svec.push-ref!
              (&mut stdlib-roots)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "--target")
            (let
              [value : String (cli_option.cli-args-value (& args))]
              (match (build_run_core.source-tool-target (string.copy (& value)))
                [(build_run_core.ResultSourceToolTarget.Ok parsed-target)
                  (set! target parsed-target)]
                [(build_run_core.ResultSourceToolTarget.Err _)
                  (cli_option.cli-args-fail!
                    (&mut args)
                    (build-cli-unknown-target value))]))]
          [(string.eq args.name "--opt-level")
            (let
              [value : String (cli_option.cli-args-value (& args))]
              [level : i64 (cli_option.cli-option-opt-level (& value))]
              (if (< level 0)
                (cli_option.cli-args-fail!
                  (&mut args)
                  (build-cli-unknown-opt-level value))
                (set! opt-level level)))]
          [(string.eq args.name "--debug")
            (ir.compiler-debug-info-set-enabled! true)]
          [(string.eq args.name "-o")
            (if has-output
              (cli_option.cli-args-fail!
                (&mut args)
                "build: -o was provided more than once")
              (begin
                (set! output (cli_option.cli-args-value (& args)))
                (set! has-output true)))]
          [(string.eq args.name "--backend-mode")
            (match (build_run_core.source-tool-backend-mode
              "build"
              (cli_option.cli-args-value (& args)))
              [(build_run_core.ResultSourceToolBackendMode.Ok parsed-mode)
                (set! mode parsed-mode)]
              [(build_run_core.ResultSourceToolBackendMode.Err message)
                (cli_option.cli-args-fail! (&mut args) message)])]
          [(string.eq args.name "--link-lib")
            (set!
              link-inputs
              (build_run_core.source-tool-link-inputs-add-lib
                link-inputs
                (cli_option.cli-args-value (& args))))]
          [(string.eq args.name "--link-search")
            (set!
              link-inputs
              (build_run_core.source-tool-link-inputs-add-search-dir
                link-inputs
                (cli_option.cli-args-value (& args))))]
          [(string.eq args.name "--link-arg")
            (set!
              link-inputs
              (build_run_core.source-tool-link-inputs-add-raw-arg
                link-inputs
                (cli_option.cli-args-value (& args))))]
          [(string.eq args.name "--manifest-path")
            (cli_option.cli-args-fail!
              (&mut args)
              "build: cannot combine a source file with --manifest-path")]
          ;; Package-only options.
          [(> (string.string-length args.name) 0)
            (let
              [message : String
                (string.concat3-borrowed
                  "build: "
                  (& args.name)
                  " is only valid for package builds")]
              (cli_option.cli-args-fail! (&mut args) message))]
          [(cli_option.cli-flag? args.arg)
            (cli_option.cli-args-fail-arg! (&mut args) "build: unknown flag ")]
          [has-source
            (cli_option.cli-args-fail!
              (&mut args)
              "build: accepts only one source file")]
          [else
            (begin
              (set! source (string.copy (& args.arg)))
              (set! has-source true))]))
      (cond
        [args.failed (ResultBuildCliConfig.Err args.error)]
        [has-source
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
              link-inputs))]
        [has-output
          (ResultBuildCliConfig.Err "build: -o requires a source file argument")]
        [else (ResultBuildCliConfig.Err "build: expected source path")]))))

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
    (ir.compiler-debug-path-remap-clear!)
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