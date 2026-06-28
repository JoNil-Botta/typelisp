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
;# export a concrete `Value` type and these hook macros for the struct/sequence
;# subset:
;# `encode-bool`, `decode-bool`, `encode-int`, `decode-int`, `encode-float`,
;# `decode-float`, `encode-string`, `decode-string`, `object-empty`,
;# `object-field`, `object-finish`, `expect-object`, `field-value`, and
;# `sequence-empty`, `sequence-element`, `sequence-finish`, `sequence-length`,
;# `sequence-element-value`, and `extra-decls`. `extra-decls` may emit
;# format-specific helper aliases in the generated module, or `(begin)` when the
;# generic `encode` / `decode` API is enough.
(module stdlib.serialize)

(import stdlib.comptime)

;: Emit the fixed length suffix from array type keys such as `array_i64_3`.
(defmacro (array-fixed-length [T : type]) : i64
  (let
    [key : String (type-key T)]
    [n : i64 (string-length key)]
    [underscore : i64 95]
    [d0 : i64 (- (cast (string-ref key (- n 1)) : i64) 48)]
    [p1 : i64 (- n 2)]
    (if (= (cast (string-ref key p1) : i64) underscore)
      (comptime.expr-int d0)
      (let
        [d1 : i64 (- (cast (string-ref key p1) : i64) 48)]
        [p2 : i64 (- n 3)]
        (if (= (cast (string-ref key p2) : i64) underscore)
          (comptime.expr-int (+ (* d1 10) d0))
          (let
            [d2 : i64 (- (cast (string-ref key p2) : i64) 48)]
            [p3 : i64 (- n 4)]
            (if (= (cast (string-ref key p3) : i64) underscore)
              (comptime.expr-int (+ (* d2 100) (+ (* d1 10) d0)))
              (let
                [d3 : i64 (- (cast (string-ref key p3) : i64) 48)]
                [p4 : i64 (- n 5)]
                (if (= (cast (string-ref key p4) : i64) underscore)
                  (comptime.expr-int
                    (+ (* d3 1000) (+ (* d2 100) (+ (* d1 10) d0))))
                  (let
                    [d4 : i64 (- (cast (string-ref key p4) : i64) 48)]
                    [p5 : i64 (- n 6)]
                    (if (= (cast (string-ref key p5) : i64) underscore)
                      (comptime.expr-int
                        (+
                          (* d4 10000)
                          (+ (* d3 1000) (+ (* d2 100) (+ (* d1 10) d0)))))
                      (let
                        [d5 : i64 (- (cast (string-ref key p5) : i64) 48)]
                        [p6 : i64 (- n 7)]
                        (if (= (cast (string-ref key p6) : i64) underscore)
                          (comptime.expr-int
                            (+
                              (* d5 100000)
                              (+
                                (* d4 10000)
                                (+ (* d3 1000) (+ (* d2 100) (+ (* d1 10) d0))))))
                          (comptime.comptime-error
                            "serialize: fixed array length suffix is too long"))))))))))))))

