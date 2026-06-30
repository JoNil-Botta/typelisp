;; windows_param_preassign_backend.tl - backend smoke for #3493's Win64
;; incoming scalar parameter homes.
(import stdlib.io)
(import "../../src/compiler_backend.tl")

(define (win-param-preassign-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

(define (win-param-preassign-globals) : CompilerIrGlobalList
  (compiler-ir-global-cons
    (CompilerIrGlobal.Global "win_pa" (AstType.I64) (CompilerIrValue.I64 0))
    (compiler-ir-global-cons
      (CompilerIrGlobal.Global "win_pb" (AstType.I64) (CompilerIrValue.I64 0))
      (compiler-ir-global-cons
        (CompilerIrGlobal.Global "win_pc" (AstType.I64) (CompilerIrValue.I64 0))
        (compiler-ir-global-cons
          (CompilerIrGlobal.Global
            "win_pd"
            (AstType.I64)
            (CompilerIrValue.I64 0))
          CompilerIrGlobalList.Nil)))))

(define (win-param-preassign-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    "win_param_preassign"
    (compiler-ir-param-cons
      (CompilerIrParam.Param "a" (AstType.I64) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "b" (AstType.I64) 1)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "c" (AstType.I64) 2)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "d" (AstType.I64) 3)
            IrParamNil))))
    (AstType.Unit)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (CompilerIrInstr.Store "win_pa" (CompilerIrValue.Var 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              "win_pb"
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                "win_pc"
                (CompilerIrValue.Var 2)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  "win_pd"
                  (CompilerIrValue.Var 3)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil))))))
      CompilerIrBlockList.Nil)))

(define (win-param-preassign-program) : CompilerIrProgram
  (CompilerIrProgram.Program
    (win-param-preassign-globals)
    (compiler-ir-function-cons
      (win-param-preassign-function)
      CompilerIrFunctionList.Nil)
    CompilerIrExternList.Nil))

(define (win-param-preassign-safe-div-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    "win_param_safe_div"
    (compiler-ir-param-cons
      (CompilerIrParam.Param "a" (AstType.I64) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "b" (AstType.I64) 1)
        IrParamNil))
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            2
            CompilerIrBinOp.SafeDiv
            (CompilerIrValue.I64 8)
            (CompilerIrValue.I64 2)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (win-param-preassign-safe-div-regalloc-ok?) : bool
  (match (compiler-reg-plan-function-scalar-for-abi
    CompilerRegTargetAbi.Windows
    (win-param-preassign-safe-div-function))
    [(CompilerRegPlan.Plan assignments ineligible _ _ _)
      (and
        (compiler-live-set-contains? ineligible 1)
        (compiler-reg-unassigned? assignments 1))]))

(define (win-param-preassign-backend-ok?) : bool
  (begin
    (compiler-backend-set-scalar-registers! true)
    (match (compiler-backend-emit-program-target-with-mode
      (win-param-preassign-program)
      (CompilerBackendTarget.Windows)
      (CompilerBackendMode.Scalar)
      (compiler-source-spans-empty)
      false)
      [(ResultCompilerBackend.Ok asm)
        (let
          [ok : bool
            (and
              (compiler-backend-string-contains?
                asm
                "#t _tl_f0 _tl_win_param_preassign\n")
              (compiler-backend-string-contains? asm "_tl_f0:\n")
              (not
                (compiler-backend-string-contains?
                  asm
                  "    movq %rcx, -8(%rbp)\n"))
              (not
                (compiler-backend-string-contains?
                  asm
                  "    movq %rdx, -16(%rbp)\n"))
              (compiler-backend-string-contains?
                asm
                "    movq %r8, -24(%rbp)\n")
              (not
                (compiler-backend-string-contains?
                  asm
                  "    movq %r9, -32(%rbp)\n")))]
          (begin
            (compiler-backend-set-scalar-registers! false)
            ok))]
      [(ResultCompilerBackend.Err _)
        (begin
          (compiler-backend-set-scalar-registers! false)
          false)])))

(test
  windows-param-preassign-backend
  (win-param-preassign-assert-true
    (win-param-preassign-backend-ok?)
    "Windows scalar param preassignment should keep rcx/rdx/r9 homes and spill r8"))

(test
  windows-param-preassign-safe-div-regalloc
  (win-param-preassign-assert-true
    (win-param-preassign-safe-div-regalloc-ok?)
    "Windows rdx parameter home should be blocked across safe div/mod clobbers"))