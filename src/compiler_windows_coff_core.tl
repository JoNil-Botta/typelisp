;; compiler_windows_coff_core.tl - Shared Windows COFF linkability and
;; one-optimization object-or-assembly emission.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.text_buf)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as windows_coff_svec)
(import compiler_object as cobj)
(import compiler_object_asm)
(import compiler_profile_state as profile_state)
(import compiler_object_coff)
(import compiler_driver_core)
(import compiler_typecheck_core)
(import compiler_ast_types)
(import compiler_backend)
(import compiler_ir_types)
(import compiler_diagnostic)
(import compiler_optimize)
(import sym_i64_env)

(defenum CompilerWindowsCoffLinkability
  (Linkable)
  (Unavailable String))

(defenum CompilerWindowsBatchSideAssembly
  (None)
  (Some String))

(defenum ResultCompilerWindowsBatchArtifact
  (CoffObject String CompilerWindowsBatchSideAssembly)
  (Assembly text_buf.TextBuf String)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(define (compiler-windows-coff-extern-linkable?
  [name : String]
  [kind : cobj.CompilerObjectSymbolKind]) : bool
  (and
    (cobj.compiler-object-symbol-kind-eq?
      kind
      (cobj.CompilerObjectSymbolKind.Function))
    (or
      (string.eq name "ExitProcess")
      (string.eq name "GetCommandLineA")
      (string.eq name "GetStdHandle")
      (string.eq name "WriteFile")
      (string.eq name "VirtualAlloc")
      (string.eq name "VirtualFree"))))

(define (compiler-windows-coff-relocation-target-linkable?
  [symbols : cobj.CompilerObjectSymbolList]
  [target : String]) : bool
  (let
    [count : i64
      (cobj.compiler-object-symbol-list-count
        (owned_view.compiler-owned-shared-view symbols))]
    [index : i64 0]
    [ok : bool true]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (match (cobj.compiler-object-symbol-list-ref
          (owned_view.compiler-owned-shared-view symbols)
          index)
          [(cobj.CompilerObjectSymbol.Symbol name binding kind _)
            (if (string.eq name target)
              (begin
                (match binding
                  [(cobj.CompilerObjectSymbolBinding.Extern)
                    (set! ok (compiler-windows-coff-extern-linkable? name kind))]
                  [_ (set! ok true)])
                (set! done true))
              (set! index (+ index 1)))]))
      ok)))

(define (compiler-windows-coff-relocations-linkable?
  [symbols : cobj.CompilerObjectSymbolList]
  [relocs : cobj.CompilerObjectRelocationList]) : bool
  (let
    [count : i64
      (cobj.compiler-object-relocation-list-count
        (owned_view.compiler-owned-shared-view relocs))]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-relocation-list-ref
          (owned_view.compiler-owned-shared-view relocs)
          index)
          [(cobj.CompilerObjectRelocation.Relocation _ _ _ target)
            (if (compiler-windows-coff-relocation-target-linkable?
              (owned_view.compiler-owned-shared-view symbols)
              target)
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-windows-coff-linkability [image : cobj.CompilerObjectImage]) : CompilerWindowsCoffLinkability
  (cond
    [(not
        (compiler_object_coff.compiler-object-coff-image-supported?
          (owned_view.compiler-owned-shared-view image)))
      (CompilerWindowsCoffLinkability.Unavailable "unsupported-coff-image")]
    [(not
        (compiler-windows-coff-relocations-linkable?
          (owned_view.compiler-owned-shared-view image.symbols)
          (owned_view.compiler-owned-shared-view image.relocations)))
      (CompilerWindowsCoffLinkability.Unavailable
        "unsupported-external-relocation")]
    [(not
        (cobj.compiler-object-symbol-list-contains?
          (owned_view.compiler-owned-shared-view image.symbols)
          "_tl_start"
          (cobj.CompilerObjectSymbolBinding.Export)
          (cobj.CompilerObjectSymbolKind.Function)))
      (CompilerWindowsCoffLinkability.Unavailable "missing-entry-symbol")]
    [(<
        (compiler_object_coff.compiler-object-coff-section-label-offset
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Text)
          "tl_setup_argv")
        0)
      (CompilerWindowsCoffLinkability.Unavailable "missing-runtime-entry")]
    [(<=
        (compiler_object_coff.compiler-object-coff-section-raw-size
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Text))
        0)
      (CompilerWindowsCoffLinkability.Unavailable "empty-text-section")]
    [else (CompilerWindowsCoffLinkability.Linkable)]))

