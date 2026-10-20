;; Versioned native-link wire values. Only the manifest/profile codec consumes
;; this strategy; stdlib.serialize owns the typed aggregate traversal.
(import stdlib.comptime)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.vector)
(import stdlib.sort)

(defenum Value
  (Null)
  (Boolean bool)
  (Signed i64)
  (Unsigned u64)
  (ByteString String)
  (Sequence (Box ValueSeq))
  (Record (Box FieldSeq)))

(defstruct ValueSeq
  (slots (__tl_dyn-array Value))
  (len i64))

(defstruct Field
  (key String)
  (value Value))

(defstruct FieldSeq
  (slots (__tl_dyn-array Field))
  (len i64))

(defenum ValueLinks
  (NoValues)
  (MoreValues Value (Box ValueList)))

(defstruct ValueList
  (len i64)
  (links ValueLinks))

(defenum FieldLinks
  (NoFields)
  (MoreFields Field (Box FieldList)))

(defstruct FieldList
  (len i64)
  (links FieldLinks))

(import (vector.vector Field core) as fields)
(import (vector.vector String) as keys)
(import (sort.vec String) as key_sort)

(define (key-less? [a : (& a str)] [b : (& b str)]) : bool
  (let
    [i : i64 0]
    [an : i64 (string.string-length a)]
    [bn : i64 (string.string-length b)]
    (while (and (< i an) (< i bn))
      (let
        [ac : i64 (cast (string.string-ref a i) : i64)]
        [bc : i64 (cast (string.string-ref b i) : i64)]
        (when (< ac bc) (return true))
        (when (> ac bc) (return false)))
      (set! i (+ i 1)))
    (< an bn)))

(define (field-less? [a : Field] [b : Field]) : bool
  (key-less? (& a.key) (& b.key)))

(define (prepend-value [value : Value] [rest : ValueList]) : ValueList
  (ValueList (+ rest.len 1) (MoreValues value (box rest))))

(define (finish-values [values : ValueList]) : Value
  (let
    [count : i64 values.len]
    [out : (__tl_dyn-array Value) (__tl_make-array Value count)]
    [i : i64 0]
    [remaining : ValueList values]
    (while (< i count)
      (match remaining.links
        [(MoreValues head tail)
          (set! (array-ref out i) head)
          (set! remaining (deref tail))]
        [_ unit])
      (set! i (+ i 1)))
    (Sequence (box (ValueSeq out count)))))

(define (prepend-field [field : Field] [rest : FieldList]) : FieldList
  (FieldList (+ rest.len 1) (MoreFields field (box rest))))

(define (finish-fields [values : FieldList]) : Value
  (let
    [out : fields.Vec (fields.new)]
    [names : keys.Vec (keys.new)]
    [n : i64 values.len]
    [remaining : FieldList values]
    [i : i64 0]
    (while (< i n)
      (match remaining.links
        [(MoreFields head tail)
          (keys.push! names (clone head.key))
          (fields.push! out head)
          (set! remaining (deref tail))]
        [_ unit])
      (set! i (+ i 1)))
    (key_sort.sort! (&mut names) sort.string-less?)
    (let
      [count : i64 (fields.len (& out))]
      [data : (__tl_dyn-array Field) (__tl_make-array Field count)]
      [slots (fields.slots (& out))]
      (for [i (stdlib.iterator.range 0 count)]
        (let
          [name : String (keys.get (& names) i "")]
          (for [j (stdlib.iterator.range 0 count)]
            (when
              (string.eq (& (array-ref slots j).key) (& name))
              (set! (array-ref data i) (clone (array-ref slots j)))))))
      (Record (box (FieldSeq data count))))))

(defenum Lookup
  (Found Value)
  (Missing))

(define (field-value-owned [object : Value] [key : String]) : Lookup
  (match object
    [(Record boxed)
      (let
        [items : FieldSeq (deref boxed)]
        [lo : i64 0]
        [hi : i64 items.len]
        (while (< lo hi)
          (let
            [mid : i64 (+ lo (/ (- hi lo) 2))]
            (if (key-less? (& (array-ref items.slots mid).key) (& key))
              (set! lo (+ mid 1))
              (set! hi mid))))
        (if (and
          (< lo items.len)
          (string.eq (& (array-ref items.slots lo).key) (& key)))
          (Found (clone (array-ref items.slots lo).value))
          (Missing)))]
    [_ (Missing)]))

(define (sequence-value-owned [value : Value] [index : i64]) : Lookup
  (match value
    [(Sequence boxed)
      (let
        [items : ValueSeq (deref boxed)]
        (if (and (>= index 0) (< index items.len))
          (Found (clone (array-ref items.slots index)))
          (Missing)))]
    [_ (Missing)]))

(defenum IntegerResult
  (Integer u64)
  (BadInteger))

