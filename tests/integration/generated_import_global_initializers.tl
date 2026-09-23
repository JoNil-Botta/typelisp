;; The #7804 reproducer: generated modules define an integer global as an
;; imported module's global. Each generated `answer` must hold the imported
;; value (14, 14 and 7), not the imported global's address.
(defmacro (first-scope) : Module
  `(begin
    (module generated.import_global_first)
    (import decls_generated_import_dep as dep)
    (import decls_generated_import_dep as another)
    (import decls_generated_import_empty as empty)
    (define answer : i64
      dep.answer)))

(defmacro (second-scope) : Module
  `(begin
    (module generated.import_global_second)
    (import generated_import_alias_other_dep as dep)
    (import decls_generated_import_empty as empty)
    (define answer : i64
      dep.answer)))

(import (first-scope) as first)
(import (first-scope) as again)
(import (second-scope) as second)

(define (main) : i64
  (+ 7 (+ first.answer (+ again.answer second.answer))))