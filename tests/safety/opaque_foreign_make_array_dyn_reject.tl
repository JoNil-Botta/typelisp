;; A macro-supplied element type reaches __tl_make-array's element check, which
;; rejects a foreign opaque type (#6999).
(import opaque_dep)

(defmacro (opaque-items) : Expr
  `(__tl_make-array opaque_dep.Connection 2))

(define (main) : i64
  (let
    [_items (opaque-items)]
    0))