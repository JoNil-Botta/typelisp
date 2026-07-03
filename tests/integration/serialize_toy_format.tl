(module serialize_toy_format)

(import stdlib.string)

(defenum Value
  (Bool bool)
  (Int i64)
  (Float f64)
  (Text String)
  (Object (Box FieldList))
  (Sequence (Box ValueList)))

(defenum FieldList
  (FieldNil)
  (FieldCons String Value (Box FieldList)))

(defenum ValueList
  (ValueNil)
  (ValueCons Value (Box ValueList)))

(defenum Lookup
  (Found Value)
  (Missing))

(define (field-list-get [fields : FieldList] [name : String]) : Lookup
  (match fields
    [FieldNil (Missing)]
    [(FieldCons key value rest)
      (if (string.eq key name)
        (Found value)
        (field-list-get (box-get rest) name))]))

(define (value-list-count [items : ValueList]) : i64
  (match items
    [(ValueNil) 0]
    [(ValueCons _ rest) (+ 1 (value-list-count (box-get rest)))]))

(define (value-list-get [items : ValueList] [index : i64]) : Lookup
  (if (< index 0)
    (Missing)
    (match items
      [(ValueNil) (Missing)]
      [(ValueCons head rest)
        (if (= index 0)
          (Found head)
          (value-list-get (box-get rest) (- index 1)))])))

(defmacro (encode-bool [value : bool]) : Value
  `(serialize_toy_format.Bool ,value))

(defmacro (decode-bool [value : Expr] [err-ctor : Expr]) : Expr
  `(match ,value
    [(serialize_toy_format.Bool parsed) parsed]
    [_ (return (,err-ctor "toy format: expected bool"))]))

(defmacro (encode-int [_T : type] [value : Expr]) : Value
  `(serialize_toy_format.Int (cast ,value : i64)))

(defmacro (decode-int [_T : type] [value : Expr] [err-ctor : Expr]) : Expr
  `(match ,value
    [(serialize_toy_format.Int parsed) (cast parsed : ,_T)]
    [_ (return (,err-ctor "toy format: expected int"))]))

(defmacro (encode-float [_T : type] [value : Expr]) : Value
  `(serialize_toy_format.Float (cast ,value : f64)))

(defmacro (decode-float [_T : type] [value : Expr] [err-ctor : Expr]) : Expr
  `(match ,value
    [(serialize_toy_format.Float parsed) (cast parsed : ,_T)]
    [_ (return (,err-ctor "toy format: expected float"))]))

(defmacro (encode-string [value : String]) : Value
  `(serialize_toy_format.Text ,value))

(defmacro (decode-string [value : Expr] [err-ctor : Expr]) : Expr
  `(match ,value
    [(serialize_toy_format.Text parsed) parsed]
    [_ (return (,err-ctor "toy format: expected string"))]))

(defmacro (object-empty) : FieldList
  `serialize_toy_format.FieldNil)

(defmacro (object-field [name : Expr] [value : Expr] [rest : Expr]) : FieldList
  `(serialize_toy_format.FieldCons ,name ,value (box ,rest)))

(defmacro (object-finish [fields : Expr]) : Value
  `(serialize_toy_format.Object (box ,fields)))

(defmacro (expect-object [value : Expr] [_type-name : Expr] [err-ctor : Expr]) : unit
  `(match ,value
    [(serialize_toy_format.Object _) unit]
    [_ (return (,err-ctor "toy format: expected object"))]))

(defmacro (field-value [object : Expr] [name : Expr] [err-ctor : Expr]) : Expr
  `(match ,object
    [(serialize_toy_format.Object fields)
      (match (serialize_toy_format.field-list-get (box-get fields) ,name)
        [(serialize_toy_format.Found found) found]
        [(serialize_toy_format.Missing)
          (return (,err-ctor "toy format: missing field"))])]
    [_ (return (,err-ctor "toy format: expected object"))]))

(defmacro (sequence-empty) : ValueList
  `ValueNil)

(defmacro (sequence-element [_index : Expr] [value : Expr] [rest : Expr]) : ValueList
  `(serialize_toy_format.ValueCons ,value (box ,rest)))

(defmacro (sequence-finish [items : Expr]) : Value
  `(serialize_toy_format.Sequence (box ,items)))

(defmacro (sequence-length [value : Expr] [err-ctor : Expr]) : i64
  `(match ,value
    [(serialize_toy_format.Sequence items)
      (serialize_toy_format.value-list-count (box-get items))]
    [_ (return (,err-ctor "toy format: expected sequence"))]))

(defmacro (sequence-element-value
  [value : Expr]
  [index : Expr]
  [err-ctor : Expr]) : Expr
  `(match ,value
    [(serialize_toy_format.Sequence items)
      (match (serialize_toy_format.value-list-get (box-get items) ,index)
        [(serialize_toy_format.Found found) found]
        [(serialize_toy_format.Missing)
          (return (,err-ctor "toy format: missing sequence element"))])]
    [_ (return (,err-ctor "toy format: expected sequence"))]))

(defmacro (extra-decls [_T : type]) : Decls
  `(begin))