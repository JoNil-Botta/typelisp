;; The first pointer store supplies the direct read between the two stores.
;; Expected exit 1 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 0]
    [p
      (unsafe
        (ptr-addr-of v))]
    (unsafe
      (ptr-write! (ptr-offset p 0) 1))
    (let
      [x (+ v 0)]
      (unsafe
        (ptr-write! (ptr-offset p 0) 2))
      x)))