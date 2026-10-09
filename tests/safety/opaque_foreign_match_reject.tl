;; Matching the variants of an opaque enum is rejected outside its module
;; family, even through a reference (#6999). The scrutinee is the reference
;; itself: a `(deref s)` scrutinee is already rejected as a by-value read
;; (#8734, opaque_foreign_deref_match_reject), before any pattern.
(import opaque_dep)

(define (peek [s : (& a opaque_dep.State)]) : i64
  (match s
    [(opaque_dep.Idle) 0]
    [_ 1]))

(define (main) : i64
  0)