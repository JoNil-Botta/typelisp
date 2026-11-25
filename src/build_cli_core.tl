;; build_cli_core.tl - Selfhost build command logic.
;;
;; Source-file builds assemble and link in-process through stdlib fs/process
;; helpers. Package builds are handled in-process by the selfhost compiler:
;; parse/discover `typelisp.pkg`, emit assembly for the manifest entry, and
;; produce the package artifact selected by manifest kind.
(import stdlib.clone as clone_gen)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import stdlib.fs)

;; lint-allow: unused-import -- used only by cfg-gated code.
(import stdlib.arena)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_cfg_core as cfg_core))
(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.env)
(import stdlib.io)
(import stdlib.io_core)
(import stdlib.process)
(import stdlib.sort)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.hashmap)
(import stdlib.vector)
(import compiler_builtin_ids as cbi)
(import (hashmap.hashmap String i64) as build_string_i64_map)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import tli_cli_core as tli_cli)
(import compiler_target_cfg_core as target_cfg)
(import build_run_core)
(import compiler_backend_object as be_object)
(import compiler_ast_types as ast)
(import compiler_load as load)
(import compiler_symbols as csym)
(import compiler_intern as ci)
(import compiler_ir_types as ir)
(import compiler_lower as lower)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_opt_level as opt_level))
(import compiler_optimize as opt)
(import compiler_object as cobj)
(import linker_archive_core as archive)
(import linker_ar_dialect_reader as ar)
(import linker_elf_object_reader as elf)
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
(import compiler_tli_types as tli)
(import compiler_tli_codec as tli_codec)
(import compiler_tli_extract as tli_extract)
(import compiler_tli_hydrate as tli_hydrate)
(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc_core)
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
    cli_svec.Vec
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
    be_state.CompilerBackendTarget
    be_state.CompilerBackendMode
    cli_svec.Vec
    cli_svec.Vec
    i64
    build_run_core.SourceToolLinkInputs))

(defenum ResultBuildCliConfig
  (Ok BuildCliConfig)
  (Err String))

;; Complete outputs from one runtime preparation. Artifact finishing has no
;; AST inputs and cannot regenerate assembly or invoke the compiler again.
(defenum ResultBuildPackagePreparedRuntime
  (DirectObject String String)
  (Assembly String be_state.CompilerDirectObjectFallbackReason)
  (Err String))

(defstruct BuildPackageDirectObjectRequest
  (name String)
  (kind load.CompilerPkgKind)
  (target be_state.CompilerBackendTarget)
  (opt-level i64)
  (mode be_state.CompilerBackendMode)
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
  (cfgs sym_i64_env.SymI64Env)
  ;; The package entry file: an emission diagnostic without a source span,
  ;; such as a missing executable `main`, is reported there.
  (entry-path String))

(define (build-package-direct-object-default-request
  [name : String]
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [cfgs : sym_i64_env.SymI64Env]
  [entry-path : String]) : BuildPackageDirectObjectRequest
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
    cfgs
    entry-path))

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
  ;; Empty for executable packages.
  (tli String)
  ;; Optional for library packages (emitted only when macros or SPMD callables exist).
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
  (tli String)
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
  (target be_state.CompilerBackendTarget)
  (mode be_state.CompilerBackendMode)
  (profile BuildProfile)
  (opt-level i64)
  (lock-policy BuildPackageLockPolicy)
  (stdlib-roots cli_svec.Vec)
  (cfgs cli_svec.Vec)
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

(clone_gen.gen-clone BuildProfile)

(defenum BuildPackageLockPolicy
  (Default)
  (Locked)
  (Update))

(clone_gen.gen-clone BuildPackageLockPolicy)

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
  6)
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
    (build_string_i64_map.insert-ref! (&mut out) key value)
    out))

(define (build-string-index-map-put!
  [map : (&mut map build_string_i64_map.Map)]
  [key : String]
  [value : i64]) : unit
  (build_string_i64_map.insert-ref! map key value))

(define (build-invalid-manifest-message
  [diag : compiler_diagnostic.CompilerDiagnostic]) : String
  (str_cat.str-cat
    "invalid package manifest: "
    (compiler_diagnostic.compiler-diagnostic-render (& diag))))

(define (build-unknown-profile [value : String]) : String
  (str_cat.str-cat
    "build: unknown profile '"
    value
    "'; expected dev or release"))

(define (build-default-profile) : BuildProfile
  (Release))

(define (build-profile-name [profile : BuildProfile]) : String
  (match profile
    [(Dev) "dev"]
    [(Release) "release"]))

(define (build-backend-mode-name [mode : be_state.CompilerBackendMode]) : String
  (match mode
    [(Scalar) "scalar"]
    [(Avx2) "avx2"]
    [(Avx512) "avx512"]))

(define (build-profile-default-opt-level [profile : BuildProfile]) : i64
  (match profile
    [(Dev) 0]
    [(Release) build-package-release-opt-level]))

(define (build-package-default-opt-level) : i64
  (build-profile-default-opt-level (build-default-profile)))

(define (build-parse-profile [value : String]) : ResultBuildProfile
  (if (string.eq value "dev")
    (Ok (Dev))
    (if (string.eq value "release")
      (Ok (Release))
      (Err (build-unknown-profile value)))))

(define (build-package-lock-policy-provided? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(Default) false]
    [_ true]))

(define (build-package-lock-policy-locked? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(Locked) true]
    [_ false]))

(define (build-package-lock-policy-update? [policy : BuildPackageLockPolicy]) : bool
  (match policy
    [(Update) true]
    [_ false]))

(define (build-package-lock-policy-option-error) : String
  "build: package lock policy was provided more than once")

(define (build-package-lock-policy-arg
  [args : process.ProcessStringList]
  [policy : BuildPackageLockPolicy]) : process.ProcessStringList
  (match policy
    [(Locked) (build_run_core.source-tool-args-append args "--locked")]
    [(Update) (build_run_core.source-tool-args-append args "--update-lock")]
    [(Default) args]))

;; Options a package build accepts.
(define (build-package-cli-options) : String
  (str_cat.str-cat
    "--cfg <name> --stdlib-root <dir> --target <target> --opt-level <0|1|2|s> -Os
     --debug|-g|--backtrace -o <exe> --manifest-path <file> --backend-mode <mode>
     --profile <dev|release> --release --locked --update-lock "
    (tli_cli.tli-sysroot-cli-options)))

(define (build-config-from [idx : i64] [count : i64]) : ResultBuildConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args "build" (build-package-cli-options) idx count)]
    [has-source : bool false]
    [has-output : bool false]
    [manifest : String ""]
    [has-manifest : bool false]
    [profile : BuildProfile (build-default-profile)]
    [has-profile : bool false]
    [lock-policy : BuildPackageLockPolicy (Default)]
    [sysroot : tli_cli.TliSysrootOptions (tli_cli.tli-sysroot-options)]
    [options : cli_option.CliCompileOptions
      (cli_option.cli-compile-options
        (target_cfg.compiler-target-cfg-host)
        (build-package-default-opt-level))]
    (while (cli_option.cli-args-next! (&mut args))
      (cond
        [(tli_cli.tli-sysroot-option! (&mut sysroot) (&mut args)) unit]
        [(cli_option.cli-compile-option! (&mut options) (&mut args)) unit]
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
            [(Err message) (cli_option.cli-args-fail! (&mut args) message)]
            [(Ok parsed-profile)
              (set! profile parsed-profile)
              (set! has-profile true)])]
        [(string.eq args.name "--release")
          (set! profile (Release))
          (set! has-profile true)]
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
                (Locked)
                (Update))))]
        [(cli_option.cli-flag? args.arg)
          (cli_option.cli-args-fail-arg! (&mut args) "build: unknown flag ")]
        [has-source
          (cli_option.cli-args-fail!
            (&mut args)
            "build: accepts only one source file")]
        [else (set! has-source true)]))
    (unless
      args.failed
      (let
        [sysroot-error : String
          (tli_cli.tli-build-sysroot-error (& sysroot) options.target)]
        (when
          (> (string.string-length (& sysroot-error)) 0)
          (cli_option.cli-args-fail! (&mut args) sysroot-error))))
    (unless
      args.failed
      (ir.compiler-debug-info-set-enabled! options.debug)
      (tli_cli.tli-set-active-sysroot-options! (& sysroot)))
    (cond
      [args.failed (Err args.error)]
      [(and has-source has-manifest)
        (Err "build: cannot combine a source file with --manifest-path")]
      [has-source (Ok (Source))]
      [has-output (Err "build: -o requires a source file argument")]
      [else
        (Ok
          (Package
            manifest
            has-manifest
            (cli_option.cli-option-target-name options.target)
            options.has-target
            (cli_option.cli-option-backend-mode-name options.backend-mode)
            profile
            options.has-opt-level
            (if options.has-opt-level
              options.opt-level
              (build-profile-default-opt-level profile))
            lock-policy
            options.stdlib-roots
            options.cfgs))])))

;; Parse the private `--package-worker` / `--package-doctest-worker` protocol.
(define (build-package-worker-config-from [idx : i64] [count : i64]) : ResultBuildPackageWorkerConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "build"
        (str_cat.str-cat
          "--cfg <name> --stdlib-root <dir> --target <target> --opt-level <0|1|2|s> -Os
           --debug|-g|--backtrace --manifest-path <file> --backend-mode <mode>
           --profile <dev|release> --release --locked --update-lock --resolved-dep "
          (tli_cli.tli-sysroot-cli-options))
        idx
        count)]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [profile : BuildProfile (build-default-profile)]
    [lock-policy : BuildPackageLockPolicy (Default)]
    [resolved-deps : load.CompilerPkgDepList (load.compiler-pkg-dep-list-empty)]
    [sysroot : tli_cli.TliSysrootOptions (tli_cli.tli-sysroot-options)]
    [options : cli_option.CliCompileOptions
      (cli_option.cli-compile-options
        (target_cfg.compiler-target-cfg-host)
        (build-package-default-opt-level))]
    (while (cli_option.cli-args-next! (&mut args))
      (cond
        [(tli_cli.tli-sysroot-option! (&mut sysroot) (&mut args)) unit]
        [(cli_option.cli-compile-option! (&mut options) (&mut args)) unit]
        [(string.eq args.name "--manifest-path")
          (set! manifest-path (cli_option.cli-args-value (& args)))
          (set! has-manifest true)]
        ;; A profile also selects its default opt level unless --opt-level
        ;; already chose one.
        [(string.eq args.name "--profile")
          (match (build-parse-profile (cli_option.cli-args-value (& args)))
            [(Err message) (cli_option.cli-args-fail! (&mut args) message)]
            [(Ok parsed-profile)
              (unless
                options.has-opt-level
                (set!
                  options.opt-level
                  (build-profile-default-opt-level parsed-profile)))
              (set! profile parsed-profile)])]
        [(string.eq args.name "--release")
          (unless
            options.has-opt-level
            (set! options.opt-level (build-profile-default-opt-level (Release))))
          (set! profile (Release))]
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
                (Locked)
                (Update))))]
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
                  (& resolved-deps)
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
    (unless
      args.failed
      (ir.compiler-debug-info-set-enabled! options.debug)
      (tli_cli.tli-set-active-sysroot-options! (& sysroot)))
    (cond
      [args.failed (Err args.error)]
      [has-manifest
        (Ok
          (BuildPackageWorkerConfig
            manifest-path
            has-manifest
            (build_run_core.source-tool-backend-target options.target)
            (build_run_core.source-tool-backend-mode options.backend-mode)
            profile
            options.opt-level
            lock-policy
            options.stdlib-roots
            options.cfgs
            resolved-deps))]
      [else (Err "build: --package-worker requires --manifest-path")])))

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
      (& (byte_buf.to-string (io.read-file manifest-path))))
      [(Ok manifest) (Ok manifest)]
      [(Err diag) (Err (build-invalid-manifest-message (deref diag)))])
    (Err (str_cat.str-cat "cannot read package manifest '" manifest-path "'"))))

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
  [target : be_state.CompilerBackendTarget]) : String
  (build-package-obj-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-obj-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : be_state.CompilerBackendTarget]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat
      name
      "."
      (build_run_core.source-tool-object-extension target))))

(define (build-package-bin-path
  [manifest-dir : String]
  [name : String]
  [target : be_state.CompilerBackendTarget]) : String
  (build-package-bin-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-bin-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : be_state.CompilerBackendTarget]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat
      name
      (build_run_core.source-tool-executable-extension target))))

(define (build-package-lib-path
  [manifest-dir : String]
  [name : String]
  [target : be_state.CompilerBackendTarget]) : String
  (build-package-lib-path-profile
    manifest-dir
    name
    (build-default-profile)
    target))

(define (build-package-lib-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]
  [target : be_state.CompilerBackendTarget]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (build_run_core.source-tool-static-library-filename name target)))

(define (build-package-tli-path-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : String
  (load.compiler-load-join-root-path
    (build-package-output-dir-profile manifest-dir "" profile)
    (str_cat.str-cat name ".tli")))

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
  [target : be_state.CompilerBackendTarget]) : String
  (match kind
    [(CompilerPkgKindBin)
      (build-package-bin-path-profile manifest-dir name profile target)]
    [(CompilerPkgKindLib)
      (build-package-lib-path-profile manifest-dir name profile target)]))

(define (build-package-artifact-paths
  [manifest-dir : String]
  [name : String]
  [kind : load.CompilerPkgKind]
  [profile : BuildProfile]
  [target : be_state.CompilerBackendTarget]) : BuildPackageArtifactPaths
  (BuildPackageArtifactPaths
    (build-package-artifact-path-profile
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view name)
      kind
      profile
      target)
    (if (build-package-kind-lib? kind)
      (build-package-tli-path-profile
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view name)
        profile)
      "")
    (if (build-package-kind-lib? kind)
      (build-package-tlci-path-profile manifest-dir name profile)
      "")))

(define (build-package-runtime-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  artifacts.runtime)

(define (build-package-tli-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  artifacts.tli)

(define (build-package-host-tlci-artifact-path
  [artifacts : BuildPackageArtifactPaths]) : String
  artifacts.tlci)

(define (build-package-artifact-state-dirty?
  [state : BuildPackageArtifactState]) : bool
  (match state
    [(Clean) false]
    [_ true]))

(define (build-package-artifact-state-render
  [state : BuildPackageArtifactState]) : String
  (match state
    [(Clean) "clean"]
    [(Missing) "missing"]
    [(Stale reason) reason]))

(define (build-package-artifact-file-state [path : String]) : BuildPackageArtifactState
  (let
    [path-text : String path]
    (match (fs.try-file-metadata (& path-text))
      [(OkFsMetadata metadata)
        (if (fs.file-kind-regular? (fs.metadata-kind metadata))
          (Clean)
          (Stale "not a regular file"))]
      [(ErrFsMetadata _) (Missing)])))

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
  (if (load.compiler-load-github-dependency-path?
    (& (string.copy declared.path)))
    (Fetched declared.alias (build-package-dep-root manifest-dir resolved))
    (Local)))

(define (build-package-validate-fetched-checkout-before-manifest
  [provenance : BuildPackageSourceProvenance]) : ResultBuildString
  (match provenance
    [(Local) (Ok "")]
    [(Fetched alias checkout-root)
      (let
        [_
          (try
            (package_source_core.package-source-confined-existing-file
              alias
              "manifest"
              "typelisp.pkg"
              checkout-root))]
        (Ok ""))]))

(define (build-package-validate-fetched-checkout
  [provenance : BuildPackageSourceProvenance]
  [manifest : load.CompilerPkgManifest]) : ResultBuildString
  (match provenance
    [(Local) (Ok "")]
    [(Fetched _ checkout-root)
      (let
        [_
          (try
            (package_source_core.package-source-confined-existing-file
              (owned_view.compiler-owned-shared-view manifest.name)
              "entry"
              manifest.entry
              (owned_view.compiler-owned-shared-view checkout-root)))]
        (let
          [_
            (try
              (package_source_core.package-source-fetched-checkout-audit
                manifest.name
                checkout-root))]
          (Ok "")))]))

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
      (Err (build-git-dep-error alias "has invalid normalized path"))
      (let
        [remote : String (string.substring (& path) 0 hash)]
        [pin : String (string.substring (& path) (+ hash 1) (- n (+ hash 1)))]
        [pin-len : i64 (string.string-length pin)]
        [eq : i64 (build-string-index-from (& pin) '=' 0 pin-len)]
        (if (<= eq 0)
          (Err (build-git-dep-error alias "has invalid pin"))
          (let
            [kind : String (string.substring (& pin) 0 eq)]
            [value : String
              (string.substring (& pin) (+ eq 1) (- pin-len (+ eq 1)))]
            [kind-for-check : String (string.copy (& kind))]
            (if (= (string.string-length value) 0)
              (Err (build-git-dep-error alias "has empty pin"))
              (if (load.compiler-load-github-pin-kind-valid? kind-for-check)
                (Ok (BuildGitDependency remote kind value))
                (Err (build-git-dep-error alias "has invalid pin kind"))))))))))

(define (build-git-dep-pin-kind
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : package_cache_core.ResultPackageCachePinKind
  (let
    [kind : String (string.copy (& dep.pin-kind))]
    (cond
      [(string.eq kind "rev") (Ok (Rev))]
      [(string.eq kind "tag") (Ok (Tag))]
      [(string.eq kind "branch") (Ok (Branch))]
      [else (Err (build-git-dep-error alias "has invalid pin kind"))])))

(define (build-package-lock-path [manifest-dir : String]) : String
  (load.compiler-load-join-root-path
    manifest-dir
    (package_lock_core.package-lock-file-name)))

(define (build-load-package-lock [manifest-dir : String]) : ResultBuildPackageLockState
  (let
    [path : String (build-package-lock-path manifest-dir)]
    (match (package_lock_core.package-lock-transaction-read (string.copy path))
      [(Err message) (Err (str_cat.str-cat "build: " message))]
      [(Ok snapshot)
        (if snapshot.existed
          (match (package_lock_core.package-lock-parse
            (& (string.copy snapshot.source)))
            [(Err message)
              (Err
                (str_cat.str-cat
                  "build: invalid package lock '"
                  path
                  "': "
                  message))]
            [(Ok lock)
              (Ok
                (BuildPackageLockState path lock.entries true snapshot.source))])
          (Ok
            (BuildPackageLockState path (package_lock_entry_vec.new) false "")))])))

(define (build-write-package-lock
  [state : BuildPackageLockState]
  [entries : package_lock_entry_vec.Vec]) : ResultBuildString
  (let
    [lock : package_lock_core.PackageLockFile
      (package_lock_core.PackageLockFile
        (package_lock_core.package-lock-version-shared-view)
        entries)]
    [text : String (package_lock_core.package-lock-emit (& lock))]
    [path : String state.path]
    [snapshot : package_lock_core.PackageLockSnapshot
      (package_lock_core.PackageLockSnapshot
        (string.copy path)
        state.original-source
        state.has-lock)]
    (match (package_lock_core.package-lock-transaction-commit snapshot text)
      [(Ok _) (Ok path)]
      [(Err message) (Err (str_cat.str-cat "build: " message))])))

(define (build-package-lock-entry-matches?
  [entry : package_lock_core.PackageLockEntry]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : bool
  (match (build-git-dep-pin-kind
    (owned_view.compiler-owned-shared-view alias)
    dep)
    [(Err _) false]
    [(Ok kind)
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
    [(No) (No)]
    [(Some entry)
      (if (build-package-lock-entry-matches?
        (owned_view.compiler-owned-shared-view entry)
        alias
        dep)
        (Some entry)
        (No))]))

(define (build-package-lock-entry-status
  [entries : package_lock_entry_vec.Vec]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : BuildPackageLockEntryStatus
  (match (package_lock_core.package-lock-entry-list-lookup entries alias)
    [(No) (Missing)]
    [(Some entry)
      (if (build-package-lock-entry-matches?
        (owned_view.compiler-owned-shared-view entry)
        alias
        dep)
        (Matched entry)
        (Stale))]))

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
  (let
    [kind
      (try
        (build-git-dep-pin-kind
          (owned_view.compiler-owned-shared-view alias)
          dep))]
    (Ok
      (package_lock_core.PackageLockEntry
        alias
        (string.copy (& dep.remote))
        kind
        (string.copy (& dep.pin-value))
        commit))))

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
    [(OkProcessOutput output)
      (if (process.success? output)
        (Ok (process.output-stdout output))
        (Err
          (str_cat.str-cat
            context
            " failed with status "
            (string.int->string (process.output-status output))
            (build-process-output-detail output))))]
    [(ErrProcessOutput error)
      (Err (str_cat.str-cat context ": " (process.error-message error)))]))

(define (build-git-clone-command [remote : String] [root : String]) : process.ProcessCommand
  (build_run_core.source-tool-git-clone-command remote root))

(define (build-git-checkout-command [root : String] [checkout-ref : String]) : process.ProcessCommand
  (build_run_core.source-tool-git-checkout-command root checkout-ref))

(define (build-git-rev-parse-command [root : String]) : process.ProcessCommand
  (build_run_core.source-tool-git-local-rev-parse-command root "HEAD"))

;; --git-dir/--work-tree override GIT_DIR/GIT_WORK_TREE, including Windows
;; case variants. These other repository-routing variables have no equivalent
;; CLI override. Refuse them before any dependency Git child can touch a repo.
(define (build-run-git-dependency
  [context : String]
  [command : process.ProcessCommand]) : ResultBuildString
  (let
    [redirect : String
      (cond
        [(env.var-exists? "GIT_COMMON_DIR") "GIT_COMMON_DIR"]
        [(env.var-exists? "GIT_INDEX_FILE") "GIT_INDEX_FILE"]
        [(env.var-exists? "GIT_OBJECT_DIRECTORY") "GIT_OBJECT_DIRECTORY"]
        [(env.var-exists? "GIT_ALTERNATE_OBJECT_DIRECTORIES")
          "GIT_ALTERNATE_OBJECT_DIRECTORIES"]
        [(env.var-exists? "GIT_SHALLOW_FILE") "GIT_SHALLOW_FILE"]
        [(env.var-exists? "GIT_GRAFT_FILE") "GIT_GRAFT_FILE"]
        [(env.var-exists? "GIT_REPLACE_REF_BASE") "GIT_REPLACE_REF_BASE"]
        [(env.var-exists? "GIT_NAMESPACE") "GIT_NAMESPACE"]
        [else ""])]
    (if (> (string.string-length redirect) 0)
      (Err
        (str_cat.str-cat
          context
          " refused inherited "
          redirect
          "; unset it to keep dependency Git metadata local"))
      (build-run-captured context command))))

(define (build-trim-command-output [output : String]) : String
  (string.trim (& output)))

(define (build-resolve-git-head [alias : String] [root : String]) : ResultBuildString
  (let
    [output
      (try
        (build-run-git-dependency
          (build-git-dep-error alias "git rev-parse")
          (build-git-rev-parse-command root)))]
    [commit : String (build-trim-command-output output)]
    (if (package_cache_core.package-cache-canonical-commit? (& commit))
      (Ok commit)
      (Err
        (build-git-dep-error
          alias
          (str_cat.str-cat
            "git rev-parse HEAD reported non-canonical commit `"
            commit
            "`; expected a full lowercase hexadecimal object ID (40 or 64 digits)"))))))

(define (build-verify-git-head
  [alias : String]
  [root : String]
  [expected : (& expected str)]) : ResultBuildString
  (let
    [observed (try (build-resolve-git-head (string.copy (& alias)) root))]
    (if (string.eq (& observed) expected)
      (Ok observed)
      (Err
        (build-git-dep-error
          alias
          (str_cat.str-cat
            "checkout commit mismatch: expected `"
            (string.copy expected)
            "`, observed `"
            observed
            "`"))))))

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
        (Err (build-git-dep-error alias "could not create target directory"))]
      [(not (build-mkdir-ok-owned? (string.copy typelisp-dir)))
        (Err
          (build-git-dep-error
            alias
            "could not create target/typelisp directory"))]
      [(not (build-mkdir-ok-owned? (string.copy deps-dir)))
        (Err
          (build-git-dep-error
            alias
            "could not create target/typelisp/git-deps directory"))]
      [else (Ok deps-dir)])))

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
        (Err (build-git-dep-error alias "could not create target directory"))]
      [(not (build-mkdir-ok-owned? (string.copy typelisp-dir)))
        (Err
          (build-git-dep-error
            alias
            "could not create target/typelisp directory"))]
      [(not (build-mkdir-ok-owned? (string.copy cache-dir)))
        (Err
          (build-git-dep-error
            alias
            "could not create target/typelisp/cache directory"))]
      [(not (build-mkdir-ok-owned? (string.copy packages-dir)))
        (Err
          (build-git-dep-error
            alias
            "could not create target/typelisp/cache/packages directory"))]
      [(not (build-mkdir-ok-owned? (string.copy root)))
        (Err
          (build-git-dep-error
            alias
            "could not create target/typelisp/cache/packages/v1 directory"))]
      [else (Ok root)])))

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
    (Err (build-git-dep-error alias "package cache has no free staging path"))
    (let
      [staged : String
        (package_cache_core.package-cache-staging-path root key attempt)]
      (if (io.file-exists? (owned_view.compiler-owned-shared-view staged))
        (build-package-cache-staging-path alias root key (+ attempt 1))
        (Ok staged)))))

