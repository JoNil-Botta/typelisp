(import stdlib.io)

;; REGRESSION for #5982: the strength-reduced remainder must not be computed
;; into a register that is still carrying a live value.
;;
;; The clang-shaped constant remainder ends `subq product, SRC`, so SRC is
;; WRITTEN. The emitter is allowed to elect the dividend's own home as SRC, and
;; it used to justify that with "this VALUE is dead after here" alone. In a loop
;; whose carried state is REASSIGNED and then immediately reduced, that fact is
;; true of the definition while the register is still the home the next
;; iteration reads from: the definition's interval ends at the `%`, but the
;; home is shared with the header phi that reads it back. The `subq` then
;; overwrote the induction state with the remainder, and every iteration after
;; the first stepped from the wrong value.
;;
;; `walk` reproduces exactly that shape: `state` is reassigned, immediately
;; reduced by a constant, the remainder is consumed by something OTHER than
;; `state`, and `state` itself is carried to the next iteration. Both a
;; power-of-two divisor (mask/shift expansion) and a non-power-of-two divisor
;; (magic-multiply expansion) reach the `subq product, SRC` tail, so the fixture
;; covers both remainder lowerings. Pre-fix this returns a corrupted `acc`
;; (opt2 only; opt0/opt1 keep the reference values), so the exit code is a
;; forcing check.
(define (walk [n : i64] [seed : i64]) : i64
  (let
    [state : i64 seed]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
          (set! acc (+ acc (% state 1073741824)))
          (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
          (set! acc (+ acc (% state 7340032)))
          (set! i (+ i 1))))
      (+ acc state))))

;; The same shape with the remainder feeding a store rather than an add: the
;; fused divmod+store bundle picks its SRC through a second selector, so it
;; needs its own coverage.
(define (walk-store [out : (Array i64)] [n : i64] [seed : i64]) : i64
  (let
    [state : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
          (array-set! out i (% state 16777216))
          (set! i (+ i 1))))
      state)))

(define (main) : i64
  (let
    ;; n = 8 when run without args (io.arg-count = 1); the runtime value keeps
    ;; both loops out of the constant folder.
    [n : i64 (+ 7 (io.arg-count))]
    [w : i64 (walk n 1)]
    [out : (Array i64) (make-array i64 8)]
    [s : i64 (walk-store out n 1)]
    [t : i64 (+ (array-ref out 0) (+ (array-ref out 4) (array-ref out 7)))]
    ;; One bit per reference value, so a failing exit code names which shape
    ;; regressed: 1 = walk's carried state, 2 = walk-store's, 4 = the stored
    ;; remainders themselves.
    [bad : i64
      (+
        (if (= w 6144348233)
          0
          1)
        (+
          (if (= s 486256185)
            0
            2)
          (if (= t 34475025)
            0
            4)))]
    (if (= bad 0)
      42
      bad)))