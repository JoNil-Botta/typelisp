;; compiler_bounds_check_smoke.tl - Optimizer/backend smoke for explicit bounds checks.
;;
;; Builds an IR program with two identical bounds checks in one block, runs the
;; optimizer, emits assembly, and requires exactly one OOB trap reference. The
;; backend no longer owns the `tl_oob_abort` body; executable driver paths link
;; it from the runtime prelude.
(import "../compiler_backend.tl")
(import "../compiler_optimize.tl")

(define (bounds-check-smoke-program) : CompilerIrProgram
  (CompilerIrProgram.Program
    CompilerIrGlobalList.Nil
    (compiler-ir-function-cons
      (CompilerIrFunction.Function
        "main"
        (compiler-ir-param-cons
          (CompilerIrParam.Param "index" (AstType.I64) 0)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "length" (AstType.I64) 1)
            IrParamNil))
        (AstType.I64)
        4
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (CompilerIrInstr.BoundsCheck
                (CompilerIrValue.Var 0)
                (CompilerIrValue.Var 1)
                "bounds_ok.0")
              (compiler-ir-instr-cons
                (CompilerIrInstr.BoundsCheck
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Var 1)
                  "bounds_ok.1")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 42)))
                  (CompilerIrInstrList.Nil)))))
          (CompilerIrBlockList.Nil)))
      (CompilerIrFunctionList.Nil))
    CompilerIrExternList.Nil))

(define (main) : i64
  (match (compiler-backend-emit-program-linux
    (optimize-program-with-level (bounds-check-smoke-program) 2))
    [(ResultCompilerBackend.Ok asm)
      (let
        [symbol-count : i64 (compiler-backend-string-count asm "tl_oob_abort")]
        [defines-abort : bool
          (compiler-backend-string-contains? asm "tl_oob_abort:\n")]
        (if (not (= symbol-count 1))
          1
          (if defines-abort
            2
            42)))]
    [(ResultCompilerBackend.Err _) 2]))