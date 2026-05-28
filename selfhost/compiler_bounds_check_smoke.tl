;; compiler_bounds_check_smoke.tl - Optimizer/backend smoke for explicit bounds checks.
;;
;; Builds an IR program with two identical bounds checks in one block, runs the
;; optimizer, emits assembly, and requires exactly one OOB trap call.
(import "compiler_backend.tl")

(import "compiler_optimize.tl")

(define (bounds-check-smoke-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        4
        (IrBlockCons
          (IrBlock
            "entry"
            (IrInstrCons
              (IrInstrMov 0 (IrValueI64 0) (AstTyU64))
              (IrInstrCons
                (IrInstrMov 1 (IrValueI64 1) (AstTyU64))
                (IrInstrCons
                  (IrInstrBoundsCheck
                    (IrValueVar 0)
                    (IrValueVar 1)
                    "bounds_ok.0")
                  (IrInstrCons
                    (IrInstrBoundsCheck
                      (IrValueVar 0)
                      (IrValueVar 1)
                      "bounds_ok.1")
                    (IrInstrCons
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
