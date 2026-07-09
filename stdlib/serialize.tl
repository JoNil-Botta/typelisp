;# Format-generic value serialization macros.
;#
;# `serialize` emits a generated module for a concrete value type and a format
;# strategy module:
;#
;# ```lisp test=ignore name=serialize-strategy-sketch reason="sketch uses an application-provided format module"
;# (import stdlib.serialize)
;# (import my.format as fmt)
;# (import (serialize.serialize fmt Person) as person_ser)
;# ```
;#
;# The generated module exposes `Value`, `Result`, `Ok`, `Err`, `encode`,
;# `decode`, `is-ok?`, `value-or`, and `error-or`. `Value` aliases the concrete
;# strategy `Value` type, while `Result` wraps decoded values as `Ok T` or
;# `Err String`. Strategy hooks are ordinary exported macros looked up with
;# `comptime.module-hook`; a missing hook is reported as
;# `typecheck: strategy module <module> does not export hook <name>`.
;#
;# A strategy module must export:
;#
;# - A concrete `Value` type.
;# - Scalar hooks:
;#   `encode-bool(value: bool) -> Value`,
;#   `decode-bool(value: Expr, err-ctor: Expr) -> Expr`,
;#   `encode-int(T: type, value: Expr) -> Value`,
;#   `decode-int(T: type, value: Expr, err-ctor: Expr) -> Expr`,
;#   `encode-float(T: type, value: Expr) -> Value`,
;#   `decode-float(T: type, value: Expr, err-ctor: Expr) -> Expr`,
;#   `encode-string(value: String) -> Value`, and
;#   `decode-string(value: Expr, err-ctor: Expr) -> Expr`.
;# - Object hooks for every struct root, enum root, nested struct, or nested
;#   enum:
;#   `object-empty() -> FieldList`,
;#   `object-field(name: Expr, value: Expr, rest: Expr) -> FieldList`,
;#   `object-finish(fields: Expr) -> Value`,
;#   `expect-object(value: Expr, type-name: Expr, err-ctor: Expr) -> unit`, and
;#   `field-value(object: Expr, name: Expr, err-ctor: Expr) -> Expr`.
;# - Sequence hooks when any serialized value is a fixed array, dynamic array,
;#   tuple, or enum payload list:
;#   `sequence-empty() -> ValueList`,
;#   `sequence-element(index: Expr, value: Expr, rest: Expr) -> ValueList`,
;#   `sequence-finish(items: Expr) -> Value`,
;#   `sequence-length(value: Expr, err-ctor: Expr) -> i64`, and
;#   `sequence-element-value(value: Expr, index: Expr, err-ctor: Expr) -> Expr`.
;# - `extra-decls(T: type) -> Decls`, which may emit format-specific helper
;#   aliases such as `to-json` / `from-json`, or `(begin)` when the generic
;#   `encode` / `decode` API is enough.
;#
;# Decode hooks receive the generated module's `Err` constructor as `err-ctor`.
;# On malformed input they should expand to an expression that returns
;# `(err-ctor message)` from the generated `decode` function; on success they
;# should produce a value expression of the requested field type. Sequence decode
;# hooks report the source length and individual encoded elements; the generated
;# module allocates and fills the fixed or dynamic output array. Enums are encoded
;# as an object with a string `tag` field and a sequence `payload` field. Direct
;# struct enum payloads, generated option/result family enum reflection, and tuple
;# roots, and enum variants with more than eight payloads remain follow-ups.
(import stdlib.comptime)
(import stdlib.string)

;: Emit the fixed length suffix from array type keys such as `array_i64_3`.
(defmacro (array-fixed-length [T : type]) : i64
  (let
    [key : String (type-key T)]
    [n : i64 (string.string-length key)]
    [underscore : i64 95]
    [d0 : i64 (- (cast (string.string-ref key (- n 1)) : i64) 48)]
    [p1 : i64 (- n 2)]
    (if (= (cast (string.string-ref key p1) : i64) underscore)
      (comptime.expr-int d0)
      (let
        [d1 : i64 (- (cast (string.string-ref key p1) : i64) 48)]
        [p2 : i64 (- n 3)]
        (if (= (cast (string.string-ref key p2) : i64) underscore)
          (comptime.expr-int (+ (* d1 10) d0))
          (let
            [d2 : i64 (- (cast (string.string-ref key p2) : i64) 48)]
            [p3 : i64 (- n 4)]
            (if (= (cast (string.string-ref key p3) : i64) underscore)
              (comptime.expr-int (+ (* d2 100) (+ (* d1 10) d0)))
              (let
                [d3 : i64 (- (cast (string.string-ref key p3) : i64) 48)]
                [p4 : i64 (- n 5)]
                (if (= (cast (string.string-ref key p4) : i64) underscore)
                  (comptime.expr-int
                    (+ (* d3 1000) (+ (* d2 100) (+ (* d1 10) d0))))
                  (let
                    [d4 : i64 (- (cast (string.string-ref key p4) : i64) 48)]
                    [p5 : i64 (- n 6)]
                    (if (= (cast (string.string-ref key p5) : i64) underscore)
                      (comptime.expr-int
                        (+
                          (* d4 10000)
                          (+ (* d3 1000) (+ (* d2 100) (+ (* d1 10) d0)))))
                      (let
                        [d5 : i64
                          (- (cast (string.string-ref key p5) : i64) 48)]
                        [p6 : i64 (- n 7)]
                        (if (=
                          (cast (string.string-ref key p6) : i64)
                          underscore)
                          (comptime.expr-int
                            (+
                              (* d5 100000)
                              (+
                                (* d4 10000)
                                (+ (* d3 1000) (+ (* d2 100) (+ (* d1 10) d0))))))
                          (comptime.comptime-error
                            "serialize: fixed array length suffix is too long"))))))))))))))

