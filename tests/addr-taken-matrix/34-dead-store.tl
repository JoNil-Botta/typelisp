;; a set! overwritten by a second set!, with a pointer read in between.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    (set! v 41)
    (let
      [a : i64
        (+
          (unsafe
            (ptr-read p))
          (- v v))]
      (set! v 7)
      (+ a 1))))