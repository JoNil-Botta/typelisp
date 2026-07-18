;; vector_macro_imported_json_aggregate.tl - regression for generated vectors
;; over imported aggregate element types with nested non-local fields.
(import stdlib.test)
(import stdlib.json)
(import stdlib.vector)
(import (vector json.Json core) as jvec)
(import (vector json.JsonMember core) as mvec)

(test
  vector-macro-imported-json-aggregate
  (let
    [members : mvec.Vec (mvec.new)]
    (begin
      (mvec.push (&mut members) (json.JsonMember "k" (json.JsonBool true)))
      (test.assert-i64-eq
        (mvec.len (& members))
        1
        "generated json aggregate vector length")
      (let
        [member : json.JsonMember
          (mvec.get (& members) 0 (json.JsonMember "" json.JsonNull))]
        (match (struct-get member value)
          [(json.JsonBool value)
            (test.assert-true value "generated json aggregate payload")]
          [_ (test.assert-true false "generated json aggregate wrong payload")])))))