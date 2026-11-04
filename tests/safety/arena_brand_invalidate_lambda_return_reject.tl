;; #9612: a brand the call invalidates may end before any local of the body,
;; and its destroy reaches only values typed with it, so its data cannot be
;; held under another lifetime.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

; Must fail: a nested lambda cannot hand `v` back under the lifetime of `y`.
(define (f [ar : (arena.Arena r) (:invalidate r)] [v : (& r i64)]) : i64
  (let
    [y : i64 1]
    [w
      ((lambda () : (& y i64)
          v))]
    (begin
      (release ar)
      (deref w))))

(define (main) : i64
  (let
    [ar (arena.make)]
    [cell (in-arena ar (box (ann 42 : i64)))]
    (f ar (& (deref cell)))))