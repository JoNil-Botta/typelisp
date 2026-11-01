;; Refs #9503, B1: mutable parameters retain main's move and call path.
(import stdlib.arena)

(defstruct Counter
  (n i64))

(define (bump [c : (&mut a Counter)]) : i64
  (set! c.n (+ c.n 1))
  c.n)

(define (shorten [owner : (arena.Arena r) (:invalidate r)] [x : (&mut r i64)]) : i64
  (let
    [k : i64 0]
    [alias : (&mut k i64) x]
    [read : i64 (deref alias)]
    (arena.destroy-safe! owner)
    read))

(define (same [owner : (arena.Arena r) (:invalidate r)] [x : (&mut r i64)]) : i64
  (let
    [alias : (&mut r i64) x]
    [read : i64 (deref alias)]
    (arena.destroy-safe! owner)
    read))

(define (helper
  [owner : (arena.Arena r) (:invalidate r)]
  [c : (&mut r Counter)]) : i64
  (let
    [read : i64 (bump c)]
    (arena.destroy-safe! owner)
    read))

(define (main) : i64
  (let
    [seed : i64 10]
    [o1 (arena.make)]
    [b1 (in-arena o1 (box seed))]
    [a : i64 (shorten o1 (&mut (deref b1)))]
    [o2 (arena.make)]
    [b2 (in-arena o2 (box seed))]
    [b : i64 (same o2 (&mut (deref b2)))]
    [o3 (arena.make)]
    [b3 (in-arena o3 (box (Counter 21)))]
    (+ (+ a b) (helper o3 (&mut (deref b3))))))