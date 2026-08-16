(module format_owner_state)

(import stdlib.format)

(defenum State
  (Ready)
  (Count i64))

(define (to-string [value : (& value State)]) : String
  (match value
    [(Ready) "ready"]
    [(Count count) (format.format "count={}" (deref count))]))