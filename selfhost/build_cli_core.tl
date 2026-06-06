;; build_cli_core.tl - Selfhost build command logic (#622, #1339).
;;
;; Source-file builds assemble and link in-process through stdlib fs/process
;; helpers. Package builds are handled in-process by the selfhost compiler:
;; parse/discover `typelisp.pkg`, emit assembly for the manifest entry, and
;; produce the package artifact selected by manifest kind.
(import "../stdlib/fs.tl")

(import "../stdlib/env.tl")

(import "../stdlib/io.tl")

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
    BuildProfile
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
    CompilerBackendMode
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

(defstruct BuildPackageGraphNode
  (manifest-path String)
  (manifest CompilerPkgManifest))

(defenum BuildPackageGraphNodeList
  (BuildPackageGraphNodeNil)
  (BuildPackageGraphNodeCons
    BuildPackageGraphNode
    (Box BuildPackageGraphNodeList)))

(defstruct BuildPackageGraph
  (order BuildPackageGraphNodeList))

(defstruct BuildPackageGraphState
  (seen StringI64Map)
  (order BuildPackageGraphNodeList))

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

(defenum ResultBuildGitDependency
  (OkBuildGitDependency BuildGitDependency)
  (ErrBuildGitDependency String))

(defenum ResultBuildString
  (OkBuildString String)
  (ErrBuildString String))

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
  (stdlib-roots CompilerLoadRootList))

(defenum ResultBuildPackageWorkerConfig
  (OkBuildPackageWorkerConfig BuildPackageWorkerConfig)
  (ErrBuildPackageWorkerConfig String))

(defstruct BuildPackageGraphWorker
  (node BuildPackageGraphNode)
  (child ProcessChild))

(defenum ResultBuildPackageGraphWorker
  (OkBuildPackageGraphWorker BuildPackageGraphWorker)
  (ErrBuildPackageGraphWorker String))

(defenum BuildPackageGraphWorkerList
  (BuildPackageGraphWorkerNil)
  (BuildPackageGraphWorkerCons
    BuildPackageGraphWorker
    (Box BuildPackageGraphWorkerList)))

(defstruct BuildPackageSchedulePass
  (scheduled StringI64Map)
  (workers BuildPackageGraphWorkerList))

(defenum ResultBuildPackageSchedulePass
  (OkBuildPackageSchedulePass BuildPackageSchedulePass)
  (ErrBuildPackageSchedulePass String))

(defenum ResultBuildPackageWait
  (OkBuildPackageWait StringI64Map)
  (ErrBuildPackageWait i64))

(defenum BuildProfile
  (BuildProfileDev)
  (BuildProfileRelease))

(defenum ResultBuildProfile
  (OkBuildProfile BuildProfile)
  (ErrBuildProfile String))

(define build-default-opt-level : i64
  2)

(define build-package-visit-visiting : i64
  1)

(define build-package-visit-done : i64
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

(define (build-unknown-profile [value : String]) : String
  (build-cat3 "build: unknown profile '" value "'; expected dev or release"))

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
    [(BuildProfileRelease) build-default-opt-level]))

(define (build-parse-profile [value : String]) : ResultBuildProfile
  (cond
    [(string-eq value "dev") (OkBuildProfile (BuildProfileDev))]
    [(string-eq value "release") (OkBuildProfile (BuildProfileRelease))]
    [else (ErrBuildProfile (build-unknown-profile value))]))

(define (build-append-stdlib [stdlib-lines : String] [root : String]) : String
  (string-append stdlib-lines (host-plan-netline "stdlib-root" root)))

(define (build-root-list-append [roots : CompilerLoadRootList] [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil)
      (CompilerLoadRootCons root (box CompilerLoadRootNil))]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons
        head
        (box (build-root-list-append (box-get rest) root)))]))

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
  [profile : BuildProfile]
  [has-profile : bool]
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
              profile
              has-opt-level
              (if has-opt-level
                opt-level
                (build-profile-default-opt-level profile))
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
                profile
                has-profile
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
                profile
                has-profile
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
              profile
              has-profile
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
                  profile
                  has-profile
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
                  profile
                  has-profile
                  opt-level
                  has-opt-level
                  stdlib-lines
                  stdlib-roots)
                (ErrBuildConfig (build-unknown-mode value)))))]
        [(string-eq current "--profile")
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
                    stdlib-lines
                    stdlib-roots)])))]
        [(string-eq current "--release")
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
              stdlib-lines
              stdlib-roots))]
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
                    profile
                    has-profile
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
            profile
            has-profile
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
    (build-default-profile)
    false
    build-default-opt-level
    false
    ""
    CompilerLoadRootNil))

