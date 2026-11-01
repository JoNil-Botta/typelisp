;; Refs #9508: an enum constructed from a reference keeps its stored brand.
(import stdlib.arena)

(defenum Opt
  (:lifetimes a)
  (Some (& a i64))
  (None))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 0]
    [o : (Opt k) (Opt.Some x)]
    (arena.destroy-safe! owner)
    (match o
      [(Some p) (deref p)]
      [(None) 0])))

(define (main) : i64
  0)
