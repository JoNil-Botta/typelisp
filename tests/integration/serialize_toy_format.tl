(import stdlib.array)
(import stdlib.string)

(defenum Value
  (Bool bool)
  (Int i64)
  (Float f64)
  (Text String)
  (Object (Box FieldList))
  (Sequence (Box ValueList)))

(defstruct Field
  (name String)
  (value Value))

(defstruct FieldList
  (items (__tl_dyn-array Field)))

(defstruct ValueList
  (items (__tl_dyn-array Value)))

(defenum Lookup
  (Found Value)
  (Missing))

(define (field-list-empty) : FieldList
  (FieldList (array.make-array Field 0)))

(define (field-list-copy-from
  [source : (__tl_dyn-array Field)]
  [target : (__tl_dyn-array Field)]
  [index : i64]) : unit
  (if (= index (array-length source))
    unit
    (begin
      (array-set! target (+ index 1) (array-ref source index))
      (field-list-copy-from source target (+ index 1)))))

(define (field-list-prepend [name : String] [value : Value] [rest : FieldList]) : FieldList
  (let
    [source : (__tl_dyn-array Field) (struct-get rest items)]
    [target : (__tl_dyn-array Field)
      (array.make-array Field (+ (array-length source) 1))]
    (begin
      (array-set! target 0 (Field name value))
      (field-list-copy-from source target 0)
      (FieldList target))))

(define (field-list-get-from
  [items : (__tl_dyn-array Field)]
  [name : String]
  [index : i64]) : Lookup
  (if (= index (array-length items))
    (Missing)
    (let
      [field : Field (array-ref items index)]
      (if (string.eq (struct-get field name) name)
        (Found (struct-get field value))
        (field-list-get-from items name (+ index 1))))))

(define (field-list-get [fields : FieldList] [name : String]) : Lookup
  (field-list-get-from (struct-get fields items) name 0))

(define (value-list-count [items : ValueList]) : i64
  (array-length (struct-get items items)))

(define (value-list-get [items : ValueList] [index : i64]) : Lookup
  (if (or (< index 0) (>= index (value-list-count items)))
    (Missing)
    (Found (array-ref (struct-get items items) index))))

(define (value-list-empty) : ValueList
  (ValueList (array.make-array Value 0)))

(define (value-list-copy-from
  [source : (__tl_dyn-array Value)]
  [target : (__tl_dyn-array Value)]
  [index : i64]) : unit
  (if (= index (array-length source))
    unit
    (begin
      (array-set! target (+ index 1) (array-ref source index))
      (value-list-copy-from source target (+ index 1)))))

(define (value-list-prepend [value : Value] [rest : ValueList]) : ValueList
  (let
    [source : (__tl_dyn-array Value) (struct-get rest items)]
    [target : (__tl_dyn-array Value)
      (array.make-array Value (+ (array-length source) 1))]
    (begin
      (array-set! target 0 value)
      (value-list-copy-from source target 0)
      (ValueList target))))

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
  `(serialize_toy_format.field-list-empty))

(defmacro (object-field [name : Expr] [value : Expr] [rest : Expr]) : FieldList
  `(serialize_toy_format.field-list-prepend ,name ,value ,rest))

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
  `(serialize_toy_format.value-list-empty))

(defmacro (sequence-element [_index : Expr] [value : Expr] [rest : Expr]) : ValueList
  `(serialize_toy_format.value-list-prepend ,value ,rest))

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