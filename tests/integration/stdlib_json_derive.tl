(import "stdlib/json.tl")
(import "stdlib/str_cat.tl")
(import "stdlib/string.tl")

(defstruct Address
  (zip i64)
  (city String))

(comptime-decl
  (:generated stdlib/json-derive AddressJson (type-key (type Address)))
  (defstruct AddressJson
    (__json_derive_request i64)))

(defstruct Person
  (name String)
  (age i32)
  (active bool)
  (home Address))

(comptime-decl
  (:generated stdlib/json-derive PersonJson (type-key (type Person)))
  (defstruct PersonJson
    (__json_derive_request i64)))

(comptime-decl
  (:generated stdlib/json-derive PersonJson (type-key (type Person)))
  (defstruct PersonJson
    (__json_derive_request i64)))

(define (json-derive-home-json) : Json
  (JsonObject
    (box
      (JsonMemberListCons
        "zip"
        (JsonNumber "12345")
        (box
          (JsonMemberListCons
            "city"
            (JsonString "London")
            (box JsonMemberListNil)))))))

(define (json-derive-person-json [age : Json]) : Json
  (JsonObject
    (box
      (JsonMemberListCons
        "name"
        (JsonString "Ada\nLovelace")
        (box
          (JsonMemberListCons
            "age"
            age
            (box
              (JsonMemberListCons
                "active"
                (JsonBool true)
                (box
                  (JsonMemberListCons
                    "home"
                    (json-derive-home-json)
                    (box JsonMemberListNil)))))))))))

(define (json-derive-person-missing-age) : Json
  (JsonObject
    (box
      (JsonMemberListCons
        "name"
        (JsonString "Ada")
        (box
          (JsonMemberListCons
            "active"
            (JsonBool true)
            (box
              (JsonMemberListCons
                "home"
                (json-derive-home-json)
                (box JsonMemberListNil)))))))))

(define (json-derive-address-ok? [home : Address]) : bool
  (and
    (= (struct-get home zip) 12345)
    (string-eq (struct-get home city) "London")))

(define (json-derive-person-ok? [person : Person]) : bool
  (and
    (string-eq (struct-get person name) "Ada\nLovelace")
    (= (struct-get person age) (cast 36 : i32))
    (struct-get person active)
    (json-derive-address-ok? (struct-get person home))))

(define (json-derive-roundtrip-ok?) : bool
  (let
    [person : Person
      (Person "Ada\nLovelace" (cast 36 : i32) true (Address 12345 "London"))]
    [json : Json (person-to-json person)]
    [encoded : String (stdlib.json.json-stringify json)]
    (and
      (string-eq
        encoded
        "{\"name\":\"Ada\\nLovelace\",\"age\":36,\"active\":true,\"home\":{\"zip\":12345,\"city\":\"London\"}}")
      (match (person-from-json json)
        [(OkPersonJson parsed) (json-derive-person-ok? parsed)]
        [(ErrPersonJson _) false]))))

(define (json-derive-missing-field-ok?) : bool
  (match (person-from-json (json-derive-person-missing-age))
    [(OkPersonJson _) false]
    [(ErrPersonJson _) true]))

(define (json-derive-wrong-kind-ok?) : bool
  (match (person-from-json (json-derive-person-json (JsonString "36")))
    [(OkPersonJson _) false]
    [(ErrPersonJson _) true]))

(define (json-derive-invalid-integer-ok?) : bool
  (match (person-from-json (json-derive-person-json (JsonNumber "36.5")))
    [(OkPersonJson _) false]
    [(ErrPersonJson _) true]))

(define (json-derive-direct-parse-ok?) : bool
  (match (person-from-json (json-derive-person-json (JsonNumber "36")))
    [(OkPersonJson parsed) (json-derive-person-ok? parsed)]
    [(ErrPersonJson _) false]))

(define (main) : i64
  (begin
    (unless (json-derive-roundtrip-ok?) (return 1))
    (unless (json-derive-direct-parse-ok?) (return 2))
    (unless (json-derive-missing-field-ok?) (return 3))
    (unless (json-derive-wrong-kind-ok?) (return 4))
    (unless (json-derive-invalid-integer-ok?) (return 5))
    42))