;; Field names are mixed syntax identities. Raw integers also carry missing
;; sentinels and unrelated structural keys, so AST construction must use an
;; explicitly classified InternSyntaxId.
(import compiler_ast_types as ast)

(define (main) : i64
  (let
    [raw : i64 -1]
    [field : ast.AstFieldDef
      (ast.AstFieldDef.Def raw (ast.AstType.I64) ast.AstFieldCleanup.No)]
    0))