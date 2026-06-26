;; vector_macro_imported_json_aggregate.tl - regression for generated vectors
;; over imported aggregate element types with nested non-local fields.
(import "stdlib/test.tl")
(import stdlib.json)
(import stdlib.vector)
(import (vector json.Json) as jvec)
(import (vector json.JsonMember) as mvec)

(test
  vector-macro-imported-json-aggregate
  (let
    [items : jvec.Vec (jvec.new)]
    [members : mvec.Vec (mvec.new)]
    (begin
      (jvec.push (&mut items) json.JsonNull)
      (mvec.push (&mut members) (json.JsonMember "k" (json.JsonBool true)))
      (assert-i64-eq
        (+ (jvec.len (& items)) (mvec.len (& members)))
        2
        "generated json aggregate vector length")
      (let
        [snapshot : (Array json.JsonMember) (mvec.to-array (& members))]
        (match (struct-get (array-ref snapshot 0) value)
          [(json.JsonBool value)
            (assert-true value "generated json aggregate payload")]
          [_ (assert-true false "generated json aggregate wrong payload")])))))