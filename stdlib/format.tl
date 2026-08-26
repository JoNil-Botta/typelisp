;# Rust-style literal format-string macro returning a fresh String.
;#
;# `format` parses a string-literal template during macro expansion. It supports
;# implicit `{}`, indexed `{0}`, explicit named, and call-site-captured `{name}`
;# selections; escapes use `{{` / `}}`. Format specifications share one parsed
;# plan supporting byte fill, alignment, sign, alternate/zero flags, width, and
;# literal/dollar/star precision counts. The generated expression evaluates
;# each supplied value once and uses one flat `str-cat` expansion. Nonnumeric
;# Display precision truncates rendered TypeLisp bytes before padding; float
;# precision selects exact fixed decimal with round-half-to-even.
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
;# Builtin placeholder values are `String`, all eight fixed-width integer
;# types, `bool`, `char`, `f64`, and `f32`. Structural formatting is
;# intentionally separate from this default Display-style protocol.
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

;: Common runtime formatting options produced by the literal template plan.
;:
;: Alignment uses `0` for the value category's default, `1` for left, `2` for
;: center, and `3` for right. Sign uses `0` for absent, `1` for `+`, and `2` for
;: Rust's currently unused `-` spelling. Width and fill count TypeLisp bytes,
;: not Unicode scalars or terminal columns. `alternate` is retained for the
;: type-specific formatter siblings even where default Display ignores it.
;: Precision is resolved before this shared transport: `precision-present`
;: distinguishes an omitted count from an explicit zero.
(defstruct FormatOptions
  (fill char)
  (alignment i64)
  (sign i64)
  (alternate bool)
  (sign-aware-zero-pad bool)
  (width i64)
  (precision-present bool)
  (precision i64))

;: Validate one runtime-provided width before allocation or arithmetic.
(define (format-width-count-runtime [count : i64]) : i64
  (if (< count 0)
    (format-runtime-abort-string
      "format: dynamic width argument must be nonnegative")
    count))

;: Validate one runtime-provided precision before rendering or allocation.
(define (format-precision-count-runtime [count : i64]) : i64
  (if (< count 0)
    (format-runtime-abort-string "format: precision count must be nonnegative")
    count))

;: Fill a caller-validated live destination byte range.
;:
;: The caller must guarantee that `[start, start + count)` is in bounds for
;: `dst`; this helper performs no independent allocation or range check.
(define (format-write-fill!
  [dst : (MutPtr u8)]
  [start : i64]
  [count : i64]
  [fill : char]) : unit
  (let
    [index : i64 0]
    [byte : u8 (cast fill : u8)]
    (while (< index count)
      (begin
        (unsafe
          (ptr-write! (ptr-offset dst (+ start index)) byte))
        (set! index (+ index 1))))))

;: Copy between caller-validated live source and destination byte ranges.
;:
;: The caller must guarantee that both ranges are in bounds. A zero-byte copy
;: does not derive a source pointer, which keeps empty rendered values valid.
(define (format-copy-rendered-range!
  [rendered : (& rendered str)]
  [source-start : i64]
  [dst : (MutPtr u8)]
  [destination-start : i64]
  [count : i64]) : unit
  (if (= count 0)
    unit
    (let
      [source : (Ptr u8)
        (unsafe
          (ptr-offset (string-data rendered) source-start))]
      (string.str-copy-bytes-into source dst destination-start count))))

;: Resolve the byte length visible to shared Display padding.
;:
;: Numeric renderers own their precision semantics, so this shared fallback
;: truncates only nonnumeric output. TypeLisp text and `char` are byte-oriented:
;: the precision boundary neither decodes nor validates UTF-8.
(define (format-rendered-display-length
  [rendered-len : i64]
  [numeric? : bool]
  [options : FormatOptions]) : i64
  (if (if numeric?
    false
    (if options.precision-present
      (< options.precision rendered-len)
      false))
    options.precision
    rendered-len))

;: Apply shared Display precision, byte width, alignment, sign, and zero padding.
;:
;: The value renderer has already chosen Display/type-specific text. Padding
;: therefore follows nonnumeric byte truncation and composes with owner-module
;: `to-string`. Numeric zero padding keeps a leading sign and a
;: `0x`/`0X`/`0o`/`0b` prefix before the inserted zeroes.
(define (format-apply-options
  [rendered : String]
  [numeric? : bool]
  [options : FormatOptions]) : String
  (let
    [rendered-len : i64 (string.string-length (& rendered))]
    [display-len : i64
      (format-rendered-display-length rendered-len numeric? options)]
    [source-sign-len : i64
      (if (if numeric?
        (> rendered-len 0)
        false)
        (if (= (cast (string.string-ref (& rendered) 0) : i64) 45)
          1
          0)
        0)]
    [add-plus? : bool
      (if (if numeric?
        (= options.sign 1)
        false)
        (= source-sign-len 0)
        false)]
    [output-sign-len : i64
      (if (or add-plus? (= source-sign-len 1))
        1
        0)]
    [prefix-len : i64 0]
    (begin
      (if (if numeric?
        (>= (- rendered-len source-sign-len) 2)
        false)
        (let
          [first : i64
            (cast (string.string-ref (& rendered) source-sign-len) : i64)]
          [second : i64
            (cast (string.string-ref (& rendered) (+ source-sign-len 1)) : i64)]
          (if (if (= first 48)
            (or (= second 120) (= second 88) (= second 111) (= second 98))
            false)
            (set! prefix-len 2)
            unit))
        unit)
      (let
        [content-len : i64 (+ (- display-len source-sign-len) output-sign-len)]
        [output-len : i64
          (if (> options.width content-len)
            options.width
            content-len)]
        [padding : i64 (- output-len content-len)]
        (if (and (= display-len rendered-len) (= padding 0) (not add-plus?))
          rendered
          (let
            [dst : (MutPtr u8) (string.string-runtime-alloc output-len)]
            [zero-pad? : bool
              (if numeric?
                options.sign-aware-zero-pad
                false)]
            (begin
              (if zero-pad?
                (let
                  [cursor : i64 0]
                  (begin
                    (if (= output-sign-len 1)
                      (begin
                        (unsafe
                          (ptr-write!
                            dst
                            (cast
                              (if add-plus?
                                43
                                45)
                              : u8)))
                        (set! cursor 1))
                      unit)
                    (format-copy-rendered-range!
                      (& rendered)
                      source-sign-len
                      dst
                      cursor
                      prefix-len)
                    (set! cursor (+ cursor prefix-len))
                    (format-write-fill! dst cursor padding '0')
                    (set! cursor (+ cursor padding))
                    (format-copy-rendered-range!
                      (& rendered)
                      (+ source-sign-len prefix-len)
                      dst
                      cursor
                      (- rendered-len (+ source-sign-len prefix-len)))))
                (let
                  [alignment : i64
                    (if (= options.alignment 0)
                      (if numeric?
                        3
                        1)
                      options.alignment)]
                  [left-padding : i64
                    (match alignment
                      [1 0]
                      [2 (/ padding 2)]
                      [_ padding])]
                  [right-padding : i64 (- padding left-padding)]
                  [cursor : i64 left-padding]
                  (begin
                    (format-write-fill! dst 0 left-padding options.fill)
                    (if (= output-sign-len 1)
                      (begin
                        (unsafe
                          (ptr-write!
                            (ptr-offset dst cursor)
                            (cast
                              (if add-plus?
                                43
                                45)
                              : u8)))
                        (set! cursor (+ cursor 1)))
                      unit)
                    (format-copy-rendered-range!
                      (& rendered)
                      source-sign-len
                      dst
                      cursor
                      (- display-len source-sign-len))
                    (format-write-fill!
                      dst
                      (- output-len right-padding)
                      right-padding
                      options.fill))))
              (unsafe
                (string-from-bytes (ptr-cast dst : (Ptr u8)) output-len)))))))))

