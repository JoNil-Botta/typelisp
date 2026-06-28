;; compiler_ir_types_smoke.tl - Runnable IR type/effect smoke (#1043).
(import stdlib.string)
(import "../compiler_ir_types.tl")

(define (compiler-ir-smoke-function-list-first-name?
  [functions : CompilerIrFunctionList]
  [want : String]) : bool
  (match (compiler-ir-function-list-force-cons functions)
    [(CompilerIrFunctionList.Cons func _)
      (match func
        [(CompilerIrFunction.Function name _ _ _ _)
          (string.string-eq name want)])]
    [(CompilerIrFunctionList.Nil) false]
    [(CompilerIrFunctionList.Array _) false]))

(define (compiler-ir-smoke-function-list-compact-kind?
  [functions : CompilerIrFunctionList]) : bool
  (match functions
    [(CompilerIrFunctionList.Array seq)
      (= (compiler-ir-function-seq-count seq) 2)]
    [_ false]))

(define (compiler-ir-smoke-function-seq-roundtrip-ok?) : bool
  (let
    [entry-instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstTyI64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
          CompilerIrInstrList.Nil))]
    [blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact
        (compiler-ir-block-cons
          (compiler-ir-block "entry" entry-instrs)
          CompilerIrBlockList.Nil))]
    [first : CompilerIrFunction
      (CompilerIrFunction.Function "first" IrParamNil (AstTyI64) 2 blocks)]
    [second : CompilerIrFunction
      (CompilerIrFunction.Function "second" IrParamNil (AstTyI64) 2 blocks)]
    [functions : CompilerIrFunctionList
      (compiler-ir-function-cons
        first
        (compiler-ir-function-cons second CompilerIrFunctionList.Nil))]
    [compact : CompilerIrFunctionList
      (compiler-ir-function-list-compact functions)]
    [cloned : CompilerIrFunctionList (compiler-ir-clone-function-list compact)]
    [summary : CompilerIrSummary
      (compiler-ir-program-summary
        (CompilerIrProgram.Program
          CompilerIrGlobalList.Nil
          compact
          CompilerIrExternList.Nil))]
    (and
      (compiler-ir-smoke-function-list-compact-kind? compact)
      (compiler-ir-smoke-function-list-compact-kind? cloned)
      (= (compiler-ir-function-list-count compact) 2)
      (compiler-ir-smoke-function-list-first-name? compact "first")
      (= (compiler-ir-function-list-block-count compact) 2)
      (= (compiler-ir-function-list-instruction-count compact) 4)
      (= (compiler-ir-summary-functions summary) 2)
      (= (compiler-ir-summary-blocks summary) 2)
      (= (compiler-ir-summary-instructions summary) 4))))

(define (compiler-ir-smoke-spmd-call-shape-ok?) : bool
  (let
    [args : CompilerIrSpmdCallArgList
      (ir-spmd-call-arg-cons
        (IrSpmdCallArg (IrSpmdValueUniform) (CompilerIrValue.Var 21) (AstTyI64))
        (ir-spmd-call-arg-cons
          (IrSpmdCallArg (IrSpmdValueVarying) (CompilerIrValue.Var 22) (AstTyI64))
          IrSpmdCallArgNil))]
    [instr : CompilerIrInstr
      (ir-instr-spmd-call
        "helper"
        (IrSpmdBackendAvx2)
        8
        (CompilerIrValue.Var 20)
        args
        (IrSpmdCallResultValue 6 (IrSpmdValueVarying) (AstTyI64)))]
    [span : AstSourceSpan (AstSourceSpan 3 4 3 9)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-empty)
        "func"
        instr
        span)]
    (and
      (string.string-eq
        (compiler-ir-instr-render instr)
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) : varying i64")
      (string.string-eq
        (compiler-ir-instr-describe instr)
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) -> %6 : varying i64")
      (compiler-ir-effect-is? instr CompilerIrEffect.Unknown)
      (= (compiler-ir-instr-call-arg-count instr) 2)
      (string.string-eq
        (compiler-ir-instr-render (compiler-ir-clone-instr instr))
        (compiler-ir-instr-render instr))
      (match (compiler-source-spans-lookup-instr spans "func" instr)
        [(CompilerMaybeSourceSpan.Some found)
          (and
            (= (struct-get found start-line) 3)
            (= (struct-get found end-col) 9))]
        [(CompilerMaybeSourceSpan.No) false]))))

(define (main) : i64
  (begin
    (unless (compiler-ir-smoke-function-seq-roundtrip-ok?) (return 1))
    (unless (compiler-ir-smoke-spmd-call-shape-ok?) (return 2))
    (compiler-ir-effect-self-test)))