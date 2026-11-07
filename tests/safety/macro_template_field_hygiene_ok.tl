;; #8749: a field operand in a macro template names a struct member, not a
;; binding. Hygiene gives a template `len` that resolves to a visible global
;; (stdlib.byte_buf's `len`) or to a template-local binding its own identity;
;; the projection bridges and `comptime.expr-struct-get` still select the field.
(import stdlib.byte_buf)
(import stdlib.comptime)

(defstruct Span
  (owner i64)
  (len i64))

(defmacro (span-len [span : Expr]) : i64
  `(__tl-project-field ,span len))

(defmacro (span-len-with-local [span : Expr]) : i64
  `(let
    [len : i64 2]
    (+ len (__tl-project-field ,span len))))

(defmacro (span-set-len! [span : Expr] [value : Expr]) : unit
  `(__tl-project-set-field ,span len ,value))

(defmacro (field-of [target : Expr] [field : Expr]) : i64
  (match field
    [(comptime.Expr.Var name) (comptime.expr-struct-get target name)]
    [_ (comptime.comptime-error "field-of expects a field name")]))

(defmacro (span-len-through-field-of [span : Expr]) : i64
  `(field-of ,span len))

(define (main) : i32
  (let
    [span : Span (Span 1 3)]
    (span-set-len! span 10)
    ;; 10 + (2 + 10) + 10 + 10 = 42
    (cast
      (+
        (span-len span)
        (span-len-with-local span)
        (span-len-through-field-of span)
        span.len)
      : i32)))