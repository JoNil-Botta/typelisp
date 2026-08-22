;# Rust-style literal format-string macro returning a fresh String.
;#
;# `format` parses a string-literal template during macro expansion. It supports
;# implicit `{}`, indexed `{0}`, explicit named, and call-site-captured `{name}`
;# selections; escapes use `{{` / `}}`. The generated expression evaluates each
;# supplied value once and uses one flat `str-cat` expansion.
;#
;# Nominal structs and enums participate through their canonical owner module.
;# A module's common primary type defines `to-string`; additional nominal types
;# use `to-string-<NominalName>`. A hook must have the exact shared-borrow
;# signature `(& T) -> String`. Defining both applicable spellings is rejected
;# as ambiguous.
;#
;# ```lisp test=run name=format-basic exit=42 stdout=""
;# (import stdlib.format)
;# (import stdlib.string)
;#
;# (define (main) : i64
;#   (let [name : String "Ada"]
;#     (if (string.eq (format.format "hello, {}" name) "hello, Ada") 42 1)))
;# ```
;#
;# Builtin placeholder values are `String`, `i64`, `bool`, `char`, `f64`, and
;# `f32`. Structural formatting is intentionally separate from this default
;# Display-style protocol.
(import stdlib.array)
(import stdlib.comptime)
(import stdlib.str_cat)
(import stdlib.string)

;: Runtime panic entry used by formatting without depending on `stdlib.io`.
;:
;: `tl_abort_string` accepts the same two-word string handle for owned `String`
;: and borrowed `str`; this declaration intentionally takes the owned form so
;: importing formatting does not introduce reference-typed runtime ABI state.
(extern (format-runtime-abort-string [message : String]) : never (:symbol "tl_abort_string"))

;: Render one supported ASCII/control character as a String for formatting.
(define (format-char-string [value : char]) : String
  (let
    [code : i64 (cast value : i64)]
    [printable : String
      " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"]
    (cond
      [(= code 9) "\t"]
      [(= code 10) "\n"]
      [(= code 13) "\r"]
      [(and (>= code 32) (<= code 126))
        (string.substring printable (- code 32) 1)]
      [else
        (format-runtime-abort-string "format: unsupported non-printable char")])))