;; The deterministic pure-TypeLisp f64 renderer is defined below the template
;; parser. Keeping it in this module makes `stdlib.format` independent of I/O.
;: Render one supported format placeholder through the shared dispatch path.
(defmacro (format-value
  [value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [width-value : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [precision-value : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  (match fill-expr
    [(comptime.Expr.Int fill-code)
      (match alignment-expr
        [(comptime.Expr.Int alignment)
          (match sign-expr
            [(comptime.Expr.Int sign)
              (match alternate-expr
                [(comptime.Expr.Int alternate)
                  (match zero-expr
                    [(comptime.Expr.Int zero)
                      (match width-kind-expr
                        [(comptime.Expr.Int width-kind)
                          (match precision-kind-expr
                            [(comptime.Expr.Int precision-kind)
                              (let
                                [selector : String
                                  (comptime.expr-string-value selector-expr)]
                                [argument-type : comptime.Expr
                                  (comptime.expr-type value)]
                                [argument-kind : String
                                  (type-kind argument-type)]
                                [borrowed? : bool
                                  (if (string.eq argument-kind "ref")
                                    true
                                    (string.eq argument-kind "mut-ref"))]
                                [value-type : comptime.Expr
                                  (if borrowed?
                                    (comptime.reference-element-type
                                      argument-type)
                                    argument-type)]
                                [value-kind : String (type-kind value-type)]
                                [nominal? : bool
                                  (match value-kind
                                    ["struct" true]
                                    ["enum" true]
                                    ["region" true]
                                    [_ false])]
                                [value-key : String (type-key value-type)]
                                [owner : String
                                  (if nominal?
                                    (type-nominal-module value-type)
                                    "")]
                                [nominal-name : String
                                  (if nominal?
                                    (type-nominal-name value-type)
                                    "")]
                                [plain-name : String "to-string"]
                                [qualified-name : String
                                  (comptime.string-append
                                    "to-string-"
                                    nominal-name)]
                                [plain-present? : bool
                                  (if nominal?
                                    (comptime.module-value? owner plain-name)
                                    false)]
                                [qualified-present? : bool
                                  (if nominal?
                                    (comptime.module-value?
                                      owner
                                      qualified-name)
                                    false)]
                                [plain-contract : String
                                  (comptime.string-append
                                    owner
                                    (comptime.string-append
                                      ".to-string : (-> (& "
                                      (comptime.string-append
                                        value-key
                                        ") String)")))]
                                [qualified-contract : String
                                  (comptime.string-append
                                    owner
                                    (comptime.string-append
                                      "."
                                      (comptime.string-append
                                        qualified-name
                                        (comptime.string-append
                                          " : (-> (& "
                                          (comptime.string-append
                                            value-key
                                            ") String)")))))]
                                [expected-contract : String
                                  (comptime.string-append
                                    plain-contract
                                    (comptime.string-append
                                      " or "
                                      qualified-contract))]
                                [plain-matches? : bool
                                  (if plain-present?
                                    (comptime.function-shared-borrow-returns-string?
                                      (comptime.module-value-type
                                        owner
                                        plain-name)
                                      value-type)
                                    false)]
                                [qualified-matches? : bool
                                  (if qualified-present?
                                    (comptime.function-shared-borrow-returns-string?
                                      (comptime.module-value-type
                                        owner
                                        qualified-name)
                                      value-type)
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
                                [integral? : bool
                                  (match value-kind
                                    ["i8" true]
                                    ["i16" true]
                                    ["i32" true]
                                    ["i64" true]
                                    ["u8" true]
                                    ["u16" true]
                                    ["u32" true]
                                    ["u64" true]
                                    [_ false])]
                                [float? : bool
                                  (match value-kind
                                    ["f64" true]
                                    ["f32" true]
                                    [_ false])]
                                [numeric? : bool
                                  (if integral?
                                    true
                                    float?)]
                                [rendered : comptime.Expr
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
                                        (if borrowed?
                                          `(,(comptime.module-value-expr
                                              owner
                                              plain-name)
                                            ,value)
                                          (comptime.expr-shared-call1
                                            (comptime.module-value-expr
                                              owner
                                              plain-name)
                                            value))]
                                      [2
                                        (if borrowed?
                                          `(,(comptime.module-value-expr
                                              owner
                                              qualified-name)
                                            ,value)
                                          (comptime.expr-shared-call1
                                            (comptime.module-value-expr
                                              owner
                                              qualified-name)
                                            value))]
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
                                                    (comptime.string-append
                                                      "; expected "
                                                      expected-contract))))))
                                          (comptime.comptime-error
                                            (comptime.string-append
                                              "format: unsupported nominal type "
                                              (comptime.string-append
                                                value-key
                                                (comptime.string-append
                                                  " from canonical owner module "
                                                  (comptime.string-append
                                                    owner
                                                    (comptime.string-append
                                                      "; expected "
                                                      expected-contract)))))))])
                                    (match value-kind
                                      ["string"
                                        (if borrowed?
                                          `(stdlib.string.copy ,value)
                                          value)]
                                      ["str" `(stdlib.string.copy ,value)]
                                      ["i8"
                                        (if borrowed?
                                          `(stdlib.string.int->string
                                            (cast (deref ,value) : i64))
                                          `(stdlib.string.int->string
                                            (cast ,value : i64)))]
                                      ["i16"
                                        (if borrowed?
                                          `(stdlib.string.int->string
                                            (cast (deref ,value) : i64))
                                          `(stdlib.string.int->string
                                            (cast ,value : i64)))]
                                      ["i32"
                                        (if borrowed?
                                          `(stdlib.string.int->string
                                            (cast (deref ,value) : i64))
                                          `(stdlib.string.int->string
                                            (cast ,value : i64)))]
                                      ["i64"
                                        (if borrowed?
                                          `(stdlib.string.int->string
                                            (deref ,value))
                                          `(stdlib.string.int->string ,value))]
                                      ["u8"
                                        (if borrowed?
                                          `(stdlib.format.format-u64-core
                                            (cast (deref ,value) : u64))
                                          `(stdlib.format.format-u64-core
                                            (cast ,value : u64)))]
                                      ["u16"
                                        (if borrowed?
                                          `(stdlib.format.format-u64-core
                                            (cast (deref ,value) : u64))
                                          `(stdlib.format.format-u64-core
                                            (cast ,value : u64)))]
                                      ["u32"
                                        (if borrowed?
                                          `(stdlib.format.format-u64-core
                                            (cast (deref ,value) : u64))
                                          `(stdlib.format.format-u64-core
                                            (cast ,value : u64)))]
                                      ["u64"
                                        (if borrowed?
                                          `(stdlib.format.format-u64-core
                                            (deref ,value))
                                          `(stdlib.format.format-u64-core
                                            ,value))]
                                      ["bool"
                                        (if borrowed?
                                          `(if (deref ,value)
                                            "true"
                                            "false")
                                          `(if ,value
                                            "true"
                                            "false"))]
                                      ["char"
                                        (if borrowed?
                                          `(stdlib.format.format-char-string
                                            (deref ,value))
                                          `(stdlib.format.format-char-string
                                            ,value))]
                                      ["f64"
                                        (if borrowed?
                                          `(stdlib.format.format-float-core
                                            (deref ,value))
                                          `(stdlib.format.format-float-core
                                            ,value))]
                                      ["f32"
                                        (if borrowed?
                                          `(stdlib.format.format-f32-core
                                            (deref ,value))
                                          `(stdlib.format.format-f32-core
                                            ,value))]
                                      [_
                                        (comptime.comptime-error
                                          (comptime.string-append
                                            "format: unsupported argument type "
                                            value-key))]))]
                                (begin
                                  (if (string.eq selector "")
                                    unit
                                    (comptime.comptime-error
                                      (comptime.string-append
                                        "format: type selector is parsed but not supported yet: "
                                        selector)))
                                  (if (= sign 1)
                                    (if numeric?
                                      unit
                                      (comptime.comptime-error
                                        "format: '+' sign requires a numeric argument"))
                                    unit)
                                  (let
                                    [resolved-width : comptime.Expr
                                      (if (= width-kind 0)
                                        (comptime.expr-int 0)
                                        (if (= width-kind 1)
                                          width-value
                                          (let
                                            [count-type : comptime.Expr
                                              (comptime.expr-type width-value)]
                                            [count-kind : String
                                              (type-kind count-type)]
                                            (if (string.eq count-kind "i64")
                                              `(stdlib.format.format-width-count-runtime
                                                ,width-value)
                                              (if (if (string.eq
                                                count-kind
                                                "ref")
                                                (string.eq
                                                  (type-kind
                                                    (comptime.reference-element-type
                                                      count-type))
                                                  "i64")
                                                (if (string.eq
                                                  count-kind
                                                  "mut-ref")
                                                  (string.eq
                                                    (type-kind
                                                      (comptime.reference-element-type
                                                        count-type))
                                                    "i64")
                                                  false))
                                                `(stdlib.format.format-width-count-runtime
                                                  (deref ,width-value))
                                                (comptime.comptime-error
                                                  "format: dynamic width argument must have exact type i64"))))))]
                                    [resolved-precision : comptime.Expr
                                      (if (= precision-kind 0)
                                        (comptime.expr-int 0)
                                        (if (= precision-kind 1)
                                          precision-value
                                          (let
                                            [count-type : comptime.Expr
                                              (comptime.expr-type
                                                precision-value)]
                                            [count-kind : String
                                              (type-kind count-type)]
                                            (if (string.eq count-kind "i64")
                                              `(stdlib.format.format-precision-count-runtime
                                                ,precision-value)
                                              (if (if (string.eq
                                                count-kind
                                                "ref")
                                                (string.eq
                                                  (type-kind
                                                    (comptime.reference-element-type
                                                      count-type))
                                                  "i64")
                                                (if (string.eq
                                                  count-kind
                                                  "mut-ref")
                                                  (string.eq
                                                    (type-kind
                                                      (comptime.reference-element-type
                                                        count-type))
                                                    "i64")
                                                  false))
                                                `(stdlib.format.format-precision-count-runtime
                                                  (deref ,precision-value))
                                                (comptime.comptime-error
                                                  "format: dynamic precision argument must have exact type i64"))))))]
                                    [precision-applies? : bool
                                      (if (= precision-kind 0)
                                        false
                                        (not integral?))]
                                    [default-options? : bool
                                      (if (= fill-code 32)
                                        (if (= alignment 0)
                                          (if (= sign 0)
                                            (if (= alternate 0)
                                              (if (= zero 0)
                                                (if (= width-kind 0)
                                                  (not precision-applies?)
                                                  false)
                                                false)
                                              false)
                                            false)
                                          false)
                                        false)]
                                    [width-runtime? : bool (> width-kind 1)]
                                    [precision-runtime? : bool
                                      (> precision-kind 1)]
                                    [width-name : String
                                      (comptime.syntax-name-fresh
                                        "__tl_format_resolved_width")]
                                    [precision-name : String
                                      (comptime.syntax-name-fresh
                                        "__tl_format_resolved_precision")]
                                    [width-var : comptime.Expr
                                      (comptime.expr-var width-name)]
                                    [precision-var : comptime.Expr
                                      (comptime.expr-var precision-name)]
                                    [transported-width : comptime.Expr
                                      (if width-runtime?
                                        width-var
                                        resolved-width)]
                                    [transported-precision : comptime.Expr
                                      (if precision-runtime?
                                        precision-var
                                        resolved-precision)]
                                    [rendered-with-precision : comptime.Expr
                                      (if (if float?
                                        (!= precision-kind 0)
                                        false)
                                        (match value-kind
                                          ["f64"
                                            (if borrowed?
                                              `(stdlib.format.format-float-fixed-core
                                                (deref ,value)
                                                ,transported-precision)
                                              `(stdlib.format.format-float-fixed-core
                                                ,value
                                                ,transported-precision))]
                                          ["f32"
                                            (if borrowed?
                                              `(stdlib.format.format-f32-fixed-core
                                                (deref ,value)
                                                ,transported-precision)
                                              `(stdlib.format.format-f32-fixed-core
                                                ,value
                                                ,transported-precision))]
                                          [_ rendered])
                                        rendered)]
                                    [formatted : comptime.Expr
                                      (if default-options?
                                        rendered-with-precision
                                        (if numeric?
                                          `(stdlib.format.format-apply-options
                                            ,rendered-with-precision
                                            true
                                            (stdlib.format.FormatOptions
                                              (cast ,fill-expr : char)
                                              ,alignment-expr
                                              ,sign-expr
                                              (!= ,alternate-expr 0)
                                              (!= ,zero-expr 0)
                                              ,transported-width
                                              (!= ,precision-kind-expr 0)
                                              ,transported-precision))
                                          `(stdlib.format.format-apply-options
                                            ,rendered-with-precision
                                            false
                                            (stdlib.format.FormatOptions
                                              (cast ,fill-expr : char)
                                              ,alignment-expr
                                              ,sign-expr
                                              (!= ,alternate-expr 0)
                                              (!= ,zero-expr 0)
                                              ,transported-width
                                              (!= ,precision-kind-expr 0)
                                              ,transported-precision))))]
                                    [precision-checked : comptime.Expr
                                      (if precision-runtime?
                                        (comptime.expr-let-scope
                                          precision-name
                                          resolved-precision
                                          formatted)
                                        formatted)]
                                    (if width-runtime?
                                      (comptime.expr-let-scope
                                        width-name
                                        resolved-width
                                        precision-checked)
                                      precision-checked))))]
                            [_
                              (comptime.comptime-error
                                "format: internal precision option is malformed")])]
                        [_
                          (comptime.comptime-error
                            "format: internal width option is malformed")])]
                    [_
                      (comptime.comptime-error
                        "format: internal zero option is malformed")])]
                [_
                  (comptime.comptime-error
                    "format: internal alternate option is malformed")])]
            [_
              (comptime.comptime-error
                "format: internal sign option is malformed")])]
        [_
          (comptime.comptime-error
            "format: internal alignment option is malformed")])]
    [_ (comptime.comptime-error "format: internal fill option is malformed")]))

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
                                                "__tl_format_shared_named_"
                                                (comptime.int->string index)))]
                                          [fresh-var : comptime.Expr
                                            (comptime.expr-var fresh-name)]
                                          (begin
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
                                                      (comptime.expr-list-empty)))))))))))
                                  (if (!= named-state 0)
                                    (comptime.comptime-error
                                      "format: positional argument follows named argument")
                                    (let
                                      [argument-value : comptime.Expr
                                        `(,callee ,@call-items)]
                                      [value-kind : String
                                        (type-kind
                                          (comptime.expr-type argument-value))]
                                      [borrow-mode : i64
                                        (match value-kind
                                          ["struct" 1]
                                          ["enum" 1]
                                          ["region" 1]
                                          [_ 0])]
                                      [fresh-name : String
                                        (comptime.syntax-name-fresh
                                          (comptime.string-append
                                            "__tl_format_positional_"
                                            (comptime.int->string index)))]
                                      [fresh-var : comptime.Expr
                                        (comptime.expr-var fresh-name)]
                                      (begin
                                        (if (= borrow-mode 1)
                                          (set!
                                            fresh-var
                                            (comptime.expr-var
                                              (comptime.string-append
                                                "__tl_format_shared_"
                                                fresh-name)))
                                          unit)
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
                                                  (comptime.expr-list-empty)))))))))))]
                            [_
                              (if (!= named-state 0)
                                (comptime.comptime-error
                                  "format: positional argument follows named argument")
                                (let
                                  [value-kind : String
                                    (type-kind (comptime.expr-type argument))]
                                  [borrow-mode : i64
                                    (match value-kind
                                      ["struct" 1]
                                      ["enum" 1]
                                      ["region" 1]
                                      [_ 0])]
                                  [fresh-name : String
                                    (comptime.syntax-name-fresh
                                      (comptime.string-append
                                        "__tl_format_positional_"
                                        (comptime.int->string index)))]
                                  [fresh-var : comptime.Expr
                                    (comptime.expr-var fresh-name)]
                                  (begin
                                    (if (= borrow-mode 1)
                                      (set!
                                        fresh-var
                                        (comptime.expr-var
                                          (comptime.string-append
                                            "__tl_format_shared_"
                                            fresh-name)))
                                      unit)
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
                                              (comptime.expr-list-empty)))))))))])]
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
                                    ;; Validate every placeholder carrier and
                                    ;; every positional value/count reference.
                                    (while (>= plan-index 0)
                                      (let
                                        [piece : comptime.Expr
                                          (comptime.expr-list-nth
                                            plan-pieces
                                            plan-index)]
                                        [fields : comptime.ExprList
                                          (comptime.expr-list-empty)]
                                        (begin
                                          (match piece
                                            [(comptime.Expr.Begin found-fields)
                                              (set! fields found-fields)]
                                            [_ unit])
                                          (if (comptime.expr-string? piece)
                                            unit
                                            (if (!=
                                              (comptime.expr-list-length fields)
                                              14)
                                              (comptime.comptime-error
                                                "format: internal placeholder plan is malformed")
                                              (let
                                                [selector-kind : i64 -1]
                                                [implicit-state : i64 -1]
                                                [width-kind : i64 -1]
                                                [precision-kind : i64 -1]
                                                (begin
                                                  (match (comptime.expr-list-nth
                                                    fields
                                                    0)
                                                    [(comptime.Expr.Int found)
                                                      (set! selector-kind found)]
                                                    [_ unit])
                                                  (match (comptime.expr-list-nth
                                                    fields
                                                    2)
                                                    [(comptime.Expr.Int found)
                                                      (set!
                                                        implicit-state
                                                        found)]
                                                    [_ unit])
                                                  (match (comptime.expr-list-nth
                                                    fields
                                                    8)
                                                    [(comptime.Expr.Int found)
                                                      (set! width-kind found)]
                                                    [_ unit])
                                                  (match (comptime.expr-list-nth
                                                    fields
                                                    10)
                                                    [(comptime.Expr.Int found)
                                                      (set!
                                                        precision-kind
                                                        found)]
                                                    [_ unit])
                                                  (if (= selector-kind 0)
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      1)
                                                      [(comptime.Expr.Int
                                                          selected)
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
                                                          "format: internal positional selector is malformed")])
                                                    (if (= selector-kind 1)
                                                      (let
                                                        [selector-value : comptime.Expr
                                                          (comptime.expr-list-nth
                                                            fields
                                                            1)]
                                                        (if (not
                                                          (comptime.expr-string?
                                                            selector-value))
                                                          (comptime.comptime-error
                                                            "format: internal named selector is malformed")
                                                          unit))
                                                      (comptime.comptime-error
                                                        "format: internal selector kind is malformed")))
                                                  ;; Macro CTFE cannot invoke `cond`.
                                                  ;; lint-allow: nested-if-ladder
                                                  (if (= width-kind 2)
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      9)
                                                      [(comptime.Expr.Int
                                                          selected)
                                                        (if (>=
                                                          selected
                                                          positional-count)
                                                          (comptime.comptime-error
                                                            (comptime.string-append
                                                              "format: dynamic width argument index is out of range: "
                                                              (comptime.int->string
                                                                selected)))
                                                          unit)]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal width reference is malformed")])
                                                    (if (< width-kind 0)
                                                      (comptime.comptime-error
                                                        "format: internal width kind is malformed")
                                                      (if (> width-kind 3)
                                                        (comptime.comptime-error
                                                          "format: internal width kind is malformed")
                                                        unit)))
                                                  ;; Macro CTFE cannot invoke `cond`.
                                                  ;; lint-allow: nested-if-ladder
                                                  (if (if (= precision-kind 2)
                                                    true
                                                    (= precision-kind 4))
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      11)
                                                      [(comptime.Expr.Int
                                                          selected)
                                                        (if (>=
                                                          selected
                                                          positional-count)
                                                          (comptime.comptime-error
                                                            (comptime.string-append
                                                              "format: dynamic precision argument index is out of range: "
                                                              (comptime.int->string
                                                                selected)))
                                                          unit)]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal precision reference is malformed")])
                                                    (if (< precision-kind 0)
                                                      (comptime.comptime-error
                                                        "format: internal precision kind is malformed")
                                                      (if (> precision-kind 4)
                                                        (comptime.comptime-error
                                                          "format: internal precision kind is malformed")
                                                        unit)))))))
                                          (set! plan-index (- plan-index 1)))))
                                    ;; Every positional value/count reference
                                    ;; counts as a use. Scanner-resolved star
                                    ;; counts have already advanced the implicit
                                    ;; iterator; dollar references have not.
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
                                                [fields : comptime.ExprList
                                                  (comptime.expr-list-empty)]
                                                [slot : i64 0]
                                                (begin
                                                  (match piece
                                                    [(comptime.Expr.Begin
                                                        found-fields)
                                                      (set! fields found-fields)]
                                                    [_ unit])
                                                  (if (=
                                                    (comptime.expr-list-length
                                                      fields)
                                                    14)
                                                    (while (< slot 3)
                                                      (let
                                                        [reference-kind : i64
                                                          -1]
                                                        [reference-value : comptime.Expr
                                                          (comptime.expr-int 0)]
                                                        (begin
                                                          (if (= slot 0)
                                                            (begin
                                                              (match (comptime.expr-list-nth
                                                                fields
                                                                0)
                                                                [(comptime.Expr.Int
                                                                    found)
                                                                  (set!
                                                                    reference-kind
                                                                    found)]
                                                                [_ unit])
                                                              (set!
                                                                reference-value
                                                                (comptime.expr-list-nth
                                                                  fields
                                                                  1)))
                                                            (if (= slot 1)
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  8)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    9)))
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  10)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    11)))))
                                                          (if (= slot 0)
                                                            (if (=
                                                              reference-kind
                                                              0)
                                                              (match reference-value
                                                                [(comptime.Expr.Int
                                                                    selected)
                                                                  (if (=
                                                                    selected
                                                                    positional-index)
                                                                    (set!
                                                                      used?
                                                                      true)
                                                                    unit)]
                                                                [_ unit])
                                                              unit)
                                                            (if (if (=
                                                              reference-kind
                                                              2)
                                                              true
                                                              (if (= slot 2)
                                                                (=
                                                                  reference-kind
                                                                  4)
                                                                false))
                                                              (match reference-value
                                                                [(comptime.Expr.Int
                                                                    selected)
                                                                  (if (=
                                                                    selected
                                                                    positional-index)
                                                                    (set!
                                                                      used?
                                                                      true)
                                                                    unit)]
                                                                [_ unit])
                                                              unit))
                                                          (set! slot (+ slot 1)))))
                                                    unit)
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
                                    ;; Explicit named values may be selected as
                                    ;; either the rendered value or a count.
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
                                                [fields : comptime.ExprList
                                                  (comptime.expr-list-empty)]
                                                [slot : i64 0]
                                                (begin
                                                  (match piece
                                                    [(comptime.Expr.Begin
                                                        found-fields)
                                                      (set! fields found-fields)]
                                                    [_ unit])
                                                  (if (=
                                                    (comptime.expr-list-length
                                                      fields)
                                                    14)
                                                    (while (< slot 3)
                                                      (let
                                                        [reference-kind : i64
                                                          -1]
                                                        [reference-value : comptime.Expr
                                                          (comptime.expr-int 0)]
                                                        (begin
                                                          (if (= slot 0)
                                                            (begin
                                                              (match (comptime.expr-list-nth
                                                                fields
                                                                0)
                                                                [(comptime.Expr.Int
                                                                    found)
                                                                  (set!
                                                                    reference-kind
                                                                    found)]
                                                                [_ unit])
                                                              (set!
                                                                reference-value
                                                                (comptime.expr-list-nth
                                                                  fields
                                                                  1)))
                                                            (if (= slot 1)
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  8)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    9)))
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  10)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    11)))))
                                                          (if (= slot 0)
                                                            (if (=
                                                              reference-kind
                                                              1)
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  reference-value)
                                                                name)
                                                                (set!
                                                                  used?
                                                                  true)
                                                                unit)
                                                              unit)
                                                            (if (=
                                                              reference-kind
                                                              3)
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  reference-value)
                                                                name)
                                                                (set!
                                                                  used?
                                                                  true)
                                                                unit)
                                                              unit))
                                                          (set! slot (+ slot 1)))))
                                                    unit)
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
                                    ;; Discover selector/count captures in
                                    ;; template order, once per lexical name.
                                    (set! plan-index (- plan-len 1))
                                    (while (>= plan-index 0)
                                      (let
                                        [piece : comptime.Expr
                                          (comptime.expr-list-nth
                                            plan-pieces
                                            plan-index)]
                                        [fields : comptime.ExprList
                                          (comptime.expr-list-empty)]
                                        [slot : i64 0]
                                        (begin
                                          (match piece
                                            [(comptime.Expr.Begin found-fields)
                                              (set! fields found-fields)]
                                            [_ unit])
                                          (if (=
                                            (comptime.expr-list-length fields)
                                            14)
                                            (while (< slot 3)
                                              (let
                                                [reference-kind : i64 -1]
                                                [reference-value : comptime.Expr
                                                  (comptime.expr-int 0)]
                                                [named-reference? : bool false]
                                                (begin
                                                  (if (= slot 0)
                                                    (begin
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        0)
                                                        [(comptime.Expr.Int
                                                            found)
                                                          (set!
                                                            reference-kind
                                                            found)]
                                                        [_ unit])
                                                      (set!
                                                        reference-value
                                                        (comptime.expr-list-nth
                                                          fields
                                                          1)))
                                                    (if (= slot 1)
                                                      (begin
                                                        (match (comptime.expr-list-nth
                                                          fields
                                                          8)
                                                          [(comptime.Expr.Int
                                                              found)
                                                            (set!
                                                              reference-kind
                                                              found)]
                                                          [_ unit])
                                                        (set!
                                                          reference-value
                                                          (comptime.expr-list-nth
                                                            fields
                                                            9)))
                                                      (begin
                                                        (match (comptime.expr-list-nth
                                                          fields
                                                          10)
                                                          [(comptime.Expr.Int
                                                              found)
                                                            (set!
                                                              reference-kind
                                                              found)]
                                                          [_ unit])
                                                        (set!
                                                          reference-value
                                                          (comptime.expr-list-nth
                                                            fields
                                                            11)))))
                                                  (if (= slot 0)
                                                    (if (= reference-kind 1)
                                                      (set!
                                                        named-reference?
                                                        true)
                                                      unit)
                                                    (if (= reference-kind 3)
                                                      (set!
                                                        named-reference?
                                                        true)
                                                      unit))
                                                  (if named-reference?
                                                    (let
                                                      [name : String
                                                        (comptime.expr-string-value
                                                          reference-value)]
                                                      [explicit-index : i64 -1]
                                                      [capture-index : i64 -1]
                                                      [explicit-scan : i64 0]
                                                      [capture-scan : i64 0]
                                                      (begin
                                                        (while (<
                                                          explicit-scan
                                                          (comptime.expr-list-length
                                                            named-name-items))
                                                          (begin
                                                            (if (string.eq
                                                              (comptime.expr-string-value
                                                                (comptime.expr-list-nth
                                                                  named-name-items
                                                                  explicit-scan))
                                                              name)
                                                              (set!
                                                                explicit-index
                                                                explicit-scan)
                                                              unit)
                                                            (set!
                                                              explicit-scan
                                                              (+
                                                                explicit-scan
                                                                1))))
                                                        (while (<
                                                          capture-scan
                                                          (comptime.expr-list-length
                                                            capture-names))
                                                          (begin
                                                            (if (string.eq
                                                              (comptime.expr-string-value
                                                                (comptime.expr-list-nth
                                                                  capture-names
                                                                  capture-scan))
                                                              name)
                                                              (set!
                                                                capture-index
                                                                capture-scan)
                                                              unit)
                                                            (set!
                                                              capture-scan
                                                              (+ capture-scan 1))))
                                                        (if (< explicit-index 0)
                                                          (if (<
                                                            capture-index
                                                            0)
                                                            (let
                                                              [fresh-name : String
                                                                (comptime.syntax-name-fresh
                                                                  (comptime.string-append
                                                                    "__tl_format_shared_capture_"
                                                                    (comptime.int->string
                                                                      capture-count)))]
                                                              [fresh-var : comptime.Expr
                                                                (comptime.expr-var
                                                                  fresh-name)]
                                                              [entry-items : comptime.ExprList
                                                                (comptime.expr-list-cons
                                                                  fresh-var
                                                                  (comptime.expr-list-cons
                                                                    (comptime.expr-var
                                                                      name)
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
                                                                  (+
                                                                    capture-count
                                                                    1))))
                                                            unit)
                                                          unit)))
                                                    unit)
                                                  (set! slot (+ slot 1)))))
                                            unit)
                                          (set! plan-index (- plan-index 1)))))
                                    ;; Render the reverse plan into forward flat
                                    ;; concat operands while resolving names.
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
                                            [fields : comptime.ExprList
                                              (comptime.expr-list-empty)]
                                            (begin
                                              (match piece
                                                [(comptime.Expr.Begin
                                                    found-fields)
                                                  (set! fields found-fields)]
                                                [_ unit])
                                              (if (comptime.expr-string? piece)
                                                (set!
                                                  output
                                                  (comptime.expr-list-cons
                                                    piece
                                                    output))
                                                (let
                                                  [selector-kind : i64 -1]
                                                  [selected : comptime.Expr
                                                    (comptime.expr-int 0)]
                                                  [width-kind : i64 -1]
                                                  [resolved-width : comptime.Expr
                                                    (comptime.expr-int 0)]
                                                  [precision-kind : i64 -1]
                                                  [resolved-precision : comptime.Expr
                                                    (comptime.expr-int 0)]
                                                  (begin
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      0)
                                                      [(comptime.Expr.Int found)
                                                        (set!
                                                          selector-kind
                                                          found)]
                                                      [_ unit])
                                                    (if (= selector-kind 0)
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        1)
                                                        [(comptime.Expr.Int
                                                            selected-index)
                                                          (set!
                                                            selected
                                                            (comptime.expr-list-nth
                                                              positional-items
                                                              selected-index))]
                                                        [_ unit])
                                                      (let
                                                        [name : String
                                                          (comptime.expr-string-value
                                                            (comptime.expr-list-nth
                                                              fields
                                                              1))]
                                                        [scan : i64 0]
                                                        (begin
                                                          (while (<
                                                            scan
                                                            (comptime.expr-list-length
                                                              named-name-items))
                                                            (begin
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  (comptime.expr-list-nth
                                                                    named-name-items
                                                                    scan))
                                                                name)
                                                                (set!
                                                                  selected
                                                                  (comptime.expr-list-nth
                                                                    named-var-items
                                                                    scan))
                                                                unit)
                                                              (set!
                                                                scan
                                                                (+ scan 1))))
                                                          (set! scan 0)
                                                          (while (<
                                                            scan
                                                            (comptime.expr-list-length
                                                              capture-names))
                                                            (begin
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  (comptime.expr-list-nth
                                                                    capture-names
                                                                    scan))
                                                                name)
                                                                (set!
                                                                  selected
                                                                  (comptime.expr-list-nth
                                                                    capture-vars
                                                                    scan))
                                                                unit)
                                                              (set!
                                                                scan
                                                                (+ scan 1)))))))
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      8)
                                                      [(comptime.Expr.Int found)
                                                        (set! width-kind found)]
                                                      [_ unit])
                                                    (if (= width-kind 2)
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        9)
                                                        [(comptime.Expr.Int
                                                            width-index)
                                                          (set!
                                                            resolved-width
                                                            (comptime.expr-list-nth
                                                              positional-items
                                                              width-index))]
                                                        [_ unit])
                                                      (if (= width-kind 3)
                                                        (let
                                                          [name : String
                                                            (comptime.expr-string-value
                                                              (comptime.expr-list-nth
                                                                fields
                                                                9))]
                                                          [scan : i64 0]
                                                          (begin
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                named-name-items))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      named-name-items
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    resolved-width
                                                                    (comptime.expr-list-nth
                                                                      named-var-items
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))
                                                            (set! scan 0)
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                capture-names))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      capture-names
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    resolved-width
                                                                    (comptime.expr-list-nth
                                                                      capture-vars
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))))
                                                        (set!
                                                          resolved-width
                                                          (comptime.expr-list-nth
                                                            fields
                                                            9))))
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      10)
                                                      [(comptime.Expr.Int found)
                                                        (set!
                                                          precision-kind
                                                          found)]
                                                      [_ unit])
                                                    (if (if (= precision-kind 2)
                                                      true
                                                      (= precision-kind 4))
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        11)
                                                        [(comptime.Expr.Int
                                                            precision-index)
                                                          (set!
                                                            resolved-precision
                                                            (comptime.expr-list-nth
                                                              positional-items
                                                              precision-index))]
                                                        [_ unit])
                                                      (if (= precision-kind 3)
                                                        (let
                                                          [name : String
                                                            (comptime.expr-string-value
                                                              (comptime.expr-list-nth
                                                                fields
                                                                11))]
                                                          [scan : i64 0]
                                                          (begin
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                named-name-items))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      named-name-items
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    resolved-precision
                                                                    (comptime.expr-list-nth
                                                                      named-var-items
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))
                                                            (set! scan 0)
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                capture-names))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      capture-names
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    resolved-precision
                                                                    (comptime.expr-list-nth
                                                                      capture-vars
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))))
                                                        (set!
                                                          resolved-precision
                                                          (comptime.expr-list-nth
                                                            fields
                                                            11))))
                                                    (set!
                                                      output
                                                      (comptime.expr-list-cons
                                                        `(stdlib.format.format-value
                                                          ,selected
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            3)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            4)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            5)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            6)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            7)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            8)
                                                          ,resolved-width
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            10)
                                                          ,resolved-precision
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            12))
                                                        output)))))
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
                                            ;; Captures are reverse template
                                            ;; order; supplied bindings are
                                            ;; forward source order. The letter
                                            ;; s at generated-name offset 12
                                            ;; marks a shared binding.
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
                                                      (let
                                                        [init : comptime.Expr
                                                          (comptime.expr-list-nth
                                                            entry
                                                            1)]
                                                        (if (=
                                                          (cast
                                                            (string.string-ref
                                                              binding-name
                                                              12)
                                                            : i64)
                                                          115)
                                                          (set!
                                                            result
                                                            (comptime.expr-shared-let-scope
                                                              binding-name
                                                              init
                                                              result))
                                                          (set!
                                                            result
                                                            (comptime.expr-let-scope
                                                              binding-name
                                                              init
                                                              result))))]
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
                                                      (let
                                                        [init : comptime.Expr
                                                          (comptime.expr-list-nth
                                                            entry
                                                            1)]
                                                        (if (=
                                                          (cast
                                                            (string.string-ref
                                                              binding-name
                                                              12)
                                                            : i64)
                                                          115)
                                                          (set!
                                                            result
                                                            (comptime.expr-shared-let-scope
                                                              binding-name
                                                              init
                                                              result))
                                                          (set!
                                                            result
                                                            (comptime.expr-let-scope
                                                              binding-name
                                                              init
                                                              result))))]
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
;: Each placeholder is one `__tl_format_placeholder` plan record containing
;: value selection plus all common options. Argument expansion resolves value
;: and count references, evaluates supplied values once in source order,
;: captures missing names at the call site, and emits one flat `str-cat`.
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
                          [placeholder-start : i64 (+ index 1)]
                          [placeholder-end : i64 close]
                          [trimming : bool true]
                          (begin
                            (while trimming
                              (if (> placeholder-end placeholder-start)
                                (let
                                  [whitespace-code : i64
                                    (cast
                                      (string.string-ref
                                        text
                                        (- placeholder-end 1))
                                      : i64)]
                                  ;; CTFE cannot invoke the surface `cond` macro.
                                  ;; lint-allow: nested-if-ladder
                                  (if (if (= whitespace-code 9)
                                    true
                                    (if (= whitespace-code 10)
                                      true
                                      (if (= whitespace-code 11)
                                        true
                                        (if (= whitespace-code 12)
                                          true
                                          (if (= whitespace-code 13)
                                            true
                                            (= whitespace-code 32))))))
                                    (set! placeholder-end (- placeholder-end 1))
                                    (set! trimming false)))
                                (set! trimming false)))
                            (let
                              [colon : i64 -1]
                              [scan : i64 placeholder-start]
                              [argument-end : i64 placeholder-end]
                              [selector-kind : i64 0]
                              [selector-value : comptime.Expr
                                (comptime.expr-int 0)]
                              [implicit-state : i64 0]
                              [fill-code : i64 32]
                              [alignment : i64 0]
                              [sign : i64 0]
                              [alternate : i64 0]
                              [zero : i64 0]
                              [width-kind : i64 0]
                              [width-value : comptime.Expr
                                (comptime.expr-int 0)]
                              [precision-kind : i64 0]
                              [precision-value : comptime.Expr
                                (comptime.expr-int 0)]
                              [type-selector : String ""]
                              [valid-type-selector? : bool false]
                              (begin
                                (while (< scan placeholder-end)
                                  (begin
                                    (if (if (< colon 0)
                                      (=
                                        (cast
                                          (string.string-ref text scan)
                                          : i64)
                                        58)
                                      false)
                                      (set! colon scan)
                                      unit)
                                    (set! scan (+ scan 1))))
                                (if (>= colon 0)
                                  (set! argument-end colon)
                                  unit)
                                ;; Parse the value selector before the colon.
                                (if (= placeholder-start argument-end)
                                  (begin
                                    (set! selector-kind 0)
                                    (set!
                                      selector-value
                                      (comptime.expr-int next-implicit))
                                    (set! implicit-state 1)
                                    (set! next-implicit (+ next-implicit 1)))
                                  (let
                                    [first-code : i64
                                      (cast
                                        (string.string-ref
                                          text
                                          placeholder-start)
                                        : i64)]
                                    [argument-len : i64
                                      (- argument-end placeholder-start)]
                                    [argument-scan : i64 placeholder-start]
                                    [has-hash : bool false]
                                    [has-whitespace : bool false]
                                    [has-non-ascii : bool false]
                                    (begin
                                      (while (< argument-scan argument-end)
                                        (let
                                          [argument-code : i64
                                            (cast
                                              (string.string-ref
                                                text
                                                argument-scan)
                                              : i64)]
                                          (begin
                                            (if (= argument-code 35)
                                              (set! has-hash true)
                                              unit)
                                            ;; CTFE cannot invoke the surface
                                            ;; `cond` macro.
                                            ;; lint-allow: nested-if-ladder
                                            (if (if (= argument-code 9)
                                              true
                                              (if (= argument-code 10)
                                                true
                                                (if (= argument-code 11)
                                                  true
                                                  (if (= argument-code 12)
                                                    true
                                                    (if (= argument-code 13)
                                                      true
                                                      (= argument-code 32))))))
                                              (set! has-whitespace true)
                                              unit)
                                            (if (>= argument-code 128)
                                              (set! has-non-ascii true)
                                              unit)
                                            (set!
                                              argument-scan
                                              (+ argument-scan 1)))))
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
                                          [digit-index : i64 placeholder-start]
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
                                                  (if (not
                                                    (if (>= digit-code 48)
                                                      (<= digit-code 57)
                                                      false))
                                                    (comptime.comptime-error
                                                      "format: malformed positional argument index")
                                                    unit)
                                                  (let
                                                    [digit : i64
                                                      (- digit-code 48)]
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
                                            (set! selector-kind 0)
                                            (set!
                                              selector-value
                                              (comptime.expr-int value))))
                                        (let
                                          [name : String
                                            (comptime.string-slice
                                              text
                                              placeholder-start
                                              argument-len)]
                                          [name-index : i64 0]
                                          [valid? : bool true]
                                          (begin
                                            (if (string.eq name "_")
                                              (comptime.comptime-error
                                                "format: bare '_' is not a captured identifier")
                                              unit)
                                            (while (< name-index argument-len)
                                              (begin
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
                                                  ;; CTFE cannot invoke `cond`.
                                                  ;; lint-allow: nested-if-ladder
                                                  (if (not
                                                    ;; lint-allow: nested-if-ladder
                                                    (if (if (>= folded 97)
                                                      (<= folded 122)
                                                      false)
                                                      true
                                                      (if (if (>= name-code 48)
                                                        (<= name-code 57)
                                                        false)
                                                        true
                                                        (if (if (>=
                                                          name-code
                                                          42)
                                                          (<= name-code 63)
                                                          false)
                                                          (if (!= name-code 44)
                                                            (!= name-code 59)
                                                            false)
                                                          (if (= name-code 33)
                                                            true
                                                            (if (if (>=
                                                              name-code
                                                              37)
                                                              (<= name-code 38)
                                                              false)
                                                              true
                                                              (= name-code 95)))))))
                                                    (set! valid? false)
                                                    unit))
                                                (set!
                                                  name-index
                                                  (+ name-index 1))))
                                            (if valid?
                                              (begin
                                                (set! selector-kind 1)
                                                (set!
                                                  selector-value
                                                  (comptime.expr-string name)))
                                              (comptime.comptime-error
                                                "format: malformed captured argument identifier"))))))))
                                ;; Parse the stable format_spec grammar.
                                (let
                                  [cursor : i64
                                    (if (>= colon 0)
                                      (+ colon 1)
                                      placeholder-end)]
                                  (begin
                                    (if (< cursor placeholder-end)
                                      (let
                                        [first-align : i64 0]
                                        [second-align : i64 0]
                                        (begin
                                          (let
                                            [alignment-code : i64
                                              (cast
                                                (string.string-ref text cursor)
                                                : i64)]
                                            ;; Macro CTFE cannot invoke `cond`.
                                            ;; lint-allow: nested-if-ladder
                                            (if (= alignment-code 60)
                                              (set! first-align 1)
                                              (if (= alignment-code 94)
                                                (set! first-align 2)
                                                (if (= alignment-code 62)
                                                  (set! first-align 3)
                                                  unit))))
                                          (if (< (+ cursor 1) placeholder-end)
                                            (let
                                              [alignment-code : i64
                                                (cast
                                                  (string.string-ref
                                                    text
                                                    (+ cursor 1))
                                                  : i64)]
                                              ;; Macro CTFE cannot invoke `cond`.
                                              ;; lint-allow: nested-if-ladder
                                              (if (= alignment-code 60)
                                                (set! second-align 1)
                                                (if (= alignment-code 94)
                                                  (set! second-align 2)
                                                  (if (= alignment-code 62)
                                                    (set! second-align 3)
                                                    unit))))
                                            unit)
                                          (if (!= first-align 0)
                                            (begin
                                              (set! alignment first-align)
                                              (set! cursor (+ cursor 1)))
                                            (if (!= second-align 0)
                                              (begin
                                                (set!
                                                  fill-code
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      cursor)
                                                    : i64))
                                                (set! alignment second-align)
                                                (set! cursor (+ cursor 2)))
                                              (let
                                                [align-scan : i64 (+ cursor 2)]
                                                [late-align? : bool false]
                                                (begin
                                                  (while (<
                                                    align-scan
                                                    placeholder-end)
                                                    (begin
                                                      (let
                                                        [alignment-code : i64
                                                          (cast
                                                            (string.string-ref
                                                              text
                                                              align-scan)
                                                            : i64)]
                                                        (if (if (=
                                                          alignment-code
                                                          60)
                                                          true
                                                          (if (=
                                                            alignment-code
                                                            94)
                                                            true
                                                            (=
                                                              alignment-code
                                                              62)))
                                                          (set!
                                                            late-align?
                                                            true)
                                                          unit))
                                                      (set!
                                                        align-scan
                                                        (+ align-scan 1))))
                                                  (if late-align?
                                                    (comptime.comptime-error
                                                      "format: fill must be exactly one TypeLisp byte before alignment")
                                                    unit)))))))
                                      unit)
                                    (if (< cursor placeholder-end)
                                      (let
                                        [sign-code : i64
                                          (cast
                                            (string.string-ref text cursor)
                                            : i64)]
                                        (if (= sign-code 43)
                                          (begin
                                            (set! sign 1)
                                            (set! cursor (+ cursor 1)))
                                          (if (= sign-code 45)
                                            (begin
                                              (set! sign 2)
                                              (set! cursor (+ cursor 1)))
                                            unit)))
                                      unit)
                                    (if (if (< cursor placeholder-end)
                                      (=
                                        (cast
                                          (string.string-ref text cursor)
                                          : i64)
                                        35)
                                      false)
                                      (begin
                                        (set! alternate 1)
                                        (set! cursor (+ cursor 1)))
                                      unit)
                                    ;; `0$` is a dynamic width reference, not
                                    ;; the zero-padding flag.
                                    (if (if (< cursor placeholder-end)
                                      (=
                                        (cast
                                          (string.string-ref text cursor)
                                          : i64)
                                        48)
                                      false)
                                      (let
                                        [zero-scan : i64 cursor]
                                        [zero-scanning? : bool true]
                                        (begin
                                          (while zero-scanning?
                                            (if (< zero-scan placeholder-end)
                                              (let
                                                [digit-code : i64
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      zero-scan)
                                                    : i64)]
                                                (if (>= digit-code 48)
                                                  (if (<= digit-code 57)
                                                    (set!
                                                      zero-scan
                                                      (+ zero-scan 1))
                                                    (set! zero-scanning? false))
                                                  (set! zero-scanning? false)))
                                              (set! zero-scanning? false)))
                                          (if (if (< zero-scan placeholder-end)
                                            (=
                                              (cast
                                                (string.string-ref
                                                  text
                                                  zero-scan)
                                                : i64)
                                              36)
                                            false)
                                            unit
                                            (begin
                                              (set! zero 1)
                                              (set! cursor (+ cursor 1))))))
                                      unit)
                                    ;; Width: inline integer, N$, or name$.
                                    (let
                                      [width-digit? : bool false]
                                      (begin
                                        (if (< cursor placeholder-end)
                                          (let
                                            [digit-code : i64
                                              (cast
                                                (string.string-ref text cursor)
                                                : i64)]
                                            (if (>= digit-code 48)
                                              (if (<= digit-code 57)
                                                (set! width-digit? true)
                                                unit)
                                              unit))
                                          unit)
                                        (if width-digit?
                                          (let
                                            [width-number : i64 0]
                                            [width-scan : i64 cursor]
                                            [width-scanning? : bool true]
                                            (begin
                                              (while width-scanning?
                                                (if (<
                                                  width-scan
                                                  placeholder-end)
                                                  (let
                                                    [digit-code : i64
                                                      (cast
                                                        (string.string-ref
                                                          text
                                                          width-scan)
                                                        : i64)]
                                                    (if (>= digit-code 48)
                                                      (if (<= digit-code 57)
                                                        (let
                                                          [digit : i64
                                                            (- digit-code 48)]
                                                          (begin
                                                            (if (if (>
                                                              width-number
                                                              922337203685477580)
                                                              true
                                                              (if (=
                                                                width-number
                                                                922337203685477580)
                                                                (> digit 7)
                                                                false))
                                                              (comptime.comptime-error
                                                                "format: width integer overflow")
                                                              unit)
                                                            (set!
                                                              width-number
                                                              (+
                                                                (*
                                                                  width-number
                                                                  10)
                                                                digit))
                                                            (set!
                                                              width-scan
                                                              (+ width-scan 1))))
                                                        (set!
                                                          width-scanning?
                                                          false))
                                                      (set!
                                                        width-scanning?
                                                        false)))
                                                  (set! width-scanning? false)))
                                              (if (if (<
                                                width-scan
                                                placeholder-end)
                                                (=
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      width-scan)
                                                    : i64)
                                                  36)
                                                false)
                                                (begin
                                                  (set! width-kind 2)
                                                  (set!
                                                    width-value
                                                    (comptime.expr-int
                                                      width-number))
                                                  (set! cursor (+ width-scan 1)))
                                                (begin
                                                  (set! width-kind 1)
                                                  (set!
                                                    width-value
                                                    (comptime.expr-int
                                                      width-number))
                                                  (set! cursor width-scan)))))
                                          (if (if (< cursor placeholder-end)
                                            (!=
                                              (cast
                                                (string.string-ref text cursor)
                                                : i64)
                                              46)
                                            false)
                                            (let
                                              [name-scan : i64 cursor]
                                              [name-scanning? : bool true]
                                              (begin
                                                (while name-scanning?
                                                  (if (<
                                                    name-scan
                                                    placeholder-end)
                                                    (let
                                                      [name-code : i64
                                                        (cast
                                                          (string.string-ref
                                                            text
                                                            name-scan)
                                                          : i64)]
                                                      [folded : i64
                                                        (if (if (>=
                                                          name-code
                                                          65)
                                                          (<= name-code 90)
                                                          false)
                                                          (+ name-code 32)
                                                          name-code)]
                                                      ;; CTFE cannot invoke `cond`.
                                                      ;; lint-allow: nested-if-ladder
                                                      (if (if (>= folded 97)
                                                        (<= folded 122)
                                                        false)
                                                        (set!
                                                          name-scan
                                                          (+ name-scan 1))
                                                        (if (if (>=
                                                          name-code
                                                          48)
                                                          (<= name-code 57)
                                                          false)
                                                          (set!
                                                            name-scan
                                                            (+ name-scan 1))
                                                          (if (if (>=
                                                            name-code
                                                            42)
                                                            (<= name-code 63)
                                                            false)
                                                            (if (!=
                                                              name-code
                                                              44)
                                                              (if (!=
                                                                name-code
                                                                59)
                                                                (set!
                                                                  name-scan
                                                                  (+
                                                                    name-scan
                                                                    1))
                                                                (set!
                                                                  name-scanning?
                                                                  false))
                                                              (set!
                                                                name-scanning?
                                                                false))
                                                            (if (= name-code 33)
                                                              (set!
                                                                name-scan
                                                                (+ name-scan 1))
                                                              (if (if (>=
                                                                name-code
                                                                37)
                                                                (<=
                                                                  name-code
                                                                  38)
                                                                false)
                                                                (set!
                                                                  name-scan
                                                                  (+
                                                                    name-scan
                                                                    1))
                                                                (if (=
                                                                  name-code
                                                                  95)
                                                                  (set!
                                                                    name-scan
                                                                    (+
                                                                      name-scan
                                                                      1))
                                                                  (set!
                                                                    name-scanning?
                                                                    false))))))))
                                                    (set! name-scanning? false)))
                                                (if (if (<
                                                  name-scan
                                                  placeholder-end)
                                                  (=
                                                    (cast
                                                      (string.string-ref
                                                        text
                                                        name-scan)
                                                      : i64)
                                                    36)
                                                  false)
                                                  (let
                                                    [width-name : String
                                                      (comptime.string-slice
                                                        text
                                                        cursor
                                                        (- name-scan cursor))]
                                                    (begin
                                                      (if (= name-scan cursor)
                                                        (comptime.comptime-error
                                                          "format: malformed dynamic width name")
                                                        unit)
                                                      (if (string.eq
                                                        width-name
                                                        "_")
                                                        (comptime.comptime-error
                                                          "format: bare '_' is not a dynamic width name")
                                                        unit)
                                                      (set! width-kind 3)
                                                      (set!
                                                        width-value
                                                        (comptime.expr-string
                                                          width-name))
                                                      (set!
                                                        cursor
                                                        (+ name-scan 1))))
                                                  unit)))
                                            unit))))
                                    ;; Precision shares the independent implicit
                                    ;; value iterator. For `{:.*}`, the selector
                                    ;; provisionally consumed the count slot, so
                                    ;; move the value to the following slot.
                                    (if (if (< cursor placeholder-end)
                                      (=
                                        (cast
                                          (string.string-ref text cursor)
                                          : i64)
                                        46)
                                      false)
                                      (begin
                                        (set! cursor (+ cursor 1))
                                        (if (>= cursor placeholder-end)
                                          (comptime.comptime-error
                                            "format: precision requires a count or '*'")
                                          unit)
                                        (if (=
                                          (cast
                                            (string.string-ref text cursor)
                                            : i64)
                                          42)
                                          (begin
                                            (set! precision-kind 4)
                                            (set!
                                              precision-value
                                              (if (= implicit-state 1)
                                                selector-value
                                                (comptime.expr-int
                                                  next-implicit)))
                                            (if (= implicit-state 1)
                                              (set!
                                                selector-value
                                                (comptime.expr-int
                                                  next-implicit))
                                              unit)
                                            (set!
                                              next-implicit
                                              (+ next-implicit 1))
                                            (set! cursor (+ cursor 1)))
                                          (let
                                            [precision-digit? : bool false]
                                            (begin
                                              (let
                                                [digit-code : i64
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      cursor)
                                                    : i64)]
                                                (if (>= digit-code 48)
                                                  (if (<= digit-code 57)
                                                    (set! precision-digit? true)
                                                    unit)
                                                  unit))
                                              (if precision-digit?
                                                (let
                                                  [precision-number : i64 0]
                                                  [precision-scan : i64 cursor]
                                                  [precision-scanning? : bool
                                                    true]
                                                  (begin
                                                    (while precision-scanning?
                                                      (if (<
                                                        precision-scan
                                                        placeholder-end)
                                                        (let
                                                          [digit-code : i64
                                                            (cast
                                                              (string.string-ref
                                                                text
                                                                precision-scan)
                                                              : i64)]
                                                          (if (>= digit-code 48)
                                                            (if (<=
                                                              digit-code
                                                              57)
                                                              (let
                                                                [digit : i64
                                                                  (-
                                                                    digit-code
                                                                    48)]
                                                                (begin
                                                                  (if (if (>
                                                                    precision-number
                                                                    922337203685477580)
                                                                    true
                                                                    (if (=
                                                                      precision-number
                                                                      922337203685477580)
                                                                      (>
                                                                        digit
                                                                        7)
                                                                      false))
                                                                    (comptime.comptime-error
                                                                      "format: precision integer overflow")
                                                                    unit)
                                                                  (set!
                                                                    precision-number
                                                                    (+
                                                                      (*
                                                                        precision-number
                                                                        10)
                                                                      digit))
                                                                  (set!
                                                                    precision-scan
                                                                    (+
                                                                      precision-scan
                                                                      1))))
                                                              (set!
                                                                precision-scanning?
                                                                false))
                                                            (set!
                                                              precision-scanning?
                                                              false)))
                                                        (set!
                                                          precision-scanning?
                                                          false)))
                                                    (if (if (<
                                                      precision-scan
                                                      placeholder-end)
                                                      (=
                                                        (cast
                                                          (string.string-ref
                                                            text
                                                            precision-scan)
                                                          : i64)
                                                        36)
                                                      false)
                                                      (begin
                                                        (set! precision-kind 2)
                                                        (set!
                                                          precision-value
                                                          (comptime.expr-int
                                                            precision-number))
                                                        (set!
                                                          cursor
                                                          (+ precision-scan 1)))
                                                      (begin
                                                        (set! precision-kind 1)
                                                        (set!
                                                          precision-value
                                                          (comptime.expr-int
                                                            precision-number))
                                                        (set!
                                                          cursor
                                                          precision-scan)))))
                                                (let
                                                  [precision-scan : i64 cursor]
                                                  [precision-name-scanning? : bool
                                                    true]
                                                  (begin
                                                    (while precision-name-scanning?
                                                      (if (<
                                                        precision-scan
                                                        placeholder-end)
                                                        (let
                                                          [name-code : i64
                                                            (cast
                                                              (string.string-ref
                                                                text
                                                                precision-scan)
                                                              : i64)]
                                                          [folded : i64
                                                            (if (if (>=
                                                              name-code
                                                              65)
                                                              (<= name-code 90)
                                                              false)
                                                              (+ name-code 32)
                                                              name-code)]
                                                          ;; CTFE cannot invoke `cond`.
                                                          ;; lint-allow: nested-if-ladder
                                                          (if (if (>= folded 97)
                                                            (<= folded 122)
                                                            false)
                                                            (set!
                                                              precision-scan
                                                              (+
                                                                precision-scan
                                                                1))
                                                            (if (if (>=
                                                              name-code
                                                              48)
                                                              (<= name-code 57)
                                                              false)
                                                              (set!
                                                                precision-scan
                                                                (+
                                                                  precision-scan
                                                                  1))
                                                              (if (if (>=
                                                                name-code
                                                                42)
                                                                (<=
                                                                  name-code
                                                                  63)
                                                                false)
                                                                (if (!=
                                                                  name-code
                                                                  44)
                                                                  (if (!=
                                                                    name-code
                                                                    59)
                                                                    (set!
                                                                      precision-scan
                                                                      (+
                                                                        precision-scan
                                                                        1))
                                                                    (set!
                                                                      precision-name-scanning?
                                                                      false))
                                                                  (set!
                                                                    precision-name-scanning?
                                                                    false))
                                                                (if (=
                                                                  name-code
                                                                  33)
                                                                  (set!
                                                                    precision-scan
                                                                    (+
                                                                      precision-scan
                                                                      1))
                                                                  (if (if (>=
                                                                    name-code
                                                                    37)
                                                                    (<=
                                                                      name-code
                                                                      38)
                                                                    false)
                                                                    (set!
                                                                      precision-scan
                                                                      (+
                                                                        precision-scan
                                                                        1))
                                                                    (if (=
                                                                      name-code
                                                                      95)
                                                                      (set!
                                                                        precision-scan
                                                                        (+
                                                                          precision-scan
                                                                          1))
                                                                      (set!
                                                                        precision-name-scanning?
                                                                        false))))))))
                                                        (set!
                                                          precision-name-scanning?
                                                          false)))
                                                    (if (if (<
                                                      precision-scan
                                                      placeholder-end)
                                                      (=
                                                        (cast
                                                          (string.string-ref
                                                            text
                                                            precision-scan)
                                                          : i64)
                                                        36)
                                                      false)
                                                      (let
                                                        [precision-name : String
                                                          (comptime.string-slice
                                                            text
                                                            cursor
                                                            (-
                                                              precision-scan
                                                              cursor))]
                                                        (begin
                                                          (if (=
                                                            precision-scan
                                                            cursor)
                                                            (comptime.comptime-error
                                                              "format: malformed dynamic precision name")
                                                            unit)
                                                          (if (string.eq
                                                            precision-name
                                                            "_")
                                                            (comptime.comptime-error
                                                              "format: bare '_' is not a dynamic precision name")
                                                            unit)
                                                          (set!
                                                            precision-kind
                                                            3)
                                                          (set!
                                                            precision-value
                                                            (comptime.expr-string
                                                              precision-name))
                                                          (set!
                                                            cursor
                                                            (+ precision-scan 1))))
                                                      (comptime.comptime-error
                                                        "format: malformed precision count")))))))))
                                      unit)
                                    (set!
                                      type-selector
                                      (comptime.string-slice
                                        text
                                        cursor
                                        (- placeholder-end cursor)))
                                    (if (string.eq type-selector "")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "?")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "x?")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "X?")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "o")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "x")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "X")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "p")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "b")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "e")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "E")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (not valid-type-selector?)
                                      (comptime.comptime-error
                                        "format: malformed, duplicated, or out-of-order format specifier")
                                      unit)
                                    (let
                                      [placeholder : comptime.Expr
                                        (comptime.expr-begin-unit
                                          (comptime.expr-list-cons
                                            (comptime.expr-int selector-kind)
                                            (comptime.expr-list-cons
                                              selector-value
                                              (comptime.expr-list-cons
                                                (comptime.expr-int
                                                  implicit-state)
                                                (comptime.expr-list-cons
                                                  (comptime.expr-int fill-code)
                                                  (comptime.expr-list-cons
                                                    (comptime.expr-int
                                                      alignment)
                                                    (comptime.expr-list-cons
                                                      (comptime.expr-int sign)
                                                      (comptime.expr-list-cons
                                                        (comptime.expr-int
                                                          alternate)
                                                        (comptime.expr-list-cons
                                                          (comptime.expr-int
                                                            zero)
                                                          (comptime.expr-list-cons
                                                            (comptime.expr-int
                                                              width-kind)
                                                            (comptime.expr-list-cons
                                                              width-value
                                                              (comptime.expr-list-cons
                                                                (comptime.expr-int
                                                                  precision-kind)
                                                                (comptime.expr-list-cons
                                                                  precision-value
                                                                  (comptime.expr-list-cons
                                                                    (comptime.expr-string
                                                                      type-selector)
                                                                    (comptime.expr-list-empty)))))))))))))))]
                                      (set!
                                        plan-pieces
                                        (comptime.expr-list-cons
                                          placeholder
                                          plan-pieces))))))
                              (set! index (+ close 1))
                              (set! literal-start index)))))))))
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

