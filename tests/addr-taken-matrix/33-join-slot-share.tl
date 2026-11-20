;; a join phi and the address-taken local could be given the same frame slot.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [r : i64 0]
    (if (= (io.arg-count) 1)
      (set!
        r
        (unsafe
          (ptr-read p)))
      (set! r 9))
    (set! v 5)
    (+
      36
      (+
        r
        (unsafe
          (ptr-read p))))))