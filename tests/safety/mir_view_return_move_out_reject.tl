;: Returning a move-only field read through a shared reference moves it out.
(defstruct Names
  (first String)
  (count i64))

(define (first-of [names : (& names Names)]) : String
  names.first)

(define (main) : i64
  0)