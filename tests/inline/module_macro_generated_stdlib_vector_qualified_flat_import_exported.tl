;; module_macro_generated_stdlib_vector_qualified_flat_import_exported.tl -
;; exported module macros retain provider-qualified generated-body imports.
(import stdlib.test)

;; Retained for #2454 path-import compatibility: the provider module name does
;; not map to this same-directory helper path.
(import "module_macro_stdlib_vector_qualified_flat_provider.tl" module tests.module_macro_stdlib_vector_qualified_flat_provider as provider)

(defstruct Pair
  (value i64))

(import (provider.vector-user i64) as user)
(import (provider.vector-user String) as string-user)
(import (provider.vector-user Pair) as pair-user)

(test
  generated-module-body-flat-imports-exported-qualified-stdlib-vector-module-macro
  (test.assert-i64-eq
    (user.score 7 0)
    42
    "exported generated module flat-imported qualified stdlib vector macro"))

(test
  generated-module-body-flat-imports-exported-qualified-stdlib-string-vector-module-macro
  (test.assert-i64-eq
    (string-user.score "alpha" "fallback")
    42
    "exported generated module flat-imported qualified stdlib string vector macro"))

(test
  generated-module-body-flat-imports-exported-qualified-stdlib-struct-vector-module-macro
  (test.assert-i64-eq
    (pair-user.score (Pair 7) (Pair 0))
    42
    "exported generated module flat-imported qualified stdlib struct vector macro"))