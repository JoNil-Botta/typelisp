;; compiler_check_core.tl - Shared selfhost check/typecheck helpers.
(import compiler_owned_view as owned_view)
(cfg compile-profile (import stdlib.str_cat_runtime as str_cat))
(cfg compile-profile (import stdlib.io))
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(cfg compile-profile (import stdlib.profile))
(import compiler_load)
(import compiler_source_overlay as source_overlay)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_cfg_core as cfg_core)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import compiler_typecheck_api)
(import compiler_typecheck_core as tc)
(import compiler_target_cfg_core as target_cfg)
(import sym_i64_env)

;; The observed consumer runs before checker pools retire. Fact producers
;; supply their observer and publication callback; ordinary check imports do
;; not depend on their record schema or collector.
(defenum CompilerSemanticCheckInput
  (Source String String)
  (File String)
  (PackageEntry String String compiler_load.CompilerPkgDeps bool))

(defstruct CompilerObservedCheckRequest
  (input CompilerSemanticCheckInput)
  (stdlib-roots svec.Vec)
  (cfgs sym_i64_env.SymI64Env)
  (job-state tc.TcJobState)
  (observer tc.TcSemanticObserver)
  (consumer-context i64)
  (consumer (-> i64 unit)))

(defenum ResultCompilerCheck
  (Ok tc.CompilerTypecheckSummary cdiag.CompilerAdvisoryList)
  (Err (Box cdiag.CompilerDiagnosticList) cdiag.CompilerAdvisoryList))

(defenum ResultCompilerCheckWithPaths
  (Ok
    tc.CompilerTypecheckSummary
    ast.AstDeclPathList
    cdiag.CompilerAdvisoryList)
  (Err (Box cdiag.CompilerDiagnosticList) cdiag.CompilerAdvisoryList))

;; A check answered from one admitted overlay generation (#7455): the check's
;; own result and the ledger of every source it consumed, in first-read order.
(defstruct CompilerCheckOverlayResult
  (check ResultCompilerCheck)
  (ledger source_overlay.CompilerSourceLedger))

(defenum ResultCompilerCheckOverlay
  (Checked CompilerCheckOverlayResult)
  (Rejected source_overlay.CompilerSourceOverlayError))

(defstruct CompilerCheckOverlayPackageResult
  (check ResultCompilerCheckWithPaths)
  (ledger source_overlay.CompilerSourceLedger))

(defenum ResultCompilerCheckOverlayPackage
  (Checked CompilerCheckOverlayPackageResult)
  (Rejected source_overlay.CompilerSourceOverlayError))

(define (compiler-check-advisories-for-job [job-state : tc.TcJobState]) : cdiag.CompilerAdvisoryList
  (cdiag.compiler-advisory-sink-snapshot
    (tc.tc-job-state-advisory-sink job-state)))

(define (compiler-check-serial-advisories) : cdiag.CompilerAdvisoryList
  (compiler-check-advisories-for-job (tc.tc-serial-job-state)))

(cfg
  compile-profile
  (define compiler-check-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-check-profile-start) : unit
    (set! compiler-check-profile-start-ms (profile.now-ms))))

(cfg
  compile-profile
  (define (compiler-check-profile-finish [phase : String]) : unit
    (io.print-error
      (str_cat.str-cat
        "compile-profile|check."
        phase
        "|"
        (string.int->string
          (- (profile.now-ms) compiler-check-profile-start-ms))
        "|0|0|0\n"))))

(define (compiler-check-language-cfgs) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-cfgs
    target_cfg.CompilerTargetCfg.Linux
    (cfg_core.compiler-cfg-empty)))

