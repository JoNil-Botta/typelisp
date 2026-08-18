;; FORCING TEST for the backend's post-register-allocation block layout
;; (#block-layout; scripts/verify-asm-shape-gates.sh check_block_layout).
;;
;; Three probes, one per decision the pass makes. Never-taken self-recursion
;; blocks inlining so the named bodies survive for the gate to inspect.
;;
;; SINK: the checked-read idiom `(if (and (>= i 0) (< i n)) <load> -1)`. The
;; `i < 0` clause is predicted false by the opcode heuristic and the `i >= n`
;; clause bails to the same arm, so the whole `-1` arm is predicted cold. It
;; moves behind the function body and the loaded value falls straight into the
;; join; before the pass the load's block ended in `jmp <join>` across that
;; one-instruction arm.
(import stdlib.string)

(define layout-text : String
  "the quick brown fox jumps over the lazy dog")
(define layout-len : i64
  43)

(define (sink-probe [n : i64]) : i64
  (if (< n -999999)
    (sink-probe (- n 1))
    (let
      [i : i64 0]
      [acc : i64 0]
      (begin
        (while (< i n)
          (begin
            (set!
              acc
              (+
                acc
                (if (and (>= i 0) (< i layout-len))
                  (cast (string.string-ref layout-text i) : i64)
                  -1)))
            (set! i (+ i 1))))
        acc))))

;; DUP: a loop exit block that is two instructions and an unconditional jump to
;; the function's join, reached by a `jmp` from the arm that skipped the loop
;; entirely. The run replaces that `jmp` outright and the exit block stays where
;; it is for the loop's own edge.
(define (dup-probe [n : i64] [pivot : i64]) : i64
  (if (< n -999999)
    (dup-probe (- n 1) pivot)
    (+
      1
      (if (> pivot 0)
        (let
          [i : i64 0]
          [acc : i64 0]
          (begin
            (while (< i n)
              (begin
                (if (> (* i 3) pivot)
                  (set! acc (+ acc 7))
                  (set! acc (- acc 1)))
                (set! i (+ i 1))))
            (+ (* acc 2) 5)))
        (* pivot 3)))))

;; KEEP: both arms carry real work and the branch compares two registers, which
;; the opcode heuristics say nothing about. Layout must follow IR order -- the
;; else arm stays between the then arm and the merge, and the then arm keeps
;; its jump across it.
(define (keep-probe [a : i64] [b : i64]) : i64
  (if (< a -999999)
    (keep-probe (- a 1) b)
    (+
      1
      (if (< a b)
        (- (* a 13) (* b 7))
        (+ (* a 11) (* b 5))))))

(define (main) : i64
  (let
    [x : i64 (+ (sink-probe 3) (sink-probe 400))]
    [y : i64 (dup-probe 64 30)]
    [z : i64 (keep-probe 3 9)]
    (if (and (> x 0) (not (= y 0)) (not (= z 0)))
      42
      1)))