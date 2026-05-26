;;;; benchmarks/string_scan/bench.tl - string-scan micro-benchmark (#1098).
;;;;
;;;; Equivalent to benchmarks/string_scan/baseline.c. Both walk a fixed ASCII
;;;; string `rounds` times, folding every byte into a polynomial rolling hash
;;;; (`acc = acc * 131 + byte`) over a wrapping 64-bit accumulator, and return
;;;; the low byte as the process exit code. TypeLisp `+`/`*` wrap modulo 2^64
;;;; (SPEC), matching C `uint64_t`, and the text is pure ASCII so each byte is a
;;;; small non-negative code that matches C `(unsigned char)`; both programs
;;;; therefore produce the identical exit code on a given host.
;;;;
;;;; The round count is `base-rounds + (arg-count)` (`arg-count` is 1 with no
;;;; extra arguments, matching C `argc`), so the trip count is not a compile-time
;;;; constant. The hash accumulator is carried across rounds, so the per-round
;;;; scan is not loop-invariant and cannot be folded into a closed form.
(define scan-text : String
  "the quick brown fox jumps over the lazy dog 0123456789")

(define base-rounds : i64
  25000000)

(define (scan-once [text : String] [n : i64] [acc : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ (* acc 131) (cast (string-ref text i) : i64)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string-length scan-text)]
    [rounds : i64 (+ base-rounds (arg-count))]
    [acc : i64 1]
    [r : i64 0]
    (begin
      (while (< r rounds)
        (begin
          (set! acc (scan-once scan-text n acc))
          (set! r (+ r 1))))
      (bit-and acc 255))))