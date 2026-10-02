(import stdlib.json)
(import stdlib.serialize)
(import stdlib.string)
(import serialize_enum_fixture as enum_fixture)

(defstruct Address
  (zip i64)
  (city String))

(import (serialize.serialize json Address) as address_json)
(import (serialize.serialize json i64) as i64_json)
(import (serialize.serialize json (Array i64 3)) as fixed_i64_json)
(import (serialize.serialize json (type (__tl_dyn-array i64))) as dyn_i64_json)
(import (serialize.serialize json (Array Address 2)) as address_array_json)
(import (serialize.serialize json enum_fixture.Status) as status_json)
(import (serialize.serialize json (Tuple i64 i64)) as tuple_i64_i64_json)
(import (serialize.serialize json (Tuple i64 i64)) as tuple_i64_i64_json_again)
(import (serialize.serialize json (Tuple i64 bool)) as tuple_i64_bool_json)
(import (serialize.serialize json u64) as u64_json)
(import (serialize.serialize json enum_fixture.Stamp) as stamp_json)

(defstruct Ledger
  (id u64)
  (history (Array u64 2))
  (pair (Tuple u64 bool)))

(import (serialize.serialize json Ledger) as ledger_json)

(defstruct Person
  (name String)
  (age i32)
  (active bool)
  (score f64)
  (ratio f32)
  (home Address)
  (scores (Array i64 3))
  (previous (Array Address 2))
  (samples (__tl_dyn-array i64))
  (combo
    (Tuple i64 Address (Array i64 2) (__tl_dyn-array i64) (Tuple String bool))))

(import (serialize.serialize json Person) as person_json)
(import (serialize.serialize json Person) as person_json_again)

(define (serialize-json-member
  [key : String]
  [value : json.Json]
  [rest : json.JsonMemberSeq]) : json.JsonMemberSeq
  (json.member-cons key value rest))

(define (serialize-json-item [value : json.Json] [rest : json.JsonSeq]) : json.JsonSeq
  (json.list-cons value rest))

(define (serialize-json-empty-array) : json.Json
  (JsonArray (box (json.list-empty))))

(define (serialize-json-enum-json [tag : String] [payload : json.Json]) : json.Json
  (JsonObject
    (box
      (serialize-json-member
        "tag"
        (JsonString tag)
        (serialize-json-member "payload" payload (json.member-list-empty))))))

(define (serialize-json-enum-missing-tag) : json.Json
  (JsonObject
    (box
      (serialize-json-member
        "payload"
        (serialize-json-empty-array)
        (json.member-list-empty)))))

(define (serialize-json-enum-missing-payload) : json.Json
  (JsonObject
    (box
      (serialize-json-member "tag" (JsonString "Idle") (json.member-list-empty)))))

(define (serialize-json-address-json [zip : String] [city : String]) : json.Json
  (JsonObject
    (box
      (serialize-json-member
        "zip"
        (JsonNumber zip)
        (serialize-json-member
          "city"
          (JsonString city)
          (json.member-list-empty))))))

(define (serialize-json-home-json) : json.Json
  (serialize-json-address-json "12345" "London"))

(define (serialize-json-scores-json) : json.Json
  (JsonArray
    (box
      (serialize-json-item
        (JsonNumber "4")
        (serialize-json-item
          (JsonNumber "5")
          (serialize-json-item (JsonNumber "6") (json.list-empty)))))))

(define (serialize-json-samples-json) : json.Json
  (JsonArray
    (box
      (serialize-json-item
        (JsonNumber "7")
        (serialize-json-item (JsonNumber "8") (json.list-empty))))))

(define (serialize-json-previous-json) : json.Json
  (JsonArray
    (box
      (serialize-json-item
        (serialize-json-address-json "111" "Oxford")
        (serialize-json-item
          (serialize-json-address-json "222" "Paris")
          (json.list-empty))))))

