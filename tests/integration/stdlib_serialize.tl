(import stdlib.serialize)
(import stdlib.array)
(import stdlib.string)
(import serialize_toy_format as toy)

(defstruct Address
  (zip i64)
  (city String))

(import (serialize.serialize toy Address) as address_ser)

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
  (let
    [samples : (Array i64) (array.make-array i64 2)]
    (begin
      (array-set! samples 0 7)
      (array-set! samples 1 8)
      samples)))

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
    42))