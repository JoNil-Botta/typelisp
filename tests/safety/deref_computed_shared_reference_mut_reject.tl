;; `(deref e)` of a computed shared reference is its referent, reached through
;; the temporary holding `e`: a mutable borrow of it writes through `&`.
(defstruct Pt
  (name String)
  (x i64))

(define (bump [p : (&mut p Pt)]) : unit
  (set! p.x (+ p.x 1)))

(define (view [p : (& p Pt)]) : (& p Pt)
  p)

(define (probe [p : (& p Pt)]) : unit
  (bump (&mut (deref (view p)))))

(define (main) : i64
  42)