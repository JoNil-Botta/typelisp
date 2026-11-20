;; a load through &v whose result is used only after a store through &v.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [v : i64 5]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [r : i64
      (if (= (io.arg-count) 1)
        (unsafe
          (ptr-read p))
        0)]
    (unsafe
      (ptr-write! p 9))
    (+ 37 r)))