;; hashmap_macro_scalar_modules.tl - scalar generated-module hashmap surfaces (#3760).
(import stdlib.test)
(import stdlib.hashmap)
(import stdlib.string)
(import (hashmap String String) as map_string_string)
(import (hashmap i64 i64) as map_i64_i64)
(import (hashmap i64 String) as map_i64_string)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(test
  hashmap-macro-string-string-basic-operations
  (let
    [alpha : String "alpha"]
    [beta : String "beta"]
    [m : map_string_string.Map (map_string_string.with-capacity 2)]
    (begin
      (test.assert-i64-eq (map_string_string.len (& m)) 0 "fresh StringString len")
      (test.assert-true
        (map_string_string.is-empty? (& m))
        "fresh StringString empty")
      (map_string_string.insert (&mut m) "alpha" "red")
      (map_string_string.insert (&mut m) "beta" "amber")
      (test.assert-i64-eq (map_string_string.len (& m)) 2 "StringString insert len")
      (assert-owned-string-eq
        (map_string_string.lookup-value-or
          (map_string_string.get (& m) "alpha")
          "fallback")
        "red"
        "StringString owned get")
      (assert-owned-string-eq
        (map_string_string.lookup-value-or
          (map_string_string.get-borrowed (& m) (& beta))
          "fallback")
        "amber"
        "StringString borrowed get")
      (test.assert-true
        (map_string_string.contains-borrowed? (& m) (& alpha))
        "StringString borrowed contains")
      (test.assert-true
        (map_string_string.borrowed-value-found?
          (map_string_string.get-value-borrowed (& m) (& alpha)))
        "StringString borrowed value get")
      (test.assert-true
        (map_string_string.remove-ok?
          (map_string_string.remove-borrowed (&mut m) (& beta)))
        "StringString remove borrowed")
      (test.assert-false
        (map_string_string.contains? (& m) "beta")
        "StringString removed key absent")
      (match (map_string_string.entry-or-insert (&mut m) "beta" "gold")
        [(map_string_string.EntryOrInsertInserted value)
          (assert-owned-string-eq value "gold" "StringString inserted value")]
        [(map_string_string.EntryOrInsertFound _)
          (test.assert-true false "StringString entry-or-insert should insert")])
      (match (map_string_string.entry-or-insert (&mut m) "alpha" "purple")
        [(map_string_string.EntryOrInsertFound value)
          (assert-owned-string-eq value "red" "StringString found value")]
        [(map_string_string.EntryOrInsertInserted _)
          (test.assert-true false "StringString entry-or-insert should find")])
      (let
        [entry : (map_string_string.MutEntry m)
          (map_string_string.get-mut-entry-borrowed (&mut m) (& alpha))]
        (begin
          (test.assert-true
            (map_string_string.mut-entry-present? entry)
            "StringString mut-entry present")
          (assert-owned-string-eq
            (map_string_string.mut-entry-value-or entry "fallback")
            "red"
            "StringString mut-entry reads")
          (map_string_string.mut-entry-set! entry "green")))
      (assert-owned-string-eq
        (map_string_string.lookup-value-or
          (map_string_string.get (& m) "alpha")
          "fallback")
        "green"
        "StringString mut-entry writes through")
      (let
        [cursor : i64 (map_string_string.next-occupied (& m) 0)]
        (test.assert-true
          (>
            (string.string-length
              (map_string_string.entry-value-or
                (map_string_string.entry-at (& m) cursor)
                ""))
            0)
          "StringString entry cursor returns a stored value")))))

(test
  hashmap-macro-string-string-insert-grows
  (let
    [m : map_string_string.Map (map_string_string.with-capacity 1)]
    (begin
      (map_string_string.insert (&mut m) "k0" "v0")
      (map_string_string.insert (&mut m) "k1" "v1")
      (map_string_string.insert (&mut m) "k2" "v2")
      (map_string_string.insert (&mut m) "k3" "v3")
      (map_string_string.insert (&mut m) "k4" "v4")
      (map_string_string.insert (&mut m) "k5" "v5")
      (test.assert-i64-eq (map_string_string.len (& m)) 6 "StringString growth len")
      (test.assert-true
        (>= (map_string_string.capacity (& m)) 8)
        "StringString growth capacity")
      (assert-owned-string-eq
        (map_string_string.lookup-value-or
          (map_string_string.get (& m) "k5")
          "fallback")
        "v5"
        "StringString growth keeps late insert"))))

(test
  hashmap-macro-i64-i64-basic-operations
  (let
    [m : map_i64_i64.Map (map_i64_i64.with-capacity 2)]
    (begin
      (test.assert-i64-eq (map_i64_i64.len (& m)) 0 "fresh I64I64 len")
      (test.assert-true (map_i64_i64.is-empty? (& m)) "fresh I64I64 empty")
      (map_i64_i64.insert (&mut m) 1 10)
      (map_i64_i64.insert (&mut m) 2 20)
      (test.assert-i64-eq (map_i64_i64.len (& m)) 2 "I64I64 insert len")
      (test.assert-i64-eq
        (map_i64_i64.lookup-value-or (map_i64_i64.get (& m) 1) -1)
        10
        "I64I64 owned get")
      (test.assert-true (map_i64_i64.contains? (& m) 2) "I64I64 contains")
      (test.assert-true
        (map_i64_i64.borrowed-value-found?
          (map_i64_i64.get-value-borrowed (& m) 1))
        "I64I64 borrowed value get")
      (test.assert-true
        (map_i64_i64.remove-ok? (map_i64_i64.remove (&mut m) 2))
        "I64I64 remove")
      (test.assert-false (map_i64_i64.contains? (& m) 2) "I64I64 removed absent")
      (match (map_i64_i64.entry-or-insert (&mut m) 2 22)
        [(map_i64_i64.EntryOrInsertInserted value)
          (test.assert-i64-eq value 22 "I64I64 inserted value")]
        [(map_i64_i64.EntryOrInsertFound _)
          (test.assert-true false "I64I64 entry-or-insert should insert")])
      (match (map_i64_i64.entry-or-insert (&mut m) 1 99)
        [(map_i64_i64.EntryOrInsertFound value)
          (test.assert-i64-eq value 10 "I64I64 found value")]
        [(map_i64_i64.EntryOrInsertInserted _)
          (test.assert-true false "I64I64 entry-or-insert should find")])
      (let
        [entry : (map_i64_i64.MutEntry m)
          (map_i64_i64.get-mut-entry (&mut m) 1)]
        (begin
          (test.assert-true
            (map_i64_i64.mut-entry-present? entry)
            "I64I64 mut-entry present")
          (test.assert-i64-eq
            (map_i64_i64.mut-entry-value-or entry -1)
            10
            "I64I64 mut-entry reads")
          (map_i64_i64.mut-entry-set! entry 33)))
      (test.assert-i64-eq
        (map_i64_i64.lookup-value-or (map_i64_i64.get (& m) 1) -1)
        33
        "I64I64 mut-entry writes through")
      (let
        [cursor : i64 (map_i64_i64.next-occupied (& m) 0)]
        (test.assert-true
          (>=
            (map_i64_i64.entry-value-or (map_i64_i64.entry-at (& m) cursor) -1)
            0)
          "I64I64 entry cursor returns a value")))))

(test
  hashmap-macro-i64-i64-insert-grows
  (let
    [m : map_i64_i64.Map (map_i64_i64.with-capacity 1)]
    (begin
      (map_i64_i64.insert (&mut m) 0 0)
      (map_i64_i64.insert (&mut m) 1 1)
      (map_i64_i64.insert (&mut m) 2 2)
      (map_i64_i64.insert (&mut m) 3 3)
      (map_i64_i64.insert (&mut m) 4 4)
      (map_i64_i64.insert (&mut m) 5 5)
      (test.assert-i64-eq (map_i64_i64.len (& m)) 6 "I64I64 growth len")
      (test.assert-true (>= (map_i64_i64.capacity (& m)) 8) "I64I64 growth capacity")
      (test.assert-i64-eq
        (map_i64_i64.lookup-value-or (map_i64_i64.get (& m) 5) -1)
        5
        "I64I64 growth keeps late insert"))))

(test
  hashmap-macro-i64-string-basic-operations
  (let
    [m : map_i64_string.Map (map_i64_string.with-capacity 2)]
    (begin
      (test.assert-i64-eq (map_i64_string.len (& m)) 0 "fresh I64String len")
      (test.assert-true (map_i64_string.is-empty? (& m)) "fresh I64String empty")
      (map_i64_string.insert (&mut m) 1 "one")
      (map_i64_string.insert (&mut m) 2 "two")
      (test.assert-i64-eq (map_i64_string.len (& m)) 2 "I64String insert len")
      (assert-owned-string-eq
        (map_i64_string.lookup-value-or (map_i64_string.get (& m) 1) "fallback")
        "one"
        "I64String owned get")
      (test.assert-true (map_i64_string.contains? (& m) 2) "I64String contains")
      (test.assert-true
        (map_i64_string.borrowed-value-found?
          (map_i64_string.get-value-borrowed (& m) 1))
        "I64String borrowed value get")
      (test.assert-true
        (map_i64_string.remove-ok? (map_i64_string.remove (&mut m) 2))
        "I64String remove")
      (test.assert-false
        (map_i64_string.contains? (& m) 2)
        "I64String removed absent")
      (match (map_i64_string.entry-or-insert (&mut m) 2 "deux")
        [(map_i64_string.EntryOrInsertInserted value)
          (assert-owned-string-eq value "deux" "I64String inserted value")]
        [(map_i64_string.EntryOrInsertFound _)
          (test.assert-true false "I64String entry-or-insert should insert")])
      (match (map_i64_string.entry-or-insert (&mut m) 1 "uno")
        [(map_i64_string.EntryOrInsertFound value)
          (assert-owned-string-eq value "one" "I64String found value")]
        [(map_i64_string.EntryOrInsertInserted _)
          (test.assert-true false "I64String entry-or-insert should find")])
      (let
        [entry : (map_i64_string.MutEntry m)
          (map_i64_string.get-mut-entry (&mut m) 1)]
        (begin
          (test.assert-true
            (map_i64_string.mut-entry-present? entry)
            "I64String mut-entry present")
          (assert-owned-string-eq
            (map_i64_string.mut-entry-value-or entry "fallback")
            "one"
            "I64String mut-entry reads")
          (map_i64_string.mut-entry-set! entry "uno")))
      (assert-owned-string-eq
        (map_i64_string.lookup-value-or (map_i64_string.get (& m) 1) "fallback")
        "uno"
        "I64String mut-entry writes through")
      (let
        [cursor : i64 (map_i64_string.next-occupied (& m) 0)]
        (test.assert-true
          (>
            (string.string-length
              (map_i64_string.entry-value-or
                (map_i64_string.entry-at (& m) cursor)
                ""))
            0)
          "I64String entry cursor returns a value")))))

(test
  hashmap-macro-i64-string-insert-grows
  (let
    [m : map_i64_string.Map (map_i64_string.with-capacity 1)]
    (begin
      (map_i64_string.insert (&mut m) 0 "v0")
      (map_i64_string.insert (&mut m) 1 "v1")
      (map_i64_string.insert (&mut m) 2 "v2")
      (map_i64_string.insert (&mut m) 3 "v3")
      (map_i64_string.insert (&mut m) 4 "v4")
      (map_i64_string.insert (&mut m) 5 "v5")
      (test.assert-i64-eq (map_i64_string.len (& m)) 6 "I64String growth len")
      (test.assert-true
        (>= (map_i64_string.capacity (& m)) 8)
        "I64String growth capacity")
      (assert-owned-string-eq
        (map_i64_string.lookup-value-or (map_i64_string.get (& m) 5) "fallback")
        "v5"
        "I64String growth keeps late insert"))))
