;; An or-pattern over an opaque enum's variants is rejected outside its module
;; family like any other match on it (#6999).
(import opaque_dep)

(define (peek [s : (& a opaque_dep.State)]) : i64
  (match (deref s)
    [(or opaque_dep.Idle (opaque_dep.Busy _)) 0]))

(define (main) : i64
  0)