(define (build-package-cache-conflict-backup-path
  [entry-path : String]
  [attempt : i64]) : String
  (str_cat.str-cat entry-path ".corrupt." (string.int->string attempt)))

(define (build-package-cache-move-conflict-attempt
  [alias : String]
  [entry-path : String]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 16)
    (Err
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
          [(OkIoUnit) (Ok backup)]
          [(ErrIoUnit error)
            (Err
              (build-package-cache-io-error
                alias
                "package cache move corrupt entry"
                error))])))))

(define (build-package-cache-move-conflict
  [alias : String]
  [entry-path : String]) : ResultBuildString
  (if (io.file-exists? (owned_view.compiler-owned-shared-view entry-path))
    (build-package-cache-move-conflict-attempt alias entry-path 1)
    (Ok entry-path)))

(define (build-package-cache-hit-result
  [alias : String]
  [entry-path : (& entry-path str)]
  [relative-entry-root : String]) : ResultBuildString
  (if (io.file-exists? (build-package-cache-manifest-path entry-path))
    (Ok relative-entry-root)
    (Err (build-git-dep-error alias "cached package is missing typelisp.pkg"))))

(define (build-package-cache-finalize-staged
  [alias : String]
  [staged-path : String]
  [entry-path : (& entry-path str)]
  [relative-entry-root : String]
  [key : (& key package_cache_core.PackageCacheKey)]) : ResultBuildString
  (match (package_cache_core.package-cache-finalize-staged
    staged-path
    entry-path)
    [(OkIoUnit) (Ok relative-entry-root)]
    [(ErrIoUnit error)
      (match (package_cache_core.package-cache-entry-state entry-path key)
        [(CompleteHit _)
          (build-package-cache-hit-result alias entry-path relative-entry-root)]
        [_
          (Err
            (build-package-cache-io-error alias "package cache finalize" error))])]))

(define (build-package-cache-write-marker
  [alias : String]
  [staged-path : String]
  [key : (& key package_cache_core.PackageCacheKey)]) : ResultBuildString
  (match (package_cache_core.package-cache-write-complete-marker
    staged-path
    key)
    [(OkIoUnit) (Ok staged-path)]
    [(ErrIoUnit error)
      (Err
        (build-package-cache-io-error alias "package cache write marker" error))]))

(define (build-package-cache-prepare-entry-parents-result
  [alias : String]
  [root : String]
  [key : (& key package_cache_core.PackageCacheKey)]) : ResultBuildString
  (match (package_cache_core.package-cache-prepare-entry-parents root key)
    [(OkIoUnit) (Ok root)]
    [(ErrIoUnit error)
      (Err
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
    [(ErrIoUnit error)
      (Err
        (build-package-cache-io-error
          alias
          "package cache prepare staging"
          error))]
    [(OkIoUnit)
      (let
        [staged-path
          (try
            (build-package-cache-staging-path
              (owned_view.compiler-owned-shared-view alias)
              root
              key
              1))]
        [_
          (try
            (build-run-git-dependency
              (build-git-dep-error alias "git clone")
              (build-git-clone-command
                (string.copy (& dep.remote))
                (owned_view.compiler-owned-shared-view staged-path))))]
        (let
          [_
            (try
              (build-run-git-dependency
                (build-git-dep-error alias "git checkout")
                (build-git-checkout-command
                  (owned_view.compiler-owned-shared-view staged-path)
                  (build-git-checkout-ref dep))))]
          (let
            [_
              (try
                (build-verify-git-head
                  (string.copy (& alias))
                  (string.copy (& staged-path))
                  (& key.commit)))]
            (if (not
              (io.file-exists?
                (build-package-cache-manifest-path (& staged-path))))
              (Err
                (build-git-dep-error
                  alias
                  "fetched package is missing typelisp.pkg"))
              (let
                [_
                  (try
                    (build-package-cache-write-marker
                      (owned_view.compiler-owned-shared-view alias)
                      (owned_view.compiler-owned-shared-view staged-path)
                      key))]
                (let
                  [_
                    (try
                      (build-package-cache-prepare-entry-parents-result
                        (owned_view.compiler-owned-shared-view alias)
                        root
                        key))]
                  (let
                    [_
                      (try
                        (if replace-existing
                          (build-package-cache-move-conflict
                            (owned_view.compiler-owned-shared-view alias)
                            (owned_view.compiler-owned-shared-view entry-path))
                          (ResultBuildString.Ok
                            (owned_view.compiler-owned-shared-view entry-path))))]
                    (build-package-cache-finalize-staged
                      alias
                      staged-path
                      entry-path
                      relative-entry-root
                      key))))))))]))

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
      [(CompleteHit _)
        (if (io.file-exists? (build-package-cache-manifest-path (& entry-path)))
          (Ok relative-entry-root)
          (let
            [_
              (try
                (build-ensure-package-cache-root
                  manifest-dir
                  (owned_view.compiler-owned-shared-view alias)))]
            (build-package-cache-fetch-staged
              alias
              dep
              root
              (& key)
              entry-path
              relative-entry-root
              true)))]
      [(Miss _)
        (let
          [_
            (try
              (build-ensure-package-cache-root
                manifest-dir
                (owned_view.compiler-owned-shared-view alias)))]
          (build-package-cache-fetch-staged
            alias
            dep
            root
            (& key)
            entry-path
            relative-entry-root
            false))]
      [(PartialOrCorrupt _ _)
        (let
          [_
            (try
              (build-ensure-package-cache-root
                manifest-dir
                (owned_view.compiler-owned-shared-view alias)))]
          (build-package-cache-fetch-staged
            alias
            dep
            root
            (& key)
            entry-path
            relative-entry-root
            true))])))

(define (build-git-clone-if-needed
  [manifest-dir : String]
  [alias : String]
  [dep : (& dep BuildGitDependency)]
  [root : String]) : ResultBuildString
  (if (io.file-exists?
    (build-github-cache-git-dir
      manifest-dir
      (owned_view.compiler-owned-shared-view alias)))
    (Ok root)
    (build-run-git-dependency
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
      (Ok manifest-path)
      (let
        [_
          (try
            (build-ensure-github-cache-parent
              manifest-dir
              (owned_view.compiler-owned-shared-view alias)))]
        (let
          [_
            (try
              (build-git-clone-if-needed
                manifest-dir
                (owned_view.compiler-owned-shared-view alias)
                dep
                (owned_view.compiler-owned-shared-view root)))]
          (let
            [_
              (try
                (build-run-git-dependency
                  (build-git-dep-error alias "git checkout")
                  (build-git-checkout-command
                    (owned_view.compiler-owned-shared-view root)
                    (build-git-checkout-ref dep))))]
            (let
              [_ (try (build-resolve-git-head (string.copy (& alias)) root))]
              (if (io.file-exists? manifest-path)
                (Ok (build-github-dep-relative-root alias))
                (Err
                  (build-git-dep-error
                    alias
                    "fetched package is missing typelisp.pkg"))))))))))

(define (build-fetch-github-dependency
  [manifest-dir : String]
  [alias : String]
  [dep : (& dep BuildGitDependency)]) : ResultBuildString
  (if (not
    (build-github-cache-needs-git?
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view alias)))
    (Ok (build-github-dep-relative-root alias))
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
    [dep-root
      (try
        (build-fetch-github-dependency-cached manifest-dir alias (& locked-dep)))]
    (Ok (BuildResolvedGitDependency dep-root entry))))

(define (build-resolve-github-dependency-without-lock
  [manifest-dir : String]
  [alias : String]
  [dep : BuildGitDependency]) : ResultBuildResolvedGitDependency
  (let
    [dep-root
      (try
        (build-fetch-github-dependency
          (owned_view.compiler-owned-shared-view manifest-dir)
          (owned_view.compiler-owned-shared-view alias)
          (& dep)))]
    [commit-result : ResultBuildString
      (if (build-git-dep-rev? (& dep))
        (Ok (string.copy (& dep.pin-value)))
        (build-resolve-git-head
          (owned_view.compiler-owned-shared-view alias)
          (build-absolute-dep-root
            manifest-dir
            (owned_view.compiler-owned-shared-view dep-root))))]
    [commit (try commit-result)]
    [entry (try (build-package-lock-entry alias (& dep) commit))]
    (Ok (BuildResolvedGitDependency dep-root entry))))

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
        [(Matched entry)
          (build-resolve-github-dependency-from-lock
            manifest-dir
            alias
            dep
            entry)]
        [(Missing) (Err (build-package-lock-missing-message alias))]
        [(Stale) (Err (build-package-lock-stale-message alias))])
      (match (build-package-lock-matching-entry
        lock-entries
        (owned_view.compiler-owned-shared-view alias)
        (& dep))
        [(Some entry)
          (build-resolve-github-dependency-from-lock
            manifest-dir
            alias
            dep
            entry)]
        [(No)
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
    (if (load.compiler-load-github-dependency-path? (& path-for-kind))
      (let
        [parse-alias : String
          (string.substring alias 0 (string.string-length alias))]
        [parse-path : String (string.copy (& path))]
        [git-dep (try (build-parse-git-dependency parse-alias parse-path))]
        [resolved
          (try
            (build-resolve-github-dependency
              manifest-dir
              (owned_view.compiler-owned-shared-view alias)
              git-dep
              lock-entries
              lock-policy))]
        (Ok
          (BuildResolvedPkgDep
            (load.CompilerPkgDep alias resolved.dep-root)
            (Some resolved.lock-entry))))
      (Ok (BuildResolvedPkgDep (load.CompilerPkgDep alias path) (No))))))

(define (build-package-lock-entry-list-add
  [entries : package_lock_entry_vec.Vec]
  [maybe-entry : BuildMaybeLockEntry]) : package_lock_core.ResultPackageLockEntryList
  (match maybe-entry
    [(No) (Ok entries)]
    [(Some entry)
      (package_lock_core.package-lock-entry-list-insert entries entry)]))

(define (build-package-lock-list-has-exact-entry?
  [entries : (& entries package_lock_entry_vec.Vec)]
  [entry : (& entry package_lock_core.PackageLockEntry)]) : bool
  (package_lock_core.package-lock-list-has-entry?
    entries
    (string.copy (& entry.alias))
    (string.copy (& entry.url))
    (package_lock_core.package-lock-pin-kind-copy (& entry.pin-kind))
    (string.copy (& entry.pin-value))
    (string.copy (& entry.commit))))

(define (build-package-lock-list-contains-all?
  [haystack : package_lock_entry_vec.Vec]
  [needles : (& needles package_lock_entry_vec.Vec)]) : bool
  (build-package-lock-list-contains-all-from haystack (& needles)))

(define (build-package-lock-list-contains-all-from
  [haystack : (& haystack package_lock_entry_vec.Vec)]
  [needles : (& needles package_lock_entry_vec.Vec)]) : bool
  (let
    [view : (& needles (Slice package_lock_core.PackageLockEntry))
      (package_lock_entry_vec.view needles)]
    (for [index (iterator.range 0 (array-length view))]
      (unless
        (build-package-lock-list-has-exact-entry?
          haystack
          (& (array-ref view index)))
        (return false))
      unit))
  true)

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
      (Err
        "build: --locked requires typelisp.lock for remote dependencies; run with --update-lock to refresh typelisp.lock")
      (if (and
        lock-state.has-lock
        (not
          (build-package-lock-list-eq? lock-state.entries resolved.lock-entries)))
        (Err
          "build: package lock is stale; run with --update-lock to refresh typelisp.lock")
        (Ok "")))
    (Ok "")))

(define (build-package-maybe-write-lock
  [policy : BuildPackageLockPolicy]
  [lock-state : BuildPackageLockState]
  [resolved : BuildResolvedPkgDeps]) : ResultBuildString
  (if (and
    (not (build-package-lock-policy-locked? policy))
    (or resolved.has-remote lock-state.has-lock))
    (build-write-package-lock lock-state resolved.lock-entries)
    (Ok "")))

(define (build-package-resolve-deps-with-lock
  [manifest-dir : String]
  [lock-entries : package_lock_entry_vec.Vec]
  [lock-policy : BuildPackageLockPolicy]
  [deps : load.CompilerPkgDepList]
  [index : i64]) : ResultBuildResolvedPkgDeps
  (if (>= index (load.compiler-pkg-dep-list-count deps))
    (Ok
      (BuildResolvedPkgDeps
        (load.compiler-pkg-dep-list-empty)
        (package_lock_entry_vec.new)
        false))
    (let
      [resolved-dep
        (try
          (build-package-resolve-dep-with-lock
            (owned_view.compiler-owned-shared-view manifest-dir)
            (owned_view.compiler-owned-shared-view lock-entries)
            lock-policy
            (load.compiler-pkg-dep-list-at deps index)))]
      [resolved-rest
        (try
          (build-package-resolve-deps-with-lock
            manifest-dir
            lock-entries
            lock-policy
            deps
            (+ index 1)))]
      [next-lock-entries
        (try
          (build-package-lock-entry-list-add
            resolved-rest.lock-entries
            (owned_view.compiler-owned-shared-view resolved-dep.lock-entry)))]
      (Ok
        (BuildResolvedPkgDeps
          (load.compiler-pkg-dep-list-cons
            resolved-dep.dep
            (& resolved-rest.deps))
          next-lock-entries
          (or
            resolved-rest.has-remote
            (match resolved-dep.lock-entry
              [(No) false]
              [(Some _) true])))))))

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
        [(NoDependency) (Ok manifest)]
        [(Dependency dep)
          (Err
            (str_cat.str-cat
              "build: "
              (load.compiler-pkg-library-dependency-message
                manifest.name
                dep.alias)))])]
    [(CompilerPkgKindBin)
      (let
        [manifest-dir : String (load.compiler-load-dirname manifest-path)]
        [lock-state
          (try
            (build-load-package-lock
              (owned_view.compiler-owned-shared-view manifest-dir)))]
        [resolved
          (try
            (build-package-resolve-deps-with-lock
              manifest-dir
              (owned_view.compiler-owned-shared-view lock-state.entries)
              lock-policy
              (load.compiler-pkg-deps-list manifest.deps)
              0))]
        [_
          (try
            (build-package-lock-policy-check
              lock-policy
              (owned_view.compiler-owned-shared-view lock-state)
              resolved))]
        (let
          [_
            (try
              (build-package-maybe-write-lock
                lock-policy
                lock-state
                (owned_view.compiler-owned-shared-view resolved)))]
          (Ok
            (load.CompilerPkgManifest
              manifest.name
              manifest.version
              manifest.kind
              manifest.entry
              (load.compiler-pkg-deps-from-list resolved.deps)
              manifest.link))))]))

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
  [v : (& v BuildPackageGraphNodeVec)]
  [index : i64]) : BuildPackageGraphNode
  (let
    [v : BuildPackageGraphNodeVec
      (owned_view.compiler-owned-reference-shared-view v)]
    (owned_view.compiler-owned-element-view v.slots index)))

(define (build-package-graph-node-vec-copy-range!
  [dst : (&mut dst (__tl_dyn-array BuildPackageGraphNode))]
  [src : (__tl_dyn-array BuildPackageGraphNode)]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (build-package-graph-node-vec-grow [v : BuildPackageGraphNodeVec]) : BuildPackageGraphNodeVec
  (let
    [count : i64 (build-package-graph-node-vec-len v)]
    [bigger : (__tl_dyn-array BuildPackageGraphNode)
      (__tl_make-array
        BuildPackageGraphNode
        (* (build-package-graph-node-vec-capacity v) 2))]
    (build-package-graph-node-vec-copy-range! (&mut bigger) v.slots count)
    (BuildPackageGraphNodeVec bigger count)))

(define (build-package-graph-node-vec-push
  [v : BuildPackageGraphNodeVec]
  [node : BuildPackageGraphNode]) : BuildPackageGraphNodeVec
  (if (<
    (build-package-graph-node-vec-len v)
    (build-package-graph-node-vec-capacity v))
    (let
      [slots : (__tl_dyn-array BuildPackageGraphNode)
        (owned_view.compiler-owned-shared-view v.slots)]
      (set! (array-ref slots (build-package-graph-node-vec-len v)) node)
      (BuildPackageGraphNodeVec
        slots
        (+ (build-package-graph-node-vec-len v) 1)))
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
  (set! state.order (build-package-graph-node-vec-push state.order node))
  state)

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
    [_
      (try
        (build-package-validate-fetched-checkout-before-manifest
          (owned_view.compiler-owned-shared-view provenance)))]
    (match (build-load-manifest
      (owned_view.compiler-owned-shared-view dep-manifest-path))
      [(Err message)
        (Err (str_cat.str-cat "dependency `" resolved-dep.alias "`: " message))]
      [(Ok dep-manifest)
        (let
          [_
            (try
              (build-package-validate-fetched-checkout
                (owned_view.compiler-owned-shared-view provenance)
                (owned_view.compiler-owned-shared-view dep-manifest)))]
          (if (not (build-package-kind-lib? dep-manifest.kind))
            (Err
              (str_cat.str-cat
                "build: dependency `"
                resolved-dep.alias
                "` at "
                dep-manifest-path
                " must be a staticlib package"))
            ;; Do not resolve or read the acquired library's lock. Its
            ;; dependency-free invariant is checked when the node enters
            ;; the graph below.
            (Ok
              (BuildPackageGraphNode dep-manifest-path dep-manifest provenance))))])))

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
    [(Dependency dep)
      (Err (build-package-acquired-library-dependency-message (& node) dep))]
    [(NoDependency)
      (let
        [manifest-path : String (string.copy node.manifest-path)]
        (match (build_string_i64_map.get
          (& state.seen)
          (owned_view.compiler-owned-shared-view manifest-path))
          [(LookupFound _) (Ok state)]
          [(LookupMissing)
            (Ok
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
    (Ok state)
    (let
      [node
        (try
          (build-package-load-dep-node
            (owned_view.compiler-owned-shared-view manifest-dir)
            (load.compiler-pkg-dep-list-at (& declared-deps) index)
            (load.compiler-pkg-dep-list-at (& resolved-deps) index)))]
      [next-state (try (build-package-graph-add-node node state))]
      (build-package-graph-add-deps
        manifest-dir
        declared-deps
        resolved-deps
        (+ index 1)
        next-state))))

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
    [state
      (try
        (build-package-graph-add-deps
          root-dir
          (load.compiler-pkg-deps-list declared-manifest.deps)
          (load.compiler-pkg-deps-list resolved-manifest.deps)
          0
          initial))]
    (Ok (BuildPackageGraph state.order))))

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
        (owned_view.compiler-owned-shared-view manifest-dir))]
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
    [output
      (try
        (build-run-captured
          "build: cannot resolve root compiler source identity"
          (build_run_core.source-tool-git-rev-parse-command
            (string.copy repo-root)
            "HEAD")))]
    [identity : String (build-trim-command-output output)]
    [tree-output
      (try
        (build-run-captured
          "build: cannot resolve root compiler source tree"
          (build_run_core.source-tool-git-rev-parse-command
            repo-root
            "HEAD^{tree}")))]
    [tree : String (build-trim-command-output tree-output)]
    (cond
      [(not
          (and
            (tlci.tlci-producer-identity-valid? identity)
            (tlci.tlci-producer-identity-valid? tree)))
        (Err
          "build: root compiler source identity is not a full Git object name")]
      [(not (build-mkdir-ok-owned? (string.copy target-dir)))
        (Err
          (str_cat.str-cat
            "build: failed to create root compiler identity directory "
            target-dir))]
      [(not (build-mkdir-ok-owned? (string.copy identity-dir)))
        (Err
          (str_cat.str-cat
            "build: failed to create root compiler identity directory "
            identity-dir))]
      [else
        (let
          [_
            (try
              (build_run_core.source-tool-write-file
                identity-path
                (string.copy identity)
                "build: failed to write root compiler identity"))]
          [_
            (try
              (build_run_core.source-tool-write-file
                (load.compiler-load-join-root-path identity-dir "tree-hash.txt")
                tree
                "build: failed to write root compiler tree identity"))]
          (Ok identity))])))

(define (build-package-compile-context
  [manifest-dir : String]
  [manifest : (& manifest load.CompilerPkgManifest)]) : BuildPackageCompileContext
  (if (build-package-root-compiler?
    (owned_view.compiler-owned-shared-view manifest-dir)
    manifest)
    (match (build-package-refresh-root-compiler-identity manifest-dir)
      [(Err message) (BuildPackageCompileContext true message)]
      [(Ok _) (BuildPackageCompileContext true "")])
    (BuildPackageCompileContext false "")))

(define (build-package-compile-cfgs
  [target : be_state.CompilerBackendTarget]
  [root-compiler : bool]
  [cfg-names : (& cfg-names cli_svec.Vec)]) : sym_i64_env.SymI64Env
  (let
    [cfgs : sym_i64_env.SymI64Env
      (compiler_driver_core.compiler-driver-target-cfgs
        target
        (target_cfg.compiler-target-user-cfgs cfg-names))]
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

;; The declaration of a link input: its package, and the manifest field when
;; there is one.
(define (build-package-link-declared-by [owner : String] [field : String]) : String
  (if (= (string.string-length field) 0)
    owner
    (str_cat.str-cat owner " field `" field "`")))

;; `package `NAME` (MANIFEST)`, the owner of a manifest's link inputs.
(define (build-package-link-owner [name : String] [manifest-path : String]) : String
  (str_cat.str-cat "package `" name "` (" manifest-path ")"))

;; Record the origin of every value of one `(link ...)` field.
(define (build-package-link-add-field-origins
  [inputs : build_run_core.SourceToolLinkInputs]
  [kind : String]
  [manifest-dir : String]
  [owner : String]
  [field : String]
  [vec : (& vec fs.FsStringVector)]) : build_run_core.SourceToolLinkInputs
  (let
    [out : build_run_core.SourceToolLinkInputs inputs]
    (for [index (iterator.range 0 (fs.string-vector-len vec))]
      (let
        [value : String (fs.string-vector-get vec index "")]
        (set!
          out
          (build_run_core.source-tool-link-inputs-add-origin
            out
            (owned_view.compiler-owned-shared-view kind)
            (if (string.eq (& kind) "search-path")
              (build-package-link-resolve-search-path
                (owned_view.compiler-owned-shared-view manifest-dir)
                value)
              value)
            (build-package-link-declared-by
              (owned_view.compiler-owned-shared-view owner)
              (owned_view.compiler-owned-shared-view field))))))
    out))

(define (build-package-link-add-set-origins
  [inputs : build_run_core.SourceToolLinkInputs]
  [manifest-dir : String]
  [owner : String]
  [prefix : String]
  [set : load.CompilerPkgLinkSet]) : build_run_core.SourceToolLinkInputs
  (build-package-link-add-field-origins
    (build-package-link-add-field-origins
      (build-package-link-add-field-origins
        inputs
        "library"
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view owner)
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view prefix)
          "libraries")
        (& set.libraries))
      "search-path"
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view owner)
      (str_cat.str-cat
        (owned_view.compiler-owned-shared-view prefix)
        "search-paths")
      (& set.search-paths))
    "arg"
    manifest-dir
    owner
    (str_cat.str-cat prefix "args")
    (& set.args)))

