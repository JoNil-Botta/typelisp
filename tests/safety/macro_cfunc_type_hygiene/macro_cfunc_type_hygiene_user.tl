(module macro_cfunc_type_hygiene_user)

(import macro_cfunc_type_hygiene_dep)
(import macro_cfunc_type_hygiene_other)

(define (fd) : i64
  (macro_cfunc_type_hygiene_dep.handle-call
    macro_cfunc_type_hygiene_dep.handle-ptr
    (macro_cfunc_type_hygiene_dep.Handle 42)))