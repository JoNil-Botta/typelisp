;; compiler_liveness_smoke.tl - Runnable smoke for compiler_liveness.tl.
(import "../compiler_ir_types.tl")
(import "../compiler_liveness.tl")

(define (compiler-live-smoke-spmd-call-use-def-ok?) : bool
  (let
    [args : CompilerIrSpmdCallArgList
      (ir-spmd-call-arg-cons
        (CompilerIrSpmdCallArg.Arg
          (CompilerIrSpmdValueClass.Uniform)
          (CompilerIrValue.Var 21)
          (compiler-live-i64-ty))
        (ir-spmd-call-arg-cons
          (CompilerIrSpmdCallArg.Arg
            (CompilerIrSpmdValueClass.Varying)
            (CompilerIrValue.Var 22)
            (compiler-live-i64-ty))
          CompilerIrSpmdCallArgList.Nil))]
    [instr : CompilerIrInstr
      (ir-instr-spmd-call
        "helper"
        (CompilerIrSpmdBackend.Avx512)
        8
        (CompilerIrValue.Var 20)
        args
        (CompilerIrSpmdCallResult.Value
          6
          (CompilerIrSpmdValueClass.Varying)
          (compiler-live-i64-ty)))]
    (and
      (compiler-live-set-eq?
        (compiler-live-instr-uses instr)
        (compiler-live-set3 20 21 22))
      (compiler-live-set-eq?
        (compiler-live-instr-defs instr)
        (compiler-live-set1 6)))))

(define (compiler-live-smoke-descriptor-pair-use-def-ok?) : bool
  (let
    [kind : CompilerIrDescriptorPairKind
      (CompilerIrDescriptorPairKind.OwnedString)]
    [pack : CompilerIrInstr
      (ir-instr-descriptor-pair-pack
        3
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 2)
        kind)]
    [data : CompilerIrInstr
      (ir-instr-descriptor-pair-data 4 (CompilerIrValue.Var 3))]
    [length : CompilerIrInstr
      (ir-instr-descriptor-pair-length 5 (CompilerIrValue.Var 3))]
    (and
      (compiler-live-set-eq?
        (compiler-live-instr-uses pack)
        (compiler-live-set2 1 2))
      (compiler-live-set-eq?
        (compiler-live-instr-defs pack)
        (compiler-live-set1 3))
      (compiler-live-set-eq?
        (compiler-live-instr-uses data)
        (compiler-live-set1 3))
      (compiler-live-set-eq?
        (compiler-live-instr-defs data)
        (compiler-live-set1 4))
      (compiler-live-set-eq?
        (compiler-live-instr-uses length)
        (compiler-live-set1 3))
      (compiler-live-set-eq?
        (compiler-live-instr-defs length)
        (compiler-live-set1 5)))))

(define (main) : i64
  (let
    [base : i64 (compiler-live-self-test)]
    (if (and
      (= base 42)
      (compiler-live-smoke-spmd-call-use-def-ok?)
      (compiler-live-smoke-descriptor-pair-use-def-ok?))
      42
      1)))