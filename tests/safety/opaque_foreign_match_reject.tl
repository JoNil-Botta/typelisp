;; Matching the variants of an opaque enum is rejected outside its module
;; family, even through a reference (#6999).
(import opaque_dep)

(define (peek [s : (& a opaque_dep.State)]) : i64
  (match (deref s)
    [(opaque_dep.Idle) 0]
    [_ 1]))

(define (main) : i64
  0)