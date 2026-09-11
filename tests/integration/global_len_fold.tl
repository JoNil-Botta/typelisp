;; FORCING TEST for BE-3 (the bounds-check length read through the handle's
;; staging register, and the data word behind it).
;;
;; A checked read of a global array inside a loop that also calls a writer of
;; that array is
;;
;;     movq g(%rip), %r10 ; movq 8(%r10), %rax ; cmpq %rax, %r15 ; jb ok
;;     movq (%r10), %rax ; movq (%rax,%r15,8), %r12
;;
;; on the pre-BE-3 compiler: the callee may rebind the global, so the handle
;; and both descriptor words are re-read per iteration; the length is loaded
;; into its own home and compared from there, and the data word is read off
;; the register the length load staged the handle into. BE-3 puts the handle
;; in the length's own home, compares the length word through it and reads the
;; data word through the same register:
;;
;;     movq g(%rip), %rax ; cmpq 8(%rax), %r15 ; jb ok ; movq (%rax), %rax
;;
;; The arrays are sized through `glf-opaque` so no length folds to a literal;
;; `probe-sum` reads `glf-items` at an index loaded out of `glf-slots`, so the
;; check on `glf-items` is data-dependent and survives every static proof, and
;; `glf-touch!` carries a never-taken rebinding of `glf-items`, which is what
;; keeps the handle out of the loop's registers (a callee that only writes
;; elements would let the descriptor words hoist, and the direct fold would
;; take the check instead). The named bodies hide behind a never-taken
;; self-recursion so the leaf inliner leaves them for the gate to read.
;;
;; The gate is check_global_len_fold in scripts/verify-asm-shape-gates.sh; it
;; FAILS on the pre-BE-3 compiler, which loads the length into a register.
(define glf-items : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define glf-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

(define (glf-opaque [n : i64] [poke : i64]) : i64
  (if (< poke 0)
    (glf-opaque n (+ poke 1))
    (+ n 8)))

(define (glf-touch! [slot : i64] [poke : i64]) : unit
  (if (< poke 0)
    (begin
      (set! glf-items (__tl_make-array i64 (glf-opaque 0 0)))
      (glf-touch! slot (+ poke 1)))
    (set! (array-ref glf-items slot) (+ (array-ref glf-items slot) 1))))

(define (probe-sum [n : i64] [poke : i64]) : i64
  (if (< poke 0)
    (probe-sum n (+ poke 1))
    (let
      [acc : i64 0]
      [i : i64 0]
      (begin
        (while (< i n)
          (let
            [slot : i64 (array-ref glf-slots i)]
            (begin
              (set! acc (+ acc (array-ref glf-items slot)))
              (glf-touch! slot 0)
              (set! i (+ i 1)))))
        acc))))

(define (main) : i64
  (let
    [i : i64 0]
    (begin
      (set! glf-items (__tl_make-array i64 (glf-opaque 0 0)))
      (set! glf-slots (__tl_make-array i64 (glf-opaque 0 0)))
      (while (< i 8)
        (begin
          (set! (array-ref glf-items i) (* i 3))
          (set! (array-ref glf-slots i) (- 7 i))
          (set! i (+ i 1))))
      (cond
        [(not (= (probe-sum 8 0) 84)) 1]
        [(not (= (probe-sum 3 0) 57)) 2]
        [else 42]))))