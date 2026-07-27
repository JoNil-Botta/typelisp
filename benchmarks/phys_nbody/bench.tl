;# benchmarks/phys_nbody/bench.tl - fixed-point 2D N-body physics workload.
;#
;# Equivalent to benchmarks/phys_nbody/baseline.c. Bodies live in a square world
;# and are integrated with explicit Euler steps. Each round accumulates pairwise
;# softened gravitational accelerations into `ax`/`ay`, integrates velocity and
;# position, reflects bodies off the four walls with branchy clamps, and folds a
;# modular digest of every position and velocity into a rolling accumulator. The
;# body count and round count are runtime arguments, so nothing can be constant
;# folded.
;#
;# All state is i64 fixed point with 20 fractional bits (Q44.20, one unit =
;# 1/1048576). The world is 1024 by 1024 units, softening holds the effective
;# distance at or above 8 units, and the timestep is 1/64. Fixed point is used
;# instead of `f64` because clang's default floating-point contraction fuses
;# multiply-add pairs, which would make the printed digest differ between the
;# two compilers; integer arithmetic wraps modulo 2^64 in both languages and
;# therefore matches exactly. Distances use an integer Newton sqrt with a
;# bit-length seed, a branchy convergence test, and a hard iteration cap,
;# implemented identically on both sides. Results stay in `[0, prime)` so the
;# printed decimal matches the C baseline's `%lld`.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

(define nb-modulus : i64
  1000000007)
(define nb-fp-shift : i64
  20)
(define nb-fp-one : i64
  1048576)

;; 1024.0 in Q44.20: the world is a nb-world by nb-world square.
(define nb-world : i64
  1073741824)

;; 64.0 in Q44.20 of squared softening, so the softened distance is at least 8.
(define nb-soft2 : i64
  67108864)

;; 16384.0 in Q44.20.
(define nb-gravity : i64
  17179869184)

;; 1/64 in Q44.20.
(define nb-dt : i64
  16384)
(define nb-sqrt-iterations : i64
  40)

;; Fixed-point multiply: the raw product wraps modulo 2^64, then an arithmetic
;; shift removes the duplicated fractional bits.
(define (nb-mul [a : i64] [b : i64]) : i64
  (shr (* a b) nb-fp-shift))

;; Fixed-point divide. Callers guarantee a non-zero divisor.
(define (nb-div [a : i64] [b : i64]) : i64
  (/ (shl a nb-fp-shift) b))

;; Integer floor-sqrt by Newton iteration from a bit-length seed. The seed is a
;; power of two at or above sqrt(n), so the iterates decrease monotonically and
;; the first non-decreasing step is the floor.
(define (nb-isqrt [n : i64]) : i64
  (if (<= n 0)
    0
    (let
      [bits : i64 0]
      [probe : i64 n]
      (begin
        (while (> probe 0)
          (begin
            (set! probe (shr probe 1))
            (set! bits (+ bits 1))))
        (let
          [guess : i64 (shl 1 (/ (+ bits 1) 2))]
          [iteration : i64 0]
          [settled : bool false]
          (begin
            (while (and (< iteration nb-sqrt-iterations) (not settled))
              (let
                [next : i64 (/ (+ guess (/ n guess)) 2)]
                (begin
                  (if (>= next guess)
                    (set! settled true)
                    (set! guess next))
                  (set! iteration (+ iteration 1)))))
            guess))))))

;; Fixed-point sqrt: sqrt(v / 2^20) * 2^20 is floor-sqrt of (v << 20).
(define (nb-sqrt [value : i64]) : i64
  (nb-isqrt (shl value nb-fp-shift)))

;; 64-bit LCG. The state advances over the full word and every drawn value comes
;; from the high bits, whose period is much longer than the low bits'.
(define (nb-next-state [state : i64]) : i64
  (+ (* state 6364136223846793005) 1442695040888963407))

(define (nb-draw [state : i64]) : i64
  (bit-and (shr state 33) 2147483647))

(define (nb-seed
  [px : (Array i64)]
  [py : (Array i64)]
  [vx : (Array i64)]
  [vy : (Array i64)]
  [mass : (Array i64)]
  [n : i64]
  [seed : i64]) : i64
  (let
    [i : i64 0]
    [state : i64 seed]
    (begin
      (while (< i n)
        (begin
          (set! state (nb-next-state state))
          (array-set! px i (% (nb-draw state) nb-world))
          (set! state (nb-next-state state))
          (array-set! py i (% (nb-draw state) nb-world))
          (set! state (nb-next-state state))
          (array-set! vx i (- (% (nb-draw state) 16777216) 8388608))
          (set! state (nb-next-state state))
          (array-set! vy i (- (% (nb-draw state) 16777216) 8388608))
          (set! state (nb-next-state state))
          (array-set! mass i (+ nb-fp-one (% (nb-draw state) 8388608)))
          (set! i (+ i 1))))
      state)))

