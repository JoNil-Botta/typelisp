(defstruct Pt
  (name String)
  (x i64))

(define (two [_left : (&mut _left Pt)] [_right : (&mut _right Pt)]) : unit
  unit)

(define (probe [p : (&mut p Pt)]) : unit
  (two (&mut (deref p)) (&mut (deref p))))

(define (main) : i64
  42)