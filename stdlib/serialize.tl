;# Format-generic struct serialization macros.
;#
;# `serialize` emits a generated module for a concrete type and a format
;# strategy module:
;#
;# ```lisp test=ignore name=serialize-strategy-sketch reason="sketch uses an application-provided format module"
;# (import stdlib.serialize)
;# (import my.format as fmt)
;# (import (serialize.serialize fmt Person) as person_ser)
;# ```
;#
;# The generated module exposes `Value`, `Result`, `Ok`, `Err`, `encode`,
;# `decode`, `is-ok?`, `value-or`, and `error-or`. The strategy module must
;# export a concrete `Value` type and these hook macros for the struct subset:
;# `encode-bool`, `decode-bool`, `encode-int`, `decode-int`, `encode-float`,
;# `decode-float`, `encode-string`, `decode-string`, `object-empty`,
;# `object-field`, `object-finish`, `expect-object`, `field-value`, and
;# `extra-decls`. `extra-decls` may emit format-specific helper aliases in the
;# generated module, or `(begin)` when the generic `encode` / `decode` API is
;# enough.
(module stdlib.serialize)

(import stdlib.comptime)

;: Emit the encoded value expression for one struct field.
(defmacro (serialize-encode-field
  [format : Module]
  [T : type]
  [index-expr : Expr]
  [value : Expr]) : Expr
  (match index-expr
    [(ExprInt index)
      (let
        [field-name : String (struct-field-name T index)]
        [field-type : Expr (struct-field-type T index)]
        [field-key : String (type-key field-type)]
        [field-kind : String (type-kind field-type)]
        [field-access : Expr (comptime.expr-struct-get value field-name)]
        (match field-key
          ["bool"
            (let
              [hook : Expr (comptime.module-hook format "encode-bool")]
              `(,hook ,field-access))]
          ["String"
            (let
              [hook : Expr (comptime.module-hook format "encode-string")]
              `(,hook ,field-access))]
          ["i64"
            (let
              [hook : Expr (comptime.module-hook format "encode-int")]
              `(,hook ,field-type ,field-access))]
          ["i32"
            (let
              [hook : Expr (comptime.module-hook format "encode-int")]
              `(,hook ,field-type ,field-access))]
          ["i16"
            (let
              [hook : Expr (comptime.module-hook format "encode-int")]
              `(,hook ,field-type ,field-access))]
          ["i8"
            (let
              [hook : Expr (comptime.module-hook format "encode-int")]
              `(,hook ,field-type ,field-access))]
          ["u64"
            (let
              [hook : Expr (comptime.module-hook format "encode-int")]
              `(,hook ,field-type ,field-access))]
          ["u32"
            (let
              [hook : Expr (comptime.module-hook format "encode-int")]
              `(,hook ,field-type ,field-access))]
          ["u16"
            (let
              [hook : Expr (comptime.module-hook format "encode-int")]
              `(,hook ,field-type ,field-access))]
          ["u8"
            (let
              [hook : Expr (comptime.module-hook format "encode-int")]
              `(,hook ,field-type ,field-access))]
          ["f64"
            (let
              [hook : Expr (comptime.module-hook format "encode-float")]
              `(,hook ,field-type ,field-access))]
          ["f32"
            (let
              [hook : Expr (comptime.module-hook format "encode-float")]
              `(,hook ,field-type ,field-access))]
          [_
            (match field-kind
              ["struct"
                (let
                  [nested-alias-text : String
                    (string-append
                      "__serialize_nested_"
                      (comptime.int->string index))]
                  [nested-encode : Expr
                    (comptime.expr-var
                      (string-append nested-alias-text ".encode"))]
                  `(,nested-encode ,field-access))]
              [_
                (comptime.comptime-error
                  (string-append
                    (string-append "serialize: unsupported field " field-name)
                    (string-append " type " field-key)))])]))]
    [_
      (comptime.comptime-error
        "serialize: field index must be an integer literal")]))

;: Emit the strategy-owned object field accumulator for struct fields.
(defmacro (serialize-encode-fields
  [format : Module]
  [T : type]
  [index-expr : Expr]
  [value : Expr]) : Expr
  (match index-expr
    [(ExprInt index)
      (if (>= index (struct-field-count T))
        (let
          [empty-hook : Expr (comptime.module-hook format "object-empty")]
          `(,empty-hook))
        (let
          [field-hook : Expr (comptime.module-hook format "object-field")]
          [field-name : String (struct-field-name T index)]
          [field-key-expr : Expr (comptime.expr-string field-name)]
          [next-index : Expr (comptime.expr-int (+ index 1))]
          [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
          `(,field-hook
            ,field-key-expr
            (stdlib.serialize.serialize-encode-field
              ,format-expr
              ,T
              ,(comptime.expr-int index)
              ,value)
            (stdlib.serialize.serialize-encode-fields
              ,format-expr
              ,T
              ,next-index
              ,value))))]
    [_
      (comptime.comptime-error
        "serialize: field accumulator index must be an integer literal")]))

;: Emit decode logic for one struct field.
(defmacro (serialize-decode-field
  [format : Module]
  [T : type]
  [index-expr : Expr]
  [value : Expr]
  [out : Expr]
  [err-ctor : Expr]) : Expr
  (match index-expr
    [(ExprInt index)
      (let
        [field-name : String (struct-field-name T index)]
        [field-type : Expr (struct-field-type T index)]
        [field-key : String (type-key field-type)]
        [field-kind : String (type-kind field-type)]
        [field-key-expr : Expr (comptime.expr-string field-name)]
        [field-value-hook : Expr (comptime.module-hook format "field-value")]
        (match field-key
          ["bool"
            (let
              [hook : Expr (comptime.module-hook format "decode-bool")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["String"
            (let
              [hook : Expr (comptime.module-hook format "decode-string")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["i64"
            (let
              [hook : Expr (comptime.module-hook format "decode-int")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["i32"
            (let
              [hook : Expr (comptime.module-hook format "decode-int")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["i16"
            (let
              [hook : Expr (comptime.module-hook format "decode-int")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["i8"
            (let
              [hook : Expr (comptime.module-hook format "decode-int")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["u64"
            (let
              [hook : Expr (comptime.module-hook format "decode-int")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["u32"
            (let
              [hook : Expr (comptime.module-hook format "decode-int")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["u16"
            (let
              [hook : Expr (comptime.module-hook format "decode-int")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["u8"
            (let
              [hook : Expr (comptime.module-hook format "decode-int")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["f64"
            (let
              [hook : Expr (comptime.module-hook format "decode-float")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          ["f32"
            (let
              [hook : Expr (comptime.module-hook format "decode-float")]
              [set-expr : Expr
                (comptime.expr-struct-set
                  out
                  field-name
                  `(,hook ,field-type __serialize_field ,err-ctor))]
              `(let
                [__serialize_field
                  (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                ,set-expr))]
          [_
            (match field-kind
              ["struct"
                (let
                  [nested-alias-text : String
                    (string-append
                      "__serialize_nested_"
                      (comptime.int->string index))]
                  [_nested-result-type : Expr
                    (comptime.expr-var
                      (string-append nested-alias-text ".Result"))]
                  [nested-decode : Expr
                    (comptime.expr-var
                      (string-append nested-alias-text ".decode"))]
                  [set-expr : Expr
                    (comptime.expr-struct-set out field-name `parsed)]
                  `(let
                    [__serialize_field
                      (,field-value-hook ,value ,field-key-expr ,err-ctor)]
                    [__serialize_nested_result : ,_nested-result-type
                      (,nested-decode __serialize_field)]
                    (match __serialize_nested_result
                      [(Ok parsed) ,set-expr]
                      [(Err err) (return (,err-ctor err))])))]
              [_
                (comptime.comptime-error
                  (string-append
                    (string-append "serialize: unsupported field " field-name)
                    (string-append " type " field-key)))])]))]
    [_
      (comptime.comptime-error
        "serialize: decode field index must be an integer literal")]))

;: Emit recursive decode logic for all struct fields.
(defmacro (serialize-decode-fields
  [format : Module]
  [T : type]
  [index-expr : Expr]
  [value : Expr]
  [out : Expr]
  [err-ctor : Expr]) : Expr
  (match index-expr
    [(ExprInt index)
      (if (>= index (struct-field-count T))
        `unit
        (let
          [next-index : Expr (comptime.expr-int (+ index 1))]
          [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
          `(begin
            (stdlib.serialize.serialize-decode-field
              ,format-expr
              ,T
              ,(comptime.expr-int index)
              ,value
              ,out
              ,err-ctor)
            (stdlib.serialize.serialize-decode-fields
              ,format-expr
              ,T
              ,next-index
              ,value
              ,out
              ,err-ctor))))]
    [_
      (comptime.comptime-error
        "serialize: decode fields index must be an integer literal")]))

;: Emit recursive generated serializer imports needed for nested struct fields.
(defmacro (serialize-nested-imports
  [format : Module]
  [T : type]
  [index-expr : Expr]) : Decls
  (match index-expr
    [(ExprInt index)
      (if (>= index (struct-field-count T))
        `(begin)
        (let
          [field-type : Expr (struct-field-type T index)]
          [field-kind : String (type-kind field-type)]
          [next-index : Expr (comptime.expr-int (+ index 1))]
          [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
          (match field-kind
            ["struct"
              (let
                [nested-alias : Expr
                  (comptime.expr-var
                    (string-append
                      "__serialize_nested_"
                      (comptime.int->string index)))]
                `(begin
                  (stdlib.serialize.serialize-nested-imports
                    ,format-expr
                    ,T
                    ,next-index)
                  (import (stdlib.serialize.serialize ,format-expr ,field-type) as ,nested-alias)))]
            [_
              `(stdlib.serialize.serialize-nested-imports
                ,format-expr
                ,T
                ,next-index)])))]
    [_
      (comptime.comptime-error
        "serialize: nested import index must be an integer literal")]))

;: Emit generic encode/decode helpers for struct type `T` and strategy `format`.
(defmacro (serialize [format : Module] [T : type]) : Module
  (match (type-kind T)
    ["struct"
      (let
        [format-name : String (comptime.module-name format)]
        [module-name-text : String
          (string-append
            (string-append
              (string-append "stdlib.serialize.generated." format-name)
              ".")
            (type-key T))]
        [module-name-expr : Expr (comptime.expr-var module-name-text)]
        [format-module-expr : Expr (comptime.expr-var format-name)]
        [value-type : Expr (comptime.expr-var "__serialize_format.Value")]
        [ok-ctor : Expr
          (comptime.expr-var (string-append module-name-text ".Ok"))]
        [err-ctor : Expr
          (comptime.expr-var (string-append module-name-text ".Err"))]
        [object-finish-hook : Expr
          (comptime.module-hook format "object-finish")]
        [expect-object-hook : Expr
          (comptime.module-hook format "expect-object")]
        [extra-decls-hook : Expr (comptime.module-hook format "extra-decls")]
        [type-name : String (type-nominal-name T)]
        `(begin
          (module ,module-name-expr)
          (import stdlib.serialize)
          (import ,format-module-expr as __serialize_format)
          (stdlib.serialize.serialize-nested-imports ,format-module-expr ,T 0)
          (defenum Result
            (Ok ,T)
            (Err String))
          (define (is-ok? [result : Result]) : bool
            (match result
              [(Ok _) true]
              [(Err _) false]))
          (define (value-or [result : Result] [fallback : ,T]) : ,T
            (match result
              [(Ok value) value]
              [(Err _) fallback]))
          (define (error-or [result : Result] [fallback : String]) : String
            (match result
              [(Ok _) fallback]
              [(Err message) message]))
          (define (encode [value : ,T]) : ,value-type
            (,object-finish-hook
              (stdlib.serialize.serialize-encode-fields
                ,format-module-expr
                ,T
                0
                value)))
          (define (decode [value : ,value-type]) : Result
            (begin
              (,expect-object-hook
                value
                ,(comptime.expr-string type-name)
                ,err-ctor)
              (let
                [__serialize_out : ,T (init : ,T)]
                (begin
                  (stdlib.serialize.serialize-decode-fields
                    ,format-module-expr
                    ,T
                    0
                    value
                    __serialize_out
                    ,err-ctor)
                  (,ok-ctor __serialize_out)))))
          (,extra-decls-hook ,T)))]
    [_
      (comptime.comptime-error
        (string-append "serialize: expected struct type, got " (type-key T)))]))