(define (build-package-link-add-libs
  [inputs : build_run_core.SourceToolLinkInputs]
  [vec : (& vec fs.FsStringVector)]
  [idx : i64]) : build_run_core.SourceToolLinkInputs
  (if (>= idx (fs.string-vector-len vec))
    inputs
    (build-package-link-add-libs
      (build_run_core.source-tool-link-inputs-add-ast
        inputs
        (Lib (fs.string-vector-get vec idx "")))
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
        (Search
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
        (Arg (fs.string-vector-get vec idx "")))
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
;: `owner` names the declaring package in every input's origin record.
(define (build-package-manifest-link-inputs
  [link : load.CompilerPkgLink]
  [manifest-dir : String]
  [owner : String]
  [target : be_state.CompilerBackendTarget]) : build_run_core.SourceToolLinkInputs
  (let
    [selected : load.CompilerPkgLinkSet
      (match target
        [(Linux) link.linux]
        [(Windows) link.windows])]
    [prefix : String
      (match target
        [(Linux) "linux-"]
        [(Windows) "windows-"])]
    (build-package-link-add-set-origins
      (build-package-link-add-set-origins
        (build-package-link-add-set
          (build-package-link-add-set
            (build_run_core.source-tool-link-inputs-empty)
            (owned_view.compiler-owned-shared-view manifest-dir)
            (owned_view.compiler-owned-shared-view link.all))
          (owned_view.compiler-owned-shared-view manifest-dir)
          (owned_view.compiler-owned-shared-view selected))
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view owner)
        ""
        link.all)
      manifest-dir
      owner
      prefix
      selected)))

(define (build-package-artifact-status
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [direct-status : build_run_core.SourceToolDirectObjectStatus]) : build_run_core.SourceToolCommandStatus
  (match direct-status
    [(Ok) Ok]
    [(Err message) (Err message)]
    [(Unavailable _)
      (match kind
        [(CompilerPkgKindBin)
          (let
            [tli-archive : String
              (compiler_driver_core.compiler-driver-last-hydrated-archive-path)]
            [effective-link-inputs : build_run_core.SourceToolLinkInputs
              (if (> (string.string-length (& tli-archive)) 0)
                (build_run_core.source-tool-link-inputs-add-archive
                  link-inputs
                  tli-archive)
                link-inputs)]
            (build_run_core.source-tool-assemble-and-link
              target
              asm-path
              obj-path
              artifact-path
              effective-link-inputs))]
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
      [(CompilerPkgKindBin) Bin]
      [(CompilerPkgKindLib) StaticLib])
    image))

(define (build-package-write-direct-object-artifact
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
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

(define (build-package-direct-object-mode?
  [mode : be_state.CompilerBackendMode]) : bool
  (match mode
    [(Scalar) true]
    [_ false]))

(define (build-package-decl-has-spmd-callable? [decl : ast.AstDecl]) : bool
  (match decl
    [(DefFn _ _ _ _ _ metadata)
      (match metadata
        [(SpmdCallable _) true]
        [_ false])]
    [(Unsafe inner)
      (build-package-decl-has-spmd-callable?
        (ast.ast-decl-box-shared-view inner))]
    [_ false]))

(define (build-package-decls-have-spmd-callable? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
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
  [target : be_state.CompilerBackendTarget]
  [path-budget : i64]
  [linux-budget-override : bool]
  [paths : (& paths ast.AstDeclPathList)]) : bool
  (match target
    [(Linux)
      (or
        linux-budget-override
        (<= (build-package-direct-object-owned-path-count paths) path-budget))]
    [(Windows)
      (<= (build-package-direct-object-owned-path-count paths) path-budget)]))

(defenum BuildPackageDirectObjectPreflight
  (Eligible)
  (Fallback be_state.CompilerDirectObjectFallbackReason))

(define (build-package-direct-object-preflight
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]
  [debug-info : bool]
  [path-budget : i64]
  [linux-budget-override : bool]
  [decls : ast.AstDeclList]
  [paths : (& paths ast.AstDeclPathList)]) : BuildPackageDirectObjectPreflight
  (cond
    ;; COFF archive production remains on the assembler path.
    [(match target
        [(Linux) false]
        [(Windows)
          (match kind
            [(CompilerPkgKindBin) false]
            [(CompilerPkgKindLib) true])])
      (Fallback
        (ArtifactKindUnavailable
          target
          (match kind
            [(CompilerPkgKindBin) Bin]
            [(CompilerPkgKindLib) StaticLib])))]
    [debug-info (Fallback DebugMetadata)]
    [(not (build-package-direct-object-mode? mode)) (Fallback BackendMode)]
    [(build-package-decls-have-spmd-callable? decls) (Fallback PrivateSpmdAbi)]
    [(not
        (build-package-direct-object-size-ok?
          target
          path-budget
          linux-budget-override
          paths))
      (Fallback
        (ResourceBudget
          (build-package-direct-object-owned-path-count paths)
          path-budget))]
    [else Eligible]))

(define (build-package-emit-assembly-fallback
  [entry-path : String]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [lowered : compiler_driver_core.ResultCompilerDriverLowered]
  [reason : be_state.CompilerDirectObjectFallbackReason]) : ResultBuildPackagePreparedRuntime
  (match (compiler_driver_core.compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
    entry-path
    lowered
    target
    true
    mode
    opt-level
    emit-entry
    crt-entry
    false)
    [(Err diag advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))
      (Err
        (compiler_driver_core.compiler-driver-render-source-diagnostic
          (deref diag)))]
    [(Ok asm advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))
      (Assembly asm reason)]))

;; Route policy is resolved while source declarations are live. Emission owns
;; one lowered result and cannot re-enter package loading or lowering.
(define (build-package-emit-preflighted-runtime
  [entry-path : String]
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [preflight : BuildPackageDirectObjectPreflight]
  [lowered : compiler_driver_core.ResultCompilerDriverLowered]) : ResultBuildPackagePreparedRuntime
  (match preflight
    [(Eligible)
      (match target
        [(Linux)
          (match (compiler_driver_core.compiler-driver-emit-lowered-result-package-runtime-with-level-mode-entry-and-crt
            entry-path
            lowered
            target
            mode
            opt-level
            emit-entry
            crt-entry)
            [(Object image asm advisories)
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (match (build-package-render-linux-direct-object kind image)
                [(Ok object) (DirectObject object asm)]
                [(Fallback reason) (Assembly asm reason)])]
            [(Assembly asm category advisories)
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (Assembly asm category)]
            [(Err diag advisories)
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (Err
                (compiler_driver_core.compiler-driver-render-source-diagnostic
                  (deref diag)))])]
        [(Windows)
          ;; The shared Windows batch emitter owns the semantic gate as well as
          ;; the COFF encoding/linkability checks. Its Assembly result is an
          ;; intentional, stable fallback rather than a compilation failure.
          (match (compiler_windows_coff_core.compiler-windows-batch-emit-lowered-result
            entry-path
            lowered
            mode
            opt-level
            emit-entry
            false
            true)
            [(CoffObject object side-assembly advisories)
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (match side-assembly
                [(None)
                  (Err
                    "build: package COFF preparation omitted required side assembly")]
                [(Some asm) (DirectObject object asm)])]
            [(Assembly asm category advisories)
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (Assembly (text_buf.render asm) category)]
            [(Err diag advisories)
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (Err
                (compiler_driver_core.compiler-driver-render-source-diagnostic
                  (deref diag)))])])]
    [(Fallback reason)
      (build-package-emit-assembly-fallback
        entry-path
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
  [target : be_state.CompilerBackendTarget]) : BuildPackageArtifactPaths
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
  [target : be_state.CompilerBackendTarget]) : String
  (build-package-runtime-artifact-path
    (build-package-graph-node-artifact-paths node profile target)))

(define (build-package-validate-graph-checkouts-from
  [nodes : BuildPackageGraphNodeVec]) : ResultBuildString
  (for [index (iterator.range 0 (build-package-graph-node-vec-len nodes))]
    (let
      [_
        (try
          (build-package-validate-graph-node-checkout
            (build-package-graph-node-vec-at nodes index)))]
      unit))
  (Ok ""))

(define (build-package-validate-graph-checkouts
  [nodes : BuildPackageGraphNodeVec]) : ResultBuildString
  (build-package-validate-graph-checkouts-from nodes))

;; A fetched dependency's relative search paths must stay inside its locked
;; checkout (#6998); absolute search paths are system locations, used as written.
(define (build-package-link-confine-search-paths
  [node : BuildPackageGraphNode]
  [field : String]
  [vec : (& vec fs.FsStringVector)]) : ResultBuildString
  (match node.provenance
    [(Local) (Ok "")]
    [(Fetched _ checkout-root)
      (let
        [index : i64 0]
        [result : ResultBuildString (Ok "")]
        (while (< index (fs.string-vector-len vec))
          (let
            [value : String (fs.string-vector-get vec index "")]
            (if (load.compiler-load-absolute-path? value)
              unit
              (match (package_source_core.package-source-confined-existing-path
                (owned_view.compiler-owned-shared-view node.manifest.name)
                (owned_view.compiler-owned-shared-view field)
                value
                (owned_view.compiler-owned-shared-view checkout-root)
                (Directory))
                [(Err message)
                  (set! result (Err message))
                  (set! index (fs.string-vector-len vec))]
                [(Ok _) unit]))
            (+= index 1)))
        result)]))

;; The dependency section of a binary's link (#6982): every direct
;; dependency's static archive, and the native requirements its `(link ...)`
;; section declares for `target`, anchored at that dependency's manifest.
;; Libraries, search paths and archives merge once; raw arguments stay with
;; each package (source-tool-link-inputs-merge-with).
(define (build-package-graph-link-inputs
  [nodes : BuildPackageGraphNodeVec]
  [profile : BuildProfile]
  [target : be_state.CompilerBackendTarget]) : build_run_core.ResultSourceToolLinkInputs
  (let
    [index : i64 (- (build-package-graph-node-vec-len nodes) 1)]
    [out : build_run_core.SourceToolLinkInputs
      (build_run_core.source-tool-link-inputs-empty)]
    [error : String ""]
    (while (>= index 0)
      (let
        [node : BuildPackageGraphNode
          (build-package-graph-node-vec-at nodes index)]
        [link : load.CompilerPkgLink node.manifest.link]
        [selected : load.CompilerPkgLinkSet
          (match target
            [(Linux) (owned_view.compiler-owned-shared-view link.linux)]
            [(Windows) (owned_view.compiler-owned-shared-view link.windows)])]
        [owner : String
          (build-package-link-owner
            (owned_view.compiler-owned-shared-view node.manifest.name)
            (owned_view.compiler-owned-shared-view node.manifest-path))]
        [archive : String
          (build-package-graph-node-artifact-path
            (owned_view.compiler-owned-shared-view node)
            profile
            target)]
        (match (build-package-link-confine-search-paths
          (owned_view.compiler-owned-shared-view node)
          "search-paths"
          (& link.all.search-paths))
          [(Err message) (set! error message)]
          [(Ok _)
            (match (build-package-link-confine-search-paths
              (owned_view.compiler-owned-shared-view node)
              (match target
                [(Linux) "linux-search-paths"]
                [(Windows) "windows-search-paths"])
              (& selected.search-paths))
              [(Err message) (set! error message)]
              [(Ok _) unit])])
        (set!
          out
          (let
            [force-source? : bool
              (cfg
                dependency-tlci-verification
                (compiler_dependency_tlci.compiler-dependency-tlci-verification-force-source?)
                false)]
            [manifest-inputs : build_run_core.SourceToolLinkInputs
              (build-package-manifest-link-inputs
                link
                (load.compiler-load-dirname
                  (owned_view.compiler-owned-shared-view node.manifest-path))
                owner
                target)]
            [node-inputs : build_run_core.SourceToolLinkInputs
              (if force-source?
                manifest-inputs
                (build_run_core.source-tool-link-inputs-merge
                  (build_run_core.source-tool-link-inputs-add-origin
                    (build_run_core.source-tool-link-inputs-from-archives
                      (process.args-single
                        (owned_view.compiler-owned-shared-view archive)))
                    "archive"
                    archive
                    (owned_view.compiler-owned-shared-view owner))
                  manifest-inputs))]
            (build_run_core.source-tool-link-inputs-merge-with
              out
              node-inputs
              false)))
        (set!
          index
          (if (> (string.string-length error) 0)
            -1
            (- index 1)))))
    (if (> (string.string-length error) 0)
      (Err error)
      (Ok out))))

(define (build-package-catalog-dep-root
  [manifest-dir : String]
  [dep : load.CompilerPkgDep]) : String
  (load.compiler-load-canonical-path
    (&
      (if (load.compiler-load-absolute-path? dep.path)
        dep.path
        (load.compiler-load-join-root-path
          manifest-dir
          (owned_view.compiler-owned-shared-view dep.path))))))

(define (build-package-catalog-deps-contain-root?
  [deps : (& deps load.CompilerPkgDepList)]
  [count : i64]
  [manifest-dir : String]
  [root : (& root str)]) : bool
  (let
    [found : bool false]
    (for [index (iterator.range 0 count)]
      (if (string.eq
        (build-package-catalog-dep-root
          (owned_view.compiler-owned-shared-view manifest-dir)
          (load.compiler-pkg-dep-list-at (& deps) index))
        root)
        (set! found true)
        unit))
    found))

(define (build-package-graph-catalog-deps
  [nodes : BuildPackageGraphNodeVec]
  [manifest-dir : String]
  [direct-deps : load.CompilerPkgDepList]) : load.CompilerPkgDepList
  (let
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [direct-count : i64 (load.compiler-pkg-dep-list-count (& direct-deps))]
    [deps : load.CompilerPkgDepList direct-deps]
    (for [index (iterator.range 0 count)]
      (let
        [node : BuildPackageGraphNode
          (build-package-graph-node-vec-at nodes index)]
        [root : String
          (load.compiler-load-canonical-path
            (& (load.compiler-load-dirname node.manifest-path)))]
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
              (& deps)
              (load.CompilerPkgDep node.manifest.name root))))))
    deps))

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
  [manifest : (& manifest load.CompilerPkgManifest)]
  [callables : tlci.TlciSpmdCallables]) : tlci.TlciMetadata
  (if (= (tlci.tlci-spmd-callables-len callables) 0)
    (tlci.tlci-make-metadata
      "v1"
      (string.copy (& manifest.name))
      (string.copy (& manifest.version)))
    (tlci.tlci-make-metadata-v2
      (string.copy (& manifest.name))
      (string.copy (& manifest.version))
      callables)))

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
    (while (< scan count)
      (let
        [order : i64
          (tlci.tlci-spmd-specialization-compare
            item
            (& (tlci.tlci-spmd-specializations-ref items scan)))]
        (cond
          [(= order 0)
            (set! duplicate true)
            (set! scan count)]
          [(< order 0)
            (set! position scan)
            (set! scan count)]
          [else (+= scan 1)])))
    (if duplicate
      items
      (let
        [dst : tlci.TlciSpmdSpecializations
          (tlci.tlci-spmd-specializations-with-capacity (+ count 1))]
        [cursor : i64 0]
        (while (< cursor position)
          (tlci.tlci-spmd-specializations-push!
            (&mut dst)
            (& (tlci.tlci-spmd-specializations-ref items cursor)))
          (+= cursor 1))
        (tlci.tlci-spmd-specializations-push! (&mut dst) (& item))
        (while (< cursor count)
          (tlci.tlci-spmd-specializations-push!
            (&mut dst)
            (& (tlci.tlci-spmd-specializations-ref items cursor)))
          (+= cursor 1))
        dst))))

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
    (while (< scan count)
      (if (<
        (tlci.tlci-spmd-callable-compare
          item
          (& (tlci.tlci-spmd-callables-ref items scan)))
        0)
        (begin
          (set! position scan)
          (set! scan count))
        (+= scan 1)))
    (while (< cursor position)
      (tlci.tlci-spmd-callables-push!
        (&mut dst)
        (& (tlci.tlci-spmd-callables-ref items cursor)))
      (+= cursor 1))
    (tlci.tlci-spmd-callables-push! (&mut dst) (& item))
    (while (< cursor count)
      (tlci.tlci-spmd-callables-push!
        (&mut dst)
        (& (tlci.tlci-spmd-callables-ref items cursor)))
      (+= cursor 1))
    dst))

(define (build-package-tlci-backend [mode : be_state.CompilerBackendMode]) : ir.CompilerIrSpmdBackend
  (match mode
    [(Scalar) Scalar]
    [(Avx2) Avx2]
    [(Avx512) Avx512]))

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
          Unit
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
          [(Scalar) 1]
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
          (be_state.compiler-backend-user-symbol-id logical-symbol-id))]
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
  [mode : be_state.CompilerBackendMode]) : tlci.TlciSpmdCallable
  (let
    [canonical-name : String
      (csym.compiler-symbol-module-key
        (if (= (string.string-length module) 0)
          (owned_view.compiler-owned-shared-view package-name)
          module)
        (ci.intern-str name))]
    [signature : String (lower.lower-spmd-source-signature params ret)]
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

(define (build-package-tlci-effective-module
  [module : (& str)]
  [package-name : (& str)]
  [manifest-dir : (& str)]
  [stdlib-roots : (& cli_svec.Vec)]
  [decl-path : (& str)]) : String
  (if (> (string.string-length module) 0)
    (string.copy module)
    (let
      [owned : String
        (load.compiler-load-package-owned-path
          (string.copy package-name)
          manifest-dir
          stdlib-roots
          (string.copy decl-path))]
      [canonical : String
        (load.compiler-load-canonical-module-id-from-path (& owned))]
      (if (> (string.string-length (& canonical)) 0)
        canonical
        (string.copy package-name)))))

(define (build-package-tlci-collect-decl-callable
  [decl : ast.AstDecl]
  [owned-path : String]
  [module : String]
  [package-name : String]
  [manifest-dir : (& str)]
  [stdlib-roots : (& cli_svec.Vec)]
  [mode : be_state.CompilerBackendMode]
  [collector : BuildPackageTlciCallableCollector]) : BuildPackageTlciCallableCollector
  (match decl
    [(DefFn decl-meta name params ret _ metadata)
      (if (= (string.string-length owned-path) 0)
        collector
        (match (ast.ast-fn-metadata-spmd-callable (& metadata))
          [(No) collector]
          [(Callable specializations)
            (if (match mode
              [(Avx2) true]
              [_ false])
              (begin
                (set!
                  collector.error
                  "build: :spmd-callable is not supported with --backend-mode avx2")
                collector)
              (let
                [eff-mod : String
                  (build-package-tlci-effective-module
                    (& module)
                    (& package-name)
                    manifest-dir
                    stdlib-roots
                    (& owned-path))]
                (set!
                  collector.items
                  (build-package-tlci-callable-insert
                    (build-package-tlci-callable
                      package-name
                      eff-mod
                      name
                      params
                      ret
                      specializations
                      mode)
                    collector.items))
                collector))]))]
    [(Unsafe inner-box)
      (build-package-tlci-collect-decl-callable
        (ast.ast-decl-box-shared-view inner-box)
        owned-path
        module
        package-name
        manifest-dir
        stdlib-roots
        mode
        collector)]
    [_ collector]))

(define (build-package-tlci-push-macro-name!
  [out : (&mut out cli_svec.Vec)]
  [name : String]) : bool
  (let
    [index : i64 0]
    [present : bool false]
    (while (and (not present) (< index (cli_svec.len out)))
      (if (string.eq (cli_svec.get out index "") name)
        (set! present true)
        (+= index 1)))
    (if present
      false
      (begin
        (cli_svec.push-ref! out name)
        true))))

(defstruct BuildPackageTlciMacroCollector
  (names (__tl_dyn-array String))
  (captures compiler_tlci_native_producer.TlciNativeMacroCaptures))

(define (build-package-tlci-sort-macro-catalog!
  [catalog : (&mut catalog (__tl_dyn-array String))]) : unit
  (let
    [count : i64 (array-length catalog)]
    (for [index (iterator.range 1 count)]
      (let
        [value : String (string.copy (array-ref catalog index))]
        [slot : i64 index]
        (while (if (> slot 0)
          (package_source_core.package-source-string-less?
            (string.copy value)
            (string.copy (array-ref catalog (- slot 1))))
          false)
          (set!
            (array-ref catalog slot)
            (string.copy (array-ref catalog (- slot 1))))
          (-= slot 1))
        (set! (array-ref catalog slot) value)))))

(define (build-package-tlci-finish-macro-collector
  [names : (&mut names cli_svec.Vec)]
  [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures]) : BuildPackageTlciMacroCollector
  (let
    [count : i64 (cli_svec.len names)]
    [catalog (__tl_make-array String count)]
    (for [index (iterator.range 0 count)]
      (set! (array-ref catalog index) (cli_svec.get names index "")))
    (build-package-tlci-sort-macro-catalog! (&mut catalog))
    (BuildPackageTlciMacroCollector catalog captures)))

(define (build-package-tlci-collect-decl-macro!
  [context : (& context compiler_tlci_native_producer.TlciNativeSourceContext)]
  [decl : ast.AstDecl]
  [owned-path : String]
  [module : String]
  [package-name : String]
  [manifest-dir : (& str)]
  [stdlib-roots : (& cli_svec.Vec)]
  [owned-sources : (& owned-sources build_string_i64_map.Map)]
  [out : (&mut out cli_svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (match decl
    [(DefMacro decl-meta name params ret body)
      (if (= (string.string-length owned-path) 0)
        unit
        (let
          [eff-mod : String
            (build-package-tlci-effective-module
              (& module)
              (& package-name)
              manifest-dir
              stdlib-roots
              (& owned-path))]
          [identity : String
            (csym.compiler-symbol-module-key
              eff-mod
              (ci.intern-compat-state-str context.intern-state name))]
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
                  context
                  ret)
                body)))))]
    [(Unsafe inner-box)
      (build-package-tlci-collect-decl-macro!
        context
        (deref inner-box)
        owned-path
        module
        package-name
        manifest-dir
        stdlib-roots
        owned-sources
        out
        captures)]
    [(ModuleBody nested-module body-box)
      (build-package-tlci-collect-macros-into!
        context
        (deref body-box)
        (ast.ast-decl-path-list-new)
        owned-path
        (ci.intern-compat-state-str context.intern-state nested-module)
        package-name
        manifest-dir
        stdlib-roots
        owned-sources
        out
        captures)]
    [_ unit]))

(define (build-package-tlci-source-map [sources : (& sources cli_svec.Vec)]) : build_string_i64_map.Map
  (let
    [out : build_string_i64_map.Map
      (build_string_i64_map.with-capacity
        (+ (* (cli_svec.len (& sources)) 2) 4))]
    (for [index (iterator.range 0 (cli_svec.len (& sources)))]
      (build_string_i64_map.insert-ref!
        (&mut out)
        (load.compiler-load-normalize-path (cli_svec.get (& sources) index ""))
        1))
    out))

(define (build-package-tlci-source-owned?
  [owned-sources : (& owned-sources build_string_i64_map.Map)]
  [path : (& path str)]) : bool
  (match (build_string_i64_map.get
    (& owned-sources)
    (load.compiler-load-normalize-path path))
    [(LookupFound _) true]
    [(LookupMissing) false]))

(define (build-package-tlci-collect-macros-into!
  [context : (& context compiler_tlci_native_producer.TlciNativeSourceContext)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [initial-module : String]
  [package-name : String]
  [manifest-dir : (& str)]
  [stdlib-roots : (& cli_svec.Vec)]
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
      (match (ast.ast-decl-list-step decl-cursor)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (let
            [decl-path : String
              (match (ast.ast-decl-path-list-step path-cursor)
                [(Nil) (owned_view.compiler-owned-shared-view fallback-path)]
                [(Cons path _) path])]
            [owned-path : String
              (if (build-package-tlci-source-owned? owned-sources decl-path)
                decl-path
                "")]
            (match (owned_view.compiler-owned-shared-view decl)
              [(Module name)
                (set!
                  module
                  (ci.intern-compat-state-str context.intern-state name))]
              [_
                (build-package-tlci-collect-decl-macro!
                  context
                  decl
                  owned-path
                  (owned_view.compiler-owned-shared-view module)
                  (owned_view.compiler-owned-shared-view package-name)
                  manifest-dir
                  stdlib-roots
                  owned-sources
                  out
                  captures)])
            (set! decl-cursor rest)
            (match (ast.ast-decl-path-list-step path-cursor)
              [(Nil) unit]
              [(Cons _ path-rest) (set! path-cursor path-rest)]))]))))

