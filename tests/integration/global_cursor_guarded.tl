;; INL-6: a MULTIBLOCK helper that advances a module-global CURSOR must inline.
;;
;; INL-5 admitted `Store` -- the write to a module global cell -- in the
;; SINGLE-BLOCK inlinable-body whitelist and left the multiblock one refusing
;; it, on a measurement whose loser turned out to be a mispricing in the
;; measured-plan tier rather than anything about the instruction. With that
;; pricing fixed the multiblock whitelist carries `Store` too, and this fixture
;; is the shape that admission is for.
;;
;; `gcg-step` is `global_cursor_helper`'s `gc-next` with a guard in front of it:
;; two blocks, a BOUNDS ARM that returns a sentinel when the cursor has reached
;; the caller's limit and a body that reads `tokens[cursor]` and bumps the
;; global cursor. One block would be the single-block tier's business; the arm
;; is what puts it in the multiblock gate's, where the `Store` was refused by
;; SHAPE before any band could price a site.
;;
;; What this pins is that the splice keeps the store's MEANING at multiblock
;; size. The cursor is read by `gcg-step` alone, so the fold below is a function
;; of the exact SEQUENCE of positions the helper visited: a clone that dropped
;; the store leaves every site reading position zero, a clone that duplicated it
;; skips every other token, and either changes the printed checksum. The
;; guard's own arm is observable in the same number -- a clone that lost the arm
;; would read past `limit` and fold different values in.
;;
;; The helper is called from FIVE sites across three functions, three of them
;; inside `gcg-run`'s loop, so no single-site absorb band can claim it: the body
;; is copied and every copy has to be right.
(import stdlib.io)
(import stdlib.string)

(define gcg-tokens : (__tl_dyn-array i64)
  (__tl_make-array i64 0))
(define gcg-cursor : i64
  0)

;; The refused shape: a guard arm, then the read and the global store. The
;; `array-ref` is where the abort twin's check lives -- it sits INSIDE the body,
;; so after the splice it is a check each caller carries, and its diagnostic
;; must still name this line.
(define (gcg-step [limit : i64]) : i64
  (if (>= gcg-cursor limit)
    -1
    (let
      [value : i64 (array-ref gcg-tokens gcg-cursor)]
      (begin
        (set! gcg-cursor (+ gcg-cursor 1))
        value))))

;; Three sites inside one loop. The fold is order-sensitive in all three
;; operands, so the cursor's advance is observable per site rather than only
;; per iteration.
(define (gcg-run [rounds : i64] [limit : i64]) : i64
  (let
    [acc : i64 1469598103934665603]
    [i : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (set! acc (* (bit-xor acc (gcg-step limit)) 1099511628211))
          (set! acc (+ (* acc 31) (gcg-step limit)))
          (set! acc (bit-xor acc (shl (gcg-step limit) 3)))
          (set! i (+ i 1))))
      acc)))

;; A fourth site at a straight-line position, and a fifth in a cold helper, so
;; the callee keeps more than one reference and more than one caller.
(define (gcg-peek-pair [limit : i64]) : i64
  (+ (* (gcg-step limit) 7) (gcg-step limit)))

(define (gcg-fill [size : i64]) : unit
  (let
    [i : i64 0]
    [p : i64 5]
    (begin
      (set! gcg-tokens (__tl_make-array i64 size))
      (while (< i size)
        (begin
          (set! (array-ref gcg-tokens i) (+ (* p 2654435761) i))
          (set! p (+ p 2))
          (set! i (+ i 1))))
      unit)))

(define (main) : i64
  (let
    [size : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    [limit : i64 (string.>int (io.arg 3))]
    [fold : i64 0]
    [pair : i64 0]
    (begin
      (gcg-fill size)
      (set! gcg-cursor 0)
      ;; Three tokens per round from the loop, then two more from the
      ;; straight-line pair. A `limit` past `size` walks the check inside the
      ;; inlined body off the end; a `limit` at or below `size` takes the
      ;; guard's arm instead and folds the sentinel in.
      (set! fold (gcg-run rounds limit))
      (set! pair (gcg-peek-pair limit))
      (io.println "{}" (bit-and fold 268435455))
      (io.println "{}" (bit-and pair 268435455))
      (io.println "{}" gcg-cursor)
      42)))