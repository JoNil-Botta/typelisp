;; A macro-generated declaration and a caller-spliced type keep their names
;; (#10004 C43): the template's bare type name is the declaration the same
;; expansion emits, and `,T` stays the caller's type.
(defmacro (define-local-box [name : Expr]) : Decls
  `(begin
    (defstruct LocalBox
      (value i64))
    (define (,name [box : LocalBox]) : i64
      box.value)))

(define-local-box box-value)

(defmacro (value-of [T : type] [value : Expr]) : Expr
  `(let
    [v : ,T ,value]
    v))

(define (main) : i64
  (box-value (value-of LocalBox (LocalBox 42))))