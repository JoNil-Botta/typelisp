;; Expression binding-clause names can carry source, generated, and structural
;; syntax identities. Raw integers must be classified before AST construction.
(import compiler_ast_types as ast)

(define (main) : i64
  (let
    [raw : i64 0]
    [clause : ast.AstExprBindingClause
      (ast.ast-expr-binding-clause-id
        raw
        false
        0
        0
        (ast.AstType.Var -3)
        (ast.ast-source-span 0 0 0 0))]
    0))