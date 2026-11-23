;; Implicit-cleanup arena escape: borrowed temporary struct `:cleanup` runs
;; inside `with-arena` and stores an active-arena allocation through a `&mut`
;; field outliving the arena.
(define (leak-mut [dst : (&mut s (Box i64))]) : unit
  (set! (deref dst) (box (cast 42 : i64))))

(defstruct MutGuard
  (:lifetimes s)
  (:cleanup close-mut-guard)
  (slot (&mut s (Box i64)) (:cleanup leak-mut)))

(define (touch [_x : (& r (MutGuard s))]) : i64
  1)

(define (work [dst : (&mut s (Box i64))]) : i64
  (with-arena r (touch (& (MutGuard dst)))))

(define (main) : i64
  (let
    [outer : (Box i64) (box (cast 1 : i64))]
    (work (&mut outer))
    (deref outer)))