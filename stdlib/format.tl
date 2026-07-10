;# Rust-style literal format-string macro returning a fresh String.
;#
;# `format` parses a string-literal template during macro expansion. Each `{}`
;# consumes one value and escapes use `{{` / `}}`. The generated expression is
;# one flat `str-cat` expansion, so the final string is allocated once.
;#
;# ```lisp test=run name=format-basic exit=42 stdout=""
;# (import stdlib.format)
;# (import stdlib.string)
;#
;# (define (main) : i64
;#   (let ([name : String "Ada"])
;#     (if (string.eq (format.format "hello, {}" name) "hello, Ada") 42 1)))
;# ```
;#
;# Supported placeholder values are `String`, `i64`, `bool`, `char`, `f64`, and
;# `f32`. Other types require an explicit string conversion before formatting.
(import stdlib.comptime)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.text_buf)
(cfg test (import stdlib.test))

;: Render one supported format placeholder as a String expression.
(defmacro (format-value [value : comptime.Expr]) : String
  (match (type-kind (comptime.expr-type value))
    ["string" value]
    ["i64" `(stdlib.string.int->string ,value)]
    ["bool"
      `(if ,value
        "true"
        "false")]
    ["char" `(stdlib.text_buf.char-string ,value)]
    ["f64" `(stdlib.io.format-float-core ,value)]
    ["f32" `(stdlib.io.format-float-core (cast ,value : f64))]
    [_
      (comptime.comptime-error
        (comptime.string-append
          "format: unsupported argument type "
          (type-kind (comptime.expr-type value))))]))

;: Append one generated String expression to the internal format carrier.
;:
;: The carrier uses a non-macro head while parsing. Rebuilding its argument list
;: through quasiquote keeps the eventual `str-cat` call flat without exposing a
;: mutable compiler syntax list API.
(defmacro (format-push [carrier : comptime.Expr] [piece : comptime.Expr]) : comptime.Expr
  (match carrier
    [(comptime.ExprCall callee pieces) `(,callee ,@pieces ,piece)]
    [_ carrier]))

;: Turn the completed internal carrier into the public single-allocation concat.
(defmacro (format-finish [carrier : comptime.Expr]) : String
  (match carrier
    [(comptime.ExprCall _ pieces) `(str_cat.str-cat ,@pieces)]
    [_ `""]))

;: Parse one byte of a literal format template and extend the output carrier.
(defmacro (format-from
  [template : comptime.Expr]
  [output-carrier : comptime.Expr]
  [offset : comptime.Expr]
  [arg-index : comptime.Expr]
  [args : comptime.Expr ...]) : String
  (match offset
    [(comptime.ExprInt index)
      (match arg-index
        [(comptime.ExprInt next-arg)
          (let
            [text : String (comptime.expr-string-value template)]
            [template-len : i64 (string.string-length text)]
            [arg-count : i64 (comptime.expr-list-length args)]
            (if (>= index template-len)
              (if (= next-arg arg-count)
                `(format-finish ,output-carrier)
                (comptime.comptime-error
                  "format: not enough placeholders for arguments"))
              (let
                [ch : char (string.string-ref text index)]
                (if (= (cast ch : i64) 123)
                  (if (>= (+ index 1) template-len)
                    (comptime.comptime-error "format: unmatched '{'")
                    (let
                      [following : char (string.string-ref text (+ index 1))]
                      (if (= (cast following : i64) 123)
                        `(format-from
                          ,(comptime.expr-string text)
                          (format-push
                            ,output-carrier
                            ,(comptime.expr-string
                              (comptime.string-slice text index 1)))
                          ,(comptime.expr-int (+ index 2))
                          ,(comptime.expr-int next-arg)
                          ,@args)
                        (if (= (cast following : i64) 125)
                          (if (>= next-arg arg-count)
                            (comptime.comptime-error
                              "format: not enough arguments for placeholders")
                            `(format-from
                              ,(comptime.expr-string text)
                              (format-push
                                ,output-carrier
                                (format-value
                                  ,(comptime.expr-list-nth args next-arg)))
                              ,(comptime.expr-int (+ index 2))
                              ,(comptime.expr-int (+ next-arg 1))
                              ,@args))
                          (comptime.comptime-error
                            "format: format specifiers are not supported")))))
                  (if (= (cast ch : i64) 125)
                    (if (>= (+ index 1) template-len)
                      (comptime.comptime-error "format: unmatched '}'")
                      (if (=
                        (cast (string.string-ref text (+ index 1)) : i64)
                        125)
                        `(format-from
                          ,(comptime.expr-string text)
                          (format-push
                            ,output-carrier
                            ,(comptime.expr-string
                              (comptime.string-slice text index 1)))
                          ,(comptime.expr-int (+ index 2))
                          ,(comptime.expr-int next-arg)
                          ,@args)
                        (comptime.comptime-error "format: unmatched '}'")))
                    `(format-from
                      ,(comptime.expr-string text)
                      (format-push
                        ,output-carrier
                        ,(comptime.expr-string
                          (comptime.string-slice text index 1)))
                      ,(comptime.expr-int (+ index 1))
                      ,(comptime.expr-int next-arg)
                      ,@args))))))]
        [_
          (comptime.comptime-error
            "format: internal argument index is not an integer")])]
    [_ (comptime.comptime-error "format: internal offset is not an integer")]))

;: Format a literal template and positional values into a freshly allocated String.
;:
;: `{}` consumes one argument; `{{` and `}}` produce literal braces. The
;: template must be a source string literal so syntax is deterministic and the
;: placeholder count is checked during macro expansion.
(defmacro (format [template : comptime.Expr] [args : comptime.Expr ...]) : String
  (if (comptime.expr-string? template)
    `(format-from
      ,(comptime.expr-string (comptime.expr-string-value template))
      (__format-output)
      0
      0
      ,@args)
    (comptime.comptime-error "format: template must be a string literal")))

(cfg
  test
  (test
    format-supported-values-and-braces
    (let
      [name : String "Ada"]
      [score : i64 -7]
      [enabled : bool true]
      [mark : char 'x']
      [ratio : f64 1.5]
      (test.assert-string-eq
        (format "{}:{}:{}:{}:{} {{ok}}" name score enabled mark ratio)
        "Ada:-7:true:x:1.5 {ok}"
        "format renders all supported values"))))