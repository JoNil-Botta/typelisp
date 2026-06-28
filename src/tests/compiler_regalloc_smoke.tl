;; compiler_regalloc_smoke.tl - Runnable smoke for compiler_regalloc.tl (#554).
(import "../compiler_liveness.tl")
(import "../compiler_regalloc.tl")

(define (compiler-reg-smoke-spmd-call-function) : CompilerIrFunction
  (let
    [spmd-args : CompilerIrSpmdCallArgList
      (ir-spmd-call-arg-cons
        (IrSpmdCallArg
          (IrSpmdValueUniform)
          (IrValueVar 1)
          (compiler-reg-i64-ty))
        (ir-spmd-call-arg-cons
          (IrSpmdCallArg
            (IrSpmdValueVarying)
            (IrValueVar 2)
            (compiler-reg-i64-ty))
          IrSpmdCallArgNil))]
    (IrFunction
      "spmd_call"
      IrParamNil
      (compiler-reg-i64-ty)
      5
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 1) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 1 (IrValueI64 2) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov 2 (IrValueI64 3) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (ir-instr-spmd-call
                    "spmd_helper"
                    (IrSpmdBackendAvx512)
                    8
                    (IrValueVar 0)
                    spmd-args
                    (IrSpmdCallResultValue
                      3
                      (IrSpmdValueVarying)
                      (compiler-reg-i64-ty)))
                  (compiler-ir-instr-cons
                    (IrInstrMov 4 (IrValueVar 3) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                      IrInstrNil)))))))
        IrBlockNil))))

(define (compiler-reg-smoke-spmd-call-shape-ok?) : bool
  (let
    [func : CompilerIrFunction (compiler-reg-smoke-spmd-call-function)]
    [blocks : CompilerIrBlockList
      (match func
        [(IrFunction _ _ _ _ inner) inner])]
    [call-args : CompilerLiveI64Set
      (compiler-reg-call-arg-vars-blocks blocks (compiler-live-set-empty))]
    [liveness : CompilerFunctionLiveness (compiler-live-analyze-function func)]
    [call-live : CompilerLiveI64Set
      (compiler-reg-call-live-blocks blocks liveness (compiler-live-set-empty))]
    [direct-calls : CompilerLiveI64Set (compiler-reg-direct-call-points func)]
    (match (compiler-reg-plan-function func)
      [(CompilerRegPlan _ ineligible _ _ _)
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