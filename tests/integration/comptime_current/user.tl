;; A named module that calls the provider's macros.
(import comptime_current.provider)

(defstruct UserThing
  (x i64))

(define (where) : String
  (provider.where))

(provider.declare-nested-where declared)

(define (owns?) : bool
  (provider.owned-here? UserThing))

(define (nested-where) : String
  (provider.nested-where))