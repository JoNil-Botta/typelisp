;; FORCING TEST for the fallthrough-chain jump peephole.
;;
;; `(if c (begin ...) unit)` inside a loop lowers to then/else/merge blocks in
;; which the ELSE block emits zero instructions: its own jump is already
;; fallthrough-suppressed and its phi-edge copies coalesce away. The then
;; block's terminator therefore used to emit `jmp merge` immediately before
;; `else:` `merge:` -- a jump to the very next instruction, retired on every
;; taken iteration. `compiler-backend-jump-target-is-fallthrough?` only
;; recognizes the IMMEDIATELY next block, so it cannot see through the empty
;; else block; the assembled-body peephole can.
;;
;; The two probes pin both directions of the rule. Never-taken self-recursion
;; blocks inlining and TCO so the named bodies survive for the gate to inspect
;; (scripts/verify-asm-shape-gates.sh check_fallthrough_jmp_chain; the
;; drop-probe assertion FAILS before the peephole).
;;
;; DROP: then-only conditional in a loop. The then arm carries a
;; multi-instruction dependency chain so it stays a real block instead of
;; collapsing to cmov, and its terminating `jmp` reaches the merge label across
;; nothing but the empty else block's label. The self-recursive tail call is a
;; BACKWARD jump in the same body and must survive untouched.
(define (chain-drop-probe [n : i64] [pivot : i64]) : i64
  (if (< n -999999)
    (chain-drop-probe (- n 1) pivot)
    (let
      [lo : i64 0]
      [hi : i64 0]
      [i : i64 0]
      (begin
        (while (< i n)
          (begin
            (if (< (* i 7) pivot)
              (begin
                (set! lo (+ lo (* i 3)))
                (set! hi (+ hi (* lo 5))))
              unit)
            (set! i (+ i 1))))
        (+ lo hi)))))

;; KEEP: both arms carry work, so the then arm's `jmp merge` crosses the else
;; arm's real instructions. That jump is NOT a fallthrough and must survive.
(define (chain-keep-probe [n : i64] [pivot : i64]) : i64
  (if (< n -999999)
    (chain-keep-probe (- n 1) pivot)
    (let
      [lo : i64 0]
      [hi : i64 0]
      [i : i64 0]
      (begin
        (while (< i n)
          (begin
            (if (< (* i 7) pivot)
              (begin
                (set! lo (+ lo (* i 3)))
                (set! hi (+ hi (* lo 5))))
              (begin
                (set! hi (- hi (* i 11)))
                (set! lo (- lo (* hi 13)))))
            (set! i (+ i 1))))
        (+ lo hi)))))

(define (main) : i64
  (let
    [a : i64 (chain-drop-probe 64 128)]
    [b : i64 (chain-keep-probe 64 128)]
    (if (and (> a 0) (not (= b 0)))
      42
      1)))