(define (compiler-check-diagnostic-with-fallback-path
  [diag : cdiag.CompilerDiagnostic]
  [path : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-with-fallback-path diag path))

(define (compiler-check-diagnostics-with-fallback-path
  [diagnostics : cdiag.CompilerDiagnosticList]
  [path : String]) : cdiag.CompilerDiagnosticList
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
    [index : i64 0]
    [out : cdiag.CompilerDiagnosticList
      (cdiag.compiler-diagnostic-list-with-capacity count)]
    (begin
      (while (< index count)
        (begin
          (cdiag.compiler-diagnostic-list-push!
            (&mut out)
            (compiler-check-diagnostic-with-fallback-path
              (cdiag.compiler-diagnostic-list-get diagnostics index)
              (owned_view.compiler-owned-shared-view path)))
          (set! index (+ index 1))))
      out)))

(define (compiler-check-diagnostic-before?
  [left : (& left cdiag.CompilerDiagnostic)]
  [right : (& right cdiag.CompilerDiagnostic)]) : bool
  (let
    [left-primary : (& left cdiag.CompilerDiagnosticSpan) (& left.primary)]
    [right-primary : (& right cdiag.CompilerDiagnosticSpan) (& right.primary)]
    (if (string.eq (& left-primary.path) (& right-primary.path))
      (let
        [left-line : i64 left-primary.start-line]
        [right-line : i64 right-primary.start-line]
        (or
          (< left-line right-line)
          (and
            (= left-line right-line)
            (< left-primary.start-col right-primary.start-col))))
      false)))

(define (compiler-check-diagnostic-list-insert-source-order
  [diag : cdiag.CompilerDiagnostic]
  [sorted : (&mut sorted cdiag.CompilerDiagnosticList)]) : unit
  (let
    [count : i64 sorted.len]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (if (compiler-check-diagnostic-before?
          (& diag)
          (cdiag.compiler-diagnostic-list-ref sorted index))
          (set! found true)
          (set! index (+ index 1))))
      (cdiag.compiler-diagnostic-list-insert! sorted index diag))))

(define (compiler-check-diagnostic-list-insert-all-source-order
  [incoming : cdiag.CompilerDiagnosticList]
  [sorted : (&mut sorted cdiag.CompilerDiagnosticList)]) : unit
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count incoming)]
    [index : i64 0]
    (while (< index count)
      (begin
        (compiler-check-diagnostic-list-insert-source-order
          (cdiag.compiler-diagnostic-list-get incoming index)
          sorted)
        (set! index (+ index 1))))))

(define (compiler-check-result-with-parse-diagnostics
  [parse-diagnostics : cdiag.CompilerDiagnosticList]
  [result : ResultCompilerCheck]) : ResultCompilerCheck
  (if (= (cdiag.compiler-diagnostic-list-count parse-diagnostics) 0)
    result
    (let
      [count : i64 (cdiag.compiler-diagnostic-list-count parse-diagnostics)]
      [index : i64 0]
      [owned-parse : cdiag.CompilerDiagnosticList
        (cdiag.compiler-diagnostic-list-with-capacity count)]
      (begin
        (while (< index count)
          (begin
            (cdiag.compiler-diagnostic-list-push!
              (&mut owned-parse)
              (cdiag.compiler-diagnostic-list-get parse-diagnostics index))
            (set! index (+ index 1))))
        (match result
          [(ResultCompilerCheck.Ok _ advisories)
            (ResultCompilerCheck.Err (box owned-parse) advisories)]
          [(ResultCompilerCheck.Err semantic-diagnostics advisories)
            (begin
              (compiler-check-diagnostic-list-insert-all-source-order
                (deref semantic-diagnostics)
                (&mut owned-parse))
              (ResultCompilerCheck.Err (box owned-parse) advisories))])))))

(define (compiler-check-reset-pools!) : unit
  (compiler_load.compiler-load-session-reset-pools!))

(define (compiler-check-reset-interns!) : unit
  (begin
    (compiler_load.compiler-load-session-reset-interns!)
    (tc.compiler-typecheck-reset-intern-owned-state!)))