(define (compiler-windows-coff-linkable? [image : cobj.CompilerObjectImage]) : bool
  (match (compiler-windows-coff-linkability image)
    [(CompilerWindowsCoffLinkability.Linkable) true]
    [(CompilerWindowsCoffLinkability.Unavailable _) false]))

(define (compiler-windows-batch-diagnostic
  [input-path : String]
  [message : String]) : (Box compiler_diagnostic.CompilerDiagnostic)
  (box (compiler_diagnostic.compiler-diagnostic-at-start input-path message)))

(define (compiler-windows-batch-backend-diagnostic
  [input-path : String]
  [diag : (Box compiler_diagnostic.CompilerDiagnostic)]) : (Box
    compiler_diagnostic.CompilerDiagnostic)
  (box
    (compiler_diagnostic.compiler-diagnostic-with-fallback-path
      (owned_view.compiler-owned-box-shared-view diag)
      input-path)))

(define (compiler-windows-batch-emit-assembly
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [mode : compiler_backend.CompilerBackendMode]
  [category : String]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerWindowsBatchArtifact
  (begin
    (cfg
      compile-profile
      (compiler_driver_core.compiler-driver-profile-start-phase profile-state))
    (match (compiler_backend.compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt-and-profile-state-backend-state
      backend-state
      pools
      program
      (compiler_backend.CompilerBackendTarget.Windows)
      mode
      spans
      true
      false
      profile-state)
      [(compiler_backend.ResultCompilerBackendBuffer.Ok asm)
        (begin
          (cfg
            compile-profile
            (compiler_driver_core.compiler-driver-profile-finish-phase
              profile-state
              "backend.assembly"))
          (compiler_driver_core.compiler-driver-allocation-profile-snapshot!
            "backend.assembly")
          (ResultCompilerWindowsBatchArtifact.Assembly asm category))]
      [(compiler_backend.ResultCompilerBackendBuffer.Err diag)
        (begin
          (cfg
            compile-profile
            (compiler_driver_core.compiler-driver-profile-finish-phase
              profile-state
              "backend.assembly"))
          (compiler_driver_core.compiler-driver-allocation-profile-snapshot!
            "backend.assembly-error")
          (ResultCompilerWindowsBatchArtifact.Err
            (compiler-windows-batch-backend-diagnostic input-path diag)))])))

(define (compiler-windows-coff-object-program-supported?
  [backend-state : compiler_backend.CompilerBackendState]
  [program : compiler_ir_types.CompilerIrProgram]) : bool
  (match (compiler_backend.compiler-backend-object-program-eligibility
    backend-state
    program)
    [(compiler_backend.CompilerBackendObjectEligibility.Eligible) true]
    [(compiler_backend.CompilerBackendObjectEligibility.Unsupported _) false]))

(define (compiler-windows-batch-emit-optimized
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [mode : compiler_backend.CompilerBackendMode]
  [force-assembly : bool]
  [emit-side-assembly : bool]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerWindowsBatchArtifact
  (if force-assembly
    (compiler-windows-batch-emit-assembly
      backend-state
      pools
      input-path
      program
      spans
      mode
      "forced-assembly"
      profile-state)
    (if (not
      (compiler-windows-coff-object-program-supported?
        (owned_view.compiler-owned-shared-view backend-state)
        (owned_view.compiler-owned-shared-view program)))
      (compiler-windows-batch-emit-assembly
        backend-state
        pools
        input-path
        program
        spans
        mode
        (compiler_backend.compiler-backend-object-unsupported-semantics-category)
        profile-state)
      (begin
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-profile-start-phase
            profile-state))
        (match (compiler_backend.compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
          backend-state
          (owned_view.compiler-owned-shared-view pools)
          (owned_view.compiler-owned-shared-view program)
          (compiler_backend.CompilerBackendTarget.Windows)
          mode
          (owned_view.compiler-owned-shared-view spans)
          true
          false
          profile-state)
          [(compiler_backend.ResultCompilerBackendObject.Ok image)
            (begin
              (cfg
                compile-profile
                (compiler_driver_core.compiler-driver-profile-finish-phase
                  profile-state
                  "backend.object-image"))
              (compiler_driver_core.compiler-driver-allocation-profile-snapshot!
                "backend.object-image")
              (match (compiler-windows-coff-linkability
                (owned_view.compiler-owned-shared-view image))
                [(CompilerWindowsCoffLinkability.Linkable)
                  (begin
                    (cfg
                      compile-profile
                      (compiler_driver_core.compiler-driver-profile-start-phase
                        profile-state))
                    (match (compiler_object_coff.compiler-object-coff-render
                      (owned_view.compiler-owned-shared-view image))
                      [(compiler_object_coff.ResultCompilerObjectCoff.Ok object)
                        (begin
                          (cfg
                            compile-profile
                            (compiler_driver_core.compiler-driver-profile-finish-phase
                              profile-state
                              "render.coff-object"))
                          (compiler_driver_core.compiler-driver-allocation-profile-snapshot!
                            "render.coff-object")
                          (if emit-side-assembly
                            (match (compiler_object_asm.compiler-object-asm-render
                              image)
                              [(compiler_object_asm.ResultCompilerObjectAsm.Ok
                                  asm)
                                (ResultCompilerWindowsBatchArtifact.CoffObject
                                  object
                                  (CompilerWindowsBatchSideAssembly.Some asm))]
                              [(compiler_object_asm.ResultCompilerObjectAsm.Err
                                  message)
                                (ResultCompilerWindowsBatchArtifact.Err
                                  (compiler-windows-batch-diagnostic
                                    input-path
                                    (str_cat.str-cat
                                      "assembly side artifact rendering failed: "
                                      message)))])
                            (ResultCompilerWindowsBatchArtifact.CoffObject
                              object
                              CompilerWindowsBatchSideAssembly.None)))]
                      [(compiler_object_coff.ResultCompilerObjectCoff.Err
                          message)
                        (begin
                          (cfg
                            compile-profile
                            (compiler_driver_core.compiler-driver-profile-finish-phase
                              profile-state
                              "render.coff-object"))
                          (ResultCompilerWindowsBatchArtifact.Err
                            (compiler-windows-batch-diagnostic
                              input-path
                              (str_cat.str-cat
                                "COFF serialization failed: "
                                message))))]))]
                [(CompilerWindowsCoffLinkability.Unavailable category)
                  (compiler-windows-batch-emit-assembly
                    backend-state
                    pools
                    input-path
                    program
                    spans
                    mode
                    category
                    profile-state)]))]
          [(compiler_backend.ResultCompilerBackendObject.Err diag)
            (begin
              (cfg
                compile-profile
                (compiler_driver_core.compiler-driver-profile-finish-phase
                  profile-state
                  "backend.object-image"))
              (compiler_driver_core.compiler-driver-allocation-profile-snapshot!
                "backend.object-image-error")
              (ResultCompilerWindowsBatchArtifact.Err
                (compiler-windows-batch-backend-diagnostic input-path diag)))])))))

