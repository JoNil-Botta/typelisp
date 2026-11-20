;; a small callee that loads, stores and returns the old value is inlined.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (bump [p : (MutPtr i64)]) : i64
  (let
    [old : i64
      (unsafe
        (ptr-read p))]
    (unsafe
      (ptr-write! p 5))
    old))

(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64 (bump p)]
    (+ a (- 6 v))))