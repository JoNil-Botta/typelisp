;; #9604: a by-value arena parameter's brand is a caller region. It outlives
;; the parameters, so a lifetime spelled like a by-value parameter (that
;; parameter's storage) cannot be stored into brand storage.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

; Must fail: `a` names the parameter `a`'s storage, which ends with the call.
(define (f
  [a : i64]
  [ra : (& a i64)]
  [ar : (arena.Arena r)]
  [out : (&mut r (RefBox r))]) : unit
  (set! out.value ra))

(define (main) : i64
  0)