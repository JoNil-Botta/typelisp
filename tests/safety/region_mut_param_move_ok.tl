;; Refs #9536: a region tag over a mutable reference is the reference itself, so
;; moving it into an annotated local or passing it to a helper before the end
;; is accepted, as for an ordinary `(&mut r T)` parameter.
(import stdlib.arena)

(defstruct Counter
  (n i64))

(define (bump [c : (&mut a Counter)]) : i64
  (set! c.n (+ c.n 1))
  c.n)

(define (moved
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (in r (&mut r i64))]) : i64
  (let
    [alias : (&mut r i64) x]
    [read : i64 (deref alias)]
    (arena.destroy-safe! owner)
    read))

(define (helper
  [owner : (arena.Arena r) (:invalidate r)]
  [c : (in r (&mut r Counter))]) : i64
  (let
    [read : i64 (bump c)]
    (arena.destroy-safe! owner)
    read))

(define (main) : i64
  0)