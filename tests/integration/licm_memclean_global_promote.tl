(import stdlib.io)

;; FORCING TEST for the memory-clean direct-call tier of LICM's loop-scope
;; global-cell promotion (opt-licm-direct-call-keeps-globals-clean?,
;; opt-licm-global-promote-live-in-budget).
;;
;; A `CompilerIrValue.Global` OPERAND is a hidden `movq SYM(%rip), %rX` at every
;; use site. When nothing the loop body executes can write a cell, LICM loads
;; the cell ONCE into the preheader and rewrites the body's operands to that
;; var. The interesting case is a body that CALLS: the function-scope global
;; pass refuses any function holding a returning call, so a loop carrying one is
;; exactly where the loop-scope tier has to earn its keep.
;;
;; The three loops below pin three different verdicts, all with the same call
;; shape and the same two cell reads per iteration, so the only thing that
;; separates them is the property under test.
;;
;;   promoted-scan   admitted   -- callee writes no memory, loop live-in is
;;                                 small, so the preheader holds ONE cell load
;;                                 and the body holds none.
;;   pressured-scan  refused    -- same callee, but the body enters with more
;;                                 live values than the budget allows, so the
;;                                 promoted copy would spill instead of taking a
;;                                 register. Both per-iteration cell reads stay.
;;   writer-scan     refused    -- the callee `set!`s the cell, so nothing is
;;                                 provable and both reads stay. This one is a
;;                                 WRONG-ANSWER guard as well: the sum depends on
;;                                 re-reading the cell after every call, so a
;;                                 hoist here changes the result, and `twin`
;;                                 recomputes it with the cell read spelled out.
;;
;; `main` returns 42 only if every loop matches its twin; the asm shapes are
;; asserted by scripts/verify-asm-shape-gates.sh (check_licm_memclean_promote).
;;
;; Two things force the shapes to survive to the asm. Each scan opens with a
;; never-taken self-recursion, which blocks the leaf inliner and TCO so the
;; named body is still there to inspect. And every cell is `set!` from the
;; process argument count before it is read, because a global that is never
;; stored is a CONSTANT -- the const-global pass folds it into its uses and
;; there is no cell left to promote.
(define gcell-a : i64
  3)
(define gcell-b : i64
  5)
(define gcell-c : i64
  7)

;; MEMORY-CLEAN callee: touches no memory at all -- no array, no cell, no
;; parameter it could write through, so the call-memory fixpoint gives it the
;; memory bit and opt-licm-direct-call-keeps-globals-clean? admits it. The
;; never-taken self-recursion is what keeps the CALL SITE alive: inlined, the
;; loops below would hold no call at all and would already be globals-clean
;; without the tier under test.
(define (mix [seed : i64] [rounds : i64]) : i64
  (if (< rounds -999999)
    (mix (- seed 1) (- rounds 1))
    (let
      [i : i64 0]
      [acc : i64 seed]
      [spin : i64 0]
      [guard : i64 0]
      (begin
        (while (< i rounds)
          (begin
            (set! acc (+ (* acc 3) 1))
            (set! i (+ i 1))))
        (set! i 0)
        (while (< i rounds)
          (begin
            (set! spin (+ spin acc))
            (set! i (+ i 1))))
        (set! i 0)
        (while (< i rounds)
          (begin
            (set! guard (+ guard 1))
            (set! i (+ i 1))))
        (+ acc (- spin spin))))))

;; The same shape as `mix`, but it WRITES a global cell. Its call-memory summary
;; therefore carries neither the memory bit nor the global bit, so
;; opt-licm-direct-call-keeps-globals-clean? refuses it and the loop calling it
;; keeps per-use cell reads.
(define (mix-writing [seed : i64] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 seed]
    [spin : i64 0]
    [guard : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (set! acc (+ (* acc 3) 1))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i rounds)
        (begin
          (set! spin (+ spin acc))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i rounds)
        (begin
          (set! guard (+ guard 1))
          (set! i (+ i 1))))
      (set! gcell-c (+ gcell-c 1))
      (+ acc (- spin spin)))))

;; ADMITTED. Two operand reads of `gcell-a` per iteration, separated by the
;; call; the loop enters with a handful of live values.
(define (promoted-scan [n : i64] [rounds : i64]) : i64
  (if (< n -999999)
    (promoted-scan (- n 1) rounds)
    (let
      [i : i64 0]
      [acc : i64 0]
      (begin
        (while (< i n)
          (begin
            (set! acc (+ acc gcell-a))
            (set! acc (+ acc (mix i rounds)))
            (set! acc (+ acc gcell-a))
            (set! i (+ i 1))))
        acc))))