(define (build-package-worker-parse-options
  [idx : i64]
  [count : i64]
  [manifest-path : String]
  [has-manifest : bool]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [profile : BuildProfile]
  [opt-level : i64]
  [stdlib-roots : CompilerLoadRootList]) : ResultBuildPackageWorkerConfig
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
          stdlib-roots))
      (ErrBuildPackageWorkerConfig
        "build: --package-worker requires --manifest-path"))
    (let
      [current : String (arg idx)]
      (cond
        [(string-eq current "--manifest-path")
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
              stdlib-roots))]
        [(string-eq current "--target")
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
                    stdlib-roots)]
                [(ErrSourceToolTarget _)
                  (ErrBuildPackageWorkerConfig (build-cli-unknown-target value))])))]
        [(string-eq current "--backend-mode")
          (if (>= (+ idx 1) count)
            (ErrBuildPackageWorkerConfig
              "build: --backend-mode requires a value")
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
                    stdlib-roots)]
                [(ErrSourceToolBackendMode message)
                  (ErrBuildPackageWorkerConfig message)])))]
        [(string-eq current "--profile")
          (if (>= (+ idx 1) count)
            (ErrBuildPackageWorkerConfig "build: --profile requires a value")
            (match (build-parse-profile (arg (+ idx 1)))
              [(ErrBuildProfile message) (ErrBuildPackageWorkerConfig message)]
              [(OkBuildProfile parsed-profile)
                (build-package-worker-parse-options
                  (+ idx 2)
                  count
                  manifest-path
                  has-manifest
                  target
                  mode
                  parsed-profile
                  opt-level
                  stdlib-roots)]))]
        [(string-eq current "--release")
          (build-package-worker-parse-options
            (+ idx 1)
            count
            manifest-path
            has-manifest
            target
            mode
            (BuildProfileRelease)
            opt-level
            stdlib-roots)]
        [(string-eq current "--opt-level")
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
                  stdlib-roots)
                (ErrBuildPackageWorkerConfig (build-unknown-opt-level value)))))]
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrBuildPackageWorkerConfig
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
              (build-root-list-append stdlib-roots (arg (+ idx 1)))))]
        [(host-plan-flag? current)
          (ErrBuildPackageWorkerConfig
            (string-append "build: unknown package worker flag " current))]
        [else
          (ErrBuildPackageWorkerConfig
            (string-append "build: unexpected package worker argument " current))]))))

(define (build-package-worker-config-from [idx : i64] [count : i64]) : ResultBuildPackageWorkerConfig
  (build-package-worker-parse-options
    idx
    count
    ""
    false
    (source-tool-default-target)
    (BackendModeScalar)
    (build-default-profile)
    build-default-opt-level
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
  (build-package-output-dir-profile manifest-dir name (build-default-profile)))

(define (build-package-output-dir-profile
  [manifest-dir : String]
  [name : String]
  [profile : BuildProfile]) : String
  (compiler-load-join-root-path
    (compiler-load-join-root-path
      (compiler-load-join-root-path
        (compiler-load-join-root-path manifest-dir "target")
        "typelisp")
      (build-profile-name profile))
    name))

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

(define (build-git-checkout-ref [dep : BuildGitDependency]) : String
  (if (string-eq (struct-get dep pin-kind) "branch")
    (string-append "origin/" (struct-get dep pin-value))
    (struct-get dep pin-value)))

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
    "git"
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append (process-args-empty) "clone")
        remote)
      root)))

(define (build-git-checkout-command [root : String] [checkout-ref : String]) : ProcessCommand
  (process-command
    "git"
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append
          (source-tool-args-append
            (source-tool-args-append (process-args-empty) "-C")
            root)
          "checkout")
        "--detach")
      checkout-ref)))

(define (build-git-rev-parse-command [root : String]) : ProcessCommand
  (process-command
    "git"
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append
          (source-tool-args-append (process-args-empty) "-C")
          root)
        "rev-parse")
      "HEAD")))

