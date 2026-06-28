(import stdlib.serialize)
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
  (home Address))

(import (serialize.serialize toy Person) as person_ser)
(import (serialize.serialize toy Person) as person_ser_again)

(define (serialize-address-ok? [home : Address]) : bool
  (and
    (= (struct-get home zip) 12345)
    (string.string-eq (struct-get home city) "London")))

(define (serialize-person-ok? [person : Person]) : bool
  (and
    (string.string-eq (struct-get person name) "Ada")
    (= (struct-get person age) (cast 36 : i32))
    (struct-get person active)
    (= (struct-get person score) 9.5)
    (serialize-address-ok? (struct-get person home))))

(define (serialize-home-value-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Object fields)
      (match (toy.field-list-get (box-get fields) "city")
        [(toy.Found city)
          (match city
            [(toy.Text found) (string.string-eq found "London")]
            [_ false])]
        [(toy.Missing) false])]
    [_ false]))

(define (serialize-encoded-shape-ok? [value : toy.Value]) : bool
  (match value
    [(toy.Object fields)
      (match (toy.field-list-get (box-get fields) "home")
        [(toy.Found home) (serialize-home-value-ok? home)]
        [(toy.Missing) false])]
    [_ false]))

(define (serialize-encoded-shape-roundtrip-ok?) : bool
  (let
    [person : Person
      (Person "Ada" (cast 36 : i32) true 9.5 (Address 12345 "London"))]
    [encoded : toy.Value (person_ser.encode person)]
    (serialize-encoded-shape-ok? encoded)))

(define (serialize-roundtrip-ok?) : bool
  (let
    [person : Person
      (Person "Ada" (cast 36 : i32) true 9.5 (Address 12345 "London"))]
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
                            (Address 12345 "London")))
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
      (Person "Ada" (cast 36 : i32) true 9.5 (Address 12345 "London"))]
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