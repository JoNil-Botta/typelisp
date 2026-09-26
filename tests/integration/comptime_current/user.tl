;; A named module that calls the provider's macros.
(module comptime_current.user)

(import comptime_current.provider)

(defstruct UserThing
  (x i64))

(define (where) : String
  (provider.where))

(provider.declare-where declared)

(define (owns?) : bool
  (provider.owned-here? UserThing))