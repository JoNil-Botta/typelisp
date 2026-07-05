;; module_macro_generated_body_imports_vector_module.tl - generated module
;; bodies can import stdlib.vector and then instantiate `(vector T)`.
(import stdlib.test)

(defmacro (vector-user) : Module
  `(begin
    (module generated.body_imports_vector_user)
    (import stdlib.vector)
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
  generated-module-body-imports-vector-module
  (test.assert-i64-eq
    (user.score (user.make 42))
    42
    "generated module body imports vector module"))