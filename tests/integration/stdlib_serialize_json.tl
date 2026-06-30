(import stdlib.json)
(import stdlib.serialize)
(import stdlib.array)
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
  (home Address)
  (scores (Array i64 3))
  (previous (Array Address 2))
  (samples (Array i64))
  (combo (Tuple i64 Address (Array i64 2) (Array i64) (Tuple String bool))))

(import (serialize.serialize json Person) as person_json)
(import (serialize.serialize json Person) as person_json_again)

(define (serialize-json-member
  [key : String]
  [value : json.Json]
  [rest : json.JsonMemberList]) : json.JsonMemberList
  (json.JsonMemberListCons key value (box rest)))

(define (serialize-json-item [value : json.Json] [rest : json.JsonList]) : json.JsonList
  (json.JsonListCons value (box rest)))

(define (serialize-json-address-json [zip : String] [city : String]) : json.Json
  (json.JsonObject
    (box
      (serialize-json-member
        "zip"
        (json.JsonNumber zip)
        (serialize-json-member
          "city"
          (json.JsonString city)
          json.JsonMemberListNil)))))

(define (serialize-json-home-json) : json.Json
  (serialize-json-address-json "12345" "London"))

(define (serialize-json-scores-json) : json.Json
  (json.JsonArray
    (box
      (serialize-json-item
        (json.JsonNumber "4")
        (serialize-json-item
          (json.JsonNumber "5")
          (serialize-json-item (json.JsonNumber "6") json.JsonListNil))))))

(define (serialize-json-samples-json) : json.Json
  (json.JsonArray
    (box
      (serialize-json-item
        (json.JsonNumber "7")
        (serialize-json-item (json.JsonNumber "8") json.JsonListNil)))))

(define (serialize-json-previous-json) : json.Json
  (json.JsonArray
    (box
      (serialize-json-item
        (serialize-json-address-json "111" "Oxford")
        (serialize-json-item
          (serialize-json-address-json "222" "Paris")
          json.JsonListNil)))))

(define (serialize-json-combo-json) : json.Json
  (json.JsonArray
    (box
      (serialize-json-item
        (json.JsonNumber "99")
        (serialize-json-item
          (serialize-json-address-json "333" "Rome")
          (serialize-json-item
            (json.JsonArray
              (box
                (serialize-json-item
                  (json.JsonNumber "9")
                  (serialize-json-item (json.JsonNumber "10") json.JsonListNil))))
            (serialize-json-item
              (serialize-json-samples-json)
              (serialize-json-item
                (json.JsonArray
                  (box
                    (serialize-json-item
                      (json.JsonString "inner")
                      (serialize-json-item
                        (json.JsonBool true)
                        json.JsonListNil))))
                json.JsonListNil))))))))

(define (serialize-json-person-json [age : json.Json]) : json.Json
  (json.JsonObject
    (box
      (serialize-json-member
        "name"
        (json.JsonString "Ada\nLovelace")
        (serialize-json-member
          "age"
          age
          (serialize-json-member
            "active"
            (json.JsonBool true)
            (serialize-json-member
              "score"
              (json.JsonNumber "9.5")
              (serialize-json-member
                "ratio"
                (json.JsonNumber "1.25")
                (serialize-json-member
                  "home"
                  (serialize-json-home-json)
                  (serialize-json-member
                    "scores"
                    (serialize-json-scores-json)
                    (serialize-json-member
                      "previous"
                      (serialize-json-previous-json)
                      (serialize-json-member
                        "samples"
                        (serialize-json-samples-json)
                        (serialize-json-member
                          "combo"
                          (serialize-json-combo-json)
                          json.JsonMemberListNil)))))))))))))

(define (serialize-json-person-missing-age) : json.Json
  (json.JsonObject
    (box
      (serialize-json-member
        "name"
        (json.JsonString "Ada")
        (serialize-json-member
          "active"
          (json.JsonBool true)
          (serialize-json-member
            "score"
            (json.JsonNumber "9.5")
            (serialize-json-member
              "ratio"
              (json.JsonNumber "1.25")
              (serialize-json-member
                "home"
                (serialize-json-home-json)
                (serialize-json-member
                  "scores"
                  (serialize-json-scores-json)
                  (serialize-json-member
                    "previous"
                    (serialize-json-previous-json)
                    (serialize-json-member
                      "samples"
                      (serialize-json-samples-json)
                      json.JsonMemberListNil)))))))))))

