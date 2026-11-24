;; Implicit-cleanup arena escape: `with` cleanup inside `with-arena` stores
;; an active-arena allocation through a `&mut` argument outliving the arena.
(define (leak-mut [dst : (&mut dst (Box i64))]) : unit
  (set! (deref dst) (box (cast 42 : i64))))

(define (work [dst : (&mut dst (Box i64))]) : i64
  (with-arena r (with ([slot dst leak-mut]) 0)))

(define (main) : i64
  (let
    [outer : (Box i64) (box (cast 1 : i64))]
    (work (&mut outer))
    (deref outer)))