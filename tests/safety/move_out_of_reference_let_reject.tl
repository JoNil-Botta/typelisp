;; Binding a non-Copy referent by value moves it out of the reference
;; (#8554).
(defstruct Pt
  (name String)
  (x i64))

(define (via-ref [p : (& Pt)]) : i64
  (let
    [q : Pt (deref p)]
    q.x))

(define (main) : i64
  (let
    [p (Pt "a" 1)]
    (via-ref (& p))))