(define (build-ensure-github-cache-parent
  [manifest-dir : String]
  [alias : String]) : ResultBuildString
  (let
    [target-dir : String (compiler-load-join-root-path manifest-dir "target")]
    [typelisp-dir : String (compiler-load-join-root-path target-dir "typelisp")]
    [deps-dir : String (compiler-load-join-root-path typelisp-dir "git-deps")]
    (cond
      [(not (build-mkdir-ok? target-dir))
        (ErrBuildString
          (build-git-dep-error alias "could not create target directory"))]
      [(not (build-mkdir-ok? typelisp-dir))
        (ErrBuildString
          (build-git-dep-error
            alias
            "could not create target/typelisp directory"))]
      [(not (build-mkdir-ok? deps-dir))
        (ErrBuildString
          (build-git-dep-error
            alias
            "could not create target/typelisp/git-deps directory"))]
      [else (OkBuildString deps-dir)])))

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

(define (build-fetch-github-dependency
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
                        (OkBuildString manifest-path)
                        (ErrBuildString
                          (build-git-dep-error
                            alias
                            "fetched package is missing typelisp.pkg")))])])])]))))

(define (build-package-resolve-dep
  [manifest-dir : String]
  [dep : CompilerPkgDep]) : ResultBuildPkgDep
  (let
    [path : String (struct-get dep path)]
    [alias : String (struct-get dep alias)]
    (if (compiler-load-github-dependency-path? path)
      (match (build-parse-git-dependency alias path)
        [(ErrBuildGitDependency message) (ErrBuildPkgDep message)]
        [(OkBuildGitDependency git-dep)
          (match (build-fetch-github-dependency manifest-dir alias git-dep)
            [(ErrBuildString message) (ErrBuildPkgDep message)]
            [(OkBuildString _)
              (OkBuildPkgDep
                (CompilerPkgDep alias (build-github-dep-relative-root alias)))])])
      (OkBuildPkgDep dep))))

(define (build-package-resolve-deps
  [manifest-dir : String]
  [deps : CompilerPkgDepList]) : ResultBuildPkgDepList
  (match deps
    [(CompilerPkgDepNil) (OkBuildPkgDepList CompilerPkgDepNil)]
    [(CompilerPkgDepCons dep rest)
      (match (build-package-resolve-dep manifest-dir dep)
        [(ErrBuildPkgDep message) (ErrBuildPkgDepList message)]
        [(OkBuildPkgDep resolved-dep)
          (match (build-package-resolve-deps manifest-dir (box-get rest))
            [(ErrBuildPkgDepList message) (ErrBuildPkgDepList message)]
            [(OkBuildPkgDepList resolved-rest)
              (OkBuildPkgDepList
                (CompilerPkgDepCons resolved-dep (box resolved-rest)))])])]))

(define (build-package-resolve-manifest-deps
  [manifest-path : String]
  [manifest : CompilerPkgManifest]) : ResultBuildManifest
  (match (build-package-resolve-deps
    (compiler-load-dirname manifest-path)
    (struct-get manifest deps))
    [(ErrBuildPkgDepList message) (ErrBuildManifest message)]
    [(OkBuildPkgDepList deps)
      (OkBuildManifest
        (CompilerPkgManifest
          (struct-get manifest name)
          (struct-get manifest version)
          (struct-get manifest kind)
          (struct-get manifest entry)
          deps))]))

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

(define (build-package-graph-node-list-append-one
  [items : BuildPackageGraphNodeList]
  [node : BuildPackageGraphNode]) : BuildPackageGraphNodeList
  (match items
    [(BuildPackageGraphNodeNil)
      (BuildPackageGraphNodeCons node (box BuildPackageGraphNodeNil))]
    [(BuildPackageGraphNodeCons head rest)
      (BuildPackageGraphNodeCons
        head
        (box (build-package-graph-node-list-append-one (box-get rest) node)))]))

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
    (build-package-graph-node-list-append-one (struct-get state order) node)))

