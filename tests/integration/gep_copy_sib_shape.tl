(import stdlib.array)

;; FORCING TEST for the gep-element copy addressing fold.
;;
;; Both functions below copy a whole 32-byte struct to or from a dynamically
;; indexed array element, which lowers to `Gep` + `CopyBytes`. Before the fold
;; the element address was COMPOSED into a register and every 16-byte chunk
;; addressed it indirectly:
;;     shlq $5, %rIDX
;;     leaq (%rBASE,%rIDX,1), %rADDR
;;     movups (%rADDR), %xmm2
;;     movups %xmm2, (%rDST)
;;     movups 16(%rADDR), %xmm2
;;     movups %xmm2, 16(%rDST)
;; base and index are register-homed under a SIB scale, so the address register
;; is unnecessary -- each chunk spells the element operand itself and the `leaq`
;; disappears:
;;     shlq $5, %rIDX
;;     movups (%rBASE,%rIDX,1), %xmm2
;;     movups %xmm2, (%rDST)
;;     movups 16(%rBASE,%rIDX,1), %xmm2
;;     movups %xmm2, 16(%rDST)
;; `take` exercises the element-as-SOURCE side and `put` the element-as-
;; DESTINATION side; scripts/verify-asm-shape-gates.sh asserts both shapes.
;;
;; `take-const` is the CONSTANT-index sibling of `take`. There is no index
;; register at all: the element address is `disp(base)` with the whole element
;; offset (3 * 32 = 96) in the displacement, so the same chunk fold applies with
;; no SIB operand:
;;     movups 96(%rBASE), %xmm2
;;     movups %xmm2, (%rDST)
;;     movups 112(%rBASE), %xmm2
;;     movups %xmm2, 16(%rDST)
;; It is a forcing test for the constant-offset admission, which is decided from
;; a static bound on `n * scale` rather than from the GAP9 displacement entry.
;;
;; The never-taken self-recursion blocks inlining, which would otherwise fold
;; the index to a constant and remove the dynamic gep the gate is about. The
;; runtime body round-trips every field through both directions, so a wrong
;; chunk address, a clobbered base/index register, or a mis-biased displacement
;; produces a wrong sum rather than a silently different shape.
(defstruct Quad
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define (take [xs : (& xs (__tl_dyn-array Quad))] [i : i64]) : Quad
  (if (> i 1000000)
    (take xs (- i 1000000))
    (array-ref xs i)))

(define (put [xs : (&mut xs (__tl_dyn-array Quad))] [i : i64] [v : Quad]) : unit
  (if (> i 1000000)
    (put xs (- i 1000000) v)
    (set! (array-ref xs i) v)))

(define (take-const [xs : (& xs (__tl_dyn-array Quad))] [i : i64]) : Quad
  (if (> i 1000000)
    (take-const xs (- i 1000000))
    (array-ref xs 3)))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array Quad) (array.make-array Quad 8)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i 8)
        (begin
          (put (&mut xs) i (Quad (+ i 1) (+ i 2) (+ i 3) (+ i 4)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 8)
        (let
          [q : Quad (take (& xs) i)]
          (begin
            (set! acc (+ acc (+ (+ q.a q.b) (+ q.c q.d))))
            (set! i (+ i 1)))))
      ;; xs[3] is (4, 5, 6, 7), so the constant-index read sums to 22.
      (let
        [q3 : Quad (take-const (& xs) 0)]
        [const-acc : i64 (+ (+ q3.a q3.b) (+ q3.c q3.d))]
        ;; sum over i in 0..7 of (4i + 10) = 4*28 + 80 = 192
        (if (and (= acc 192) (= const-acc 22))
          42
          1)))))