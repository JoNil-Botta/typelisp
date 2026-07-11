(defenum Value
  (ValueNull))

(defmacro (object-finish [_fields : Expr]) : Value
  `serialize_missing_extra_decls_hook_format.ValueNull)

(defmacro (expect-object [_value : Expr] [_type-name : Expr] [_err-ctor : Expr]) : unit
  `unit)