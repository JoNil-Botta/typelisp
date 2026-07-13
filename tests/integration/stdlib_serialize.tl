(import stdlib.serialize)
(import stdlib.array)
(import stdlib.comptime)
(import stdlib.option)
(import stdlib.result)
(import stdlib.string)
(import serialize_toy_format as toy)
(import serialize_enum_fixture as enum_fixture)
(import (option i64) as option_i64)
(import (result i64 String) as result_i64_string)

(defmacro (enum-type-info [T : type]) : Module
  (let
    [module-name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "generated.enum_type_info." (type-key T)))]
    (match (type-info T)
      [(comptime.TypeInfoEnum _ _)
        `(begin
          (module ,module-name)
          (define (score) : i64
            1))]
      [_
        `(begin
          (module ,module-name)
          (define (score) : i64
            0))])))

(import (enum-type-info option_i64.Option) as option_type_info)
(import (enum-type-info result_i64_string.Result) as result_type_info)

(defstruct Address
  (zip i64)
  (city String))

(import (serialize.serialize toy Address) as address_ser)
(import (serialize.serialize toy i64) as i64_ser)
(import (serialize.serialize toy (Array i64 3)) as fixed_i64_ser)
(import (serialize.serialize toy (Array i64)) as dyn_i64_ser)
(import (serialize.serialize toy (Array Address 2)) as address_array_ser)
(import (serialize.serialize toy enum_fixture.Status) as status_ser)
(import (serialize.serialize toy option_i64.Option) as option_i64_ser)
(import (serialize.serialize toy result_i64_string.Result) as result_i64_string_ser)

(defstruct Person
  (name String)
  (age i32)
  (active bool)
  (score f64)
  (home Address)
  (scores (Array i64 3))
  (previous (Array Address 2))
  (samples (Array i64))
  (combo (Tuple i64 Address (Array i64 2) (Array i64) (Tuple String bool))))

(import (serialize.serialize toy Person) as person_ser)
(import (serialize.serialize toy Person) as person_ser_again)

(define (serialize-address-eq? [home : Address] [zip : i64] [city : String]) : bool
  (and (= (struct-get home zip) zip) (string.eq (struct-get home city) city)))

(define (serialize-address-ok? [home : Address]) : bool
  (serialize-address-eq? home 12345 "London"))

(define (serialize-scores-ok? [scores : (Array i64 3)]) : bool
  (and
    (= (array-ref scores 0) 4)
    (= (array-ref scores 1) 5)
    (= (array-ref scores 2) 6)))

(define (serialize-samples-ok? [samples : (Array i64)]) : bool
  (and
    (= (array-length samples) 2)
    (= (array-ref samples 0) 7)
    (= (array-ref samples 1) 8)))

(define (serialize-previous-ok? [previous : (Array Address 2)]) : bool
  (and
    (serialize-address-eq? (array-ref previous 0) 111 "Oxford")
    (serialize-address-eq? (array-ref previous 1) 222 "Paris")))

(define (serialize-combo-ok?
  [combo : (Tuple i64 Address (Array i64 2) (Array i64) (Tuple String bool))]) : bool
  (and
    (= (tuple-ref combo 0) 99)
    (serialize-address-eq? (tuple-ref combo 1) 333 "Rome")
    (= (array.ref (tuple-ref combo 2) 0) 9)
    (= (array.ref (tuple-ref combo 2) 1) 10)
    (serialize-samples-ok? (tuple-ref combo 3))
    (string.eq (tuple-ref (tuple-ref combo 4) 0) "inner")
    (tuple-ref (tuple-ref combo 4) 1)))

(define (serialize-person-ok? [person : Person]) : bool
  (and
    (string.eq (struct-get person name) "Ada")
    (= (struct-get person age) (cast 36 : i32))
    (struct-get person active)
    (= (struct-get person score) 9.5)
    (serialize-address-ok? (struct-get person home))
    (serialize-scores-ok? (struct-get person scores))
    (serialize-previous-ok? (struct-get person previous))
    (serialize-samples-ok? (struct-get person samples))
    (serialize-combo-ok? (struct-get person combo))))

(define (serialize-address-value-city-ok?
  [value : toy.Value]
  [expected-city : String]) : bool
  (match value
    [(toy.Object fields)
      (match (toy.field-list-get (box-get fields) "city")
        [(toy.Found city-value)
          (match city-value
            [(toy.Text found) (string.eq found expected-city)]
            [_ false])]
        [(toy.Missing) false])]
    [_ false]))

