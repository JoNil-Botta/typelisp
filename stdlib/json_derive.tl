;# JSON derive module macros.
;#
;# Usage:
;#
;# ```typelisp
;# (import stdlib.json)
;# (import stdlib.json_derive)
;# (defstruct Person
;#   (name String))
;# (import (json_derive.json-derive Person) as person_json)
;# ```
(module stdlib.json_derive)

(import stdlib.comptime)
(import stdlib.json)
(import stdlib.string)

;: Emit the JSON value expression for one struct field.
(defmacro (json-derive-field-to-json
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
        [field-access : Expr (expr-struct-get value field-name)]
        (match field-key
          ["bool" `(json.JsonBool ,field-access)]
          ["String" `(json.JsonString ,field-access)]
          ["i64" `(json.json-i64->number ,field-access)]
          ["i32" `(json.json-i64->number (cast ,field-access : i64))]
          ["i16" `(json.json-i64->number (cast ,field-access : i64))]
          ["i8" `(json.json-i64->number (cast ,field-access : i64))]
          ["u32" `(json.json-i64->number (cast ,field-access : i64))]
          ["u16" `(json.json-i64->number (cast ,field-access : i64))]
          ["u8" `(json.json-i64->number (cast ,field-access : i64))]
          [_
            (match field-kind
              ["struct"
                (let
                  [nested-to : Expr
                    (expr-var
                      (string-append
                        (string-append "__json_nested_" (int->string index))
                        ".to-json"))]
                  `(,nested-to ,field-access))]
              [_
                (comptime.comptime-error
                  (string-append
                    (string-append "json-derive: unsupported field " field-name)
                    (string-append " type " field-key)))])]))]
    [_
      (comptime.comptime-error
        "json-derive: field index must be an integer literal")]))

;: Emit the object member list expression for struct fields.
(defmacro (json-derive-members [T : type] [index-expr : Expr] [value : Expr]) : Expr
  (match index-expr
    [(ExprInt index)
      (if (>= index (struct-field-count T))
        `json.JsonMemberListNil
        (let
          [field-name : String (struct-field-name T index)]
          [field-key-expr : Expr (expr-string field-name)]
          [next-index : Expr (expr-int (+ index 1))]
          `(json.JsonMemberListCons
            ,field-key-expr
            (stdlib.json_derive.json-derive-field-to-json
              ,T
              ,(expr-int index)
              ,value)
            (box (stdlib.json_derive.json-derive-members ,T ,next-index ,value)))))]
    [_
      (comptime.comptime-error
        "json-derive: member index must be an integer literal")]))

