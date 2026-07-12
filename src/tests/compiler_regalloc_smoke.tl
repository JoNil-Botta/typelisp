;; compiler_regalloc_smoke.tl - Runnable smoke for compiler_regalloc.tl.
(import "../compiler_liveness.tl")
(import "../compiler_regalloc.tl")

(define (compiler-reg-smoke-spmd-call-function) : CompilerIrFunction
  (let
    [spmd-args : CompilerIrSpmdCallArgList
      (ir-spmd-call-arg-cons
        (CompilerIrSpmdCallArg.Arg
          (CompilerIrSpmdValueClass.Uniform)
          (CompilerIrValue.Var 1)
          (compiler-reg-i64-ty))
        (ir-spmd-call-arg-cons
          (CompilerIrSpmdCallArg.Arg
            (CompilerIrSpmdValueClass.Varying)
            (CompilerIrValue.Var 2)
            (compiler-reg-i64-ty))
          CompilerIrSpmdCallArgList.Nil))]
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
                    (CompilerIrSpmdBackend.Avx512)
                    8
                    (CompilerIrValue.Var 0)
                    spmd-args
                    (CompilerIrSpmdCallResult.Value
                      3
                      (CompilerIrSpmdValueClass.Varying)
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

(define (compiler-reg-smoke-descriptor-pair-function) : CompilerIrFunction
  (let
    [kind : CompilerIrDescriptorPairKind
      (CompilerIrDescriptorPairKind.OwnedString)]
    (CompilerIrFunction.Function
      "descriptor_pair"
      (compiler-ir-param-cons
        (CompilerIrParam.Param "handle" (AstType.String) 0)
        CompilerIrParamList.Nil)
      (AstType.I64)
      8
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 1 (CompilerIrValue.Var 0) (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                2
                (CompilerIrValue.Var 0)
                (CompilerIrValue.I64 8)
                (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
                (compiler-ir-instr-cons
                  (ir-instr-descriptor-pair-pack
                    4
                    (CompilerIrValue.Var 1)
                    (CompilerIrValue.Var 3)
                    kind)
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      5
                      (CompilerIrValue.Var 4)
                      (AstType.String))
                    (compiler-ir-instr-cons
                      (ir-instr-descriptor-pair-data 6 (CompilerIrValue.Var 5))
                      (compiler-ir-instr-cons
                        (ir-instr-descriptor-pair-length
                          7
                          (CompilerIrValue.Var 5))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.Return
                            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 7)))
                          CompilerIrInstrList.Nil)))))))))
        CompilerIrBlockList.Nil))))

(define (compiler-reg-smoke-descriptor-pair-group-ok?) : bool
  (let
    [func : CompilerIrFunction (compiler-reg-smoke-descriptor-pair-function)]
    [types : CompilerRegVarTypes (compiler-reg-function-var-types func)]
    [groups : CompilerLiveI64Set
      (compiler-reg-function-group-vars
        func
        (compiler-reg-var-types-list types))]
    (and
      ;; Source handles remain scalar even though structurally-created pair
      ;; vars with the same provenance type occupy two homes.
      (not (compiler-reg-type-register-group? (AstType.String)))
      (not (compiler-reg-type-register-group? (AstType.DynArray 1)))
      (= (compiler-live-set-count groups) 2)
      (not (compiler-live-set-contains? groups 0))
      (compiler-live-set-contains? groups 4)
      (compiler-live-set-contains? groups 5)
      (not (compiler-live-set-contains? groups 6))
      (not (compiler-live-set-contains? groups 7)))))

(define (main) : i64
  (let
    [base : i64 (compiler-regalloc-self-test)]
    (if (and
      (= base 42)
      (compiler-reg-smoke-spmd-call-shape-ok?)
      (compiler-reg-smoke-descriptor-pair-group-ok?))
      42
      1)))