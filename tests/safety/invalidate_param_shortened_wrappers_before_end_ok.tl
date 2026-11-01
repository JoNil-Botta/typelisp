;; Refs #9503/#9508: Box, array, enum and tuple wrappers of a shortened
;; reference read before the end are accepted, as on main.
(import stdlib.arena)

(defenum Opt
  (:lifetimes a)
  (Some (& a i64))
  (None))

(define (boxed [owner : (arena.Arena r) (:invalidate r)] [x : (Box (& r i64))]) : i64
  (let
    [k : i64 0]
    [b : (Box (& k i64)) x]
    [v : i64 (deref (deref b))]
    (arena.destroy-safe! owner)
    v))

(define (array
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (Array (& r i64) 2)]) : i64
  (let
    [k : i64 0]
    [a : (Array (& k i64) 2) x]
    [v : i64 (deref (array-ref a 0))]
    (arena.destroy-safe! owner)
    v))

(define (option [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 0]
    [o : (Opt k) (Opt.Some x)]
    [v : i64
      (match o
        [(Some p) (deref p)]
        [(None) 0])]
    (arena.destroy-safe! owner)
    v))

(define (tupled [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 0]
    [t : (Tuple (& k i64) i64) (tuple x 1)]
    [v : i64 (deref (tuple-ref t 0))]
    (arena.destroy-safe! owner)
    v))

(define (main) : i64
  0)