(import stdlib.io)

;; Correctness twin for MULTI-EXIT loop rotation (LCSSA-style exit placement).
;;
;; Rotation duplicates the header's exit test into the latch and moves the
;; header phis into the body block. A loop with a SECOND exit -- one that
;; leaves through a body block rather than the header's exit arm -- then has
;; two live-out edges served by two different definitions: the header's exit
;; edge by a fresh phi minted at the exit block, the body's own exit edge by
;; the moved phi itself. Getting either edge wrong is silent: the loop still
;; terminates and still returns a plausible number.
;;
;; Every function below leaves its loop by BOTH doors on some input, and each
;; one is checked on a value that differs between the doors, so a value taken
;; from the wrong edge changes the checksum.
;;
;; `scan-limit`: the counter is read past both exits. Door A is the counter
;; test (i reaches n); door B is the sentinel hit inside the body. The counter
;; at door A is n; at door B it is the sentinel's index. Reading the exit
;; phi on the escape edge would report n on every input.
;;
;; `scan-pair`: the SAME shape, but the value read past the loop is live only
;; on ONE exit path -- `last` is meaningful only when the sentinel was hit, and
;; the counter-exhausted door reports the seed. This is the case where the two
;; edges carry genuinely different definitions rather than two copies of one.
;;
;; `scan-nested`: a multi-exit loop inside another loop, so the rotation runs
;; on a body whose exit blocks are themselves inside a loop and the merged
;; values feed the outer back edge.
;;
;; Never-taken self-recursions keep these out of the inliner, so the loops are
;; rotated in the shape SSA construction hands them over rather than in some
;; merged body.
(define (scan-limit
  [xs : (& xs (__tl_dyn-array i64))]
  [n : i64]
  [sentinel : i64]) : i64
  (if (< n (- 0 1))
    (scan-limit xs (+ n 1) sentinel)
    (let
      [i : i64 0]
      [hit : bool false]
      (begin
        (while (and (< i n) (not hit))
          (if (= (array-ref xs i) sentinel)
            (set! hit true)
            (set! i (+ i 1))))
        ;; `i` is read on BOTH exit edges: n on the counter door, the
        ;; sentinel's index on the escape door.
        i))))

(define (scan-pair
  [xs : (& xs (__tl_dyn-array i64))]
  [n : i64]
  [sentinel : i64]) : i64
  (if (< n (- 0 1))
    (scan-pair xs (+ n 1) sentinel)
    (let
      [i : i64 0]
      [last : i64 (- 0 7)]
      [hit : bool false]
      (begin
        (while (and (< i n) (not hit))
          (begin
            (set! last (array-ref xs i))
            (if (= last sentinel)
              (set! hit true)
              (set! i (+ i 1)))))
        ;; `last` is only meaningful on the escape door; the counter door
        ;; reports the last element scanned, or the seed for an empty range.
        (+ (* i 100) last)))))

(define (scan-nested
  [xs : (& xs (__tl_dyn-array i64))]
  [n : i64]
  [rounds : i64]) : i64
  (if (< rounds (- 0 1))
    (scan-nested xs n (+ rounds 1))
    (let
      [r : i64 0]
      [acc : i64 0]
      (begin
        (while (< r rounds)
          (let
            [i : i64 0]
            [hit : bool false]
            (begin
              (while (and (< i n) (not hit))
                (if (= (array-ref xs i) r)
                  (set! hit true)
                  (set! i (+ i 1))))
              (set! acc (+ acc i))
              (set! r (+ r 1)))))
        acc))))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 5)]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [i : i64 0]
    (begin
      ;; xs = [0, 3, 6, 9, 12, 15] for n = 6 (no args).
      (while (< i n)
        (begin
          (set! (array-ref xs i) (* i 3))
          (set! i (+ i 1))))
      (let
        ;; escape door: xs[2] = 6, so i stops at 2.
        [a : i64 (scan-limit (& xs) n 6)]
        ;; counter door: 7 is absent, so i runs to n = 6.
        [b : i64 (scan-limit (& xs) n 7)]
        ;; empty range: neither door runs a trip, i stays 0.
        [c : i64 (scan-limit (& xs) 0 6)]
        ;; escape door: stops at index 1 with last = 3 -> 1*100 + 3 = 103.
        [d : i64 (scan-pair (& xs) n 3)]
        ;; counter door: last is xs[5] = 15 -> 6*100 + 15 = 615.
        [e : i64 (scan-pair (& xs) n 7)]
        ;; empty range: the seed survives -> 0*100 + -7 = -7.
        [f : i64 (scan-pair (& xs) 0 3)]
        ;; rounds 0,1,2: r=0 hits at index 0, r=1 misses (i=6),
        ;; r=2 misses (i=6) -> 0 + 6 + 6 = 12.
        [g : i64 (scan-nested (& xs) n 3)]
        (if (and
          (= a 2)
          (= b 6)
          (= c 0)
          (= d 103)
          (= e 615)
          (= f (- 0 7))
          (= g 12))
          42
          1)))))