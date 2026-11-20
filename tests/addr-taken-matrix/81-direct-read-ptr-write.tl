;; two direct reads of v with a store through &v between them.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64 v]
    (unsafe
      (ptr-write! p 5))
    (let
      [b : i64 v]
      (+ a b))))