;; #9612: a brand the call invalidates may end before any local of the body,
;; and its destroy reaches only values typed with it, so its data cannot be
;; held under another lifetime.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

; Must fail: a self-named invalidated owner's brand ends inside the call too.
(define (f
  [owner : (arena.Arena owner) (:invalidate owner)]
  [v : (& owner i64)]) : i64
  (let
    [y : i64 1]
    [bx : (RefBox y) (RefBox v)]
    (begin
      (release owner)
      (deref bx.value))))

(define (main) : i64
  0)