;: Count decimal digits in an unsigned 64-bit value.
(define (format-u64-digit-count [value : u64]) : i64
  (let
    [cursor : u64 value]
    [digits : i64 1]
    (begin
      (while (>= cursor (cast 10 : u64))
        (begin
          (set! cursor (/ cursor (cast 10 : u64)))
          (set! digits (+ digits 1))))
      digits)))

;: Render the complete unsigned 64-bit range as decimal Display text.
(define (format-u64-core [value : u64]) : String
  (let
    [digits : i64 (format-u64-digit-count value)]
    [dst : (MutPtr u8) (string.string-runtime-alloc digits)]
    [cursor : u64 value]
    [index : i64 (- digits 1)]
    (begin
      (while (>= index 0)
        (let
          [next : u64 (/ cursor (cast 10 : u64))]
          [digit : u64 (- cursor (* next (cast 10 : u64)))]
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset dst index)
                (cast (+ digit (cast 48 : u64)) : u8)))
            (set! cursor next)
            (set! index (- index 1)))))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) digits)))))

;: Fixed-capacity base-2^32 bignum backing the pure-TL float formatter.
(defstruct BigNum
  (limbs (__tl_dyn-array u64))
  (len i64))

;: Limb capacity of formatter bignum scratch buffers.
(define ftoa-cap : i64
  40)

