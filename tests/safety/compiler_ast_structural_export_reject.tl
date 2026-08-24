;; Export/link metadata accepts only renderable names. A mixed structural
;; syntax identity must be explicitly reduced to its source spelling first.
(import compiler_ast_types as ast)
(import compiler_intern as ci)

(define (main) : i64
  (let
    [structural : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw 999999999999999)]
    (begin
      (ast.ast-fn-export-id structural)
      0)))