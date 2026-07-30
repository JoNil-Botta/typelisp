;; compiler_windows_coff_core.tl - Shared Windows COFF eligibility and
;; one-optimization object-or-assembly emission.
(import stdlib.text_buf)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as windows_coff_svec)
(import compiler_object as cobj)
(import compiler_profile_state as profile_state)
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
  [category : String]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerWindowsBatchArtifact
  (begin
    (cfg compile-profile (compiler-driver-profile-start-phase profile-state))
    (match (compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt-and-profile-state
      pools
      program
      (CompilerBackendTarget.Windows)
      mode
      spans
      true
      false
      profile-state)
      [(ResultCompilerBackendBuffer.Ok asm)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              profile-state
              "backend.assembly"))
          (compiler-driver-allocation-profile-snapshot! "backend.assembly")
          (ResultCompilerWindowsBatchArtifact.Assembly asm category))]
      [(ResultCompilerBackendBuffer.Err diag)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              profile-state
              "backend.assembly"))
          (compiler-driver-allocation-profile-snapshot!
            "backend.assembly-error")
          (ResultCompilerWindowsBatchArtifact.Err
            (compiler-windows-batch-backend-diagnostic input-path diag)))])))

(define (compiler-windows-coff-object-binop-supported?
  [op : CompilerIrBinOp]
  [ty : AstType]) : bool
  (and
    (not (compiler-backend-float-type? ty))
    (match op
      [(CompilerIrBinOp.Add) true]
      [(CompilerIrBinOp.Sub) true]
      [(CompilerIrBinOp.Mul) true]
      [(CompilerIrBinOp.Eq) true]
      [(CompilerIrBinOp.Ne) true]
      [(CompilerIrBinOp.Lt) true]
      [(CompilerIrBinOp.Le) true]
      [(CompilerIrBinOp.Gt) true]
      [(CompilerIrBinOp.Ge) true]
      [(CompilerIrBinOp.BitTestEq) true]
      [(CompilerIrBinOp.BitTestNe) true]
      [(CompilerIrBinOp.And) true]
      [(CompilerIrBinOp.Or) true]
      [(CompilerIrBinOp.BitAnd) true]
      [(CompilerIrBinOp.BitOr) true]
      [(CompilerIrBinOp.BitXor) true]
      [_ false])))

(define (compiler-windows-coff-object-value-supported?
  [value : CompilerIrValue]) : bool
  (match value
    ;; The object emitter currently uses `REX.W C7 /0`, whose imm32 operand is
    ;; sign-extended. Keep wider constants on the assembly path until movabs
    ;; lowering is shared with the object backend.
    [(CompilerIrValue.I64 value)
      (and (>= value -2147483648) (<= value 2147483647))]
    ;; This placeholder only records the initializer reference today.
    [(CompilerIrValue.RuntimeGlobal _) false]
    [_ true]))

(define (compiler-windows-coff-object-call-args-supported?
  [args : CompilerIrCallArgs]) : bool
  (match args
    [(CompilerIrCallArgs.Nil) true]
    [(CompilerIrCallArgs.One value)
      (compiler-windows-coff-object-value-supported? value)]
    [(CompilerIrCallArgs.Two lhs rhs)
      (and
        (compiler-windows-coff-object-value-supported? lhs)
        (compiler-windows-coff-object-value-supported? rhs))]
    [(CompilerIrCallArgs.Array values)
      (let
        [index : i64 0]
        [count : i64 (array-length values)]
        [supported : bool true]
        (begin
          (while (and supported (< index count))
            (begin
              (set!
                supported
                (compiler-windows-coff-object-value-supported?
                  (array-ref values index)))
              (set! index (+ index 1))))
          supported))]))

(define (compiler-windows-coff-object-call-supported? [name : i64]) : bool
  (let
    [text : String (compiler-ir-symbol-text name)]
    (and
      (not (compiler-backend-stdlib-runtime-function-name? text))
      (not (compiler-backend-string-prefix-at? text "tl_" 0))
      (not (compiler-backend-fixed-fault-symbol-id? name)))))