(define (build-package-load-dep-node
  [manifest-dir : String]
  [dep : CompilerPkgDep]) : ResultBuildPackageGraphNode
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
              dep-manifest)
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
  [stack : BuildPackagePathList]) : ResultBuildPackageGraphState
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
            (struct-get manifest deps)
            visiting
            next-stack)
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
  [stack : BuildPackagePathList]) : ResultBuildPackageGraphState
  (match deps
    [(CompilerPkgDepNil) (OkBuildPackageGraphState state)]
    [(CompilerPkgDepCons dep rest)
      (match (build-package-load-dep-node manifest-dir dep)
        [(ErrBuildPackageGraphNode message) (ErrBuildPackageGraphState message)]
        [(OkBuildPackageGraphNode node)
          (match (build-package-graph-add-node node state stack)
            [(ErrBuildPackageGraphState message)
              (ErrBuildPackageGraphState message)]
            [(OkBuildPackageGraphState next-state)
              (build-package-graph-add-deps
                manifest-dir
                (box-get rest)
                next-state
                stack)])])]))

(define (build-package-dependency-graph
  [manifest-path : String]
  [manifest : CompilerPkgManifest]) : ResultBuildPackageGraph
  (let
    [root-path : String (build-package-normalize-manifest-path manifest-path)]
    [root-dir : String (compiler-load-dirname root-path)]
    [initial : BuildPackageGraphState
      (BuildPackageGraphState
        (string-i64-map-put
          (string-i64-map-with-capacity 32)
          root-path
          build-package-visit-visiting)
        BuildPackageGraphNodeNil)]
    [stack : BuildPackagePathList
      (BuildPackagePathCons root-path (box BuildPackagePathNil))]
    (match (build-package-graph-add-deps
      root-dir
      (struct-get manifest deps)
      initial
      stack)
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
    [typelisp-dir : String (compiler-load-join-root-path target-dir "typelisp")]
    [profile-dir : String
      (compiler-load-join-root-path typelisp-dir (build-profile-name profile))]
    [package-dir : String (compiler-load-join-root-path profile-dir name)]
    (and
      (build-mkdir-ok? target-dir)
      (and
        (build-mkdir-ok? typelisp-dir)
        (and (build-mkdir-ok? profile-dir) (build-mkdir-ok? package-dir))))))

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
  [nodes : BuildPackageGraphNodeList]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : ProcessStringList
  (match nodes
    [(BuildPackageGraphNodeNil) (process-args-empty)]
    [(BuildPackageGraphNodeCons node rest)
      (process-args-append
        (build-package-graph-link-libs (box-get rest) profile target)
        (process-args-single
          (build-package-graph-node-artifact-path node profile target)))]))

(define (build-package-emit-one
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]
  [dep-libs : ProcessStringList]) : i64
  (let
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
    (if (not (build-ensure-package-output-dirs manifest-dir name profile))
      (begin
        (print-error
          (string-append
            "build: failed to create package output directory "
            (build-package-output-dir-profile manifest-dir name profile)))
        1)
      (let
        [dep-link-inputs : SourceToolLinkInputs
          (source-tool-link-inputs-from-archives dep-libs)]
        [emit-entry : bool (build-package-kind-entry? kind)]
        [crt-entry : bool
          (and emit-entry (source-tool-linux-crt-entry? target dep-link-inputs))]
        (match (source-tool-emit-package-assembly
          entry-path
          target
          stdlib-roots
          opt-level
          mode
          manifest-dir
          (struct-get manifest deps)
          emit-entry
          crt-entry)
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
                      (print-string (string-append "Generated: " artifact-path))
                      0)])])])))))

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
  [roots : CompilerLoadRootList]) : ProcessStringList
  (match roots
    [(CompilerLoadRootNil) args]
    [(CompilerLoadRootCons root rest)
      (build-package-worker-append-stdlib-roots
        (build-package-worker-append-option args "--stdlib-root" root)
        (box-get rest))]))

(define (build-package-worker-args
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]) : ProcessStringList
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
    (build-package-worker-append-stdlib-roots args6 stdlib-roots)))

(define (build-package-worker-command
  [manifest-path : String]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]) : ProcessCommand
  (process-command
    (arg 0)
    (build-package-worker-args
      manifest-path
      target
      opt-level
      profile
      mode
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
              manifest)
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
    (build-package-deps-built? manifest-dir (struct-get manifest deps) built)))

(define (build-package-node-scheduled?
  [scheduled : StringI64Map]
  [manifest-path : String]) : bool
  (match (string-i64-map-get scheduled manifest-path)
    [(StringI64MapFound _) true]
    [(StringI64MapMissing) false]))

