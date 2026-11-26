;; A different module with a same-named struct: the macro's `Handle` must still
;; resolve to its own definition module, never to this one.
(module macro_type_hygiene_other)

(defstruct Handle
  (other i64))

(define (new-handle) : Handle
  (Handle 7))