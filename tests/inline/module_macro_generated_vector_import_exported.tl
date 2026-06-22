;; module_macro_generated_vector_import_exported.tl - exported module macros keep
;; their defining-module lookup context for generated body imports.
(import "stdlib/test.tl")
(import "module_macro_vector_provider.tl" module tests.module_macro_vector_provider as provider)
(import (provider.vector-user i64) as user)
(import (provider.vector-user String) as string-user)

(test
  generated-module-body-imports-exported-vector-module-macro
  (assert-i64-eq
    (user.score 7 0)
    42
    "exported generated module imported vector macro"))

(test
  generated-module-body-imports-exported-string-vector-module-macro
  (assert-i64-eq
    (string-user.score "alpha" "fallback")
    42
    "exported generated module imported string vector macro"))