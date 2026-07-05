;; module_macro_generated_stdlib_vector_alias_import_exported.tl - exported
;; module macros keep their defining-module dotted import context for bare
;; generated body imports of `(vector T)`.
(import stdlib.test)
;; Retained for #2454 path-import compatibility: the provider module name does
;; not map to this same-directory helper path.
(import "module_macro_stdlib_vector_alias_provider.tl" module tests.module_macro_stdlib_vector_alias_provider as provider)

(defstruct Pair
  (value i64))

(import (provider.vector-user i64) as user)
(import (provider.vector-user String) as string-user)
(import (provider.vector-user Pair) as pair-user)

(test
  exported-generated-module-body-dotted-context-bare-vector
  (test.assert-i64-eq
    (user.score 7 0)
    42
    "exported generated body dotted context bare vector import"))

(test
  exported-generated-module-body-dotted-context-bare-vector-string
  (test.assert-i64-eq
    (string-user.score "alpha" "fallback")
    42
    "exported generated body dotted context bare vector import string"))

(test
  exported-generated-module-body-dotted-context-bare-vector-struct
  (test.assert-i64-eq
    (pair-user.score (Pair 7) (Pair 0))
    42
    "exported generated body dotted context bare vector import struct"))
