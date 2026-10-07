;; A branch result is checked by the move check rather than the escape
;; checks; it reports the same move out of the reference (#8554).
(defstruct Pt
  (name String)
  (x i64))

(define (via-ref [p : (& Pt)] [b : bool]) : Pt
  (if b
    (deref p)
    (Pt "z" 0)))

(define (main) : i64
  (let
    [p (Pt "a" 1)]
    (via-ref (& p) true).x))