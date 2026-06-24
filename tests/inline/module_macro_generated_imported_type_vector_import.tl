;; module_macro_generated_imported_type_vector_import.tl - generated module
;; bodies can use a flat-imported generated type in a later `(vector T)` import.
(import "stdlib/test.tl")
(import "stdlib/vector.tl")

(defmacro (type-provider) : Module
  `(begin
    (module generated.imported_type_vector_provider)
    (defstruct T
      (value i64))))

(defmacro (vector-user) : Module
  `(begin
    (module generated.imported_type_vector_user)
    (import (type-provider))
    (import (vector T) as vec)
    (define (make [value : i64]) : T
      (T value))
    (define (score [value : T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push (&mut items) value)
          (struct-get (vec.get (& items) 0 (T 0)) value))))))

(import (vector-user) as user)

(test
  generated-module-imported-type-vector-import
  (assert-i64-eq
    (user.score (user.make 42))
    42
    "generated module imported type vector"))