(define (build-package-tlci-macro-collector
  [context : (& context compiler_tlci_native_producer.TlciNativeSourceContext)]
  [source-set : (& source-set package_source_core.PackageSourceSet)]
  [manifest : (& manifest load.CompilerPkgManifest)]
  [stdlib-roots : (& cli_svec.Vec)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : BuildPackageTlciMacroCollector
  (let
    [out : cli_svec.Vec (cli_svec.new)]
    [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
      (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
    [owned-sources : build_string_i64_map.Map
      (build-package-tlci-source-map source-set.sources)]
    (build-package-tlci-collect-macros-into!
      context
      decls
      paths
      ""
      ""
      (string.copy (& manifest.name))
      (& source-set.manifest-dir)
      stdlib-roots
      owned-sources
      (&mut out)
      (&mut captures))
    (build-package-tlci-finish-macro-collector (&mut out) captures)))

(define (build-package-tlci-collect-callables-into!
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [initial-module : String]
  [package-name : String]
  [manifest-dir : (& str)]
  [stdlib-roots : (& cli_svec.Vec)]
  [mode : be_state.CompilerBackendMode]
  [owned-sources : (& owned-sources build_string_i64_map.Map)]
  [collector : BuildPackageTlciCallableCollector]) : BuildPackageTlciCallableCollector
  (let
    [decl-cursor : ast.AstDeclList decls]
    [path-cursor : ast.AstDeclPathList paths]
    [module : String initial-module]
    [done : bool false]
    [current : BuildPackageTlciCallableCollector collector]
    (while (and (not done) (= (string.string-length current.error) 0))
      (match (ast.ast-decl-list-step decl-cursor)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (let
            [decl-path : String
              (match (ast.ast-decl-path-list-step path-cursor)
                [(Nil) (owned_view.compiler-owned-shared-view fallback-path)]
                [(Cons path _) path])]
            [owned-path : String
              (if (build-package-tlci-source-owned? owned-sources decl-path)
                decl-path
                "")]
            (match (owned_view.compiler-owned-shared-view decl)
              [(Module name) (set! module (ci.intern-str name))]
              [(ModuleBody nested-module body-box)
                (set!
                  current
                  (build-package-tlci-collect-callables-into!
                    (ast.ast-decl-list-box-shared-view body-box)
                    (ast.ast-decl-path-list-new)
                    owned-path
                    (ci.intern-str nested-module)
                    (owned_view.compiler-owned-shared-view package-name)
                    manifest-dir
                    stdlib-roots
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
                    manifest-dir
                    stdlib-roots
                    mode
                    current))])
            (set! decl-cursor rest)
            (match (ast.ast-decl-path-list-step path-cursor)
              [(Nil) unit]
              [(Cons _ path-rest) (set! path-cursor path-rest)]))]))
    current))

(define (build-package-tlci-callable-collector
  [source-set : (& source-set package_source_core.PackageSourceSet)]
  [manifest : (& manifest load.CompilerPkgManifest)]
  [stdlib-roots : (& cli_svec.Vec)]
  [mode : be_state.CompilerBackendMode]
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
      (string.copy (& manifest.name))
      (& source-set.manifest-dir)
      stdlib-roots
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
  (defenum BuildPackageTlciSourceInputs
    (Image package_source_core.PackageSourceSet i64)
    (NoImage)))

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
      (Err "build: exact producer compiler identity is unavailable")
      (let
        [source-set
          (try
            (package_source_core.package-source-discover-for
              "build"
              manifest-path
              true))]
        (match (package_source_core.package-source-set-digest
          (owned_view.compiler-owned-shared-view source-set))
          [(Err message)
            (Err
              (str_cat.str-cat
                "build: failed to compute package source digest: "
                message))]
          [(Ok digest) (Ok (Image source-set digest))])))))

;; Only canonical text and owned catalog strings cross runtime lowering. Native
;; captures themselves contain AST pool indices and must remain inside capture.
(defenum ResultBuildPackageTlciExports
  (Ok String (__tl_dyn-array String) String bool)
  (Err String))

(define (clone-result-build-package-tlci-exports
  [value : (& value ResultBuildPackageTlciExports)]) : ResultBuildPackageTlciExports
  (match value
    [(Ok metadata names native-source has-spmd)
      (let
        [count : i64 (array-length names)]
        [dst : (__tl_dyn-array String) (__tl_make-array String count)]
        (for [index (iterator.range 0 count)]
          (set! (array-ref dst index) (string.copy (& (array-ref names index)))))
        (Ok (string.copy metadata) dst (string.copy native-source) has-spmd))]
    [(Err message) (Err (string.copy message))]))

(define (build-package-tlci-capture-exports
  [context : (& context compiler_tlci_native_producer.TlciNativeSourceContext)]
  [manifest : (& manifest load.CompilerPkgManifest)]
  [stdlib-roots : (& cli_svec.Vec)]
  [mode : be_state.CompilerBackendMode]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [source-set : (& source-set package_source_core.PackageSourceSet)]) : ResultBuildPackageTlciExports
  ;; The clone-out copies the native report strings before this arena ends.
  (with-scratch
    (unsafe
      (build-package-tlci-collect-exports
        context
        manifest
        stdlib-roots
        mode
        decls
        paths
        source-set))))

(define (build-package-tlci-collect-exports
  [context : (& context compiler_tlci_native_producer.TlciNativeSourceContext)]
  [manifest : (& manifest load.CompilerPkgManifest)]
  [stdlib-roots : (& cli_svec.Vec)]
  [mode : be_state.CompilerBackendMode]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [source-set : (& source-set package_source_core.PackageSourceSet)]) : ResultBuildPackageTlciExports
  (let
    [collector : BuildPackageTlciCallableCollector
      (build-package-tlci-callable-collector
        source-set
        manifest
        stdlib-roots
        mode
        (owned_view.compiler-owned-shared-view decls)
        (owned_view.compiler-owned-shared-view paths))]
    [macro-collector : BuildPackageTlciMacroCollector
      (build-package-tlci-macro-collector
        context
        source-set
        manifest
        stdlib-roots
        decls
        paths)]
    [names : (__tl_dyn-array String) macro-collector.names]
    [has-spmd : bool (> (tlci.tlci-spmd-callables-len (& collector.items)) 0)]
    (if (> (string.string-length collector.error) 0)
      (Err collector.error)
      (Ok
        (tlci.tlci-metadata-emit
          (& (build-package-tlci-metadata manifest collector.items)))
        (owned_view.compiler-owned-shared-view names)
        (if (= (array-length names) 0)
          ""
          (compiler_tlci_native_producer.embedded-native-source
            context
            names
            (& macro-collector.captures)))
        has-spmd))))

(defenum BuildPackageTlciEmitted
  (NoTlci)
  (SomeTlci String (Array u8 32))
  (Err String))

(define (build-package-bytes-sha256 [bytes : (& (__tl_dyn-array u8))]) : (Array
    u8
    32)
  (let
    [st : sha256.Sha256State (sha256.new)]
    [n : i64 (array-length (deref bytes))]
    (when
      (> n 0)
      (unsafe
        (let
          [_ : sha256.Sha256UpdateResult
            (sha256.update-from-pointer!
              (&mut st)
              (ptr-cast (__tl_array-data (deref bytes)) : (Ptr u8))
              n)]
          unit)))
    (match (sha256.finalize! (&mut st))
      [(Sha256FinalizeOk digest) (sha256.digest-bytes (& digest))]
      [_ (make-array u8 32)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-tlci-emit-optional
    [exports : ResultBuildPackageTlciExports]
    [producer-identity : String]
    [source-digest : i64]) : BuildPackageTlciEmitted
    (match exports
      [(Err message) (BuildPackageTlciEmitted.Err message)]
      [(Ok metadata-text names native-source has-spmd)
        (if (and (= (array-length names) 0) (not has-spmd))
          (BuildPackageTlciEmitted.NoTlci)
          (let
            [sections : (__tl_dyn-array tlci.TlciAuxSection)
              (__tl_make-array
                (tlci.tlci-package-source-binding-section source-digest))]
            (match (tlci.tlci-aux-pack-rodata
              (& (tlci.tlci-empty-bytes))
              sections)
              [(Err message)
                (BuildPackageTlciEmitted.Err
                  (str_cat.str-cat
                    "build: failed to pack package source binding: "
                    message))]
              [(Ok rodata)
                (if (= (array-length names) 0)
                  (match (tlci.tlci-metadata-parse (& metadata-text))
                    [(Err message)
                      (BuildPackageTlciEmitted.Err
                        (str_cat.str-cat
                          "build: captured package metadata rejected: "
                          message))]
                    [(Ok metadata)
                      (match (tlci.tlci-emit-image
                        (&
                          (build-package-tlci-image
                            metadata
                            producer-identity
                            rodata)))
                        [(Err message)
                          (BuildPackageTlciEmitted.Err
                            (str_cat.str-cat
                              "build: failed to emit package tlci: "
                              message))]
                        [(Ok bytes)
                          (let
                            [digest : (Array u8 32)
                              (build-package-bytes-sha256 (& bytes))]
                            (BuildPackageTlciEmitted.SomeTlci
                              (tlci.tlci-bytes->string
                                bytes
                                0
                                (array-length bytes))
                              digest))])])
                  (match (compiler_tlci_native_producer.embedded-native-emit-package-source
                    metadata-text
                    producer-identity
                    (cfg windows true false)
                    rodata
                    names
                    native-source)
                    [(Err message)
                      (BuildPackageTlciEmitted.Err
                        (str_cat.str-cat
                          "build: failed to emit package tlci: "
                          message))]
                    [(Ok bytes)
                      (let
                        [digest : (Array u8 32)
                          (build-package-bytes-sha256 (& bytes))]
                        (BuildPackageTlciEmitted.SomeTlci
                          (tlci.tlci-bytes->string bytes 0 (array-length bytes))
                          digest))]))])))])))

(define (build-package-runtime-fingerprint-path [artifact-path : String]) : String
  (str_cat.str-cat artifact-path ".runtime-inputs"))

(define (build-package-file-regular? [path : String]) : bool
  (match (build-package-artifact-file-state path)
    [(Clean) true]
    [_ false]))

(define (build-package-file-text-eq? [path : String] [expected : String]) : bool
  (if (not
    (build-package-file-regular? (owned_view.compiler-owned-shared-view path)))
    false
    (match (io.try-read-file (& path))
      [(OkIoBytes contents) (string.eq (byte_buf.to-string contents) expected)]
      [(ErrIoBytes _) false])))

(define (build-package-file-digest [path : (& path str)] [context : String]) : ResultBuildPackageFileDigest
  (match (io.try-read-file path)
    [(ErrIoBytes error)
      (Err (str_cat.str-cat context ": " (io.error-message error)))]
    [(OkIoBytes contents)
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
        (Ok
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
    [(ErrFsMetadata error)
      (Err (str_cat.str-cat context ": " (io.error-message error)))]
    [(OkFsMetadata metadata)
      (let
        [size : i64 (fs.metadata-size metadata)]
        [sample-size : i64 65536]
        (match (io.file-open path (OpenRead))
          [(ErrIoFile error)
            (Err (str_cat.str-cat context ": " (io.error-message error)))]
          [(OkIoFile handle)
            (let
              [first : (__tl_dyn-array u8) (__tl_make-array u8 0)]
              [last : (__tl_dyn-array u8) (__tl_make-array u8 0)]
              [ok : bool true]
              [error-message : String ""]
              (match (io.file-read-chunk handle sample-size)
                [(ErrIoRead error)
                  (set! ok false)
                  (set! error-message (io.error-message error))]
                [(OkIoRead read)
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
                    [(ErrIoRead error)
                      (set! ok false)
                      (set! error-message (io.error-message error))]
                    [(OkIoRead read)
                      (set! last (byte_buf.to-array (io.file-read-bytes read)))]))
                unit)
              (io.file-close handle)
              (if ok
                (Ok (build-package-sampled-file-digest-text size first last))
                (Err (str_cat.str-cat context ": " error-message))))]))]))

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
    [count : i64 (process.args-count args)]
    [out : String
      (build-package-transcript-field "argc" (string.int->string count))]
    (for [index (iterator.range 0 count)]
      (set!
        out
        (str_cat.str-cat
          out
          (build-package-transcript-field "arg" (process.args-ref args index)))))
    out))

(define (build-package-command-env-transcript [items : process.ProcessEnvList]) : String
  (let
    [count : i64 (process.env-count items)]
    [out : String
      (build-package-transcript-field "envc" (string.int->string count))]
    (for [index (iterator.range 0 count)]
      (set!
        out
        (str_cat.str-cat
          out
          (build-package-transcript-field
            "env-name"
            (process.env-name-ref items index))
          (build-package-transcript-field
            "env-value"
            (process.env-value-ref items index)))))
    out))

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
      (Err
        (str_cat.str-cat
          "build: cannot fingerprint "
          role
          " executable "
          executable))
      (let
        [digest
          (try
            (build-package-tool-file-digest
              executable
              (str_cat.str-cat
                "build: cannot fingerprint "
                (owned_view.compiler-owned-shared-view role)
                " executable")))]
        (Ok
          (str_cat.str-cat
            (build-package-transcript-field "tool-role" role)
            (build-package-transcript-field "tool-path" executable)
            (build-package-transcript-field "tool-digest" digest)
            (build-package-command-args-transcript
              (process.command-argv command))
            (build-package-command-env-transcript (process.command-env command))))))))

(define (build-package-env-transcript-one [name : String]) : String
  (match (env.get (& name))
    [(EnvNoString)
      (build-package-transcript-field
        (str_cat.str-cat "inherited-env-" name)
        "<unset>")]
    [(EnvSomeString value)
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
    (let
      [digest
        (try
          (build-package-file-digest
            path
            "build: cannot fingerprint native link input"))]
      (Ok
        (str_cat.str-cat
          (build-package-transcript-field "link-file-path" path)
          (build-package-transcript-field "link-file-digest" digest))))
    (Ok "")))

;; Digest every raw argument and dependency archive that names a file.
(define (build-package-link-raw-file-transcript
  [inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildString
  (let
    [args : process.ProcessStringList
      (process.args-append
        (build_run_core.source-tool-link-inputs-raw-args inputs)
        (build_run_core.source-tool-link-inputs-archives inputs))]
    [index : i64 0]
    [count : i64 (process.args-count args)]
    [out : String ""]
    [ok : bool true]
    [error : String ""]
    (while (and ok (< index count))
      (let
        [path : String (process.args-ref args index)]
        (match (build-package-link-path-transcript path)
          [(Err message)
            (set! ok false)
            (set! error message)]
          [(Ok text) (set! out (str_cat.str-cat out text))])
        (+= index 1)))
    (if ok
      (Ok out)
      (Err error))))

(define (build-package-link-library-candidate [dir : String] [name : String]) : String
  (if (= (string.string-length dir) 0)
    name
    (load.compiler-load-join-root-path dir name)))

(define (build-package-link-library-file-transcript
  [target : be_state.CompilerBackendTarget]
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
          [(Linux)
            (str_cat.str-cat
              "lib"
              (owned_view.compiler-owned-shared-view library)
              ".a")]
          [(Windows)
            (str_cat.str-cat
              (owned_view.compiler-owned-shared-view library)
              ".lib")]))]
    [second : String
      (build-package-link-library-candidate
        dir
        (match target
          [(Linux) (str_cat.str-cat "lib" library ".so")]
          [(Windows) ""]))]
    [direct-text (try (build-package-link-path-transcript direct))]
    [first-text (try (build-package-link-path-transcript first))]
    (if (= (string.string-length second) 0)
      (Ok (str_cat.str-cat direct-text first-text))
      (let
        [second-text (try (build-package-link-path-transcript second))]
        (Ok (str_cat.str-cat direct-text first-text second-text))))))

(define (build-package-link-library-files-transcript
  [target : be_state.CompilerBackendTarget]
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
    (while (and ok (< library-index library-count))
      (let
        [library : String (process.args-ref libraries library-index)]
        [dir-index : i64 0]
        [dir-count : i64 (process.args-count dirs)]
        (if (= dir-count 0)
          (match (build-package-link-library-file-transcript target "" library)
            [(Err message)
              (set! ok false)
              (set! error message)]
            [(Ok text) (set! out (str_cat.str-cat out text))])
          (while (and ok (< dir-index dir-count))
            (match (build-package-link-library-file-transcript
              target
              (process.args-ref dirs dir-index)
              (owned_view.compiler-owned-shared-view library))
              [(Err message)
                (set! ok false)
                (set! error message)]
              [(Ok text) (set! out (str_cat.str-cat out text))])
            (+= dir-index 1)))
        (+= library-index 1)))
    (if ok
      (Ok out)
      (Err error))))

(define (build-package-link-file-transcript
  [target : be_state.CompilerBackendTarget]
  [inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildString
  (let
    [raw-text
      (try
        (build-package-link-raw-file-transcript
          (owned_view.compiler-owned-shared-view inputs)))]
    [library-text
      (try
        (build-package-link-library-files-transcript
          target
          (owned_view.compiler-owned-shared-view inputs)))]
    (Ok
      (str_cat.str-cat
        raw-text
        library-text
        (build-package-link-origins-transcript inputs)))))

;; Each link input's kind, value and declaring package, manifest and field, in
;; declaration order (source-tool-link-inputs-origins).
(define (build-package-link-origins-transcript
  [inputs : build_run_core.SourceToolLinkInputs]) : String
  (let
    [origins : build_run_core.SourceToolLinkOrigins
      (build_run_core.source-tool-link-inputs-origins inputs)]
    [out : String ""]
    (for [index (iterator.range 0 (process.args-count origins.kinds))]
      (set!
        out
        (str_cat.str-cat
          out
          (build-package-transcript-field
            "native-link"
            (process.args-ref origins.kinds index))
          (build-package-transcript-field
            "native-link-value"
            (process.args-ref origins.values index))
          (build-package-transcript-field
            "native-link-declared-by"
            (process.args-ref origins.declared-by index)))))
    out))

(define (build-package-assembler-command-for
  [target : be_state.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]) : build_run_core.ResultSourceToolCommand
  (match target
    [(Linux)
      (Ok (build_run_core.source-tool-assembler-command asm-path obj-path))]
    [(Windows)
      (Ok
        (build_run_core.source-tool-windows-assembler-command asm-path obj-path))]))

(define (build-package-artifact-command-for
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]) : build_run_core.ResultSourceToolCommand
  (match kind
    [(CompilerPkgKindBin)
      (match target
        [(Linux)
          (Ok
            (build_run_core.source-tool-linker-command
              obj-path
              artifact-path
              link-inputs))]
        [(Windows)
          (build_run_core.source-tool-windows-linker-command
            obj-path
            artifact-path
            link-inputs)])]
    [(CompilerPkgKindLib)
      (match target
        [(Linux)
          (Ok
            (build_run_core.source-tool-archiver-command obj-path artifact-path))]
        [(Windows)
          (build_run_core.source-tool-windows-archiver-command
            obj-path
            artifact-path)])]))

(define (build-package-runtime-input-transcript-after-assembler
  [base : String]
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]) : ResultBuildString
  (let
    [command
      (try
        (build-package-artifact-command-for
          kind
          target
          obj-path
          artifact-path
          (owned_view.compiler-owned-shared-view link-inputs)))]
    [command-text
      (try (build-package-command-transcript "runtime artifact tool" command))]
    (match kind
      [(CompilerPkgKindLib)
        (Ok
          (str_cat.str-cat
            base
            command-text
            (build-package-runtime-inherited-env-transcript)))]
      [(CompilerPkgKindBin)
        (let
          [link-file-text
            (try (build-package-link-file-transcript target link-inputs))]
          (Ok
            (str_cat.str-cat
              base
              command-text
              link-file-text
              (build-package-runtime-inherited-env-transcript))))])))

(define (build-package-bytes-sha256-hex [bytes : (& (__tl_dyn-array u8))]) : String
  (let
    [d : sha256.Sha256Digest
      (sha256.Sha256Digest (build-package-bytes-sha256 bytes))]
    (sha256.to-hex (& d))))

(define (build-package-file-sha256-hex [path : (& str)]) : ResultBuildPackageFileDigest
  (match (io.try-read-file path)
    [(ErrIoBytes error)
      (Err
        (str_cat.str-cat
          "build: cannot hash file "
          (string.copy path)
          ": "
          (io.error-message error)))]
    [(OkIoBytes contents)
      (let
        [bytes : (__tl_dyn-array u8) (byte_buf.to-array contents)]
        (Ok (build-package-bytes-sha256-hex (& bytes))))]))

(define (build-package-target-cfg [target : be_state.CompilerBackendTarget]) : target_cfg.CompilerTargetCfg
  (match target
    [(Linux) (target_cfg.CompilerTargetCfg.Linux)]
    [(Windows) (target_cfg.CompilerTargetCfg.Windows)]))

(define (build-package-collect-dep-tli-fields!
  [manifest-dir : (& str)]
  [deps : (& load.CompilerPkgDeps)]
  [profile : BuildProfile]
  [visited : (&mut build_string_i64_map.Map)]
  [out : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [ordered : load.CompilerPkgDepList
      (load.compiler-pkg-deps-list (load.clone-compiler-pkg-deps deps))]
    [count : i64 (load.compiler-pkg-dep-list-count (& ordered))]
    [buf : text_buf.TextBuf out]
    (for [index (iterator.range 0 count)]
      (let
        [dep : load.CompilerPkgDep
          (load.compiler-pkg-dep-list-at (& ordered) index)]
        [dep-dir : String
          (load.compiler-load-canonical-path
            (&
              (load.compiler-load-join-root-path
                (string.copy manifest-dir)
                (string.copy (& dep.path)))))]
        (match (build_string_i64_map.get visited (string.copy (& dep-dir)))
          [(LookupFound _) unit]
          [(LookupMissing)
            (build_string_i64_map.insert-ref!
              visited
              (string.copy (& dep-dir))
              1)
            (let
              [dep-manifest-path : String
                (fs.path-join (& dep-dir) "typelisp.pkg")]
              (match (build-load-manifest (string.copy (& dep-manifest-path)))
                [(Err _) unit]
                [(Ok dep-manifest)
                  (set!
                    buf
                    (build-package-collect-dep-tli-fields!
                      (& dep-dir)
                      (& dep-manifest.deps)
                      profile
                      visited
                      buf))
                  (let
                    [tli-path : String
                      (build-package-tli-path-profile
                        (string.copy (& dep-dir))
                        (string.copy (& dep-manifest.name))
                        profile)]
                    [digest : String
                      (match (build-package-file-sha256-hex (& tli-path))
                        [(Ok hex) hex]
                        [(Err _) "missing"])]
                    (set!
                      buf
                      (text_buf.append
                        buf
                        (build-package-transcript-field
                          (str_cat.str-cat
                            "dep-tli-sha256:"
                            (string.copy (& dep-dir)))
                          digest))))]))])))
    buf))

(define (build-package-v3-extra-inputs
  [manifest-path : (& str)]
  [manifest-dir : (& str)]
  [manifest : (& load.CompilerPkgManifest)]
  [profile : BuildProfile]
  [target : be_state.CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]
  [sources : (& cli_svec.Vec)]) : ResultBuildString
  (let
    [out : text_buf.TextBuf (text_buf.empty)]
    [cfg-bytes : (Array u8 32) (tli_extract.tli-extract-cfg-digest cfgs)]
    [cfg-digest : sha256.Sha256Digest (sha256.Sha256Digest cfg-bytes)]
    [sysroot : tli_cli.TliSysrootOptions (tli_cli.tli-active-sysroot-options)]
    [stdlib-mode : String
      (cond
        [sysroot.disabled "disabled"]
        [(> (string.string-length (& sysroot.explicit-root)) 0)
          (string.copy (& sysroot.explicit-root))]
        [else "auto"])]
    [stdlib-tli-digest : String
      (match (tli_cli.tli-sysroot-discover
        (& sysroot)
        (build-package-target-cfg target))
        [(Found dir)
          (let
            [bundle-path : String (tli_cli.tli-sysroot-bundle-path (& dir))]
            (match (build-package-file-sha256-hex (& bundle-path))
              [(Ok hex) hex]
              [(Err _) "missing"]))]
        [_ "none"])]
    [manifest-digest : String
      (try (build-package-file-sha256-hex manifest-path))]
    (set!
      out
      (text_buf.append
        out
        (build-package-transcript-field
          "cfg-fingerprint-sha256"
          (sha256.to-hex (& cfg-digest)))))
    (set!
      out
      (text_buf.append
        out
        (build-package-transcript-field "stdlib-mode" stdlib-mode)))
    (set!
      out
      (text_buf.append
        out
        (build-package-transcript-field "stdlib-tli-sha256" stdlib-tli-digest)))
    (set!
      out
      (text_buf.append
        out
        (build-package-transcript-field
          "force-source"
          (if (compiler_dependency_tlci.compiler-dependency-tlci-force-source?)
            "true"
            "false"))))
    (set!
      out
      (text_buf.append
        out
        (build-package-transcript-field "manifest-sha256" manifest-digest)))
    (for [i (iterator.range 0 (cli_svec.len sources))]
      (let
        [src : String (cli_svec.get sources i "")]
        [src-digest : String (try (build-package-file-sha256-hex (& src)))]
        (set!
          out
          (text_buf.append
            out
            (build-package-transcript-field
              (str_cat.str-cat "source-sha256:" src)
              src-digest)))))
    (let
      [visited : build_string_i64_map.Map
        (build_string_i64_map.with-capacity 16)]
      (set!
        out
        (build-package-collect-dep-tli-fields!
          manifest-dir
          (& manifest.deps)
          profile
          (&mut visited)
          out)))
    (Ok (text_buf.render out))))

(define (build-package-runtime-input-transcript
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [producer-identity : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [direct-object : bool]
  [extra-v3 : String]) : ResultBuildString
  (let
    [base : String
      (str_cat.str-cat
        "typelisp-package-runtime-inputs-v3\n"
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
            "false"))
        extra-v3)]
    (if direct-object
      (build-package-runtime-input-transcript-after-assembler
        base
        kind
        target
        obj-path
        artifact-path
        link-inputs)
      (let
        [assembler
          (try
            (build-package-assembler-command-for
              target
              asm-path
              (owned_view.compiler-owned-shared-view obj-path)))]
        [assembler-text
          (try (build-package-command-transcript "assembler" assembler))]
        (build-package-runtime-input-transcript-after-assembler
          (str_cat.str-cat base assembler-text)
          kind
          target
          obj-path
          artifact-path
          link-inputs)))))

