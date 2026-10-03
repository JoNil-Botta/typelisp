;; compiler_windows_coff_core.tl - Shared Windows COFF linkability and
;; one-optimization object-or-assembly emission.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(cfg test (import stdlib.io))
(import stdlib.text_buf)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as windows_coff_svec)
(import compiler_object as cobj)
(import compiler_object_asm)
(import compiler_profile_state as profile_state)
(import compiler_object_coff)
(import compiler_object_layout as layout)
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
  (Unavailable compiler_backend.CompilerDirectObjectFallbackReason))

(defenum CompilerWindowsBatchSideAssembly
  (None)
  (Some String))

(defenum ResultCompilerWindowsBatchArtifact
  (CoffObject
    String
    CompilerWindowsBatchSideAssembly
    compiler_diagnostic.CompilerAdvisoryList)
  (Assembly
    text_buf.TextBuf
    compiler_backend.CompilerDirectObjectFallbackReason
    compiler_diagnostic.CompilerAdvisoryList)
  (Err
    (Box compiler_diagnostic.CompilerDiagnostic)
    compiler_diagnostic.CompilerAdvisoryList))

(define (compiler-windows-coff-extern-linkable?
  [name : String]
  [kind : cobj.CompilerObjectSymbolKind]) : bool
  (and
    (cobj.compiler-object-symbol-kind-eq? kind (Function))
    (or
      (string.eq name "ExitProcess")
      (string.eq name "ConvertThreadToFiber")
      (string.eq name "CreateFiberEx")
      (string.eq name "GetCommandLineA")
      (string.eq name "GetStdHandle")
      (string.eq name "NtCreateFile")
      (string.eq name "SetThreadStackGuarantee")
      (string.eq name "SetUnhandledExceptionFilter")
      (string.eq name "SwitchToFiber")
      (string.eq name "WriteFile")
      (string.eq name "VirtualAlloc")
      (string.eq name "VirtualFree"))))

(define (compiler-windows-coff-relocation-target-linkable?
  [symbols : cobj.CompilerObjectSymbolList]
  [target : String]) : bool
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [ok : bool true]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (match (cobj.compiler-object-symbol-list-ref symbols index)
          [(Symbol name binding kind _)
            (if (string.eq name target)
              (begin
                (match binding
                  [(Extern)
                    (set! ok (compiler-windows-coff-extern-linkable? name kind))]
                  [_ (set! ok true)])
                (set! done true))
              (set! index (+ index 1)))]))
      ok)))

(define (compiler-windows-coff-relocations-linkable?
  [symbols : cobj.CompilerObjectSymbolList]
  [relocs : cobj.CompilerObjectRelocationList]) : bool
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-relocation-list-ref relocs index)
          [(Relocation _ _ _ target)
            (if (compiler-windows-coff-relocation-target-linkable?
              (owned_view.compiler-owned-shared-view symbols)
              target)
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-windows-coff-linkability [image : cobj.CompilerObjectImage]) : CompilerWindowsCoffLinkability
  (cond
    [(not (compiler_object_coff.compiler-object-coff-image-supported? image))
      (Unavailable UnsupportedCoffImage)]
    [(not
        (compiler-windows-coff-relocations-linkable?
          (owned_view.compiler-owned-shared-view image.symbols)
          (owned_view.compiler-owned-shared-view image.relocations)))
      (Unavailable ObjectRelocation)]
    [(not
        (cobj.compiler-object-symbol-list-contains?
          image.symbols
          "_tl_start"
          (Export)
          (Function)))
      (Unavailable MissingEntrySymbol)]
    [(<
        (layout.compiler-object-layout-section-label-offset
          image
          (Text)
          "tl_setup_argv")
        0)
      (Unavailable MissingRuntimeEntry)]
    [(<= (layout.compiler-object-layout-section-raw-size image (Text)) 0)
      (Unavailable EmptyTextSection)]
    [else (Linkable)]))

(define (compiler-windows-coff-linkable? [image : cobj.CompilerObjectImage]) : bool
  (match (compiler-windows-coff-linkability image)
    [(Linkable) true]
    [(Unavailable _) false]))

(cfg
  test
  (test
    compiler-windows-coff-typed-missing-entry
    (match (compiler-windows-coff-linkability
      (compiler_object_coff.compiler-object-coff-smoke-image))
      [(Unavailable (MissingEntrySymbol)) unit]
      [_ (io.panic "COFF missing-entry reason changed")])))

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
      (deref diag)
      input-path)))

