;; A macro's quoted `(CFunc ...)` signature names this module's nominal type
;; (#10004 C43).
(module macro_cfunc_type_hygiene_dep)

(defstruct Handle
  (fd i64))

(extern handle-ptr (:symbol "c43_handle_ptr") : (CFunc non-null (-> Handle i64)))

(defmacro (handle-call [fp : Expr] [value : Expr]) : Expr
  `(let
    [f : (CFunc non-null (-> Handle i64)) ,fp]
    (f ,value)))