(define (build-package-lib-input-transcript
  [target : be_state.CompilerBackendTarget]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [producer-identity : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [extra-v3 : String]) : ResultBuildString
  (build-package-runtime-input-transcript
    (load.CompilerPkgKind.CompilerPkgKindLib)
    target
    profile
    mode
    opt-level
    producer-identity
    asm-path
    obj-path
    artifact-path
    (build_run_core.source-tool-link-inputs-empty)
    false
    (str_cat.str-cat
      (build-package-transcript-field "partitioned-tli" "true")
      extra-v3)))

(define (build-package-lib-output-fingerprint
  [input-transcript : String]
  [tli-path : (& str)]
  [artifact-path : (& str)]
  [tlci-path : (& str)]) : ResultBuildString
  (let
    [tli-digest
      (try
        (build-package-file-digest
          tli-path
          "build: cannot fingerprint package tli"))]
    [artifact-digest
      (try
        (build-package-file-digest
          artifact-path
          "build: cannot fingerprint package runtime artifact"))]
    [tlci-digest : String
      (if (and
        (> (string.string-length tlci-path) 0)
        (build-package-file-regular? (string.copy tlci-path)))
        (try
          (build-package-file-digest
            tlci-path
            "build: cannot fingerprint package tlci"))
        "none")]
    (Ok
      (str_cat.str-cat
        input-transcript
        (build-package-transcript-field "tli-output" tli-digest)
        (build-package-transcript-field "runtime-output" artifact-digest)
        (build-package-transcript-field "tlci-output" tlci-digest)))))

(define (build-package-lib-fresh?
  [input-transcript : String]
  [tli-path : (& str)]
  [artifact-path : (& str)]
  [tlci-path : (& str)]
  [fingerprint-path : (& str)]) : bool
  (if (not
    (and
      (build-package-file-regular? (string.copy tli-path))
      (build-package-file-regular? (string.copy artifact-path))
      (build-package-file-regular? (string.copy fingerprint-path))))
    false
    (match (build-package-lib-output-fingerprint
      input-transcript
      tli-path
      artifact-path
      tlci-path)
      [(Err _) false]
      [(Ok expected)
        (build-package-file-text-eq? (string.copy fingerprint-path) expected)])))

(define (build-package-runtime-output-fingerprint
  [input-transcript : String]
  [asm-path : (& asm-path str)]
  [obj-path : (& obj-path str)]
  [artifact-path : (& artifact-path str)]) : ResultBuildString
  (let
    [asm-digest
      (try
        (build-package-file-digest
          asm-path
          "build: cannot fingerprint package assembly"))]
    [obj-digest
      (try
        (build-package-file-digest
          obj-path
          "build: cannot fingerprint package object"))]
    [artifact-digest
      (try
        (build-package-file-digest
          artifact-path
          "build: cannot fingerprint package runtime artifact"))]
    (Ok
      (str_cat.str-cat
        input-transcript
        (build-package-transcript-field "assembly-output" asm-digest)
        (build-package-transcript-field "object-output" obj-digest)
        (build-package-transcript-field "runtime-output" artifact-digest)))))

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
      [(Err _) false]
      [(Ok expected) (build-package-file-text-eq? fingerprint-path expected)])))

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
    [(OkFsMetadata _) true]
    [(ErrFsMetadata _) false]))

(define (build-package-stage-dir-attempt
  [output-dir : String]
  [_name : String]
  [attempt : i64]) : ResultBuildString
  (if (> attempt 64)
    (Err "build: package artifact staging has no free path")
    (let
      [candidate : String
        (load.compiler-load-join-root-path
          (owned_view.compiler-owned-shared-view output-dir)
          (str_cat.str-cat ".t" (string.int->string attempt)))]
      (if (build-package-path-present? candidate)
        (build-package-stage-dir-attempt output-dir _name (+ attempt 1))
        (if (build-mkdir-ok-owned?
          (owned_view.compiler-owned-shared-view candidate))
          (Ok candidate)
          (Err
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

(define (build-package-stage-paths-with-tli
  [output-dir : String]
  [name : String]
  [asm-path : (& asm-path str)]
  [obj-path : (& obj-path str)]
  [artifact-path : (& artifact-path str)]
  [fingerprint-path : (& fingerprint-path str)]
  [tli-path : (& tli-path str)]
  [tlci-path : (& tlci-path str)]) : ResultBuildPackageStagePaths
  (let
    [dir (try (build-package-stage-dir-attempt output-dir name 1))]
    (Ok
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
        (if (> (string.string-length tli-path) 0)
          (build-package-stage-file
            (owned_view.compiler-owned-shared-view dir)
            "i"
            tli-path)
          "")
        (if (> (string.string-length tlci-path) 0)
          (build-package-stage-file dir "t" tlci-path)
          "")))))

(define (build-package-stage-paths
  [output-dir : String]
  [name : String]
  [asm-path : (& asm-path str)]
  [obj-path : (& obj-path str)]
  [artifact-path : (& artifact-path str)]
  [fingerprint-path : (& fingerprint-path str)]
  [tlci-path : (& tlci-path str)]) : ResultBuildPackageStagePaths
  (build-package-stage-paths-with-tli
    output-dir
    name
    asm-path
    obj-path
    artifact-path
    fingerprint-path
    ""
    tlci-path))

(define (build-package-remove-staged-file [path : String]) : unit
  (fs.try-remove-file-if-exists (& path))
  (let
    [backup : String (str_cat.str-cat path ".previous")]
    (fs.try-remove-file-if-exists (& backup)))
  unit)

(define (build-package-clean-stage [paths : BuildPackageStagePaths]) : unit
  (build-package-remove-staged-file paths.asm)
  (build-package-remove-staged-file paths.obj)
  (build-package-remove-staged-file paths.artifact)
  (build-package-remove-staged-file paths.fingerprint)
  (when
    (> (string.string-length (& paths.tli)) 0)
    (build-package-remove-staged-file paths.tli))
  (when
    (> (string.string-length (& paths.tlci)) 0)
    (build-package-remove-staged-file paths.tlci))
  (let
    [dir : String paths.dir]
    (fs.try-remove-dir-if-exists (& dir)))
  unit)

(define (build-package-rollback-preserves-backup?
  [rollback : (& rollback BuildPackageRollbackDisposition)]
  [backup-path : (& backup-path str)]) : bool
  (let
    [index : i64 0]
    [preserve : bool false]
    (while (and (not preserve) (< index rollback.len))
      (match (owned_view.compiler-owned-array-element-shared-view
        rollback.backups
        index)
        [(Retained backup _ _) (set! preserve (string.eq backup backup-path))]
        [_ unit])
      (+= index 1))
    preserve))

(define (build-package-remove-staged-file-after-rollback
  [path : String]
  [rollback : (& rollback BuildPackageRollbackDisposition)]) : unit
  (fs.try-remove-file-if-exists (& path))
  (let
    [backup : String (str_cat.str-cat path ".previous")]
    (if (build-package-rollback-preserves-backup? rollback backup)
      unit
      (let
        [_ : io.ResultIoUnit (fs.try-remove-file-if-exists (& backup))]
        unit)))
  unit)

(define (build-package-clean-stage-after-rollback
  [paths : (& paths BuildPackageStagePaths)]
  [rollback : BuildPackageRollbackDisposition]) : unit
  ;; Always discard new staged data. Delete only superseded `.previous` files;
  ;; a retained entry also keeps the containing stage directory recoverable.
  (let
    [paths : BuildPackageStagePaths
      (owned_view.compiler-owned-reference-shared-view paths)]
    (build-package-remove-staged-file-after-rollback paths.asm rollback)
    (build-package-remove-staged-file-after-rollback paths.obj rollback)
    (build-package-remove-staged-file-after-rollback paths.artifact rollback)
    (build-package-remove-staged-file-after-rollback paths.fingerprint rollback)
    (when
      (> (string.string-length (& paths.tli)) 0)
      (build-package-remove-staged-file-after-rollback paths.tli rollback))
    (when
      (> (string.string-length (& paths.tlci)) 0)
      (build-package-remove-staged-file-after-rollback paths.tlci rollback))
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
    (set!
      (array-ref files index)
      (BuildPackageCommitFile
        final-path
        (owned_view.compiler-owned-shared-view staged-path)
        (str_cat.str-cat staged-path ".previous")
        false))
    (BuildPackageCommitPlan files (+ index 1))))

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
    (set! (array-ref backups index) backup)
    (BuildPackageRollbackDisposition backups (+ index 1) rollback.errors)))

(define (build-package-rollback-disposition-add-error
  [rollback : BuildPackageRollbackDisposition]
  [message : String]) : BuildPackageRollbackDisposition
  (set!
    rollback.errors
    (if (= (string.string-length rollback.errors) 0)
      message
      (str_cat.str-cat rollback.errors "\n" message)))
  rollback)

(define (build-package-rollback-recovery-required?
  [rollback : BuildPackageRollbackDisposition]) : bool
  (let
    [index : i64 0]
    [required : bool false]
    (while (and (not required) (< index rollback.len))
      (match (owned_view.compiler-owned-array-element-shared-view
        rollback.backups
        index)
        [(Retained _ _ _) (set! required true)]
        [_ unit])
      (+= index 1))
    required))

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
    (while (and ok (< index count))
      (let
        [item : BuildPackageCommitFile
          (owned_view.compiler-owned-array-element-shared-view plan.files index)]
        [final-state : BuildPackageArtifactState
          (build-package-artifact-file-state
            (owned_view.compiler-owned-shared-view item.final-path))]
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
            [(Stale reason)
              (set! ok false)
              (set!
                error
                (str_cat.str-cat
                  "build: cannot replace package artifact "
                  item.final-path
                  ": "
                  reason))]
            [_ unit]))
        (+= index 1)))
    (if ok
      (Ok "")
      (Err error))))

(define (build-package-commit-plan-rollback
  [plan : BuildPackageCommitPlan]
  [installed : i64]
  [backed-up : i64]) : BuildPackageRollbackDisposition
  (let
    [index : i64 (- installed 1)]
    [rollback : BuildPackageRollbackDisposition
      (build-package-rollback-disposition-new)]
    (while (>= index 0)
      (let
        [item : BuildPackageCommitFile
          (owned_view.compiler-owned-array-element-shared-view plan.files index)]
        (let
          [path : String item.final-path]
          (match (fs.try-remove-file-if-exists (& path))
            [(OkIoUnit) unit]
            [(ErrIoUnit io-error)
              (set!
                rollback
                (build-package-rollback-disposition-add-error
                  rollback
                  (str_cat.str-cat
                    "build: rollback failed to remove installed package artifact "
                    path
                    ": "
                    (io.error-message io-error))))]))
        (-= index 1)))
    (set! index (- backed-up 1))
    (while (>= index 0)
      (let
        [item : BuildPackageCommitFile
          (owned_view.compiler-owned-array-element-shared-view plan.files index)]
        (if item.had-old
          (let
            [backup : String item.backup-path]
            [final-path : String item.final-path]
            (match (fs.try-rename (& backup) (& final-path))
              [(OkIoUnit)
                (set!
                  rollback
                  (build-package-rollback-disposition-add-backup
                    rollback
                    (Restored backup final-path)))]
              [(ErrIoUnit io-error)
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
                  (set!
                    rollback
                    (build-package-rollback-disposition-add-error
                      rollback
                      failure))
                  (set!
                    rollback
                    (build-package-rollback-disposition-add-backup
                      rollback
                      (Retained backup final-path io-message))))]))
          unit)
        (-= index 1)))
    rollback))

(define (build-package-commit-plan-run [plan : BuildPackageCommitPlan]) : ResultBuildPackageCommit
  (match (build-package-commit-plan-preflight plan)
    [(Err message) (Err message (build-package-rollback-disposition-new))]
    [(Ok _)
      (let
        [index : i64 0]
        [count : i64 plan.len]
        [backed-up : i64 0]
        [installed : i64 0]
        [ok : bool true]
        [error : String ""]
        (while (and ok (< index count))
          (let
            [item : BuildPackageCommitFile
              (owned_view.compiler-owned-array-element-shared-view
                plan.files
                index)]
            [state : BuildPackageArtifactState
              (build-package-artifact-file-state
                (owned_view.compiler-owned-shared-view item.final-path))]
            (match state
              [(Clean)
                (let
                  [from : String item.final-path]
                  [to : String item.backup-path]
                  (match (fs.try-rename (& from) (& to))
                    [(OkIoUnit)
                      (build-package-commit-plan-set-had-old!
                        (owned_view.compiler-owned-shared-view plan)
                        index)]
                    [(ErrIoUnit io-error)
                      (set! ok false)
                      (set!
                        error
                        (str_cat.str-cat
                          "build: failed to stage previous package artifact: "
                          (io.error-message io-error)))]))]
              [(Missing) unit]
              [(Stale reason)
                (set! ok false)
                (set! error reason)])
            (if ok
              (+= backed-up 1)
              unit)
            (+= index 1)))
        (set! index 0)
        (while (and ok (< index count))
          (let
            [item : BuildPackageCommitFile
              (owned_view.compiler-owned-array-element-shared-view
                plan.files
                index)]
            [from : String item.staged-path]
            [to : String item.final-path]
            (match (fs.try-rename (& from) (& to))
              [(OkIoUnit) (+= installed 1)]
              [(ErrIoUnit io-error)
                (set! ok false)
                (set!
                  error
                  (str_cat.str-cat
                    "build: failed to commit package artifact: "
                    (io.error-message io-error)))])
            (+= index 1)))
        (if ok
          (begin
            (set! index 0)
            (while (< index count)
              (let
                [item : BuildPackageCommitFile
                  (owned_view.compiler-owned-array-element-shared-view
                    plan.files
                    index)]
                (if item.had-old
                  (let
                    [backup : String item.backup-path]
                    (fs.try-remove-file-if-exists (& backup)))
                  io.OkIoUnit)
                (+= index 1)))
            (Ok))
          (Err
            error
            (build-package-commit-plan-rollback plan installed backed-up))))]))

(define (build-package-write-tlci [path : (& path str)] [text : String]) : build_run_core.SourceToolCommandStatus
  (build_run_core.source-tool-write-file
    path
    text
    "build: failed to write package tlci"))

(define (build-package-write-assembly
  [path : (& path str)]
  [asm : String]
  [target : be_state.CompilerBackendTarget]) : build_run_core.SourceToolCommandStatus
  (let
    [_
      (try
        (build_run_core.source-tool-write-file
          path
          asm
          "build: failed to write package assembly"))]
    [haystack : String asm]
    [needle : String ".note.GNU-stack"]
    [note : String (build_run_core.source-tool-noexecstack-note)]
    (if (and
      (be_facts.compiler-backend-target-linux? target)
      (not (string.contains (& haystack) (& needle))))
      (match (io.try-append-file path (byte_buf.str-as-bytes (& note)))
        [(OkIoUnit) Ok]
        [(ErrIoUnit error)
          (Err
            (str_cat.str-cat
              "build: failed to write package assembly: "
              (io.error-message error)))])
      Ok)))

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
      (when
        (> (string.string-length (& tlci-path)) 0)
        (io.print-format
          "{}"
          (str_cat.str-cat
            (if tlci-dirty
              "Built "
              "Fresh ")
            tlci-path
            "\n")))
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
    (if runtime-dirty
      (match (build-package-runtime-output-fingerprint
        input-transcript
        stage.asm
        stage.obj
        stage.artifact)
        [(Err message)
          (set! ok false)
          (set! error message)]
        [(Ok fingerprint)
          (match (build_run_core.source-tool-write-file
            stage.fingerprint
            fingerprint
            "build: failed to stage package runtime fingerprint")
            [(Err message)
              (set! ok false)
              (set! error message)]
            [(Ok)
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
                  (owned_view.compiler-owned-shared-view stage.fingerprint)))])])
      unit)
    (if (and ok tlci-dirty)
      (match (build-package-write-tlci stage.tlci tlci-text)
        [(Err message)
          (set! ok false)
          (set! error message)]
        [(Ok)
          (set!
            plan
            (build-package-commit-plan-add
              plan
              (owned_view.compiler-owned-shared-view tlci-path)
              (owned_view.compiler-owned-shared-view stage.tlci)))])
      unit)
    (if ok
      (match (build-package-commit-plan-run plan)
        [(Err message rollback)
          (build-package-clean-stage-after-rollback
            stage
            (owned_view.compiler-owned-shared-view rollback))
          (io.print-error
            (build-package-commit-error-message message rollback stage.dir))
          1]
        [(Ok)
          (build-package-clean-stage stage)
          (build-package-announce-freshness
            artifact-path
            tlci-path
            runtime-dirty
            tlci-dirty
            announce)])
      (begin
        (build-package-clean-stage stage)
        (io.print-error error)
        1))))

(define (build-package-finish-direct-fresh-artifacts
  [name : String]
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
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
  [extra-v3 : String]
  [announce : bool]) : i64
  (let
    [fingerprint-path : String
      (build-package-runtime-fingerprint-path
        (owned_view.compiler-owned-shared-view artifact-path))]
    [tlci-dirty : bool
      (and
        (> (string.string-length (& tlci-path)) 0)
        (not
          (build-package-file-text-eq?
            (owned_view.compiler-owned-shared-view tlci-path)
            (owned_view.compiler-owned-shared-view tlci-text))))]
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
      true
      extra-v3)
      [(Err message)
        (io.print-error message)
        1]
      [(Ok input-transcript)
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
              [(Err message)
                (io.print-error message)
                1]
              [(Ok stage)
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
                      Ok)]
                  (match runtime-status
                    [(Err message)
                      (build-package-clean-stage stage)
                      (io.print-error message)
                      1]
                    [(Unavailable message)
                      (build-package-clean-stage stage)
                      (io.print-error message)
                      1]
                    [(Ok)
                      (let
                        [asm-status : build_run_core.SourceToolCommandStatus
                          (if runtime-dirty
                            (build-package-write-assembly
                              stage.asm
                              side-assembly
                              target)
                            Ok)]
                        (match asm-status
                          [(Err message)
                            (build-package-clean-stage stage)
                            (io.print-error message)
                            1]
                          [(Ok)
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
                              announce)]))]))])))])))

(define (build-package-finish-assembly-fresh-artifacts
  [name : String]
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [producer-identity : String]
  [output-dir : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [tlci-path : String]
  [tlci-text : String]
  [asm : String]
  [extra-v3 : String]
  [announce : bool]) : i64
  (let
    [fingerprint-path : String
      (build-package-runtime-fingerprint-path
        (owned_view.compiler-owned-shared-view artifact-path))]
    [augmented-asm : String
      (build_run_core.source-tool-augment-assembly-for-target asm target)]
    [tlci-dirty : bool
      (and
        (> (string.string-length (& tlci-path)) 0)
        (not
          (build-package-file-text-eq?
            (owned_view.compiler-owned-shared-view tlci-path)
            (owned_view.compiler-owned-shared-view tlci-text))))]
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
      false
      extra-v3)
      [(Err message)
        (io.print-error message)
        1]
      [(Ok input-transcript)
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
              [(Err message)
                (io.print-error message)
                1]
              [(Ok stage)
                (let
                  [runtime-status : build_run_core.SourceToolCommandStatus
                    (if runtime-dirty
                      (match (build-package-write-assembly
                        stage.asm
                        augmented-asm
                        target)
                        [(Err message) (Err message)]
                        [(Ok)
                          (build-package-artifact-status
                            kind
                            target
                            (owned_view.compiler-owned-shared-view stage.asm)
                            (owned_view.compiler-owned-shared-view stage.obj)
                            (owned_view.compiler-owned-shared-view
                              stage.artifact)
                            link-inputs
                            (Unavailable "freshness fallback"))])
                      Ok)]
                  (match runtime-status
                    [(Err message)
                      (build-package-clean-stage stage)
                      (io.print-error message)
                      1]
                    [(Ok)
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
                        announce)]))])))])))

(define (build-package-finish-prepared-runtime
  [prepared : ResultBuildPackagePreparedRuntime]
  [name : String]
  [kind : load.CompilerPkgKind]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [producer-identity : String]
  [output-dir : String]
  [asm-path : String]
  [obj-path : String]
  [artifact-path : String]
  [link-inputs : build_run_core.SourceToolLinkInputs]
  [tlci-path : String]
  [tlci-text : String]
  [extra-v3 : String]
  [announce : bool]) : i64
  (match prepared
    [(DirectObject object-text side-assembly)
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
        extra-v3
        announce)]
    [(Assembly asm _)
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
        extra-v3
        announce)]
    [(Err message)
      (io.print-error message)
      1]))

(define (build-package-require-direct-object
  [prepared : ResultBuildPackagePreparedRuntime]) : ResultBuildPackagePreparedRuntime
  (match prepared
    [(DirectObject object side-assembly) (DirectObject object side-assembly)]
    [(Assembly _ reason)
      (Err
        (str_cat.str-cat
          "build: direct object required: "
          (be_object.compiler-direct-object-fallback-transcript reason)))]
    [(Err message) (Err message)]))

(define (build-package-elf-member-needs-runtime?
  [bytes : (& bytes str)]
  [request : (& elf.ElfReadRequest)]) : bool
  (let
    [size : i64 (string.string-length bytes)]
    (when (> size request.limits.max-input-bytes) (return true))
    (let
      [data : (__tl_dyn-array u8) (__tl_make-array u8 size)]
      (unsafe
        (string.str-copy-borrowed-bytes-into
          bytes
          (__tl_array-data data)
          0
          size))
      (match (elf.read-object (& data) request)
        [(ReadFailed _) true]
        [(ReadObject object)
          (for [symbol (& object.symbols)]
            (match (& symbol.section)
              [(Undefined)
                (let
                  [name
                    (string.substring-view
                      bytes
                      symbol.name.offset
                      symbol.name.size)]
                  ;; Package symbols are mangled with _tl_. The native
                  ;; runtime supplies the unprefixed tl_ ABI.
                  (when (string.is-string-prefix-at name "tl_" 0) (return true)))]
              [_ unit]))
          false]))))

