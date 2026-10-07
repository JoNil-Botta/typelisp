;; A mutable reference does not own its referent either (#8554).
(defstruct Pt
  (name String)
  (x i64))

(define (by-value [p : Pt]) : i64
  p.x)

(define (via-mut [p : (&mut Pt)]) : i64
  (by-value (deref p)))

(define (main) : i64
  (let
    [p (Pt "a" 1)]
    (via-mut (&mut p))))