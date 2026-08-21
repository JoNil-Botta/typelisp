;; compiler_liveness_smoke.tl - Runnable smoke for compiler_liveness.tl.
(import compiler_ir_types as ir)
(import compiler_liveness as live)
(import compiler_liveness_tests as live_tests)
(import compiler_intern as ci)

(define (compiler-live-smoke-spmd-call-use-def-ok?) : bool
  (let
    [args : ir.CompilerIrSpmdCallArgSeq
      (ir.compiler-ir-spmd-call-arg-seq2
        (ir.CompilerIrSpmdCallArg.Arg
          (ir.CompilerIrSpmdValueClass.Uniform)
          (ir.CompilerIrValue.Var 21)
          (live_tests.compiler-live-i64-ty))
        (ir.CompilerIrSpmdCallArg.Arg
          (ir.CompilerIrSpmdValueClass.Varying)
          (ir.CompilerIrValue.Var 22)
          (live_tests.compiler-live-i64-ty)))]
    [instr : ir.CompilerIrInstr
      (ir.ir-instr-spmd-call
        (ci.intern-generated-canonical-name "helper")
        (ir.CompilerIrSpmdBackend.Avx512)
        8
        (ir.CompilerIrValue.Var 20)
        args
        (ir.CompilerIrSpmdCallResult.Value
          6
          (ir.CompilerIrSpmdValueClass.Varying)
          (live_tests.compiler-live-i64-ty)))]
    (and
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-uses instr)
        (live.compiler-live-set3 20 21 22))
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-defs instr)
        (live.compiler-live-set1 6)))))

(define (compiler-live-smoke-descriptor-pair-use-def-ok?) : bool
  (let
    [kind : ir.CompilerIrDescriptorPairKind
      (ir.CompilerIrDescriptorPairKind.OwnedString)]
    [pack : ir.CompilerIrInstr
      (ir.ir-instr-descriptor-pair-pack
        3
        (ir.CompilerIrValue.Var 1)
        (ir.CompilerIrValue.Var 2)
        kind)]
    [data : ir.CompilerIrInstr
      (ir.ir-instr-descriptor-pair-data 4 (ir.CompilerIrValue.Var 3))]
    [length : ir.CompilerIrInstr
      (ir.ir-instr-descriptor-pair-length 5 (ir.CompilerIrValue.Var 3))]
    (and
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-uses pack)
        (live.compiler-live-set2 1 2))
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-defs pack)
        (live.compiler-live-set1 3))
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-uses data)
        (live.compiler-live-set1 3))
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-defs data)
        (live.compiler-live-set1 4))
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-uses length)
        (live.compiler-live-set1 3))
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-defs length)
        (live.compiler-live-set1 5)))))

(define (main) : i64
  (let
    [base : i64 (live_tests.compiler-live-self-test)]
    (if (and
      (= base 42)
      (compiler-live-smoke-spmd-call-use-def-ok?)
      (compiler-live-smoke-descriptor-pair-use-def-ok?))
      42
      1)))