(define (build-package-elf-archive-needs-runtime? [path : (& str)]) : bool
  (let
    [limits : elf.ElfLimits (elf.default-limits)]
    [size : i64 (fs.file-size path)]
    (when (or (< size 0) (> size limits.max-input-bytes)) (return true))
    (match (io.try-read-file path)
      [(ErrIoBytes _) true]
      [(OkIoBytes buffer)
        (let
          [bytes : String (byte_buf.to-string buffer)]
          [request : elf.ElfReadRequest
            (elf.ElfReadRequest (elf.ElfIdentity 0 0) limits)]
          (match (ar.read
            (& bytes)
            (archive.ArchiveIdentity 0 0)
            (GnuSystemV)
            (archive.ArchiveLimits
              request.limits.max-input-bytes
              65536
              16777216
              4
              1048576
              1
              67108864))
            [(ReadFailed _) true]
            [(ReadArchive parsed)
              (for [member (& parsed.members)]
                (match (& member.kind)
                  [(Ordinary)
                    (when
                      (build-package-elf-member-needs-runtime?
                        (string.substring-view
                          (& bytes)
                          member.content-offset
                          member.content-size)
                        (& request))
                      (return true))]
                  [_ unit]))
              false]))])))

(define (build-package-archives-need-runtime?
  [target : be_state.CompilerBackendTarget]
  [inputs : (& inputs build_run_core.SourceToolLinkInputs)]) : bool
  (and
    (build_run_core.source-tool-link-inputs-have-archives? inputs)
    (if (and
      (be_state.compiler-backend-target-elf? target)
      (build_run_core.source-tool-linux-direct-object-enabled?))
      (let
        [archives (build_run_core.source-tool-link-inputs-archives inputs)]
        (for [i (iterator.range 0 (process.args-count archives))]
          (let
            [path : String (process.args-ref archives i)]
            (when
              (with-arena
                archive-check
                (build-package-elf-archive-needs-runtime? (& path)))
              (return true))))
        false)
      true)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-prepare-owned-runtime
    [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope]
    [request : BuildPackageDirectObjectRequest]
    [archive-runtime : bool]) : ResultBuildPackagePreparedRuntime
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
          request.cfgs
          request.opt-level)]
      [_archive-runtime : unit
        (when
          archive-runtime
          (compiler_driver_core.compiler-driver-lowered-result-enable-archive-runtime!
            (& lowered)))]
      [prepared : ResultBuildPackagePreparedRuntime
        (build-package-emit-preflighted-runtime
          request.entry-path
          request.kind
          request.target
          request.opt-level
          request.mode
          request.emit-entry
          request.crt-entry
          ;; Archive members can need runtime entry points that the consumer's
          ;; IR does not reference. The assembly runtime provides them.
          (if archive-runtime
            (Fallback ForcedAssembly)
            preflight)
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
  (define (build-package-finish-bin-artifacts
    [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope]
    [manifest-path : (& str)]
    [manifest-dir : (& str)]
    [manifest : (& manifest load.CompilerPkgManifest)]
    [name : String]
    [kind : load.CompilerPkgKind]
    [target : be_state.CompilerBackendTarget]
    [opt-level : i64]
    [profile : BuildProfile]
    [mode : be_state.CompilerBackendMode]
    [producer-identity : String]
    [entry-path : String]
    [emit-entry : bool]
    [crt-entry : bool]
    [decls : ast.AstDeclList]
    [owned-paths : ast.AstDeclPathList]
    [output-dir : String]
    [asm-path : String]
    [obj-path : String]
    [artifact-path : String]
    [link-inputs : build_run_core.SourceToolLinkInputs]
    [announce : bool]
    [cfgs : sym_i64_env.SymI64Env]) : i64
    (let
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
            cfgs
            (owned_view.compiler-owned-shared-view entry-path))
          (and
            emit-entry
            (build-package-archives-need-runtime? target (& link-inputs))))]
      ;; Capture hydrated archive paths BEFORE releasing the runtime scope,
      ;; which resets the driver file state.
      [final-link-inputs : build_run_core.SourceToolLinkInputs
        (build_run_core.source-tool-link-inputs-with-hydrated-archives
          link-inputs)]
      [_release : unit (build-package-runtime-scope-release! scope)]
      [extra-v3 : String
        (match (package_source_core.package-source-discover-for
          "build"
          (string.copy manifest-path)
          true)
          [(Err _) ""]
          [(Ok source-set)
            (match (build-package-v3-extra-inputs
              manifest-path
              manifest-dir
              manifest
              profile
              target
              cfgs
              (& source-set.sources))
              [(Ok text) text]
              [(Err _) ""])])]
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
        final-link-inputs
        ""
        ""
        extra-v3
        announce))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-lib-file-sha256 [path : (& str)]) : (Array u8 32)
    (match (io.try-read-file path)
      [(ErrIoBytes _) (make-array u8 32)]
      [(OkIoBytes contents)
        (let
          [bytes : (__tl_dyn-array u8) (byte_buf.to-array contents)]
          (build-package-bytes-sha256 (& bytes)))])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-lib-pre-sources
    [decls : (& ast.AstDeclList)]
    [raw-paths : (& ast.AstDeclPathList)]
    [owned-paths : (& ast.AstDeclPathList)]
    [entry-path : (& str)]
    [package-name : (& str)]
    [manifest-dir : (& str)]
    [stdlib-roots : (& cli_svec.Vec)]
    [source-set : (& package_source_core.PackageSourceSet)]) : (__tl_dyn-array
      tli_extract.TliSource)
    (let
      [owned-sources : build_string_i64_map.Map
        (build-package-tlci-source-map (& source-set.sources))]
      [seen-owned : build_string_i64_map.Map
        (build_string_i64_map.with-capacity 16)]
      [mod-names : cli_svec.Vec (cli_svec.new)]
      [owned-list : cli_svec.Vec (cli_svec.new)]
      [raw-list : cli_svec.Vec (cli_svec.new)]
      [count : i64 (ast.ast-decl-list-len decls)]
      (for [index (iterator.range 0 count)]
        (let
          [raw-p : String (ast.ast-decl-path-list-get raw-paths index "")]
          (when
            (build-package-tlci-source-owned? (& owned-sources) (& raw-p))
            (let
              [owned-p : String
                (ast.ast-decl-path-list-get owned-paths index "")]
              (when
                (> (string.string-length (& owned-p)) 0)
                (match (build_string_i64_map.get
                  (& seen-owned)
                  (string.copy (& owned-p)))
                  [(LookupFound _) unit]
                  [(LookupMissing)
                    (let
                      [slot : i64 (cli_svec.len (& owned-list))]
                      [decl : ast.AstDecl
                        (ast.ast-decl-list-get
                          decls
                          index
                          (ast.ast-decl-fallback))]
                      [mod-name : String
                        (let
                          [explicit : String
                            (match decl
                              [(Module name-id) (ci.intern-str name-id)]
                              [_ ""])]
                          (if (> (string.string-length (& explicit)) 0)
                            explicit
                            (let
                              [canon : String
                                (load.compiler-load-canonical-module-id-from-path
                                  (& owned-p))]
                              (if (> (string.string-length (& canon)) 0)
                                canon
                                (string.copy package-name)))))]
                      (build_string_i64_map.insert-ref!
                        (&mut seen-owned)
                        (string.copy (& owned-p))
                        slot)
                      (cli_svec.push-ref! (&mut mod-names) mod-name)
                      (cli_svec.push-ref! (&mut owned-list) owned-p)
                      (cli_svec.push-ref! (&mut raw-list) raw-p))]))))))
      (when
        (= (cli_svec.len (& owned-list)) 0)
        (let
          [entry-owned : String
            (load.compiler-load-package-owned-path
              (string.copy package-name)
              manifest-dir
              stdlib-roots
              (string.copy entry-path))]
          [canon : String
            (load.compiler-load-canonical-module-id-from-path (& entry-owned))]
          [mod-name : String
            (if (> (string.string-length (& canon)) 0)
              canon
              (string.copy package-name))]
          (cli_svec.push-ref! (&mut mod-names) mod-name)
          (cli_svec.push-ref! (&mut owned-list) entry-owned)
          (cli_svec.push-ref! (&mut raw-list) (string.copy entry-path))))
      (let
        [n : i64 (cli_svec.len (& owned-list))]
        [out : (__tl_dyn-array tli_extract.TliSource)
          (__tl_make-array tli_extract.TliSource n)]
        (for [i (iterator.range 0 n)]
          (let
            [raw-p : String (cli_svec.get (& raw-list) i "")]
            (set!
              (array-ref out i)
              (tli_extract.TliSource
                (cli_svec.get (& mod-names) i "")
                (cli_svec.get (& owned-list) i "")
                (build-package-lib-file-sha256 (& raw-p))))))
        out))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-lib-snapshot-external-imports!
    [bundle : (&mut tli.TliBundle)]
    [load-state : (& load.CompilerLoadSessionState)]) : unit
    (let
      [mcount : i64 (array-length bundle.modules)]
      (for [m (iterator.range 0 mcount)]
        (let
          [icount : i64 (array-length (array-ref bundle.modules m).imports)]
          (for [i (iterator.range 0 icount)]
            (let
              [imp-name : String
                (string.copy
                  (&
                    (array-ref (array-ref bundle.modules m).imports i).module-name))]
              (match (load.compiler-load-session-state-tli-module-sha256
                load-state
                (& imp-name))
                [(Some ext-digest)
                  (set!
                    (array-ref (array-ref bundle.modules m).imports i).interface-sha256
                    ext-digest)]
                [(None) unit]))))))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-lib-stamp-tlci-companion!
    [bundle : (&mut tli.TliBundle)]
    [tlci-sha256 : (Array u8 32)]) : unit
    (set! bundle.flags (bit-or bundle.flags tli.tli-has-tlci-companion))
    (for [m (iterator.range 0 (array-length bundle.modules))]
      (for [k
        (iterator.range 0 (array-length (array-ref bundle.modules m).macros))]
        (when
          (!=
            (bit-and (array-ref (array-ref bundle.modules m).macros k).flags 1)
            0)
          (set!
            (array-ref (array-ref bundle.modules m).macros k).tlci-catalog-sha256
            tlci-sha256))))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-lib-obj-name
    [asm-file : (& str)]
    [target : be_state.CompilerBackendTarget]) : String
    (let
      [n : i64 (string.string-length asm-file)]
      [stem : String
        (if (and (> n 2) (string.is-string-prefix-at asm-file ".s" (- n 2)))
          (string.substring asm-file 0 (- n 2))
          (string.copy asm-file))]
      (match target
        [(Linux) (str_cat.str-cat stem ".o")]
        [(Windows) (str_cat.str-cat stem ".obj")]))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-lib-clean-mods-dir! [mods-dir : (& str)]) : unit
    (match (fs.try-read-dir mods-dir)
      [(ErrIoStringVector _) unit]
      [(OkIoStringVector entries)
        (for [i (iterator.range 0 (fs.string-vector-len (& entries)))]
          (let
            [entry : String (fs.string-vector-get (& entries) i "")]
            [full : String (fs.path-join mods-dir (& entry))]
            (fs.try-remove-file-if-exists (& full))))])
    (fs.try-remove-dir-if-exists mods-dir)
    unit))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-lib-assemble-and-archive
    [mods-dir : (& str)]
    [asm-files : (& (__tl_dyn-array String))]
    [package-name : (& str)]
    [target : be_state.CompilerBackendTarget]
    [archive-path : String]) : build_run_core.SourceToolCommandStatus
    (let
      [obj-paths : process.ProcessStringList (process.args-empty)]
      [count : i64 (array-length (deref asm-files))]
      (if (= count 0)
        (let
          [stub-name : String
            (str_cat.str-cat
              "000_"
              (tli_extract.tli-partition-sanitize-module-filename package-name)
              ".s")]
          [stub-asm : String (fs.path-join mods-dir (& stub-name))]
          [stub-obj : String
            (fs.path-join
              mods-dir
              (& (build-package-lib-obj-name (& stub-name) target)))]
          [stub-text : String
            (match target
              [(Linux) "    .section .note.GNU-stack,\"\",@progbits\n"]
              [(Windows) "    .text\n"])]
          (try
            (build_run_core.source-tool-write-file
              (& stub-asm)
              (& stub-text)
              "build: failed to write empty library stub assembly"))
          (let
            [asm-cmd : process.ProcessCommand
              (try
                (build-package-assembler-command-for
                  target
                  (string.copy (& stub-asm))
                  (string.copy (& stub-obj))))]
            (try
              (build_run_core.source-tool-run-command
                "build: assembler failed"
                target
                asm-cmd)))
          (set!
            obj-paths
            (build_run_core.source-tool-args-append obj-paths stub-obj)))
        (for [i (iterator.range 0 count)]
          (let
            [fname : String (string.copy (& (array-ref (deref asm-files) i)))]
            [asm-p : String (fs.path-join mods-dir (& fname))]
            [obj-p : String
              (fs.path-join
                mods-dir
                (& (build-package-lib-obj-name (& fname) target)))]
            [asm-cmd : process.ProcessCommand
              (try
                (build-package-assembler-command-for
                  target
                  (string.copy (& asm-p))
                  (string.copy (& obj-p))))]
            (try
              (build_run_core.source-tool-run-command
                "build: assembler failed"
                target
                asm-cmd))
            (set!
              obj-paths
              (build_run_core.source-tool-args-append obj-paths obj-p)))))
      (build_run_core.source-tool-archive-many target obj-paths archive-path))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-emit-lib-tli!
    [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope]
    [request : (& BuildPackageEmitRequest)]
    [decls : ast.AstDeclList]
    [raw-paths : ast.AstDeclPathList]
    [owned-paths : ast.AstDeclPathList]
    [cfgs : sym_i64_env.SymI64Env]) : i64
    (let
      [output-dir : String
        (build-package-output-dir-profile
          (string.copy (& request.manifest-dir))
          (string.copy (& request.manifest.name))
          (clone-build-profile (& request.profile)))]
      [target : be_state.CompilerBackendTarget
        (be_state.clone-compiler-backend-target (& request.target))]
      [mode : be_state.CompilerBackendMode
        (be_state.clone-compiler-backend-mode (& request.mode))]
      [profile : BuildProfile (clone-build-profile (& request.profile))]
      [fingerprint-path : String
        (build-package-runtime-fingerprint-path
          (string.copy (& request.artifact-path)))]
      [source-inputs : BuildPackageTlciSourceInputs
        (match (build-package-tlci-source-inputs
          (string.copy (& request.manifest-path))
          (& request.producer-identity))
          [(Err message)
            (build-package-runtime-scope-release! scope)
            (io.print-error message)
            (return 1)]
          [(Ok inputs) inputs])]
      [source-digest : i64
        (match (& source-inputs)
          [(Image _ d) d]
          [(NoImage) 0])]
      [source-set : package_source_core.PackageSourceSet
        (match source-inputs
          [(Image s _) s]
          [(NoImage)
            (build-package-runtime-scope-release! scope)
            (io.print-error "build: missing library source set")
            (return 1)])]
      [source-context : compiler_tlci_native_producer.TlciNativeSourceContext
        (compiler_tlci_native_producer.tlci-native-source-context-new
          (compiler_driver_core.compiler-driver-state-pool-context
            (& scope.state))
          (compiler_driver_core.compiler-driver-state-owned-interns
            (& scope.state)))]
      [exports : ResultBuildPackageTlciExports
        (build-package-tlci-capture-exports
          (& source-context)
          (& request.manifest)
          (& request.stdlib-roots)
          mode
          (owned_view.compiler-owned-shared-view decls)
          (owned_view.compiler-owned-shared-view raw-paths)
          (& source-set))]
      (match (& exports)
        [(Err message)
          (build-package-runtime-scope-release! scope)
          (io.print-error message)
          (return 1)]
        [_ unit])
      (let
        [macro-names : (__tl_dyn-array String)
          (match (& exports)
            [(Ok _ names _ _)
              (let
                [n : i64 (array-length names)]
                [dst : (__tl_dyn-array String) (__tl_make-array String n)]
                (for [i (iterator.range 0 n)]
                  (set! (array-ref dst i) (string.copy (& (array-ref names i)))))
                dst)]
            [(Err _) (__tl_make-array String 0)])]
        [pre-sources : (__tl_dyn-array tli_extract.TliSource)
          (build-package-lib-pre-sources
            (& decls)
            (& raw-paths)
            (& owned-paths)
            (& request.entry-path)
            (& request.manifest.name)
            (& request.manifest-dir)
            (& request.stdlib-roots)
            (& source-set))]
        [_capture-fe : unit
          (compiler_driver_core.compiler-driver-package-runtime-capture-frontend!
            (owned_view.compiler-owned-shared-view scope))]
        [tc-req : tc_api.TypecheckRequest
          (tc_api.TypecheckRequest
            (owned_view.compiler-owned-shared-view scope.state.load-session)
            (owned_view.compiler-owned-shared-view
              scope.state.typecheck-prefix-cache)
            scope.state.typecheck-state
            (ast.AstProgram.Program (box decls))
            owned-paths
            (cli_svec.clone-vec (& request.stdlib-roots))
            cfgs
            (tc_core.tc-prefix-default-cache-scope)
            (ast.ast-node-pool-context-capture-active)
            (ci.intern-compat-state-capture-active)
            (tc_core.tc-job-state-semantic-observer scope.state.typecheck-state)
            true)]
        [cfg-digest : (Array u8 32) (tli_extract.tli-extract-cfg-digest cfgs)]
        [records : (__tl_dyn-array tli_extract.TliExtractModule)
          (tli_extract.tli-extract-open-modules (& tc-req) (& pre-sources))]
        [job : tc_core.TcJobState scope.state.typecheck-state]
        [let-facts : tc_core.TcCheckedLetBindingFactState
          (tc_core.tc-job-state-checked-let-binding-facts job)]
        [target-triple : String
          (tli_cli.tli-sysroot-target-triple (build-package-target-cfg target))]
        [stage : BuildPackageStagePaths
          (match (build-package-stage-paths-with-tli
            (string.copy (& output-dir))
            (string.copy (& request.manifest.name))
            (string.copy (& request.asm-path))
            (string.copy (& request.obj-path))
            (string.copy (& request.artifact-path))
            (string.copy (& fingerprint-path))
            (string.copy (& request.tli-path))
            (string.copy (& request.tlci-path)))
            [(Err message)
              (build-package-runtime-scope-release! scope)
              (io.print-error message)
              (return 1)]
            [(Ok s) s])]
        [mods-dir : String (fs.path-join (& stage.dir) "mods")]
        (unless
          (build-mkdir-ok? (& mods-dir))
          (build-package-runtime-scope-release! scope)
          (build-package-clean-stage stage)
          (io.print-error
            (str_cat.str-cat
              "build: failed to create module stage dir "
              mods-dir))
          (return 1))
        (tc_core.tc-checked-let-binding-facts-begin! let-facts false)
        (match (tli_extract.tli-typecheck-for-extract-and-lower tc-req)
          [(or (Partial diagnostics _ _ _) (Err diagnostics))
            (tc_core.tc-global-call-effects-finish! job)
            (tc_core.tc-checked-let-binding-facts-finish! let-facts)
            (build-package-runtime-scope-release! scope)
            (build-package-lib-clean-mods-dir! (& mods-dir))
            (build-package-clean-stage stage)
            (io.print-error
              (compiler_driver_core.compiler-driver-render-source-diagnostic
                (compiler_diagnostic.compiler-diagnostic-list-first
                  (& (__tl-box-place diagnostics)))))
            1]
          [(Ok _ ctx env checked-paths)
            (tc_core.tc-checked-let-binding-facts-freeze! let-facts)
            (let
              [all-sources : (__tl_dyn-array tli_extract.TliSource)
                (tli_extract.tli-extract-add-generated-sources
                  ctx
                  (& checked-paths)
                  (& pre-sources))]
              [all-records : (__tl_dyn-array tli_extract.TliExtractModule)
                (tli_extract.tli-extract-extend-records records (& all-sources))]
              [companion : tli_extract.TliPackageCompanionBinding
                (tli_extract.TliPackageCompanionBinding
                  (> (array-length macro-names) 0)
                  (make-array u8 32)
                  macro-names)]
              [bundle : tli.TliBundle
                (tli_extract.tli-extract-checked-with-companion
                  ctx
                  env
                  (& checked-paths)
                  (& all-sources)
                  all-records
                  (& cfg-digest)
                  0
                  (string.copy (& request.producer-identity))
                  target-triple
                  (& companion))]
              (build-package-lib-snapshot-external-imports!
                (&mut bundle)
                (& scope.state.load-session))
              (tc_core.tc-global-call-effects-finish! job)
              (let
                [pools : ast.AstNodePoolContext (tc_core.tc-context-pools ctx)]
                [checked-program : ast.AstProgram
                  (tc_core.tc-context-program ctx)]
                [lower-state : lower.CompilerLowerState
                  (lower.compiler-lower-state-new)]
                [lower-mode : lower.CompilerLowerMode
                  (compiler_driver_core.compiler-driver-lower-mode-for-target
                    target
                    mode)]
                (lower.compiler-lower-state-enable-module-ownership!
                  lower-state
                  true)
                (lower.compiler-lower-state-set-spmd-package!
                  lower-state
                  (string.copy (& request.manifest.name)))
                (ast.ast-node-pool-context-install! pools)
                (let
                  [lower-names : lower.LowerNameEnv
                    (match (& checked-program)
                      [(ast.AstProgram.Program decls-box)
                        (lower.lower-name-env-from-decls-with-state
                          lower-state
                          (& (deref decls-box))
                          (& checked-paths)
                          ""
                          lower.LowerNameEnv.Nil)])]
                  (match (lower.lower-compiler-program-checked-with-names-mode
                    lower-state
                    ctx
                    (tc_core.tc-env-with-cache env)
                    checked-program
                    checked-paths
                    ""
                    lower-names
                    lower-mode)
                    [(Err diag-box)
                      (tc_core.tc-checked-let-binding-facts-finish! let-facts)
                      (lower.compiler-lower-arena-state-release!
                        (lower.compiler-lower-state-arenas lower-state))
                      (build-package-runtime-scope-release! scope)
                      (build-package-lib-clean-mods-dir! (& mods-dir))
                      (build-package-clean-stage stage)
                      (io.print-error
                        (compiler_driver_core.compiler-driver-render-source-diagnostic
                          (deref diag-box)))
                      1]
                    [(Ok whole-program whole-spans lower-owner)
                      (tc_core.tc-checked-let-binding-facts-finish! let-facts)
                      (let
                        [part-result : tli_extract.ResultTliPartitionedEmit
                          (tli_extract.tli-emit-partitioned-modules!
                            (& bundle)
                            whole-program
                            whole-spans
                            lower-owner
                            pools
                            job
                            (& mods-dir)
                            ""
                            target
                            mode
                            (be_facts.compiler-backend-target-windows? target)
                            request.opt-level
                            false)]
                        (match part-result
                          [(Err message)
                            (lower.compiler-lower-arena-state-release!
                              (lower.compiler-lower-state-arenas lower-owner))
                            (build-package-runtime-scope-release! scope)
                            (build-package-lib-clean-mods-dir! (& mods-dir))
                            (build-package-clean-stage stage)
                            (io.print-error message)
                            1]
                          [(Ok emitted)
                            (let
                              [tlci-emitted : BuildPackageTlciEmitted
                                (build-package-tlci-emit-optional
                                  exports
                                  (string.copy (& request.producer-identity))
                                  source-digest)]
                              (match tlci-emitted
                                [(Err message)
                                  (lower.compiler-lower-arena-state-release!
                                    (lower.compiler-lower-state-arenas
                                      lower-owner))
                                  (build-package-runtime-scope-release! scope)
                                  (build-package-lib-clean-mods-dir!
                                    (& mods-dir))
                                  (build-package-clean-stage stage)
                                  (io.print-error message)
                                  1]
                                [_
                                  (let
                                    [has-tlci : bool
                                      (match (& tlci-emitted)
                                        [(SomeTlci _ _) true]
                                        [_ false])]
                                    [tlci-text : String
                                      (match tlci-emitted
                                        [(SomeTlci text digest)
                                          (build-package-lib-stamp-tlci-companion!
                                            (&mut bundle)
                                            digest)
                                          text]
                                        [_ ""])]
                                    [tlci-dirty : bool
                                      (and
                                        has-tlci
                                        (not
                                          (build-package-file-text-eq?
                                            (string.copy (& request.tlci-path))
                                            (string.copy (& tlci-text)))))]
                                    (unless
                                      (tli_extract.tli-extract-pin-imports-with-load-state!
                                        (&mut bundle)
                                        (& scope.state.load-session))
                                      (lower.compiler-lower-arena-state-release!
                                        (lower.compiler-lower-state-arenas
                                          lower-owner))
                                      (build-package-runtime-scope-release!
                                        scope)
                                      (build-package-lib-clean-mods-dir!
                                        (& mods-dir))
                                      (build-package-clean-stage stage)
                                      (io.print-error
                                        "build: TLI import cycle cannot pin module record digests")
                                      (return 1))
                                    (let
                                      [encoded-arr : (__tl_dyn-array u8)
                                        (tli_codec.tli-encode-bundle (& bundle))]
                                      [encoded-buf : byte_buf.ByteBuf
                                        (byte_buf.from-array encoded-arr)]
                                      (lower.compiler-lower-arena-state-release!
                                        (lower.compiler-lower-state-arenas
                                          lower-owner))
                                      (build-package-runtime-scope-release!
                                        scope)
                                      (match (io.try-write-file
                                        (& stage.tli)
                                        (byte_buf.as-bytes (& encoded-buf)))
                                        [(OkIoUnit) unit]
                                        [(ErrIoUnit err)
                                          (build-package-lib-clean-mods-dir!
                                            (& mods-dir))
                                          (build-package-clean-stage stage)
                                          (io.print-error
                                            (str_cat.str-cat
                                              "build: failed to write package tli: "
                                              (io.error-message err)))
                                          (return 1)]))
                                    (let
                                      [combined-asm : text_buf.TextBuf
                                        (text_buf.empty)]
                                      (if (= (array-length emitted.asm-files) 0)
                                        (set!
                                          combined-asm
                                          (text_buf.append
                                            combined-asm
                                            "; empty library package\n"))
                                        (for [ai
                                          (iterator.range
                                            0
                                            (array-length emitted.asm-files))]
                                          (match (io.try-read-file
                                            (& (array-ref emitted.asm-files ai)))
                                            [(io.OkIoBytes chunk)
                                              (let
                                                [chunk-text : String
                                                  (byte_buf.to-string chunk)]
                                                (set!
                                                  combined-asm
                                                  (text_buf.append
                                                    combined-asm
                                                    chunk-text)))]
                                            [(io.ErrIoBytes _) unit])))
                                      (let
                                        [asm-text : String
                                          (text_buf.render combined-asm)]
                                        (match (build_run_core.source-tool-write-file
                                          (& stage.asm)
                                          (& asm-text)
                                          "build: failed to stage package library assembly")
                                          [(Ok) unit]
                                          [(Err message)
                                            (build-package-lib-clean-mods-dir!
                                              (& mods-dir))
                                            (build-package-clean-stage stage)
                                            (io.print-error message)
                                            (return 1)])))
                                    (match (build-package-lib-assemble-and-archive
                                      (& mods-dir)
                                      (& emitted.asm-files)
                                      (& request.manifest.name)
                                      target
                                      (string.copy (& stage.artifact)))
                                      [(Err message)
                                        (build-package-lib-clean-mods-dir!
                                          (& mods-dir))
                                        (build-package-clean-stage stage)
                                        (io.print-error message)
                                        1]
                                      [(Ok)
                                        (build-package-lib-clean-mods-dir!
                                          (& mods-dir))
                                        (when
                                          tlci-dirty
                                          (match (build-package-write-tlci
                                            (& stage.tlci)
                                            tlci-text)
                                            [(Ok) unit]
                                            [(Err message)
                                              (build-package-clean-stage stage)
                                              (io.print-error message)
                                              (return 1)]))
                                        (match (build-package-lib-output-fingerprint
                                          (string.copy
                                            (& request.lib-input-transcript))
                                          (& stage.tli)
                                          (& stage.artifact)
                                          (&
                                            (if has-tlci
                                              (if tlci-dirty
                                                (string.copy (& stage.tlci))
                                                (string.copy
                                                  (& request.tlci-path)))
                                              "")))
                                          [(Err message)
                                            (build-package-clean-stage stage)
                                            (io.print-error message)
                                            1]
                                          [(Ok fp-text)
                                            (match (build_run_core.source-tool-write-file
                                              (& stage.fingerprint)
                                              (& fp-text)
                                              "build: failed to stage package runtime fingerprint")
                                              [(Err message)
                                                (build-package-clean-stage
                                                  stage)
                                                (io.print-error message)
                                                1]
                                              [(Ok)
                                                (let
                                                  [plan : BuildPackageCommitPlan
                                                    (build-package-commit-plan-add
                                                      (build-package-commit-plan-add
                                                        (build-package-commit-plan-add
                                                          (build-package-commit-plan-add
                                                            (build-package-commit-plan-new)
                                                            (string.copy
                                                              (&
                                                                request.asm-path))
                                                            (string.copy
                                                              (& stage.asm)))
                                                          (string.copy
                                                            (& request.tli-path))
                                                          (string.copy
                                                            (& stage.tli)))
                                                        (string.copy
                                                          (&
                                                            request.artifact-path))
                                                        (string.copy
                                                          (& stage.artifact)))
                                                      (string.copy
                                                        (& fingerprint-path))
                                                      (string.copy
                                                        (& stage.fingerprint)))]
                                                  (when
                                                    tlci-dirty
                                                    (set!
                                                      plan
                                                      (build-package-commit-plan-add
                                                        plan
                                                        (string.copy
                                                          (& request.tlci-path))
                                                        (string.copy
                                                          (& stage.tlci)))))
                                                  (compiler_driver_core.compiler-driver-reset-file-state!)
                                                  (match (build-package-commit-plan-run
                                                    plan)
                                                    [(Err message rollback)
                                                      (build-package-clean-stage-after-rollback
                                                        (& stage)
                                                        (owned_view.compiler-owned-shared-view
                                                          rollback))
                                                      (io.print-error
                                                        (build-package-commit-error-message
                                                          message
                                                          rollback
                                                          stage.dir))
                                                      1]
                                                    [(Ok)
                                                      (unless
                                                        has-tlci
                                                        (let
                                                          [_ : io.ResultIoUnit
                                                            (fs.try-remove-file-if-exists
                                                              (&
                                                                request.tlci-path))]
                                                          unit))
                                                      (build-package-clean-stage
                                                        stage)
                                                      (build-package-announce-freshness
                                                        (string.copy
                                                          (&
                                                            request.artifact-path))
                                                        (if has-tlci
                                                          (string.copy
                                                            (&
                                                              request.tlci-path))
                                                          "")
                                                        true
                                                        tlci-dirty
                                                        request.announce)]))])])]))]))]))]))))])))))

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
      [(Nil) (ast.ast-decl-path-list-new)]
      [(Cons path rest)
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
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
  [manifest-dir : String]
  [deps : load.CompilerPkgDeps]
  [emit-entry : bool]) : i64
  (match (compiler_driver_core.compiler-driver-load-package-preflight-paths
    entry-path
    target
    cfg-names
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view manifest-dir)
    (owned_view.compiler-owned-shared-view deps)
    emit-entry)
    [(Err diag)
      (io.print-error
        (compiler_driver_core.compiler-driver-render-source-diagnostic
          (deref diag)))
      1]
    [(Ok paths)
      (doc_test.doc-test-report-status
        (doc_test.doc-test-typecheck-package-paths-with-roots-and-cfg
          (build-package-doctest-paths owner paths)
          stdlib-roots
          manifest-dir
          deps
          (compiler_driver_core.compiler-driver-target-cfgs
            target
            (target_cfg.compiler-target-user-cfgs cfg-names))))]))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defstruct BuildPackageEmitRequest
    (manifest-path String)
    (manifest load.CompilerPkgManifest)
    (target be_state.CompilerBackendTarget)
    (opt-level i64)
    (profile BuildProfile)
    (mode be_state.CompilerBackendMode)
    (stdlib-roots cli_svec.Vec)
    (producer-identity String)
    (entry-path String)
    (manifest-dir String)
    (kind load.CompilerPkgKind)
    (asm-path String)
    (obj-path String)
    (artifact-path String)
    (tli-path String)
    (tlci-path String)
    (lib-input-transcript String)
    (manifest-link-inputs build_run_core.SourceToolLinkInputs)
    (dep-link-inputs build_run_core.SourceToolLinkInputs)
    (emit-entry bool)
    (compile-cfgs cfg_core.CompilerCfgSnapshot)
    (announce bool)
    (lock-policy BuildPackageLockPolicy)
    (cfg-names cli_svec.Vec)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defenum ResultBuildPackageEmit
    (Finished i64)
    (Preflight cli_svec.Vec bool)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (clone-result-build-package-emit
    [value : (& value ResultBuildPackageEmit)]) : ResultBuildPackageEmit
    (match value
      [(Finished status) (Finished status)]
      [(Preflight inline-sources doctests)
        (Preflight (cli_svec.clone-vec inline-sources) doctests)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-emit-attempt
    [request : (& BuildPackageEmitRequest)]
    [check-closure : bool]) : ResultBuildPackageEmit
    (let
      [home : arena.Arena (arena.current)]
      (with-scratch
        (let
          [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope
            (unsafe
              ;; unsafe: installs the global load session; replaced before this arena ends
              (compiler_driver_core.compiler-driver-package-runtime-scope-new
                home))]
          [result : ResultBuildPackageEmit
            (in-arena
              home
              (unsafe
                ;; unsafe: the runtime scope owns the loaded frontend and TLI catalogs
                (build-package-emit-one-in-runtime-scope
                  (owned_view.compiler-owned-shared-view scope)
                  request
                  check-closure)))]
          (unsafe
            ;; unsafe: restores the enclosing load session before the scratch arena ends
            (match (& result)
              [(Preflight _ _)
                (compiler_driver_core.compiler-driver-package-runtime-scope-release!
                  scope)]
              [_ (build-package-runtime-scope-release! scope)]))
          result)))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-emit-one-with-surface
    [request : (& BuildPackageEmitRequest)]) : i64
    (match (build-package-emit-attempt request true)
      [(Finished status) status]
      [(Preflight inline-sources doctests)
        (let
          [inline-status : i64
            (test_cli_core.tltest-inline-typecheck-package-sources-with-cfg
              inline-sources
              (cli_svec.clone-vec (& request.stdlib-roots))
              (string.copy (& request.manifest-dir))
              (string.copy (& request.manifest.name))
              (load.clone-compiler-pkg-deps (& request.manifest.deps))
              (cfg_core.compiler-cfg-snapshot-to-env (& request.compile-cfgs))
              "typecheck-prefix-inline-build-package")]
          (when (not (= inline-status 0)) (return inline-status))
          (compiler_driver_core.compiler-driver-reset-file-state!)
          (ci.intern-persistent-arena-reset!)
          (when
            doctests
            (let
              [status : i64
                (build-package-run-doctest-worker-or-inline
                  (string.copy (& request.manifest.name))
                  (string.copy (& request.entry-path))
                  (string.copy (& request.manifest-path))
                  (be_state.clone-compiler-backend-target (& request.target))
                  request.opt-level
                  (clone-build-profile (& request.profile))
                  (be_state.clone-compiler-backend-mode (& request.mode))
                  (clone-build-package-lock-policy (& request.lock-policy))
                  (load.clone-compiler-pkg-deps (& request.manifest.deps))
                  (load.clone-compiler-pkg-dep-list
                    (& request.manifest.deps.ordered))
                  (cli_svec.clone-vec (& request.stdlib-roots))
                  (& request.cfg-names)
                  (string.copy (& request.manifest-dir))
                  request.emit-entry)]
              (when (not (= status 0)) (return status))
              (compiler_driver_core.compiler-driver-reset-file-state!)
              (ci.intern-persistent-arena-reset!)))
          (match (build-package-emit-attempt request false)
            [(Finished status) status]
            [(Preflight _ _)
              (io.print-error "build: package preflight did not complete")
              1]))])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-emit-one-in-runtime-scope
    [scope : compiler_driver_core.CompilerDriverPackageRuntimeScope]
    [request : (& BuildPackageEmitRequest)]
    [check-closure : bool]) : ResultBuildPackageEmit
    (let
      [cfgs : sym_i64_env.SymI64Env
        (cfg_core.compiler-cfg-snapshot-to-env (& request.compile-cfgs))]
      [is-lib : bool
        (build-package-kind-lib?
          (load.clone-compiler-pkg-kind (& request.kind)))]
      [req-target : be_state.CompilerBackendTarget
        (be_state.clone-compiler-backend-target (& request.target))]
      (match (compiler_driver_core.compiler-driver-package-runtime-open-tli!
        (owned_view.compiler-owned-shared-view scope)
        (& request.entry-path)
        (& request.manifest-dir)
        (& request.manifest.deps)
        req-target
        (& request.stdlib-roots)
        cfgs
        request.opt-level
        (not is-lib))
        [(Err tli-msg)
          (io.print-error tli-msg)
          (return (Finished 1))]
        [(Ok) unit])
      (match (compiler_driver_core.compiler-driver-package-runtime-load
        (owned_view.compiler-owned-shared-view scope)
        (string.copy (& request.entry-path))
        (cli_svec.clone-vec (& request.stdlib-roots))
        (string.copy (& request.manifest-dir))
        (load.clone-compiler-pkg-deps (& request.manifest.deps))
        request.emit-entry
        cfgs)
        [(Err diag)
          (io.print-error
            (compiler_driver_core.compiler-driver-render-source-diagnostic
              (deref diag)))
          (Finished 1)]
        [(Ok decls paths _ seen)
          (when
            check-closure
            (let
              [files : cli_svec.Vec
                (package_source_core.package-source-reachable-owned-files
                  (&
                    (load.compiler-load-package-reachable-paths
                      (& request.entry-path)
                      (& paths)
                      seen))
                  (& request.manifest-dir)
                  (& request.stdlib-roots))]
              [inline-sources : cli_svec.Vec (cli_svec.new)]
              [doctests : bool false]
              (for [index (iterator.range 0 (cli_svec.len (& files)))]
                (let
                  [path : String (cli_svec.get (& files) index "")]
                  (when
                    (test_cli_core.tltest-source-has-inline-tests?
                      (string.copy (& path)))
                    (cli_svec.push-ref!
                      (&mut inline-sources)
                      (string.copy (& path))))
                  (unless
                    doctests
                    (set!
                      doctests
                      (doc_test.doc-test-package-file-has-examples? (& path))))))
              (when
                (or doctests (> (cli_svec.len (& inline-sources)) 0))
                (return (Preflight inline-sources doctests)))))
          (let
            [owned-paths : ast.AstDeclPathList
              (load.compiler-load-package-owned-paths-for-decls
                (& request.manifest.name)
                (& request.manifest-dir)
                (& request.stdlib-roots)
                (& request.entry-path)
                (& decls)
                (& paths))]
            (if is-lib
              (Finished
                (build-package-emit-lib-tli!
                  scope
                  request
                  decls
                  paths
                  owned-paths
                  cfgs))
              (let
                [metadata-link-inputs : build_run_core.SourceToolLinkInputs
                  (build_run_core.source-tool-link-inputs-from-decls
                    (owned_view.compiler-owned-shared-view decls)
                    (build_run_core.source-tool-link-inputs-empty))]
                ;; The dependency section keeps each package's raw arguments.
                [effective-link-inputs : build_run_core.SourceToolLinkInputs
                  (build_run_core.clone-source-tool-link-inputs
                    (&
                      (build_run_core.source-tool-link-inputs-merge-with
                        (build_run_core.source-tool-link-inputs-merge
                          (build_run_core.clone-source-tool-link-inputs
                            (& request.manifest-link-inputs))
                          metadata-link-inputs)
                        (build_run_core.clone-source-tool-link-inputs
                          (& request.dep-link-inputs))
                        false)))]
                [crt-entry : bool
                  (and
                    request.emit-entry
                    (build_run_core.source-tool-linux-crt-entry?
                      (be_state.clone-compiler-backend-target
                        (& request.target))
                      effective-link-inputs))]
                (Finished
                  (build-package-finish-bin-artifacts
                    scope
                    (& request.manifest-path)
                    (& request.manifest-dir)
                    (& request.manifest)
                    (string.copy (& request.manifest.name))
                    (load.clone-compiler-pkg-kind (& request.kind))
                    (be_state.clone-compiler-backend-target (& request.target))
                    request.opt-level
                    (clone-build-profile (& request.profile))
                    (be_state.clone-compiler-backend-mode (& request.mode))
                    (string.copy (& request.producer-identity))
                    (string.copy (& request.entry-path))
                    request.emit-entry
                    crt-entry
                    decls
                    owned-paths
                    (build-package-output-dir-profile
                      (string.copy (& request.manifest-dir))
                      (string.copy (& request.manifest.name))
                      (clone-build-profile (& request.profile)))
                    (string.copy (& request.asm-path))
                    (string.copy (& request.obj-path))
                    (string.copy (& request.artifact-path))
                    effective-link-inputs
                    request.announce
                    cfgs)))))]))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (build-package-emit-one
    [manifest-path : String]
    [manifest : load.CompilerPkgManifest]
    [target : be_state.CompilerBackendTarget]
    [opt-level : i64]
    [profile : BuildProfile]
    [mode : be_state.CompilerBackendMode]
    [lock-policy : BuildPackageLockPolicy]
    [stdlib-roots : cli_svec.Vec]
    [cfg-names : (& cfg-names cli_svec.Vec)]
    [dep-link-inputs : build_run_core.SourceToolLinkInputs]
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
      [tli-path : String (string.copy (& artifact-paths.tli))]
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
          (io.print-error message)
          1)
        (let
          [compile-cfgs : sym_i64_env.SymI64Env
            (build-package-compile-cfgs
              target
              compile-context.root-compiler
              cfg-names)]
          [lib-input-transcript : String
            (if (build-package-kind-lib? kind)
              (match (package_source_core.package-source-discover-for
                "build"
                (string.copy (& manifest-path))
                true)
                [(Err message)
                  (io.print-error message)
                  (return 1)]
                [(Ok source-set)
                  (match (build-package-v3-extra-inputs
                    (& manifest-path)
                    (& manifest-dir)
                    (& manifest)
                    profile
                    target
                    compile-cfgs
                    (& source-set.sources))
                    [(Err message)
                      (io.print-error message)
                      (return 1)]
                    [(Ok extra-v3)
                      (match (build-package-lib-input-transcript
                        target
                        profile
                        mode
                        opt-level
                        (string.copy (& producer-identity))
                        (string.copy (& asm-path))
                        (string.copy (& obj-path))
                        (string.copy (& artifact-path))
                        extra-v3)
                        [(Err message)
                          (io.print-error message)
                          (return 1)]
                        [(Ok transcript) transcript])])])
              "")]
          [verify-lib-deps? : bool
            (cfg
              dependency-tlci-verification
              (and
                (build-package-kind-lib? kind)
                (>
                  (load.compiler-pkg-dep-list-count
                    (&
                      (load.compiler-pkg-deps-list
                        (load.clone-compiler-pkg-deps (& manifest.deps)))))
                  0)
                (match (env.get "TYPELISP_DEPENDENCY_TLCI_VERIFY")
                  [(EnvSomeString v) (string.eq (& v) "1")]
                  [_ false]))
              false)]
          (when
            (and
              (build-package-kind-lib? kind)
              (not verify-lib-deps?)
              (build-package-lib-fresh?
                (string.copy (& lib-input-transcript))
                (& tli-path)
                (& artifact-path)
                (& tlci-path)
                (&
                  (build-package-runtime-fingerprint-path
                    (string.copy (& artifact-path))))))
            (return
              (build-package-announce-freshness
                artifact-path
                (if (build-package-file-regular? (string.copy (& tlci-path)))
                  tlci-path
                  "")
                false
                false
                announce)))
          (let
            [manifest-link-inputs : build_run_core.SourceToolLinkInputs
              (build-package-manifest-link-inputs
                (owned_view.compiler-owned-shared-view manifest.link)
                (owned_view.compiler-owned-shared-view manifest-dir)
                (build-package-link-owner
                  (owned_view.compiler-owned-shared-view manifest.name)
                  (owned_view.compiler-owned-shared-view manifest-path))
                target)]
            [emit-entry : bool (build-package-kind-entry? kind)]
            (build-package-emit-one-with-surface
              (&
                (BuildPackageEmitRequest
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
                  tli-path
                  tlci-path
                  lib-input-transcript
                  manifest-link-inputs
                  dep-link-inputs
                  emit-entry
                  (cfg_core.compiler-cfg-snapshot-from-env compile-cfgs)
                  announce
                  lock-policy
                  (cli_svec.clone-vec cfg-names))))))))))