;; The deterministic pure-TypeLisp f64 renderer is defined below the template
;; parser. Keeping it in this module makes `stdlib.format` independent of I/O.
;: Render one supported format placeholder through the shared dispatch path.
(defmacro (format-value [value : comptime.Expr]) : String
  (let
    [argument-type : comptime.Expr (comptime.expr-type value)]
    [argument-kind : String (type-kind argument-type)]
    [nominal? : bool
      (match argument-kind
        ["struct" true]
        ["enum" true]
        ["region" true]
        [_ false])]
    [value-key : String (type-key argument-type)]
    [owner : String
      (if nominal?
        (type-nominal-module argument-type)
        "")]
    [nominal-name : String
      (if nominal?
        (type-nominal-name argument-type)
        "")]
    [plain-name : String "to-string"]
    [qualified-name : String (comptime.string-append "to-string-" nominal-name)]
    [plain-present? : bool
      (if nominal?
        (comptime.module-value? owner plain-name)
        false)]
    [qualified-present? : bool
      (if nominal?
        (comptime.module-value? owner qualified-name)
        false)]
    [plain-contract : String
      (comptime.string-append
        owner
        (comptime.string-append
          ".to-string : (-> (& "
          (comptime.string-append value-key ") String)")))]
    [qualified-contract : String
      (comptime.string-append
        owner
        (comptime.string-append
          "."
          (comptime.string-append
            qualified-name
            (comptime.string-append
              " : (-> (& "
              (comptime.string-append value-key ") String)")))))]
    [expected-contract : String
      (comptime.string-append
        plain-contract
        (comptime.string-append " or " qualified-contract))]
    [plain-matches? : bool
      (if plain-present?
        (comptime.function-shared-borrow-returns-string?
          (comptime.module-value-type owner plain-name)
          argument-type)
        false)]
    [qualified-matches? : bool
      (if qualified-present?
        (comptime.function-shared-borrow-returns-string?
          (comptime.module-value-type owner qualified-name)
          argument-type)
        false)]
    [hook-dispatch : i64
      (+
        (if plain-matches?
          1
          0)
        (if qualified-matches?
          2
          0))]
    [hook-present? : bool
      (if plain-present?
        true
        qualified-present?)]
    (if nominal?
      (match hook-dispatch
        [3
          (comptime.comptime-error
            (comptime.string-append
              "format: ambiguous owner hooks for "
              (comptime.string-append
                value-key
                (comptime.string-append
                  " in canonical module "
                  (comptime.string-append
                    owner
                    (comptime.string-append
                      "; define only one of "
                      expected-contract))))))]
        [1
          (comptime.expr-shared-call1
            (comptime.module-value-expr owner plain-name)
            value)]
        [2
          (comptime.expr-shared-call1
            (comptime.module-value-expr owner qualified-name)
            value)]
        [_
          (if hook-present?
            (comptime.comptime-error
              (comptime.string-append
                "format: owner hook has wrong signature for "
                (comptime.string-append
                  value-key
                  (comptime.string-append
                    " in canonical module "
                    (comptime.string-append
                      owner
                      (comptime.string-append "; expected " expected-contract))))))
            (comptime.comptime-error
              (comptime.string-append
                "format: unsupported nominal type "
                (comptime.string-append
                  value-key
                  (comptime.string-append
                    " from canonical owner module "
                    (comptime.string-append
                      owner
                      (comptime.string-append "; expected " expected-contract)))))))])
      (match argument-kind
        ["string" value]
        ["i64" `(stdlib.string.int->string ,value)]
        ["bool"
          `(if ,value
            "true"
            "false")]
        ["char" `(stdlib.format.format-char-string ,value)]
        ["f64" `(stdlib.format.format-float-core ,value)]
        ["f32" `(stdlib.format.format-float-core (cast ,value : f64))]
        [_
          (comptime.comptime-error
            (comptime.string-append
              "format: unsupported argument type "
              value-key))]))))

;: Mark one explicit named argument for `format`.
;:
;: This wrapper expands to private marker syntax consumed by `format`; using it
;: outside a format argument is invalid. Imported module aliases expand to the
;: same marker.
(defmacro (named [name : comptime.Expr] [value : comptime.Expr]) : comptime.Expr
  `(__tl_format_named_argument ,name ,value))

;: Classify and bind one direct format operand before continuing expansion.
;:
;: Matching the direct operand preserves a call callee's compiler-owned syntax
;: identity. The private marker emitted by `named` is consumed here; every other
;: call is reconstructed as an ordinary positional value.
(defmacro (format-expand-call
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [argument-index : comptime.Expr]
  [named-seen : comptime.Expr]
  [positional-vars : comptime.Expr]
  [named-names : comptime.Expr]
  [named-vars : comptime.Expr]
  [bindings : comptime.Expr]
  [argument : comptime.Expr]) : String
  (match argument-index
    [(comptime.Expr.Int index)
      (match named-seen
        [(comptime.Expr.Int named-state)
          (match positional-vars
            [(comptime.Expr.Call _ positional-items)
              (match named-names
                [(comptime.Expr.Call _ named-name-items)
                  (match named-vars
                    [(comptime.Expr.Call _ named-var-items)
                      (match bindings
                        [(comptime.Expr.Call _ binding-items)
                          (match argument
                            [(comptime.Expr.Call callee call-items)
                              (let
                                [callee-name : String
                                  (match callee
                                    [(comptime.Expr.Var found) found]
                                    [_ ""])]
                                [named-wrapper? : bool
                                  (string.eq
                                    callee-name
                                    "__tl_format_named_argument")]
                                (if named-wrapper?
                                  (if (!=
                                    (comptime.expr-list-length call-items)
                                    2)
                                    (comptime.comptime-error
                                      "format: named argument wrapper expects a name and value")
                                    (let
                                      [name-expr : comptime.Expr
                                        (comptime.expr-list-nth call-items 0)]
                                      [value-expr : comptime.Expr
                                        (comptime.expr-list-nth call-items 1)]
                                      [argument-name : String
                                        (match name-expr
                                          [(comptime.Expr.Var found) found]
                                          [_
                                            (comptime.comptime-error
                                              "format: named argument name must be an identifier")])]
                                      [duplicate? : bool false]
                                      [name-index : i64 0]
                                      (begin
                                        (if (string.eq argument-name "_")
                                          (comptime.comptime-error
                                            "format: bare '_' is not a named argument identifier")
                                          unit)
                                        (while (<
                                          name-index
                                          (comptime.expr-list-length
                                            named-name-items))
                                          (begin
                                            (if (string.eq
                                              (comptime.expr-string-value
                                                (comptime.expr-list-nth
                                                  named-name-items
                                                  name-index))
                                              argument-name)
                                              (set! duplicate? true)
                                              unit)
                                            (set! name-index (+ name-index 1))))
                                        (if duplicate?
                                          (comptime.comptime-error
                                            (comptime.string-append
                                              "format: duplicate named argument "
                                              argument-name))
                                          unit)
                                        (let
                                          [fresh-name : String
                                            (comptime.syntax-name-fresh
                                              (comptime.string-append
                                                "__tl_format_named_"
                                                (comptime.int->string index)))]
                                          [fresh-var : comptime.Expr
                                            (comptime.expr-var fresh-name)]
                                          `(stdlib.format.format-expand
                                            ,plan
                                            ,argument-carrier
                                            ,(comptime.expr-int (+ index 1))
                                            ,(comptime.expr-int 1)
                                            ,positional-vars
                                            (__tl_format_named_names
                                              ,@named-name-items
                                              ,(comptime.expr-string
                                                argument-name))
                                            (__tl_format_named_vars
                                              ,@named-var-items
                                              ,fresh-var)
                                            (__tl_format_bindings
                                              ,@binding-items
                                              ,(comptime.expr-begin-unit
                                                (comptime.expr-list-cons
                                                  fresh-var
                                                  (comptime.expr-list-cons
                                                    value-expr
                                                    (comptime.expr-list-empty))))))))))
                                  (if (!= named-state 0)
                                    (comptime.comptime-error
                                      "format: positional argument follows named argument")
                                    (let
                                      [fresh-name : String
                                        (comptime.syntax-name-fresh
                                          (comptime.string-append
                                            "__tl_format_positional_"
                                            (comptime.int->string index)))]
                                      [fresh-var : comptime.Expr
                                        (comptime.expr-var fresh-name)]
                                      [argument-value : comptime.Expr
                                        `(,callee ,@call-items)]
                                      `(stdlib.format.format-expand
                                        ,plan
                                        ,argument-carrier
                                        ,(comptime.expr-int (+ index 1))
                                        ,(comptime.expr-int 0)
                                        (__tl_format_positional_vars
                                          ,@positional-items
                                          ,fresh-var)
                                        ,named-names
                                        ,named-vars
                                        (__tl_format_bindings
                                          ,@binding-items
                                          ,(comptime.expr-begin-unit
                                            (comptime.expr-list-cons
                                              fresh-var
                                              (comptime.expr-list-cons
                                                argument-value
                                                (comptime.expr-list-empty))))))))))]
                            [_
                              (if (!= named-state 0)
                                (comptime.comptime-error
                                  "format: positional argument follows named argument")
                                (let
                                  [fresh-name : String
                                    (comptime.syntax-name-fresh
                                      (comptime.string-append
                                        "__tl_format_positional_"
                                        (comptime.int->string index)))]
                                  [fresh-var : comptime.Expr
                                    (comptime.expr-var fresh-name)]
                                  `(stdlib.format.format-expand
                                    ,plan
                                    ,argument-carrier
                                    ,(comptime.expr-int (+ index 1))
                                    ,(comptime.expr-int 0)
                                    (__tl_format_positional_vars
                                      ,@positional-items
                                      ,fresh-var)
                                    ,named-names
                                    ,named-vars
                                    (__tl_format_bindings
                                      ,@binding-items
                                      ,(comptime.expr-begin-unit
                                        (comptime.expr-list-cons
                                          fresh-var
                                          (comptime.expr-list-cons
                                            argument
                                            (comptime.expr-list-empty))))))))])]
                        [_
                          (comptime.comptime-error
                            "format: internal binding carrier is malformed")])]
                    [_
                      (comptime.comptime-error
                        "format: internal named variable carrier is malformed")])]
                [_
                  (comptime.comptime-error
                    "format: internal named argument carrier is malformed")])]
            [_
              (comptime.comptime-error
                "format: internal positional carrier is malformed")])]
        [_
          (comptime.comptime-error
            "format: internal named-argument state is malformed")])]
    [_
      (comptime.comptime-error
        "format: internal argument index is not an integer")]))

;: Bind supplied arguments, validate a completed plan, and emit one flat concat.
(defmacro (format-expand
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [argument-index : comptime.Expr]
  [named-seen : comptime.Expr]
  [positional-vars : comptime.Expr]
  [named-names : comptime.Expr]
  [named-vars : comptime.Expr]
  [bindings : comptime.Expr]) : String
  (match argument-index
    [(comptime.Expr.Int index)
      (match argument-carrier
        [(comptime.Expr.Call _ arguments)
          (if (< index (comptime.expr-list-length arguments))
            (let
              [argument : comptime.Expr
                (comptime.expr-list-nth arguments index)]
              `(stdlib.format.format-expand-call
                ,plan
                ,argument-carrier
                ,argument-index
                ,named-seen
                ,positional-vars
                ,named-names
                ,named-vars
                ,bindings
                ,argument))
            (match plan
              [(comptime.Expr.Call _ plan-pieces)
                (match positional-vars
                  [(comptime.Expr.Call _ positional-items)
                    (match named-names
                      [(comptime.Expr.Call _ named-name-items)
                        (match named-vars
                          [(comptime.Expr.Call _ named-var-items)
                            (match bindings
                              [(comptime.Expr.Call _ binding-items)
                                (let
                                  [plan-len : i64
                                    (comptime.expr-list-length plan-pieces)]
                                  [positional-count : i64
                                    (comptime.expr-list-length positional-items)]
                                  [capture-names : comptime.ExprList
                                    (comptime.expr-list-empty)]
                                  [capture-vars : comptime.ExprList
                                    (comptime.expr-list-empty)]
                                  [capture-bindings : comptime.ExprList
                                    (comptime.expr-list-empty)]
                                  [capture-count : i64 0]
                                  [plan-index : i64 (- plan-len 1)]
                                  (begin
                                    ;; Validate indices before selection. Calls
                                    ;; in the plan carry [index, implicit?].
                                    (while (>= plan-index 0)
                                      (let
                                        [piece : comptime.Expr
                                          (comptime.expr-list-nth
                                            plan-pieces
                                            plan-index)]
                                        (begin
                                          (match piece
                                            [(comptime.Expr.Begin reference)
                                              (if (!=
                                                (comptime.expr-list-length
                                                  reference)
                                                3)
                                                (comptime.comptime-error
                                                  "format: internal positional plan is malformed")
                                                (match (comptime.expr-list-nth
                                                  reference
                                                  0)
                                                  [(comptime.Expr.Int selected)
                                                    (match (comptime.expr-list-nth
                                                      reference
                                                      1)
                                                      [(comptime.Expr.Int
                                                          implicit-state)
                                                        (if (>=
                                                          selected
                                                          positional-count)
                                                          (if (!=
                                                            implicit-state
                                                            0)
                                                            (comptime.comptime-error
                                                              "format: not enough arguments for placeholders")
                                                            (comptime.comptime-error
                                                              (comptime.string-append
                                                                "format: positional argument index is out of range: "
                                                                (comptime.int->string
                                                                  selected))))
                                                          unit)]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal positional mode is malformed")])]
                                                  [_
                                                    (comptime.comptime-error
                                                      "format: internal positional index is malformed")]))]
                                            [_ unit])
                                          (set! plan-index (- plan-index 1)))))
                                    ;; Every supplied positional argument is
                                    ;; used, even when explicit indices repeat.
                                    (let
                                      [positional-index : i64 0]
                                      (while (<
                                        positional-index
                                        positional-count)
                                        (let
                                          [used? : bool false]
                                          [piece-index : i64 0]
                                          (begin
                                            (while (< piece-index plan-len)
                                              (let
                                                [piece : comptime.Expr
                                                  (comptime.expr-list-nth
                                                    plan-pieces
                                                    piece-index)]
                                                (begin
                                                  (match piece
                                                    [(comptime.Expr.Begin
                                                        reference)
                                                      (if (=
                                                        (comptime.expr-list-length
                                                          reference)
                                                        3)
                                                        (match (comptime.expr-list-nth
                                                          reference
                                                          0)
                                                          [(comptime.Expr.Int
                                                              selected)
                                                            (if (=
                                                              selected
                                                              positional-index)
                                                              (set! used? true)
                                                              unit)]
                                                          [_ unit])
                                                        unit)]
                                                    [_ unit])
                                                  (set!
                                                    piece-index
                                                    (+ piece-index 1)))))
                                            (if (not used?)
                                              (comptime.comptime-error
                                                (comptime.string-append
                                                  "format: not enough placeholders for arguments; unused positional argument "
                                                  (comptime.int->string
                                                    positional-index)))
                                              unit)
                                            (set!
                                              positional-index
                                              (+ positional-index 1))))))
                                    ;; Explicit named arguments must also be
                                    ;; used. Missing names become captures.
                                    (let
                                      [named-index : i64 0]
                                      (while (<
                                        named-index
                                        (comptime.expr-list-length
                                          named-name-items))
                                        (let
                                          [name : String
                                            (comptime.expr-string-value
                                              (comptime.expr-list-nth
                                                named-name-items
                                                named-index))]
                                          [used? : bool false]
                                          [piece-index : i64 0]
                                          (begin
                                            (while (< piece-index plan-len)
                                              (let
                                                [piece : comptime.Expr
                                                  (comptime.expr-list-nth
                                                    plan-pieces
                                                    piece-index)]
                                                (begin
                                                  (match piece
                                                    [(comptime.Expr.Var found)
                                                      (if (string.eq found name)
                                                        (set! used? true)
                                                        unit)]
                                                    [_ unit])
                                                  (set!
                                                    piece-index
                                                    (+ piece-index 1)))))
                                            (if (not used?)
                                              (comptime.comptime-error
                                                (comptime.string-append
                                                  "format: unused named argument "
                                                  name))
                                              unit)
                                            (set! named-index (+ named-index 1))))))
                                    ;; Discover captures in template order.
                                    (set! plan-index (- plan-len 1))
                                    (while (>= plan-index 0)
                                      (let
                                        [piece : comptime.Expr
                                          (comptime.expr-list-nth
                                            plan-pieces
                                            plan-index)]
                                        (begin
                                          (match piece
                                            [(comptime.Expr.Var name)
                                              (let
                                                [explicit? : bool false]
                                                [known-capture? : bool false]
                                                [named-index : i64 0]
                                                [capture-index : i64 0]
                                                (begin
                                                  (while (<
                                                    named-index
                                                    (comptime.expr-list-length
                                                      named-name-items))
                                                    (begin
                                                      (if (string.eq
                                                        (comptime.expr-string-value
                                                          (comptime.expr-list-nth
                                                            named-name-items
                                                            named-index))
                                                        name)
                                                        (set! explicit? true)
                                                        unit)
                                                      (set!
                                                        named-index
                                                        (+ named-index 1))))
                                                  (while (<
                                                    capture-index
                                                    (comptime.expr-list-length
                                                      capture-names))
                                                    (begin
                                                      (if (string.eq
                                                        (comptime.expr-string-value
                                                          (comptime.expr-list-nth
                                                            capture-names
                                                            capture-index))
                                                        name)
                                                        (set!
                                                          known-capture?
                                                          true)
                                                        unit)
                                                      (set!
                                                        capture-index
                                                        (+ capture-index 1))))
                                                  (if (if (not explicit?)
                                                    (not known-capture?)
                                                    false)
                                                    (let
                                                      [fresh-name : String
                                                        (comptime.syntax-name-fresh
                                                          (comptime.string-append
                                                            "__tl_format_capture_"
                                                            (comptime.int->string
                                                              capture-count)))]
                                                      [fresh-var : comptime.Expr
                                                        (comptime.expr-var
                                                          fresh-name)]
                                                      [entry-items : comptime.ExprList
                                                        (comptime.expr-list-cons
                                                          fresh-var
                                                          (comptime.expr-list-cons
                                                            piece
                                                            (comptime.expr-list-empty)))]
                                                      (begin
                                                        (set!
                                                          capture-names
                                                          (comptime.expr-list-cons
                                                            (comptime.expr-string
                                                              name)
                                                            capture-names))
                                                        (set!
                                                          capture-vars
                                                          (comptime.expr-list-cons
                                                            fresh-var
                                                            capture-vars))
                                                        (set!
                                                          capture-bindings
                                                          (comptime.expr-list-cons
                                                            (comptime.expr-begin-unit
                                                              entry-items)
                                                            capture-bindings))
                                                        (set!
                                                          capture-count
                                                          (+ capture-count 1))))
                                                    unit)))]
                                            [_ unit])
                                          (set! plan-index (- plan-index 1)))))
                                    ;; Render the reverse plan into forward
                                    ;; concat operands while resolving bindings.
                                    (let
                                      [output : comptime.ExprList
                                        (comptime.expr-list-empty)]
                                      [piece-index : i64 0]
                                      (begin
                                        (while (< piece-index plan-len)
                                          (let
                                            [piece : comptime.Expr
                                              (comptime.expr-list-nth
                                                plan-pieces
                                                piece-index)]
                                            (begin
                                              (if (comptime.expr-string? piece)
                                                (set!
                                                  output
                                                  (comptime.expr-list-cons
                                                    piece
                                                    output))
                                                (match piece
                                                  [(comptime.Expr.Begin
                                                      reference)
                                                    (match (comptime.expr-list-nth
                                                      reference
                                                      0)
                                                      [(comptime.Expr.Int
                                                          selected)
                                                        (set!
                                                          output
                                                          (comptime.expr-list-cons
                                                            `(stdlib.format.format-value
                                                              ,(comptime.expr-list-nth
                                                                positional-items
                                                                selected))
                                                            output))]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal positional index is malformed")])]
                                                  [_
                                                    (match piece
                                                      [(comptime.Expr.Var name)
                                                        (let
                                                          [selected : comptime.Expr
                                                            (comptime.expr-int
                                                              0)]
                                                          [found? : bool false]
                                                          [named-index : i64 0]
                                                          [capture-index : i64
                                                            0]
                                                          (begin
                                                            (while (<
                                                              named-index
                                                              (comptime.expr-list-length
                                                                named-name-items))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      named-name-items
                                                                      named-index))
                                                                  name)
                                                                  (begin
                                                                    (set!
                                                                      selected
                                                                      (comptime.expr-list-nth
                                                                        named-var-items
                                                                        named-index))
                                                                    (set!
                                                                      found?
                                                                      true))
                                                                  unit)
                                                                (set!
                                                                  named-index
                                                                  (+
                                                                    named-index
                                                                    1))))
                                                            (while (<
                                                              capture-index
                                                              (comptime.expr-list-length
                                                                capture-names))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      capture-names
                                                                      capture-index))
                                                                  name)
                                                                  (begin
                                                                    (set!
                                                                      selected
                                                                      (comptime.expr-list-nth
                                                                        capture-vars
                                                                        capture-index))
                                                                    (set!
                                                                      found?
                                                                      true))
                                                                  unit)
                                                                (set!
                                                                  capture-index
                                                                  (+
                                                                    capture-index
                                                                    1))))
                                                            (if found?
                                                              (set!
                                                                output
                                                                (comptime.expr-list-cons
                                                                  `(stdlib.format.format-value
                                                                    ,selected)
                                                                  output))
                                                              (comptime.comptime-error
                                                                "format: internal named argument lookup failed"))))]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal plan piece is malformed")])]))
                                              (set!
                                                piece-index
                                                (+ piece-index 1)))))
                                        (let
                                          [result : comptime.Expr
                                            `(stdlib.str_cat.str-cat ,@output)]
                                          [capture-index : i64 0]
                                          [binding-index : i64
                                            (-
                                              (comptime.expr-list-length
                                                binding-items)
                                              1)]
                                          (begin
                                            ;; Capture entries are reverse
                                            ;; template order; supplied entries
                                            ;; are forward source order.
                                            (while (<
                                              capture-index
                                              (comptime.expr-list-length
                                                capture-bindings))
                                              (match (comptime.expr-list-nth
                                                capture-bindings
                                                capture-index)
                                                [(comptime.Expr.Begin entry)
                                                  (match (comptime.expr-list-nth
                                                    entry
                                                    0)
                                                    [(comptime.Expr.Var
                                                        binding-name)
                                                      (set!
                                                        result
                                                        (comptime.expr-let-scope
                                                          binding-name
                                                          (comptime.expr-list-nth
                                                            entry
                                                            1)
                                                          result))]
                                                    [_
                                                      (comptime.comptime-error
                                                        "format: internal capture binding is malformed")])]
                                                [_
                                                  (comptime.comptime-error
                                                    "format: internal capture binding is malformed")])
                                              (set!
                                                capture-index
                                                (+ capture-index 1)))
                                            (while (>= binding-index 0)
                                              (match (comptime.expr-list-nth
                                                binding-items
                                                binding-index)
                                                [(comptime.Expr.Begin entry)
                                                  (match (comptime.expr-list-nth
                                                    entry
                                                    0)
                                                    [(comptime.Expr.Var
                                                        binding-name)
                                                      (set!
                                                        result
                                                        (comptime.expr-let-scope
                                                          binding-name
                                                          (comptime.expr-list-nth
                                                            entry
                                                            1)
                                                          result))]
                                                    [_
                                                      (comptime.comptime-error
                                                        "format: internal supplied binding is malformed")])]
                                                [_
                                                  (comptime.comptime-error
                                                    "format: internal supplied binding is malformed")])
                                              (set!
                                                binding-index
                                                (- binding-index 1)))
                                            result))))))]
                              [_
                                (comptime.comptime-error
                                  "format: internal binding carrier is malformed")])]
                          [_
                            (comptime.comptime-error
                              "format: internal named variable carrier is malformed")])]
                      [_
                        (comptime.comptime-error
                          "format: internal named argument carrier is malformed")])]
                  [_
                    (comptime.comptime-error
                      "format: internal positional carrier is malformed")])]
              [_
                (comptime.comptime-error
                  "format: internal plan carrier is malformed")]))]
        [_
          (comptime.comptime-error
            "format: internal argument carrier is malformed")])]
    [_
      (comptime.comptime-error
        "format: internal argument index is not an integer")]))