(define (serialize-json-combo-json) : json.Json
  (JsonArray
    (box
      (serialize-json-item
        (JsonNumber "99")
        (serialize-json-item
          (serialize-json-address-json "333" "Rome")
          (serialize-json-item
            (JsonArray
              (box
                (serialize-json-item
                  (JsonNumber "9")
                  (serialize-json-item (JsonNumber "10") (json.list-empty)))))
            (serialize-json-item
              (serialize-json-samples-json)
              (serialize-json-item
                (JsonArray
                  (box
                    (serialize-json-item
                      (JsonString "inner")
                      (serialize-json-item (JsonBool true) (json.list-empty)))))
                (json.list-empty)))))))))

(define (serialize-json-person-json [age : json.Json]) : json.Json
  (JsonObject
    (box
      (serialize-json-member
        "name"
        (JsonString "Ada\nLovelace")
        (serialize-json-member
          "age"
          age
          (serialize-json-member
            "active"
            (JsonBool true)
            (serialize-json-member
              "score"
              (JsonNumber "9.5")
              (serialize-json-member
                "ratio"
                (JsonNumber "1.25")
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
                          (json.member-list-empty))))))))))))))

(define (serialize-json-person-missing-age) : json.Json
  (JsonObject
    (box
      (serialize-json-member
        "name"
        (JsonString "Ada")
        (serialize-json-member
          "active"
          (JsonBool true)
          (serialize-json-member
            "score"
            (JsonNumber "9.5")
            (serialize-json-member
              "ratio"
              (JsonNumber "1.25")
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
                      (json.member-list-empty))))))))))))

(define (serialize-json-address-eq?
  [home : Address]
  [zip : i64]
  [city : String]) : bool
  (and (= home.zip zip) (string.eq home.city city)))

(define (serialize-json-address-ok? [home : Address]) : bool
  (serialize-json-address-eq? home 12345 "London"))

(define (serialize-json-scores-ok? [scores : (Array i64 3)]) : bool
  (and
    (= (array-ref scores 0) 4)
    (= (array-ref scores 1) 5)
    (= (array-ref scores 2) 6)))

(define (serialize-json-samples-ok? [samples : (__tl_dyn-array i64)]) : bool
  (and
    (= (array-length samples) 2)
    (= (array-ref samples 0) 7)
    (= (array-ref samples 1) 8)))

(define (serialize-json-previous-ok? [previous : (Array Address 2)]) : bool
  (and
    (serialize-json-address-eq? (array-ref previous 0) 111 "Oxford")
    (serialize-json-address-eq? (array-ref previous 1) 222 "Paris")))

(define (serialize-json-combo-ok?
  [combo
    : (Tuple i64 Address (Array i64 2) (__tl_dyn-array i64) (Tuple String bool))]) : bool
  (and
    (= (tuple-ref combo 0) 99)
    (serialize-json-address-eq? (tuple-ref combo 1) 333 "Rome")
    (= (array-ref (tuple-ref combo 2) 0) 9)
    (= (array-ref (tuple-ref combo 2) 1) 10)
    (serialize-json-samples-ok? (tuple-ref combo 3))
    (string.eq (tuple-ref (tuple-ref combo 4) 0) "inner")
    (tuple-ref (tuple-ref combo 4) 1)))

(define (serialize-json-person-ok? [person : Person]) : bool
  (and
    (string.eq person.name "Ada\nLovelace")
    (= person.age (cast 36 : i32))
    person.active
    (= person.score 9.5)
    (= person.ratio (cast 1.25 : f32))
    (serialize-json-address-ok? person.home)
    (serialize-json-scores-ok? person.scores)
    (serialize-json-previous-ok? person.previous)
    (serialize-json-samples-ok? person.samples)
    (serialize-json-combo-ok? person.combo)))

(define (serialize-json-make-samples) : (__tl_dyn-array i64)
  (__tl_make-array 7 8))

(define (serialize-json-previous-addresses) : (Array Address 2)
  (array (Address 111 "Oxford") (Address 222 "Paris")))

