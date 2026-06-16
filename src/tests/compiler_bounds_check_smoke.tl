;; compiler_bounds_check_smoke.tl - Optimizer/backend smoke for explicit bounds checks.
;;
;; Builds an IR program with two identical bounds checks in one block, runs the
;; optimizer, emits assembly, and requires exactly one OOB trap reference. The
;; backend no longer owns the `tl_oob_abort` body; executable driver paths link
;; it from the runtime prelude.
(import "compiler_backend.tl")
(import "compiler_optimize.tl")

(define (bounds-check-smoke-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "main"
        (compiler-ir-param-cons
          (IrParam "index" (AstTyI64) 0)
          (compiler-ir-param-cons (IrParam "length" (AstTyI64) 1) IrParamNil))
        (AstTyI64)
        4
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
              (compiler-ir-instr-cons
                (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueI64 42)))
                  (IrInstrNil)))))
          (IrBlockNil)))
      (IrFunctionNil))
    IrExternNil))

(define (main) : i64
  (match (compiler-backend-emit-program
    (optimize-program-with-level (bounds-check-smoke-program) 2))
    [(OkCompilerBackend asm)
      (let
        [symbol-count : i64 (compiler-backend-string-count asm "tl_oob_abort")]
        [defines-abort : bool
          (compiler-backend-string-contains? asm "tl_oob_abort:\n")]
        (if (not (= symbol-count 1))
          1
          (if defines-abort
            2
            42)))]
    [(ErrCompilerBackend _) 2]))