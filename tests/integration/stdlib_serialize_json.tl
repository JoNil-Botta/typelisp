(import stdlib.json)
(import stdlib.serialize)
(import stdlib.string)

(defstruct Address
  (zip i64)
  (city String))

(import (serialize.serialize json Address) as address_json)

(defstruct Person
  (name String)
  (age i32)
  (active bool)
  (score f64)
  (ratio f32)
  (home Address))

(import (serialize.serialize json Person) as person_json)
(import (serialize.serialize json Person) as person_json_again)

(define (serialize-json-home-json) : json.Json
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

(define (serialize-json-person-json [age : json.Json]) : json.Json
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
                    "score"
                    (json.JsonNumber "9.5")
                    (box
                      (json.JsonMemberListCons
                        "ratio"
                        (json.JsonNumber "1.25")
                        (box
                          (json.JsonMemberListCons
                            "home"
                            (serialize-json-home-json)
                            (box json.JsonMemberListNil)))))))))))))))

(define (serialize-json-person-missing-age) : json.Json
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
                "score"
                (json.JsonNumber "9.5")
                (box
                  (json.JsonMemberListCons
                    "ratio"
                    (json.JsonNumber "1.25")
                    (box
                      (json.JsonMemberListCons
                        "home"
                        (serialize-json-home-json)
                        (box json.JsonMemberListNil)))))))))))))

(define (serialize-json-address-ok? [home : Address]) : bool
  (and
    (= (struct-get home zip) 12345)
    (string.string-eq (struct-get home city) "London")))

(define (serialize-json-person-ok? [person : Person]) : bool
  (and
    (string.string-eq (struct-get person name) "Ada\nLovelace")
    (= (struct-get person age) (cast 36 : i32))
    (struct-get person active)
    (= (struct-get person score) 9.5)
    (= (struct-get person ratio) (cast 1.25 : f32))
    (serialize-json-address-ok? (struct-get person home))))

(define (serialize-json-roundtrip-ok?) : bool
  (let
    [person : Person
      (Person
        "Ada\nLovelace"
        (cast 36 : i32)
        true
        9.5
        (cast 1.25 : f32)
        (Address 12345 "London"))]
    [json : json.Json (person_json.to-json person)]
    [encoded : String (stdlib.json.json-stringify json)]
    (and
      (string.string-eq
        encoded
        "{\"name\":\"Ada\\nLovelace\",\"age\":36,\"active\":true,\"score\":9.5,\"ratio\":1.25,\"home\":{\"zip\":12345,\"city\":\"London\"}}")
      (match (person_json.from-json json)
        [(person_json.Ok parsed) (serialize-json-person-ok? parsed)]
        [(person_json.Err _) false]))))

(define (serialize-json-address-roundtrip-ok?) : bool
  (let
    [home : Address (Address 12345 "London")]
    [json : json.Json (address_json.to-json home)]
    (match (address_json.from-json json)
      [(address_json.Ok parsed) (serialize-json-address-ok? parsed)]
      [(address_json.Err _) false])))

(define (serialize-json-missing-field-ok?) : bool
  (match (person_json.from-json (serialize-json-person-missing-age))
    [(person_json.Ok _) false]
    [(person_json.Err _) true]))

(define (serialize-json-wrong-kind-ok?) : bool
  (match (person_json.from-json
    (serialize-json-person-json (json.JsonString "36")))
    [(person_json.Ok _) false]
    [(person_json.Err _) true]))

(define (serialize-json-invalid-integer-ok?) : bool
  (match (person_json.from-json
    (serialize-json-person-json (json.JsonNumber "36.5")))
    [(person_json.Ok _) false]
    [(person_json.Err _) true]))

(define (serialize-json-direct-parse-ok?) : bool
  (match (person_json_again.from-json
    (serialize-json-person-json (json.JsonNumber "36")))
    [(person_json_again.Ok parsed) (serialize-json-person-ok? parsed)]
    [(person_json_again.Err _) false]))

(define (main) : i64
  (begin
    (unless (serialize-json-roundtrip-ok?) (return 1))
    (unless (serialize-json-direct-parse-ok?) (return 2))
    (unless (serialize-json-missing-field-ok?) (return 3))
    (unless (serialize-json-wrong-kind-ok?) (return 4))
    (unless (serialize-json-invalid-integer-ok?) (return 5))
    (unless (serialize-json-address-roundtrip-ok?) (return 6))
    42))