(define (serialize-json-combo) : (Tuple
    i64
    Address
    (Array i64 2)
    (__tl_dyn-array i64)
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
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq
        encoded
        "{\"name\":\"Ada\\nLovelace\",\"age\":36,\"active\":true,\"score\":9.5,\"ratio\":1.25,\"home\":{\"zip\":12345,\"city\":\"London\"},\"scores\":[4,5,6],\"previous\":[{\"zip\":111,\"city\":\"Oxford\"},{\"zip\":222,\"city\":\"Paris\"}],\"samples\":[7,8],\"combo\":[99,{\"zip\":333,\"city\":\"Rome\"},[9,10],[7,8],[\"inner\",true]]}")
      (match (person_json.from-json json)
        [(Ok parsed) (serialize-json-person-ok? parsed)]
        [(Err _) false]))))

(define (serialize-json-address-roundtrip-ok?) : bool
  (let
    [home : Address (Address 12345 "London")]
    [json : json.Json (address_json.to-json home)]
    (match (address_json.from-json json)
      [(Ok parsed) (serialize-json-address-ok? parsed)]
      [(Err _) false])))

(define (serialize-json-i64-root-roundtrip-ok?) : bool
  (let
    [json : json.Json (i64_json.to-json 42)]
    [encoded-source : json.Json (i64_json.to-json 42)]
    ;; An explicit caller `unsafe` view (#7701): the read consumes
    ;; `encoded-source`, which is not used again.
    [encoded : String
      (stdlib.json.stringify
        (unsafe
          (stdlib.json.json-shared-view encoded-source)))]
    (and
      (string.eq encoded "42")
      (match (i64_json.from-json json)
        [(Ok parsed) (= parsed 42)]
        [(Err _) false]))))

(define (serialize-json-fixed-array-root-roundtrip-ok?) : bool
  (let
    [scores : (Array i64 3) (array 4 5 6)]
    [json : json.Json (fixed_i64_json.to-json scores)]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq encoded "[4,5,6]")
      (match (fixed_i64_json.from-json json)
        [(Ok parsed) (serialize-json-scores-ok? parsed)]
        [(Err _) false]))))

(define (serialize-json-dyn-array-root-roundtrip-ok?) : bool
  (let
    [samples : (__tl_dyn-array i64) (serialize-json-make-samples)]
    [json : json.Json (dyn_i64_json.to-json samples)]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq encoded "[7,8]")
      (match (dyn_i64_json.from-json json)
        [(Ok parsed) (serialize-json-samples-ok? parsed)]
        [(Err _) false]))))

(define (serialize-json-address-array-root-roundtrip-ok?) : bool
  (let
    [previous : (Array Address 2) (serialize-json-previous-addresses)]
    [json : json.Json (address_array_json.to-json previous)]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq
        encoded
        "[{\"zip\":111,\"city\":\"Oxford\"},{\"zip\":222,\"city\":\"Paris\"}]")
      (match (address_array_json.from-json json)
        [(Ok parsed) (serialize-json-previous-ok? parsed)]
        [(Err _) false]))))

(define (serialize-json-tuple-root-roundtrip-ok?) : bool
  (let
    [json : json.Json (tuple_i64_i64_json.to-json (tuple 11 12))]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq encoded "[11,12]")
      (match (tuple_i64_i64_json_again.from-json json)
        [(Ok parsed)
          (and (= (tuple-ref parsed 0) 11) (= (tuple-ref parsed 1) 12))]
        [(Err _) false]))))

(define (serialize-json-distinct-tuple-root-ok?) : bool
  (let
    [json : json.Json (tuple_i64_bool_json.to-json (tuple 23 true))]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq encoded "[23,true]")
      (match (tuple_i64_bool_json.from-json json)
        [(Ok parsed) (and (= (tuple-ref parsed 0) 23) (tuple-ref parsed 1))]
        [(Err _) false]))))

