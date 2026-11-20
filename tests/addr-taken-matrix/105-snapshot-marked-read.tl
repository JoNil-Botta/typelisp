;; Capture a global cell in a marked local. Its direct read must see the first
;; pointer store even after a second store. Expected exit 42.
(define cell : i64
  40)

(define (capture [n : i64]) : i64
  (let
    [v : i64 cell]
    [p
      (unsafe
        (ptr-addr-of v))]
    (unsafe
      (ptr-write! (ptr-offset p 0) (+ n 1)))
    (let
      [x (+ v 0)]
      (unsafe
        (ptr-write! (ptr-offset p 0) (+ n 2)))
      (+ x 1))))

(define (main) : i64
  (capture cell))