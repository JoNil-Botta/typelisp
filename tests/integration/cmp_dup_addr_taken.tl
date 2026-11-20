;; The store through `p` changes `x`, so cmp_dup may not re-read `x` for `b`
;; at its use: it got the value `a` read before the store (#8785). Exits 42;
;; opt2 exited 1.
(define (write-99 [p : (MutPtr i64)]) : unit
  (unsafe
    (ptr-write! p 99)))

(define (main) : i64
  (let
    [x : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    [a : bool (= x 99)]
    (write-99 p)
    (let
      [b : bool (= x 99)]
      (if a
        1
        (if b
          42
          2)))))