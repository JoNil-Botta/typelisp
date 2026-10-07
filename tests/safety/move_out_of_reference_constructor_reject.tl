;; A constructor operand is a by-value use of the referent (#8554).
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (pt Pt))

(define (via-ref [p : (& Pt)]) : Holder
  (Holder (deref p)))

(define (main) : i64
  (let
    [p (Pt "a" 1)]
    (via-ref (& p)).pt.x))