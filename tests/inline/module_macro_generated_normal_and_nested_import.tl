;; module_macro_generated_normal_and_nested_import.tl - generated module bodies
;; can combine normal imports with nested generated imports.
(import stdlib.test)
(import stdlib.vector)
(import stdlib.vector_slice)
(import (vector.vector i64) as i64v)
(import (vector_slice.slice i64) as i64s)

(test
  generated-module-body-normal-import-with-nested-generated-import
  (let
    [items : i64v.Vec (i64v.with-capacity 2)]
    (begin
      (i64v.push (&mut items) 11)
      (i64v.push (&mut items) 31)
      (let
        [view : (i64s.Slice items) (i64s.all-vec (& items))]
        (begin
          (test.assert-i64-eq (i64s.len view) 2 "slice len")
          (test.assert-i64-eq (i64s.get view 1 -1) 31 "slice value"))))))