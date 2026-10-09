;; An or-pattern over an opaque enum's variants is rejected outside its module
;; family like any other match on it (#6999). The scrutinee is the reference
;; itself: a `(deref s)` scrutinee is already rejected as a by-value read
;; (#8734), before any pattern.
(import opaque_dep)

(define (peek [s : (& a opaque_dep.State)]) : i64
  (match s
    [(or opaque_dep.Idle (opaque_dep.Busy _)) 0]))

(define (main) : i64
  0)