(cfg
  (not
    (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci))
  (define (build-package-emit-one
    [_manifest-path : String]
    [_manifest : load.CompilerPkgManifest]
    [_target : be_state.CompilerBackendTarget]
    [_opt-level : i64]
    [_profile : BuildProfile]
    [_mode : be_state.CompilerBackendMode]
    [_lock-policy : BuildPackageLockPolicy]
    [_stdlib-roots : cli_svec.Vec]
    [cfg-names : (& cfg-names cli_svec.Vec)]
    [_dep-link-inputs : build_run_core.SourceToolLinkInputs]
    [_catalog-deps : load.CompilerPkgDepList]
    [_producer-identity : String]
    [_announce : bool]) : i64
    (io.print-error
      "build: package emission requires checked frontend surface support")
    1))

(define (build-package-dependency-catalog-finish [status : i64]) : i64
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    (compiler_dependency_tlci.compiler-dependency-tlci-verification-finish!
      (owned_view.compiler-owned-shared-view state))
    (match (load.compiler-load-session-state-dependency-catalog-release! state)
      [(Ok) status]
      [(Err message)
        (io.print-error
          (str_cat.str-cat
            "build: failed to release dependency catalog mapping: "
            message))
        (if (= status 0)
          1
          status)])))

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

(define (build-package-worker-append-values
  [args : process.ProcessStringList]
  [roots : (& roots cli_svec.Vec)]
  [flag : String]) : process.ProcessStringList
  (let
    [n : i64 (cli_svec.len (& roots))]
    [out : process.ProcessStringList args]
    (for [i (iterator.range 0 n)]
      (set!
        out
        (build-package-worker-append-option
          out
          (string.copy (& flag))
          (cli_svec.get (& roots) i ""))))
    out))

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
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [resolved-deps : load.CompilerPkgDepList]
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]
  [cfg-names : (& cfg-names cli_svec.Vec)]) : process.ProcessStringList
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
        (cli_option.cli-option-opt-level-name opt-level))]
    [debug-args : process.ProcessStringList
      (if (ir.compiler-debug-info-enabled?)
        (build_run_core.source-tool-args-append args6 "--debug")
        args6)]
    [args7 : process.ProcessStringList
      (build-package-lock-policy-arg debug-args lock-policy)]
    [args8 : process.ProcessStringList
      (build-package-worker-append-resolved-deps args7 resolved-deps 0)]
    [sysroot : tli_cli.TliSysrootOptions (tli_cli.tli-active-sysroot-options)]
    [args9 : process.ProcessStringList
      (if (> (string.string-length (& sysroot.explicit-root)) 0)
        (build-package-worker-append-option
          args8
          "--sysroot"
          sysroot.explicit-root)
        args8)]
    [args10 : process.ProcessStringList
      (if sysroot.disabled
        (build_run_core.source-tool-args-append args9 "--no-prebuilt-stdlib")
        args9)]
    (build-package-worker-append-values
      (build-package-worker-append-values args10 stdlib-roots "--stdlib-root")
      cfg-names
      "--cfg")))

(define (build-package-worker-args
  [manifest-path : String]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]
  [cfg-names : (& cfg-names cli_svec.Vec)]) : process.ProcessStringList
  (build-package-worker-args-with-flag
    "--package-worker"
    manifest-path
    target
    opt-level
    profile
    mode
    lock-policy
    (load.compiler-pkg-dep-list-empty)
    stdlib-roots
    (& cfg-names)))

(define (build-package-worker-command
  [manifest-path : String]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]
  [cfg-names : (& cfg-names cli_svec.Vec)]) : process.ProcessCommand
  (process.command
    (io.arg 0)
    (build-package-worker-args
      manifest-path
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots
      (& cfg-names))))

(define (build-package-doctest-worker-command
  [manifest-path : String]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [resolved-deps : load.CompilerPkgDepList]
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]
  [cfg-names : (& cfg-names cli_svec.Vec)]) : process.ProcessCommand
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
      stdlib-roots
      (& cfg-names))))

(define (build-package-worker-spawn-supported?) : bool
  (match (process.output
    (process.command
      (io.arg 0)
      (build_run_core.source-tool-args-append (process.args-empty) "--version")))
    [(OkProcessOutput output) (= (process.output-status output) 0)]
    [(ErrProcessOutput _) false]))

