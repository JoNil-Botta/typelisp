;; #9604: two by-value arena brands are distinct caller regions, so a value
;; allocated in one cannot be returned as the other's.
(import stdlib.arena)
(import stdlib.string)

(define (allocate-from-wrong-owner
  [first : (arena.Arena s)]
  [_second : (arena.Arena t)]) : (in t String)
  (in-arena first (string.append "wrong" "-owner")))

(define (main) : i64
  (allocate-from-wrong-owner (arena.make) (arena.make)))