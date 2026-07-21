;; module_macro_generated_qualified_type_vector_import.tl - generated module
;; bodies can use an alias-qualified generated type in a later `(vector.vector T)`
;; import.
(import stdlib.test)
(import stdlib.vector)

(defmacro (type-provider) : Module
  `(begin
    (module generated.qualified_type_vector_provider)
    (defstruct T
      (value i64))))

(defmacro (vector-user) : Module
  `(begin
    (module generated.qualified_type_vector_user)
    (import (type-provider) as provider)
    (import (vector.vector provider.T) as vec)
    (define (make [value : i64]) : provider.T
      (provider.T value))
    (define (score [value : provider.T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push (&mut items) value)
          (struct-get (vec.get (& items) 0 (provider.T 0)) value))))))

(import (vector-user) as user)

(test
  generated-module-qualified-type-vector-import
  (test.assert-i64-eq
    (user.score (user.make 42))
    42
    "generated module qualified type vector"))