;; REFUSED on pressure. Identical call and cell shape; the extra parameters are
;; all live across the loop, pushing the body's live-in count past the budget,
;; so the promoted copy would land in a frame slot rather than a register.
(define (pressured-scan
  [n : i64]
  [rounds : i64]
  [p0 : i64]
  [p1 : i64]
  [p2 : i64]
  [p3 : i64]
  [p4 : i64]
  [p5 : i64]
  [p6 : i64]
  [p7 : i64]
  [p8 : i64]
  [p9 : i64]) : i64
  (if (< n -999999)
    (pressured-scan (- n 1) rounds p0 p1 p2 p3 p4 p5 p6 p7 p8 p9)
    (let
      [i : i64 0]
      [acc : i64 0]
      (begin
        (while (< i n)
          (begin
            (set! acc (+ acc gcell-b))
            (set! acc (+ acc (mix i rounds)))
            (set! acc (+ acc gcell-b))
            ;; Each parameter is XORed with the loop counter, so none of them
            ;; is a loop-invariant sub-expression LICM could fold into one
            ;; hoisted value: all ten stay live ACROSS the loop and the body's
            ;; live-in count is what the budget refuses.
            (set! acc (+ acc (bit-xor p0 i)))
            (set! acc (+ acc (bit-xor p1 i)))
            (set! acc (+ acc (bit-xor p2 i)))
            (set! acc (+ acc (bit-xor p3 i)))
            (set! acc (+ acc (bit-xor p4 i)))
            (set! acc (+ acc (bit-xor p5 i)))
            (set! acc (+ acc (bit-xor p6 i)))
            (set! acc (+ acc (bit-xor p7 i)))
            (set! acc (+ acc (bit-xor p8 i)))
            (set! acc (+ acc (bit-xor p9 i)))
            (set! i (+ i 1))))
        acc))))

;; REFUSED on the proof. `mix-writing` writes the cell, so every iteration must
;; observe the value the previous call left behind.
(define (writer-scan [n : i64] [rounds : i64]) : i64
  (if (< n -999999)
    (writer-scan (- n 1) rounds)
    (let
      [i : i64 0]
      [acc : i64 0]
      (begin
        (while (< i n)
          (begin
            (set! acc (+ acc gcell-c))
            (set! acc (+ acc (mix-writing i rounds)))
            (set! acc (+ acc gcell-c))
            (set! i (+ i 1))))
        acc))))

;; Hand-spelled twin for `writer-scan`: the cell reads are written out around
;; the call in the same order, so it is only equal to `writer-scan` if the cell
;; is re-read after the call on every iteration.
(define (writer-twin [n : i64] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    [before : i64 0]
    [after : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! before gcell-c)
          (set! acc (+ acc before))
          (set! acc (+ acc (mix-writing i rounds)))
          (set! after gcell-c)
          (set! acc (+ acc after))
          (set! i (+ i 1))))
      acc)))

;; Twin for `pressured-scan`: the same ten XOR terms, spelled out against
;; literal parameter values.
(define (pressured-twin [n : i64] [rounds : i64] [cell : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    [k : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (* 2 cell)))
          (set! acc (+ acc (mix i rounds)))
          (set! k 1)
          (while (< k 11)
            (begin
              (set! acc (+ acc (bit-xor k i)))
              (set! k (+ k 1))))
          (set! i (+ i 1))))
      acc)))

;; Closed form for the remaining non-writing scan: the cell never changes, so each
;; iteration adds 2*cell plus whatever `mix` returns for that index.
(define (scan-twin [n : i64] [rounds : i64] [cell : i64] [extra : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (* 2 cell)))
          (set! acc (+ acc (mix i rounds)))
          (set! acc (+ acc extra))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  ;; `n` and `rounds` come from the process argument count so nothing folds to a
  ;; constant and every loop is a real run-time trip. The cells are stored here
  ;; for the same reason -- an unstored global is folded away entirely.
  (let
    [n : i64 (+ (io.arg-count) 5)]
    [rounds : i64 (+ (io.arg-count) 2)]
    [_seed-a : unit (set! gcell-a (+ (io.arg-count) 3))]
    [_seed-b : unit (set! gcell-b (+ (io.arg-count) 5))]
    [_seed-c : unit (set! gcell-c (+ (io.arg-count) 7))]
    [a : i64 (promoted-scan n rounds)]
    [a-want : i64 (scan-twin n rounds gcell-a 0)]
    [b : i64 (pressured-scan n rounds 1 2 3 4 5 6 7 8 9 10)]
    [b-want : i64 (pressured-twin n rounds gcell-b)]
    ;; Both writer runs start from the same cell value, so reset between them.
    [c-start : i64 gcell-c]
    [c : i64 (writer-scan n rounds)]
    [c-mid : i64 gcell-c]
    [_reset : unit (set! gcell-c c-start)]
    [c-want : i64 (writer-twin n rounds)]
    [c-end : i64 gcell-c]
    (if (and
      (= a a-want)
      (= b b-want)
      (= c c-want)
      (= c-mid c-end)
      (> c-mid c-start))
      42
      1)))