(define (compiler-check-program
  [path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_typecheck_api.typecheck-compiler-request
      (compiler_typecheck_api.TypecheckRequest
        (compiler_load.compiler-load-serial-test-session-state)
        (tc.tc-prefix-snapshot-serial-test-cache-state-shared-view)
        job-state
        (ast.ast-program decls)
        paths
        stdlib-roots
        cfgs
        cache-scope
        (ast.ast-node-pool-context-capture-active)
        (ci.intern-compat-state-capture-active)
        (tc.tc-job-state-semantic-observer job-state)))
      [(tc.ResultCompilerTypecheck.Ok summary)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Ok
            summary
            (compiler-check-advisories-for-job job-state)))]
      [(tc.ResultCompilerTypecheck.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Err
            (box
              (compiler-check-diagnostics-with-fallback-path (deref diag) path))
            (compiler-check-advisories-for-job job-state)))])))

(define (compiler-check-loaded-with-prelude
  [path : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [loaded : compiler_load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (match loaded
    [(compiler_load.ResultCompilerLoadWithPaths.Ok
        entry-decls
        entry-paths
        entry-modules
        _)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (compiler-check-program
          path
          (compiler_load.compiler-load-decl-list-append
            prelude-decls
            entry-decls)
          (compiler_load.compiler-load-decl-path-list-append
            prelude-paths
            (ast.ast-decl-path-list-with-modules entry-paths entry-modules))
          stdlib-roots
          cfgs
          cache-scope
          job-state))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err
          (cdiag.compiler-diagnostic-list-box-single diag)
          (compiler-check-advisories-for-job job-state)))]))

(define (compiler-check-source-with-prelude-recovery
  [path : String]
  [source : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [prelude-seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (match (parser.parse-ast-source-recovery-diagnostic-with-cfg
    (owned_view.compiler-owned-shared-view path)
    source
    cfgs)
    [(parser.ResultAstProgramRecovery.Fatal diagnostics)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err
          diagnostics
          (compiler-check-advisories-for-job job-state)))]
    [(parser.ResultAstProgramRecovery.Parsed program diagnostics)
      (let
        [parse-identity : compiler_load.CompilerLoadParseIdentity
          (compiler_load.compiler-load-parse-identity
            (owned_view.compiler-owned-shared-view path)
            (compiler_load.compiler-load-canonical-module-id-from-path path)
            ast.AstMaybeModuleName.No)]
        [loaded : compiler_load.ResultCompilerLoadWithPaths
          (compiler_load.compiler-load-program-with-paths-and-roots-expect-cfg
            path
            program
            prelude-seen
            (owned_view.compiler-owned-shared-view stdlib-roots)
            ast.AstMaybeModuleName.No
            cfgs
            parse-identity)]
        (compiler-check-result-with-parse-diagnostics
          (deref diagnostics)
          (compiler-check-loaded-with-prelude
            path
            prelude-decls
            prelude-paths
            loaded
            stdlib-roots
            cfgs
            cache-scope
            job-state)))]))

(define (compiler-check-loaded-cache-with-paths
  [path : String]
  [loaded : compiler_load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheckWithPaths
  (match loaded
    [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
      (let
        [owned-paths : ast.AstDeclPathList
          (ast.ast-decl-path-list-with-modules paths modules)]
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (match (compiler-check-program
            path
            decls
            (owned_view.compiler-owned-shared-view owned-paths)
            stdlib-roots
            cfgs
            cache-scope
            job-state)
            [(ResultCompilerCheck.Ok summary advisories)
              (ResultCompilerCheckWithPaths.Ok summary owned-paths advisories)]
            [(ResultCompilerCheck.Err diag advisories)
              (ResultCompilerCheckWithPaths.Err diag advisories)])))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheckWithPaths.Err
          (cdiag.compiler-diagnostic-list-box-single diag)
          (compiler-check-advisories-for-job job-state)))]))

(define (compiler-check-file-with-roots
  [path : String]
  [stdlib-roots : svec.Vec]) : ResultCompilerCheck
  (compiler-check-file-with-roots-and-cfg
    path
    stdlib-roots
    (compiler-check-language-cfgs)))