(define (serialize-home-value-ok? [value : toy.Value]) : bool
  (serialize-address-value-city-ok? value "London"))

(define (serialize-scores-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Sequence items)
      (and
        (= (toy.value-list-count (box-get items)) 3)
        (match (toy.value-list-get (box-get items) 2)
          [(toy.Found item)
            (match item
              [(toy.Int found) (= found 6)]
              [_ false])]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-samples-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Sequence items)
      (and
        (= (toy.value-list-count (box-get items)) 2)
        (match (toy.value-list-get (box-get items) 1)
          [(toy.Found item)
            (match item
              [(toy.Int found) (= found 8)]
              [_ false])]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-previous-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Sequence items)
      (and
        (= (toy.value-list-count (box-get items)) 2)
        (match (toy.value-list-get (box-get items) 1)
          [(toy.Found item) (serialize-address-value-city-ok? item "Paris")]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-combo-fixed-array-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Sequence items)
      (and
        (= (toy.value-list-count (box-get items)) 2)
        (match (toy.value-list-get (box-get items) 1)
          [(toy.Found item)
            (match item
              [(toy.Int found) (= found 10)]
              [_ false])]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-combo-inner-tuple-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Sequence items)
      (and
        (= (toy.value-list-count (box-get items)) 2)
        (match (toy.value-list-get (box-get items) 0)
          [(toy.Found item)
            (match item
              [(toy.Text found) (string.eq found "inner")]
              [_ false])]
          [(toy.Missing) false])
        (match (toy.value-list-get (box-get items) 1)
          [(toy.Found item)
            (match item
              [(toy.Bool found) found]
              [_ false])]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-combo-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Sequence items)
      (and
        (= (toy.value-list-count (box-get items)) 5)
        (match (toy.value-list-get (box-get items) 0)
          [(toy.Found item)
            (match item
              [(toy.Int found) (= found 99)]
              [_ false])]
          [(toy.Missing) false])
        (match (toy.value-list-get (box-get items) 1)
          [(toy.Found item) (serialize-address-value-city-ok? item "Rome")]
          [(toy.Missing) false])
        (match (toy.value-list-get (box-get items) 2)
          [(toy.Found item) (serialize-combo-fixed-array-value-ok? item)]
          [(toy.Missing) false])
        (match (toy.value-list-get (box-get items) 3)
          [(toy.Found item) (serialize-samples-value-ok? item)]
          [(toy.Missing) false])
        (match (toy.value-list-get (box-get items) 4)
          [(toy.Found item) (serialize-combo-inner-tuple-value-ok? item)]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-toy-empty-sequence) : toy.Value
  (toy.Sequence (box toy.ValueNil)))

(define (serialize-toy-enum-object [tag : String] [payload : toy.Value]) : toy.Value
  (toy.Object
    (box
      (toy.FieldCons
        "tag"
        (toy.Text tag)
        (box (toy.FieldCons "payload" payload (box toy.FieldNil)))))))

(define (serialize-toy-enum-missing-tag) : toy.Value
  (toy.Object
    (box
      (toy.FieldCons
        "payload"
        (serialize-toy-empty-sequence)
        (box toy.FieldNil)))))

(define (serialize-toy-enum-missing-payload) : toy.Value
  (toy.Object (box (toy.FieldCons "tag" (toy.Text "Idle") (box toy.FieldNil)))))

(define (serialize-enum-object-tag-and-payload-count-ok?
  [value : toy.Value]
  [expected-tag : String]
  [expected-count : i64]) : bool
  (match value
    [(toy.Object fields)
      (and
        (match (toy.field-list-get (box-get fields) "tag")
          [(toy.Found tag-value)
            (match tag-value
              [(toy.Text found) (string.eq found expected-tag)]
              [_ false])]
          [(toy.Missing) false])
        (match (toy.field-list-get (box-get fields) "payload")
          [(toy.Found payload-value)
            (match payload-value
              [(toy.Sequence items)
                (= (toy.value-list-count (box-get items)) expected-count)]
              [_ false])]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-status-array-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Sequence items)
      (and
        (= (toy.value-list-count (box-get items)) 2)
        (match (toy.value-list-get (box-get items) 0)
          [(toy.Found item)
            (match item
              [(toy.Int found) (= found 9)]
              [_ false])]
          [(toy.Missing) false])
        (match (toy.value-list-get (box-get items) 1)
          [(toy.Found item)
            (match item
              [(toy.Int found) (= found 10)]
              [_ false])]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-status-payload-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Sequence items)
      (and
        (= (toy.value-list-count (box-get items)) 2)
        (match (toy.value-list-get (box-get items) 0)
          [(toy.Found item)
            (match item
              [(toy.Int found) (= found 123)]
              [_ false])]
          [(toy.Missing) false])
        (match (toy.value-list-get (box-get items) 1)
          [(toy.Found item) (serialize-status-array-value-ok? item)]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-status-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Object fields)
      (and
        (serialize-enum-object-tag-and-payload-count-ok? value "Moved" 2)
        (match (toy.field-list-get (box-get fields) "payload")
          [(toy.Found payload) (serialize-status-payload-value-ok? payload)]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-status-wide-item-ok? [items : toy.ValueList] [index : i64]) : bool
  (match (toy.value-list-get items index)
    [(toy.Found item)
      (match item
        [(toy.Int found) (= found (+ index 1))]
        [_ false])]
    [(toy.Missing) false]))

(define (serialize-status-wide-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Object fields)
      (and
        (serialize-enum-object-tag-and-payload-count-ok? value "Wide" 9)
        (match (toy.field-list-get (box-get fields) "payload")
          [(toy.Found payload)
            (match payload
              [(toy.Sequence items)
                (and
                  (serialize-status-wide-item-ok? (box-get items) 0)
                  (serialize-status-wide-item-ok? (box-get items) 1)
                  (serialize-status-wide-item-ok? (box-get items) 2)
                  (serialize-status-wide-item-ok? (box-get items) 3)
                  (serialize-status-wide-item-ok? (box-get items) 4)
                  (serialize-status-wide-item-ok? (box-get items) 5)
                  (serialize-status-wide-item-ok? (box-get items) 6)
                  (serialize-status-wide-item-ok? (box-get items) 7)
                  (serialize-status-wide-item-ok? (box-get items) 8))]
              [_ false])]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-encoded-shape-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Object fields)
      (and
        (match (toy.field-list-get (box-get fields) "home")
          [(toy.Found home) (serialize-home-value-ok? home)]
          [(toy.Missing) false])
        (match (toy.field-list-get (box-get fields) "scores")
          [(toy.Found scores) (serialize-scores-value-ok? scores)]
          [(toy.Missing) false])
        (match (toy.field-list-get (box-get fields) "previous")
          [(toy.Found previous) (serialize-previous-value-ok? previous)]
          [(toy.Missing) false])
        (match (toy.field-list-get (box-get fields) "samples")
          [(toy.Found samples) (serialize-samples-value-ok? samples)]
          [(toy.Missing) false])
        (match (toy.field-list-get (box-get fields) "combo")
          [(toy.Found combo) (serialize-combo-value-ok? combo)]
          [(toy.Missing) false]))]
    [_ false]))

(define (serialize-previous-addresses) : (Array Address 2)
  (array (Address 111 "Oxford") (Address 222 "Paris")))

(define (serialize-make-samples) : (Array i64)
  (make-array 7 8))

(define (serialize-combo) : (Tuple
    i64
    Address
    (Array i64 2)
    (Array i64)
    (Tuple String bool))
  (tuple
    99
    (Address 333 "Rome")
    (array 9 10)
    (serialize-make-samples)
    (tuple "inner" true)))

(define (serialize-encoded-shape-roundtrip-ok?) : bool
  (let
    [person : Person
      (Person
        "Ada"
        (cast 36 : i32)
        true
        9.5
        (Address 12345 "London")
        (array 4 5 6)
        (serialize-previous-addresses)
        (serialize-make-samples)
        (serialize-combo))]
    [encoded : toy.Value (person_ser.encode person)]
    (serialize-encoded-shape-ok? encoded)))

(define (serialize-roundtrip-ok?) : bool
  (let
    [person : Person
      (Person
        "Ada"
        (cast 36 : i32)
        true
        9.5
        (Address 12345 "London")
        (array 4 5 6)
        (serialize-previous-addresses)
        (serialize-make-samples)
        (serialize-combo))]
    [encoded : toy.Value (person_ser.encode person)]
    (match (person_ser.decode encoded)
      [(person_ser.Ok parsed) (serialize-person-ok? parsed)]
      [(person_ser.Err _) false])))

(define (serialize-address-roundtrip-ok?) : bool
  (let
    [home : Address (Address 12345 "London")]
    [encoded : toy.Value (address_ser.encode home)]
    (match (address_ser.decode encoded)
      [(address_ser.Ok parsed) (serialize-address-ok? parsed)]
      [(address_ser.Err _) false])))

(define (serialize-i64-root-roundtrip-ok?) : bool
  (let
    [encoded : toy.Value (i64_ser.encode 42)]
    (and
      (match encoded
        [(toy.Int found) (= found 42)]
        [_ false])
      (match (i64_ser.decode encoded)
        [(i64_ser.Ok parsed) (= parsed 42)]
        [(i64_ser.Err _) false]))))

(define (serialize-fixed-array-root-roundtrip-ok?) : bool
  (let
    [scores : (Array i64 3) (array 4 5 6)]
    [encoded : toy.Value (fixed_i64_ser.encode scores)]
    (and
      (serialize-scores-value-ok? encoded)
      (match (fixed_i64_ser.decode encoded)
        [(fixed_i64_ser.Ok parsed) (serialize-scores-ok? parsed)]
        [(fixed_i64_ser.Err _) false]))))

(define (serialize-dyn-array-root-roundtrip-ok?) : bool
  (let
    [samples : (Array i64) (serialize-make-samples)]
    [encoded : toy.Value (dyn_i64_ser.encode samples)]
    (and
      (serialize-samples-value-ok? encoded)
      (match (dyn_i64_ser.decode encoded)
        [(dyn_i64_ser.Ok parsed) (serialize-samples-ok? parsed)]
        [(dyn_i64_ser.Err _) false]))))

(define (serialize-address-array-root-roundtrip-ok?) : bool
  (let
    [previous : (Array Address 2) (serialize-previous-addresses)]
    [encoded : toy.Value (address_array_ser.encode previous)]
    (and
      (serialize-previous-value-ok? encoded)
      (match (address_array_ser.decode encoded)
        [(address_array_ser.Ok parsed) (serialize-previous-ok? parsed)]
        [(address_array_ser.Err _) false]))))

(define (serialize-status-nullary-unary-roundtrip-ok?) : bool
  (and
    (match (status_ser.decode (status_ser.encode (enum_fixture.idle)))
      [(status_ser.Ok parsed) (enum_fixture.idle? parsed)]
      [(status_ser.Err _) false])
    (match (status_ser.decode (status_ser.encode (enum_fixture.scored 12)))
      [(status_ser.Ok parsed) (enum_fixture.scored? parsed 12)]
      [(status_ser.Err _) false])))

(define (serialize-status-root-roundtrip-ok?) : bool
  (let
    [status : enum_fixture.Status (enum_fixture.moved)]
    [encoded : toy.Value (status_ser.encode status)]
    (and
      (serialize-status-value-ok? encoded)
      (match (status_ser.decode encoded)
        [(status_ser.Ok parsed) (enum_fixture.moved? parsed)]
        [(status_ser.Err _) false]))))

(define (serialize-status-wide-roundtrip-ok?) : bool
  (let
    [status : enum_fixture.Status (enum_fixture.wide)]
    [encoded : toy.Value (status_ser.encode status)]
    (and
      (serialize-status-wide-value-ok? encoded)
      (match (status_ser.decode encoded)
        [(status_ser.Ok parsed) (enum_fixture.wide? parsed)]
        [(status_ser.Err _) false]))))

(define (serialize-status-struct-payload-roundtrip-ok?) : bool
  (match (status_ser.decode (status_ser.encode (enum_fixture.detailed)))
    [(status_ser.Ok parsed) (enum_fixture.detailed? parsed)]
    [(status_ser.Err _) false]))

(define (serialize-status-invalid-tag-ok?) : bool
  (match (status_ser.decode
    (serialize-toy-enum-object "Unknown" (serialize-toy-empty-sequence)))
    [(status_ser.Ok _) false]
    [(status_ser.Err _) true]))

(define (serialize-status-missing-tag-ok?) : bool
  (match (status_ser.decode (serialize-toy-enum-missing-tag))
    [(status_ser.Ok _) false]
    [(status_ser.Err _) true]))

(define (serialize-status-missing-payload-ok?) : bool
  (match (status_ser.decode (serialize-toy-enum-missing-payload))
    [(status_ser.Ok _) false]
    [(status_ser.Err _) true]))

(define (serialize-status-payload-length-ok?) : bool
  (match (status_ser.decode
    (serialize-toy-enum-object "Scored" (serialize-toy-empty-sequence)))
    [(status_ser.Ok _) false]
    [(status_ser.Err _) true]))

(define (serialize-option-root-roundtrip-ok?) : bool
  (and
    (match (option_i64_ser.decode (option_i64_ser.encode (option_i64.none)))
      [(option_i64_ser.Ok parsed) (option_i64.is-none? (& parsed))]
      [(option_i64_ser.Err _) false])
    (match (option_i64_ser.decode (option_i64_ser.encode (option_i64.some 41)))
      [(option_i64_ser.Ok parsed) (= (option_i64.value-or parsed 0) 41)]
      [(option_i64_ser.Err _) false])))

(define (serialize-result-root-roundtrip-ok?) : bool
  (and
    (match (result_i64_string_ser.decode
      (result_i64_string_ser.encode (result_i64_string.ok 7)))
      [(result_i64_string_ser.Ok parsed)
        (= (result_i64_string.value-or parsed 0) 7)]
      [(result_i64_string_ser.Err _) false])
    (match (result_i64_string_ser.decode
      (result_i64_string_ser.encode (result_i64_string.err "bad")))
      [(result_i64_string_ser.Ok parsed) (result_i64_string.is-err? (& parsed))]
      [(result_i64_string_ser.Err _) false])))

(define (serialize-missing-field-value) : toy.Value
  (toy.Object (box (toy.FieldCons "name" (toy.Text "Ada") (box toy.FieldNil)))))

(define (serialize-wrong-kind-value) : toy.Value
  (toy.Object
    (box
      (toy.FieldCons
        "name"
        (toy.Text "Ada")
        (box
          (toy.FieldCons
            "age"
            (toy.Text "36")
            (box
              (toy.FieldCons
                "active"
                (toy.Bool true)
                (box
                  (toy.FieldCons
                    "score"
                    (toy.Float 9.5)
                    (box
                      (toy.FieldCons
                        "home"
                        (person_ser.encode
                          (Person
                            "Nested"
                            (cast 1 : i32)
                            false
                            1.0
                            (Address 12345 "London")
                            (array 4 5 6)
                            (serialize-previous-addresses)
                            (serialize-make-samples)
                            (serialize-combo)))
                        (box toy.FieldNil)))))))))))))

(define (serialize-missing-field-ok?) : bool
  (match (person_ser.decode (serialize-missing-field-value))
    [(person_ser.Ok _) false]
    [(person_ser.Err _) true]))

(define (serialize-wrong-kind-ok?) : bool
  (match (person_ser.decode (serialize-wrong-kind-value))
    [(person_ser.Ok _) false]
    [(person_ser.Err _) true]))

(define (serialize-direct-parse-ok?) : bool
  (let
    [person : Person
      (Person
        "Ada"
        (cast 36 : i32)
        true
        9.5
        (Address 12345 "London")
        (array 4 5 6)
        (serialize-previous-addresses)
        (serialize-make-samples)
        (serialize-combo))]
    [encoded : toy.Value (person_ser_again.encode person)]
    (match (person_ser_again.decode encoded)
      [(person_ser_again.Ok parsed) (serialize-person-ok? parsed)]
      [(person_ser_again.Err _) false])))

(define (main) : i64
  (begin
    (unless (serialize-encoded-shape-roundtrip-ok?) (return 1))
    (unless (serialize-roundtrip-ok?) (return 2))
    (unless (serialize-direct-parse-ok?) (return 3))
    (unless (serialize-missing-field-ok?) (return 4))
    (unless (serialize-wrong-kind-ok?) (return 5))
    (unless (serialize-address-roundtrip-ok?) (return 6))
    (unless (serialize-i64-root-roundtrip-ok?) (return 7))
    (unless (serialize-fixed-array-root-roundtrip-ok?) (return 8))
    (unless (serialize-dyn-array-root-roundtrip-ok?) (return 9))
    (unless (serialize-address-array-root-roundtrip-ok?) (return 10))
    (unless (serialize-status-nullary-unary-roundtrip-ok?) (return 11))
    (unless (serialize-status-root-roundtrip-ok?) (return 12))
    (unless (serialize-status-invalid-tag-ok?) (return 13))
    (unless (serialize-status-missing-tag-ok?) (return 14))
    (unless (serialize-status-missing-payload-ok?) (return 15))
    (unless (serialize-status-payload-length-ok?) (return 16))
    (unless (serialize-status-wide-roundtrip-ok?) (return 17))
    (unless (serialize-option-root-roundtrip-ok?) (return 18))
    (unless (serialize-result-root-roundtrip-ok?) (return 19))
    (unless (= (option_type_info.score) 1) (return 20))
    (unless (= (result_type_info.score) 1) (return 21))
    (unless (serialize-status-struct-payload-roundtrip-ok?) (return 22))
    42))