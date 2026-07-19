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
;#   (let [name : String "Ada"]
;#     (if (string.eq (format.format "hello, {}" name) "hello, Ada") 42 1)))
;# ```
;#
;# Supported placeholder values are `String`, `i64`, `bool`, `char`, `f64`, and
;# `f32`. Other types require an explicit string conversion before formatting.
(import stdlib.comptime)
(import stdlib.io)
(cfg test (import stdlib.test))

;: Format a literal template and positional values into a freshly allocated String.
(defmacro (format [template : comptime.Expr] [args : comptime.Expr ...]) : String
  `(stdlib.io.format-with stdlib.io.format-float-core ,template ,@args))

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