;; #9612: a brand the call invalidates may end before any local of the body,
;; and its destroy reaches only values typed with it, so its data cannot be
;; held under another lifetime.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

; Must fail: the store would leave `v` in `bx` after `release`.
(define (f [ar : (arena.Arena r) (:invalidate r)] [v : (& r i64)]) : i64
  (let
    [z : i64 2]
    [y : i64 1]
    [bx : (RefBox y) (RefBox (& z))]
    (begin
      (set! bx.value v)
      (release ar)
      (deref bx.value))))

(define (main) : i64
  0)