(define (serialize-json-status-nullary-unary-roundtrip-ok?) : bool
  (and
    (match (status_json.from-json (status_json.to-json (enum_fixture.idle)))
      [(Ok parsed) (enum_fixture.idle? parsed)]
      [(Err _) false])
    (match (status_json.from-json
      (status_json.to-json (enum_fixture.scored 12)))
      [(Ok parsed) (enum_fixture.scored? parsed 12)]
      [(Err _) false])))

(define (serialize-json-status-root-roundtrip-ok?) : bool
  (let
    [status : enum_fixture.Status (enum_fixture.moved)]
    [json : json.Json (status_json.to-json status)]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq encoded "{\"tag\":\"Moved\",\"payload\":[123,[9,10]]}")
      (match (status_json.from-json json)
        [(Ok parsed) (enum_fixture.moved? parsed)]
        [(Err _) false]))))

(define (serialize-json-status-wide-roundtrip-ok?) : bool
  (let
    [status : enum_fixture.Status (enum_fixture.wide)]
    [json : json.Json (status_json.to-json status)]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq encoded "{\"tag\":\"Wide\",\"payload\":[1,2,3,4,5,6,7,8,9]}")
      (match (status_json.from-json json)
        [(Ok parsed) (enum_fixture.wide? parsed)]
        [(Err _) false]))))

(define (serialize-json-status-struct-payload-roundtrip-ok?) : bool
  (let
    [json : json.Json (status_json.to-json (enum_fixture.detailed))]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq
        encoded
        "{\"tag\":\"Detailed\",\"payload\":[{\"code\":77,\"place\":{\"zip\":90210,\"city\":\"Malmo\"}}]}")
      (match (status_json.from-json json)
        [(Ok parsed) (enum_fixture.detailed? parsed)]
        [(Err _) false]))))

(define (serialize-json-status-invalid-tag-ok?) : bool
  (match (status_json.from-json
    (serialize-json-enum-json "Unknown" (serialize-json-empty-array)))
    [(Ok _) false]
    [(Err _) true]))

(define (serialize-json-status-missing-tag-ok?) : bool
  (match (status_json.from-json (serialize-json-enum-missing-tag))
    [(Ok _) false]
    [(Err _) true]))

(define (serialize-json-status-missing-payload-ok?) : bool
  (match (status_json.from-json (serialize-json-enum-missing-payload))
    [(Ok _) false]
    [(Err _) true]))

(define (serialize-json-status-payload-length-ok?) : bool
  (match (status_json.from-json
    (serialize-json-enum-json "Scored" (serialize-json-empty-array)))
    [(Ok _) false]
    [(Err _) true]))

(define (serialize-json-missing-field-ok?) : bool
  (match (person_json.from-json (serialize-json-person-missing-age))
    [(Ok _) false]
    [(Err _) true]))

(define (serialize-json-wrong-kind-ok?) : bool
  (match (person_json.from-json (serialize-json-person-json (JsonString "36")))
    [(Ok _) false]
    [(Err _) true]))

(define (serialize-json-invalid-integer-ok?) : bool
  (match (person_json.from-json
    (serialize-json-person-json (JsonNumber "36.5")))
    [(Ok _) false]
    [(Err _) true]))

(define (serialize-json-direct-parse-ok?) : bool
  (match (person_json_again.from-json
    (serialize-json-person-json (JsonNumber "36")))
    [(Ok parsed) (serialize-json-person-ok? parsed)]
    [(Err _) false]))

(define (serialize-json-u64-root-roundtrip-ok?) : bool
  (let
    [max : u64 (cast -1 : u64)]
    [json : json.Json (u64_json.to-json max)]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq encoded "18446744073709551615")
      (match (u64_json.from-json json)
        [(Ok parsed) (= parsed max)]
        [(Err _) false]))))

