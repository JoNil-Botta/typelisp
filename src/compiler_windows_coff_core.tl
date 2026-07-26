;; compiler_windows_coff_core.tl - Shared Windows COFF eligibility and
;; one-optimization object-or-assembly emission.
(import stdlib.text_buf)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as windows_coff_svec)
(import compiler_object as cobj)
(import "compiler_object_coff.tl")
(import "compiler_driver_core.tl")
(import sym_i64_env)

(defenum CompilerWindowsCoffLinkability
  (Linkable)
  (Unavailable String))

(defenum ResultCompilerWindowsBatchArtifact
  (CoffObject String)
  (Assembly text_buf.TextBuf String)
  (Err (Box CompilerDiagnostic)))

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
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [ok : bool true]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (match (cobj.compiler-object-symbol-list-ref symbols index)
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
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-relocation-list-ref relocs index)
          [(cobj.CompilerObjectRelocation.Relocation _ _ _ target)
            (if (compiler-windows-coff-relocation-target-linkable?
              symbols
              target)
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-windows-coff-linkability [image : cobj.CompilerObjectImage]) : CompilerWindowsCoffLinkability
  (cond
    [(not (compiler-object-coff-image-supported? image))
      (CompilerWindowsCoffLinkability.Unavailable "unsupported-coff-image")]
    [(not
        (compiler-windows-coff-relocations-linkable?
          (struct-get image symbols)
          (struct-get image relocations)))
      (CompilerWindowsCoffLinkability.Unavailable
        "unsupported-external-relocation")]
    [(not
        (cobj.compiler-object-symbol-list-contains?
          (struct-get image symbols)
          "_tl_start"
          (cobj.CompilerObjectSymbolBinding.Export)
          (cobj.CompilerObjectSymbolKind.Function)))
      (CompilerWindowsCoffLinkability.Unavailable "missing-entry-symbol")]
    [(<
        (compiler-object-coff-section-label-offset
          image
          (cobj.CompilerObjectSectionKind.Text)
          "tl_setup_argv")
        0)
      (CompilerWindowsCoffLinkability.Unavailable "missing-runtime-entry")]
    [(<=
        (compiler-object-coff-section-raw-size
          image
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
  [message : String]) : (Box CompilerDiagnostic)
  (box (compiler-diagnostic-at-start input-path message)))

(define (compiler-windows-batch-backend-diagnostic
  [input-path : String]
  [diag : (Box CompilerDiagnostic)]) : (Box CompilerDiagnostic)
  (box (compiler-diagnostic-with-path (box-get diag) input-path)))

(define (compiler-windows-batch-emit-assembly
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [mode : CompilerBackendMode]
  [category : String]) : ResultCompilerWindowsBatchArtifact
  (begin
    (cfg compile-profile (compiler-driver-profile-start-phase))
    (match (compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt
      pools
      program
      (CompilerBackendTarget.Windows)
      mode
      spans
      true
      false)
      [(ResultCompilerBackendBuffer.Ok asm)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase "backend.assembly"))
          (compiler-driver-allocation-profile-snapshot! "backend.assembly")
          (ResultCompilerWindowsBatchArtifact.Assembly asm category))]
      [(ResultCompilerBackendBuffer.Err diag)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase "backend.assembly"))
          (compiler-driver-allocation-profile-snapshot!
            "backend.assembly-error")
          (ResultCompilerWindowsBatchArtifact.Err
            (compiler-windows-batch-backend-diagnostic input-path diag)))])))

(define (compiler-windows-batch-emit-optimized
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [mode : CompilerBackendMode]
  [force-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (if force-assembly
    (compiler-windows-batch-emit-assembly
      pools
      input-path
      program
      spans
      mode
      "forced-assembly")
    (begin
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt
        pools
        program
        (CompilerBackendTarget.Windows)
        mode
        spans
        true
        false)
        [(ResultCompilerBackendObject.Ok image)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "backend.object-image"))
            (compiler-driver-allocation-profile-snapshot!
              "backend.object-image")
            (match (compiler-windows-coff-linkability image)
              [(CompilerWindowsCoffLinkability.Linkable)
                (begin
                  (cfg compile-profile (compiler-driver-profile-start-phase))
                  (match (compiler-object-coff-render image)
                    [(ResultCompilerObjectCoff.Ok object)
                      (begin
                        (cfg
                          compile-profile
                          (compiler-driver-profile-finish-phase
                            "render.coff-object"))
                        (compiler-driver-allocation-profile-snapshot!
                          "render.coff-object")
                        (ResultCompilerWindowsBatchArtifact.CoffObject object))]
                    [(ResultCompilerObjectCoff.Err message)
                      (begin
                        (cfg
                          compile-profile
                          (compiler-driver-profile-finish-phase
                            "render.coff-object"))
                        (ResultCompilerWindowsBatchArtifact.Err
                          (compiler-windows-batch-diagnostic
                            input-path
                            (string.append
                              "COFF serialization failed: "
                              message))))]))]
              [(CompilerWindowsCoffLinkability.Unavailable category)
                (compiler-windows-batch-emit-assembly
                  pools
                  input-path
                  program
                  spans
                  mode
                  category)]))]
        [(ResultCompilerBackendObject.Err diag)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "backend.object-image"))
            (compiler-driver-allocation-profile-snapshot!
              "backend.object-image-error")
            (ResultCompilerWindowsBatchArtifact.Err
              (compiler-windows-batch-backend-diagnostic input-path diag)))]))))

(define (compiler-windows-batch-emit-lowered
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [force-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (if (ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerWindowsBatchArtifact.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (compiler-driver-retire-frontend-arena!)
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-pools-and-level
        pools
        program
        spans
        opt-level)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-allocation-profile-snapshot! "optimize")
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerWindowsBatchArtifact.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (compiler-windows-batch-emit-optimized
                  pools
                  input-path
                  optimized
                  optimized-spans
                  mode
                  force-assembly))))]))))

(define (compiler-windows-batch-emit-lowered-result
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [force-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (match lowered
    [(ResultCompilerDriverLowered.Ok program spans pools)
      (let
        [emit-program : CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler-ir-clone-program-shell pools program)
            program)]
        [emit-spans : CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerWindowsBatchArtifact
          (begin
            (ast-node-pool-reader-use! pools)
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-windows-batch-emit-lowered
              pools
              input-path
              emit-program
              emit-spans
              mode
              opt-level
              force-assembly))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerWindowsBatchArtifact.Err diag))]))

(define (compiler-windows-batch-state-emit-file
  [state : CompilerDriverState]
  [input-path : String]
  [stdlib-roots : windows_coff_svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [force-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    (let
      [target : CompilerBackendTarget (CompilerBackendTarget.Windows)]
      [lowered : ResultCompilerDriverLowered
        (compiler-driver-load-and-lower-escaping-with-state-and-retirement
          state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-state-target-cfgs state target cfgs)
          (>= opt-level 1))]
      (begin
        (compiler-driver-state-install-builtins! state)
        (compiler-windows-batch-emit-lowered-result
          input-path
          lowered
          mode
          opt-level
          force-assembly)))))