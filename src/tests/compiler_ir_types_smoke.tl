;; compiler_ir_types_smoke.tl - Runnable IR type/effect smoke (#1043).
(import "../../stdlib/string.tl")
(import "../compiler_ir_types.tl")

(define (compiler-ir-smoke-function-list-first-name?
  [functions : CompilerIrFunctionList]
  [want : String]) : bool
  (match (compiler-ir-function-list-force-cons functions)
    [(IrFunctionCons func _)
      (match func
        [(IrFunction name _ _ _ _) (string-eq name want)])]
    [(IrFunctionNil) false]
    [(IrFunctionArray _) false]))

(define (compiler-ir-smoke-function-list-compact-kind?
  [functions : CompilerIrFunctionList]) : bool
  (match functions
    [(IrFunctionArray seq) (= (compiler-ir-function-seq-count seq) 2)]
    [_ false]))

(define (compiler-ir-smoke-function-seq-roundtrip-ok?) : bool
  (let
    [entry-instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 1)))
          IrInstrNil))]
    [blocks : CompilerIrBlockList
      (compiler-ir-block-list-compact
        (compiler-ir-block-cons
          (compiler-ir-block "entry" entry-instrs)
          IrBlockNil))]
    [first : CompilerIrFunction
      (IrFunction "first" IrParamNil (AstTyI64) 2 blocks)]
    [second : CompilerIrFunction
      (IrFunction "second" IrParamNil (AstTyI64) 2 blocks)]
    [functions : CompilerIrFunctionList
      (compiler-ir-function-cons
        first
        (compiler-ir-function-cons second IrFunctionNil))]
    [compact : CompilerIrFunctionList
      (compiler-ir-function-list-compact functions)]
    [cloned : CompilerIrFunctionList (compiler-ir-clone-function-list compact)]
    [summary : CompilerIrSummary
      (compiler-ir-program-summary (IrProgram IrGlobalNil compact IrExternNil))]
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

(define (main) : i64
  (begin
    (unless (compiler-ir-smoke-function-seq-roundtrip-ok?) (return 1))
    (compiler-ir-effect-self-test)))