;: Limb capacity for exact fixed-precision f64 decimal coefficients.
;:
;: The largest coefficient is a 53-bit significand multiplied by `5^1074`,
;: which needs fewer than 81 base-2^32 limbs. Shortest Display keeps the
;: smaller `ftoa-cap` buffers so omitted precision does not regress.
(define ftoa-fixed-cap : i64
  84)

;: Decimal scratch bytes covering every value representable by 84 limbs.
(define ftoa-fixed-decimal-cap : i64
  820)

;: Low 32-bit mask isolating a base-2^32 limb.
(define ftoa-mask32 : u64
  0xffffffff)

;: A zero-valued formatter BigNum with caller-selected scratch capacity.
(define (bn-zero-cap [capacity : i64]) : BigNum
  (BigNum (array.make-array u64 capacity) 0))

;: A zero-valued shortest-formatter BigNum.
(define (bn-zero) : BigNum
  (bn-zero-cap stdlib.format.ftoa-cap))

;: BigNum holding the u64 value x with caller-selected scratch capacity.
(define (bn-from-u64-cap [x : u64] [capacity : i64]) : BigNum
  (let
    [r : BigNum (bn-zero-cap capacity)]
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

;: BigNum holding the u64 value x for shortest formatting.
(define (bn-from-u64 [x : u64]) : BigNum
  (bn-from-u64-cap x stdlib.format.ftoa-cap))

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
    [a-cap : i64 (array-length a.limbs)]
    [b-cap : i64 (array-length b.limbs)]
    [capacity : i64
      (if (> a-cap b-cap)
        a-cap
        b-cap)]
    [r : (__tl_dyn-array u64) (array.make-array u64 capacity)]
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
    [r : (__tl_dyn-array u64) (array.make-array u64 (array-length a.limbs))]
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
      [r : (__tl_dyn-array u64) (array.make-array u64 (array-length a.limbs))]
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

;: BigNum a multiplied by ten raised to p.
(define (bn-mul-pow10 [a : BigNum] [p : i64]) : BigNum
  (let
    [r : BigNum a]
    [remaining : i64 p]
    (begin
      (while (>= remaining 9)
        (begin
          (set! r (bn-mul-u32 r (cast 1000000000 : u64)))
          (set! remaining (- remaining 9))))
      (while (> remaining 0)
        (begin
          (set! r (bn-mul-u32 r (cast 10 : u64)))
          (set! remaining (- remaining 1))))
      r)))

;: BigNum a multiplied by five raised to p.
(define (bn-mul-pow5 [a : BigNum] [p : i64]) : BigNum
  (let
    [r : BigNum a]
    [remaining : i64 p]
    (begin
      (while (>= remaining 13)
        (begin
          (set! r (bn-mul-u32 r (cast 1220703125 : u64)))
          (set! remaining (- remaining 13))))
      (while (> remaining 0)
        (begin
          (set! r (bn-mul-u32 r (cast 5 : u64)))
          (set! remaining (- remaining 1))))
      r)))

;: Difference of BigNums a and b, assuming a >= b.
(define (bn-sub [a : BigNum] [b : BigNum]) : BigNum
  (let
    [r : (__tl_dyn-array u64) (array.make-array u64 (array-length a.limbs))]
    [borrow : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i a.len)
        (let
          [av : u64 (array-ref a.limbs i)]
          [bv : u64
            (if (< i b.len)
              (array-ref b.limbs i)
              (cast 0 : u64))]
          [subtrahend : u64 (+ bv borrow)]
          (begin
            (if (>= av subtrahend)
              (begin
                (set! (array-ref r i) (- av subtrahend))
                (set! borrow (cast 0 : u64)))
              (begin
                (set!
                  (array-ref r i)
                  (- (+ av (cast 0x100000000 : u64)) subtrahend))
                (set! borrow (cast 1 : u64))))
            (set! i (+ i 1)))))
      (BigNum r (bn-norm-len r a.len)))))