;: Format a literal template and values into a freshly allocated String.
;:
;: The parser builds a reverse dense plan of literal chunks, positional
;: references, and named references. Argument expansion then validates the
;: whole plan, evaluates supplied values once in source order, captures missing
;: names at the call site, and emits one flat `str-cat` expression.
(defmacro (format [template : comptime.Expr] [args : comptime.Expr ...]) : String
  (if (comptime.expr-string? template)
    (let
      [text : String (comptime.expr-string-value template)]
      [template-len : i64 (string.string-length text)]
      [plan-pieces : comptime.ExprList (comptime.expr-list-empty)]
      [index : i64 0]
      [literal-start : i64 0]
      [next-implicit : i64 0]
      (begin
        (while (< index template-len)
          (let
            [code : i64 (cast (string.string-ref text index) : i64)]
            (if (= code 123)
              (if (>= (+ index 1) template-len)
                (comptime.comptime-error "format: unmatched '{'")
                (let
                  [following : i64
                    (cast (string.string-ref text (+ index 1)) : i64)]
                  (if (= following 123)
                    (begin
                      (if (> index literal-start)
                        (set!
                          plan-pieces
                          (comptime.expr-list-cons
                            (comptime.expr-string
                              (comptime.string-slice
                                text
                                literal-start
                                (- index literal-start)))
                            plan-pieces))
                        unit)
                      (set!
                        plan-pieces
                        (comptime.expr-list-cons
                          (comptime.expr-string "{")
                          plan-pieces))
                      (set! index (+ index 2))
                      (set! literal-start index))
                    (let
                      [close : i64 (+ index 1)]
                      [searching : bool true]
                      (begin
                        (while searching
                          (if (< close template-len)
                            (if (!=
                              (cast (string.string-ref text close) : i64)
                              125)
                              (set! close (+ close 1))
                              (set! searching false))
                            (set! searching false)))
                        (if (>= close template-len)
                          (comptime.comptime-error "format: unmatched '{'")
                          unit)
                        (if (> index literal-start)
                          (set!
                            plan-pieces
                            (comptime.expr-list-cons
                              (comptime.expr-string
                                (comptime.string-slice
                                  text
                                  literal-start
                                  (- index literal-start)))
                              plan-pieces))
                          unit)
                        (let
                          [argument-start : i64 (+ index 1)]
                          [argument-end : i64 close]
                          [trimming : bool true]
                          (begin
                            (while trimming
                              (if (> argument-end argument-start)
                                (let
                                  [last-code : i64
                                    (cast
                                      (string.string-ref
                                        text
                                        (- argument-end 1))
                                      : i64)]
                                  ;; Core `cond` cannot execute in macro CTFE.
                                  ;; lint-allow: nested-if-ladder
                                  (if (if (= last-code 9)
                                    true
                                    (if (= last-code 10)
                                      true
                                      (if (= last-code 11)
                                        true
                                        (if (= last-code 12)
                                          true
                                          (if (= last-code 13)
                                            true
                                            (= last-code 32))))))
                                    (set! argument-end (- argument-end 1))
                                    (set! trimming false)))
                                (set! trimming false)))
                            (if (= argument-start argument-end)
                              (let
                                [reference : comptime.ExprList
                                  (comptime.expr-list-cons
                                    (comptime.expr-int next-implicit)
                                    (comptime.expr-list-cons
                                      (comptime.expr-int 1)
                                      (comptime.expr-list-empty)))]
                                (begin
                                  (set!
                                    plan-pieces
                                    (comptime.expr-list-cons
                                      (comptime.expr-begin-unit reference)
                                      plan-pieces))
                                  (set! next-implicit (+ next-implicit 1))))
                              (let
                                [argument-len : i64
                                  (- argument-end argument-start)]
                                [first-code : i64
                                  (cast
                                    (string.string-ref text argument-start)
                                    : i64)]
                                [scan : i64 argument-start]
                                [has-colon : bool false]
                                [has-hash : bool false]
                                [has-whitespace : bool false]
                                [has-non-ascii : bool false]
                                (begin
                                  (while (< scan argument-end)
                                    (let
                                      [scan-code : i64
                                        (cast
                                          (string.string-ref text scan)
                                          : i64)]
                                      (begin
                                        (if (= scan-code 58)
                                          (set! has-colon true)
                                          unit)
                                        (if (= scan-code 35)
                                          (set! has-hash true)
                                          unit)
                                        ;; Core `cond` cannot execute in macro CTFE.
                                        ;; lint-allow: nested-if-ladder
                                        (if (if (= scan-code 9)
                                          true
                                          (if (= scan-code 10)
                                            true
                                            (if (= scan-code 11)
                                              true
                                              (if (= scan-code 12)
                                                true
                                                (if (= scan-code 13)
                                                  true
                                                  (= scan-code 32))))))
                                          (set! has-whitespace true)
                                          unit)
                                        (if (>= scan-code 128)
                                          (set! has-non-ascii true)
                                          unit)
                                        (set! scan (+ scan 1)))))
                                  (if has-colon
                                    (comptime.comptime-error
                                      "format: format specifiers are not supported")
                                    unit)
                                  (if has-hash
                                    (comptime.comptime-error
                                      "format: Rust raw identifiers use the TypeLisp spelling without 'r#'")
                                    unit)
                                  (if has-whitespace
                                    (comptime.comptime-error
                                      "format: whitespace is only allowed immediately before '}'")
                                    unit)
                                  (if has-non-ascii
                                    (comptime.comptime-error
                                      "format: placeholder names and whitespace are ASCII-only")
                                    unit)
                                  (if (if (>= first-code 48)
                                    (<= first-code 57)
                                    false)
                                    (let
                                      [value : i64 0]
                                      [digit-index : i64 argument-start]
                                      (begin
                                        (while (< digit-index argument-end)
                                          (let
                                            [digit-code : i64
                                              (cast
                                                (string.string-ref
                                                  text
                                                  digit-index)
                                                : i64)]
                                            (begin
                                              (if (if (< digit-code 48)
                                                true
                                                (> digit-code 57))
                                                (comptime.comptime-error
                                                  "format: malformed positional argument index")
                                                unit)
                                              (let
                                                [digit : i64 (- digit-code 48)]
                                                (begin
                                                  (if (if (>
                                                    value
                                                    922337203685477580)
                                                    true
                                                    (if (=
                                                      value
                                                      922337203685477580)
                                                      (> digit 7)
                                                      false))
                                                    (comptime.comptime-error
                                                      "format: positional argument index overflow")
                                                    unit)
                                                  (set!
                                                    value
                                                    (+ (* value 10) digit))))
                                              (set!
                                                digit-index
                                                (+ digit-index 1)))))
                                        (let
                                          [reference : comptime.ExprList
                                            (comptime.expr-list-cons
                                              (comptime.expr-int value)
                                              (comptime.expr-list-cons
                                                (comptime.expr-int 0)
                                                (comptime.expr-list-empty)))]
                                          (set!
                                            plan-pieces
                                            (comptime.expr-list-cons
                                              (comptime.expr-begin-unit
                                                reference)
                                              plan-pieces)))))
                                    (let
                                      [name : String
                                        (comptime.string-slice
                                          text
                                          argument-start
                                          argument-len)]
                                      [name-index : i64 0]
                                      [valid? : bool true]
                                      (begin
                                        (if (string.eq name "_")
                                          (comptime.comptime-error
                                            "format: bare '_' is not a captured identifier")
                                          unit)
                                        (while (< name-index argument-len)
                                          (let
                                            [name-code : i64
                                              (cast
                                                (string.string-ref
                                                  name
                                                  name-index)
                                                : i64)]
                                            [folded : i64
                                              (if (if (>= name-code 65)
                                                (<= name-code 90)
                                                false)
                                                (+ name-code 32)
                                                name-code)]
                                            [symbol-char?
                                              : bool
                                              ;; Mirrors lex.is-symbol-char;
                                              ;; `cond` is unavailable in macro CTFE.
                                              ;; lint-allow: nested-if-ladder
                                              (if (if (>= folded 97)
                                                (<= folded 122)
                                                false)
                                                true
                                                (if (if (>= name-code 48)
                                                  (<= name-code 57)
                                                  false)
                                                  true
                                                  (if (if (>= name-code 42)
                                                    (<= name-code 63)
                                                    false)
                                                    (if (!= name-code 44)
                                                      (!= name-code 59)
                                                      false)
                                                    (if (= name-code 33)
                                                      true
                                                      (if (if (>= name-code 37)
                                                        (<= name-code 38)
                                                        false)
                                                        true
                                                        (= name-code 95))))))]
                                            (begin
                                              (if (not symbol-char?)
                                                (set! valid? false)
                                                unit)
                                              (set! name-index (+ name-index 1)))))
                                        (if valid?
                                          (set!
                                            plan-pieces
                                            (comptime.expr-list-cons
                                              (comptime.expr-var name)
                                              plan-pieces))
                                          (comptime.comptime-error
                                            "format: malformed captured argument identifier"))))))))
                            (set! index (+ close 1))
                            (set! literal-start index))))))))
              (if (= code 125)
                (if (if (< (+ index 1) template-len)
                  (= (cast (string.string-ref text (+ index 1)) : i64) 125)
                  false)
                  (begin
                    (if (> index literal-start)
                      (set!
                        plan-pieces
                        (comptime.expr-list-cons
                          (comptime.expr-string
                            (comptime.string-slice
                              text
                              literal-start
                              (- index literal-start)))
                          plan-pieces))
                      unit)
                    (set!
                      plan-pieces
                      (comptime.expr-list-cons
                        (comptime.expr-string "}")
                        plan-pieces))
                    (set! index (+ index 2))
                    (set! literal-start index))
                  (comptime.comptime-error "format: unmatched '}'"))
                (set! index (+ index 1))))))
        (if (> template-len literal-start)
          (set!
            plan-pieces
            (comptime.expr-list-cons
              (comptime.expr-string
                (comptime.string-slice
                  text
                  literal-start
                  (- template-len literal-start)))
              plan-pieces))
          unit)
        (let
          [plan : comptime.Expr
            (comptime.expr-call
              (comptime.expr-var "__tl_format_plan")
              plan-pieces)]
          `(stdlib.format.format-expand
            ,plan
            (__tl_format_arguments ,@args)
            0
            0
            (__tl_format_positional_vars)
            (__tl_format_named_names)
            (__tl_format_named_vars)
            (__tl_format_bindings)))))
    (comptime.comptime-error "format: template must be a string literal")))

;: Fixed-capacity base-2^32 bignum backing the pure-TL f64 formatter.
(defstruct BigNum
  (limbs (__tl_dyn-array u64))
  (len i64))

;: Limb capacity of formatter bignum scratch buffers.
(define ftoa-cap : i64
  96)

;: Low 32-bit mask isolating a base-2^32 limb.
(define ftoa-mask32 : u64
  0xffffffff)

;: A zero-valued formatter BigNum.
(define (bn-zero) : BigNum
  (BigNum (array.make-array u64 stdlib.format.ftoa-cap) 0))

;: BigNum holding the u64 value x.
(define (bn-from-u64 [x : u64]) : BigNum
  (let
    [r : BigNum (bn-zero)]
    [lo : u64 (bit-and x stdlib.format.ftoa-mask32)]
    [hi : u64 (shr x 32)]
    (begin
      (set! (array-ref r.limbs 0) lo)
      (set! (array-ref r.limbs 1) hi)
      (if (> hi (cast 0 : u64))
        (BigNum r.limbs 2)
        (if (> lo (cast 0 : u64))
          (BigNum r.limbs 1)
          (BigNum r.limbs 0))))))

;: Compare BigNums a and b; -1 if a<b, 0 if equal, 1 if a>b.
(define (bn-cmp [a : BigNum] [b : BigNum]) : i64
  (let
    [la : i64 a.len]
    [lb : i64 b.len]
    (if (> la lb)
      1
      (if (< la lb)
        -1
        (let
          [i : i64 (- la 1)]
          [res : i64 0]
          [done : bool false]
          (begin
            (while (and (not done) (>= i 0))
              (let
                [av : u64 (array-ref a.limbs i)]
                [bv : u64 (array-ref b.limbs i)]
                (begin
                  (if (> av bv)
                    (begin
                      (set! res 1)
                      (set! done true))
                    (if (< av bv)
                      (begin
                        (set! res -1)
                        (set! done true))
                      unit))
                  (set! i (- i 1)))))
            res))))))

;: Limb count of arr with high zero limbs trimmed, starting from hint.
(define (bn-norm-len [arr : (__tl_dyn-array u64)] [hint : i64]) : i64
  (let
    [i : i64 hint]
    (begin
      (while (and (> i 0) (= (array-ref arr (- i 1)) (cast 0 : u64)))
        (set! i (- i 1)))
      i)))

;: Sum of BigNums a and b.
(define (bn-add [a : BigNum] [b : BigNum]) : BigNum
  (let
    [r : (__tl_dyn-array u64) (array.make-array u64 stdlib.format.ftoa-cap)]
    [la : i64 a.len]
    [lb : i64 b.len]
    [n : i64
      (if (> la lb)
        la
        lb)]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [av : u64
            (if (< i la)
              (array-ref a.limbs i)
              (cast 0 : u64))]
          [bv : u64
            (if (< i lb)
              (array-ref b.limbs i)
              (cast 0 : u64))]
          [s : u64 (+ (+ av bv) carry)]
          (begin
            (set! (array-ref r i) (bit-and s stdlib.format.ftoa-mask32))
            (set! carry (shr s 32))
            (set! i (+ i 1)))))
      (when
        (> carry (cast 0 : u64))
        (begin
          (set! (array-ref r i) carry)
          (set! n (+ n 1))))
      (BigNum r (bn-norm-len r n)))))

;: Product of BigNum a and a value m that fits in 32 bits.
(define (bn-mul-u32 [a : BigNum] [m : u64]) : BigNum
  (let
    [r : (__tl_dyn-array u64) (array.make-array u64 stdlib.format.ftoa-cap)]
    [la : i64 a.len]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i la)
        (let
          [p : u64 (+ (* (array-ref a.limbs i) m) carry)]
          (begin
            (set! (array-ref r i) (bit-and p stdlib.format.ftoa-mask32))
            (set! carry (shr p 32))
            (set! i (+ i 1)))))
      (while (> carry (cast 0 : u64))
        (begin
          (set! (array-ref r i) (bit-and carry stdlib.format.ftoa-mask32))
          (set! carry (shr carry 32))
          (set! i (+ i 1))))
      (BigNum r (bn-norm-len r i)))))

;: BigNum a shifted left by n bits.
(define (bn-shl-bits [a : BigNum] [n : i64]) : BigNum
  (if (= a.len 0)
    a
    (let
      [limb-shift : i64 (/ n 32)]
      [bit-shift : i64 (% n 32)]
      [r : (__tl_dyn-array u64) (array.make-array u64 stdlib.format.ftoa-cap)]
      [la : i64 a.len]
      [carry : u64 (cast 0 : u64)]
      [i : i64 0]
      (begin
        (if (= bit-shift 0)
          (while (< i la)
            (begin
              (set! (array-ref r (+ i limb-shift)) (array-ref a.limbs i))
              (set! i (+ i 1))))
          (while (< i la)
            (let
              [v : u64 (array-ref a.limbs i)]
              [shifted : u64
                (bit-or
                  (bit-and (shl v bit-shift) stdlib.format.ftoa-mask32)
                  carry)]
              (begin
                (set! (array-ref r (+ i limb-shift)) shifted)
                (set! carry (shr v (- 32 bit-shift)))
                (set! i (+ i 1))))))
        (when
          (and (not (= bit-shift 0)) (> carry (cast 0 : u64)))
          (set! (array-ref r (+ la limb-shift)) carry))
        (BigNum r (bn-norm-len r (+ la (+ limb-shift 1))))))))

;: Product of BigNum a and the 64-bit value m.
(define (bn-mul-u64 [a : BigNum] [m : u64]) : BigNum
  (let
    [lo : u64 (bit-and m stdlib.format.ftoa-mask32)]
    [hi : u64 (shr m 32)]
    [low : BigNum (bn-mul-u32 a lo)]
    (if (= hi (cast 0 : u64))
      low
      (bn-add low (bn-shl-bits (bn-mul-u32 a hi) 32)))))

;: BigNum a multiplied by ten raised to p.
(define (bn-mul-pow10 [a : BigNum] [p : i64]) : BigNum
  (let
    [r : BigNum a]
    [i : i64 0]
    (begin
      (while (< i p)
        (begin
          (set! r (bn-mul-u32 r (cast 10 : u64)))
          (set! i (+ i 1))))
      r)))

;: floor(num/den) as u64, assuming the quotient fits in 60 bits.
(define (bn-div-floor-u64 [num : BigNum] [den : BigNum]) : u64
  (let
    [q : u64 (cast 0 : u64)]
    [bit : i64 59]
    (begin
      (while (>= bit 0)
        (let
          [cand : u64 (+ q (shl (cast 1 : u64) bit))]
          [prod : BigNum (bn-mul-u64 den cand)]
          (begin
            (if (<= (bn-cmp prod num) 0)
              (set! q cand)
              unit)
            (set! bit (- bit 1)))))
      q)))

;: floor(a / b) for b > 0 (TL `/` truncates toward zero).
(define (ftoa-floor-div [a : i64] [b : i64]) : i64
  (if (>= a 0)
    (/ a b)
    (- 0 (/ (+ (- 0 a) (- b 1)) b))))

;: Index of the highest set bit of m.
(define (ftoa-msb-index [m : u64]) : i64
  (let
    [i : i64 0]
    [v : u64 m]
    (begin
      (while (> v (cast 1 : u64))
        (begin
          (set! v (shr v 1))
          (set! i (+ i 1))))
      i)))

;: Significant-digit string of d with trailing zeros removed (>= 1 digit).
(define (ftoa-strip-zeros [d : i64]) : String
  (let
    [dd : i64 d]
    (begin
      (while (and (> dd 9) (= (% dd 10) 0))
        (set! dd (/ dd 10)))
      (string.int->string dd))))

;: Exponent k formatted with sign and at least two digits.
(define (ftoa-pad-exp [k : i64]) : String
  (let
    [mag : i64
      (if (< k 0)
        (- 0 k)
        k)]
    [digits : String (string.int->string mag)]
    [sign : String
      (if (< k 0)
        "-"
        "+")]
    (str_cat.str-cat
      sign
      (if (< (string-length digits) 2)
        (str_cat.str-cat "0" digits "")
        digits)
      "")))

;: A string of n zero characters.
(define (format-array-const-ptr [buf : (__tl_dyn-array u8)]) : (Ptr u8)
  (unsafe
    (ptr-cast (__tl_array-data buf) : (Ptr u8))))

;: A string of n zero characters.
(define (ftoa-zeros [n : i64]) : String
  (let
    [out : (__tl_dyn-array u8) (array.make-array u8 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref out i) (cast '0' : u8))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes (format-array-const-ptr out) n)))))

;: Format significant-digit string s whose leading digit has decimal exponent k.
(define (ftoa-render [neg : bool] [s : String] [k : i64]) : String
  (let
    [body : String ""]
    [ndig : i64 (string-length s)]
    (begin
      (cond
        [(or (< k -4) (>= k 17))
          (set!
            body
            (str_cat.str-cat
              (string.substring s 0 1)
              (if (> ndig 1)
                (str_cat.str-cat "." (string.substring s 1 (- ndig 1)) "")
                "")
              "e"
              (stdlib.format.ftoa-pad-exp k)))]
        [(< k 0)
          (set!
            body
            (str_cat.str-cat "0." (stdlib.format.ftoa-zeros (- (- 0 k) 1)) s))]
        [(>= (+ k 1) ndig)
          (set!
            body
            (str_cat.str-cat s (stdlib.format.ftoa-zeros (- (+ k 1) ndig)) ""))]
        [else
          (set!
            body
            (str_cat.str-cat
              (string.substring s 0 (+ k 1))
              "."
              (string.substring s (+ k 1) (- ndig (+ k 1)))))])
      (if neg
        (str_cat.str-cat "-" body "")
        body))))

;: Render an f64 as a shortest round-tripping decimal string.
(define (format-float-core [value : f64]) : String
  (let
    [buf : (__tl_dyn-array f64) (array.make-array f64 1)]
    (begin
      (set! (array-ref buf 0) value)
      (let
        [bits : u64
          (unsafe
            (ptr-read (ptr-cast (__tl_array-data buf) : (Ptr u64))))]
        [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
        [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
        [frac : u64 (bit-and bits 0xfffffffffffff)]
        (begin
          (when
            (= expf (cast 0x7ff : u64))
            (return
              (if (= frac (cast 0 : u64))
                (if neg
                  "-inf"
                  "inf")
                (if neg
                  "-nan"
                  "nan"))))
          (when
            (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
            (return
              (if neg
                "-0"
                "0")))
          (let
            [m : u64
              (if (= expf (cast 0 : u64))
                frac
                (bit-or frac 0x10000000000000))]
            [e2 : i64
              (if (= expf (cast 0 : u64))
                -1074
                (- (cast expf : i64) 1075))]
            [msb : i64 (stdlib.format.ftoa-msb-index m)]
            [kest : i64
              (stdlib.format.ftoa-floor-div (* (+ msb e2) 30103) 100000)]
            [d : u64 (cast 0 : u64)]
            [iters : i64 0]
            [settled : bool false]
            (begin
              (while (if (not settled)
                (< iters 6)
                false)
                (let
                  [p : i64 (- 16 kest)]
                  [num : BigNum (stdlib.format.bn-from-u64 m)]
                  [den : BigNum (stdlib.format.bn-from-u64 (cast 1 : u64))]
                  (begin
                    (if (>= e2 0)
                      (set! num (stdlib.format.bn-shl-bits num e2))
                      (set! den (stdlib.format.bn-shl-bits den (- 0 e2))))
                    (if (>= p 0)
                      (set! num (stdlib.format.bn-mul-pow10 num p))
                      (set! den (stdlib.format.bn-mul-pow10 den (- 0 p))))
                    (let
                      [q : u64 (stdlib.format.bn-div-floor-u64 num den)]
                      [two-num : BigNum (stdlib.format.bn-shl-bits num 1)]
                      [t : BigNum
                        (stdlib.format.bn-mul-u64
                          den
                          (+ (* (cast 2 : u64) q) (cast 1 : u64)))]
                      [c : i64 (stdlib.format.bn-cmp two-num t)]
                      (begin
                        (set! d q)
                        (if (> c 0)
                          (set! d (+ q (cast 1 : u64)))
                          (if (= c 0)
                            (if (= (bit-and q (cast 1 : u64)) (cast 1 : u64))
                              (set! d (+ q (cast 1 : u64)))
                              unit)
                            unit))
                        (if (>= d 100000000000000000)
                          (set! kest (+ kest 1))
                          (if (< d 10000000000000000)
                            (set! kest (- kest 1))
                            (set! settled true)))
                        (set! iters (+ iters 1)))))))
              (let
                [s0 : String (string.int->string (cast d : i64))]
                [k : i64 (+ (- (string-length s0) 17) kest)]
                (stdlib.format.ftoa-render
                  neg
                  (stdlib.format.ftoa-strip-zeros (cast d : i64))
                  k)))))))))