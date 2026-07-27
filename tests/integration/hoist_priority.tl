(import stdlib.io)

;; FORCING TEST for A36: the const-hoist plan awards a region's free candidate
;; registers by DESCENDING STATIC SITE COUNT, not by program order.
;;
;; Both loops hold more distinct hoistable constants than the candidate list
;; can ever carry (five registers on Linux, three on Win64), so the region is
;; guaranteed to run out of registers no matter what the surrounding pressure
;; is -- the shortage is structural, not an allocator accident.
;;
;;   * `spread` writes SIX single-site wide literals first (`bit-xor` by a
;;     non-imm32 value; the `+ i` between them blocks constant folding, so each
;;     stays a real 64-bit literal operand) and a THREE-site divmod magic last
;;     (`% _ 1000000007` on three accumulators). Pre-A36 the six one-site
;;     literals took every candidate in program order and the three-site magic
;;     got none, re-materialising `movabsq $-8543223828751151131` at all three
;;     sites on every iteration. Post-A36 the magic outweighs them 3:1, is
;;     awarded first, and loads ONCE in the preheader. The gate asserts exactly
;;     one magic `movabsq` in `spread`: 1 post-change, 3 pre-change.
;;
;;   * `tie` gives every key the SAME weight -- five wide literals with two
;;     sites each, then a two-site magic. Equal counts must keep program order,
;;     so the earlier literals win the registers and the trailing magic loses.
;;     The gate asserts the first literal is hoisted (one `movabsq`, the
;;     preheader load) while the magic still materialises at both of its sites.
;;     That pins the tie-break as a total order: an unstable or reversed sort
;;     would promote the magic and drop its count to one.
;;
;; NON-TAIL self-recursion (never taken at rounds = 1) keeps both functions out
;; of the inliner AND out of opt-tailrec, so the gate can assert on the named
;; functions' bodies (divmagic_hoist pattern).
(define (spread [n : i64] [rounds : i64]) : i64
  (let
    [w : i64 7]
    [a : i64 1]
    [b : i64 2]
    [c : i64 3]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! w (+ (bit-xor w 2654435761) i))
          (set! w (+ (bit-xor w 2654435763) i))
          (set! w (+ (bit-xor w 2654435765) i))
          (set! w (+ (bit-xor w 2654435767) i))
          (set! w (+ (bit-xor w 2654435769) i))
          (set! w (+ (bit-xor w 2654435771) i))
          (set! a (% (+ (* a 131) i) 1000000007))
          (set! b (% (+ (* b 977) i) 1000000007))
          (set! c (% (+ (* c 613) i) 1000000007))
          (set! i (+ i 1))))
      (if (> rounds 1)
        (+ w (spread n (- rounds 1)))
        (+ w (+ a (+ b c)))))))

(define (tie [n : i64] [rounds : i64]) : i64
  (let
    [x : i64 5]
    [y : i64 1]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! x (+ (bit-xor x 3141592653589) i))
          (set! y (+ (bit-xor y 3141592653589) i))
          (set! x (+ (bit-xor x 2718281828459) i))
          (set! y (+ (bit-xor y 2718281828459) i))
          (set! x (+ (bit-xor x 1618033988749) i))
          (set! y (+ (bit-xor y 1618033988749) i))
          (set! x (+ (bit-xor x 1414213562373) i))
          (set! y (+ (bit-xor y 1414213562373) i))
          (set! x (+ (bit-xor x 1732050807568) i))
          (set! y (+ (bit-xor y 1732050807568) i))
          (set! x (% (+ (* x 131) i) 1000000007))
          (set! y (% (+ (* y 977) i) 1000000007))
          (set! i (+ i 1))))
      (if (> rounds 1)
        (+ x (tie n (- rounds 1)))
        (+ x y)))))

(define (main) : i64
  (let
    ;; n = 10 when run without args (io.arg-count = 1); the runtime value
    ;; blocks constant folding of both loops.
    [n : i64 (+ 9 (io.arg-count))]
    [s : i64 (spread n 1)]
    [t : i64 (tie n 1)]
    (if (= s 1149750724)
      (if (= t 572330981)
        42
        2)
      1)))