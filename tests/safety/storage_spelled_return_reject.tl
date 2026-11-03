;; #8998: a lifetime spelled like a by-value parameter names that parameter's
;; storage, which ends before every caller region.
; Must fail: `a` is the storage of the by-value `a`.
(define (bad [a : i64] [r : (& a i64)] [q : (& q i64)]) : (& q i64)
  r)

(define (main) : i64
  0)