(import "stdlib/io.tl")
(import stdlib.array)

;; FORCING TEST for M-C part 1: same-value coalescing of copies OF mutable
;; sources. `sum-loop` is a call-free loop whose `array-ref` bounds check
;; materializes the loop index into a fresh width-64 cast temp every iteration
;; (`t = Cast i : u64` feeding IrInstrBoundsCheck). Under the old contract the
;; temp never coalesced with the (phi-defined / multi-def) index, so the loop
;; body carried a `movq <i-reg>, <t-reg>` per iteration; under the new contract
;; the temp merges into the index's class (the index has no def inside the
;; temp's live range) and the copy is elided as a same-register self-move.
;; The runtime check guards reconstruction (a mis-coalesce that lets the
;; increment clobber the checked index, or the checked index clobber the
;; carried value, produces a wrong sum or an OOB abort -> not 42);
;; target/idx-copy-gate.sh additionally asserts the asm shape.
(define (sum-loop [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array.array-ref xs i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (+ (arg-count) 5)]
    [xs : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array.array-set! xs i (* i 3))
          (set! i (+ i 1))))
      (let
        [r : i64 (sum-loop xs n)]
        ;; n = 6 (no args): sum = 3*(0+1+2+3+4+5) = 45.
        (if (= r 45)
          42
          1)))))