(define (compiler-windows-batch-emit-assembly
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [mode : compiler_backend.CompilerBackendMode]
  [emit-entry : bool]
  [category : compiler_backend.CompilerDirectObjectFallbackReason]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerWindowsBatchArtifact
  (begin
    (cfg
      compile-profile
      (compiler_driver_core.compiler-driver-profile-start-phase profile-state))
    (match (compiler_backend.compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt-and-profile-state-backend-state
      backend-state
      pools
      program
      (Windows)
      mode
      spans
      emit-entry
      false
      profile-state)
      [(Ok asm)
        (begin
          (cfg
            compile-profile
            (compiler_driver_core.compiler-driver-profile-finish-phase
              profile-state
              "backend.assembly"))
          (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
            typecheck-state
            "backend.assembly")
          (Assembly
            asm
            category
            (compiler_driver_core.compiler-driver-advisories-for-job
              typecheck-state)))]
      [(Err diag)
        (begin
          (cfg
            compile-profile
            (compiler_driver_core.compiler-driver-profile-finish-phase
              profile-state
              "backend.assembly"))
          (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
            typecheck-state
            "backend.assembly-error")
          (Err
            (compiler-windows-batch-backend-diagnostic input-path diag)
            (compiler_driver_core.compiler-driver-advisories-for-job
              typecheck-state)))])))

(define (compiler-windows-coff-object-program-eligibility
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [profile-state : profile_state.CompilerProfileState]) : compiler_backend.CompilerBackendObjectEligibility
  (compiler_backend.compiler-backend-object-program-eligibility-with-pools-and-profile-state
    backend-state
    pools
    program
    (Windows)
    profile-state))

(define (compiler-windows-batch-emit-optimized
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [mode : compiler_backend.CompilerBackendMode]
  [emit-entry : bool]
  [force-assembly : bool]
  [emit-side-assembly : bool]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerWindowsBatchArtifact
  ;; A direct COFF object is linkable only through the freestanding runtime's
  ;; `_tl_start`, so a no-entry (library) image takes the assembly route.
  (if (or force-assembly (not emit-entry))
    (compiler-windows-batch-emit-assembly
      backend-state
      pools
      input-path
      program
      spans
      mode
      emit-entry
      (if force-assembly
        ForcedAssembly
        MissingEntrySymbol)
      profile-state
      typecheck-state)
    (match (compiler-windows-coff-object-program-eligibility
      backend-state
      pools
      (owned_view.compiler-owned-shared-view program)
      profile-state)
      [(Unsupported category)
        (compiler-windows-batch-emit-assembly
          backend-state
          pools
          input-path
          program
          spans
          mode
          emit-entry
          category
          profile-state
          typecheck-state)]
      [(Eligible)
        (begin
          (cfg
            compile-profile
            (compiler_driver_core.compiler-driver-profile-start-phase
              profile-state))
          (match (compiler_backend.compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
            backend-state
            pools
            (owned_view.compiler-owned-shared-view program)
            (Windows)
            mode
            (owned_view.compiler-owned-shared-view spans)
            emit-entry
            false
            profile-state)
            [(Ok image)
              (begin
                (cfg
                  compile-profile
                  (compiler_driver_core.compiler-driver-profile-finish-phase
                    profile-state
                    "backend.object-image"))
                (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
                  typecheck-state
                  "backend.object-image")
                (match (compiler-windows-coff-linkability
                  (owned_view.compiler-owned-shared-view image))
                  [(Linkable)
                    (begin
                      (cfg
                        compile-profile
                        (compiler_driver_core.compiler-driver-profile-start-phase
                          profile-state))
                      (match (compiler_object_coff.compiler-object-coff-render
                        image)
                        [(Ok object)
                          (begin
                            (cfg
                              compile-profile
                              (compiler_driver_core.compiler-driver-profile-finish-phase
                                profile-state
                                "render.coff-object"))
                            (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
                              typecheck-state
                              "render.coff-object")
                            (if emit-side-assembly
                              (match (compiler_object_asm.compiler-object-asm-render
                                image)
                                [(Ok asm)
                                  (CoffObject
                                    object
                                    (Some asm)
                                    (compiler_driver_core.compiler-driver-advisories-for-job
                                      typecheck-state))]
                                [(Err message)
                                  (Err
                                    (compiler-windows-batch-diagnostic
                                      input-path
                                      (str_cat.str-cat
                                        "assembly side artifact rendering failed: "
                                        message))
                                    (compiler_driver_core.compiler-driver-advisories-for-job
                                      typecheck-state))])
                              (CoffObject
                                object
                                None
                                (compiler_driver_core.compiler-driver-advisories-for-job
                                  typecheck-state))))]
                        [(Err message)
                          (begin
                            (cfg
                              compile-profile
                              (compiler_driver_core.compiler-driver-profile-finish-phase
                                profile-state
                                "render.coff-object"))
                            (Err
                              (compiler-windows-batch-diagnostic
                                input-path
                                (str_cat.str-cat
                                  "COFF serialization failed: "
                                  message))
                              (compiler_driver_core.compiler-driver-advisories-for-job
                                typecheck-state)))]))]
                  [(Unavailable category)
                    (compiler-windows-batch-emit-assembly
                      backend-state
                      pools
                      input-path
                      program
                      spans
                      mode
                      emit-entry
                      category
                      profile-state
                      typecheck-state)]))]
            [(Err diag)
              (begin
                (cfg
                  compile-profile
                  (compiler_driver_core.compiler-driver-profile-finish-phase
                    profile-state
                    "backend.object-image"))
                (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
                  typecheck-state
                  "backend.object-image-error")
                (Err
                  (compiler-windows-batch-backend-diagnostic input-path diag)
                  (compiler_driver_core.compiler-driver-advisories-for-job
                    typecheck-state)))]))])))

(define (compiler-windows-batch-emit-lowered
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [force-assembly : bool]
  [emit-side-assembly : bool]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerWindowsBatchArtifact
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (Err
      (box
        (compiler_driver_core.compiler-driver-ty-node-pool-exhausted-diagnostic
          input-path))
      (compiler_driver_core.compiler-driver-advisories-for-job typecheck-state))
    (begin
      (compiler_driver_core.compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler_driver_core.compiler-driver-retire-frontend-arena!)
      (cfg
        compile-profile
        (compiler_driver_core.compiler-driver-profile-start-phase profile-state))
      (match (compiler_optimize.optimize-program
        program
        spans
        (compiler_optimize.OptimizeRequest
          pools
          opt-level
          profile-state
          false
          (compiler_ir_types.compiler-ir-representation-index-empty)))
        [(Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler_driver_core.compiler-driver-profile-finish-phase
                profile-state
                "optimize"))
            (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
              typecheck-state
              "optimize")
            (compiler_driver_core.compiler-driver-release-lowered-ir! opt-level)
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (Err
                (box
                  (compiler_driver_core.compiler-driver-ty-node-pool-exhausted-diagnostic
                    input-path))
                (compiler_driver_core.compiler-driver-advisories-for-job
                  typecheck-state))
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
                  emit-entry
                  force-assembly
                  emit-side-assembly
                  profile-state
                  typecheck-state))))]))))

