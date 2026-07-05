;; compiler_ir_types_smoke.tl - Runnable IR type/effect smoke (#1043).
(import stdlib.string)
(import "../compiler_ir_types.tl")

(define (compiler-ir-smoke-function-list-first-name?
  [functions : CompilerIrFunctionList]
  [want : String]) : bool
  (match (compiler-ir-function-list-force-cons functions)
    [(CompilerIrFunctionList.Cons func _)
      (match func
        [(CompilerIrFunction.Function name _ _ _ _) (string.eq name want)])]
    [(CompilerIrFunctionList.Nil) false]
    [(CompilerIrFunctionList.Array _) false]))

(define (compiler-ir-smoke-function-list-name-at?
  [functions : CompilerIrFunctionList]
  [index : i64]
  [want : String]) : bool
  (match (compiler-ir-function-list-force-cons functions)
    [(CompilerIrFunctionList.Cons func rest)
      (if (= index 0)
        (match func
          [(CompilerIrFunction.Function name _ _ _ _) (string.eq name want)])
        (compiler-ir-smoke-function-list-name-at?
          (box-get rest)
          (- index 1)
          want))]
    [(CompilerIrFunctionList.Nil) false]
    [(CompilerIrFunctionList.Array _) false]))

(define (compiler-ir-smoke-block-list-label-at?
  [blocks : CompilerIrBlockList]
  [index : i64]
  [want : String]) : bool
  (match (compiler-ir-block-list-force-cons blocks)
    [(CompilerIrBlockList.Cons block rest)
      (if (= index 0)
        (match block
          [(CompilerIrBlock.Block label _) (string.eq label want)])
        (compiler-ir-smoke-block-list-label-at? (box-get rest) (- index 1) want))]
    [(CompilerIrBlockList.Nil) false]
    [(CompilerIrBlockList.Array _) false]))

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
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
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
      (CompilerIrFunction.Function
        "first"
        CompilerIrParamList.Nil
        (AstType.I64)
        2
        blocks)]
    [second : CompilerIrFunction
      (CompilerIrFunction.Function
        "second"
        CompilerIrParamList.Nil
        (AstType.I64)
        2
        blocks)]
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

(define (compiler-ir-smoke-reversed-compaction-ok?) : bool
  (let
    [first-block : CompilerIrBlock
      (compiler-ir-block "first" CompilerIrInstrList.Nil)]
    [second-block : CompilerIrBlock
      (compiler-ir-block "second" CompilerIrInstrList.Nil)]
    [third-block : CompilerIrBlock
      (compiler-ir-block "third" CompilerIrInstrList.Nil)]
    [reversed-blocks : CompilerIrBlockList
      (compiler-ir-block-cons
        third-block
        (compiler-ir-block-cons
          second-block
          (compiler-ir-block-cons first-block CompilerIrBlockList.Nil)))]
    [compact-blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact-reversed reversed-blocks)]
    [array-reversed-blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact-reversed compact-blocks)]
    [first-func : CompilerIrFunction
      (CompilerIrFunction.Function
        "first-func"
        CompilerIrParamList.Nil
        (AstType.Unit)
        0
        compact-blocks)]
    [second-func : CompilerIrFunction
      (CompilerIrFunction.Function
        "second-func"
        CompilerIrParamList.Nil
        (AstType.Unit)
        0
        compact-blocks)]
    [third-func : CompilerIrFunction
      (CompilerIrFunction.Function
        "third-func"
        CompilerIrParamList.Nil
        (AstType.Unit)
        0
        compact-blocks)]
    [reversed-functions : CompilerIrFunctionList
      (compiler-ir-function-cons
        third-func
        (compiler-ir-function-cons
          second-func
          (compiler-ir-function-cons first-func CompilerIrFunctionList.Nil)))]
    [compact-functions : CompilerIrFunctionList
      (compiler-ir-function-list-compact-reversed reversed-functions)]
    [array-reversed-functions : CompilerIrFunctionList
      (compiler-ir-function-list-compact-reversed compact-functions)]
    (and
      (= (compiler-ir-block-list-count compact-blocks) 3)
      (compiler-ir-smoke-block-list-label-at? compact-blocks 0 "first")
      (compiler-ir-smoke-block-list-label-at? compact-blocks 1 "second")
      (compiler-ir-smoke-block-list-label-at? compact-blocks 2 "third")
      (compiler-ir-smoke-block-list-label-at? array-reversed-blocks 0 "third")
      (compiler-ir-smoke-block-list-label-at? array-reversed-blocks 2 "first")
      (= (compiler-ir-function-list-count compact-functions) 3)
      (compiler-ir-smoke-function-list-name-at?
        compact-functions
        0
        "first-func")
      (compiler-ir-smoke-function-list-name-at?
        compact-functions
        1
        "second-func")
      (compiler-ir-smoke-function-list-name-at?
        compact-functions
        2
        "third-func")
      (compiler-ir-smoke-function-list-name-at?
        array-reversed-functions
        0
        "third-func")
      (compiler-ir-smoke-function-list-name-at?
        array-reversed-functions
        2
        "first-func"))))

(define (compiler-ir-smoke-spmd-call-shape-ok?) : bool
  (let
    [args : CompilerIrSpmdCallArgList
      (ir-spmd-call-arg-cons
        (IrSpmdCallArg
          (IrSpmdValueUniform)
          (CompilerIrValue.Var 21)
          (AstType.I64))
        (ir-spmd-call-arg-cons
          (IrSpmdCallArg
            (IrSpmdValueVarying)
            (CompilerIrValue.Var 22)
            (AstType.I64))
          IrSpmdCallArgNil))]
    [instr : CompilerIrInstr
      (ir-instr-spmd-call
        "helper"
        (IrSpmdBackendAvx2)
        8
        (CompilerIrValue.Var 20)
        args
        (IrSpmdCallResultValue 6 (IrSpmdValueVarying) (AstType.I64)))]
    [span : AstSourceSpan (AstSourceSpan 3 4 3 9)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-empty)
        "func"
        instr
        span)]
    (and
      (string.eq
        (compiler-ir-instr-render instr)
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) : varying i64")
      (string.eq
        (compiler-ir-instr-describe instr)
        "  spmd_call helper backend avx2 lanes 8 mask %20(uniform %21 : i64, varying %22 : i64) -> %6 : varying i64")
      (compiler-ir-effect-is? instr CompilerIrEffect.Unknown)
      (= (compiler-ir-instr-call-arg-count instr) 2)
      (string.eq
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
    (unless (compiler-ir-smoke-reversed-compaction-ok?) (return 2))
    (unless (compiler-ir-smoke-spmd-call-shape-ok?) (return 3))
    (compiler-ir-effect-self-test)))