;; module_macro_generated_local_type_vector_import.tl - generated module bodies
;; can use a locally generated type in a later `(vector T)` import.
(import stdlib.test)
(import stdlib.vector)

(defmacro (vector-user) : Module
  `(begin
    (module generated.local_type_vector_user)
    (defstruct T
      (value i64))
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
  generated-module-local-type-vector-import
  (test.assert-i64-eq
    (user.score (user.make 42))
    42
    "generated module local type vector"))
