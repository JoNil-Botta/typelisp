;; Enabling a generated cfg must expose its import to the canonical resolver.
(defmacro (configured-missing-module) : Module
  (let
    [cfg-head : Expr (expr-var "cfg")]
    `(begin
      (module generated.cfg_missing)
      (,cfg-head (any linux windows) (import nonexistent_cfg_active_dependency)))))

(import (configured-missing-module) as configured)

(define (main) : i64
  42)