;; copy of v taken before set!, compared with *p after it.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [c : i64 v]
    (set! v 5)
    (if (=
      c
      (unsafe
        (ptr-read p)))
      7
      40)))