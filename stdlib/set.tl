;# Generated concrete hash set family (collections v1, #2730).
;#
;# `StringSet` and `I64Set` are generated from explicit key descriptor requests.
;# They expose set-specific APIs over the same deterministic open-addressed
;# storage policy as `stdlib/hashmap.tl`: linear probing, tombstones for remove,
;# power-of-two capacities, resize/rehash on growth, and bucket-order iteration.
;#
;# Use a set when only key membership matters. Use a map when each key carries a
;# meaningful value; callers should not model sets as maps with dummy values.
;#
;# Iteration is deterministic bucket order for a fixed table state. It is not
;# insertion order, and it can change after resize/rehash. Walk by starting at
;# `*-set-next-occupied set 0`, advancing with `(+ index 1)`, and reading each
;# key with `*-set-entry-at`.
;#
;# Usage: `(import stdlib.set)`
(module stdlib.set)

(import stdlib.hashmap as hashmap_mod)

;: Stable descriptor identity for generated `String`-key set families.
(define (set-string-key-descriptor-key) : String
  (hashmap_mod.hashmap-string-key-descriptor-key))

;: Stable descriptor identity for generated `i64`-key set families.
(define (set-i64-key-descriptor-key) : String
  (hashmap_mod.hashmap-i64-key-descriptor-key))

;: Generated `HashSet<String>` family request. The public API is produced by
;: the `stdlib/set-family` declaration generator.
(comptime-decl
  (:generated stdlib/set-family StringSet (type-key (type String)) "stdlib/hashmap/string-key-v1")
  (defstruct StringSet
    (__set_family_request i64)))

;: Generated `HashSet<i64>` family request. The public API is produced by the
;: `stdlib/set-family` declaration generator.
(comptime-decl
  (:generated stdlib/set-family I64Set (type-key (type i64)) "stdlib/hashmap/i64-key-v1")
  (defstruct I64Set
    (__set_family_request i64)))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value set-string-key-descriptor-key)
  (value set-i64-key-descriptor-key)
  (type StringSet)
  (type I64Set)
  (constructor StringSet)
  (constructor I64Set))