(define (nb-forces
  [px : (Array i64)]
  [py : (Array i64)]
  [mass : (Array i64)]
  [ax : (Array i64)]
  [ay : (Array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [sum-x : i64 0]
          [sum-y : i64 0]
          [j : i64 0]
          (begin
            (while (< j n)
              (begin
                (when
                  (!= j i)
                  (let
                    [dx : i64 (- (array-ref px j) (array-ref px i))]
                    [dy : i64 (- (array-ref py j) (array-ref py i))]
                    [d2 : i64 (+ (nb-mul dx dx) (nb-mul dy dy) nb-soft2)]
                    [dist : i64 (nb-sqrt d2)]
                    [unit-x : i64 (nb-div dx dist)]
                    [unit-y : i64 (nb-div dy dist)]
                    [pull : i64
                      (nb-div (nb-mul nb-gravity (array-ref mass j)) d2)]
                    (begin
                      (set! sum-x (+ sum-x (nb-mul pull unit-x)))
                      (set! sum-y (+ sum-y (nb-mul pull unit-y))))))
                (set! j (+ j 1))))
            (array-set! ax i sum-x)
            (array-set! ay i sum-y)
            (set! i (+ i 1)))))
      unit)))

(define (nb-integrate
  [px : (Array i64)]
  [py : (Array i64)]
  [vx : (Array i64)]
  [vy : (Array i64)]
  [ax : (Array i64)]
  [ay : (Array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [nvx : i64 (+ (array-ref vx i) (nb-mul (array-ref ax i) nb-dt))]
          [nvy : i64 (+ (array-ref vy i) (nb-mul (array-ref ay i) nb-dt))]
          [npx : i64 (+ (array-ref px i) (nb-mul nvx nb-dt))]
          [npy : i64 (+ (array-ref py i) (nb-mul nvy nb-dt))]
          (begin
            (when
              (< npx 0)
              (begin
                (set! npx (neg npx))
                (set! nvx (neg nvx))))
            (when
              (> npx nb-world)
              (begin
                (set! npx (- (* 2 nb-world) npx))
                (set! nvx (neg nvx))))
            (when (< npx 0) (set! npx 0))
            (when (> npx nb-world) (set! npx nb-world))
            (when
              (< npy 0)
              (begin
                (set! npy (neg npy))
                (set! nvy (neg nvy))))
            (when
              (> npy nb-world)
              (begin
                (set! npy (- (* 2 nb-world) npy))
                (set! nvy (neg nvy))))
            (when (< npy 0) (set! npy 0))
            (when (> npy nb-world) (set! npy nb-world))
            (array-set! vx i nvx)
            (array-set! vy i nvy)
            (array-set! px i npx)
            (array-set! py i npy)
            (set! i (+ i 1)))))
      unit)))

;; Velocities are signed, so the remainder is normalized into [0, prime).
(define (nb-fold [value : i64]) : i64
  (% (+ (% value nb-modulus) nb-modulus) nb-modulus))

(define (nb-checksum
  [px : (Array i64)]
  [py : (Array i64)]
  [vx : (Array i64)]
  [vy : (Array i64)]
  [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! sum (% (+ sum (nb-fold (array-ref px i))) nb-modulus))
          (set! sum (% (+ sum (nb-fold (array-ref py i))) nb-modulus))
          (set! sum (% (+ sum (nb-fold (array-ref vx i))) nb-modulus))
          (set! sum (% (+ sum (nb-fold (array-ref vy i))) nb-modulus))
          (set! i (+ i 1))))
      sum)))

(define (nb-bench [n : i64] [rounds : i64]) : i64
  (let
    [px : (Array i64) (array.make-array i64 n)]
    [py : (Array i64) (array.make-array i64 n)]
    [vx : (Array i64) (array.make-array i64 n)]
    [vy : (Array i64) (array.make-array i64 n)]
    [ax : (Array i64) (array.make-array i64 n)]
    [ay : (Array i64) (array.make-array i64 n)]
    [mass : (Array i64) (array.make-array i64 n)]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (nb-seed px py vx vy mass n 1)
      (while (< round rounds)
        (begin
          (nb-forces px py mass ax ay n)
          (nb-integrate px py vx vy ax ay n)
          (set! acc (% (+ (* acc 31) (nb-checksum px py vx vy n)) nb-modulus))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (nb-bench n rounds))
      0)))