;; A different module with a same-named struct: the macro's `Handle` inside the
;; quoted signature must still resolve to its own definition module.
(module macro_cfunc_type_hygiene_other)

(defstruct Handle
  (other i64))