;: BigNum a shifted right by n bits.
(define (bn-shr-bits [a : BigNum] [n : i64]) : BigNum
  (if (or (= a.len 0) (<= n 0))
    a
    (let
      [limb-shift : i64 (/ n 32)]
      [bit-shift : i64 (% n 32)]
      [capacity : i64 (array-length a.limbs)]
      [r : (__tl_dyn-array u64) (array.make-array u64 capacity)]
      [out-len : i64
        (if (>= limb-shift a.len)
          0
          (- a.len limb-shift))]
      [i : i64 0]
      (begin
        (while (< i out-len)
          (let
            [source-index : i64 (+ i limb-shift)]
            [low : u64 (shr (array-ref a.limbs source-index) bit-shift)]
            [high : u64
              (if (if (= bit-shift 0)
                false
                (< (+ source-index 1) a.len))
                (bit-and
                  (shl (array-ref a.limbs (+ source-index 1)) (- 32 bit-shift))
                  stdlib.format.ftoa-mask32)
                (cast 0 : u64))]
            (begin
              (set!
                (array-ref r i)
                (bit-and (bit-or low high) stdlib.format.ftoa-mask32))
              (set! i (+ i 1)))))
        (BigNum r (bn-norm-len r out-len))))))

;: Whether one zero-based bit is set in a BigNum.
(define (bn-bit-set? [a : BigNum] [index : i64]) : bool
  (if (< index 0)
    false
    (let
      [limb-index : i64 (/ index 32)]
      [bit-index : i64 (% index 32)]
      (if (>= limb-index a.len)
        false
        (!=
          (bit-and
            (shr (array-ref a.limbs limb-index) bit-index)
            (cast 1 : u64))
          (cast 0 : u64))))))

