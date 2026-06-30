;; module_macro_generated_normal_and_nested_import.tl - generated module bodies
;; can combine normal imports with nested generated imports.
(import stdlib.array)
(import stdlib.test)
(import stdlib.vector_slice)
(import (vector_slice.slice i64) as i64s)

(test
  generated-module-body-normal-import-with-nested-generated-import
  (let
    [items : (Array i64) (array.make-array i64 2)]
    (begin
      (array-set! items 0 11)
      (array-set! items 1 31)
      (let
        [view : (i64s.Slice items) (i64s.from-array (& items) 2 0 2)]
        (begin
          (test.assert-i64-eq (i64s.len view) 2 "slice len")
          (test.assert-i64-eq (i64s.get view 1 -1) 31 "slice value"))))))