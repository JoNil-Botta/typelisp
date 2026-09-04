;; INL-5: a helper that advances a module-global CURSOR must inline.
;;
;; `gc-next` is `benchmarks/asm_render/bench.tl`'s `asm-tok-next` shape, the
;; body the inliner's instruction whitelist refused for as long as it carried
;; no `Store` arm: a one-block function that reads `tokens[cursor]` and bumps
;; the global `cursor`. Nothing about it is expensive -- two global-cell loads,
;; a bounds check, an element load, an add, the store and a return -- and every
;; one of its call sites paid a full call boundary plus a reload of both cells
;; for it.
;;
;; What this fixture pins is that the splice keeps the store's MEANING. The
;; cursor is read by `gc-next` itself and never by anything else, so the fold
;; below is a function of the exact SEQUENCE of positions the helper visited:
;; a store the clone dropped leaves every site reading position zero, a store
;; the clone duplicated skips every other token, and either one changes the
;; printed checksum and the exit code. `gc-tokens` holds distinct primes so no
;; two positions can be confused, and its length comes from argv so nothing can
;; fold the run away.
;;
;; The helper is called from FIVE sites across three functions -- three of them
;; inside `gc-run`'s loop -- so no single-site absorb band can claim it: the
;; body is copied, and every copy has to be right.
(import stdlib.io)
(import stdlib.string)

(define gc-tokens : (__tl_dyn-array i64)
  (__tl_make-array i64 0))
(define gc-cursor : i64
  0)

;; The refused shape. `array-ref` on a global array is where the abort twin's
;; check lives: it sits INSIDE the body, so after the splice it is a check the
;; caller carries, and its diagnostic must still name this line.
(define (gc-next) : i64
  (let
    [value : i64 (array-ref gc-tokens gc-cursor)]
    (begin
      (set! gc-cursor (+ gc-cursor 1))
      value)))

;; Three sites inside one loop. The fold is order-sensitive in all three
;; operands, so the cursor's advance is observable per site rather than only
;; per iteration.
(define (gc-run [rounds : i64]) : i64
  (let
    [acc : i64 1469598103934665603]
    [i : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (set! acc (* (bit-xor acc (gc-next)) 1099511628211))
          (set! acc (+ (* acc 31) (gc-next)))
          (set! acc (bit-xor acc (shl (gc-next) 3)))
          (set! i (+ i 1))))
      acc)))

;; A fourth site at a straight-line position, and a fifth in a cold helper, so
;; the callee keeps more than one reference and more than one caller.
(define (gc-peek-pair) : i64
  (+ (* (gc-next) 7) (gc-next)))

(define (gc-fill [size : i64]) : unit
  (let
    [i : i64 0]
    [p : i64 3]
    (begin
      (set! gc-tokens (__tl_make-array i64 size))
      (while (< i size)
        (begin
          (set! (array-ref gc-tokens i) (+ (* p 2654435761) i))
          (set! p (+ p 2))
          (set! i (+ i 1))))
      unit)))

(define (main) : i64
  (let
    [size : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    [fold : i64 0]
    [pair : i64 0]
    (begin
      (gc-fill size)
      (set! gc-cursor 0)
      ;; Three tokens per round from the loop, then two more from the
      ;; straight-line pair: a `rounds` that overruns `size` walks the check
      ;; inside the inlined body off the end.
      (set! fold (gc-run rounds))
      (set! pair (gc-peek-pair))
      (io.println "{}" (bit-and fold 268435455))
      (io.println "{}" (bit-and pair 268435455))
      (io.println "{}" gc-cursor)
      42)))