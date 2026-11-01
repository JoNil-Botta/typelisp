;; #9096's all-`&mut` twin: the same holder field write through a mutable
;; reference to the holder stays accepted and reaches the caller's `p`.
(defstruct Pt
  (s String)
  (x i64))

(defstruct Hold
  (:lifetimes a)
  (r (&mut a Pt)))

(define (poke [h : (&mut h (Hold a))]) : unit
  (set! (deref h.r) (Pt "z" 42)))

(define (main) : i64
  (let
    [p : Pt (Pt "a" 7)]
    (let
      [hold (Hold (&mut p))]
      (poke (&mut hold)))
    p.x))