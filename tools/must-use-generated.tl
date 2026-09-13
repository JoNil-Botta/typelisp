(defmacro (emit-ticket) : Decls
  `(defstruct Ticket
    (:must-use)
    (id i64)))

(emit-ticket)

(define (main) : i64
  (Ticket 42).id)