;: Emit a tuple's encoded element-list expression using literal tuple indexes.
(defmacro (encode-tuple-elements
  [format : Module]
  [tuple-type : type]
  [nested-alias : comptime.Expr]
  [value : comptime.Expr]
  [index-expr : comptime.Expr]
  [items : comptime.Expr]) : comptime.Expr
  (match index-expr
    [(comptime.ExprInt index)
      (if (< index 0)
        items
        (let
          [element-type : comptime.Expr (tuple-element-type tuple-type index)]
          [element-alias : comptime.Expr
            (match nested-alias
              [(comptime.ExprVar nested-alias-text)
                (comptime.expr-var
                  (comptime.string-append
                    (comptime.string-append nested-alias-text "_tuple_")
                    (comptime.int->string index)))]
              [_
                (comptime.comptime-error
                  "serialize: nested alias must be a name")])]
          [element-hook : comptime.Expr
            (comptime.module-hook format "sequence-element")]
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
          [element-value : comptime.Expr (comptime.expr-tuple-ref value index)]
          [prev-index : comptime.Expr (comptime.expr-int (- index 1))]
          `(stdlib.serialize.encode-tuple-elements
            ,format-expr
            ,tuple-type
            ,nested-alias
            ,value
            ,prev-index
            (,element-hook
              ,index-expr
              (stdlib.serialize.encode-value
                ,format-expr
                ,element-type
                ,element-alias
                ,element-value)
              ,items))))]
    [_
      (comptime.comptime-error
        "serialize: tuple encode index must be an integer literal")]))

;: Emit a tuple constructor by accumulating decoded element expressions.
(defmacro (decode-tuple-items
  [format : Module]
  [tuple-type : type]
  [nested-alias : comptime.Expr]
  [value : comptime.Expr]
  [err-ctor : comptime.Expr]
  [index-expr : comptime.Expr]
  [items : comptime.Expr ...]) : comptime.Expr
  (match index-expr
    [(comptime.ExprInt index)
      (if (>= index (tuple-element-count tuple-type))
        `(tuple ,@items)
        (let
          [element-type : comptime.Expr (tuple-element-type tuple-type index)]
          [element-alias : comptime.Expr
            (match nested-alias
              [(comptime.ExprVar nested-alias-text)
                (comptime.expr-var
                  (comptime.string-append
                    (comptime.string-append nested-alias-text "_tuple_")
                    (comptime.int->string index)))]
              [_
                (comptime.comptime-error
                  "serialize: nested alias must be a name")])]
          [element-hook : comptime.Expr
            (comptime.module-hook format "sequence-element-value")]
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          [decoded : comptime.Expr
            `(stdlib.serialize.decode-value
              ,format-expr
              ,element-type
              ,element-alias
              (,element-hook ,value ,index-expr ,err-ctor)
              ,err-ctor)]
          `(stdlib.serialize.decode-tuple-items
            ,format-expr
            ,tuple-type
            ,nested-alias
            ,value
            ,err-ctor
            ,next-index
            ,@items
            ,decoded)))]
    [_
      (comptime.comptime-error
        "serialize: tuple decode index must be an integer literal")]))

;: Emit an enum payload's encoded sequence elements using payload bindings.
(defmacro (encode-enum-payload-elements
  [format : Module]
  [enum-type : type]
  [nested-alias : comptime.Expr]
  [variant-index-expr : comptime.Expr]
  [payload-index-expr : comptime.Expr]
  [items : comptime.Expr]) : comptime.Expr
  (match variant-index-expr
    [(comptime.ExprInt variant-index)
      (match payload-index-expr
        [(comptime.ExprInt payload-index)
          (if (< payload-index 0)
            items
            (let
              [payload-name : String
                (comptime.string-append
                  (comptime.string-append
                    (comptime.string-append
                      "__serialize_v"
                      (comptime.int->string variant-index))
                    "_p")
                  (comptime.int->string payload-index))]
              [payload-value : comptime.Expr (comptime.expr-var payload-name)]
              [payload-type : comptime.Expr
                (enum-variant-payload-type
                  enum-type
                  variant-index
                  payload-index)]
              [payload-kind : String (type-kind payload-type)]
              [payload-alias : comptime.Expr
                (match nested-alias
                  [(comptime.ExprVar nested-alias-text)
                    (comptime.expr-var
                      (comptime.string-append
                        (comptime.string-append
                          (comptime.string-append
                            (comptime.string-append
                              nested-alias-text
                              "_variant_")
                            (comptime.int->string variant-index))
                          "_payload_")
                        (comptime.int->string payload-index)))]
                  [_
                    (comptime.comptime-error
                      "serialize: nested alias must be a name")])]
              [element-hook : comptime.Expr
                (comptime.module-hook format "sequence-element")]
              [format-expr : comptime.Expr
                (comptime.expr-var (comptime.module-name format))]
              [prev-index : comptime.Expr
                (comptime.expr-int (- payload-index 1))]
              (if (string.eq payload-kind "struct")
                (comptime.comptime-error
                  "serialize: enum struct payloads are not supported yet")
                `(stdlib.serialize.encode-enum-payload-elements
                  ,format-expr
                  ,enum-type
                  ,nested-alias
                  ,variant-index-expr
                  ,prev-index
                  (,element-hook
                    ,payload-index-expr
                    (stdlib.serialize.encode-value
                      ,format-expr
                      ,payload-type
                      ,payload-alias
                      ,payload-value)
                    ,items)))))]
        [_
          (comptime.comptime-error
            "serialize: enum payload index must be an integer literal")])]
    [_
      (comptime.comptime-error
        "serialize: enum variant index must be an integer literal")]))

;: Emit a staged single-variant match for encoding an enum value.
(defmacro (encode-enum-dispatch
  [format : Module]
  [enum-type : type]
  [nested-alias : comptime.Expr]
  [value : comptime.Expr]
  [variant-index-expr : comptime.Expr]) : comptime.Expr
  (match variant-index-expr
    [(comptime.ExprInt variant-index)
      (if (>= variant-index (enum-variant-count enum-type))
        (let
          [empty-object-hook : comptime.Expr
            (comptime.module-hook format "object-empty")]
          [object-finish-hook : comptime.Expr
            (comptime.module-hook format "object-finish")]
          `(,object-finish-hook (,empty-object-hook)))
        (let
          [variant-name : String (enum-variant-name enum-type variant-index)]
          [variant-source-name : String variant-name]
          [payload-count : i64
            (enum-variant-payload-count enum-type variant-index)]
          [p0 : comptime.Pattern
            (comptime.pattern-binding
              (comptime.string-append
                (comptime.string-append
                  (comptime.string-append
                    "__serialize_v"
                    (comptime.int->string variant-index))
                  "_p")
                "0"))]
          [p1 : comptime.Pattern
            (comptime.pattern-binding
              (comptime.string-append
                (comptime.string-append
                  (comptime.string-append
                    "__serialize_v"
                    (comptime.int->string variant-index))
                  "_p")
                "1"))]
          [p2 : comptime.Pattern
            (comptime.pattern-binding
              (comptime.string-append
                (comptime.string-append
                  (comptime.string-append
                    "__serialize_v"
                    (comptime.int->string variant-index))
                  "_p")
                "2"))]
          [p3 : comptime.Pattern
            (comptime.pattern-binding
              (comptime.string-append
                (comptime.string-append
                  (comptime.string-append
                    "__serialize_v"
                    (comptime.int->string variant-index))
                  "_p")
                "3"))]
          [p4 : comptime.Pattern
            (comptime.pattern-binding
              (comptime.string-append
                (comptime.string-append
                  (comptime.string-append
                    "__serialize_v"
                    (comptime.int->string variant-index))
                  "_p")
                "4"))]
          [p5 : comptime.Pattern
            (comptime.pattern-binding
              (comptime.string-append
                (comptime.string-append
                  (comptime.string-append
                    "__serialize_v"
                    (comptime.int->string variant-index))
                  "_p")
                "5"))]
          [p6 : comptime.Pattern
            (comptime.pattern-binding
              (comptime.string-append
                (comptime.string-append
                  (comptime.string-append
                    "__serialize_v"
                    (comptime.int->string variant-index))
                  "_p")
                "6"))]
          [p7 : comptime.Pattern
            (comptime.pattern-binding
              (comptime.string-append
                (comptime.string-append
                  (comptime.string-append
                    "__serialize_v"
                    (comptime.int->string variant-index))
                  "_p")
                "7"))]
          [payload-patterns : comptime.PatternList
            (if (= payload-count 0)
              (comptime.pattern-list-empty)
              (if (= payload-count 1)
                (comptime.pattern-list-cons p0 (comptime.pattern-list-empty))
                (if (= payload-count 2)
                  (comptime.pattern-list-cons
                    p0
                    (comptime.pattern-list-cons
                      p1
                      (comptime.pattern-list-empty)))
                  (if (= payload-count 3)
                    (comptime.pattern-list-cons
                      p0
                      (comptime.pattern-list-cons
                        p1
                        (comptime.pattern-list-cons
                          p2
                          (comptime.pattern-list-empty))))
                    (if (= payload-count 4)
                      (comptime.pattern-list-cons
                        p0
                        (comptime.pattern-list-cons
                          p1
                          (comptime.pattern-list-cons
                            p2
                            (comptime.pattern-list-cons
                              p3
                              (comptime.pattern-list-empty)))))
                      (if (= payload-count 5)
                        (comptime.pattern-list-cons
                          p0
                          (comptime.pattern-list-cons
                            p1
                            (comptime.pattern-list-cons
                              p2
                              (comptime.pattern-list-cons
                                p3
                                (comptime.pattern-list-cons
                                  p4
                                  (comptime.pattern-list-empty))))))
                        (if (= payload-count 6)
                          (comptime.pattern-list-cons
                            p0
                            (comptime.pattern-list-cons
                              p1
                              (comptime.pattern-list-cons
                                p2
                                (comptime.pattern-list-cons
                                  p3
                                  (comptime.pattern-list-cons
                                    p4
                                    (comptime.pattern-list-cons
                                      p5
                                      (comptime.pattern-list-empty)))))))
                          (if (= payload-count 7)
                            (comptime.pattern-list-cons
                              p0
                              (comptime.pattern-list-cons
                                p1
                                (comptime.pattern-list-cons
                                  p2
                                  (comptime.pattern-list-cons
                                    p3
                                    (comptime.pattern-list-cons
                                      p4
                                      (comptime.pattern-list-cons
                                        p5
                                        (comptime.pattern-list-cons
                                          p6
                                          (comptime.pattern-list-empty))))))))
                            (if (= payload-count 8)
                              (comptime.pattern-list-cons
                                p0
                                (comptime.pattern-list-cons
                                  p1
                                  (comptime.pattern-list-cons
                                    p2
                                    (comptime.pattern-list-cons
                                      p3
                                      (comptime.pattern-list-cons
                                        p4
                                        (comptime.pattern-list-cons
                                          p5
                                          (comptime.pattern-list-cons
                                            p6
                                            (comptime.pattern-list-cons
                                              p7
                                              (comptime.pattern-list-empty)))))))))
                              (comptime.comptime-error
                                "serialize: enum variants with more than 8 payloads are not supported"))))))))))]
          [pattern : comptime.Pattern
            (comptime.pattern-variant variant-source-name payload-patterns)]
          [empty-object-hook : comptime.Expr
            (comptime.module-hook format "object-empty")]
          [field-hook : comptime.Expr
            (comptime.module-hook format "object-field")]
          [object-finish-hook : comptime.Expr
            (comptime.module-hook format "object-finish")]
          [encode-string-hook : comptime.Expr
            (comptime.module-hook format "encode-string")]
          [sequence-empty-hook : comptime.Expr
            (comptime.module-hook format "sequence-empty")]
          [sequence-finish-hook : comptime.Expr
            (comptime.module-hook format "sequence-finish")]
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
          [last-payload-index : comptime.Expr
            (comptime.expr-int (- payload-count 1))]
          [next-variant-index : comptime.Expr
            (comptime.expr-int (+ variant-index 1))]
          [fallback : comptime.Expr
            `(stdlib.serialize.encode-enum-dispatch
              ,format-expr
              ,enum-type
              ,nested-alias
              ,value
              ,next-variant-index)]
          [body : comptime.Expr
            `(,object-finish-hook
              (,field-hook
                "tag"
                (,encode-string-hook ,(comptime.expr-string variant-name))
                (,field-hook
                  "payload"
                  (,sequence-finish-hook
                    (stdlib.serialize.encode-enum-payload-elements
                      ,format-expr
                      ,enum-type
                      ,nested-alias
                      ,variant-index-expr
                      ,last-payload-index
                      (,sequence-empty-hook)))
                  (,empty-object-hook))))]
          (comptime.expr-match
            value
            (comptime.match-arm-list-cons
              (comptime.match-arm pattern body)
              (comptime.match-arm-list-cons
                (comptime.match-arm (comptime.pattern-wildcard) fallback)
                (comptime.match-arm-list-empty))))))]
    [_
      (comptime.comptime-error
        "serialize: enum variant index must be an integer literal")]))

;: Emit an enum variant constructor from decoded payload expressions.
(defmacro (decode-enum-payload-items
  [format : Module]
  [enum-type : type]
  [nested-alias : comptime.Expr]
  [payload : comptime.Expr]
  [err-ctor : comptime.Expr]
  [variant-index-expr : comptime.Expr]
  [payload-index-expr : comptime.Expr]
  [items : comptime.Expr ...]) : comptime.Expr
  (match variant-index-expr
    [(comptime.ExprInt variant-index)
      (match payload-index-expr
        [(comptime.ExprInt payload-index)
          (if (>=
            payload-index
            (enum-variant-payload-count enum-type variant-index))
            (let
              [variant-name : String
                (enum-variant-name enum-type variant-index)]
              [enum-module : String (type-nominal-module enum-type)]
              [enum-name : String (type-nominal-name enum-type)]
              [enum-variant-source-name : String
                (comptime.string-append
                  enum-name
                  (comptime.string-append "." variant-name))]
              [enum-source-alias : String
                (match nested-alias
                  [(comptime.ExprVar nested-alias-text)
                    (comptime.string-append nested-alias-text "_enum_source")]
                  [_
                    (comptime.comptime-error
                      "serialize: nested alias must be a name")])]
              [variant-source-name : String
                (if (string.eq enum-module "")
                  enum-variant-source-name
                  (comptime.string-append
                    enum-source-alias
                    (comptime.string-append "." enum-variant-source-name)))]
              [variant-ctor : comptime.Expr
                (comptime.expr-var variant-source-name)]
              `(,variant-ctor ,@items))
            (let
              [payload-type : comptime.Expr
                (enum-variant-payload-type
                  enum-type
                  variant-index
                  payload-index)]
              [payload-alias : comptime.Expr
                (match nested-alias
                  [(comptime.ExprVar nested-alias-text)
                    (comptime.expr-var
                      (comptime.string-append
                        (comptime.string-append
                          (comptime.string-append
                            (comptime.string-append
                              nested-alias-text
                              "_variant_")
                            (comptime.int->string variant-index))
                          "_payload_")
                        (comptime.int->string payload-index)))]
                  [_
                    (comptime.comptime-error
                      "serialize: nested alias must be a name")])]
              [element-hook : comptime.Expr
                (comptime.module-hook format "sequence-element-value")]
              [format-expr : comptime.Expr
                (comptime.expr-var (comptime.module-name format))]
              [next-index : comptime.Expr
                (comptime.expr-int (+ payload-index 1))]
              [decoded : comptime.Expr
                `(stdlib.serialize.decode-value
                  ,format-expr
                  ,payload-type
                  ,payload-alias
                  (,element-hook ,payload ,payload-index-expr ,err-ctor)
                  ,err-ctor)]
              `(stdlib.serialize.decode-enum-payload-items
                ,format-expr
                ,enum-type
                ,nested-alias
                ,payload
                ,err-ctor
                ,variant-index-expr
                ,next-index
                ,@items
                ,decoded)))]
        [_
          (comptime.comptime-error
            "serialize: enum payload index must be an integer literal")])]
    [_
      (comptime.comptime-error
        "serialize: enum variant index must be an integer literal")]))

;: Emit the runtime decode branch chain for enum tags.
(defmacro (decode-enum-variants
  [format : Module]
  [enum-type : type]
  [nested-alias : comptime.Expr]
  [payload : comptime.Expr]
  [err-ctor : comptime.Expr]
  [tag : comptime.Expr]
  [variant-index-expr : comptime.Expr]) : comptime.Expr
  (match variant-index-expr
    [(comptime.ExprInt variant-index)
      (if (>= variant-index (enum-variant-count enum-type))
        `(return (,err-ctor "serialize: unknown enum tag"))
        (let
          [variant-name : String (enum-variant-name enum-type variant-index)]
          [payload-count : i64
            (enum-variant-payload-count enum-type variant-index)]
          [payload-count-expr : comptime.Expr (comptime.expr-int payload-count)]
          [length-hook : comptime.Expr
            (comptime.module-hook format "sequence-length")]
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
          [next-variant-index : comptime.Expr
            (comptime.expr-int (+ variant-index 1))]
          `(if (stdlib.string.eq ,tag ,(comptime.expr-string variant-name))
            (let
              [__serialize_payload_count : i64
                (,length-hook ,payload ,err-ctor)]
              (begin
                (if (!= __serialize_payload_count ,payload-count-expr)
                  (return (,err-ctor "serialize: enum payload length mismatch"))
                  unit)
                (stdlib.serialize.decode-enum-payload-items
                  ,format-expr
                  ,enum-type
                  ,nested-alias
                  ,payload
                  ,err-ctor
                  ,variant-index-expr
                  0)))
            (stdlib.serialize.decode-enum-variants
              ,format-expr
              ,enum-type
              ,nested-alias
              ,payload
              ,err-ctor
              ,tag
              ,next-variant-index))))]
    [_
      (comptime.comptime-error
        "serialize: enum variant index must be an integer literal")]))

;: Emit the encoded value expression for one supported value type.
(defmacro (encode-value
  [format : Module]
  [value-type : type]
  [nested-alias : comptime.Expr]
  [value : comptime.Expr]) : comptime.Expr
  (let
    [nested-alias-text : String
      (match nested-alias
        [(comptime.ExprVar found) found]
        [_ (comptime.comptime-error "serialize: nested alias must be a name")])]
    [value-key : String (type-key value-type)]
    [value-kind : String (type-kind value-type)]
    [format-expr : comptime.Expr
      (comptime.expr-var (comptime.module-name format))]
    (match value-key
      ["bool"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-bool")]
          `(,hook ,value))]
      ["String"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-string")]
          `(,hook ,value))]
      ["i64"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["i32"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["i16"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["i8"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["u64"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["u32"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["u16"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["u8"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-int")]
          `(,hook ,value-type ,value))]
      ["f64"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-float")]
          `(,hook ,value-type ,value))]
      ["f32"
        (let
          [hook : comptime.Expr (comptime.module-hook format "encode-float")]
          `(,hook ,value-type ,value))]
      [_
        (match value-kind
          ["struct"
            (let
              [nested-encode : comptime.Expr
                (comptime.expr-var
                  (comptime.string-append nested-alias-text ".encode"))]
              `(,nested-encode ,value))]
          ["array"
            (let
              [element-type : comptime.Expr (array-element-type value-type)]
              [element-alias : String
                (comptime.string-append nested-alias-text "_elem")]
              [empty-hook : comptime.Expr
                (comptime.module-hook format "sequence-empty")]
              [element-hook : comptime.Expr
                (comptime.module-hook format "sequence-element")]
              [finish-hook : comptime.Expr
                (comptime.module-hook format "sequence-finish")]
              [length-expr : comptime.Expr
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
              [element-type : comptime.Expr (array-element-type value-type)]
              [element-alias : String
                (comptime.string-append nested-alias-text "_elem")]
              [empty-hook : comptime.Expr
                (comptime.module-hook format "sequence-empty")]
              [element-hook : comptime.Expr
                (comptime.module-hook format "sequence-element")]
              [finish-hook : comptime.Expr
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
          ["tuple"
            (let
              [empty-hook : comptime.Expr
                (comptime.module-hook format "sequence-empty")]
              [finish-hook : comptime.Expr
                (comptime.module-hook format "sequence-finish")]
              [last-index : comptime.Expr
                (comptime.expr-int (- (tuple-element-count value-type) 1))]
              `(,finish-hook
                (stdlib.serialize.encode-tuple-elements
                  ,format-expr
                  ,value-type
                  ,nested-alias
                  ,value
                  ,last-index
                  (,empty-hook))))]
          ["enum"
            `(stdlib.serialize.encode-enum-dispatch
              ,format-expr
              ,value-type
              ,nested-alias
              ,value
              0)]
          [_
            (comptime.comptime-error
              (comptime.string-append "serialize: unsupported type " value-key))])])))

;: Emit the decoded value expression for one supported value type.
(defmacro (decode-value
  [format : Module]
  [value-type : type]
  [nested-alias : comptime.Expr]
  [value : comptime.Expr]
  [err-ctor : comptime.Expr]) : comptime.Expr
  (let
    [nested-alias-text : String
      (match nested-alias
        [(comptime.ExprVar found) found]
        [_ (comptime.comptime-error "serialize: nested alias must be a name")])]
    [value-key : String (type-key value-type)]
    [value-kind : String (type-kind value-type)]
    [format-expr : comptime.Expr
      (comptime.expr-var (comptime.module-name format))]
    (match value-key
      ["bool"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-bool")]
          `(,hook ,value ,err-ctor))]
      ["String"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-string")]
          `(,hook ,value ,err-ctor))]
      ["i64"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["i32"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["i16"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["i8"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["u64"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["u32"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["u16"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["u8"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-int")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["f64"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-float")]
          `(,hook ,value-type ,value ,err-ctor))]
      ["f32"
        (let
          [hook : comptime.Expr (comptime.module-hook format "decode-float")]
          `(,hook ,value-type ,value ,err-ctor))]
      [_
        (match value-kind
          ["struct"
            (let
              [nested-decode : comptime.Expr
                (comptime.expr-var
                  (comptime.string-append nested-alias-text ".decode"))]
              `(let
                [__serialize_nested_result (,nested-decode ,value)]
                (match __serialize_nested_result
                  [(Ok parsed) parsed]
                  [(Err err) (return (,err-ctor err))])))]
          ["array"
            (let
              [element-type : comptime.Expr (array-element-type value-type)]
              [element-alias : String
                (comptime.string-append nested-alias-text "_elem")]
              [length-hook : comptime.Expr
                (comptime.module-hook format "sequence-length")]
              [element-hook : comptime.Expr
                (comptime.module-hook format "sequence-element-value")]
              [length-expr : comptime.Expr
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
              [element-type : comptime.Expr (array-element-type value-type)]
              [element-alias : String
                (comptime.string-append nested-alias-text "_elem")]
              [length-hook : comptime.Expr
                (comptime.module-hook format "sequence-length")]
              [element-hook : comptime.Expr
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
          ["tuple"
            (let
              [length-hook : comptime.Expr
                (comptime.module-hook format "sequence-length")]
              [length-expr : comptime.Expr
                (comptime.expr-int (tuple-element-count value-type))]
              `(let
                [__serialize_count : i64 (,length-hook ,value ,err-ctor)]
                (begin
                  (if (!= __serialize_count ,length-expr)
                    (return (,err-ctor "serialize: sequence length mismatch"))
                    unit)
                  (stdlib.serialize.decode-tuple-items
                    ,format-expr
                    ,value-type
                    ,nested-alias
                    ,value
                    ,err-ctor
                    0))))]
          ["enum"
            (let
              [expect-object-hook : comptime.Expr
                (comptime.module-hook format "expect-object")]
              [field-value-hook : comptime.Expr
                (comptime.module-hook format "field-value")]
              [decode-string-hook : comptime.Expr
                (comptime.module-hook format "decode-string")]
              [format-expr : comptime.Expr
                (comptime.expr-var (comptime.module-name format))]
              [type-name : String (type-nominal-name value-type)]
              `(begin
                (,expect-object-hook
                  ,value
                  ,(comptime.expr-string type-name)
                  ,err-ctor)
                (let
                  [__serialize_tag_value
                    (,field-value-hook
                      ,value
                      ,(comptime.expr-string "tag")
                      ,err-ctor)]
                  [__serialize_payload_value
                    (,field-value-hook
                      ,value
                      ,(comptime.expr-string "payload")
                      ,err-ctor)]
                  [__serialize_tag : String
                    (,decode-string-hook __serialize_tag_value ,err-ctor)]
                  (stdlib.serialize.decode-enum-variants
                    ,format-expr
                    ,value-type
                    ,nested-alias
                    __serialize_payload_value
                    ,err-ctor
                    __serialize_tag
                    0))))]
          [_
            (comptime.comptime-error
              (comptime.string-append "serialize: unsupported type " value-key))])])))

;: Emit the encoded value expression for one struct field.
(defmacro (encode-field
  [format : Module]
  [T : type]
  [index-expr : comptime.Expr]
  [value : comptime.Expr]) : comptime.Expr
  (match index-expr
    [(comptime.ExprInt index)
      (let
        [field-name : String (struct-field-name T index)]
        [field-type : comptime.Expr (struct-field-type T index)]
        [field-access : comptime.Expr
          (comptime.expr-struct-get value field-name)]
        [nested-alias-text : String
          (comptime.string-append
            "__serialize_nested_f"
            (comptime.int->string index))]
        [format-expr : comptime.Expr
          (comptime.expr-var (comptime.module-name format))]
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
  [index-expr : comptime.Expr]
  [value : comptime.Expr]) : comptime.Expr
  (match index-expr
    [(comptime.ExprInt index)
      (if (>= index (struct-field-count T))
        (let
          [empty-hook : comptime.Expr
            (comptime.module-hook format "object-empty")]
          `(,empty-hook))
        (let
          [field-hook : comptime.Expr
            (comptime.module-hook format "object-field")]
          [field-name : String (struct-field-name T index)]
          [field-key-expr : comptime.Expr (comptime.expr-string field-name)]
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
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
  [index-expr : comptime.Expr]
  [value : comptime.Expr]
  [out : comptime.Expr]
  [err-ctor : comptime.Expr]) : comptime.Expr
  (match index-expr
    [(comptime.ExprInt index)
      (let
        [field-name : String (struct-field-name T index)]
        [field-type : comptime.Expr (struct-field-type T index)]
        [field-key-expr : comptime.Expr (comptime.expr-string field-name)]
        [field-value-hook : comptime.Expr
          (comptime.module-hook format "field-value")]
        [nested-alias-text : String
          (comptime.string-append
            "__serialize_nested_f"
            (comptime.int->string index))]
        [format-expr : comptime.Expr
          (comptime.expr-var (comptime.module-name format))]
        [decoded-expr : comptime.Expr
          `(stdlib.serialize.decode-value
            ,format-expr
            ,field-type
            ,(comptime.expr-var nested-alias-text)
            __serialize_field
            ,err-ctor)]
        [set-expr : comptime.Expr
          (comptime.expr-struct-set out field-name decoded-expr)]
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
  [index-expr : comptime.Expr]
  [value : comptime.Expr]
  [out : comptime.Expr]
  [err-ctor : comptime.Expr]) : comptime.Expr
  (match index-expr
    [(comptime.ExprInt index)
      (if (>= index (struct-field-count T))
        `unit
        (let
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
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

;: Emit the source-module import needed to construct enum variants on decode.
(defmacro (enum-source-import [enum-type : type] [nested-alias : comptime.Expr]) : Decls
  (let
    [enum-module : String (type-nominal-module enum-type)]
    [source-alias : comptime.Expr
      (match nested-alias
        [(comptime.ExprVar nested-alias-text)
          (comptime.expr-var
            (comptime.string-append nested-alias-text "_enum_source"))]
        [_ (comptime.comptime-error "serialize: nested alias must be a name")])]
    (if (string.eq enum-module "")
      `(begin)
      `(import ,(comptime.expr-var enum-module) as ,source-alias))))

;: Emit one recursive generated serializer import needed by a nested value type.
(defmacro (nested-import-for-type
  [format : Module]
  [value-type : type]
  [nested-alias : comptime.Expr]) : Decls
  (let
    [nested-alias-text : String
      (match nested-alias
        [(comptime.ExprVar found) found]
        [_ (comptime.comptime-error "serialize: nested alias must be a name")])]
    [value-kind : String (type-kind value-type)]
    [format-expr : comptime.Expr
      (comptime.expr-var (comptime.module-name format))]
    (match value-kind
      ["struct"
        `(import (stdlib.serialize.serialize ,format-expr ,value-type) as ,nested-alias)]
      ["array"
        (let
          [element-type : comptime.Expr (array-element-type value-type)]
          [element-alias : String
            (comptime.string-append nested-alias-text "_elem")]
          `(stdlib.serialize.nested-import-for-type
            ,format-expr
            ,element-type
            ,(comptime.expr-var element-alias)))]
      ["dyn-array"
        (let
          [element-type : comptime.Expr (array-element-type value-type)]
          [element-alias : String
            (comptime.string-append nested-alias-text "_elem")]
          `(stdlib.serialize.nested-import-for-type
            ,format-expr
            ,element-type
            ,(comptime.expr-var element-alias)))]
      ["tuple"
        `(stdlib.serialize.nested-imports-for-tuple
          ,format-expr
          ,value-type
          ,nested-alias
          0)]
      ["enum"
        `(begin
          (stdlib.serialize.enum-source-import ,value-type ,nested-alias)
          (stdlib.serialize.nested-imports-for-enum
            ,format-expr
            ,value-type
            ,nested-alias
            0))]
      [_ `(begin)])))

;: Emit recursive generated serializer imports needed for tuple element types.
(defmacro (nested-imports-for-tuple
  [format : Module]
  [tuple-type : type]
  [nested-alias : comptime.Expr]
  [index-expr : comptime.Expr]) : Decls
  (match index-expr
    [(comptime.ExprInt index)
      (if (>= index (tuple-element-count tuple-type))
        `(begin)
        (let
          [element-type : comptime.Expr (tuple-element-type tuple-type index)]
          [element-alias : comptime.Expr
            (match nested-alias
              [(comptime.ExprVar nested-alias-text)
                (comptime.expr-var
                  (comptime.string-append
                    (comptime.string-append nested-alias-text "_tuple_")
                    (comptime.int->string index)))]
              [_
                (comptime.comptime-error
                  "serialize: nested alias must be a name")])]
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          `(begin
            (stdlib.serialize.nested-imports-for-tuple
              ,format-expr
              ,tuple-type
              ,nested-alias
              ,next-index)
            (stdlib.serialize.nested-import-for-type
              ,format-expr
              ,element-type
              ,element-alias))))]
    [_
      (comptime.comptime-error
        "serialize: nested tuple import index must be an integer literal")]))

;: Emit recursive generated serializer imports needed for enum payload types.
(defmacro (nested-imports-for-enum-payloads
  [format : Module]
  [enum-type : type]
  [nested-alias : comptime.Expr]
  [variant-index-expr : comptime.Expr]
  [payload-index-expr : comptime.Expr]) : Decls
  (match variant-index-expr
    [(comptime.ExprInt variant-index)
      (match payload-index-expr
        [(comptime.ExprInt payload-index)
          (if (>=
            payload-index
            (enum-variant-payload-count enum-type variant-index))
            `(begin)
            (let
              [payload-type : comptime.Expr
                (enum-variant-payload-type
                  enum-type
                  variant-index
                  payload-index)]
              [payload-alias : comptime.Expr
                (match nested-alias
                  [(comptime.ExprVar nested-alias-text)
                    (comptime.expr-var
                      (comptime.string-append
                        (comptime.string-append
                          (comptime.string-append
                            (comptime.string-append
                              nested-alias-text
                              "_variant_")
                            (comptime.int->string variant-index))
                          "_payload_")
                        (comptime.int->string payload-index)))]
                  [_
                    (comptime.comptime-error
                      "serialize: nested alias must be a name")])]
              [format-expr : comptime.Expr
                (comptime.expr-var (comptime.module-name format))]
              [next-index : comptime.Expr
                (comptime.expr-int (+ payload-index 1))]
              `(begin
                (stdlib.serialize.nested-imports-for-enum-payloads
                  ,format-expr
                  ,enum-type
                  ,nested-alias
                  ,variant-index-expr
                  ,next-index)
                (stdlib.serialize.nested-import-for-type
                  ,format-expr
                  ,payload-type
                  ,payload-alias))))]
        [_
          (comptime.comptime-error
            "serialize: nested enum payload index must be an integer literal")])]
    [_
      (comptime.comptime-error
        "serialize: nested enum variant index must be an integer literal")]))

;: Emit recursive generated serializer imports needed for all enum variants.
(defmacro (nested-imports-for-enum
  [format : Module]
  [enum-type : type]
  [nested-alias : comptime.Expr]
  [variant-index-expr : comptime.Expr]) : Decls
  (match variant-index-expr
    [(comptime.ExprInt variant-index)
      (if (>= variant-index (enum-variant-count enum-type))
        `(begin)
        (let
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
          [next-index : comptime.Expr (comptime.expr-int (+ variant-index 1))]
          `(begin
            (stdlib.serialize.nested-imports-for-enum
              ,format-expr
              ,enum-type
              ,nested-alias
              ,next-index)
            (stdlib.serialize.nested-imports-for-enum-payloads
              ,format-expr
              ,enum-type
              ,nested-alias
              ,variant-index-expr
              0))))]
    [_
      (comptime.comptime-error
        "serialize: nested enum import index must be an integer literal")]))

;: Emit recursive generated serializer imports needed for nested struct fields.
(defmacro (nested-imports
  [format : Module]
  [T : type]
  [index-expr : comptime.Expr]) : Decls
  (match index-expr
    [(comptime.ExprInt index)
      (if (>= index (struct-field-count T))
        `(begin)
        (let
          [field-type : comptime.Expr (struct-field-type T index)]
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          [format-expr : comptime.Expr
            (comptime.expr-var (comptime.module-name format))]
          [nested-alias-text : String
            (comptime.string-append
              "__serialize_nested_f"
              (comptime.int->string index))]
          `(begin
            (stdlib.serialize.nested-imports ,format-expr ,T ,next-index)
            (stdlib.serialize.nested-import-for-type
              ,format-expr
              ,field-type
              ,(comptime.expr-var nested-alias-text)))))]
    [_
      (comptime.comptime-error
        "serialize: nested import index must be an integer literal")]))

;: Emit generic encode/decode helpers for type `T` and strategy `format`.
(defmacro (serialize [format : Module] [T : type]) : Module
  (let
    [root-key : String (type-key T)]
    [root-kind : String (type-kind T)]
    [root-supported : bool
      (match root-key
        ["bool" true]
        ["String" true]
        ["i64" true]
        ["i32" true]
        ["i16" true]
        ["i8" true]
        ["u64" true]
        ["u32" true]
        ["u16" true]
        ["u8" true]
        ["f64" true]
        ["f32" true]
        [_
          (if (string.eq root-kind "struct")
            true
            (if (string.eq root-kind "array")
              true
              (if (string.eq root-kind "dyn-array")
                true
                (string.eq root-kind "enum"))))])]
    (if root-supported
      (let
        [format-name : String (comptime.module-name format)]
        [root-module-suffix : String
          (if (string.eq root-kind "enum")
            (let
              [enum-module : String (type-nominal-module T)]
              [enum-name : String (type-nominal-name T)]
              (if (string.eq enum-module "")
                enum-name
                (comptime.string-append
                  enum-module
                  (comptime.string-append "." enum-name))))
            root-key)]
        [module-name-text : String
          (comptime.string-append
            (comptime.string-append
              (comptime.string-append "stdlib.serialize.generated." format-name)
              ".")
            root-module-suffix)]
        [module-name-expr : comptime.Expr (comptime.expr-var module-name-text)]
        [format-module-expr : comptime.Expr (comptime.expr-var format-name)]
        [value-type : comptime.Expr
          (comptime.expr-var "__serialize_format.Value")]
        [ok-ctor : comptime.Expr
          (comptime.expr-var (comptime.string-append module-name-text ".Ok"))]
        [err-ctor : comptime.Expr
          (comptime.expr-var (comptime.string-append module-name-text ".Err"))]
        (match root-kind
          ["struct"
            (let
              [object-finish-hook : comptime.Expr
                (comptime.module-hook format "object-finish")]
              [expect-object-hook : comptime.Expr
                (comptime.module-hook format "expect-object")]
              [extra-decls-hook : comptime.Expr
                (comptime.module-hook format "extra-decls")]
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
                    (stdlib.serialize.encode-fields
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
            (let
              [root-alias : comptime.Expr
                (comptime.expr-var "__serialize_root")]
              [extra-decls-hook : comptime.Expr
                (comptime.module-hook format "extra-decls")]
              `(begin
                (module ,module-name-expr)
                (import stdlib.serialize)
                (import ,format-module-expr as __serialize_format)
                (stdlib.serialize.nested-import-for-type
                  ,format-module-expr
                  ,T
                  ,root-alias)
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
                  (stdlib.serialize.encode-value
                    ,format-module-expr
                    ,T
                    ,root-alias
                    value))
                (define (decode [value : ,value-type]) : Result
                  (,ok-ctor
                    (stdlib.serialize.decode-value
                      ,format-module-expr
                      ,T
                      ,root-alias
                      value
                      ,err-ctor)))
                (,extra-decls-hook ,T)))]))
      (comptime.comptime-error
        (comptime.string-append "serialize: unsupported root type " root-key)))))