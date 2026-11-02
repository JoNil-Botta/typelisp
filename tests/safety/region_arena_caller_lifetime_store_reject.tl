;; A `with-arena` region is a fresh binder: spelled like the caller lifetime
;; of a `&mut` parameter, it still names the arena, so a borrow of arena data
;; stored into the caller's struct outlives the arena (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      ; Must fail: the arena `r` resets before the caller reads `b.value`.
      (set! b.value (& (deref x))))))

(define (main) : i64
  0)