(module serialize_bad_object_finish_hook_format)

(defenum Value
  (ValueText String))

(defenum FieldList
  (FieldNil)
  (FieldCons Value (Box FieldList)))

(defmacro (encode-string [value : String]) : Value
  `(serialize_bad_object_finish_hook_format.ValueText ,value))

(defmacro (decode-string [_value : Expr] [_err-ctor : Expr]) : Expr
  `"")

(defmacro (object-empty) : FieldList
  `serialize_bad_object_finish_hook_format.FieldNil)

(defmacro (object-field [_name : Expr] [value : Expr] [rest : Expr]) : FieldList
  `(serialize_bad_object_finish_hook_format.FieldCons ,value (box ,rest)))

(defmacro (object-finish [_fields : Expr]) : i64
  `0)

(defmacro (expect-object [_value : Expr] [_type-name : Expr] [_err-ctor : Expr]) : unit
  `unit)

(defmacro (field-value [_object : Expr] [_name : Expr] [_err-ctor : Expr]) : Expr
  `(serialize_bad_object_finish_hook_format.ValueText ""))

(defmacro (extra-decls [_T : type]) : Decls
  `(begin))