;: Emit integer field parsing with generated range checks.
(defmacro (json-derive-parse-int-field
  [T : type]
  [index-expr : Expr]
  [json-value : Expr]
  [out : Expr]
  [err-ctor : Expr]) : Expr
  (match index-expr
    [(ExprInt index)
      (let
        [field-name : String (struct-field-name T index)]
        [field-type : Expr (struct-field-type T index)]
        [field-key : String (type-key field-type)]
        [kind-error : Expr
          (expr-string
            (string-append
              (string-append "json-derive: field " field-name)
              (string-append " expected " field-key)))]
        [invalid-prefix : Expr
          (expr-string
            (string-append
              (string-append "json-derive: field " field-name)
              (string-append " invalid " (string-append field-key ": "))))]
        [range-error : Expr
          (expr-string
            (string-append
              (string-append "json-derive: field " field-name)
              (string-append " outside " (string-append field-key " range"))))]
        [set-parsed : Expr (expr-struct-set out field-name `parsed)]
        [set-cast-parsed : Expr
          (expr-struct-set out field-name `(cast parsed : ,field-type))]
        [min-expr : Expr
          (match field-key
            ["i32" (expr-int (- 0 2147483648))]
            ["i16" (expr-int (- 0 32768))]
            ["i8" (expr-int (- 0 128))]
            [_ (expr-int 0)])]
        [max-expr : Expr
          (match field-key
            ["i32" (expr-int 2147483647)]
            ["i16" (expr-int 32767)]
            ["i8" (expr-int 127)]
            ["u32" (expr-int 4294967295)]
            ["u16" (expr-int 65535)]
            ["u8" (expr-int 255)]
            [_ (expr-int 9223372036854775807)])]
        [set-expr : Expr
          (if (string=? field-key "i64")
            set-parsed
            `(if (if (< parsed ,min-expr)
              true
              (> parsed ,max-expr))
              (return (,err-ctor ,range-error))
              ,set-cast-parsed))]
        `(match ,json-value
          [(json.JsonNumber text)
            (match (json.json-number-owned->i64 text)
              [(json.OkJsonNumberI64 parsed) ,set-expr]
              [(json.ErrJsonNumberI64 err)
                (return (,err-ctor (string.string-append ,invalid-prefix err)))])]
          [_ (return (,err-ctor ,kind-error))]))]
    [_
      (comptime.comptime-error
        "json-derive: int parse index must be an integer literal")]))

;: Emit decode logic for one struct field.
(defmacro (json-derive-parse-field
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
        [field-key-expr : Expr (expr-string field-name)]
        [missing-error : Expr
          (expr-string (string-append "json-derive: missing field " field-name))]
        [kind-error : Expr
          (expr-string
            (string-append
              (string-append "json-derive: field " field-name)
              (string-append " expected " field-key)))]
        [invalid-prefix : Expr
          (expr-string
            (string-append
              (string-append "json-derive: field " field-name)
              (string-append " invalid " (string-append field-key ": "))))]
        [range-error : Expr
          (expr-string
            (string-append
              (string-append "json-derive: field " field-name)
              (string-append " outside " (string-append field-key " range"))))]
        [set-parsed : Expr (expr-struct-set out field-name `parsed)]
        [set-cast-parsed : Expr
          (expr-struct-set out field-name `(cast parsed : ,field-type))]
        [min-expr : Expr
          (match field-key
            ["i32" (expr-int (- 0 2147483648))]
            ["i16" (expr-int (- 0 32768))]
            ["i8" (expr-int (- 0 128))]
            [_ (expr-int 0)])]
        [max-expr : Expr
          (match field-key
            ["i32" (expr-int 2147483647)]
            ["i16" (expr-int 32767)]
            ["i8" (expr-int 127)]
            ["u32" (expr-int 4294967295)]
            ["u16" (expr-int 65535)]
            ["u8" (expr-int 255)]
            [_ (expr-int 9223372036854775807)])]
        (match field-key
          ["bool"
            `(let
              [__json_key : String ,field-key-expr]
              (match (json.json-object-get-owned ,value __json_key)
                [(json.JsonFound __json_value)
                  (match __json_value
                    [(json.JsonBool parsed) ,set-parsed]
                    [_ (return (,err-ctor ,kind-error))])]
                [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
          ["String"
            `(let
              [__json_key : String ,field-key-expr]
              (match (json.json-object-get-owned ,value __json_key)
                [(json.JsonFound __json_value)
                  (match __json_value
                    [(json.JsonString parsed) ,set-parsed]
                    [_ (return (,err-ctor ,kind-error))])]
                [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
          ["i64"
            `(let
              [__json_key : String ,field-key-expr]
              (match (json.json-object-get-owned ,value __json_key)
                [(json.JsonFound __json_value)
                  (match __json_value
                    [(json.JsonNumber text)
                      (match (json.json-number-owned->i64 text)
                        [(json.OkJsonNumberI64 parsed) ,set-parsed]
                        [(json.ErrJsonNumberI64 err)
                          (return
                            (,err-ctor
                              (string.string-append ,invalid-prefix err)))])]
                    [_ (return (,err-ctor ,kind-error))])]
                [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
          [_
            (match field-key
              ["i32"
                `(let
                  [__json_key : String ,field-key-expr]
                  (match (json.json-object-get-owned ,value __json_key)
                    [(json.JsonFound __json_value)
                      (match __json_value
                        [(json.JsonNumber text)
                          (match (json.json-number-owned->i64 text)
                            [(json.OkJsonNumberI64 parsed)
                              (if (if (< parsed ,min-expr)
                                true
                                (> parsed ,max-expr))
                                (return (,err-ctor ,range-error))
                                ,set-cast-parsed)]
                            [(json.ErrJsonNumberI64 err)
                              (return
                                (,err-ctor
                                  (string.string-append ,invalid-prefix err)))])]
                        [_ (return (,err-ctor ,kind-error))])]
                    [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
              ["i16"
                `(let
                  [__json_key : String ,field-key-expr]
                  (match (json.json-object-get-owned ,value __json_key)
                    [(json.JsonFound __json_value)
                      (match __json_value
                        [(json.JsonNumber text)
                          (match (json.json-number-owned->i64 text)
                            [(json.OkJsonNumberI64 parsed)
                              (if (if (< parsed ,min-expr)
                                true
                                (> parsed ,max-expr))
                                (return (,err-ctor ,range-error))
                                ,set-cast-parsed)]
                            [(json.ErrJsonNumberI64 err)
                              (return
                                (,err-ctor
                                  (string.string-append ,invalid-prefix err)))])]
                        [_ (return (,err-ctor ,kind-error))])]
                    [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
              ["i8"
                `(let
                  [__json_key : String ,field-key-expr]
                  (match (json.json-object-get-owned ,value __json_key)
                    [(json.JsonFound __json_value)
                      (match __json_value
                        [(json.JsonNumber text)
                          (match (json.json-number-owned->i64 text)
                            [(json.OkJsonNumberI64 parsed)
                              (if (if (< parsed ,min-expr)
                                true
                                (> parsed ,max-expr))
                                (return (,err-ctor ,range-error))
                                ,set-cast-parsed)]
                            [(json.ErrJsonNumberI64 err)
                              (return
                                (,err-ctor
                                  (string.string-append ,invalid-prefix err)))])]
                        [_ (return (,err-ctor ,kind-error))])]
                    [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
              ["u32"
                `(let
                  [__json_key : String ,field-key-expr]
                  (match (json.json-object-get-owned ,value __json_key)
                    [(json.JsonFound __json_value)
                      (match __json_value
                        [(json.JsonNumber text)
                          (match (json.json-number-owned->i64 text)
                            [(json.OkJsonNumberI64 parsed)
                              (if (if (< parsed ,min-expr)
                                true
                                (> parsed ,max-expr))
                                (return (,err-ctor ,range-error))
                                ,set-cast-parsed)]
                            [(json.ErrJsonNumberI64 err)
                              (return
                                (,err-ctor
                                  (string.string-append ,invalid-prefix err)))])]
                        [_ (return (,err-ctor ,kind-error))])]
                    [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
              ["u16"
                `(let
                  [__json_key : String ,field-key-expr]
                  (match (json.json-object-get-owned ,value __json_key)
                    [(json.JsonFound __json_value)
                      (match __json_value
                        [(json.JsonNumber text)
                          (match (json.json-number-owned->i64 text)
                            [(json.OkJsonNumberI64 parsed)
                              (if (if (< parsed ,min-expr)
                                true
                                (> parsed ,max-expr))
                                (return (,err-ctor ,range-error))
                                ,set-cast-parsed)]
                            [(json.ErrJsonNumberI64 err)
                              (return
                                (,err-ctor
                                  (string.string-append ,invalid-prefix err)))])]
                        [_ (return (,err-ctor ,kind-error))])]
                    [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
              ["u8"
                `(let
                  [__json_key : String ,field-key-expr]
                  (match (json.json-object-get-owned ,value __json_key)
                    [(json.JsonFound __json_value)
                      (match __json_value
                        [(json.JsonNumber text)
                          (match (json.json-number-owned->i64 text)
                            [(json.OkJsonNumberI64 parsed)
                              (if (if (< parsed ,min-expr)
                                true
                                (> parsed ,max-expr))
                                (return (,err-ctor ,range-error))
                                ,set-cast-parsed)]
                            [(json.ErrJsonNumberI64 err)
                              (return
                                (,err-ctor
                                  (string.string-append ,invalid-prefix err)))])]
                        [_ (return (,err-ctor ,kind-error))])]
                    [(json.JsonMissing) (return (,err-ctor ,missing-error))]))]
              [_
                (match field-kind
                  ["struct"
                    (let
                      [nested-alias-text : String
                        (string-append "__json_nested_" (int->string index))]
                      [__json_nested_result_type : Expr
                        (expr-var (string-append nested-alias-text ".Result"))]
                      [nested-from : Expr
                        (expr-var
                          (string-append nested-alias-text ".from-json"))]
                      [nested-type-name : String (type-nominal-name field-type)]
                      [nested-invalid-prefix : Expr
                        (expr-string
                          (string-append
                            (string-append "json-derive: field " field-name)
                            (string-append
                              " invalid "
                              (string-append nested-type-name ": "))))]
                      `(let
                        [__json_key : String ,field-key-expr]
                        (match (json.json-object-get-owned ,value __json_key)
                          [(json.JsonFound __json_value)
                            (let
                              [__json_nested_result : ,__json_nested_result_type
                                (,nested-from __json_value)]
                              (match __json_nested_result
                                [(Ok parsed) ,set-parsed]
                                [(Err err)
                                  (return
                                    (,err-ctor
                                      (string.string-append
                                        ,nested-invalid-prefix
                                        err)))]))]
                          [(json.JsonMissing)
                            (return (,err-ctor ,missing-error))])))]
                  [_
                    (comptime.comptime-error
                      (string-append
                        (string-append
                          "json-derive: unsupported field "
                          field-name)
                        (string-append " type " field-key)))])])]))]
    [_
      (comptime.comptime-error
        "json-derive: parse index must be an integer literal")]))

;: Emit recursive decode logic for all struct fields.
(defmacro (json-derive-parse-fields
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
          [next-index : Expr (expr-int (+ index 1))]
          `(begin
            (stdlib.json_derive.json-derive-parse-field
              ,T
              ,(expr-int index)
              ,value
              ,out
              ,err-ctor)
            (stdlib.json_derive.json-derive-parse-fields
              ,T
              ,next-index
              ,value
              ,out
              ,err-ctor))))]
    [_
      (comptime.comptime-error
        "json-derive: parse-fields index must be an integer literal")]))

;: Emit derive imports needed for nested struct fields.
(defmacro (json-derive-nested-imports [T : type] [index-expr : Expr]) : Decls
  (match index-expr
    [(ExprInt index)
      (if (>= index (struct-field-count T))
        `(begin)
        (let
          [field-type : Expr (struct-field-type T index)]
          [field-kind : String (type-kind field-type)]
          [next-index : Expr (expr-int (+ index 1))]
          (match field-kind
            ["struct"
              (let
                [nested-alias : Expr
                  (expr-var
                    (string-append "__json_nested_" (int->string index)))]
                `(begin
                  (stdlib.json_derive.json-derive-nested-imports ,T ,next-index)
                  (import (json_derive.json-derive ,field-type) as ,nested-alias)))]
            [_ `(stdlib.json_derive.json-derive-nested-imports ,T ,next-index)])))]
    [_
      (comptime.comptime-error
        "json-derive: nested import index must be an integer literal")]))

;: Emit JSON encode/decode helpers for a supported struct type.
(defmacro (json-derive [T : type]) : Module
  (match (type-kind T)
    ["struct"
      (let
        [module-name-text : String
          (string-append "stdlib.json_derive.generated." (type-key T))]
        [module-name : Expr (expr-var module-name-text)]
        [ok-ctor : Expr (expr-var (string-append module-name-text ".Ok"))]
        [err-ctor : Expr (expr-var (string-append module-name-text ".Err"))]
        [json-type : Expr (expr-var "json.Json")]
        [type-name : String (type-nominal-name T)]
        `(begin
          (module ,module-name)
          (import stdlib.json as json)
          (import stdlib.json_derive as json_derive)
          (import stdlib.string as string)
          (json_derive.json-derive-nested-imports ,T 0)
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
          (define (to-json [value : ,T]) : ,json-type
            (json.JsonObject
              (box (stdlib.json_derive.json-derive-members ,T 0 value))))
          (define (from-json [value : ,json-type]) : Result
            (match value
              [(json.JsonObject _)
                (let
                  [__json_out : ,T (init : ,T)]
                  (begin
                    (stdlib.json_derive.json-derive-parse-fields
                      ,T
                      0
                      value
                      __json_out
                      ,err-ctor)
                    (,ok-ctor __json_out)))]
              [_
                (,err-ctor
                  ,(expr-string
                    (string-append
                      "json-derive: expected object for "
                      type-name)))]))))]
    [_
      (comptime.comptime-error
        (string-append "json-derive: expected struct type, got " (type-key T)))]))