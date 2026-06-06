;; compiler_bounds_check_smoke.tl - Optimizer/backend smoke for explicit bounds checks.
;;
;; Builds an IR program with two identical bounds checks in one block, runs the
;; optimizer, emits assembly, and requires exactly one OOB trap call.
(import "compiler_backend.tl")

(import "compiler_optimize.tl")

(define (bounds-check-smoke-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        4
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrMov 0 (IrValueI64 0) (AstTyU64))
              (compiler-ir-instr-cons
                (IrInstrMov 1 (IrValueI64 1) (AstTyU64))
                (compiler-ir-instr-cons
                  (IrInstrBoundsCheck
                    (IrValueVar 0)
                    (IrValueVar 1)
                    "bounds_ok.0")
                  (compiler-ir-instr-cons
                    (IrInstrBoundsCheck
                      (IrValueVar 0)
                      (IrValueVar 1)
                      "bounds_ok.1")
                    (compiler-ir-instr-cons
                      (IrInstrReturn (IrSomeValue (IrValueI64 42)))
                      (IrInstrNil)))))))
          (IrBlockNil)))
      (IrFunctionNil))
    IrExternNil))

(define (main) : i64
  (match (compiler-backend-emit-program
    (optimize-program-with-level (bounds-check-smoke-program) 2))
    [(OkCompilerBackend asm)
      (if (and
        (= (compiler-backend-string-count asm "    call tl_oob_abort\n") 1)
        (compiler-backend-string-contains? asm "tl_oob_abort:\n"))
        42
        1)]
    [(ErrCompilerBackend _) 2]))