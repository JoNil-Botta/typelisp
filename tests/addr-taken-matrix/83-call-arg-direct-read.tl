;; v is read directly as a call argument after a set!, following a pointer load.
;; Expected exit 11 at --opt-level 0, 1 and 2.
(define (double [x : i64]) : i64
  (* x 2))

(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (set! v 5)
    (+ a (double v))))