(define (compiler-windows-batch-emit-lowered
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [force-assembly : bool]
  [emit-side-assembly : bool]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerWindowsBatchArtifact
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerWindowsBatchArtifact.Err
      (box
        (compiler_driver_core.compiler-driver-ty-node-pool-exhausted-diagnostic
          input-path)))
    (begin
      (compiler_driver_core.compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler_driver_core.compiler-driver-retire-frontend-arena!)
      (cfg
        compile-profile
        (compiler_driver_core.compiler-driver-profile-start-phase profile-state))
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view program)
        (owned_view.compiler-owned-shared-view spans)
        opt-level
        profile-state)
        [(compiler_optimize.CompilerOptimizedProgram.Program
            optimized
            optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler_driver_core.compiler-driver-profile-finish-phase
                profile-state
                "optimize"))
            (compiler_driver_core.compiler-driver-allocation-profile-snapshot!
              "optimize")
            (compiler_driver_core.compiler-driver-release-lowered-ir! opt-level)
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerWindowsBatchArtifact.Err
                (box
                  (compiler_driver_core.compiler-driver-ty-node-pool-exhausted-diagnostic
                    input-path)))
              (begin
                (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                  backend-state
                  (>= opt-level 2))
                (compiler-windows-batch-emit-optimized
                  backend-state
                  pools
                  input-path
                  optimized
                  optimized-spans
                  mode
                  force-assembly
                  emit-side-assembly
                  profile-state))))]))))

