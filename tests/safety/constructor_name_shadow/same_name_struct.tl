;; This module's own `Token` names this struct, not the imported enum of the
;; same name, so constructing it stays an inlined struct literal.
(module same_name_struct)

(import same_name_enum)

(defstruct Token
  (kind i64))

(define (make-token) : Token
  (Token 42))