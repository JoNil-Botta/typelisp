;; A macro's unqualified nominal type names this module's type (#10004 C43).
(module macro_type_hygiene_dep)

(defstruct Handle
  (fd i64))

(define (new-handle) : Handle
  (Handle 42))

(defmacro (handle-fd [value : Expr]) : Expr
  `(let
    [h : Handle ,value]
    h.fd))