;; dead set! with the intervening pointer read inside a callee.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (readp [p : (MutPtr i64)]) : i64
  (unsafe
    (ptr-read p)))

(define (main) : i64
  (let
    [v : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    (set! v 41)
    (let
      [a : i64 (readp p)]
      (set! v 7)
      (+ a 1))))