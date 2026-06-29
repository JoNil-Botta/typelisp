(module serialize_missing_sequence_hook_format)

(defenum Value
  (ValueObject FieldList))

(defenum FieldList
  (FieldNil)
  (FieldCons Value (Box FieldList)))

(defmacro (object-empty) : FieldList
  `serialize_missing_sequence_hook_format.FieldNil)

(defmacro (object-field [_name : Expr] [value : Expr] [rest : Expr]) : FieldList
  `(serialize_missing_sequence_hook_format.FieldCons ,value (box ,rest)))

(defmacro (object-finish [fields : Expr]) : Value
  `(serialize_missing_sequence_hook_format.ValueObject ,fields))

(defmacro (expect-object [_value : Expr] [_type-name : Expr] [_err-ctor : Expr]) : unit
  `unit)

(defmacro (extra-decls [_T : type]) : Decls
  `(begin))
