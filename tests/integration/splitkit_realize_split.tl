(import stdlib.io)

;; SplitKit M3 FORCING TEST -- realized register-piece split (read-only sub-range).
;;
;; Under `--cfg splitkit-stress` (budget>0) the greedy splits a spilled
;; call-spanning value at its call boundaries and the M3 realization pass
;; (compiler-reg-splitkit-rewrite-blocks) homes a call-free post-call sub-range in
;; a register: it reloads the value from its slot ONCE at the sub-range entry,
;; remaps the sub-range reads (the whole coalesce class) to that register, and
;; -- since the value is not redefined here -- inserts NO write-back.
;;
;; SHAPE: eight values a..h are computed before a loop and used INSIDE it, both
;; BEFORE and AFTER a REAL non-inlinable recursive call (`clobber`, which clobbers
;; every caller-saved register). The use-before + use-after gives each value a
;; pre-call and a post-call call-free sub-range; with eight values overflowing the
;; five callee-saved registers several spill, and the realization homes a spilled
;; value's post-call read-run in a caller-saved register instead of reloading it
;; per use.
;;
;; SOUNDNESS GUARD: if the realization reloads the wrong slot, remaps the wrong
;; reads, or homes the value in a register a call clobbers, the sum is wrong ->
;; exit 1. Inputs derive from (io.arg-count) so nothing constant-folds; `expected`
;; is a straight-line closed form.
(define (clobber [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (clobber (- x 1)))))

(define (split-hot [n : i64]) : i64
  (let
    [a : i64 (+ n 1)]
    [b : i64 (+ n 2)]
    [c : i64 (+ n 3)]
    [d : i64 (+ n 4)]
    [e : i64 (+ n 5)]
    [f : i64 (+ n 6)]
    [g : i64 (+ n 7)]
    [h : i64 (+ n 8)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 4)
        (begin
          ;; use a..h BEFORE the call (pre-call sub-range)
          (set!
            acc
            (+
              acc
              (+
                (* a 3)
                (+
                  (* b 3)
                  (+
                    (* c 3)
                    (+ (* d 3) (+ (* e 3) (+ (* f 3) (+ (* g 3) (* h 3))))))))))
          (set! acc (+ acc (clobber i)))
          ;; use a..h AFTER the call (post-call sub-range: the register piece)
          (set!
            acc
            (+
              acc
              (+
                (* a 5)
                (+
                  (* b 5)
                  (+
                    (* c 5)
                    (+ (* d 5) (+ (* e 5) (+ (* f 5) (+ (* g 5) (* h 5))))))))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [r : i64 (split-hot n)]
    ;; n=1: a..h = 2..9, sum = 44. Per iteration: 3*44 + clobber(i) + 5*44
    ;; = 132 + (i+1) + 220 = 353 + i. Sum over i=0..3 = 353+354+355+356 = 1418.
    (if (= r 1418)
      42
      1)))