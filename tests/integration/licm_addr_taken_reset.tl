;; LICM and an address-taken local that the loop itself writes (#7974). The
;; loop resets the local every iteration and a call then bumps it through its
;; address, so the reset must stay in the loop. Exits 42 (18 + 8 + 8 + 8);
;; keeping the reset out of the loop would give 18 + 8 + 9 + 10.
;; Adds one through `p` and returns the new value.
(define (bump [p : (MutPtr i64)]) : i64
  (unsafe
    (begin
      (ptr-write! p (+ (ptr-read p) 1))
      (ptr-read p))))

;; The loop resets the local every iteration and the call then bumps it
;; through its address: each iteration sees 8 (8 + 8 + 8). Keeping the reset
;; out of the loop would give 8 + 9 + 10.
(define (reset-before-call [seed : i64]) : i64
  (let
    [value : i64 seed]
    [sum : i64 0]
    [i : i64 0]
    (begin
      (while (< i 3)
        (begin
          (set! value 7)
          (set!
            sum
            (+
              sum
              (bump
                (unsafe
                  (ptr-addr-of value)))))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (+ 18 (reset-before-call 0)))