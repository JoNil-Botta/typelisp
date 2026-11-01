;; KNOWN OPEN, pre-existing and unsafe (accepted; reads destroyed storage at run
;; time): tracked in #9503. Only reference parameters carry the arena region of
;; an invalidated brand, so a tuple parameter shortened as a whole to a
;; body-local lifetime no longer names the brand, as on main. This row records
;; current behaviour, not correctness, and must flip to check-fail when tuple
;; parameters keep provenance (D-C47 I2).
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (Tuple (& r i64) i64)]) : i64
  (let
    [k : i64 5]
    (let
      [t : (Tuple (& k i64) i64) x]
      (begin
        (arena.destroy-safe! owner)
        (deref (tuple-ref t 0))))))

(define (main) : i64
  0)