;; #9775 W02: the same for a box allocated in the arena.
(import stdlib.arena)

(define (keep) : (Box i64)
  (with
    ([a (arena.make) arena.destroy-safe!])
    (in-arena a (box (cast 42 : i64)))))

(define (main) : i64
  (let
    [k (keep)]
    (deref k)))