(define (serialize-json-u64-fields-roundtrip-ok?) : bool
  (let
    [top : u64 (cast -1 : u64)]
    [high : u64 (+ (cast 9223372036854775807 : u64) (cast 1 : u64))]
    [ledger : Ledger
      (Ledger top (array high (cast 0 : u64)) (tuple (cast 7 : u64) true))]
    [json : json.Json (ledger_json.to-json ledger)]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq
        encoded
        "{\"id\":18446744073709551615,\"history\":[9223372036854775808,0],\"pair\":[7,true]}")
      (match (ledger_json.from-json json)
        [(Ok parsed)
          (and
            (= parsed.id top)
            (= (array-ref parsed.history 0) high)
            (= (array-ref parsed.history 1) (cast 0 : u64))
            (= (tuple-ref parsed.pair 0) (cast 7 : u64))
            (tuple-ref parsed.pair 1))]
        [(Err _) false]))))

(define (serialize-json-u64-enum-roundtrip-ok?) : bool
  (let
    [stamp : enum_fixture.Stamp (enum_fixture.stamp-max)]
    [json : json.Json (stamp_json.to-json stamp)]
    [encoded : String (stdlib.json.stringify (clone json))]
    (and
      (string.eq encoded "{\"tag\":\"At\",\"payload\":[18446744073709551615]}")
      (match (stamp_json.from-json json)
        [(Ok parsed) (enum_fixture.stamp-max? parsed)]
        [(Err _) false]))))

(define (serialize-json-u64-rejects? [value : json.Json] [message : String]) : bool
  (match (u64_json.from-json value)
    [(Ok _) false]
    [(Err actual) (string.eq actual message)]))

(define (serialize-json-u64-invalid-ok?) : bool
  (and
    (serialize-json-u64-rejects?
      (JsonNumber "18446744073709551616")
      "json: integer outside u64 range")
    (serialize-json-u64-rejects?
      (JsonNumber "-1")
      "json: negative number outside u64 range")
    (serialize-json-u64-rejects?
      (JsonNumber "-0")
      "json: negative number outside u64 range")
    (serialize-json-u64-rejects?
      (JsonNumber "2.5")
      "json: expected integer number")
    (serialize-json-u64-rejects?
      (JsonNumber "1e3")
      "json: expected integer number")
    (serialize-json-u64-rejects?
      (JsonString "5")
      "json: expected integer number")))

(define (main) : i64
  (begin
    (unless (serialize-json-roundtrip-ok?) (return 1))
    (unless (serialize-json-direct-parse-ok?) (return 2))
    (unless (serialize-json-missing-field-ok?) (return 3))
    (unless (serialize-json-wrong-kind-ok?) (return 4))
    (unless (serialize-json-invalid-integer-ok?) (return 5))
    (unless (serialize-json-address-roundtrip-ok?) (return 6))
    (unless (serialize-json-i64-root-roundtrip-ok?) (return 7))
    (unless (serialize-json-fixed-array-root-roundtrip-ok?) (return 8))
    (unless (serialize-json-dyn-array-root-roundtrip-ok?) (return 9))
    (unless (serialize-json-address-array-root-roundtrip-ok?) (return 10))
    (unless (serialize-json-status-nullary-unary-roundtrip-ok?) (return 11))
    (unless (serialize-json-status-root-roundtrip-ok?) (return 12))
    (unless (serialize-json-status-invalid-tag-ok?) (return 13))
    (unless (serialize-json-status-missing-tag-ok?) (return 14))
    (unless (serialize-json-status-missing-payload-ok?) (return 15))
    (unless (serialize-json-status-payload-length-ok?) (return 16))
    (unless (serialize-json-status-wide-roundtrip-ok?) (return 17))
    (unless (serialize-json-status-struct-payload-roundtrip-ok?) (return 18))
    (unless (serialize-json-tuple-root-roundtrip-ok?) (return 19))
    (unless (serialize-json-distinct-tuple-root-ok?) (return 20))
    (unless (serialize-json-u64-root-roundtrip-ok?) (return 21))
    (unless (serialize-json-u64-fields-roundtrip-ok?) (return 22))
    (unless (serialize-json-u64-enum-roundtrip-ok?) (return 23))
    (unless (serialize-json-u64-invalid-ok?) (return 24))
    42))