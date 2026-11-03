;; #8998: a constructor formal spelled like a binding infers under a hidden
;; name; a `(&mut program T)` argument it echoes binds the unshadowed `program`
;; (as without the collision), and where a parameter named `program` shadows
;; the reserved lifetime, `program` is that parameter's own lifetime instead.
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (:lifetimes p)
  (m (&mut p Pt)))

(define (local-use [r : (&mut program Pt)] [p : i64]) : i64
  (let
    [h (Holder r)]
    h.m.x))

(define (shadowed-use [r : (&mut program Pt)] [p : i64] [program : i64]) : i64
  (let
    [h (Holder r)]
    h.m.x))

(define (main) : i64
  0)