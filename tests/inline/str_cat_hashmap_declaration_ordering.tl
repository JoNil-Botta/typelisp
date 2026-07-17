;; str_cat_hashmap_declaration_ordering.tl - declaration families are generated
;; before expression macros expand when both occur in one program.
(import stdlib.test)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.hashmap)
(import (hashmap i64 i64) as map_i64_i64)

(test
  str-cat-hashmap-declaration-ordering
  (let
    [m : map_i64_i64.Map (map_i64_i64.with-capacity 8)]
    (begin
      (map_i64_i64.insert! m 1 7)
      (test.assert-i64-eq
        (+
          (map_i64_i64.capacity (& m))
          (string.string-length (str_cat.str-cat "a" "b")))
        10
        "generated hashmap declarations precede str-cat expansion"))))