;; A Decls splice can introduce a Module macro import, whose generated body
;; introduces another ordinary dependency. All stages share the same loader.
(defmacro (emit-module) : Module
  `(begin
    (module generated.decls_import_nested)
    (import decls_generated_import_dep as dep)
    (import decls_generated_import_dep.answer as selected)
    (define answer : i64
      (+ dep.answer (+ selected 14)))))

(defmacro (emit-nested-import) : Decls
  `(import (emit-module) as generated))

(emit-nested-import)

(emit-nested-import)

(define (main) : i64
  generated.answer)