;; Refs #9508: a shortened callable result read before the end (C58 p3).
(import stdlib.arena)

(define (id [p : (& a i64)]) : (& a i64)
  p)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r i64)]
  [f : (-> (& a i64) (& a i64))]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64) (f x)]
    [v : i64 (deref alias)]
    (begin
      (arena.destroy-safe! owner)
      v)))

(define (main) : i64
  (let
    [seed : i64 41]
    [owner (arena.make)]
    [b (in-arena owner (box seed))]
    (exercise owner (& (deref b)) id)))
