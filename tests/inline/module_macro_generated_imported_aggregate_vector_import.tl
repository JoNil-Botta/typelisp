;; module_macro_generated_imported_aggregate_vector_import.tl - generated module
;; bodies can instantiate stdlib vectors over definition-site imported types.
(import stdlib.test)
(import stdlib.json)
(import stdlib.vector)

(defmacro (json-vector-user) : Module
  `(begin
    (module generated.json_vector_user)
    (import (vector json.Json) as jvec)
    (define (score) : i64
      (let
        [items : jvec.Vec (jvec.new)]
        (jvec.len (& items))))))

(import (json-vector-user) as user)

(test
  generated-module-imported-aggregate-vector
  (test.assert-i64-eq (user.score) 0 "generated module imported aggregate vector"))
