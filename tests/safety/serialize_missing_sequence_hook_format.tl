(defenum Value
  (ValueObject FieldList))

(defstruct FieldList
  (items (Array Value)))

(defmacro (object-empty) : FieldList
  `(serialize_missing_sequence_hook_format.FieldList (make-array Value 0)))

(defmacro (object-field [_name : Expr] [_value : Expr] [rest : Expr]) : FieldList
  rest)

(defmacro (object-finish [fields : Expr]) : Value
  `(serialize_missing_sequence_hook_format.ValueObject ,fields))

(defmacro (expect-object [_value : Expr] [_type-name : Expr] [_err-ctor : Expr]) : unit
  `unit)

(defmacro (extra-decls [_T : type]) : Decls
  `(begin))
