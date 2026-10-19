(defstruct Pt
  (name String)
  (x i64))

(define (bump [p : (&mut p Pt)]) : unit
  (set! p.x (+ p.x 1)))

(define (take [_value : Pt]) : unit
  unit)

(define (probe [p : (&mut p Pt)]) : unit
  (bump
    (&mut
      (deref
        (begin
          (take (deref p))
          p)))))

(define (main) : i64
  42)