;; Refs #9508: a tuple projection keeps the stored brand through a shortening
;; annotation.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r (Tuple (& r i64) i64))]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (tuple-ref (deref x) 0)]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)