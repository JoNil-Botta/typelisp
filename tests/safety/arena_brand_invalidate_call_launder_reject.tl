;; #9612: a brand the call invalidates may end before any local of the body,
;; and its destroy reaches only values typed with it, so its data cannot be
;; held under another lifetime.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (pick [a : (& q i64)] [b : (& q i64)]) : (& q i64)
  a)

; Must fail: the call would type `v` with the lifetime of `y`.
(define (f [ar : (arena.Arena r) (:invalidate r)] [v : (& r i64)]) : i64
  (let
    [y : i64 1]
    [w (pick v (& y))]
    (begin
      (release ar)
      (deref w))))

(define (main) : i64
  0)