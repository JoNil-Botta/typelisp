;; Arbitrary caller-owned nominal value families (#6842).
(import stdlib.test)
(import stdlib.hashmap)
(import tests.hashmap_macro_clone_collision_first as collision_first)
(import tests.hashmap_macro_clone_collision_second as collision_second)

(defenum LocalValueTag
  (LocalValueNone)
  (LocalValueText String)
  (LocalValueOtherText String))

(defstruct LocalNestedValue
  (pair (Tuple i32 bool))
  (codes (Array u8 3))
  (tag LocalValueTag))

(defstruct LocalStructValue
  (score i64)
  (label String)
  (nested LocalNestedValue))

(defenum LocalEnumValue
  (LocalEnumNone)
  (LocalEnumSome LocalStructValue)
  (LocalEnumPair String i64))

(import (hashmap.hashmap String LocalStructValue) as map_local_struct_value)
(import (hashmap.hashmap i64 LocalEnumValue) as map_local_enum_value)

;; Reverse the family imports relative to the provider imports above. The two
;; modules export the same nominal spelling, so aliases and owner reflection
;; must keep the generated value families distinct.
(import (hashmap.hashmap i64 collision_second.DuplicateKey) as map_duplicate_value_second)
(import (hashmap.hashmap i64 collision_first.DuplicateKey) as map_duplicate_value_first)

(define (local-nested-value [seed : i64] [text : String]) : LocalNestedValue
  (LocalNestedValue
    (tuple (cast seed : i32) (> seed 0))
    (array (cast seed : u8) 2 3)
    (LocalValueText text)))

(define (local-struct-score [value : LocalStructValue]) : i64
  (+ value.score (__tl_string_length value.label)))

(define (local-enum-score [value : LocalEnumValue]) : i64
  (match value
    [(LocalEnumNone) -1]
    [(LocalEnumSome payload) (local-struct-score payload)]
    [(LocalEnumPair text score) (+ (__tl_string_length text) score)]))

(test
  hashmap-macro-caller-local-nominal-values
  (let
    [structs : map_local_struct_value.Map
      (map_local_struct_value.with-capacity 1)]
    [states : map_local_enum_value.Map (map_local_enum_value.new)]
    [value-evaluations : i64 0]
    (begin
      (map_local_struct_value.insert!
        structs
        "one"
        (begin
          (set! value-evaluations (+ value-evaluations 1))
          (LocalStructValue 10 "alpha" (local-nested-value 1 "nested"))))
      (test.assert-i64-eq
        value-evaluations
        1
        "caller-local value expression evaluates once")
      (map_local_struct_value.insert!
        structs
        "two"
        (LocalStructValue 20 "beta" (local-nested-value 2 "nested")))
      (test.assert-true
        (> (map_local_struct_value.capacity (& structs)) 1)
        "caller-local struct values survive growth")
      (test.assert-i64-eq
        (local-struct-score
          (map_local_struct_value.lookup-value-or
            (map_local_struct_value.get (& structs) "one")
            (LocalStructValue 0 "" (local-nested-value 0 ""))))
        15
        "caller-local struct value owned lookup")
      (test.assert-true
        (map_local_struct_value.borrowed-value-found?
          (map_local_struct_value.get-value-borrowed (& structs) "two"))
        "caller-local struct value borrowed lookup")
      (map_local_struct_value.insert-or-update!
        structs
        "one"
        (LocalStructValue 30 "updated" (local-nested-value 3 "replacement")))
      (test.assert-i64-eq
        (local-struct-score
          (map_local_struct_value.lookup-value-or
            (map_local_struct_value.get (& structs) "one")
            (LocalStructValue 0 "" (local-nested-value 0 ""))))
        37
        "caller-local struct value update")
      (test.assert-true
        (map_local_struct_value.remove-ok?
          (map_local_struct_value.remove! structs "two"))
        "caller-local struct value remove")
      (match (map_local_struct_value.entry-or-insert!
        structs
        "three"
        (LocalStructValue 40 "entry" (local-nested-value 4 "entry")))
        [(map_local_struct_value.EntryOrInsertInserted value)
          (test.assert-i64-eq
            (local-struct-score value)
            45
            "caller-local struct entry inserts")]
        [(map_local_struct_value.EntryOrInsertFound _)
          (test.assert-true false "caller-local struct entry should insert")])
      (map_local_enum_value.insert!
        states
        1
        (LocalEnumSome
          (LocalStructValue 50 "enum" (local-nested-value 5 "enum"))))
      ;; 1, 5, and 9 collide modulo the initial capacity. Removing 1 then
      ;; inserting 9 exercises tombstone reuse without triggering growth.
      (map_local_enum_value.insert! states 5 (LocalEnumPair "pair" 60))
      (test.assert-i64-eq
        (local-enum-score
          (map_local_enum_value.lookup-value-or
            (map_local_enum_value.get (& states) 1)
            (LocalEnumNone)))
        54
        "caller-local enum value owned lookup")
      (test.assert-true
        (map_local_enum_value.borrowed-value-found?
          (map_local_enum_value.get-value-borrowed (& states) 5))
        "caller-local enum value borrowed lookup")
      (map_local_enum_value.insert-or-update!
        states
        1
        (LocalEnumPair "updated" 70))
      (test.assert-i64-eq
        (local-enum-score
          (map_local_enum_value.lookup-value-or
            (map_local_enum_value.get (& states) 1)
            (LocalEnumNone)))
        77
        "caller-local enum value update")
      (test.assert-true
        (map_local_enum_value.remove-ok?
          (map_local_enum_value.remove! states 1))
        "caller-local enum value remove")
      (match (map_local_enum_value.entry-or-insert!
        states
        9
        (LocalEnumPair "tombstone" 80))
        [(map_local_enum_value.EntryOrInsertInserted value)
          (test.assert-i64-eq
            (local-enum-score value)
            89
            "caller-local enum value reuses tombstone")]
        [(map_local_enum_value.EntryOrInsertFound _)
          (test.assert-true false "caller-local enum tombstone should insert")]))))

(test
  hashmap-macro-value-module-identity-keeps-exact-nominal-owner
  (let
    [first : map_duplicate_value_first.Map (map_duplicate_value_first.new)]
    [second : map_duplicate_value_second.Map (map_duplicate_value_second.new)]
    (begin
      (map_duplicate_value_first.insert!
        first
        1
        (collision_first.DuplicateKey "first"))
      (map_duplicate_value_second.insert!
        second
        1
        (collision_second.DuplicateKey "second"))
      (test.assert-i64-eq
        (__tl_string_length
          (map_duplicate_value_first.lookup-value-or
            (map_duplicate_value_first.get (& first) 1)
            (collision_first.DuplicateKey "")).text)
        5
        "first duplicate-name value keeps its owner")
      (test.assert-i64-eq
        (__tl_string_length
          (map_duplicate_value_second.lookup-value-or
            (map_duplicate_value_second.get (& second) 1)
            (collision_second.DuplicateKey "")).text)
        6
        "second duplicate-name value keeps its owner"))))