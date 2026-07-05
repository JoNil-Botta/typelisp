;; module_macro_generated_stdlib_vector_bare_import_exported.tl - exported
;; module macros keep their defining-module lookup context for bare generated
;; body imports of stdlib `(vector T)`.
(import stdlib.test)
;; Retained for #2454 path-import compatibility: the provider module name does
;; not map to this same-directory helper path.
(import "module_macro_stdlib_vector_bare_provider.tl" module tests.module_macro_stdlib_vector_bare_provider as provider)

(defstruct Pair
  (value i64))

(import (provider.vector-user i64) as user)
(import (provider.vector-user String) as string-user)
(import (provider.vector-user Pair) as pair-user)

(test
  generated-module-body-bare-imports-exported-stdlib-vector-module-macro
  (test.assert-i64-eq
    (user.score 7 0)
    42
    "exported generated module bare-imported stdlib vector macro"))

(test
  generated-module-body-bare-imports-exported-stdlib-string-vector-module-macro
  (test.assert-i64-eq
    (string-user.score "alpha" "fallback")
    42
    "exported generated module bare-imported stdlib string vector macro"))

(test
  generated-module-body-bare-imports-exported-stdlib-struct-vector-module-macro
  (test.assert-i64-eq
    (pair-user.score (Pair 7) (Pair 0))
    42
    "exported generated module bare-imported stdlib struct vector macro"))
