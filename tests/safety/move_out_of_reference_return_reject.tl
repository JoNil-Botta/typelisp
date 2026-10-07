;; Returning the referent, here from the tail of a nested `let` and `begin`,
;; moves it out of the reference (#8554).
(defstruct Pt
  (name String)
  (x i64))

(define (via-ref [p : (& Pt)]) : Pt
  (let
    [n : i64 p.x]
    (begin
      n
      (deref p))))

(define (main) : i64
  (let
    [p (Pt "a" 1)]
    (via-ref (& p)).x))