;; hashmap_macro_aggregate_modules.tl - aggregate generated-module hashmap surfaces (#3761).
(import stdlib.test)
(import stdlib.hashmap)
(import (hashmap String hashmap.HashPayload) as map_string_payload)
(import (hashmap i64 hashmap.HashState) as map_i64_state)
(import (hashmap hashmap.HashNestedKey i64) as map_nested_i64)

(test
  hashmap-macro-aggregate-key-basic-operations
  (let
    [alpha : hashmap.HashNestedKey (hashmap.hash-key-alpha)]
    [alpha-copy : hashmap.HashNestedKey (hashmap.hash-key-alpha-copy)]
    [beta : hashmap.HashNestedKey (hashmap.hash-key-beta)]
    [missing : hashmap.HashNestedKey (hashmap.hash-key-missing)]
    [m : map_nested_i64.Map (map_nested_i64.with-capacity 2)]
    (begin
      (test.assert-i64-eq (map_nested_i64.len m) 0 "fresh aggregate-key len")
      (test.assert-true
        (map_nested_i64.is-empty? m)
        "fresh aggregate-key empty")
      (map_nested_i64.insert (&mut m) alpha 10)
      (map_nested_i64.insert (&mut m) beta 20)
      (test.assert-i64-eq (map_nested_i64.len m) 2 "aggregate-key insert len")
      (test.assert-i64-eq
        (map_nested_i64.lookup-value-or (map_nested_i64.get m alpha-copy) -1)
        10
        "aggregate-key owned get by equal copy")
      (test.assert-true
        (map_nested_i64.borrowed-value-found?
          (map_nested_i64.get-value-borrowed (& m) beta))
        "aggregate-key borrowed value get")
      (test.assert-false
        (map_nested_i64.contains? m missing)
        "aggregate-key missing absent")
      (test.assert-true
        (map_nested_i64.remove-ok? (map_nested_i64.remove (&mut m) beta))
        "aggregate-key remove")
      (test.assert-false
        (map_nested_i64.contains? m beta)
        "aggregate-key removed absent")
      (match (map_nested_i64.entry-or-insert (&mut m) beta 22)
        [(map_nested_i64.EntryOrInsertInserted value)
          (test.assert-i64-eq value 22 "aggregate-key entry inserted value")]
        [(map_nested_i64.EntryOrInsertFound _)
          (test.assert-true false "aggregate-key entry-or-insert should insert")])
      (match (map_nested_i64.entry-or-insert (&mut m) alpha-copy 99)
        [(map_nested_i64.EntryOrInsertFound value)
          (test.assert-i64-eq value 10 "aggregate-key entry found value")]
        [(map_nested_i64.EntryOrInsertInserted _)
          (test.assert-true false "aggregate-key entry-or-insert should find")])
      (let
        [cursor : i64 (map_nested_i64.next-occupied m 0)]
        (test.assert-true
          (>=
            (map_nested_i64.entry-value-or
              (map_nested_i64.entry-at m cursor)
              -1)
            0)
          "aggregate-key entry cursor returns a value")))))

(test
  hashmap-macro-aggregate-struct-value-basic-operations
  (let
    [m : map_string_payload.Map (map_string_payload.with-capacity 2)]
    (begin
      (map_string_payload.insert (&mut m) "alpha" (hashmap.HashPayload 3 4))
      (map_string_payload.insert (&mut m) "beta" (hashmap.HashPayload 5 6))
      (test.assert-i64-eq
        (hashmap.hash-payload-score
          (map_string_payload.lookup-value-or
            (map_string_payload.get m "alpha")
            (hashmap.HashPayload 0 0)))
        7
        "aggregate struct value owned get")
      (test.assert-true
        (map_string_payload.borrowed-value-found?
          (map_string_payload.get-value-borrowed (& m) "beta"))
        "aggregate struct value borrowed get")
      (map_string_payload.insert-or-update
        (&mut m)
        "alpha"
        (hashmap.HashPayload 20 1))
      (test.assert-i64-eq
        (hashmap.hash-payload-score
          (map_string_payload.lookup-value-or
            (map_string_payload.get m "alpha")
            (hashmap.HashPayload 0 0)))
        21
        "aggregate struct value update")
      (test.assert-true
        (map_string_payload.remove-ok?
          (map_string_payload.remove (&mut m) "beta"))
        "aggregate struct value remove")
      (match (map_string_payload.entry-or-insert
        (&mut m)
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
        [cursor : i64 (map_string_payload.next-occupied m 0)]
        (test.assert-true
          (>
            (hashmap.hash-payload-score
              (map_string_payload.entry-value-or
                (map_string_payload.entry-at m cursor)
                (hashmap.HashPayload 0 0)))
            0)
          "aggregate struct value entry cursor returns a value")))))

(test
  hashmap-macro-aggregate-enum-value-basic-operations
  (let
    [m : map_i64_state.Map (map_i64_state.with-capacity 2)]
    (begin
      (map_i64_state.insert (&mut m) 1 (hashmap.HashReady 10))
      (map_i64_state.insert (&mut m) 2 (hashmap.HashPaused 3))
      (test.assert-i64-eq
        (hashmap.hash-state-score
          (map_i64_state.lookup-value-or
            (map_i64_state.get m 1)
            (hashmap.HashFailed)))
        10
        "aggregate enum value owned get")
      (test.assert-true
        (map_i64_state.borrowed-value-found?
          (map_i64_state.get-value-borrowed (& m) 2))
        "aggregate enum value borrowed get")
      (map_i64_state.insert-or-update (&mut m) 1 (hashmap.HashPaused 7))
      (test.assert-i64-eq
        (hashmap.hash-state-score
          (map_i64_state.lookup-value-or
            (map_i64_state.get m 1)
            (hashmap.HashFailed)))
        -7
        "aggregate enum value update")
      (test.assert-true
        (map_i64_state.remove-ok? (map_i64_state.remove (&mut m) 2))
        "aggregate enum value remove")
      (match (map_i64_state.entry-or-insert (&mut m) 2 (hashmap.HashReady 22))
        [(map_i64_state.EntryOrInsertInserted value)
          (test.assert-i64-eq
            (hashmap.hash-state-score value)
            22
            "aggregate enum value entry inserted")]
        [(map_i64_state.EntryOrInsertFound _)
          (test.assert-true false "aggregate enum value entry should insert")])
      (let
        [cursor : i64 (map_i64_state.next-occupied m 0)]
        (test.assert-true
          (>=
            (hashmap.hash-state-score
              (map_i64_state.entry-value-or
                (map_i64_state.entry-at m cursor)
                (hashmap.HashFailed)))
            -7)
          "aggregate enum value entry cursor returns a value")))))