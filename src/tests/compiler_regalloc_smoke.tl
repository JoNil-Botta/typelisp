;; compiler_regalloc_smoke.tl - Runnable smoke for compiler_regalloc.tl.
(import "../compiler_liveness.tl")
(import "../compiler_regalloc.tl")

(define (compiler-reg-smoke-spmd-call-function) : CompilerIrFunction
  (let
    [spmd-args : CompilerIrSpmdCallArgList
      (ir-spmd-call-arg-cons
        (IrSpmdCallArg
          (IrSpmdValueUniform)
          (CompilerIrValue.Var 1)
          (compiler-reg-i64-ty))
        (ir-spmd-call-arg-cons
          (IrSpmdCallArg
            (IrSpmdValueVarying)
            (CompilerIrValue.Var 2)
            (compiler-reg-i64-ty))
          IrSpmdCallArgNil))]
    (CompilerIrFunction.Function
      "spmd_call"
      CompilerIrParamList.Nil
      (compiler-reg-i64-ty)
      5
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 1)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                1
                (CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Mov
                  2
                  (CompilerIrValue.I64 3)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (ir-instr-spmd-call
                    "spmd_helper"
                    (IrSpmdBackendAvx512)
                    8
                    (CompilerIrValue.Var 0)
                    spmd-args
                    (IrSpmdCallResultValue
                      3
                      (IrSpmdValueVarying)
                      (compiler-reg-i64-ty)))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      4
                      (CompilerIrValue.Var 3)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Return
                        (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                      CompilerIrInstrList.Nil)))))))
        CompilerIrBlockList.Nil))))

(define (compiler-reg-smoke-spmd-call-shape-ok?) : bool
  (let
    [func : CompilerIrFunction (compiler-reg-smoke-spmd-call-function)]
    [blocks : CompilerIrBlockList
      (match func
        [(CompilerIrFunction.Function _ _ _ _ inner) inner])]
    [call-args : CompilerLiveI64Set
      (compiler-reg-call-arg-vars-blocks blocks (compiler-live-set-empty))]
    [liveness : CompilerFunctionLiveness (compiler-live-analyze-function func)]
    [call-live : CompilerLiveI64Set
      (compiler-reg-call-live-blocks blocks liveness (compiler-live-set-empty))]
    [direct-calls : CompilerLiveI64Set (compiler-reg-direct-call-points func)]
    (match (compiler-reg-plan-function func)
      [(CompilerRegPlan.Plan _ ineligible _ _ _ _)
        (and
          (compiler-live-set-eq? call-args (compiler-live-set3 0 1 2))
          (compiler-live-set-contains? call-live 3)
          (compiler-live-set-contains? direct-calls 6)
          (compiler-live-set-contains? ineligible 0)
          (compiler-live-set-contains? ineligible 1)
          (compiler-live-set-contains? ineligible 2))])))

(define (main) : i64
  (let
    [base : i64 (compiler-regalloc-self-test)]
    (if (and (= base 42) (compiler-reg-smoke-spmd-call-shape-ok?))
      42
      1)))