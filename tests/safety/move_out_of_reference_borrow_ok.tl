;; The fixes the #8554 diagnostic points to: borrow the referent again,
;; pass the reference on, or read a Copy field by value.
(defstruct Pt
  (name String)
  (x i64))

(define (by-ref [p : (& Pt)]) : i64
  p.x)

(define (via-ref [p : (& Pt)]) : i64
  (+ (by-ref (& (deref p))) (by-ref p) (deref p).x p.x))

(define (main) : i64
  (let
    [p (Pt "a" 10)]
    (+ (via-ref (& p)) 2)))