;; #9604: the `(:invalidate r T)` type form invalidates its brand too.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

; Must fail: `slot` would read `v` after `ar` is destroyed.
(define (f
  [a : i64]
  [ar : (:invalidate r (arena.Arena r))]
  [v : (& r i64)]
  [slot : (&mut a (RefBox a))]) : i64
  (begin
    (set! slot.value v)
    (arena.destroy-safe! ar)
    (deref slot.value)))

(define (main) : i64
  0)