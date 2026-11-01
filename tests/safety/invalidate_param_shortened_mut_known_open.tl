;; KNOWN OPEN (#9503): mutable-reference parameters keep main's binding path.
;; Current unsafe behaviour only; never execute the ended-storage read.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (&mut r i64)]) : i64
  (let
    [k : i64 0]
    [alias : (&mut k i64) x]
    (arena.destroy-safe! owner)
    (deref alias)))

(define (main) : i64
  0)