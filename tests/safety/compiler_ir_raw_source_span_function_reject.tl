;; Function identities in instruction source-span keys are renderable IR
;; symbols. Raw integers also carry function-local indexes and structural or
;; missing identities, so callers must classify the function before insertion.
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)

(define (main) : i64
  (let
    [raw-function : i64 17]
    [instr : ir.CompilerIrInstr
      (ir.CompilerIrInstr.Mov 1 (ir.CompilerIrValue.I64 0) (ast.AstType.I64))]
    [spans : ir.CompilerSourceSpans
      (ir.compiler-source-spans-insert-instr
        (ir.compiler-source-spans-empty)
        raw-function
        (ir.compiler-ir-global-shared-view instr)
        (ast.ast-source-span 1 1 1 1))]
    (begin
      spans
      0)))