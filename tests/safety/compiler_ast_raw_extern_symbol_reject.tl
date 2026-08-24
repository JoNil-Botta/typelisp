;; Raw integers include structural keys and missing sentinels, so they cannot
;; enter the renderable linker-symbol lane without checked classification.
(import compiler_ast_types as ast)

(define (main) : i64
  (let
    [raw : i64 -1]
    [metadata : ast.AstExternMetadata
      (ast.AstExternMetadata.Metadata
        (ast.AstExternAbi.C)
        raw
        (ast.ast-extern-link-input-list-new)
        0
        ast.AstImportedSpmdMetadata.No)]
    0))