;: Whether any of the lowest `count` bits are nonzero.
(define (bn-low-bits-nonzero? [a : BigNum] [count : i64]) : bool
  (if (<= count 0)
    false
    (let
      [full-limbs : i64 (/ count 32)]
      [partial-bits : i64 (% count 32)]
      [i : i64 0]
      [found : bool false]
      (begin
        (while (and (not found) (< i full-limbs) (< i a.len))
          (begin
            (when (!= (array-ref a.limbs i) (cast 0 : u64)) (set! found true))
            (set! i (+ i 1))))
        (if (if found
          false
          (if (= partial-bits 0)
            false
            (< full-limbs a.len)))
          (let
            [mask : u64 (- (shl (cast 1 : u64) partial-bits) (cast 1 : u64))]
            (!= (bit-and (array-ref a.limbs full-limbs) mask) (cast 0 : u64)))
          found)))))

;: Divide by 2^shift and round an exact midpoint to an even quotient.
(define (bn-round-shr-even [a : BigNum] [shift : i64]) : BigNum
  (if (<= shift 0)
    a
    (let
      [quotient : BigNum (bn-shr-bits a shift)]
      [half? : bool (bn-bit-set? a (- shift 1))]
      [lower? : bool (bn-low-bits-nonzero? a (- shift 1))]
      [odd? : bool
        (if (= quotient.len 0)
          false
          (!=
            (bit-and (array-ref quotient.limbs 0) (cast 1 : u64))
            (cast 0 : u64)))]
      (if (and half? (or lower? odd?))
        (bn-add
          quotient
          (bn-from-u64-cap (cast 1 : u64) (array-length a.limbs)))
        quotient))))

