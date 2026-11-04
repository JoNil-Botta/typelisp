;; #9604: an invalidated self-named arena owner's brand also ends inside the
;; call.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

; Must fail: `slot` would read `v` after `owner` is destroyed.
(define (f
  [a : i64]
  [owner : (arena.Arena owner) (:invalidate owner)]
  [v : (& owner i64)]
  [slot : (&mut a (RefBox a))]) : i64
  (begin
    (set! slot.value v)
    (arena.destroy-safe! owner)
    (deref slot.value)))

(define (main) : i64
  0)