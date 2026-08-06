;; module_macro_generated_normal_and_nested_import.tl - generated module bodies
;; can combine normal imports with nested generated imports.
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector i64) as i64v)

(test
  generated-module-body-normal-import-with-nested-generated-import
  (let
    [items : i64v.Vec (i64v.with-capacity 2)]
    (begin
      (i64v.push (&mut items) 11)
      (i64v.push (&mut items) 31)
      (let
        [view : (& items (Slice i64)) (i64v.view (& items))]
        (begin
          (test.assert-i64-eq (array-length view) 2 "slice len")
          (test.assert-i64-eq (array-ref view 1) 31 "slice value"))))))