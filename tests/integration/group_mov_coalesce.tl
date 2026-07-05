(import stdlib.io)

;; FORCING TEST for M-B part 2: stack-homed register-group Mov coalescing.
;; `Op` is a two-word register-group enum (tag + payload). The match scrutinee
;; chain `(array-ref ops i)` -> element temp -> match binding produces a
;; group-typed IrInstrMov between two stack-homed group vars (the arms live in
;; other blocks, so block-local copy-prop cannot collapse it). The old backend
;; spilled BOTH vars -- the element pair once and the scrutinee pair AGAIN
;; through %rax:%rdx -- every iteration; with coalescing they share one slot
;; pair and the second spill disappears. The recursive in-loop call plus the
;; loop-carried accumulators keep the CSRs busy so the group values stay
;; stack-homed. The runtime check guards reconstruction (a wrong shared slot
;; or clobbered word changes the sum -> exit 1); target/group-mov-gate.sh
;; additionally asserts the asm shape.
(defenum Op
  (Add i64)
  (Sub i64)
  (Mul i64))

;; Recursive on purpose: a trivial leaf would be inlined at opt2, deleting the
;; in-loop clobber point. bump(x) = x+1 for x >= 0.
(define (bump [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (bump (- x 1)))))

(define (run [ops : (Array Op)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    [lo : i64 0]
    [hi : i64 0]
    (begin
      (while (< i n)
        (begin
          (match (array-ref ops i)
            [(Add v) (set! acc (+ acc v))]
            [(Sub v) (set! acc (- acc v))]
            [(Mul v) (set! acc (* acc v))])
          (set! lo (+ lo (bump i)))
          (set! hi (+ hi i))
          (set! i (+ i 1))))
      (+ acc (+ lo hi)))))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 3)]
    [ops : (Array Op) (make-array Op n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set!
            ops
            i
            (if (= (% i 3) 0)
              (Add (+ i 2))
              (if (= (% i 3) 1)
                (Sub i)
                (Mul 3))))
          (set! i (+ i 1))))
      (let
        [r : i64 (run ops n)]
        ;; n=4 (no args): ops = [Add 2, Sub 1, Mul 3, Add 5].
        ;; acc: 0+2=2; 2-1=1; 1*3=3; 3+5=8. lo = bump(0..3) = 1+2+3+4 = 10.
        ;; hi = 0+1+2+3 = 6. r = 8+10+6 = 24.
        (if (= r 24)
          42
          1)))))