(define (integer-value [value : Value] [signed : bool] [bits : i64]) : IntegerResult
  (let
    [minimum : i64
      (match bits
        [8 -128]
        [16 -32768]
        [32 -2147483648]
        [_ -9223372036854775808])]
    (match value
      [(Signed number)
        (if (and signed (< number 0) (>= number minimum))
          (Integer (cast number : u64))
          (BadInteger))]
      [(Unsigned number)
        (let
          [maximum : u64
            (if signed
              (if (= bits 64)
                (cast 9223372036854775807 : u64)
                (- (shl (cast 1 : u64) (- bits 1)) (cast 1 : u64)))
              (if (= bits 64)
                (cast -1 : u64)
                (- (shl (cast 1 : u64) bits) (cast 1 : u64))))]
          (if (<= number maximum)
            (Integer number)
            (BadInteger)))]
      [_ (BadInteger)])))

(defmacro (encode-bool [value : bool]) : Value
  `(native_link_manifest_wire.Boolean ,value))

(defmacro (decode-bool [value : comptime.Expr] [error : comptime.Expr]) : comptime.Expr
  `(match ,value
    [(native_link_manifest_wire.Boolean found) found]
    [_ (return (,error "native link wire: expected bool"))]))

(defmacro (encode-int [T : type] [value : comptime.Expr]) : Value
  (match (type-kind T)
    [(or "i8" "i16" "i32" "i64")
      `(let
        [number : i64 (cast ,value : i64)]
        (if (< number 0)
          (native_link_manifest_wire.Signed number)
          (native_link_manifest_wire.Unsigned (cast number : u64))))]
    [(or "u8" "u16" "u32" "u64")
      `(native_link_manifest_wire.Unsigned (cast ,value : u64))]
    [_ (comptime.comptime-error "native link wire: unsupported scalar type")]))

(defmacro (decode-int
  [T : type]
  [value : comptime.Expr]
  [error : comptime.Expr]) : comptime.Expr
  (let
    [signed : bool
      (match (type-kind T)
        [(or "i8" "i16" "i32" "i64") true]
        [_ false])]
    [bits : i64
      (match (type-kind T)
        [(or "i8" "u8") 8]
        [(or "i16" "u16") 16]
        [(or "i32" "u32") 32]
        [_ 64])]
    `(match (native_link_manifest_wire.integer-value
      ,value
      ,(if signed
        `true
        `false)
      ,(comptime.expr-int bits))
      [(native_link_manifest_wire.Integer number) (cast number : ,T)]
      [_ (return (,error "native link wire: integer out of range"))])))

(defmacro (encode-float [_T : type] [_value : comptime.Expr]) : Value
  (comptime.comptime-error
    "native link wire: floating-point values are not in v1"))

(defmacro (decode-float
  [_T : type]
  [_value : comptime.Expr]
  [_error : comptime.Expr]) : comptime.Expr
  (comptime.comptime-error
    "native link wire: floating-point values are not in v1"))

(defmacro (encode-string [value : String]) : Value
  `(native_link_manifest_wire.ByteString ,value))

(defmacro (decode-string [value : comptime.Expr] [error : comptime.Expr]) : comptime.Expr
  `(match ,value
    [(native_link_manifest_wire.ByteString found) found]
    [_ (return (,error "native link wire: expected byte string"))]))

(defmacro (object-empty) : FieldList
  `(native_link_manifest_wire.FieldList 0 (native_link_manifest_wire.NoFields)))

(defmacro (object-field
  [name : comptime.Expr]
  [value : comptime.Expr]
  [rest : comptime.Expr]) : FieldList
  `(native_link_manifest_wire.prepend-field
    (native_link_manifest_wire.Field ,name ,value)
    ,rest))

(defmacro (object-finish [fields : comptime.Expr]) : Value
  `(native_link_manifest_wire.finish-fields ,fields))

(defmacro (expect-object
  [value : comptime.Expr]
  [_type-name : comptime.Expr]
  [error : comptime.Expr]) : unit
  `(match ,value
    [(native_link_manifest_wire.Record _) unit]
    [_ (return (,error "native link wire: expected record"))]))

(defmacro (field-value
  [object : comptime.Expr]
  [name : comptime.Expr]
  [error : comptime.Expr]) : comptime.Expr
  `(match (native_link_manifest_wire.field-value-owned ,object ,name)
    [(native_link_manifest_wire.Found found) found]
    [_ (return (,error "native link wire: missing field"))]))

(defmacro (sequence-empty) : ValueList
  `(native_link_manifest_wire.ValueList 0 (native_link_manifest_wire.NoValues)))

(defmacro (sequence-element
  [_index : comptime.Expr]
  [value : comptime.Expr]
  [rest : comptime.Expr]) : ValueList
  `(native_link_manifest_wire.prepend-value ,value ,rest))

(defmacro (sequence-finish [items : comptime.Expr]) : Value
  `(native_link_manifest_wire.finish-values ,items))

(defmacro (sequence-length [value : comptime.Expr] [error : comptime.Expr]) : i64
  `(match ,value
    [(native_link_manifest_wire.Sequence items) (deref items).len]
    [_ (return (,error "native link wire: expected sequence"))]))

(defmacro (sequence-element-value
  [value : comptime.Expr]
  [index : comptime.Expr]
  [error : comptime.Expr]) : comptime.Expr
  `(match (native_link_manifest_wire.sequence-value-owned ,value ,index)
    [(native_link_manifest_wire.Found found) found]
    [_ (return (,error "native link wire: missing sequence item"))]))

(defmacro (extra-decls [_T : type]) : Decls
  `(begin))