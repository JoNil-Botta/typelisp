;; A store through `p` changes `x`, so gvn may not number the compare of `x`
;; after the call the same as the one before it (#8785). Exits 42; opt2
;; exited 2.
(define (write-99 [p : (MutPtr i64)]) : unit
  (unsafe
    (ptr-write! p 99)))

(define (main) : i64
  (let
    [x : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (if (= x 1)
      (begin
        (write-99 p)
        (if (= x 1)
          2
          42))
      1)))