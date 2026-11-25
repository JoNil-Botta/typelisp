(import stdlib.io)

;; FORCING TEST for the register-homed divisor. Integer Newton square roots
;; divide by a loop-carried estimate that already lives in a register; idiv
;; takes it as its operand directly instead of copying it into a scratch first
;; (which, with every scratch busy, saves and restores a live register around
;; each division). Several running sums keep the callee-saved bank occupied.
(define (isqrt [x : i64]) : i64
  (if (<= x 1)
    x
    (let
      [r : i64 x]
      [next : i64 (/ (+ r (/ x r)) 2)]
      (while (< next r)
        (set! r next)
        (set! next (/ (+ r (/ x r)) 2)))
      r)))

(define (mix [n : i64] [seed : i64]) : i64
  (let
    [a : i64 0]
    [b : i64 seed]
    [c : i64 1]
    [d : i64 3]
    [e : i64 5]
    [i : i64 1]
    (while (<= i n)
      (let
        [s : i64 (isqrt (+ (* i i) seed))]
        (set! a (+ a s))
        (set! b (bit-xor b (* s 31)))
        (set! c (+ c (/ (* i 7) (+ s 1))))
        (set! d (+ d (% (+ b i) (+ s 2))))
        (set! e (+ e (/ (+ a c) (+ d 1)))))
      (set! i (+ i 1)))
    (+ (% (+ a b c d e) 1000) 0)))

(define (main) : i64
  (let
    [v : i64 (mix 200 17)]
    (io.println "{}" v)
    (if (> v -1)
      42
      1)))