;; #8785 case 3: `cmp_dup` re-read the local after the store and got its entry
;; value. Expected exit 42 (opt2 exited 1).
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