;; Object-image lowering is deliberately incremental. The COFF encoder can
;; serialize every byte record produced by the cases below, but several IR
;; instructions still have reference-discovery-only placeholders in the object
;; emitter. Do not mistake an encodable image for a semantically complete one:
;; keep those programs on the assembly path until their object lowering lands.
(define (compiler-windows-coff-object-instr-supported?
  [instr : CompilerIrInstr]) : bool
  (match instr
    [(CompilerIrInstr.Mov _ src _)
      (compiler-windows-coff-object-value-supported? src)]
    [(CompilerIrInstr.BinOp _ op lhs rhs ty)
      (and
        (compiler-windows-coff-object-binop-supported? op ty)
        (compiler-windows-coff-object-value-supported? lhs)
        (compiler-windows-coff-object-value-supported? rhs))]
    [(CompilerIrInstr.UnOp _ op src _)
      (and
        (compiler-windows-coff-object-value-supported? src)
        (match op
          [(CompilerIrUnOp.Sqrt) false]
          [_ true]))]
    [(CompilerIrInstr.Call _ name args _)
      (and
        (compiler-windows-coff-object-call-supported? name)
        (compiler-windows-coff-object-call-args-supported? args))]
    [(CompilerIrInstr.CallIndirect _ _ _ _) false]
    [(CompilerIrInstr.CallIndirectC _ callee args _)
      (and
        (compiler-windows-coff-object-value-supported? callee)
        (compiler-windows-coff-object-call-args-supported? args))]
    [(CompilerIrInstr.CallCAbiStoreResult _) false]
    [(CompilerIrInstr.CallIndirectCAbiStoreResult _) false]
    [(CompilerIrInstr.TailCall _ _ _) false]
    [(CompilerIrInstr.Store _ value _)
      (compiler-windows-coff-object-value-supported? value)]
    [(CompilerIrInstr.Jump _) true]
    ;; The object-only control-flow implementation still has differential
    ;; mismatches for conditions, early returns, and enum matches.
    [(CompilerIrInstr.Branch _ _ _) false]
    [(CompilerIrInstr.Return maybe)
      (match maybe
        [(CompilerIrMaybeValue.No) true]
        [(CompilerIrMaybeValue.Some value)
          (compiler-windows-coff-object-value-supported? value)])]
    [(CompilerIrInstr.Phi _ _ _) false]
    [(CompilerIrInstr.Gep _ base offset _)
      (and
        (compiler-windows-coff-object-value-supported? base)
        (compiler-windows-coff-object-value-supported? offset))]
    [(CompilerIrInstr.Load _ src _)
      (compiler-windows-coff-object-value-supported? src)]
    [(CompilerIrInstr.StorePtr _ _ _) false]
    [(CompilerIrInstr.CopyBytes _ _ _) false]
    [(CompilerIrInstr.BoundsCheck _ _ _) false]
    [(CompilerIrInstr.Cast _ _ _ _) false]
    [(CompilerIrInstr.Bitcast _ _ _ _) false]
    [(CompilerIrInstr.Splat _ _ _ _) false]
    [(CompilerIrInstr.VectorBinOp _) false]
    [(CompilerIrInstr.VectorPrefix _) false]
    [(CompilerIrInstr.VectorReduce _ _ _ _ _) false]
    [(CompilerIrInstr.VectorCompare _) false]
    [(CompilerIrInstr.MaskBinOp _ _ _ _ _) false]
    [(CompilerIrInstr.MaskNot _ _ _) false]
    [(CompilerIrInstr.MaskReduce _ _ _ _) false]
    [(CompilerIrInstr.Select _) false]
    [(CompilerIrInstr.VectorLoad _ _ _ _ _) false]
    [(CompilerIrInstr.VectorStore _) false]
    [(CompilerIrInstr.PredicatedStore _) false]
    [(CompilerIrInstr.PredicatedLoad _) false]
    [(CompilerIrInstr.GatherLoad _) false]
    [(CompilerIrInstr.VectorShuffle _) false]
    [(CompilerIrInstr.TailMask _ _ _ _) false]
    [(CompilerIrInstr.CpuId _ _ _ _) false]
    [(CompilerIrInstr.Xgetbv _ _) false]
    [(CompilerIrInstr.Syscall _ _) false]
    [(CompilerIrInstr.SpmdCall _) false]
    [(CompilerIrInstr.Pack _ _ _) false]
    [(CompilerIrInstr.Word _ _ _ _) false]
    [(CompilerIrInstr.TailCallIndirect _ _ _) false]
    [(CompilerIrInstr.Alloc _ _) false]
    [(CompilerIrInstr.AddrOf _ _) false]
    [(CompilerIrInstr.LaneId _ _ _) false]
    [(CompilerIrInstr.EntryArgc _) false]
    [(CompilerIrInstr.EntryArgv _) false]
    [(CompilerIrInstr.EntryEnvp _) false]
    [(CompilerIrInstr.Switch _ _ _ _) false]))

(define (compiler-windows-coff-object-instrs-supported?
  [instrs : CompilerIrInstrSeq]) : bool
  (let
    [index : i64 0]
    [count : i64 (compiler-ir-instr-seq-count instrs)]
    [supported : bool true]
    (begin
      (while (and supported (< index count))
        (begin
          (set!
            supported
            (compiler-windows-coff-object-instr-supported?
              (compiler-ir-instr-seq-ref instrs index)))
          (set! index (+ index 1))))
      supported)))

