;; A local borrow's referent is no more movable than a parameter's (#8554).
(defstruct Pt
  (name String)
  (x i64))

(define (by-value [p : Pt]) : i64
  p.x)

(define (main) : i64
  (let
    [p (Pt "a" 1)]
    [r (& p)]
    (by-value (deref r))))