;: One base-2^32 long-division step by a u32-sized divisor.
(defstruct BigDivU32Step
  (quotient BigNum)
  (remainder u64))

;: Divide a BigNum by one nonzero value that fits in 32 bits.
(define (bn-div-u32 [a : BigNum] [divisor : u64]) : BigDivU32Step
  (let
    [r : (__tl_dyn-array u64) (array.make-array u64 (array-length a.limbs))]
    [remainder : u64 (cast 0 : u64)]
    [i : i64 (- a.len 1)]
    (begin
      (while (>= i 0)
        (let
          [current : u64 (bit-or (shl remainder 32) (array-ref a.limbs i))]
          [digit : u64 (/ current divisor)]
          (begin
            (set! (array-ref r i) digit)
            (set! remainder (- current (* digit divisor)))
            (set! i (- i 1)))))
      (BigDivU32Step (BigNum r (bn-norm-len r a.len)) remainder))))

;: One base-10 long-division digit and its exact remainder.
(defstruct BigDigitStep
  (digit i64)
  (remainder BigNum))

;: Divide num by den when the quotient is one decimal digit.
(define (bn-div-digit [num : BigNum] [den : BigNum]) : BigDigitStep
  (let
    [digit : i64 0]
    [remainder : BigNum num]
    (begin
      (while (>= (bn-cmp remainder den) 0)
        (begin
          (set! remainder (bn-sub remainder den))
          (set! digit (+ digit 1))))
      (BigDigitStep digit remainder))))

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

;: Expose an array's backing bytes without taking ownership.
(define (format-array-const-ptr [buf : (__tl_dyn-array u8)]) : (Ptr u8)
  (unsafe
    (ptr-cast (__tl_array-data buf) : (Ptr u8))))

;: Render one nonnegative BigNum as decimal digits.
(define (bn-decimal-string [value : BigNum]) : String
  (if (= value.len 0)
    "0"
    (let
      [out : (__tl_dyn-array u8)
        (array.make-array u8 stdlib.format.ftoa-fixed-decimal-cap)]
      [cursor : i64 stdlib.format.ftoa-fixed-decimal-cap]
      [current : BigNum value]
      (begin
        (while (> current.len 0)
          (let
            [step : BigDivU32Step (bn-div-u32 current (cast 1000000000 : u64))]
            [chunk : u64 step.remainder]
            [digit-count : i64
              (if (> step.quotient.len 0)
                9
                (format-u64-digit-count chunk))]
            [i : i64 0]
            (begin
              (while (< i digit-count)
                (let
                  [next : u64 (/ chunk (cast 10 : u64))]
                  [digit : u64 (- chunk (* next (cast 10 : u64)))]
                  (begin
                    (set! cursor (- cursor 1))
                    (set!
                      (array-ref out cursor)
                      (cast (+ digit (cast 48 : u64)) : u8))
                    (set! chunk next)
                    (set! i (+ i 1)))))
              (set! current step.quotient))))
        (unsafe
          (string-from-bytes
            (ptr-offset (format-array-const-ptr out) cursor)
            (- stdlib.format.ftoa-fixed-decimal-cap cursor)))))))

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

