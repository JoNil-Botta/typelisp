;: An `if` whose branch reads a move-only field through a shared reference
;: would move the value out from behind the reference.
(defstruct Names
  (first String)
  (count i64))

(define (pick [names : (& names Names)] [fallback : String] [use-first : bool]) : String
  (if use-first
    names.first
    fallback))

(define (main) : i64
  0)