(define (compiler-windows-coff-object-blocks-supported?
  [blocks : CompilerIrBlockList]) : bool
  (match blocks
    [(CompilerIrBlockList.Nil) true]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (and
            (compiler-windows-coff-object-instrs-supported? instrs)
            (compiler-windows-coff-object-blocks-supported? (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (let
        [index : i64 0]
        [count : i64 (compiler-ir-block-seq-count seq)]
        [supported : bool true]
        (begin
          (while (and supported (< index count))
            (begin
              (match (compiler-ir-block-seq-ref seq index)
                [(CompilerIrBlock.Block _ instrs)
                  (set!
                    supported
                    (compiler-windows-coff-object-instrs-supported? instrs))])
              (set! index (+ index 1))))
          supported))]))

(define (compiler-windows-coff-object-functions-supported?
  [functions : CompilerIrFunctionList]) : bool
  (match functions
    [(CompilerIrFunctionList.Nil) true]
    [(CompilerIrFunctionList.Cons function rest)
      (match function
        [(CompilerIrFunction.Function name _ _ _ blocks)
          (and
            (or
              (compiler-backend-stdlib-runtime-function-name?
                (compiler-ir-symbol-text name))
              (compiler-windows-coff-object-blocks-supported? blocks))
            (compiler-windows-coff-object-functions-supported? (box-get rest)))])]
    [(CompilerIrFunctionList.Array seq)
      (let
        [index : i64 0]
        [count : i64 (compiler-ir-function-seq-count seq)]
        [supported : bool true]
        (begin
          (while (and supported (< index count))
            (begin
              (match (compiler-ir-function-seq-ref seq index)
                [(CompilerIrFunction.Function name _ _ _ blocks)
                  (set!
                    supported
                    (or
                      (compiler-backend-stdlib-runtime-function-name?
                        (compiler-ir-symbol-text name))
                      (compiler-windows-coff-object-blocks-supported? blocks)))])
              (set! index (+ index 1))))
          supported))]))

(define (compiler-windows-coff-object-program-supported?
  [program : CompilerIrProgram]) : bool
  (match program
    [(CompilerIrProgram.Program _ functions _)
      (compiler-windows-coff-object-functions-supported? functions)]))

(define (compiler-windows-batch-emit-optimized
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [mode : CompilerBackendMode]
  [force-assembly : bool]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerWindowsBatchArtifact
  (if force-assembly
    (compiler-windows-batch-emit-assembly
      pools
      input-path
      program
      spans
      mode
      "forced-assembly"
      profile-state)
    (if (not (compiler-windows-coff-object-program-supported? program))
      (compiler-windows-batch-emit-assembly
        pools
        input-path
        program
        spans
        mode
        "unsupported-object-semantics"
        profile-state)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase profile-state))
        (match (compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state
          pools
          program
          (CompilerBackendTarget.Windows)
          mode
          spans
          true
          false
          profile-state)
          [(ResultCompilerBackendObject.Ok image)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  profile-state
                  "backend.object-image"))
              (compiler-driver-allocation-profile-snapshot!
                "backend.object-image")
              (match (compiler-windows-coff-linkability image)
                [(CompilerWindowsCoffLinkability.Linkable)
                  (begin
                    (cfg
                      compile-profile
                      (compiler-driver-profile-start-phase profile-state))
                    (match (compiler-object-coff-render image)
                      [(ResultCompilerObjectCoff.Ok object)
                        (begin
                          (cfg
                            compile-profile
                            (compiler-driver-profile-finish-phase
                              profile-state
                              "render.coff-object"))
                          (compiler-driver-allocation-profile-snapshot!
                            "render.coff-object")
                          (ResultCompilerWindowsBatchArtifact.CoffObject object))]
                      [(ResultCompilerObjectCoff.Err message)
                        (begin
                          (cfg
                            compile-profile
                            (compiler-driver-profile-finish-phase
                              profile-state
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
                    category
                    profile-state)]))]
          [(ResultCompilerBackendObject.Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  profile-state
                  "backend.object-image"))
              (compiler-driver-allocation-profile-snapshot!
                "backend.object-image-error")
              (ResultCompilerWindowsBatchArtifact.Err
                (compiler-windows-batch-backend-diagnostic input-path diag)))])))))

(define (compiler-windows-batch-emit-lowered
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [force-assembly : bool]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerWindowsBatchArtifact
  (if (ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerWindowsBatchArtifact.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (compiler-driver-retire-frontend-arena!)
      (cfg compile-profile (compiler-driver-profile-start-phase profile-state))
      (match (optimize-program-with-spans-and-pools-and-level-and-profile-state
        pools
        program
        spans
        opt-level
        profile-state)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase profile-state "optimize"))
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
                  force-assembly
                  profile-state))))]))))

(define (compiler-windows-batch-emit-lowered-result
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [force-assembly : bool]) : ResultCompilerWindowsBatchArtifact
  (match lowered
    [(ResultCompilerDriverLowered.Ok program spans pools profile-state)
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
              force-assembly
              profile-state))]
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
    (cfg
      compile-profile
      (compiler-driver-profile-start-total
        (compiler-driver-state-profile state)))
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