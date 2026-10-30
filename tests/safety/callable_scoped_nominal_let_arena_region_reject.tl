;; Refs #9098: a let annotated with a nominal that names a `with-arena` region
;; keeps the initializer's inferred `(View r)`, as on main, so destroying the
;; `:invalidate` owner of `r` ends `v` and the later read is rejected. Main's
;; plain-reference case is #9503.
(import stdlib.arena)

(defstruct View
  (:lifetimes a)
  (s (& a i64)))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (with-arena
    s
    (let
      [v : (View s) (View x)]
      (begin
        (arena.destroy-safe! owner)
        (deref v.s)))))

(define (main) : i64
  (let
    [seed : i64 41]
    [owner (arena.make)]
    [b (in-arena owner (box seed))]
    (exercise owner (& (deref b)))))