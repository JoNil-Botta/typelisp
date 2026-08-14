;; FORCING TEST for backend jump-only block forwarding (#jump-forward).
;;
;; Nested conditionals inside a loop lower to a run of if_merge blocks: the
;; inner merge holds a phi and `jump <outer merge>`, the outer merge holds a phi
;; and `jump <next merge>`, and so on out to the loop's own tail. Once the
;; phi-edge copies coalesce -- every phi in the run lands in the same home --
;; each of those blocks emits a single `jmp`, so a branch into the run used to
;; walk it one jump at a time before reaching code that does anything. The
;; backend's forwarding table collapses the walk: a jump aimed at a block that
;; emits nothing but `jmp M` names M instead. The blocks themselves are still
;; emitted, so every label, span and switch-table entry stays valid.
;;
;; The gate (scripts/verify-asm-shape-gates.sh check_jump_only_forward) asserts
;; the property directly over every compiled body here: no branch may target a
;; label whose block is a lone `jmp`. It FAILS on the forward probe before the
;; forwarding table exists (3 such branches on linux-x86_64).
;;
;; Never-taken self-recursion blocks inlining so the named bodies survive for
;; the gate to inspect.
;; FORWARD: a four-deep nested conditional in a loop. Every arm assigns the same
;; accumulator, so each merge's phi coalesces into one home and the merge run
;; degenerates to a jump chain.
(define (forward-probe [n : i64] [pivot : i64]) : i64
  (if (< n -999999)
    (forward-probe (- n 1) pivot)
    (let
      [a : i64 0]
      [i : i64 0]
      (begin
        (while (< i n)
          (begin
            (if (> (* i 3) pivot)
              (if (> (* i 5) pivot)
                (if (> (* i 7) pivot)
                  (if (> (* i 11) pivot)
                    (set! a (+ a i))
                    (set! a (- a 1)))
                  (set! a (* a 2)))
                (set! a (+ a 3)))
              (set! a (- a 5)))
            (set! i (+ i 1))))
        a))))

;; DIAMOND: sequential merges whose incoming values differ per edge and stay
;; live into the next diamond, so those merges keep real work and are NOT
;; jump-only. Jumps naming them must survive: the correctness twin for the
;; forward probe, same control shape, values that must be unchanged.
(define (diamond-probe [n : i64] [pivot : i64]) : i64
  (if (< n -999999)
    (diamond-probe (- n 1) pivot)
    (let
      [acc : i64 0]
      [i : i64 0]
      (begin
        (while (< i n)
          (let
            [a : i64
              (if (> (* i 3) pivot)
                (* i 5)
                (- pivot i))]
            [b : i64
              (if (> a pivot)
                (+ a 7)
                (- a 11))]
            [c : i64
              (if (< b 0)
                (* b 3)
                (+ b 13))]
            (begin
              (set! acc (+ acc (+ a (+ b c))))
              (set! i (+ i 1)))))
        acc))))

;; SELF-LOOP: an empty infinite loop lowers to a block whose only instruction is
;; a jump to its own label. Forwarding must refuse it -- a block that hands its
;; jumps to itself has no "next" to name -- so the self-jump has to survive.
;; Guarded by a runtime-false global so the probe returns.
(define jump-only-forward-spin : bool
  false)

(define (spin-probe [seed : i64]) : i64
  (begin
    (if jump-only-forward-spin
      (while true
        unit)
      unit)
    (+ seed 1)))

(define (main) : i64
  (let
    [a : i64 (forward-probe 64 128)]
    [b : i64 (diamond-probe 64 128)]
    [c : i64 (spin-probe 6)]
    (if (and (= a 898) (= b 30678) (= c 7))
      42
      1)))