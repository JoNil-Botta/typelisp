;; Cleanup function names are mixed syntax identities. Raw integers also carry
;; missing sentinels and unrelated structural keys, so construction must use an
;; explicitly classified InternSyntaxId.
(import compiler_ast_types as ast)

(define (main) : i64
  (let
    [raw : i64 -1]
    [cleanup : ast.AstStructCleanup (ast.AstStructCleanup.Fn raw)]
    0))