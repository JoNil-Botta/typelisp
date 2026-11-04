;; #9604: a brand the call invalidates ends inside the call, so it stays inside
;; the parameters: its data cannot be stored where a parameter's storage
;; outlives it.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

; Must fail: `slot` would read `v` after `ar` is destroyed.
(define (f
  [a : i64]
  [ar : (arena.Arena r) (:invalidate r)]
  [v : (& r i64)]
  [slot : (&mut a (RefBox a))]) : i64
  (begin
    (set! slot.value v)
    (arena.destroy-safe! ar)
    (deref slot.value)))

(define (main) : i64
  0)