(define (compiler-check-file-with-roots-and-cfg
  [path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg
    (owned_view.compiler-owned-shared-view path)
    (compiler_load.compiler-load-session-read-source-text path)
    stdlib-roots
    cfgs))

(define (compiler-check-package-source-with-prelude-recovery
  [path : String]
  [source : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [prelude-seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (match (parser.parse-ast-source-recovery-diagnostic-with-cfg
    (owned_view.compiler-owned-shared-view path)
    source
    cfgs)
    [(parser.ResultAstProgramRecovery.Fatal diagnostics)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err diagnostics (compiler-check-serial-advisories)))]
    [(parser.ResultAstProgramRecovery.Parsed program diagnostics)
      (let
        [parse-identity : compiler_load.CompilerLoadParseIdentity
          (compiler_load.compiler-load-parse-identity
            (owned_view.compiler-owned-shared-view path)
            (compiler_load.compiler-load-canonical-module-id-from-path path)
            ast.AstMaybeModuleName.No)]
        [loaded : compiler_load.ResultCompilerLoadWithPaths
          (compiler_load.compiler-load-package-program-with-paths-and-roots-expect
            path
            program
            prelude-seen
            (owned_view.compiler-owned-shared-view stdlib-roots)
            ast.AstMaybeModuleName.No
            manifest-dir
            deps
            cfgs
            parse-identity)]
        (compiler-check-result-with-parse-diagnostics
          (deref diagnostics)
          (compiler-check-loaded-with-prelude
            path
            prelude-decls
            prelude-paths
            loaded
            (owned_view.compiler-owned-shared-view stdlib-roots)
            cfgs
            (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
              "typecheck-prefix-check"
              stdlib-roots
              cfgs)
            (tc.tc-serial-job-state))))]))

(define (compiler-check-package-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (tc.tc-job-state-reset-advisories! (tc.tc-serial-job-state))
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_load.compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view deps)
      cfgs)
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-package-source-with-prelude-recovery
          path
          source
          prelude-decls
          (ast.ast-decl-path-list-with-modules prelude-paths prelude-modules)
          prelude-seen
          stdlib-roots
          manifest-dir
          deps
          cfgs)]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err
            (cdiag.compiler-diagnostic-list-box-single diag)
            (compiler-check-serial-advisories)))])))

(define (compiler-check-package-entry-file-with-roots-and-cfg
  [path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]
  [job-state : tc.TcJobState]) : ResultCompilerCheckWithPaths
  (begin
    (compiler-check-reset-pools!)
    (tc.tc-job-state-reset-advisories! job-state)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-loaded-cache-with-paths
      (owned_view.compiler-owned-shared-view path)
      (compiler_load.compiler-load-package-file-with-runtime-cfg
        path
        (owned_view.compiler-owned-shared-view stdlib-roots)
        manifest-dir
        deps
        emit-entry
        cfgs)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      cfgs
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-check"
        stdlib-roots
        cfgs)
      job-state)))

(define (compiler-check-source [path : String] [source : String]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg
    path
    source
    (svec.new)
    (compiler-check-language-cfgs)))

(define (compiler-check-observed-request
  [request : CompilerObservedCheckRequest]) : ResultCompilerCheck
  (let
    [job : tc.TcJobState request.job-state]
    [parse-state : parser.CompilerParseState (parser.compiler-parse-state-new)]
    [_binding-tokens : unit
      (parser.compiler-parse-state-set-binding-origins! (& parse-state) true)]
    [parse-cfgs : sym_i64_env.SymI64Env
      (parser.compiler-parse-state-cfgs
        parse-state
        (owned_view.compiler-owned-shared-view request.cfgs))]
    [previous : tc.TcSemanticObserver (tc.tc-job-state-semantic-observer job)]
    [_install : unit
      (tc.tc-job-state-set-semantic-observer! job request.observer)]
    [result : ResultCompilerCheck
      (match request.input
        [(CompilerSemanticCheckInput.Source path source)
          (compiler-check-source-with-roots-and-cfg-and-job-state
            path
            source
            request.stdlib-roots
            parse-cfgs
            job)]
        [(CompilerSemanticCheckInput.File path)
          (compiler-check-source-with-roots-and-cfg-and-job-state
            (owned_view.compiler-owned-shared-view path)
            (compiler_load.compiler-load-session-read-source-text path)
            request.stdlib-roots
            parse-cfgs
            job)]
        [(CompilerSemanticCheckInput.PackageEntry
            path
            manifest-dir
            deps
            emit-entry)
          (match (compiler-check-package-entry-file-with-roots-and-cfg
            path
            request.stdlib-roots
            manifest-dir
            deps
            emit-entry
            parse-cfgs
            job)
            [(ResultCompilerCheckWithPaths.Ok summary _ advisories)
              (ResultCompilerCheck.Ok summary advisories)]
            [(ResultCompilerCheckWithPaths.Err diagnostics advisories)
              (ResultCompilerCheck.Err diagnostics advisories)])])]
    (begin
      (tc.tc-job-state-set-semantic-observer! job previous)
      (request.consumer request.consumer-context)
      result)))

