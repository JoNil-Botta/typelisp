;; #8998: a lifetime spelled like a by-value parameter names that parameter's
;; storage, which ends before every caller region.
;; A by-value parameter named `program` shadows the reserved lifetime.
; Must fail: `program` is the storage of the by-value `program`.
(define (bad [program : i64] [r : (& program i64)] [q : (& q i64)]) : (& q i64)
  r)

(define (main) : i64
  0)