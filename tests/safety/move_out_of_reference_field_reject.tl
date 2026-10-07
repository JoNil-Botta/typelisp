;; A dotted field projection through a reference reads the field through the
;; reference, so a non-Copy field cannot be passed by value (#8554).
(defstruct Pt
  (name String)
  (x i64))

(defstruct Outer
  (pt Pt)
  (n i64))

(define (by-value [p : Pt]) : i64
  p.x)

(define (via-ref [o : (& Outer)]) : i64
  (by-value o.pt))

(define (main) : i64
  (let
    [o (Outer (Pt "a" 1) 2)]
    (via-ref (& o))))