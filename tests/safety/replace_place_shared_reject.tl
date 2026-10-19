(defstruct Pt
  (name String)
  (x i64))

(define (probe [p : (& p Pt)]) : Pt
  (replace! (deref p) (Pt "z" 2)))

(define (main) : i64
  42)