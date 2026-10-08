;: A field nested inside a field reached through a shared reference cannot be
;: borrowed mutably: the path stays shared below the first projection (#8694).
(defstruct Pt
  (name String)
  (x i64))

(defstruct Outer
  (inner Pt)
  (y i64))

(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (f [r : (& Outer)]) : i64
  (bump (&mut r.inner.x))
  r.inner.x)

(define (main) : i64
  (let
    [o (Outer (Pt "a" 40) 0)]
    (f (& o))))