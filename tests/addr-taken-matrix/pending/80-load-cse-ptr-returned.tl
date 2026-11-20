;; Expected exit 6 at --opt-level 0 (opt1 and opt2 exit 2 and 2 until the queued fix lands).
(import stdlib.io)

;; load-CSE: the address is taken once and handed back by a second function.
(define (pick [p : (MutPtr i64)] [q : (MutPtr i64)]) : (MutPtr i64)
  (if (= (io.arg-count) 1)
    p
    q))

(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [q : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [r : (MutPtr i64) (pick p q)]
    [a : i64
      (unsafe
        (ptr-read r))]
    (set! v 5)
    (let
      [b : i64
        (unsafe
          (ptr-read r))]
      (+ a b))))