;; vector_macro_imported_json_aggregate.tl - regression for generated vectors
;; over imported aggregate element types with nested non-local fields.
(import stdlib.test)
(import stdlib.json)
(import stdlib.vector)
(import (vector.vector json.Json core) as jvec)
(import (vector.vector json.JsonMember core) as mvec)

(test
  vector-macro-imported-json-aggregate
  (let
    [members : mvec.Vec (mvec.new)]
    (mvec.push-ref! (&mut members) (json.JsonMember "k" (JsonBool true)))
    (test.assert-i64-eq
      (mvec.len (& members))
      1
      "generated json aggregate vector length")
    (let
      [members-view : (& members (Slice json.JsonMember))
        (mvec.view (& members))]
      [member : (& members json.JsonMember) (& (array-ref members-view 0))]
      (match member.value
        [(JsonBool value)
          (test.assert-true value "generated json aggregate payload")]
        [_ (test.assert-true false "generated json aggregate wrong payload")]))))