(define (build-package-run-doctest-worker-or-inline
  [owner : String]
  [entry-path : String]
  [manifest-path : String]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [deps : load.CompilerPkgDeps]
  [resolved-deps : load.CompilerPkgDepList]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
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
      stdlib-roots
      (& cfg-names)))
    [(OkProcessOutput output)
      (build_run_core.source-tool-forward-output output)
      (process.output-status output)]
    [(ErrProcessOutput error)
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
            (& cfg-names)
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
    [(Err message)
      (io.print-error message)
      1]
    [(Ok config)
      (let
        [manifest-path : String config.manifest-path]
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-load-manifest
          (owned_view.compiler-owned-shared-view normalized-path))
          [(Err message)
            (io.print-error (str_cat.str-cat "Error: " message))
            1]
          [(Ok manifest)
            (let
              [resolved-deps : load.CompilerPkgDepList config.resolved-deps]
              [resolved-manifest-result : ResultBuildManifest
                (if (= (load.compiler-pkg-dep-list-count resolved-deps) 0)
                  (build-package-resolve-manifest-deps
                    (owned_view.compiler-owned-shared-view normalized-path)
                    manifest
                    config.lock-policy)
                  (Ok
                    (load.CompilerPkgManifest
                      manifest.name
                      manifest.version
                      manifest.kind
                      manifest.entry
                      (load.compiler-pkg-deps-from-list resolved-deps)
                      manifest.link)))]
              (match resolved-manifest-result
                [(Err message)
                  (io.print-error message)
                  1]
                [(Ok resolved-manifest)
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
                        (& config.cfgs)
                        (build_run_core.source-tool-link-inputs-empty)
                        (load.compiler-pkg-deps-list resolved-manifest.deps)
                        producer-identity
                        true))
                    (begin
                      (io.print-error
                        "build: package worker can only build staticlib packages")
                      1))]))]))]))

(define (build-package-doctest-worker-run-from [idx : i64] [count : i64]) : i64
  (match (build-package-worker-config-from idx count)
    [(Err message)
      (io.print-error message)
      1]
    [(Ok config)
      (let
        [manifest-path : String config.manifest-path]
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-load-manifest
          (owned_view.compiler-owned-shared-view normalized-path))
          [(Err message)
            (io.print-error (str_cat.str-cat "Error: " message))
            1]
          [(Ok manifest)
            (let
              [resolved-deps : load.CompilerPkgDepList config.resolved-deps]
              [resolved-manifest-result : ResultBuildManifest
                (if (= (load.compiler-pkg-dep-list-count resolved-deps) 0)
                  (build-package-resolve-manifest-deps
                    (owned_view.compiler-owned-shared-view normalized-path)
                    manifest
                    config.lock-policy)
                  (Ok
                    (load.CompilerPkgManifest
                      manifest.name
                      manifest.version
                      manifest.kind
                      manifest.entry
                      (load.compiler-pkg-deps-from-list resolved-deps)
                      manifest.link)))]
              (match resolved-manifest-result
                [(Err message)
                  (io.print-error message)
                  1]
                [(Ok resolved-manifest)
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
                      (& config.cfgs)
                      manifest-dir
                      resolved-manifest.deps
                      (build-package-kind-entry? kind)))]))]))]))

(define (build-package-async-process-supported?) : bool
  (not (string.eq (env.path-list-separator) ";")))

(define (build-package-deps-built?
  [manifest-dir : String]
  [deps : load.CompilerPkgDepList]
  [built : (& built build_string_i64_map.Map)]) : bool
  (for [index (iterator.range 0 (load.compiler-pkg-dep-list-count deps))]
    (let
      [dep-manifest-path : String
        (build-package-dep-manifest-path
          (owned_view.compiler-owned-shared-view manifest-dir)
          (load.compiler-pkg-dep-list-at deps index))]
      (match (build_string_i64_map.get built dep-manifest-path)
        [(LookupFound _) unit]
        [(LookupMissing) (return false)])))
  true)

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
      built)))

(define (build-package-node-scheduled?
  [scheduled : (& scheduled build_string_i64_map.Map)]
  [manifest-path : String]) : bool
  (match (build_string_i64_map.get (& scheduled) manifest-path)
    [(LookupFound _) true]
    [(LookupMissing) false]))

(define (build-package-graph-worker-list-empty?
  [items : (& items BuildPackageGraphWorkerList)]) : bool
  (match items
    [(Empty) true]
    [(More _ _) false]))

(define (build-package-graph-worker-list-reverse-with
  [remaining : BuildPackageGraphWorkerList]
  [out : BuildPackageGraphWorkerList]) : BuildPackageGraphWorkerList
  (match remaining
    [(Empty) out]
    [(More worker tail)
      (build-package-graph-worker-list-reverse-with
        (deref tail)
        (More worker (box out)))]))

(define (build-package-graph-worker-list-reverse
  [workers : BuildPackageGraphWorkerList]) : BuildPackageGraphWorkerList
  (build-package-graph-worker-list-reverse-with workers (Empty)))

(define (build-package-start-worker
  [node : BuildPackageGraphNode]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : (& stdlib-roots cli_svec.Vec)]
  [cfg-names : (& cfg-names cli_svec.Vec)]) : ResultBuildPackageGraphWorker
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
        stdlib-roots
        (& cfg-names))]
    [_
      (try
        (build-package-validate-graph-node-checkout
          (owned_view.compiler-owned-shared-view node)))]
    (match (process.start command)
      [(OkProcessChild child)
        (Ok (BuildPackageGraphWorker node artifacts child))]
      [(ErrProcessChild error)
        (Err
          (str_cat.str-cat
            "build: failed to start package dependency `"
            name
            "`: "
            (process.error-message error)))])))

(define (build-package-schedule-pass-with
  [nodes : BuildPackageGraphNodeVec]
  [scheduled : build_string_i64_map.Map]
  [built : (& built build_string_i64_map.Map)]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
  [workers : BuildPackageGraphWorkerList]
  [index : i64]
  [count : i64]) : ResultBuildPackageSchedulePass
  (if (>= index count)
    (Ok
      (BuildPackageSchedulePass
        scheduled
        (build-package-graph-worker-list-reverse workers)))
    (let
      [node : BuildPackageGraphNode
        (build-package-graph-node-vec-at nodes index)]
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
          (& cfg-names)
          workers
          (+ index 1)
          count)
        (let
          [worker
            (try
              (build-package-start-worker
                node
                target
                opt-level
                profile
                mode
                lock-policy
                stdlib-roots
                (& cfg-names)))]
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
            (& cfg-names)
            (More worker (box workers))
            (+ index 1)
            count))))))

(define (build-package-schedule-pass
  [nodes : BuildPackageGraphNodeVec]
  [scheduled : build_string_i64_map.Map]
  [built : build_string_i64_map.Map]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]) : ResultBuildPackageSchedulePass
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
      (& cfg-names)
      (Empty)
      0
      count)))

(define (build-package-all-built?
  [nodes : BuildPackageGraphNodeVec]
  [built : (& built build_string_i64_map.Map)]) : bool
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [all-built : bool true]
    (while (and all-built (< index count))
      (let
        [node : BuildPackageGraphNode
          (build-package-graph-node-vec-at nodes index)]
        [manifest-path : String node.manifest-path]
        (match (build_string_i64_map.get (& built) manifest-path)
          [(LookupFound _) unit]
          [(LookupMissing) (set! all-built false)])
        (+= index 1)))
    all-built))

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
    [tli-path : String (string.copy (& worker.artifacts.tli))]
    [result : process.ResultProcessOutput (process.wait (&mut worker.child))]
    (match result
      [(OkProcessOutput output)
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
                [tli-state : BuildPackageArtifactState
                  (build-package-artifact-file-state
                    (owned_view.compiler-owned-shared-view tli-path))]
                (if (build-package-artifact-state-dirty?
                  (owned_view.compiler-owned-shared-view tli-state))
                  (begin
                    (io.print-error
                      (build-package-artifact-status-error-message
                        name
                        "library interface (.tli)"
                        tli-path
                        tli-state))
                    (set!
                      (deref failed-status)
                      (build-package-failure-status (deref failed-status) 1)))
                  (build-string-index-map-put! built manifest-path 1)))))
          (let
            [status : i64 (process.output-status output)]
            (io.print-error
              (str_cat.str-cat
                "build: package dependency `"
                name
                "` failed with status "
                (string.int->string status)))
            (set!
              (deref failed-status)
              (build-package-failure-status (deref failed-status) status))))]
      [(ErrProcessOutput error)
        (io.print-error
          (str_cat.str-cat
            "build: failed to wait for package dependency `"
            name
            "`: "
            (process.error-message error)))
        (set!
          (deref failed-status)
          (build-package-failure-status (deref failed-status) 1))])))

(define (build-package-wait-workers-with
  [workers : BuildPackageGraphWorkerList]
  [built : build_string_i64_map.Map]
  [announce : bool]
  [failed-status : i64]) : ResultBuildPackageWait
  (match workers
    [(Empty)
      (if (= failed-status 0)
        (Ok built)
        (Err failed-status))]
    [(More worker tail)
      (let
        [next-built : build_string_i64_map.Map built]
        [next-failed-status : i64 failed-status]
        (build-package-wait-worker
          (&mut worker)
          (&mut next-built)
          announce
          (&mut next-failed-status))
        (build-package-wait-workers-with
          (deref tail)
          next-built
          announce
          next-failed-status))]))

(define (build-package-wait-workers
  [workers : BuildPackageGraphWorkerList]
  [built : build_string_i64_map.Map]
  [announce : bool]) : ResultBuildPackageWait
  (build-package-wait-workers-with workers built announce 0))

(define (build-package-emit-graph-nodes-parallel-loop
  [nodes : BuildPackageGraphNodeVec]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
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
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (& cfg-names))
      [(Err message)
        (io.print-error message)
        1]
      [(Ok pass)
        (if (build-package-graph-worker-list-empty? (& pass.workers))
          (begin
            (io.print-error
              "build: package dependency scheduler made no progress")
            1)
          (match (build-package-wait-workers pass.workers built announce)
            [(Err status) status]
            [(Ok next-built)
              (build-package-emit-graph-nodes-parallel-loop
                nodes
                target
                opt-level
                profile
                mode
                lock-policy
                stdlib-roots
                (& cfg-names)
                announce
                pass.scheduled
                next-built)]))])))

(define (build-package-emit-graph-nodes-parallel
  [nodes : BuildPackageGraphNodeVec]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [announce : bool]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]) : i64
  (build-package-emit-graph-nodes-parallel-loop
    nodes
    target
    opt-level
    profile
    mode
    lock-policy
    stdlib-roots
    (& cfg-names)
    announce
    (build_string_i64_map.with-capacity 32)
    (build_string_i64_map.with-capacity 32)))

(define (build-package-emit-graph-nodes-serial
  [nodes : BuildPackageGraphNodeVec]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
  [producer-identity : String]
  [announce : bool]) : i64
  (let
    [index : i64 0]
    [count : i64 (build-package-graph-node-vec-len nodes)]
    [status : i64 0]
    (while (and (= status 0) (< index count))
      (let
        [node : BuildPackageGraphNode
          (build-package-graph-node-vec-at nodes index)]
        [validation : ResultBuildString
          (build-package-validate-graph-node-checkout
            (owned_view.compiler-owned-shared-view node))]
        [manifest-path : String node.manifest-path]
        [manifest : load.CompilerPkgManifest node.manifest]
        [node-status : i64
          (match validation
            [(Err message)
              (io.print-error message)
              1]
            [(Ok _)
              (build-package-emit-one
                manifest-path
                (owned_view.compiler-owned-shared-view manifest)
                target
                opt-level
                profile
                mode
                lock-policy
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (& cfg-names)
                (build_run_core.source-tool-link-inputs-empty)
                (load.compiler-pkg-deps-list manifest.deps)
                (owned_view.compiler-owned-shared-view producer-identity)
                announce)])]
        (if (= node-status 0)
          (+= index 1)
          (begin
            (io.print-error
              (str_cat.str-cat
                "build: package dependency `"
                manifest.name
                "` failed with status "
                (string.int->string node-status)))
            (set! status node-status)))))
    status))

(define (build-package-emit-graph-nodes
  [nodes : BuildPackageGraphNodeVec]
  [target : be_state.CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
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
      stdlib-roots
      (& cfg-names))
    (build-package-emit-graph-nodes-serial
      nodes
      target
      opt-level
      profile
      mode
      lock-policy
      stdlib-roots
      (& cfg-names)
      producer-identity
      announce)))

(define (build-doctest-build-source
  [source : String]
  [output : String]
  [has-output : bool]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : cli_svec.Vec]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [link-inputs : build_run_core.SourceToolLinkInputs]) : i64
  (let
    [doctest-status : i64
      (doc_test.doc-test-report-status
        (doc_test.doc-test-typecheck-file-with-roots-and-cfg
          (owned_view.compiler-owned-shared-view source)
          (owned_view.compiler-owned-shared-view stdlib-roots)
          (compiler_driver_core.compiler-driver-target-cfgs
            target
            (target_cfg.compiler-target-user-cfgs (& cfg-names)))))]
    (if (= doctest-status 0)
      (let
        [inline-test-status : i64
          (test_cli_core.tltest-inline-typecheck-file-with-cfg
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view stdlib-roots)
            (compiler_driver_core.compiler-driver-target-cfgs
              target
              (target_cfg.compiler-target-user-cfgs (& cfg-names)))
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
              cfg-names
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
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
  [producer-identity : String]
  [announce : bool]) : i64
  (match (build_run_core.source-tool-parse-target target-text)
    [(Err message)
      (io.print-error message)
      1]
    [(Ok target)
      (let
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-package-resolve-manifest-deps
          (owned_view.compiler-owned-shared-view normalized-path)
          (owned_view.compiler-owned-shared-view manifest)
          lock-policy)
          [(Err message)
            (io.print-error message)
            1]
          [(Ok resolved-manifest)
            (match (build-package-dependency-graph
              (owned_view.compiler-owned-shared-view normalized-path)
              manifest
              (owned_view.compiler-owned-shared-view resolved-manifest))
              [(Err message)
                (io.print-error message)
                1]
              [(Ok graph)
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
                      (& cfg-names)
                      (owned_view.compiler-owned-shared-view producer-identity)
                      announce)]
                  (if (= dep-status 0)
                    (match (build-package-validate-graph-checkouts
                      (owned_view.compiler-owned-shared-view nodes))
                      [(Err message)
                        (io.print-error message)
                        1]
                      [(Ok _)
                        (match (build-package-graph-link-inputs
                          (owned_view.compiler-owned-shared-view nodes)
                          profile
                          target)
                          [(Err message)
                            (io.print-error message)
                            1]
                          [(Ok dep-link-inputs)
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
                              (& cfg-names)
                              dep-link-inputs
                              (build-package-graph-catalog-deps
                                nodes
                                (load.compiler-load-dirname normalized-path)
                                (load.compiler-pkg-deps-list
                                  resolved-manifest.deps))
                              producer-identity
                              announce)])])
                    dep-status))])]))]))

(define (build-package-emit
  [manifest-path : String]
  [manifest : load.CompilerPkgManifest]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : be_state.CompilerBackendMode]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
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
      (& cfg-names)
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
  [cfg-names : (& cfg-names cli_svec.Vec)]
  [producer-identity : String]
  [announce : bool]) : i64
  (match (build_run_core.source-tool-parse-backend-mode mode)
    [(Err message)
      (io.print-error message)
      1]
    [(Ok backend-mode)
      (match (build-load-manifest
        (owned_view.compiler-owned-shared-view manifest-path))
        [(Err message)
          (io.print-error (str_cat.str-cat "Error: " message))
          1]
        [(Ok manifest)
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
            (& cfg-names)
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
  [cfg-names : (& cfg-names cli_svec.Vec)]
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
    (& cfg-names)
    producer-identity
    true))

(define (build-package [config : BuildConfig] [producer-identity : String]) : i64
  (match config
    [(Package
        manifest-path
        has-manifest
        target-text
        has-target
        mode
        profile
        _
        opt-level
        lock-policy
        stdlib-roots
        cfg-names)
      (let
        [resolved-manifest : load.CompilerLoadMaybePath
          (if has-manifest
            (CompilerLoadSomePath manifest-path)
            (build-discover-manifest-up "" 256))]
        (match resolved-manifest
          [(CompilerLoadNoPath)
            (io.print-error
              "could not find typelisp.pkg from '.' or any parent directory")
            1]
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
              (& cfg-names)
              producer-identity)]))]
    [_ 1]))

(define (build-main-from [idx : i64] [producer-identity : String]) : i64
  (match (build-config-from idx (io.arg-count))
    [(Ok config)
      (match (owned_view.compiler-owned-shared-view config)
        [(Source) (build-source-direct-from idx (io.arg-count))]
        [(Package _ _ _ _ _ _ _ _ _ _ _)
          (build-package config producer-identity)])]
    [(Err message)
      (io.print-error message)
      1]))

(define (build-args-contain-manifest? [idx : i64] [count : i64]) : bool
  (if (>= idx count)
    false
    (if (string.eq (io.arg idx) "--manifest-path")
      true
      (build-args-contain-manifest? (+ idx 1) count))))

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
    (while (and (not found) (< i count))
      (let
        [current : String (io.arg i)]
        (match (cli_option.cli-option-lookup (& specs) (& current))
          [(Found _ arity) (+= i (+ arity 1))]
          [(None)
            (if (cli_option.cli-flag? (& current))
              (+= i 1)
              (set! found true))])))
    found))

(define (build-cli-config-from [idx : i64] [count : i64]) : ResultBuildCliConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "build"
        (str_cat.str-cat
          "--cfg <name> --stdlib-root <dir> --target <target> --opt-level <0|1|2|s> -Os
           --debug|-g|--backtrace -o <exe> --backend-mode <mode>
           --manifest-path <file> --profile --release --locked --update-lock "
          (tli_cli.tli-sysroot-cli-options)
          " "
          (build-link-cli-options))
        idx
        count)]
    [source : String ""]
    [has-source : bool false]
    [output : String ""]
    [has-output : bool false]
    [link-inputs : build_run_core.SourceToolLinkInputs
      (build_run_core.source-tool-link-inputs-empty)]
    [sysroot : tli_cli.TliSysrootOptions (tli_cli.tli-sysroot-options)]
    [options : cli_option.CliCompileOptions
      (cli_option.cli-compile-options
        (target_cfg.compiler-target-cfg-host)
        (opt.compiler-optimize-default-level))]
    (while (cli_option.cli-args-next! (&mut args))
      (cond
        [(tli_cli.tli-sysroot-option! (&mut sysroot) (&mut args)) unit]
        [(cli_option.cli-compile-option! (&mut options) (&mut args)) unit]
        [(string.eq args.name "-o")
          (if has-output
            (cli_option.cli-args-fail!
              (&mut args)
              "build: -o was provided more than once")
            (begin
              (set! output (cli_option.cli-args-value (& args)))
              (set! has-output true)))]
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
          (set! source (string.copy (& args.arg)))
          (set! has-source true)]))
    (unless
      args.failed
      (let
        [sysroot-error : String
          (tli_cli.tli-build-sysroot-error (& sysroot) options.target)]
        (when
          (> (string.string-length (& sysroot-error)) 0)
          (cli_option.cli-args-fail! (&mut args) sysroot-error))))
    (unless
      args.failed
      (ir.compiler-debug-info-set-enabled! options.debug)
      (tli_cli.tli-set-active-sysroot-options! (& sysroot)))
    (cond
      [args.failed (Err args.error)]
      [has-source
        (Ok
          (Config
            source
            has-source
            output
            has-output
            (build_run_core.source-tool-backend-target options.target)
            (build_run_core.source-tool-backend-mode options.backend-mode)
            options.stdlib-roots
            options.cfgs
            options.opt-level
            link-inputs))]
      [has-output (Err "build: -o requires a source file argument")]
      [else (Err "build: expected source path")])))

;; Build a source file directly. Manifest builds go through the package parser
;; (`build-main-from`) so `typelisp build` discovers `typelisp.pkg` from the
;; working tree.
(define (build-source-direct-from [idx : i64] [count : i64]) : i64
  (match (build-cli-config-from idx count)
    [(Ok config)
      (match config
        [(Config
            source
            _
            output
            has-output
            target
            mode
            stdlib-roots
            cfg-names
            opt-level
            link-inputs)
          (build-doctest-build-source
            source
            output
            has-output
            target
            stdlib-roots
            cfg-names
            opt-level
            mode
            link-inputs)])]
    [(Err message)
      (io.print-error message)
      1]))

(define (build-direct-from
  [start : i64]
  [count : i64]
  [producer-identity : String]) : i64
  (if (or
    (build-args-contain-manifest? start count)
    (not (build-args-have-source? start count)))
    (build-main-from start producer-identity)
    (build-source-direct-from start count)))

(define (build-package-deps-only-emit
  [manifest-path : String]
  [target-text : String]
  [mode : String]
  [opt-level : i64]
  [profile : BuildProfile]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : (& cfg-names cli_svec.Vec)]
  [producer-identity : String]) : i64
  (match (build_run_core.source-tool-parse-backend-mode mode)
    [(Err message)
      (io.print-error message)
      1]
    [(Ok backend-mode)
      (match (build_run_core.source-tool-parse-target target-text)
        [(Err message)
          (io.print-error message)
          1]
        [(Ok target)
          (match (build-load-manifest (string.copy (& manifest-path)))
            [(Err message)
              (io.print-error (str_cat.str-cat "Error: " message))
              1]
            [(Ok manifest)
              (let
                [normalized-path : String
                  (build-package-normalize-manifest-path manifest-path)]
                (match (build-package-resolve-manifest-deps
                  (string.copy (& normalized-path))
                  (owned_view.compiler-owned-shared-view manifest)
                  lock-policy)
                  [(Err message)
                    (io.print-error message)
                    1]
                  [(Ok resolved-manifest)
                    (match (build-package-dependency-graph
                      (string.copy (& normalized-path))
                      manifest
                      (owned_view.compiler-owned-shared-view resolved-manifest))
                      [(Err message)
                        (io.print-error message)
                        1]
                      [(Ok graph)
                        (build-package-emit-graph-nodes
                          graph.order
                          target
                          opt-level
                          profile
                          backend-mode
                          lock-policy
                          stdlib-roots
                          cfg-names
                          producer-identity
                          false)])]))])])]))

(define (build-package-deps-only-run-from
  [idx : i64]
  [count : i64]
  [producer-identity : String]) : i64
  (match (build-config-from idx count)
    [(Err message)
      (io.print-error message)
      1]
    [(Ok config)
      (match config
        [(Package
            manifest-path
            has-manifest
            target-text
            _
            mode
            profile
            _
            opt-level
            lock-policy
            stdlib-roots
            cfg-names)
          (let
            [resolved-manifest : load.CompilerLoadMaybePath
              (if has-manifest
                (CompilerLoadSomePath manifest-path)
                (build-discover-manifest-up "" 256))]
            (match resolved-manifest
              [(CompilerLoadNoPath)
                (io.print-error
                  "could not find typelisp.pkg from '.' or any parent directory")
                1]
              [(CompilerLoadSomePath path)
                (build-package-deps-only-emit
                  path
                  target-text
                  mode
                  opt-level
                  profile
                  lock-policy
                  stdlib-roots
                  (& cfg-names)
                  producer-identity)]))]
        [(Source)
          (io.print-error "build: --deps-only requires a package manifest")
          1])]))

;; Run the `build` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name). `--direct` remains accepted as a
;; compatibility no-op; the bare form also builds in-process.
(define (build-run-from
  [start : i64]
  [count : i64]
  [producer-identity : String]) : i64
  (tli_cli.tli-reset-active-sysroot-options!)
  (ir.compiler-debug-info-set-enabled! false)
  (ir.compiler-debug-path-remap-clear!)
  (cond
    [(and (> count start) (string.eq (io.arg start) "--package-worker"))
      (build-package-worker-run-from (+ start 1) count producer-identity)]
    [(and (> count start) (string.eq (io.arg start) "--package-doctest-worker"))
      (build-package-doctest-worker-run-from (+ start 1) count)]
    [(and (> count start) (string.eq (io.arg start) "--deps-only"))
      (build-package-deps-only-run-from (+ start 1) count producer-identity)]
    [(and (> count start) (string.eq (io.arg start) "--direct"))
      (build-direct-from (+ start 1) count producer-identity)]
    [else (build-direct-from start count producer-identity)]))