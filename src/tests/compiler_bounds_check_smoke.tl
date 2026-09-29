;; compiler_bounds_check_smoke.tl - Optimizer/backend smoke for explicit bounds checks.
;;
;; Builds an IR program with two identical bounds checks in one block, runs the
;; optimizer, emits assembly, and requires exactly one OOB trap reference. The
;; backend no longer owns the `tl_oob_abort` body; executable driver paths link
;; it from the runtime prelude. The function is not an entry point (it takes
;; parameters), so the program emits as library code with no entry (#7071).
(import compiler_backend)
(import compiler_optimize)
(import compiler_ir_types as ir)

(define (compiler-bounds-check-smoke-instr-seq-prepend
  [instr : ir.CompilerIrInstr]
  [rest : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
  (let
    [builder : ir.CompilerIrInstrBuilder
      (ir.compiler-ir-instr-builder-with-capacity (+ rest.len 1))]
    (begin
      (ir.compiler-ir-instr-builder-push! (&mut builder) instr)
      (ir.compiler-ir-instr-builder-append-seq-range!
        (&mut builder)
        rest
        0
        rest.len)
      (ir.compiler-ir-instr-builder-to-seq builder))))

(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)

(define (bounds-check-smoke-program) : ir.CompilerIrProgram
  (ir.CompilerIrProgram.Program
    (ir.compiler-ir-global-seq-empty)
    (ir.compiler-ir-function-seq-prepend
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-label "main")
        (ir.compiler-ir-param-seq-prepend
          (ir.CompilerIrParam.Param "index" (ast.AstType.I64) 0)
          (ir.compiler-ir-param-seq-prepend
            (ir.CompilerIrParam.Param "length" (ast.AstType.I64) 1)
            (ir.compiler-ir-param-seq-empty)))
        (ast.AstType.I64)
        4
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "entry")
            (compiler-bounds-check-smoke-instr-seq-prepend
              (ir.CompilerIrInstr.BoundsCheck
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.Var 1)
                (ir.compiler-ir-label "bounds_ok.0"))
              (compiler-bounds-check-smoke-instr-seq-prepend
                (ir.CompilerIrInstr.BoundsCheck
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 1)
                  (ir.compiler-ir-label "bounds_ok.1"))
                (compiler-bounds-check-smoke-instr-seq-prepend
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 42)))
                  (ir.compiler-ir-instr-seq-empty)))))
          (ir.CompilerIrBlockList.Nil))
        ir.CompilerIrFunctionAbi.Ordinary)
      (ir.compiler-ir-function-seq-empty))
    (ir.compiler-ir-extern-seq-empty)))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match (compiler_backend.compiler-backend-emit-program-target-with-mode
      (match (compiler_optimize.optimize-program-with-spans-and-level
        (bounds-check-smoke-program)
        (ir.compiler-source-spans-empty)
        2)
        [(compiler_optimize.CompilerOptimizedProgram.Program optimized _)
          optimized])
      (compiler_backend.CompilerBackendTarget.Linux)
      (compiler_backend.CompilerBackendMode.Scalar)
      (ir.compiler-source-spans-empty)
      false)
      [(compiler_backend.ResultCompilerBackend.Ok asm)
        (let
          [symbol-count : i64
            (compiler_backend.compiler-backend-string-count asm "tl_oob_abort")]
          [defines-abort : bool
            (compiler_backend.compiler-backend-string-contains?
              asm
              "tl_oob_abort:\n")]
          (if (not (= symbol-count 1))
            1
            (if defines-abort
              2
              42)))]
      [(compiler_backend.ResultCompilerBackend.Err _) 2])))