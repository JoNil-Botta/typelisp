(import stdlib.io)
(import stdlib.array)

;; FORCING TEST for M-E: loop-invariant descriptor-load hoisting.
;;
;; `sum-loop` is the canonical bounds-checked array-sum: every iteration reads
;; the array descriptor's len (fat offset 8, feeding IrInstrBoundsCheck) and
;; data pointer (fat offset 0, feeding the element load). Before M-E the
;; natural-loop body collection mishandled self-loops (latch == header), so
;; rotated single-block loops never got a preheader and memory-LICM was inert:
;; both descriptor fields were re-loaded every iteration. After M-E the len and
;; data-pointer loads live in the synthesized `while_body.1__preheader` and the
;; loop body carries exactly one memory read (the element) plus the bounds
;; compare on a register.
;;
;; The runtime check guards reconstruction (a wrong hoist that reads a stale
;; or unrelated descriptor field produces a wrong sum or an OOB abort -> not
;; 42); target/licm-hoist-gate.sh additionally asserts the asm shape (no
;; descriptor-field load inside the loop body).
(define (sum-loop [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array.ref xs i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 7)]
    [xs : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (* i 5))
          (set! i (+ i 1))))
      (let
        [r : i64 (sum-loop xs n)]
        ;; n = 8 (no args): sum = 5*(0+1+...+7) = 140.
        (if (= r 140)
          42
          1)))))