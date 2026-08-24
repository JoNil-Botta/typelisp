;; compiler_bounds_check_smoke.tl - Optimizer/backend smoke for explicit bounds checks.
;;
;; Builds an IR program with two identical bounds checks in one block, runs the
;; optimizer, emits assembly, and requires exactly one OOB trap reference. The
;; backend no longer owns the `tl_oob_abort` body; executable driver paths link
;; it from the runtime prelude.
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
    (ir.compiler-ir-function-cons
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-label "main")
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "index" (ast.AstType.I64) 0)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "length" (ast.AstType.I64) 1)
            ir.CompilerIrParamList.Nil))
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
          (ir.CompilerIrBlockList.Nil)))
      (ir.CompilerIrFunctionList.Nil))
    (ir.compiler-ir-extern-seq-empty)))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match (compiler_backend.compiler-backend-emit-program-linux
      (compiler_optimize.optimize-program-with-level
        (bounds-check-smoke-program)
        2))
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