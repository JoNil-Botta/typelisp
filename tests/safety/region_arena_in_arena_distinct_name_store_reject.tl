;; Control for `region_arena_in_arena_caller_lifetime_store_reject`: the same
;; store from an inner arena whose name does not collide keeps its ordinary
;; field type mismatch (#9593).
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [home : (arena.Arena r)] [b : (&mut r (RefBox r))]) : unit
  (in-arena
    home
    (with-arena
      q
      (let
        [x : (Box i64) (box 5)]
        ; Must fail: `(& q i64)` is not `(& r i64)`.
        (set! b.value (& (deref x)))))))

(define (main) : i64
  0)