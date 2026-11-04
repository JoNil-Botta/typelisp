;; #9612: a brand the call invalidates may end before any local of the body,
;; and its destroy reaches only values typed with it, so its data cannot be
;; held under another lifetime.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

; Must fail: a lambda value cannot hold `v` under the lifetime of `y` either.
(define (f [ar : (arena.Arena r) (:invalidate r)] [v : (& r i64)]) : i64
  (let
    [y : i64 1]
    [g
      (lambda () : (RefBox y)
        (RefBox v))]
    [bx (g)]
    (begin
      (release ar)
      (deref bx.value))))

(define (main) : i64
  0)