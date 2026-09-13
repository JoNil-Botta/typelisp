;; Decls and Module cfg output share the canonical import resolver, including
;; unused imports whose cfg head is constructed during expansion.
(defmacro (configured-missing-decls) : Decls
  (let
    [cfg-head : Expr (expr-var "cfg")]
    `(begin
      (,cfg-head (any linux windows) (import nonexistent_cfg_active_dependency)))))

(configured-missing-decls)

(define (main) : i64
  42)