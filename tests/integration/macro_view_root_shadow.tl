;; The entry module declares `size` and a `State` variant, as the imported
;; macro_view_root_shadow_lib.tl does, and imports the generated module that
;; library later imports lazily. Typing the library's locals during macro
;; expansion must see `m.Map` resolved (#8614).
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as root_map)
(import macro_view_root_shadow_lib as lib)

(defenum Local
  (State i64))

(define (size [x : i64]) : i64
  x)

(define (main) : i64
  (+
    (lib.bump (root_map.with-capacity 4))
    (lib.slot-base 30 (root_map.with-capacity 4))
    (size 3)
    (match (State 2)
      [(State n) n])))