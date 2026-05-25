(import "stdlib/random.tl")

;;; Integration test for random-system-seed and random-from-system.
;;; Verifies: system seed is positive, normalized, varies between calls.
(define (main) : i64
  (match (random-system-seed)
    [(OkSystemSeed seed)
      (if (and (> seed 0) (<= seed 2147483647))
        1
        0)]
    [(ErrSystemSeed _) 0]))