;: Format significant digits whose leading digit has decimal exponent k.
;: Rust Display always uses decimal notation, including very small/large values.
(define (ftoa-render [neg : bool] [s : String] [k : i64]) : String
  (let
    [body : String ""]
    [ndig : i64 (string-length s)]
    (begin
      (cond
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

;: Checked output byte length for fixed float Display.
(define (ftoa-fixed-output-length
  [neg : bool]
  [integer-digits : i64]
  [precision : i64]) : i64
  (let
    [base : i64
      (+
        integer-digits
        (if neg
          1
          0))]
    (if (= precision 0)
      base
      (if (> precision (- 9223372036854775807 (+ base 1)))
        (format-runtime-abort-string
          "format: fixed float output length overflow")
        (+ base (+ 1 precision))))))

;: Render exact decimal digits at `scale`, extending to requested precision.
;:
;: `precision >= scale`. Rounding has already happened when precision is below
;: the source value's exact terminating-decimal scale.
(define (ftoa-render-fixed
  [neg : bool]
  [digits : String]
  [scale : i64]
  [precision : i64]) : String
  (let
    [digits-len : i64 (string.string-length (& digits))]
    [decimal-position : i64 (- digits-len scale)]
    [integer-digits : i64
      (if (> decimal-position 0)
        decimal-position
        1)]
    [output-len : i64 (ftoa-fixed-output-length neg integer-digits precision)]
    [dst : (MutPtr u8) (string.string-runtime-alloc output-len)]
    [cursor : i64 0]
    (begin
      (when
        neg
        (begin
          (unsafe
            (ptr-write! dst (cast '-' : u8)))
          (set! cursor 1)))
      (if (= precision 0)
        (format-copy-rendered-range! (& digits) 0 dst cursor digits-len)
        (if (<= decimal-position 0)
          (begin
            (unsafe
              (ptr-write! (ptr-offset dst cursor) (cast '0' : u8)))
            (set! cursor (+ cursor 1))
            (unsafe
              (ptr-write! (ptr-offset dst cursor) (cast '.' : u8)))
            (set! cursor (+ cursor 1))
            (format-write-fill! dst cursor (- 0 decimal-position) '0')
            (set! cursor (+ cursor (- 0 decimal-position)))
            (format-copy-rendered-range! (& digits) 0 dst cursor digits-len)
            (set! cursor (+ cursor digits-len))
            (format-write-fill! dst cursor (- precision scale) '0'))
          (begin
            (format-copy-rendered-range!
              (& digits)
              0
              dst
              cursor
              decimal-position)
            (set! cursor (+ cursor decimal-position))
            (unsafe
              (ptr-write! (ptr-offset dst cursor) (cast '.' : u8)))
            (set! cursor (+ cursor 1))
            (format-copy-rendered-range!
              (& digits)
              decimal-position
              dst
              cursor
              (- digits-len decimal-position))
            (set! cursor (+ cursor (- digits-len decimal-position)))
            (format-write-fill! dst cursor (- precision scale) '0'))))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) output-len)))))

;: Ten raised to n for n <= 17.
(define (ftoa-pow10-u64 [n : i64]) : u64
  (let
    [result : u64 (cast 1 : u64)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! result (* result (cast 10 : u64)))
          (set! i (+ i 1))))
      result)))

;: Dragon-style shortest-decimal generation using exact interval boundaries.
(define (ftoa-shortest
  [neg : bool]
  [m : u64]
  [e2 : i64]
  [lower-close : bool]
  [max-digits : i64]) : String
  (let
    [mv : u64 (* m (cast 4 : u64))]
    [mp : u64 (+ mv (cast 2 : u64))]
    [mm : u64
      (-
        (- mv (cast 1 : u64))
        (if lower-close
          (cast 0 : u64)
          (cast 1 : u64)))]
    [boundary-e2 : i64 (- e2 2)]
    [r : BigNum (bn-from-u64 mv)]
    [s : BigNum (bn-from-u64 (cast 1 : u64))]
    [mminus : BigNum (bn-from-u64 (- mv mm))]
    [mplus : BigNum (bn-from-u64 (- mp mv))]
    [accept-bounds : bool (= (bit-and m (cast 1 : u64)) (cast 0 : u64))]
    [msb : i64 (ftoa-msb-index m)]
    [k : i64 (ftoa-floor-div (* (+ msb e2) 30103) 100000)]
    [prefix : u64 (cast 0 : u64)]
    [digits : i64 0]
    [done : bool false]
    (begin
      (if (>= boundary-e2 0)
        (begin
          (set! r (bn-shl-bits r boundary-e2))
          (set! mminus (bn-shl-bits mminus boundary-e2))
          (set! mplus (bn-shl-bits mplus boundary-e2)))
        (set! s (bn-shl-bits s (- 0 boundary-e2))))
      (if (>= k 0)
        (set! s (bn-mul-pow10 s k))
        (begin
          (set! r (bn-mul-pow10 r (- 0 k)))
          (set! mminus (bn-mul-pow10 mminus (- 0 k)))
          (set! mplus (bn-mul-pow10 mplus (- 0 k)))))
      (while (>= (bn-cmp r (bn-mul-u32 s (cast 10 : u64))) 0)
        (begin
          (set! s (bn-mul-u32 s (cast 10 : u64)))
          (set! k (+ k 1))))
      (while (< (bn-cmp r s) 0)
        (begin
          (set! r (bn-mul-u32 r (cast 10 : u64)))
          (set! mminus (bn-mul-u32 mminus (cast 10 : u64)))
          (set! mplus (bn-mul-u32 mplus (cast 10 : u64)))
          (set! k (- k 1))))
      (while (not done)
        (let
          [step : BigDigitStep (bn-div-digit r s)]
          [remainder : BigNum step.remainder]
          [low-cmp : i64 (bn-cmp remainder mminus)]
          [high-cmp : i64 (bn-cmp (bn-add remainder mplus) s)]
          [low : bool (or (< low-cmp 0) (and accept-bounds (= low-cmp 0)))]
          [high : bool (or (> high-cmp 0) (and accept-bounds (= high-cmp 0)))]
          (begin
            (set! prefix (+ (* prefix (cast 10 : u64)) (cast step.digit : u64)))
            (set! digits (+ digits 1))
            (if (or low high (>= digits max-digits))
              (let
                [round-up : bool false]
                (begin
                  (cond
                    [(and high (not low)) (set! round-up true)]
                    [(and low (not high)) unit]
                    [else
                      (let
                        [half-cmp : i64 (bn-cmp (bn-shl-bits remainder 1) s)]
                        (if (> half-cmp 0)
                          (set! round-up true)
                          (if (= half-cmp 0)
                            ;; Rust shortest Display breaks an exact decimal
                            ;; midpoint toward the larger magnitude.
                            (set! round-up true)
                            unit)))])
                  (when round-up (set! prefix (+ prefix (cast 1 : u64))))
                  (when (>= prefix (ftoa-pow10-u64 digits)) (set! k (+ k 1)))
                  (set! done true)))
              (begin
                (set! r (bn-mul-u32 remainder (cast 10 : u64)))
                (set! mminus (bn-mul-u32 mminus (cast 10 : u64)))
                (set! mplus (bn-mul-u32 mplus (cast 10 : u64))))))))
      (ftoa-render neg (ftoa-strip-zeros (cast prefix : i64)) k))))

;: Shared IEEE-754 Display implementation for f64 and f32 bit layouts.
(define (format-float-parts
  [neg : bool]
  [expf : u64]
  [frac : u64]
  [exp-max : u64]
  [mantissa-bits : i64]
  [bias : i64]
  [max-digits : i64]) : String
  (begin
    (when
      (= expf exp-max)
      (return
        (if (= frac (cast 0 : u64))
          (if neg
            "-inf"
            "inf")
          "NaN")))
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
          (bit-or frac (shl (cast 1 : u64) mantissa-bits)))]
      [e2 : i64
        (if (= expf (cast 0 : u64))
          (- (- 1 bias) mantissa-bits)
          (- (- (cast expf : i64) bias) mantissa-bits))]
      [lower-close : bool (and (= frac (cast 0 : u64)) (> expf (cast 1 : u64)))]
      (ftoa-shortest neg m e2 lower-close max-digits))))

;: Shared exact fixed-precision implementation for f64 and f32 bit layouts.
(define (format-float-fixed-parts
  [neg : bool]
  [expf : u64]
  [frac : u64]
  [exp-max : u64]
  [mantissa-bits : i64]
  [bias : i64]
  [precision : i64]) : String
  (begin
    (when
      (= expf exp-max)
      (return
        (if (= frac (cast 0 : u64))
          (if neg
            "-inf"
            "inf")
          "NaN")))
    (when
      (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
      (return (ftoa-render-fixed neg "0" 0 precision)))
    (let
      [m : u64
        (if (= expf (cast 0 : u64))
          frac
          (bit-or frac (shl (cast 1 : u64) mantissa-bits)))]
      [e2 : i64
        (if (= expf (cast 0 : u64))
          (- (- 1 bias) mantissa-bits)
          (- (- (cast expf : i64) bias) mantissa-bits))]
      [base : BigNum (bn-from-u64-cap m stdlib.format.ftoa-fixed-cap)]
      (if (>= e2 0)
        (ftoa-render-fixed
          neg
          (bn-decimal-string (bn-shl-bits base e2))
          0
          precision)
        (let
          [exact-scale : i64 (- 0 e2)]
          (if (< precision exact-scale)
            (let
              [scaled : BigNum (bn-mul-pow5 base precision)]
              [rounded : BigNum
                (bn-round-shr-even scaled (- exact-scale precision))]
              (ftoa-render-fixed
                neg
                (bn-decimal-string rounded)
                precision
                precision))
            (let
              [coefficient : BigNum (bn-mul-pow5 base exact-scale)]
              (ftoa-render-fixed
                neg
                (bn-decimal-string coefficient)
                exact-scale
                precision))))))))

;: Render an f64 with Rust Display-compatible shortest decimal semantics.
(define (format-float-core [value : f64]) : String
  (let
    [bits : u64 (__tl_float_to_bits value)]
    [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
    [frac : u64 (bit-and bits 0xfffffffffffff)]
    (format-float-parts neg expf frac (cast 0x7ff : u64) 52 1023 17)))

;: Render an f32 at source width (without widening through f64).
(define (format-f32-core [value : f32]) : String
  (let
    [bits32 : u32 (__tl_float_to_bits value)]
    [bits : u64 (cast bits32 : u64)]
    [neg : bool (= (bit-and (shr bits 31) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 23) (cast 0xff : u64))]
    [frac : u64 (bit-and bits (cast 0x7fffff : u64))]
    (format-float-parts neg expf frac (cast 0xff : u64) 23 127 9)))

;: Render an f64 with exact fixed precision and round-half-to-even.
(define (format-float-fixed-core [value : f64] [precision : i64]) : String
  (let
    [bits : u64 (__tl_float_to_bits value)]
    [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
    [frac : u64 (bit-and bits 0xfffffffffffff)]
    (format-float-fixed-parts
      neg
      expf
      frac
      (cast 0x7ff : u64)
      52
      1023
      precision)))

;: Render an f32 at source width with exact fixed precision.
(define (format-f32-fixed-core [value : f32] [precision : i64]) : String
  (let
    [bits32 : u32 (__tl_float_to_bits value)]
    [bits : u64 (cast bits32 : u64)]
    [neg : bool (= (bit-and (shr bits 31) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 23) (cast 0xff : u64))]
    [frac : u64 (bit-and bits (cast 0x7fffff : u64))]
    (format-float-fixed-parts neg expf frac (cast 0xff : u64) 23 127 precision)))