(module macro_type_hygiene_user)

(import macro_type_hygiene_dep)
(import macro_type_hygiene_other)

(define (fd) : i64
  (macro_type_hygiene_dep.handle-fd (macro_type_hygiene_dep.new-handle)))