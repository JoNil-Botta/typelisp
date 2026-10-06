(import compiler_ast_types as ast)

(define (main) : i64
  (let
    [ty : ast.AstType (I64)]
    (match ty
      [(I64) 0]
      [_ 1])))