(define (compiler-check-source-with-roots-and-cfg-and-job-state
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (tc.tc-job-state-reset-advisories! job-state)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      cfgs)
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-source-with-prelude-recovery
          path
          source
          prelude-decls
          (ast.ast-decl-path-list-with-modules prelude-paths prelude-modules)
          prelude-seen
          (owned_view.compiler-owned-shared-view stdlib-roots)
          cfgs
          (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            stdlib-roots
            cfgs)
          job-state)]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err
            (cdiag.compiler-diagnostic-list-box-single diag)
            (compiler-check-advisories-for-job job-state)))])))

(define (compiler-check-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg-and-job-state
    path
    source
    stdlib-roots
    cfgs
    (tc.tc-serial-job-state)))

;; An overlay may only replace sources outside every stdlib root.
(define (compiler-check-overlay-editable
  [overlay : (& overlay source_overlay.CompilerSourceOverlay)]
  [stdlib-roots : (& stdlib-roots svec.Vec)]) : source_overlay.CompilerSourceOverlayStatus
  (let
    [count : i64 (svec.len stdlib-roots)]
    [index : i64 0]
    [rejected : bool false]
    [status : source_overlay.CompilerSourceOverlayStatus
      (source_overlay.CompilerSourceOverlayStatus.Ok)]
    (begin
      (while (and (not rejected) (< index count))
        (let
          [root : String (svec.get stdlib-roots index "")]
          (begin
            (match (source_overlay.compiler-source-overlay-check-not-under
              overlay
              (& root))
              [(source_overlay.CompilerSourceOverlayStatus.Err failure)
                (begin
                  (set!
                    status
                    (source_overlay.CompilerSourceOverlayStatus.Err failure))
                  (set! rejected true))]
              [(source_overlay.CompilerSourceOverlayStatus.Ok) unit])
            (set! index (+ index 1)))))
      status)))

;; The ledger's verdict on a finished overlay check: a recording failure, or,
;; when the check `passed`, an admitted entry it never read and whose candidate
;; it therefore did not check. A failing check keeps its diagnostics however
;; many entries it stopped short of.
(define (compiler-check-overlay-ledger-status
  [overlay : (& overlay source_overlay.CompilerSourceOverlay)]
  [ledger : (& ledger source_overlay.CompilerSourceLedger)]
  [passed : bool]) : source_overlay.CompilerSourceOverlayStatus
  (if (source_overlay.compiler-source-ledger-failed? ledger)
    (source_overlay.CompilerSourceOverlayStatus.Err
      (source_overlay.compiler-source-ledger-failure ledger))
    (let
      [unread : svec.Vec
        (source_overlay.compiler-source-overlay-unread overlay ledger)]
      [first : String (svec.get (& unread) 0 "")]
      (if (or (not passed) (= (svec.len (& unread)) 0))
        (source_overlay.CompilerSourceOverlayStatus.Ok)
        (source_overlay.CompilerSourceOverlayStatus.Err
          (source_overlay.compiler-source-overlay-error
            source_overlay.compiler-source-overlay-error-unread
            (& first)
            "the check never read an admitted overlay source"))))))