(define (compiler-windows-batch-emit-lowered-result
  [input-path : String]
  [lowered : compiler_driver_core.ResultCompilerDriverLowered]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [force-assembly : bool]
  [emit-side-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (match lowered
    [(Ok program spans pools profile-state backend-state typecheck-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler_driver_core.compiler-driver-retirement-clone-shells?
            opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              program)
            program)]
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
              emit-entry
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
    [(Err diag advisories)
      (begin
        (compiler_driver_core.compiler-driver-restore-frontend-return-arena!)
        (Err diag advisories))]))

(define (compiler-windows-batch-state-emit-file
  [state : compiler_driver_core.CompilerDriverState]
  [input-path : String]
  [stdlib-roots : windows_coff_svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [emit-entry : bool]
  [force-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (begin
    (cfg
      compile-profile
      (compiler_driver_core.compiler-driver-profile-start-total
        (compiler_driver_core.compiler-driver-state-profile state)))
    (let
      [target : compiler_backend.CompilerBackendTarget (Windows)]
      [lowered : compiler_driver_core.ResultCompilerDriverLowered
        (compiler_driver_core.compiler-driver-load-and-lower-escaping-with-state-and-retirement
          (owned_view.compiler-owned-shared-view state)
          (owned_view.compiler-owned-shared-view input-path)
          target
          stdlib-roots
          mode
          (compiler_driver_core.compiler-driver-state-target-cfgs
            state
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
        emit-entry
        force-assembly
        false))))