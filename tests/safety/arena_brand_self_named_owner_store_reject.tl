;; #9604: a self-named arena handle `[owner : (arena.Arena owner)]` carries the
;; caller's arena region, which outlives every parameter, wherever the handle
;; appears in the parameter list.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

; Must fail: `a` names the parameter `a`'s storage, which ends with the call.
(define (f
  [a : i64]
  [ra : (& a i64)]
  [owner : (arena.Arena owner)]
  [out : (&mut owner (RefBox owner))]) : unit
  (set! out.value ra))

(define (main) : i64
  0)