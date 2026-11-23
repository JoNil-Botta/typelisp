;; Implicit-cleanup arena escape: `with` binding using a struct `:cleanup`
;; disposer inside `with-arena` stores an allocation through a `&mut` field.
(define (leak-mut [dst : (&mut s (Box i64))]) : unit
  (set! (deref dst) (box (cast 42 : i64))))

(defstruct MutGuard
  (:lifetimes s)
  (:cleanup close-mut-guard)
  (slot (&mut s (Box i64)) (:cleanup leak-mut)))

(define (work [dst : (&mut s (Box i64))]) : i64
  (with-arena r (with ([g (MutGuard dst) close-mut-guard]) 0)))

(define (main) : i64
  (let
    [outer : (Box i64) (box (cast 1 : i64))]
    (work (&mut outer))
    (deref outer)))