(define (serialize-json-address-eq?
  [home : Address]
  [zip : i64]
  [city : String]) : bool
  (and (= (struct-get home zip) zip) (string.eq (struct-get home city) city)))

(define (serialize-json-address-ok? [home : Address]) : bool
  (serialize-json-address-eq? home 12345 "London"))

(define (serialize-json-scores-ok? [scores : (Array i64 3)]) : bool
  (and
    (= (array-ref scores 0) 4)
    (= (array-ref scores 1) 5)
    (= (array-ref scores 2) 6)))

(define (serialize-json-samples-ok? [samples : (Array i64)]) : bool
  (and
    (= (array-length samples) 2)
    (= (array-ref samples 0) 7)
    (= (array-ref samples 1) 8)))

(define (serialize-json-previous-ok? [previous : (Array Address 2)]) : bool
  (and
    (serialize-json-address-eq? (array-ref previous 0) 111 "Oxford")
    (serialize-json-address-eq? (array-ref previous 1) 222 "Paris")))

(define (serialize-json-combo-ok?
  [combo : (Tuple i64 Address (Array i64 2) (Array i64) (Tuple String bool))]) : bool
  (and
    (= (tuple-ref combo 0) 99)
    (serialize-json-address-eq? (tuple-ref combo 1) 333 "Rome")
    (= (array.ref (tuple-ref combo 2) 0) 9)
    (= (array.ref (tuple-ref combo 2) 1) 10)
    (serialize-json-samples-ok? (tuple-ref combo 3))
    (string.eq (tuple-ref (tuple-ref combo 4) 0) "inner")
    (tuple-ref (tuple-ref combo 4) 1)))

(define (serialize-json-person-ok? [person : Person]) : bool
  (and
    (string.eq (struct-get person name) "Ada\nLovelace")
    (= (struct-get person age) (cast 36 : i32))
    (struct-get person active)
    (= (struct-get person score) 9.5)
    (= (struct-get person ratio) (cast 1.25 : f32))
    (serialize-json-address-ok? (struct-get person home))
    (serialize-json-scores-ok? (struct-get person scores))
    (serialize-json-previous-ok? (struct-get person previous))
    (serialize-json-samples-ok? (struct-get person samples))
    (serialize-json-combo-ok? (struct-get person combo))))

(define (serialize-json-make-samples) : (Array i64)
  (let
    [samples : (Array i64) (array.make-array i64 2)]
    (begin
      (array-set! samples 0 7)
      (array-set! samples 1 8)
      samples)))

(define (serialize-json-previous-addresses) : (Array Address 2)
  (array (Address 111 "Oxford") (Address 222 "Paris")))

(define (serialize-json-combo) : (Tuple
    i64
    Address
    (Array i64 2)
    (Array i64)
    (Tuple String bool))
  (tuple
    99
    (Address 333 "Rome")
    (array 9 10)
    (serialize-json-make-samples)
    (tuple "inner" true)))

(define (serialize-json-roundtrip-ok?) : bool
  (let
    [person : Person
      (Person
        "Ada\nLovelace"
        (cast 36 : i32)
        true
        9.5
        (cast 1.25 : f32)
        (Address 12345 "London")
        (array 4 5 6)
        (serialize-json-previous-addresses)
        (serialize-json-make-samples)
        (serialize-json-combo))]
    [json : json.Json (person_json.to-json person)]
    [encoded : String (stdlib.json.json-stringify json)]
    (and
      (string.eq
        encoded
        "{\"name\":\"Ada\\nLovelace\",\"age\":36,\"active\":true,\"score\":9.5,\"ratio\":1.25,\"home\":{\"zip\":12345,\"city\":\"London\"},\"scores\":[4,5,6],\"previous\":[{\"zip\":111,\"city\":\"Oxford\"},{\"zip\":222,\"city\":\"Paris\"}],\"samples\":[7,8],\"combo\":[99,{\"zip\":333,\"city\":\"Rome\"},[9,10],[7,8],[\"inner\",true]]}")
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
