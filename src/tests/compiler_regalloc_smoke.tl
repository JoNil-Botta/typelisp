;; compiler_regalloc_smoke.tl - Runnable smoke for compiler_regalloc.tl.
(import compiler_liveness as live)
(import compiler_regalloc as reg)
(import compiler_regalloc_tests as reg_tests)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.string)

(define (compiler-reg-smoke-spmd-call-function) : ir.CompilerIrFunction
  (let
    [spmd-args : ir.CompilerIrSpmdCallArgList
      (ir.ir-spmd-call-arg-cons
        (ir.CompilerIrSpmdCallArg.Arg
          (ir.CompilerIrSpmdValueClass.Uniform)
          (ir.CompilerIrValue.Var 1)
          (reg_tests.compiler-reg-i64-ty))
        (ir.ir-spmd-call-arg-cons
          (ir.CompilerIrSpmdCallArg.Arg
            (ir.CompilerIrSpmdValueClass.Varying)
            (ir.CompilerIrValue.Var 2)
            (reg_tests.compiler-reg-i64-ty))
          ir.CompilerIrSpmdCallArgList.Nil))]
    (ir.CompilerIrFunction.Function
      (ci.intern-generated-canonical-name "spmd_call")
      ir.CompilerIrParamList.Nil
      (reg_tests.compiler-reg-i64-ty)
      5
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 1)
              (reg_tests.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 2)
                (reg_tests.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Mov
                  2
                  (ir.CompilerIrValue.I64 3)
                  (reg_tests.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.ir-instr-spmd-call
                    (ci.intern-generated-canonical-name "spmd_helper")
                    (ir.CompilerIrSpmdBackend.Avx512)
                    8
                    (ir.CompilerIrValue.Var 0)
                    spmd-args
                    (ir.CompilerIrSpmdCallResult.Value
                      3
                      (ir.CompilerIrSpmdValueClass.Varying)
                      (reg_tests.compiler-reg-i64-ty)))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Mov
                      4
                      (ir.CompilerIrValue.Var 3)
                      (reg_tests.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Return
                        (ir.CompilerIrMaybeValue.Some
                          (ir.CompilerIrValue.Var 4)))
                      ir.CompilerIrInstrList.Nil)))))))
        ir.CompilerIrBlockList.Nil))))

(define (compiler-reg-smoke-spmd-call-shape-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-smoke-spmd-call-function)]
    [blocks : ir.CompilerIrBlockList
      (match (clone func)
        [(ir.CompilerIrFunction.Function _ _ _ _ inner) inner])]
    [call-args : live.CompilerLiveI64Set
      (reg.compiler-reg-call-arg-vars-blocks
        (clone blocks)
        (live.compiler-live-set-empty))]
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (clone func))]
    [call-live : live.CompilerLiveI64Set
      (reg.compiler-reg-call-live-blocks
        blocks
        liveness
        (live.compiler-live-set-empty))]
    [direct-calls : live.CompilerLiveI64Set
      (reg.compiler-reg-direct-call-points (clone func))]
    (match (reg.compiler-reg-plan-function func)
      [(reg.CompilerRegPlan.Plan _ ineligible _ _ _ _)
        (and
          (live.compiler-live-set-eq? call-args (live.compiler-live-set3 0 1 2))
          (live.compiler-live-set-contains? call-live 3)
          (live.compiler-live-set-contains? direct-calls 6)
          ;; Call operands retain ordinary spill eligibility; only hidden helper
          ;; parameters are admitted to the fixed private-register allocator.
          (live.compiler-live-set-contains?
            (live.compiler-live-shared-view ineligible)
            0)
          (live.compiler-live-set-contains?
            (live.compiler-live-shared-view ineligible)
            1)
          (live.compiler-live-set-contains?
            (live.compiler-live-shared-view ineligible)
            2))])))

(define (compiler-reg-smoke-descriptor-pair-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ci.intern-generated-canonical-name "descriptor_pair")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "handle" (ast.AstType.String) 0)
      ir.CompilerIrParamList.Nil)
    (ast.AstType.I64)
    8
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Load
            1
            (ir.CompilerIrValue.Var 0)
            (ast.AstType.U64))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Gep
              2
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 8)
              (ast.AstType.U8))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Load
                3
                (ir.CompilerIrValue.Var 2)
                (ast.AstType.I64))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Pack
                  4
                  (ir.compiler-ir-value-cons
                    (ir.CompilerIrValue.Var 1)
                    (ir.compiler-ir-value-cons
                      (ir.CompilerIrValue.Var 3)
                      ir.CompilerIrValueList.Nil))
                  (ast.AstType.String))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Mov
                    5
                    (ir.CompilerIrValue.Var 4)
                    (ast.AstType.String))
                  (ir.compiler-ir-instr-cons
                    (ir.ir-instr-descriptor-pair-data
                      6
                      (ir.CompilerIrValue.Var 5))
                    (ir.compiler-ir-instr-cons
                      (ir.ir-instr-descriptor-pair-length
                        7
                        (ir.CompilerIrValue.Var 5))
                      (ir.compiler-ir-instr-cons
                        (ir.CompilerIrInstr.Return
                          (ir.CompilerIrMaybeValue.Some
                            (ir.CompilerIrValue.Var 7)))
                        ir.CompilerIrInstrList.Nil)))))))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-reg-smoke-descriptor-pair-group-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-smoke-descriptor-pair-function)]
    [types : reg.CompilerRegVarTypes (reg.compiler-reg-function-var-types func)]
    [representations : ir.CompilerIrRepresentationIndex
      (ir.compiler-ir-representation-index-empty)]
    [groups : live.CompilerLiveI64Set
      (reg.compiler-reg-function-group-vars
        (ast.ast-node-pool-reader-type-segment-bases)
        func
        types)]
    (and
      ;; Source handles remain scalar even though structurally-created pair
      ;; vars with the same provenance type occupy two homes.
      (not
        (reg.compiler-reg-type-register-group?
          (ast.ast-node-pool-reader-type-segment-bases)
          representations
          (ast.AstType.String)))
      (not
        (reg.compiler-reg-type-register-group?
          (ast.ast-node-pool-reader-type-segment-bases)
          representations
          (ast.AstType.DynArray 1)))
      (=
        (live.compiler-live-set-count
          (live.compiler-live-shared-view groups))
        2)
      (not
        (live.compiler-live-set-contains?
          (live.compiler-live-shared-view groups)
          0))
      (live.compiler-live-set-contains?
        (live.compiler-live-shared-view groups)
        4)
      (live.compiler-live-set-contains?
        (live.compiler-live-shared-view groups)
        5)
      (not
        (live.compiler-live-set-contains?
          (live.compiler-live-shared-view groups)
          6))
      (not
        (live.compiler-live-set-contains?
          (live.compiler-live-shared-view groups)
          7)))))

(define (main) : i64
  (begin
    (reg_tests.compiler-regalloc-self-test-require!
      "named failure message renderer"
      (string.eq
        (reg_tests.compiler-regalloc-self-test-failure-message "register reuse")
        "regalloc self-test failed: register reuse"))
    (reg_tests.compiler-regalloc-self-test)
    (reg_tests.compiler-regalloc-self-test-require!
      "compiler-reg-smoke-spmd-call-shape-ok?"
      (compiler-reg-smoke-spmd-call-shape-ok?))
    (reg_tests.compiler-regalloc-self-test-require!
      "compiler-reg-smoke-descriptor-pair-group-ok?"
      (compiler-reg-smoke-descriptor-pair-group-ok?))
    42))
