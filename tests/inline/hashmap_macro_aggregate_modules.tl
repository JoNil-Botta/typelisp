;; hashmap_macro_aggregate_modules.tl - aggregate generated-module hashmap surfaces (#3761).
(import stdlib.test)
(import stdlib.hashmap)
(import stdlib.string as string_mod)
(import tests.hashmap_macro_clone_collision_first as collision_first)
(import tests.hashmap_macro_clone_collision_second as collision_second)

(defenum GenericHashKeyTag
  (GenericHashKeyNone)
  (GenericHashKeyText String)
  (GenericHashKeyOtherText String))

(defstruct GenericHashKey
  (pair (Tuple i32 bool))
  (codes (Array u8 3))
  (tag GenericHashKeyTag))

(import (hashmap.hashmap String hashmap.HashPayload) as map_string_payload)
(import (hashmap.hashmap i64 hashmap.HashState) as map_i64_state)
(import (hashmap.hashmap hashmap.HashNestedKey i64) as map_nested_i64)
(import (hashmap.hashmap GenericHashKey i64) as map_generic_struct)
(import (hashmap.hashmap GenericHashKeyTag i64) as map_generic_enum)
(import (hashmap.hashmap (Tuple i64 String) i64) as map_generic_tuple)
(import (hashmap.hashmap (Array i16 2) i64) as map_generic_array)
(import (hashmap.hashmap collision_first.DuplicateKey i64) as map_duplicate_name)

(define (generic-array-key [first : i64]) : (Array i16 2)
  (array (cast first : i16) 0))

(test
  hashmap-macro-aggregate-key-basic-operations
  (let
    [alpha : hashmap.HashNestedKey (hashmap.hash-key-alpha)]
    [alpha-copy : hashmap.HashNestedKey (hashmap.hash-key-alpha-copy)]
    [beta : hashmap.HashNestedKey (hashmap.hash-key-beta)]
    [missing : hashmap.HashNestedKey (hashmap.hash-key-missing)]
    [m : map_nested_i64.Map (map_nested_i64.with-capacity 2)]
    (begin
      (test.assert-i64-eq
        (map_nested_i64.len (& m))
        0
        "fresh aggregate-key len")
      (test.assert-true
        (map_nested_i64.is-empty? (& m))
        "fresh aggregate-key empty")
      (map_nested_i64.insert! m alpha 10)
      (map_nested_i64.insert! m beta 20)
      (test.assert-i64-eq
        (map_nested_i64.len (& m))
        2
        "aggregate-key insert len")
      (test.assert-i64-eq
        (map_nested_i64.lookup-value-or
          (map_nested_i64.get (& m) alpha-copy)
          -1)
        10
        "aggregate-key owned get by equal copy")
      (test.assert-true
        (map_nested_i64.borrowed-value-found?
          (map_nested_i64.get-value-borrowed (& m) beta))
        "aggregate-key borrowed value get")
      (test.assert-false
        (map_nested_i64.contains? (& m) missing)
        "aggregate-key missing absent")
      (test.assert-true
        (map_nested_i64.remove-ok? (map_nested_i64.remove! m beta))
        "aggregate-key remove")
      (test.assert-false
        (map_nested_i64.contains? (& m) beta)
        "aggregate-key removed absent")
      (match (map_nested_i64.entry-or-insert! m beta 22)
        [(map_nested_i64.EntryOrInsertInserted value)
          (test.assert-i64-eq value 22 "aggregate-key entry inserted value")]
        [(map_nested_i64.EntryOrInsertFound _)
          (test.assert-true false "aggregate-key entry-or-insert should insert")])
      (match (map_nested_i64.entry-or-insert! m alpha-copy 99)
        [(map_nested_i64.EntryOrInsertFound value)
          (test.assert-i64-eq value 10 "aggregate-key entry found value")]
        [(map_nested_i64.EntryOrInsertInserted _)
          (test.assert-true false "aggregate-key entry-or-insert should find")])
      (let
        [cursor : i64 (map_nested_i64.next-occupied (& m) 0)]
        (test.assert-true
          (>=
            (map_nested_i64.entry-value-or
              (map_nested_i64.entry-at (& m) cursor)
              -1)
            0)
          "aggregate-key entry cursor returns a value")))))

(test
  hashmap-macro-aggregate-struct-value-basic-operations
  (let
    [m : map_string_payload.Map (map_string_payload.with-capacity 2)]
    (begin
      (map_string_payload.insert! m "alpha" (hashmap.HashPayload 3 4))
      (map_string_payload.insert! m "beta" (hashmap.HashPayload 5 6))
      (test.assert-i64-eq
        (hashmap.hash-payload-score
          (map_string_payload.lookup-value-or
            (map_string_payload.get (& m) "alpha")
            (hashmap.HashPayload 0 0)))
        7
        "aggregate struct value owned get")
      (test.assert-true
        (map_string_payload.borrowed-value-found?
          (map_string_payload.get-value-borrowed (& m) "beta"))
        "aggregate struct value borrowed get")
      (map_string_payload.insert-or-update!
        m
        "alpha"
        (hashmap.HashPayload 20 1))
      (test.assert-i64-eq
        (hashmap.hash-payload-score
          (map_string_payload.lookup-value-or
            (map_string_payload.get (& m) "alpha")
            (hashmap.HashPayload 0 0)))
        21
        "aggregate struct value update")
      (test.assert-true
        (map_string_payload.remove-ok? (map_string_payload.remove! m "beta"))
        "aggregate struct value remove")
      (match (map_string_payload.entry-or-insert!
        m
        "beta"
        (hashmap.HashPayload 8 9))
        [(map_string_payload.EntryOrInsertInserted value)
          (test.assert-i64-eq
            (hashmap.hash-payload-score value)
            17
            "aggregate struct value entry inserted")]
        [(map_string_payload.EntryOrInsertFound _)
          (test.assert-true false "aggregate struct value entry should insert")])
      (let
        [cursor : i64 (map_string_payload.next-occupied (& m) 0)]
        (test.assert-true
          (>
            (hashmap.hash-payload-score
              (map_string_payload.entry-value-or
                (map_string_payload.entry-at (& m) cursor)
                (hashmap.HashPayload 0 0)))
            0)
          "aggregate struct value entry cursor returns a value")))))

(test
  hashmap-macro-aggregate-enum-value-basic-operations
  (let
    [m : map_i64_state.Map (map_i64_state.with-capacity 2)]
    (begin
      (map_i64_state.insert! m 1 (hashmap.HashReady 10))
      (map_i64_state.insert! m 2 (hashmap.HashPaused 3))
      (test.assert-i64-eq
        (hashmap.hash-state-score
          (map_i64_state.lookup-value-or
            (map_i64_state.get (& m) 1)
            (hashmap.HashFailed)))
        10
        "aggregate enum value owned get")
      (test.assert-true
        (map_i64_state.borrowed-value-found?
          (map_i64_state.get-value-borrowed (& m) 2))
        "aggregate enum value borrowed get")
      (map_i64_state.insert-or-update! m 1 (hashmap.HashPaused 7))
      (test.assert-i64-eq
        (hashmap.hash-state-score
          (map_i64_state.lookup-value-or
            (map_i64_state.get (& m) 1)
            (hashmap.HashFailed)))
        -7
        "aggregate enum value update")
      (test.assert-true
        (map_i64_state.remove-ok? (map_i64_state.remove! m 2))
        "aggregate enum value remove")
      (match (map_i64_state.entry-or-insert! m 2 (hashmap.HashReady 22))
        [(map_i64_state.EntryOrInsertInserted value)
          (test.assert-i64-eq
            (hashmap.hash-state-score value)
            22
            "aggregate enum value entry inserted")]
        [(map_i64_state.EntryOrInsertFound _)
          (test.assert-true false "aggregate enum value entry should insert")])
      (let
        [cursor : i64 (map_i64_state.next-occupied (& m) 0)]
        (test.assert-true
          (>=
            (hashmap.hash-state-score
              (map_i64_state.entry-value-or
                (map_i64_state.entry-at (& m) cursor)
                (hashmap.HashFailed)))
            -7)
          "aggregate enum value entry cursor returns a value")))))

(test
  hashmap-macro-generic-structural-key-modules
  (let
    [left : GenericHashKey
      (GenericHashKey (tuple 7 true) (array 1 2 3) (GenericHashKeyText "alpha"))]
    [equal : GenericHashKey
      (GenericHashKey
        (tuple 7 true)
        (array 1 2 3)
        (GenericHashKeyText (string_mod.append "al" "pha")))]
    [other-variant : GenericHashKey
      (GenericHashKey
        (tuple 7 true)
        (array 1 2 3)
        (GenericHashKeyOtherText "alpha"))]
    [structs : map_generic_struct.Map (map_generic_struct.with-capacity 2)]
    [enums : map_generic_enum.Map (map_generic_enum.new)]
    [tuples : map_generic_tuple.Map (map_generic_tuple.new)]
    (begin
      (map_generic_struct.insert! structs left 41)
      (test.assert-i64-eq
        (map_generic_struct.lookup-value-or
          (map_generic_struct.get (& structs) equal)
          -1)
        41
        "generic struct key uses generated hash and equality")
      (test.assert-true
        (map_generic_struct.contains? (& structs) equal)
        "generic struct query remains reusable")
      (test.assert-false
        (map_generic_struct.contains? (& structs) other-variant)
        "nested enum variant contributes to key identity")
      (let
        [entry : (map_generic_struct.MutEntry structs)
          (map_generic_struct.get-mut-entry (&mut structs) equal)]
        (begin
          (test.assert-true
            (map_generic_struct.mut-entry-present? entry)
            "generic struct mutable entry is present")
          (map_generic_struct.mut-entry-set! entry 42)))
      (test.assert-i64-eq
        (map_generic_struct.lookup-value-or
          (map_generic_struct.get (& structs) equal)
          -1)
        42
        "generic struct mutable entry updates the value")
      (map_generic_enum.insert! enums (GenericHashKeyText "same") 11)
      (map_generic_enum.insert! enums (GenericHashKeyOtherText "same") 22)
      (test.assert-i64-eq
        (map_generic_enum.lookup-value-or
          (map_generic_enum.get (& enums) (GenericHashKeyOtherText "same"))
          -1)
        22
        "root enum variants remain distinct")
      (map_generic_tuple.insert! tuples (tuple 9 "tuple") 33)
      (test.assert-i64-eq
        (map_generic_tuple.lookup-value-or
          (map_generic_tuple.get
            (& tuples)
            (tuple 9 (string_mod.append "tu" "ple")))
          -1)
        33
        "root tuple key compares equal distinct strings"))))

(test
  hashmap-macro-generic-fixed-array-collision-growth-and-tombstone
  (let
    [owned-first : (Array i16 2) (generic-array-key 0)]
    [first-query : (Array i16 2) (generic-array-key 0)]
    [collision : (Array i16 2) (generic-array-key 8)]
    [replacement : (Array i16 2) (generic-array-key 16)]
    [m : map_generic_array.Map (map_generic_array.with-capacity 8)]
    [next : i64 1]
    (begin
      (test.assert-i64-eq
        (bit-and (map_generic_array.hash-key first-query) 7)
        (bit-and (map_generic_array.hash-key collision) 7)
        "fixed-array fixture keys collide in the initial table")
      (map_generic_array.insert! m owned-first 10)
      (array-set! owned-first 0 99)
      (test.assert-i64-eq
        (map_generic_array.lookup-value-or
          (map_generic_array.get (& m) first-query)
          -1)
        10
        "insertion clones an aggregate key into map ownership")
      (map_generic_array.insert! m collision 20)
      (test.assert-true
        (map_generic_array.remove-ok? (map_generic_array.remove! m first-query))
        "fixed-array collision head removed")
      (test.assert-i64-eq
        (map_generic_array.lookup-value-or
          (map_generic_array.get (& m) collision)
          -1)
        20
        "fixed-array lookup crosses a tombstone")
      (map_generic_array.insert! m replacement 30)
      (while (< next 20)
        (begin
          (if (or (= next 8) (= next 16))
            unit
            (map_generic_array.insert! m (generic-array-key next) next))
          (set! next (+ next 1))))
      (test.assert-true
        (> (map_generic_array.capacity (& m)) 8)
        "fixed-array structural keys survive growth")
      (test.assert-i64-eq
        (map_generic_array.lookup-value-or
          (map_generic_array.get (& m) collision)
          -1)
        20
        "collision key survives growth")
      (test.assert-i64-eq
        (map_generic_array.lookup-value-or
          (map_generic_array.get (& m) replacement)
          -1)
        30
        "tombstone replacement survives growth"))))

(test
  hashmap-macro-clone-helper-keeps-exact-nominal-owner
  (let
    [key : collision_first.DuplicateKey (collision_first.DuplicateKey "first")]
    [equal : collision_first.DuplicateKey
      (collision_first.DuplicateKey (string_mod.append "fir" "st"))]
    [other-owner : collision_second.DuplicateKey
      (clone (collision_second.DuplicateKey "second"))]
    [m : map_duplicate_name.Map (map_duplicate_name.new)]
    (begin
      (map_duplicate_name.insert! m key 42)
      (test.assert-i64-eq
        (map_duplicate_name.lookup-value-or
          (map_duplicate_name.get (& m) equal)
          -1)
        42
        "generated clone helper resolves the exact duplicate-name owner")
      (test.assert-i64-eq
        (__tl_string_length (struct-get other-owner text))
        6
        "second duplicate-name clone helper remains independently reachable"))))