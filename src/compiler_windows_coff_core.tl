;; compiler_windows_coff_core.tl - Shared Windows COFF eligibility and
;; one-optimization object-or-assembly emission.
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
(import compiler_ast_types)
(import compiler_backend)
(import compiler_ir_types)
(import compiler_diagnostic)
(import compiler_optimize)
(import sym_i64_env)
(cfg test (import stdlib.test))
(cfg test (import compiler_intern as ci))

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
    [(not (compiler_object_coff.compiler-object-coff-image-supported? image))
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
        (compiler_object_coff.compiler-object-coff-section-label-offset
          image
          (cobj.CompilerObjectSectionKind.Text)
          "tl_setup_argv")
        0)
      (CompilerWindowsCoffLinkability.Unavailable "missing-runtime-entry")]
    [(<=
        (compiler_object_coff.compiler-object-coff-section-raw-size
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
  [message : String]) : (Box compiler_diagnostic.CompilerDiagnostic)
  (box (compiler_diagnostic.compiler-diagnostic-at-start input-path message)))

(define (compiler-windows-batch-backend-diagnostic
  [input-path : String]
  [diag : (Box compiler_diagnostic.CompilerDiagnostic)]) : (Box
    compiler_diagnostic.CompilerDiagnostic)
  (box
    (compiler_diagnostic.compiler-diagnostic-with-path
      (box-get diag)
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

(define (compiler-windows-coff-object-binop-supported?
  [op : compiler_ir_types.CompilerIrBinOp]
  [ty : compiler_ast_types.AstType]) : bool
  (and
    (not (compiler_backend.compiler-backend-float-type? ty))
    (match op
      [(compiler_ir_types.CompilerIrBinOp.Add) true]
      [(compiler_ir_types.CompilerIrBinOp.Sub) true]
      [(compiler_ir_types.CompilerIrBinOp.Mul) true]
      [(compiler_ir_types.CompilerIrBinOp.Eq) true]
      [(compiler_ir_types.CompilerIrBinOp.Ne) true]
      [(compiler_ir_types.CompilerIrBinOp.Lt) true]
      [(compiler_ir_types.CompilerIrBinOp.Le) true]
      [(compiler_ir_types.CompilerIrBinOp.Gt) true]
      [(compiler_ir_types.CompilerIrBinOp.Ge) true]
      [(compiler_ir_types.CompilerIrBinOp.BitTestEq) true]
      [(compiler_ir_types.CompilerIrBinOp.BitTestNe) true]
      [(compiler_ir_types.CompilerIrBinOp.And) true]
      [(compiler_ir_types.CompilerIrBinOp.Or) true]
      [(compiler_ir_types.CompilerIrBinOp.BitAnd) true]
      [(compiler_ir_types.CompilerIrBinOp.BitOr) true]
      [(compiler_ir_types.CompilerIrBinOp.BitXor) true]
      [_ false])))

(define (compiler-windows-coff-object-value-supported?
  [value : compiler_ir_types.CompilerIrValue]) : bool
  (match value
    ;; The object emitter currently uses `REX.W C7 /0`, whose imm32 operand is
    ;; sign-extended. Keep wider constants on the assembly path until movabs
    ;; lowering is shared with the object backend.
    [(compiler_ir_types.CompilerIrValue.I64 value)
      (and (>= value -2147483648) (<= value 2147483647))]
    ;; This placeholder only records the initializer reference today.
    [(compiler_ir_types.CompilerIrValue.RuntimeGlobal _) false]
    [_ true]))

(define (compiler-windows-coff-object-call-args-supported?
  [args : compiler_ir_types.CompilerIrCallArgs]) : bool
  (match args
    [(compiler_ir_types.CompilerIrCallArgs.Nil) true]
    [(compiler_ir_types.CompilerIrCallArgs.One value)
      (compiler-windows-coff-object-value-supported? value)]
    [(compiler_ir_types.CompilerIrCallArgs.Two lhs rhs)
      (and
        (compiler-windows-coff-object-value-supported? lhs)
        (compiler-windows-coff-object-value-supported? rhs))]
    [(compiler_ir_types.CompilerIrCallArgs.Array values)
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

(define (compiler-windows-coff-object-call-supported?
  [backend-state : compiler_backend.CompilerBackendState]
  [name : i64]) : bool
  (let
    [text : String
      (compiler_backend.compiler-backend-symbol-text-state backend-state name)]
    (and
      (not
        (compiler_backend.compiler-backend-stdlib-runtime-function-name? text))
      (not (compiler_backend.compiler-backend-string-prefix-at? text "tl_" 0))
      (not
        (compiler_backend.compiler-backend-fixed-fault-symbol-id?
          backend-state
          name)))))

;; Object-image lowering is deliberately incremental. The COFF encoder can
;; serialize every byte record produced by the cases below, but several IR
;; instructions still have reference-discovery-only placeholders in the object
;; emitter. Do not mistake an encodable image for a semantically complete one:
;; keep those programs on the assembly path until their object lowering lands.
(define (compiler-windows-coff-object-instr-supported?
  [backend-state : compiler_backend.CompilerBackendState]
  [instr : compiler_ir_types.CompilerIrInstr]) : bool
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Mov _ src _)
      (compiler-windows-coff-object-value-supported? src)]
    [(compiler_ir_types.CompilerIrInstr.BinOp _ op lhs rhs ty)
      (and
        (compiler-windows-coff-object-binop-supported? op ty)
        (compiler-windows-coff-object-value-supported? lhs)
        (compiler-windows-coff-object-value-supported? rhs))]
    [(compiler_ir_types.CompilerIrInstr.UnOp _ op src _)
      (and
        (compiler-windows-coff-object-value-supported? src)
        (match op
          [(compiler_ir_types.CompilerIrUnOp.Sqrt) false]
          [_ true]))]
    [(compiler_ir_types.CompilerIrInstr.Call _ name args _)
      (and
        (compiler-windows-coff-object-call-supported? backend-state name)
        (compiler-windows-coff-object-call-args-supported? args))]
    [(compiler_ir_types.CompilerIrInstr.CallIndirect _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.CallIndirectC _ callee args _)
      (and
        (compiler-windows-coff-object-value-supported? callee)
        (compiler-windows-coff-object-call-args-supported? args))]
    [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult _) false]
    [(compiler_ir_types.CompilerIrInstr.CallIndirectCAbiStoreResult _) false]
    [(compiler_ir_types.CompilerIrInstr.TailCall _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Store _ value _)
      (compiler-windows-coff-object-value-supported? value)]
    [(compiler_ir_types.CompilerIrInstr.Jump _) true]
    ;; The object-only control-flow implementation still has differential
    ;; mismatches for conditions, early returns, and enum matches.
    [(compiler_ir_types.CompilerIrInstr.Branch _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Return maybe)
      (match maybe
        [(compiler_ir_types.CompilerIrMaybeValue.No) true]
        [(compiler_ir_types.CompilerIrMaybeValue.Some value)
          (compiler-windows-coff-object-value-supported? value)])]
    [(compiler_ir_types.CompilerIrInstr.Phi _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Gep _ base offset _)
      (and
        (compiler-windows-coff-object-value-supported? base)
        (compiler-windows-coff-object-value-supported? offset))]
    [(compiler_ir_types.CompilerIrInstr.Load _ src _)
      (compiler-windows-coff-object-value-supported? src)]
    [(compiler_ir_types.CompilerIrInstr.StorePtr _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.CopyBytes _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.BoundsCheck _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Cast _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Bitcast _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Splat _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.VectorBinOp _) false]
    [(compiler_ir_types.CompilerIrInstr.VectorPrefix _) false]
    [(compiler_ir_types.CompilerIrInstr.VectorReduce _ _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.VectorCompare _) false]
    [(compiler_ir_types.CompilerIrInstr.MaskBinOp _ _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.MaskNot _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.MaskReduce _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Select _) false]
    [(compiler_ir_types.CompilerIrInstr.VectorLoad _ _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.VectorStore _) false]
    [(compiler_ir_types.CompilerIrInstr.PredicatedStore _) false]
    [(compiler_ir_types.CompilerIrInstr.PredicatedLoad _) false]
    [(compiler_ir_types.CompilerIrInstr.GatherLoad _) false]
    [(compiler_ir_types.CompilerIrInstr.VectorShuffle _) false]
    [(compiler_ir_types.CompilerIrInstr.TailMask _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.CpuId _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Xgetbv _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Syscall _ _) false]
    [(compiler_ir_types.CompilerIrInstr.SpmdCall _) false]
    [(compiler_ir_types.CompilerIrInstr.Pack _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Word _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.TailCallIndirect _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.Alloc _ _) false]
    [(compiler_ir_types.CompilerIrInstr.AddrOf _ _) false]
    [(compiler_ir_types.CompilerIrInstr.LaneId _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.EntryArgc _) false]
    [(compiler_ir_types.CompilerIrInstr.EntryArgv _) false]
    [(compiler_ir_types.CompilerIrInstr.EntryEnvp _) false]
    [(compiler_ir_types.CompilerIrInstr.Switch _ _ _ _) false]
    [(compiler_ir_types.CompilerIrInstr.TotalEnumSwitch _ _ _ _ _) false]))

(test
  compiler-windows-coff-total-enum-control-flow-falls-back
  (let
    [backend-state : compiler_backend.CompilerBackendState
      (compiler_backend.compiler-backend-state-new
        (ci.intern-compat-state-capture-active))]
    (begin
      (test.assert-false
        (compiler-windows-coff-object-instr-supported?
          backend-state
          (compiler_ir_types.CompilerIrInstr.TotalEnumBranch
            (compiler_ir_types.CompilerIrValue.I64 0)
            1
            2))
        "total enum branches stay on the assembly path")
      (test.assert-false
        (compiler-windows-coff-object-instr-supported?
          backend-state
          (compiler_ir_types.CompilerIrInstr.TotalEnumSwitch
            (compiler_ir_types.CompilerIrValue.I64 0)
            0
            compiler_ir_types.CompilerIrSwitchCaseList.Nil
            1
            2))
        "total enum switches stay on the assembly path"))))

(define (compiler-windows-coff-object-instrs-supported?
  [backend-state : compiler_backend.CompilerBackendState]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : bool
  (let
    [index : i64 0]
    [count : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
    [supported : bool true]
    (begin
      (while (and supported (< index count))
        (begin
          (set!
            supported
            (compiler-windows-coff-object-instr-supported?
              backend-state
              (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)))
          (set! index (+ index 1))))
      supported)))

(define (compiler-windows-coff-object-blocks-supported?
  [backend-state : compiler_backend.CompilerBackendState]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : bool
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) true]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (and
            (compiler-windows-coff-object-instrs-supported?
              backend-state
              instrs)
            (compiler-windows-coff-object-blocks-supported?
              backend-state
              (box-get rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (let
        [index : i64 0]
        [count : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
        [supported : bool true]
        (begin
          (while (and supported (< index count))
            (begin
              (match (compiler_ir_types.compiler-ir-block-seq-ref seq index)
                [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
                  (set!
                    supported
                    (compiler-windows-coff-object-instrs-supported?
                      backend-state
                      instrs))])
              (set! index (+ index 1))))
          supported))]))

(define (compiler-windows-coff-object-globals-supported?
  [globals : compiler_ir_types.CompilerIrGlobalList]) : bool
  (match globals
    [(compiler_ir_types.CompilerIrGlobalList.Nil) true]
    [(compiler_ir_types.CompilerIrGlobalList.Cons global rest)
      (match global
        [(compiler_ir_types.CompilerIrGlobal.Global _ _ value)
          (and
            (compiler-windows-coff-object-value-supported? value)
            (compiler-windows-coff-object-globals-supported? (box-get rest)))])]
    [(compiler_ir_types.CompilerIrGlobalList.Array seq)
      (let
        [index : i64 0]
        [count : i64 (compiler_ir_types.compiler-ir-global-seq-count seq)]
        [supported : bool true]
        (begin
          (while (and supported (< index count))
            (begin
              (match (compiler_ir_types.compiler-ir-global-seq-ref seq index)
                [(compiler_ir_types.CompilerIrGlobal.Global _ _ value)
                  (set!
                    supported
                    (compiler-windows-coff-object-value-supported? value))])
              (set! index (+ index 1))))
          supported))]))

(define (compiler-windows-coff-object-functions-supported?
  [backend-state : compiler_backend.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionList]) : bool
  (match functions
    [(compiler_ir_types.CompilerIrFunctionList.Nil) true]
    [(compiler_ir_types.CompilerIrFunctionList.Cons function rest)
      (match function
        [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ blocks)
          (and
            (or
              (compiler_backend.compiler-backend-stdlib-runtime-function-name?
                (compiler_backend.compiler-backend-symbol-text-state
                  backend-state
                  name))
              (compiler-windows-coff-object-blocks-supported?
                backend-state
                blocks))
            (compiler-windows-coff-object-functions-supported?
              backend-state
              (box-get rest)))])]
    [(compiler_ir_types.CompilerIrFunctionList.Array seq)
      (let
        [index : i64 0]
        [count : i64 (compiler_ir_types.compiler-ir-function-seq-count seq)]
        [supported : bool true]
        (begin
          (while (and supported (< index count))
            (begin
              (match (compiler_ir_types.compiler-ir-function-seq-ref seq index)
                [(compiler_ir_types.CompilerIrFunction.Function
                    name
                    _
                    _
                    _
                    blocks)
                  (set!
                    supported
                    (or
                      (compiler_backend.compiler-backend-stdlib-runtime-function-name?
                        (compiler_backend.compiler-backend-symbol-text-state
                          backend-state
                          name))
                      (compiler-windows-coff-object-blocks-supported?
                        backend-state
                        blocks)))])
              (set! index (+ index 1))))
          supported))]))

(define (compiler-windows-coff-object-program-supported?
  [backend-state : compiler_backend.CompilerBackendState]
  [program : compiler_ir_types.CompilerIrProgram]) : bool
  (match program
    [(compiler_ir_types.CompilerIrProgram.Program globals functions _)
      (and
        (compiler-windows-coff-object-globals-supported? globals)
        (compiler-windows-coff-object-functions-supported?
          backend-state
          functions))]))

(test
  compiler-windows-coff-runtime-global-falls-back
  (let
    [backend-state : compiler_backend.CompilerBackendState
      (compiler_backend.compiler-backend-state-new
        (ci.intern-compat-state-capture-active))]
    [globals : compiler_ir_types.CompilerIrGlobalList
      (compiler_ir_types.CompilerIrGlobalList.Cons
        (compiler_ir_types.CompilerIrGlobal.Global
          1
          (compiler_ast_types.AstType.I64)
          (compiler_ir_types.CompilerIrValue.RuntimeGlobal 2))
        (box compiler_ir_types.CompilerIrGlobalList.Nil))]
    [program : compiler_ir_types.CompilerIrProgram
      (compiler_ir_types.CompilerIrProgram.Program
        globals
        compiler_ir_types.CompilerIrFunctionList.Nil
        compiler_ir_types.CompilerIrExternList.Nil)]
    (test.assert-false
      (compiler-windows-coff-object-program-supported? backend-state program)
      "runtime-initialized globals stay on the assembly path")))

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
      (compiler-windows-coff-object-program-supported? backend-state program))
      (compiler-windows-batch-emit-assembly
        backend-state
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
          (compiler_driver_core.compiler-driver-profile-start-phase
            profile-state))
        (match (compiler_backend.compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
          backend-state
          pools
          program
          (compiler_backend.CompilerBackendTarget.Windows)
          mode
          spans
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
              (match (compiler-windows-coff-linkability image)
                [(CompilerWindowsCoffLinkability.Linkable)
                  (begin
                    (cfg
                      compile-profile
                      (compiler_driver_core.compiler-driver-profile-start-phase
                        profile-state))
                    (match (compiler_object_coff.compiler-object-coff-render
                      image)
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
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerWindowsBatchArtifact
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerWindowsBatchArtifact.Err
      (box
        (compiler_driver_core.compiler-driver-ty-node-pool-exhausted-diagnostic
          input-path)))
    (begin
      (compiler_driver_core.compiler-driver-release-typecheck-caches-after-lower!)
      (compiler_driver_core.compiler-driver-retire-frontend-arena!)
      (cfg
        compile-profile
        (compiler_driver_core.compiler-driver-profile-start-phase profile-state))
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state
        pools
        program
        spans
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
        backend-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler_driver_core.compiler-driver-retirement-clone-shells?
            opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell pools program)
            program)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler_driver_core.compiler-driver-retirement-clone-shells?
            opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerWindowsBatchArtifact
          (begin
            (compiler_ast_types.ast-node-pool-reader-use! pools)
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
              profile-state))]
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
          state
          input-path
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
        force-assembly
        false))))