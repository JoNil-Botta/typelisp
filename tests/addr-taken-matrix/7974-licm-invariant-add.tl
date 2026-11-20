;; #7974: LICM hoisted an `add` of an address-taken local that the body rewrote
;; through its address. Expected exit 42 (opt2 exited 28).
(define (write-seven [p : (MutPtr i64)] [depth : i64]) : i32
  (if (> depth 0)
    (write-seven p (- depth 1))
    (begin
      (unsafe
        (ptr-write! p 7))
      (cast 1 : i32))))

(define (p-licm [depth : i64] [seed : i64]) : i64
  (let
    [value : i64 seed]
    [sum : i64 0]
    [i : i64 0]
    (begin
      (while (< i 3)
        (begin
          (set! sum (+ sum (+ value 1)))
          (write-seven
            (unsafe
              (ptr-addr-of value))
            depth)
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (+ 25 (p-licm 3 0)))