;; Check `path` with `overlay` answering its admitted sources. The root and
;; every import are resolved exactly as in `compiler-check-file-with-roots-and-cfg`;
;; only the bytes of an admitted resolved source differ. The overlay is
;; installed on the serial session for the duration of the check.
(define (compiler-check-file-with-overlay
  [path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [overlay : source_overlay.CompilerSourceOverlay]) : ResultCompilerCheckOverlay
  (match (compiler-check-overlay-editable (& overlay) (& stdlib-roots))
    [(source_overlay.CompilerSourceOverlayStatus.Err failure)
      (ResultCompilerCheckOverlay.Rejected failure)]
    [(source_overlay.CompilerSourceOverlayStatus.Ok)
      (let
        [state : compiler_load.CompilerLoadSessionState
          (compiler_load.compiler-load-serial-test-session-state)]
        [_install : unit
          (compiler_load.compiler-load-session-state-source-provider-install!
            (owned_view.compiler-owned-shared-view state)
            (owned_view.compiler-owned-shared-view overlay))]
        [source : String
          (compiler_load.compiler-load-session-read-source-text (& path))]
        [check : ResultCompilerCheck
          (compiler-check-source-with-roots-and-cfg
            path
            source
            stdlib-roots
            cfgs)]
        [ledger : source_overlay.CompilerSourceLedger
          (compiler_load.compiler-load-session-state-source-provider-finish!
            state)]
        (match (compiler-check-overlay-ledger-status
          (& overlay)
          (& ledger)
          (match (& check)
            [(ResultCompilerCheck.Ok _ _) true]
            [(ResultCompilerCheck.Err _ _) false]))
          [(source_overlay.CompilerSourceOverlayStatus.Err failure)
            (ResultCompilerCheckOverlay.Rejected failure)]
          [(source_overlay.CompilerSourceOverlayStatus.Ok)
            (ResultCompilerCheckOverlay.Checked
              (CompilerCheckOverlayResult check ledger))]))]))

;; The package-entry form of `compiler-check-file-with-overlay`.
(define (compiler-check-package-entry-file-with-overlay
  [path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]
  [overlay : source_overlay.CompilerSourceOverlay]) : ResultCompilerCheckOverlayPackage
  (match (compiler-check-overlay-editable (& overlay) (& stdlib-roots))
    [(source_overlay.CompilerSourceOverlayStatus.Err failure)
      (ResultCompilerCheckOverlayPackage.Rejected failure)]
    [(source_overlay.CompilerSourceOverlayStatus.Ok)
      (let
        [state : compiler_load.CompilerLoadSessionState
          (compiler_load.compiler-load-serial-test-session-state)]
        [_install : unit
          (compiler_load.compiler-load-session-state-source-provider-install!
            (owned_view.compiler-owned-shared-view state)
            (owned_view.compiler-owned-shared-view overlay))]
        [check : ResultCompilerCheckWithPaths
          (compiler-check-package-entry-file-with-roots-and-cfg
            path
            stdlib-roots
            manifest-dir
            deps
            emit-entry
            cfgs
            (tc.tc-serial-job-state))]
        [ledger : source_overlay.CompilerSourceLedger
          (compiler_load.compiler-load-session-state-source-provider-finish!
            state)]
        (match (compiler-check-overlay-ledger-status
          (& overlay)
          (& ledger)
          (match (& check)
            [(ResultCompilerCheckWithPaths.Ok _ _ _) true]
            [(ResultCompilerCheckWithPaths.Err _ _) false]))
          [(source_overlay.CompilerSourceOverlayStatus.Err failure)
            (ResultCompilerCheckOverlayPackage.Rejected failure)]
          [(source_overlay.CompilerSourceOverlayStatus.Ok)
            (ResultCompilerCheckOverlayPackage.Checked
              (CompilerCheckOverlayPackageResult check ledger))]))]))