(define (build-package-graph-worker-list-append-one
  [items : BuildPackageGraphWorkerList]
  [worker : BuildPackageGraphWorker]) : BuildPackageGraphWorkerList
  (match items
    [(BuildPackageGraphWorkerNil)
      (BuildPackageGraphWorkerCons worker (box BuildPackageGraphWorkerNil))]
    [(BuildPackageGraphWorkerCons head rest)
      (BuildPackageGraphWorkerCons
        head
        (box (build-package-graph-worker-list-append-one (box-get rest) worker)))]))

(define (build-package-graph-worker-list-empty?
  [items : BuildPackageGraphWorkerList]) : bool
  (match items
    [(BuildPackageGraphWorkerNil) true]
    [(BuildPackageGraphWorkerCons _ _) false]))

(define (build-package-start-worker
  [node : BuildPackageGraphNode]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]) : ResultBuildPackageGraphWorker
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
  [nodes : BuildPackageGraphNodeList]
  [scheduled : StringI64Map]
  [built : StringI64Map]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]
  [workers : BuildPackageGraphWorkerList]) : ResultBuildPackageSchedulePass
  (match nodes
    [(BuildPackageGraphNodeNil)
      (OkBuildPackageSchedulePass (BuildPackageSchedulePass scheduled workers))]
    [(BuildPackageGraphNodeCons node rest)
      (let
        [manifest-path : String (struct-get node manifest-path)]
        (if (build-package-node-scheduled? scheduled manifest-path)
          (build-package-schedule-pass
            (box-get rest)
            scheduled
            built
            target
            opt-level
            profile
            mode
            stdlib-roots
            workers)
          (if (build-package-node-ready? node built)
            (match (build-package-start-worker
              node
              target
              opt-level
              profile
              mode
              stdlib-roots)
              [(ErrBuildPackageGraphWorker message)
                (ErrBuildPackageSchedulePass message)]
              [(OkBuildPackageGraphWorker worker)
                (build-package-schedule-pass
                  (box-get rest)
                  (string-i64-map-put scheduled manifest-path 1)
                  built
                  target
                  opt-level
                  profile
                  mode
                  stdlib-roots
                  (build-package-graph-worker-list-append-one workers worker))])
            (build-package-schedule-pass
              (box-get rest)
              scheduled
              built
              target
              opt-level
              profile
              mode
              stdlib-roots
              workers))))]))

(define (build-package-all-built?
  [nodes : BuildPackageGraphNodeList]
  [built : StringI64Map]) : bool
  (match nodes
    [(BuildPackageGraphNodeNil) true]
    [(BuildPackageGraphNodeCons node rest)
      (let
        [manifest-path : String (struct-get node manifest-path)]
        (match (string-i64-map-get built manifest-path)
          [(StringI64MapFound _)
            (build-package-all-built? (box-get rest) built)]
          [(StringI64MapMissing) false]))]))

(define (build-package-failure-status [failed-status : i64] [status : i64]) : i64
  (if (= failed-status 0)
    status
    failed-status))

(define (build-package-wait-workers-with
  [workers : BuildPackageGraphWorkerList]
  [built : StringI64Map]
  [failed-status : i64]) : ResultBuildPackageWait
  (match workers
    [(BuildPackageGraphWorkerNil)
      (if (= failed-status 0)
        (OkBuildPackageWait built)
        (ErrBuildPackageWait failed-status))]
    [(BuildPackageGraphWorkerCons worker rest)
      (let
        [node : BuildPackageGraphNode (struct-get worker node)]
        [manifest-path : String (struct-get node manifest-path)]
        [manifest : CompilerPkgManifest (struct-get node manifest)]
        [name : String (struct-get manifest name)]
        [result : ResultProcessOutput (process-wait (struct-get worker child))]
        (match result
          [(OkProcessOutput output)
            (begin
              (source-tool-forward-output output)
              (if (process-success? output)
                (build-package-wait-workers-with
                  (box-get rest)
                  (string-i64-map-put built manifest-path 1)
                  failed-status)
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
                    (build-package-wait-workers-with
                      (box-get rest)
                      built
                      (build-package-failure-status failed-status status))))))]
          [(ErrProcessOutput error)
            (begin
              (print-error
                (string-append
                  "build: failed to wait for package dependency `"
                  (string-append
                    name
                    (string-append "`: " (process-error-message error)))))
              (build-package-wait-workers-with
                (box-get rest)
                built
                (build-package-failure-status failed-status 1)))]))]))

