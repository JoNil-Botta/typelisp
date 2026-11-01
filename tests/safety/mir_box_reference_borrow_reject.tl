;; A box holding a reference keeps its referent borrowed while the box is
;; used.
(defstruct Pair
  (a i64)
  (b i64))

(define (bump [cell : (&mut cell Pair)]) : unit
  (set! cell.b (+ cell.b 1)))

(define (main) : i64
  (let
    [pair : Pair (Pair 1 41)]
    [held : (Box (& pair i64)) (box (& pair.b))]
    (begin
      (bump (&mut pair))
      (deref (deref held)))))