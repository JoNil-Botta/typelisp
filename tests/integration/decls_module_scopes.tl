(import stdlib.comptime)

;; These expansions have identical arguments in each consuming generated
;; module. Each module needs its own imported aliases and generated function.
(defmacro (emit-local) : Decls
  `(begin
    (import decls_generated_import_dep as local)
    (define (answer) : i64
      local.answer)))

(defmacro (make-scope [name : comptime.Expr]) : Module
  `(begin
    (module ,name)
    (emit-local)
    (emit-local)))

(import (make-scope generated.decls_scope_first) as first)
(import (make-scope generated.decls_scope_second) as second)
(import (make-scope generated.decls_scope_first) as repeated)

(define (main) : i64
  (+ (first.answer) (second.answer) (repeated.answer)))