(define (build-package-wait-workers
  [workers : BuildPackageGraphWorkerList]
  [built : StringI64Map]) : ResultBuildPackageWait
  (build-package-wait-workers-with workers built 0))

(define (build-package-emit-graph-nodes-parallel-loop
  [nodes : BuildPackageGraphNodeList]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]
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
      stdlib-roots
      BuildPackageGraphWorkerNil)
      [(ErrBuildPackageSchedulePass message)
        (begin
          (print-error message)
          1)]
      [(OkBuildPackageSchedulePass pass)
        (let
          [workers : BuildPackageGraphWorkerList (struct-get pass workers)]
          (if (build-package-graph-worker-list-empty? workers)
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
                  stdlib-roots
                  (struct-get pass scheduled)
                  next-built)])))])))

(define (build-package-emit-graph-nodes-parallel
  [nodes : BuildPackageGraphNodeList]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (build-package-emit-graph-nodes-parallel-loop
    nodes
    target
    opt-level
    profile
    mode
    stdlib-roots
    (string-i64-map-with-capacity 32)
    (string-i64-map-with-capacity 32)))

(define (build-package-emit-graph-nodes-serial
  [nodes : BuildPackageGraphNodeList]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (match nodes
    [(BuildPackageGraphNodeNil) 0]
    [(BuildPackageGraphNodeCons node rest)
      (let
        [manifest-path : String (struct-get node manifest-path)]
        [manifest : CompilerPkgManifest (struct-get node manifest)]
        [status : i64
          (build-package-emit-one
            manifest-path
            manifest
            target
            opt-level
            profile
            mode
            stdlib-roots
            (process-args-empty))]
        (if (= status 0)
          (build-package-emit-graph-nodes-serial
            (box-get rest)
            target
            opt-level
            profile
            mode
            stdlib-roots)
          (begin
            (print-error
              (string-append
                "build: package dependency `"
                (string-append
                  (struct-get manifest name)
                  (string-append "` failed with status " (int->string status)))))
            status)))]))

(define (build-package-emit-graph-nodes
  [nodes : BuildPackageGraphNodeList]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (if (build-package-async-process-supported?)
    (build-package-emit-graph-nodes-parallel
      nodes
      target
      opt-level
      profile
      mode
      stdlib-roots)
    (build-package-emit-graph-nodes-serial
      nodes
      target
      opt-level
      profile
      mode
      stdlib-roots)))

(define (build-package-emit
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [target-text : String]
  [has-target : bool]
  [opt-level : i64]
  [profile : BuildProfile]
  [mode : CompilerBackendMode]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (match (build-parse-target target-text)
    [(ErrBuildTarget message)
      (begin
        (print-error message)
        1)]
    [(OkBuildTarget target)
      (let
        [normalized-path : String
          (build-package-normalize-manifest-path manifest-path)]
        (match (build-package-resolve-manifest-deps normalized-path manifest)
          [(ErrBuildManifest message)
            (begin
              (print-error message)
              1)]
          [(OkBuildManifest resolved-manifest)
            (match (build-package-dependency-graph
              normalized-path
              resolved-manifest)
              [(ErrBuildPackageGraph message)
                (begin
                  (print-error message)
                  1)]
              [(OkBuildPackageGraph graph)
                (let
                  [nodes : BuildPackageGraphNodeList (struct-get graph order)]
                  [dep-status : i64
                    (build-package-emit-graph-nodes
                      nodes
                      target
                      opt-level
                      profile
                      mode
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
                    dep-status))])]))]))

(define (build-package-from-path
  [manifest-path : String]
  [target-text : String]
  [has-target : bool]
  [mode : String]
  [opt-level : i64]
  [profile : BuildProfile]
  [stdlib-roots : CompilerLoadRootList]) : i64
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
        [(BuildPackageConfig _ _ _ _ _ _ _ _ _) (build-package config)])]
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
  (BuildCliOptionProfile)
  (BuildCliOptionRelease)
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
            mode
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
          (source-tool-build-source
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
    [(and (> count start) (string-eq (arg start) "--package-worker"))
      (build-package-worker-run-from (+ start 1) count)]
    [(and (> count start) (string-eq (arg start) "--direct"))
      (build-direct-from (+ start 1) count)]
    [else (build-direct-from start count)]))