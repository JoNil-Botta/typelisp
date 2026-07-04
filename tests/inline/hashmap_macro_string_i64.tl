;; hashmap_macro_string_i64.tl - module-emitting hashmap macro surface (#3201).
(import "stdlib/test.tl")
(import stdlib.hashmap)
(import (hashmap String i64) as map_string_i64)

(test
  hashmap-macro-string-i64-basic-operations
  (let
    [alpha : String "alpha"]
    [beta : String "beta"]
    [m : map_string_i64.Map (map_string_i64.with-capacity 2)]
    (begin
      (assert-i64-eq (map_string_i64.len (& m)) 0 "fresh map len")
      (assert-true (map_string_i64.is-empty? (& m)) "fresh map empty")
      (map_string_i64.insert (&mut m) "alpha" 10)
      (map_string_i64.insert (&mut m) "beta" 20)
      (assert-i64-eq (map_string_i64.len (& m)) 2 "insert updates len")
      (assert-false
        (map_string_i64.insert-if-absent? (&mut m) "alpha" 99)
        "insert-if-absent reports existing key")
      (assert-i64-eq
        (map_string_i64.lookup-value-or (map_string_i64.get (& m) "alpha") -1)
        10
        "insert-if-absent preserves existing value")
      (assert-true
        (map_string_i64.insert-if-absent? (&mut m) "gamma" 30)
        "insert-if-absent inserts missing key")
      (assert-i64-eq
        (map_string_i64.lookup-value-or (map_string_i64.get (& m) "gamma") -1)
        30
        "insert-if-absent stores missing value")
      (assert-i64-eq
        (map_string_i64.lookup-value-or (map_string_i64.get (& m) "alpha") -1)
        10
        "owned get finds alpha")
      (assert-i64-eq
        (map_string_i64.lookup-value-or
          (map_string_i64.get-borrowed (& m) (& beta))
          -1)
        20
        "borrowed get finds beta")
      (assert-true
        (map_string_i64.contains-borrowed? (& m) (& alpha))
        "borrowed contains alpha")
      (assert-true
        (map_string_i64.borrowed-value-found?
          (map_string_i64.get-value-borrowed (& m) (& alpha)))
        "borrowed value get finds alpha")
      (assert-true
        (map_string_i64.remove-ok?
          (map_string_i64.remove-borrowed (&mut m) (& beta)))
        "remove borrowed hit")
      (assert-false
        (map_string_i64.contains? (& m) "beta")
        "removed key absent")
      (match (map_string_i64.entry-or-insert (&mut m) "beta" 22)
        [(map_string_i64.EntryOrInsertInserted value)
          (assert-i64-eq value 22 "entry-or-insert inserted value")]
        [(map_string_i64.EntryOrInsertFound _)
          (assert-true false "entry-or-insert should insert")])
      (match (map_string_i64.entry-or-insert (&mut m) "alpha" 99)
        [(map_string_i64.EntryOrInsertFound value)
          (assert-i64-eq value 10 "entry-or-insert found existing value")]
        [(map_string_i64.EntryOrInsertInserted _)
          (assert-true false "entry-or-insert should find")])
      (let
        [entry : (map_string_i64.MutEntry m)
          (map_string_i64.get-mut-entry-borrowed (&mut m) (& alpha))]
        (begin
          (assert-true
            (map_string_i64.mut-entry-present? entry)
            "mut-entry present")
          (assert-i64-eq
            (map_string_i64.mut-entry-value-or entry -1)
            10
            "mut-entry reads current value")
          (map_string_i64.mut-entry-set! entry 33)))
      (assert-i64-eq
        (map_string_i64.lookup-value-or (map_string_i64.get (& m) "alpha") -1)
        33
        "mut-entry writes through")
      (let
        [cursor : i64 (map_string_i64.next-occupied (& m) 0)]
        (assert-true
          (>=
            (map_string_i64.entry-value-or
              (map_string_i64.entry-at (& m) cursor)
              -1)
            0)
          "entry cursor returns a value")))))

(test
  hashmap-macro-string-i64-insert-grows
  (let
    [m : map_string_i64.Map (map_string_i64.with-capacity 1)]
    (begin
      (map_string_i64.insert (&mut m) "k0" 0)
      (map_string_i64.insert (&mut m) "k1" 1)
      (map_string_i64.insert (&mut m) "k2" 2)
      (map_string_i64.insert (&mut m) "k3" 3)
      (map_string_i64.insert (&mut m) "k4" 4)
      (map_string_i64.insert (&mut m) "k5" 5)
      (assert-i64-eq (map_string_i64.len (& m)) 6 "growth preserves len")
      (assert-true
        (>= (map_string_i64.capacity (& m)) 8)
        "growth expands capacity")
      (assert-i64-eq
        (map_string_i64.lookup-value-or (map_string_i64.get (& m) "k5") -1)
        5
        "growth keeps late insert"))))