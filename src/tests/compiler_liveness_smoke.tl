;; compiler_liveness_smoke.tl - Runnable smoke for compiler_liveness.tl.
(import "../compiler_ir_types.tl")
(import "../compiler_liveness.tl")

(define (compiler-live-smoke-spmd-call-use-def-ok?) : bool
  (let
    [args : CompilerIrSpmdCallArgList
      (ir-spmd-call-arg-cons
        (IrSpmdCallArg
          (IrSpmdValueUniform)
          (CompilerIrValue.Var 21)
          (compiler-live-i64-ty))
        (ir-spmd-call-arg-cons
          (IrSpmdCallArg
            (IrSpmdValueVarying)
            (CompilerIrValue.Var 22)
            (compiler-live-i64-ty))
          IrSpmdCallArgNil))]
    [instr : CompilerIrInstr
      (ir-instr-spmd-call
        "helper"
        (IrSpmdBackendAvx512)
        8
        (CompilerIrValue.Var 20)
        args
        (IrSpmdCallResultValue 6 (IrSpmdValueVarying) (compiler-live-i64-ty)))]
    (and
      (compiler-live-set-eq?
        (compiler-live-instr-uses instr)
        (compiler-live-set3 20 21 22))
      (compiler-live-set-eq?
        (compiler-live-instr-defs instr)
        (compiler-live-set1 6)))))

(define (main) : i64
  (let
    [base : i64 (compiler-live-self-test)]
    (if (and (= base 42) (compiler-live-smoke-spmd-call-use-def-ok?))
      42
      1)))