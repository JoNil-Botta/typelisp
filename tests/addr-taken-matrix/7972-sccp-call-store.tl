;; #7972: SCCP folded a read of an address-taken local to its initializer after a
;; call wrote through the address. Expected exit 42 (opt2 exited 2).
(define (write-seven [p : (MutPtr i64)] [n : i64]) : i32
  (if (> n 0)
    (write-seven p (- n 1))
    (begin
      (unsafe
        (ptr-write! p 7))
      (cast 1 : i32))))

(define (measure [n : i64]) : i64
  (let
    [frequency : i64 0]
    [status : i32
      (write-seven
        (unsafe
          (ptr-addr-of frequency))
        n)]
    (if (= status (cast 0 : i32))
      1
      (if (<= frequency 0)
        2
        (+ 35 frequency)))))

(define (main) : i64
  (measure 3))