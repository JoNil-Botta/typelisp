;; Passing a non-Copy referent by value would move it out of the shared
;; reference (#8554).
(defstruct Pt
  (name String)
  (x i64))

(define (by-value [p : Pt]) : i64
  p.x)

(define (via-ref [p : (& Pt)]) : i64
  (by-value (deref p)))

(define (main) : i64
  (let
    [p (Pt "a" 1)]
    (via-ref (& p))))