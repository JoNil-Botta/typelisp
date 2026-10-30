(module callable_binders_transport_defs)

(define (identity [value : (& source i64)]) : (& source i64)
  value)

(define (returned) : (-> (& result i64) (& result i64))
  identity)

(defmacro (generated) : Module
  `(begin
    (module callable.generated)
    (define (identity [value : (& generated i64)]) : (& generated i64)
      value)))