(define (compiler-windows-batch-emit-lowered-result
  [input-path : String]
  [lowered : compiler_driver_core.ResultCompilerDriverLowered]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [force-assembly : bool]
  [emit-side-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (match lowered
    [(compiler_driver_core.ResultCompilerDriverLowered.Ok
        program
        spans
        pools
        profile-state
        backend-state
        typecheck-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler_driver_core.compiler-driver-retirement-clone-shells?
            opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              (owned_view.compiler-owned-shared-view program))
            (owned_view.compiler-owned-shared-view program))]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler_driver_core.compiler-driver-retirement-clone-shells?
            opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerWindowsBatchArtifact
          (begin
            (compiler_ast_types.ast-node-pool-reader-use!
              (owned_view.compiler-owned-shared-view pools))
            (if (>= opt-level 1)
              (compiler_driver_core.compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-windows-batch-emit-lowered
              backend-state
              pools
              input-path
              emit-program
              emit-spans
              mode
              opt-level
              force-assembly
              emit-side-assembly
              profile-state
              typecheck-state))]
        (begin
          (if (= opt-level 0)
            (compiler_driver_core.compiler-driver-retire-lowered-source-arena!)
            unit)
          (compiler_ast_types.ast-node-pool-reader-clear!)
          (compiler_driver_core.compiler-driver-restore-frontend-return-arena!)
          out))]
    [(compiler_driver_core.ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler_driver_core.compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerWindowsBatchArtifact.Err diag))]))

(define (compiler-windows-batch-state-emit-file
  [state : compiler_driver_core.CompilerDriverState]
  [input-path : String]
  [stdlib-roots : windows_coff_svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [force-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (begin
    (cfg
      compile-profile
      (compiler_driver_core.compiler-driver-profile-start-total
        (compiler_driver_core.compiler-driver-state-profile state)))
    (let
      [target : compiler_backend.CompilerBackendTarget
        (compiler_backend.CompilerBackendTarget.Windows)]
      [lowered : compiler_driver_core.ResultCompilerDriverLowered
        (compiler_driver_core.compiler-driver-load-and-lower-escaping-with-state-and-retirement
          (owned_view.compiler-owned-shared-view state)
          (owned_view.compiler-owned-shared-view input-path)
          target
          stdlib-roots
          mode
          (compiler_driver_core.compiler-driver-state-target-cfgs
            (owned_view.compiler-owned-shared-view state)
            target
            cfgs)
          (>= opt-level 1))]
      ;; No builtin reinstall here; this state's parse-derived table is still
      ;; installed and id values are spelling-derived and state-independent.
      (compiler-windows-batch-emit-lowered-result
        input-path
        lowered
        mode
        opt-level
        force-assembly
        false))))