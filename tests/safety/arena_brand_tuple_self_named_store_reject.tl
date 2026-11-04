;; #9604: a tuple-wrapped self-named parameter's lifetime is its storage, which
;; a by-value arena parameter's brand outlives.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

; Must fail: the brand `r` outlives the parameter `n`.
(define (f
  [n : (Tuple (& n i64) i64)]
  [ar : (arena.Arena r)]
  [out : (&mut r (RefBox r))]) : unit
  (set! out.value (tuple-ref n 0)))

(define (main) : i64
  0)