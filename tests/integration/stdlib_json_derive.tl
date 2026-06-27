(import stdlib.json)
(import stdlib.json_derive)
(import stdlib.string)

(defstruct Address
  (zip i64)
  (city String))

(import (json_derive.json-derive Address) as address_json)

(defstruct Person
  (name String)
  (age i32)
  (active bool)
  (home Address))

(import (json_derive.json-derive Person) as person_json)
(import (json_derive.json-derive Person) as person_json_again)

(define (json-derive-home-json) : json.Json
  (json.JsonObject
    (box
      (json.JsonMemberListCons
        "zip"
        (json.JsonNumber "12345")
        (box
          (json.JsonMemberListCons
            "city"
            (json.JsonString "London")
            (box json.JsonMemberListNil)))))))

(define (json-derive-person-json [age : json.Json]) : json.Json
  (json.JsonObject
    (box
      (json.JsonMemberListCons
        "name"
        (json.JsonString "Ada\nLovelace")
        (box
          (json.JsonMemberListCons
            "age"
            age
            (box
              (json.JsonMemberListCons
                "active"
                (json.JsonBool true)
                (box
                  (json.JsonMemberListCons
                    "home"
                    (json-derive-home-json)
                    (box json.JsonMemberListNil)))))))))))

(define (json-derive-person-missing-age) : json.Json
  (json.JsonObject
    (box
      (json.JsonMemberListCons
        "name"
        (json.JsonString "Ada")
        (box
          (json.JsonMemberListCons
            "active"
            (json.JsonBool true)
            (box
              (json.JsonMemberListCons
                "home"
                (json-derive-home-json)
                (box json.JsonMemberListNil)))))))))

(define (json-derive-address-ok? [home : Address]) : bool
  (and
    (= (struct-get home zip) 12345)
    (string.string-eq (struct-get home city) "London")))

(define (json-derive-person-ok? [person : Person]) : bool
  (and
    (string.string-eq (struct-get person name) "Ada\nLovelace")
    (= (struct-get person age) (cast 36 : i32))
    (struct-get person active)
    (json-derive-address-ok? (struct-get person home))))

(define (json-derive-roundtrip-ok?) : bool
  (let
    [person : Person
      (Person "Ada\nLovelace" (cast 36 : i32) true (Address 12345 "London"))]
    [json : json.Json (person_json.to-json person)]
    [encoded : String (stdlib.json.json-stringify json)]
    (and
      (string.string-eq
        encoded
        "{\"name\":\"Ada\\nLovelace\",\"age\":36,\"active\":true,\"home\":{\"zip\":12345,\"city\":\"London\"}}")
      (match (person_json.from-json json)
        [(person_json.Ok parsed) (json-derive-person-ok? parsed)]
        [(person_json.Err _) false]))))

(define (json-derive-address-roundtrip-ok?) : bool
  (let
    [home : Address (Address 12345 "London")]
    [json : json.Json (address_json.to-json home)]
    (match (address_json.from-json json)
      [(address_json.Ok parsed) (json-derive-address-ok? parsed)]
      [(address_json.Err _) false])))

(define (json-derive-missing-field-ok?) : bool
  (match (person_json.from-json (json-derive-person-missing-age))
    [(person_json.Ok _) false]
    [(person_json.Err _) true]))

(define (json-derive-wrong-kind-ok?) : bool
  (match (person_json.from-json
    (json-derive-person-json (json.JsonString "36")))
    [(person_json.Ok _) false]
    [(person_json.Err _) true]))

(define (json-derive-invalid-integer-ok?) : bool
  (match (person_json.from-json
    (json-derive-person-json (json.JsonNumber "36.5")))
    [(person_json.Ok _) false]
    [(person_json.Err _) true]))

(define (json-derive-direct-parse-ok?) : bool
  (match (person_json_again.from-json
    (json-derive-person-json (json.JsonNumber "36")))
    [(person_json_again.Ok parsed) (json-derive-person-ok? parsed)]
    [(person_json_again.Err _) false]))

(define (main) : i64
  (begin
    (unless (json-derive-roundtrip-ok?) (return 1))
    (unless (json-derive-direct-parse-ok?) (return 2))
    (unless (json-derive-missing-field-ok?) (return 3))
    (unless (json-derive-wrong-kind-ok?) (return 4))
    (unless (json-derive-invalid-integer-ok?) (return 5))
    (unless (json-derive-address-roundtrip-ok?) (return 6))
    42))