;: Emit the encoded value expression for one supported value type.
(defmacro (encode-value
  [format : Module]
  [value-type : type]
  [nested-alias : Expr]
  [value : Expr]) : Expr
  (let
    [nested-alias-text : String
      (match nested-alias
        [(ExprVar found) found]
        [_ (comptime.comptime-error "serialize: nested alias must be a name")])]
    [value-key : String (type-key value-type)]
    [value-kind : String (type-kind value-type)]
    [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
    (match value-key
      ["bool"
        (let
          [hook : Expr (comptime.module-hook format "encode-bool")]
          `(,hook ,value))]
      ["String"
        (let
          [hook : Expr (comptime.module-hook format "encode-string")]
          `(,hook ,value))]
      ["i64"
        (let
          [hook : Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["i32"
        (let
          [hook : Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["i16"
        (let
          [hook : Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["i8"
        (let
          [hook : Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["u64"
        (let
          [hook : Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["u32"
        (let
          [hook : Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["u16"
        (let
          [hook : Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["u8"
        (let
          [hook : Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["f64"
        (let
          [hook : Expr (comptime.module-hook format "encode-float")]
          `(,hook ,value-type ,value))]
      ["f32"
        (let
          [hook : Expr (comptime.module-hook format "encode-float")]
          `(,hook ,value-type ,value))]
      [_
        (match value-kind
          ["struct"
            (let
              [nested-encode : Expr
                (comptime.expr-var (string-append nested-alias-text ".encode"))]
              `(,nested-encode ,value))]
          ["array"
            (let
              [element-type : Expr (array-element-type value-type)]
              [element-alias : String (string-append nested-alias-text "_elem")]
              [empty-hook : Expr (comptime.module-hook format "sequence-empty")]
              [element-hook : Expr
                (comptime.module-hook format "sequence-element")]
              [finish-hook : Expr
                (comptime.module-hook format "sequence-finish")]
              [length-expr : Expr
                `(stdlib.serialize.array-fixed-length ,value-type)]
              `(let
                [__serialize_items (,empty-hook)]
                [__serialize_i : i64 (- ,length-expr 1)]
                (begin
                  (while (>= __serialize_i 0)
                    (begin
                      (set!
                        __serialize_items
                        (,element-hook
                          __serialize_i
                          (stdlib.serialize.encode-value
                            ,format-expr
                            ,element-type
                            ,(comptime.expr-var element-alias)
                            (__tl_array-ref ,value __serialize_i))
                          __serialize_items))
                      (set! __serialize_i (- __serialize_i 1))))
                  (,finish-hook __serialize_items))))]
          ["dyn-array"
            (let
              [element-type : Expr (array-element-type value-type)]
              [element-alias : String (string-append nested-alias-text "_elem")]
              [empty-hook : Expr (comptime.module-hook format "sequence-empty")]
              [element-hook : Expr
                (comptime.module-hook format "sequence-element")]
              [finish-hook : Expr
                (comptime.module-hook format "sequence-finish")]
              `(let
                [__serialize_items (,empty-hook)]
                [__serialize_i : i64 (- (__tl_array-length ,value) 1)]
                (begin
                  (while (>= __serialize_i 0)
                    (begin
                      (set!
                        __serialize_items
                        (,element-hook
                          __serialize_i
                          (stdlib.serialize.encode-value
                            ,format-expr
                            ,element-type
                            ,(comptime.expr-var element-alias)
                            (__tl_array-ref ,value __serialize_i))
                          __serialize_items))
                      (set! __serialize_i (- __serialize_i 1))))
                  (,finish-hook __serialize_items))))]
          [_
            (comptime.comptime-error
              (string-append "serialize: unsupported type " value-key))])])))

;: Emit the decoded value expression for one supported value type.
(defmacro (decode-value
  [format : Module]
  [value-type : type]
  [nested-alias : Expr]
  [value : Expr]
  [err-ctor : Expr]) : Expr
  (let
    [nested-alias-text : String
      (match nested-alias
        [(ExprVar found) found]
        [_ (comptime.comptime-error "serialize: nested alias must be a name")])]
    [value-key : String (type-key value-type)]
    [value-kind : String (type-kind value-type)]
    [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
    (match value-key
      ["bool"
        (let
          [hook : Expr (comptime.module-hook format "decode-bool")]
          `(,hook ,value ,err-ctor))]
      ["String"
        (let
          [hook : Expr (comptime.module-hook format "decode-string")]
          `(,hook ,value ,err-ctor))]
      ["i64"
        (let
          [hook : Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["i32"
        (let
          [hook : Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["i16"
        (let
          [hook : Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["i8"
        (let
          [hook : Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["u64"
        (let
          [hook : Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["u32"
        (let
          [hook : Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["u16"
        (let
          [hook : Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["u8"
        (let
          [hook : Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["f64"
        (let
          [hook : Expr (comptime.module-hook format "decode-float")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["f32"
        (let
          [hook : Expr (comptime.module-hook format "decode-float")]
          `(,hook ,value-type ,value ,err-ctor))]
      [_
        (match value-kind
          ["struct"
            (let
              [nested-decode : Expr
                (comptime.expr-var (string-append nested-alias-text ".decode"))]
              `(let
                [__serialize_nested_result (,nested-decode ,value)]
                (match __serialize_nested_result
                  [(Ok parsed) parsed]
                  [(Err err) (return (,err-ctor err))])))]
          ["array"
            (let
              [element-type : Expr (array-element-type value-type)]
              [element-alias : String (string-append nested-alias-text "_elem")]
              [length-hook : Expr
                (comptime.module-hook format "sequence-length")]
              [element-hook : Expr
                (comptime.module-hook format "sequence-element-value")]
              [length-expr : Expr
                `(stdlib.serialize.array-fixed-length ,value-type)]
              `(let
                [__serialize_count : i64 (,length-hook ,value ,err-ctor)]
                (begin
                  (if (!= __serialize_count ,length-expr)
                    (return (,err-ctor "serialize: sequence length mismatch"))
                    unit)
                  (let
                    [__serialize_out : ,value-type (init : ,value-type)]
                    [__serialize_i : i64 0]
                    (begin
                      (while (< __serialize_i ,length-expr)
                        (begin
                          (__tl_array-set!
                            __serialize_out
                            __serialize_i
                            (stdlib.serialize.decode-value
                              ,format-expr
                              ,element-type
                              ,(comptime.expr-var element-alias)
                              (,element-hook ,value __serialize_i ,err-ctor)
                              ,err-ctor))
                          (set! __serialize_i (+ __serialize_i 1))))
                      __serialize_out)))))]
          ["dyn-array"
            (let
              [element-type : Expr (array-element-type value-type)]
              [element-alias : String (string-append nested-alias-text "_elem")]
              [length-hook : Expr
                (comptime.module-hook format "sequence-length")]
              [element-hook : Expr
                (comptime.module-hook format "sequence-element-value")]
              `(let
                [__serialize_count : i64 (,length-hook ,value ,err-ctor)]
                [__serialize_out : ,value-type
                  (__tl_make-array ,element-type __serialize_count)]
                [__serialize_i : i64 0]
                (begin
                  (while (< __serialize_i __serialize_count)
                    (begin
                      (__tl_array-set!
                        __serialize_out
                        __serialize_i
                        (stdlib.serialize.decode-value
                          ,format-expr
                          ,element-type
                          ,(comptime.expr-var element-alias)
                          (,element-hook ,value __serialize_i ,err-ctor)
                          ,err-ctor))
                      (set! __serialize_i (+ __serialize_i 1))))
                  __serialize_out)))]
          [_
            (comptime.comptime-error
              (string-append "serialize: unsupported type " value-key))])])))

;: Emit the encoded value expression for one struct field.
(defmacro (encode-field
  [format : Module]
  [T : type]
  [index-expr : Expr]
  [value : Expr]) : Expr
  (match index-expr
    [(ExprInt index)
      (let
        [field-name : String (struct-field-name T index)]
        [field-type : Expr (struct-field-type T index)]
        [field-access : Expr (comptime.expr-struct-get value field-name)]
        [nested-alias-text : String
          (string-append "__serialize_nested_f" (comptime.int->string index))]
        [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
        `(stdlib.serialize.encode-value
          ,format-expr
          ,field-type
          ,(comptime.expr-var nested-alias-text)
          ,field-access))]
    [_
      (comptime.comptime-error
        "serialize: field index must be an integer literal")]))

;: Emit the strategy-owned object field accumulator for struct fields.
(defmacro (encode-fields
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
            (stdlib.serialize.encode-field
              ,format-expr
              ,T
              ,(comptime.expr-int index)
              ,value)
            (stdlib.serialize.encode-fields ,format-expr ,T ,next-index ,value))))]
    [_
      (comptime.comptime-error
        "serialize: field accumulator index must be an integer literal")]))

;: Emit decode logic for one struct field.
(defmacro (decode-field
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
        [field-key-expr : Expr (comptime.expr-string field-name)]
        [field-value-hook : Expr (comptime.module-hook format "field-value")]
        [nested-alias-text : String
          (string-append "__serialize_nested_f" (comptime.int->string index))]
        [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
        [decoded-expr : Expr
          `(stdlib.serialize.decode-value
            ,format-expr
            ,field-type
            ,(comptime.expr-var nested-alias-text)
            __serialize_field
            ,err-ctor)]
        [set-expr : Expr (comptime.expr-struct-set out field-name decoded-expr)]
        `(let
          [__serialize_field
            (,field-value-hook ,value ,field-key-expr ,err-ctor)]
          ,set-expr))]
    [_
      (comptime.comptime-error
        "serialize: decode field index must be an integer literal")]))

;: Emit recursive decode logic for all struct fields.
(defmacro (decode-fields
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
            (stdlib.serialize.decode-field
              ,format-expr
              ,T
              ,(comptime.expr-int index)
              ,value
              ,out
              ,err-ctor)
            (stdlib.serialize.decode-fields
              ,format-expr
              ,T
              ,next-index
              ,value
              ,out
              ,err-ctor))))]
    [_
      (comptime.comptime-error
        "serialize: decode fields index must be an integer literal")]))

;: Emit one recursive generated serializer import needed by a nested value type.
(defmacro (nested-import-for-type
  [format : Module]
  [value-type : type]
  [nested-alias : Expr]) : Decls
  (let
    [nested-alias-text : String
      (match nested-alias
        [(ExprVar found) found]
        [_ (comptime.comptime-error "serialize: nested alias must be a name")])]
    [value-kind : String (type-kind value-type)]
    [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
    (match value-kind
      ["struct"
        `(import (stdlib.serialize.serialize ,format-expr ,value-type) as ,nested-alias)]
      ["array"
        (let
          [element-type : Expr (array-element-type value-type)]
          [element-alias : String (string-append nested-alias-text "_elem")]
          `(stdlib.serialize.nested-import-for-type
            ,format-expr
            ,element-type
            ,(comptime.expr-var element-alias)))]
      ["dyn-array"
        (let
          [element-type : Expr (array-element-type value-type)]
          [element-alias : String (string-append nested-alias-text "_elem")]
          `(stdlib.serialize.nested-import-for-type
            ,format-expr
            ,element-type
            ,(comptime.expr-var element-alias)))]
      [_ `(begin)])))

;: Emit recursive generated serializer imports needed for nested struct fields.
(defmacro (nested-imports [format : Module] [T : type] [index-expr : Expr]) : Decls
  (match index-expr
    [(ExprInt index)
      (if (>= index (struct-field-count T))
        `(begin)
        (let
          [field-type : Expr (struct-field-type T index)]
          [next-index : Expr (comptime.expr-int (+ index 1))]
          [format-expr : Expr (comptime.expr-var (comptime.module-name format))]
          [nested-alias-text : String
            (string-append "__serialize_nested_f" (comptime.int->string index))]
          `(begin
            (stdlib.serialize.nested-imports ,format-expr ,T ,next-index)
            (stdlib.serialize.nested-import-for-type
              ,format-expr
              ,field-type
              ,(comptime.expr-var nested-alias-text)))))]
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
          (stdlib.serialize.nested-imports ,format-module-expr ,T 0)
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
              (stdlib.serialize.encode-fields ,format-module-expr ,T 0 value)))
          (define (decode [value : ,value-type]) : Result
            (begin
              (,expect-object-hook
                value
                ,(comptime.expr-string type-name)
                ,err-ctor)
              (let
                [__serialize_out : ,T (init : ,T)]
                (begin
                  (stdlib.serialize.decode-fields
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