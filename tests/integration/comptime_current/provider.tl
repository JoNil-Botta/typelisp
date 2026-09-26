;; Macros that report `comptime.current-module` from wherever they are called.
(import stdlib.comptime)

;: The module the call expands into, as a string literal.
(defmacro (where) : String
  (comptime.expr-string (comptime.current-module)))

;: A declaration naming the module it is spliced into.
(defmacro (declare-where [name : Expr]) : Decls
  `(define (,name) : String
    ,(comptime.expr-string (comptime.current-module))))

;: True when the call expands in `T`'s canonical owner module.
(defmacro (owned-here? [T : type]) : bool
  (comptime.expr-bool
    (__tl_string_eq (comptime.current-module) (type-nominal-module T))))

(define (provider-where) : String
  (where))

(declare-where provider-declared)