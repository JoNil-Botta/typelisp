;; compiler_regalloc_smoke.tl - Runnable smoke for compiler_regalloc.tl.
(import compiler_liveness as live)
(import compiler_liveness_tests as live_tests)
(import compiler_regalloc as reg)
(import compiler_regalloc_tests as reg_tests)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)

(define (compiler-regalloc-smoke-instr-seq-prepend
  [instr : ir.CompilerIrInstr]
  [rest : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
  (let
    [builder : ir.CompilerIrInstrBuilder
      (ir.compiler-ir-instr-builder-with-capacity (+ rest.len 1))]
    (ir.compiler-ir-instr-builder-push! (&mut builder) instr)
    (ir.compiler-ir-instr-builder-append-seq-range!
      (&mut builder)
      rest
      0
      rest.len)
    (ir.compiler-ir-instr-builder-to-seq builder)))

(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.string)

(define (compiler-reg-smoke-spmd-call-function) : ir.CompilerIrFunction
  (let
    [spmd-args : ir.CompilerIrSpmdCallArgSeq
      (ir.compiler-ir-spmd-call-arg-seq2
        (Arg (Uniform) (Var 1) (reg_tests.compiler-reg-i64-ty))
        (Arg (Varying) (Var 2) (reg_tests.compiler-reg-i64-ty)))]
    (Function
      (ci.intern-generated-canonical-name "spmd_call")
      (ir.compiler-ir-param-seq-empty)
      (reg_tests.compiler-reg-i64-ty)
      5
      (ir.compiler-ir-blocks
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "entry")
          (compiler-regalloc-smoke-instr-seq-prepend
            (irt.instr "%0 = mov 1 : i64")
            (compiler-regalloc-smoke-instr-seq-prepend
              (irt.instr "%1 = mov 2 : i64")
              (compiler-regalloc-smoke-instr-seq-prepend
                (irt.instr "%2 = mov 3 : i64")
                (compiler-regalloc-smoke-instr-seq-prepend
                  (ir.compiler-ir-test-spmd-private-call
                    (ci.intern-generated-canonical-name "spmd_helper")
                    (Avx512)
                    8
                    (& (Var 0))
                    (& spmd-args)
                    (& (Value 3 (Varying) (reg_tests.compiler-reg-i64-ty))))
                  (irt.instrs
                    "%4 = mov %3 : i64
                     return %4")))))))
      Ordinary)))

(define (compiler-reg-smoke-spmd-call-shape-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-smoke-spmd-call-function)]
    [blocks : ir.CompilerIrBlockList
      (match (clone func)
        [(Function _ _ _ _ inner _) inner])]
    [call-args : live.CompilerLiveI64Set
      (reg.compiler-reg-call-arg-vars-blocks
        (& (clone blocks))
        (live.compiler-live-set-empty))]
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (& (clone func)))]
    [call-live : live.CompilerLiveI64Set
      (reg_tests.compiler-reg-call-live-blocks
        blocks
        liveness
        (live.compiler-live-set-empty))]
    [direct-calls : live.CompilerLiveI64Set
      (reg_tests.compiler-reg-direct-call-points (clone func))]
    (match (reg_tests.compiler-reg-plan-function func)
      [(Plan _ ineligible _ _ _)
        (and
          (live.compiler-live-set-eq?
            call-args
            (live_tests.compiler-live-set3 0 1 2))
          (live.compiler-live-set-contains? call-live 3)
          (live.compiler-live-set-contains? direct-calls 6)
          ;; Call operands retain ordinary spill eligibility; only hidden helper
          ;; parameters are admitted to the fixed private-register allocator.
          (live.compiler-live-set-contains? ineligible 0)
          (live.compiler-live-set-contains? ineligible 1)
          (live.compiler-live-set-contains? ineligible 2))])))

(define (compiler-reg-smoke-descriptor-pair-function) : ir.CompilerIrFunction
  (Function
    (ci.intern-generated-canonical-name "descriptor_pair")
    (irt.params "handle=%0:String")
    (I64)
    8
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (compiler-regalloc-smoke-instr-seq-prepend
          (irt.instr "%1 = load %0 : u64")
          (compiler-regalloc-smoke-instr-seq-prepend
            (irt.instr "%2 = gep %0, 8 : u8")
            (compiler-regalloc-smoke-instr-seq-prepend
              (irt.instr "%3 = load %2 : i64")
              (compiler-regalloc-smoke-instr-seq-prepend
                (irt.instr "%4 = pack [%1, %3] : String")
                (compiler-regalloc-smoke-instr-seq-prepend
                  (irt.instr "%5 = mov %4 : String")
                  (compiler-regalloc-smoke-instr-seq-prepend
                    (ir.ir-instr-descriptor-pair-data 6 (Var 5))
                    (compiler-regalloc-smoke-instr-seq-prepend
                      (ir.ir-instr-descriptor-pair-length 7 (Var 5))
                      (irt.instrs "return %7"))))))))))
    Ordinary))

(define (compiler-reg-smoke-descriptor-pair-group-ok?) : bool
  (let
    [func : ir.CompilerIrFunction (compiler-reg-smoke-descriptor-pair-function)]
    [types : reg.CompilerRegVarTypes (reg.compiler-reg-function-var-types func)]
    [representations : ir.CompilerIrRepresentationIndex
      (ir.compiler-ir-representation-index-empty)]
    [groups : live.CompilerLiveI64Set
      (reg.compiler-reg-function-group-vars
        (ast.ast-node-pool-reader-type-segment-bases)
        (& func)
        types)]
    (and
      ;; Source handles remain scalar even though structurally-created pair
      ;; vars with the same provenance type occupy two homes.
      (not
        (reg.compiler-reg-type-register-group?
          (ast.ast-node-pool-reader-type-segment-bases)
          (& representations)
          (& (String))))
      (not
        (reg.compiler-reg-type-register-group?
          (ast.ast-node-pool-reader-type-segment-bases)
          (& representations)
          (& (DynArray 1))))
      (= (live.compiler-live-set-count groups) 2)
      (not (live.compiler-live-set-contains? groups 0))
      (live.compiler-live-set-contains? groups 4)
      (live.compiler-live-set-contains? groups 5)
      (not (live.compiler-live-set-contains? groups 6))
      (not (live.compiler-live-set-contains? groups 7)))))

(define (main) : i64
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
  42)