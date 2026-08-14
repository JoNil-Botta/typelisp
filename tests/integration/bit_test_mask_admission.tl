;; Correctness twin for single-bit mask-test admission (opt-instr-dead-array?).
;;
;; `(= (bit-and x m) m)` and `(!= (bit-and x m) m)` collapse to one `test`
;; whose jump sense is INVERTED relative to the compare-against-zero rewrite:
;; `x & m` is either 0 or m when m has a single bit, so equality with the mask
;; means the bit is SET (ZF clear -> BitTestNe) and inequality means it is
;; CLEAR (ZF set -> BitTestEq). A flipped sense is silent in an instruction
;; count, so every kernel here is checked in BOTH branch directions against an
;; independently spelled reference (`(bit-and (shr x k) 1)`).
;;
;; The refused neighbours are exercised too: a multi-bit mask asks whether ALL
;; the selected bits are set, a comparison constant that is not the mask asks
;; something the bit test cannot answer, and `1 << 63` is stored negative as
;; i64 and stays on the old mov+and+cmp path.
;;
;; The never-taken self-recursion in each kernel blocks the opt2 inliner, so
;; each keeps its own frame and its own emitted symbol for the assembly-shape
;; gate (scripts/verify-asm-shape-gates.sh: check_mask_test_admission).
;;
;; Reference bit read: shift the wanted bit down and mask it. Shares no
;; instruction shape with the `(x & m) == m` spelling under test.
(define (bit-ref [x : i64] [k : i64]) : i64
  (bit-and (shr x k) 1))

;; ADMITTED, Eq against the mask -> BitTestNe (`testq $1`; `jne` to the set arm).
(define (parity-set [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (parity-set x (+ poke 1))
    (if (= (bit-and x 1) 1)
      1
      0)))

;; ADMITTED, Ne against the mask -> BitTestEq (`testq $8`; `je` to the clear arm).
(define (bit3-clear [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (bit3-clear x (+ poke 1))
    (if (!= (bit-and x 8) 8)
      1
      0)))

;; REFUSED: a multi-bit mask asks whether BOTH bits are set, which one `test`
;; cannot answer. Keeps mov+and+cmp.
(define (pair-both-set [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (pair-both-set x (+ poke 1))
    (if (= (bit-and x 3) 3)
      1
      0)))

;; REFUSED: the comparison constant is not the mask. `(x & 4) == 1` is never
;; true; the point is that it is not miscompiled into a bit test either.
(define (mismatched-const [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (mismatched-const x (+ poke 1))
    (if (= (bit-and x 4) 1)
      1
      0)))

;; REFUSED: ordered compares against the mask are a constant fold, not a bit
;; test. `(x & 1) <= 1` always holds and `(x & 1) > 1` never does.
(define (mask-le [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (mask-le x (+ poke 1))
    (if (<= (bit-and x 1) 1)
      1
      0)))

(define (mask-gt [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (mask-gt x (+ poke 1))
    (if (> (bit-and x 1) 1)
      1
      0)))

;; REFUSED: the mask is not a literal.
(define (dynamic-mask [x : i64] [m : i64] [poke : i64]) : i64
  (if (< poke 0)
    (dynamic-mask x m (+ poke 1))
    (if (= (bit-and x m) m)
      1
      0)))

;; Boundary single-bit masks: the lowest, the 32-bit edge, and the highest bit
;; the `> 0` guard still admits.
(define (bit31-set [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (bit31-set x (+ poke 1))
    (if (= (bit-and x 2147483648) 2147483648)
      1
      0)))

(define (bit62-clear [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (bit62-clear x (+ poke 1))
    (if (!= (bit-and x 4611686018427387904) 4611686018427387904)
      1
      0)))

;; REFUSED: `1 << 63` is negative as i64, so the `> 0` single-bit guard drops
;; it. It must still compute the right answer on the old path.
(define (bit63-set [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (bit63-set x (+ poke 1))
    (if (= (bit-and x (shl 1 63)) (shl 1 63))
      1
      0)))

;; Exhaustive over every low-byte input, so bits 0 and 3 are each observed set
;; and clear and both arms of both admitted mappings are taken.
(define (exhaustive-low-bits) : i64
  (let
    [x : i64 0]
    [status : i64 42]
    (begin
      (while (< x 256)
        (begin
          (if (!= (parity-set x 0) (bit-ref x 0))
            (set! status 1)
            unit)
          (if (!= (bit3-clear x 0) (- 1 (bit-ref x 3)))
            (set! status 2)
            unit)
          (if (!= (pair-both-set x 0) (bit-and (bit-ref x 0) (bit-ref x 1)))
            (set! status 3)
            unit)
          (if (!= (mismatched-const x 0) 0)
            (set! status 4)
            unit)
          (if (!= (mask-le x 0) 1)
            (set! status 5)
            unit)
          (if (!= (mask-gt x 0) 0)
            (set! status 6)
            unit)
          (if (!= (dynamic-mask x 1 0) (bit-ref x 0))
            (set! status 7)
            unit)
          (set! x (+ x 1))))
      status)))

;; The wide masks over the four inputs that pin both branch directions: the
;; bit clear, the bit alone, the bit with unrelated noise, and the all-ones
;; word where every mask matches.
(define (wide-mask-probe [x : i64]) : i64
  (let
    [status : i64 42]
    (begin
      (if (!= (bit31-set x 0) (bit-ref x 31))
        (set! status 1)
        unit)
      (if (!= (bit62-clear x 0) (- 1 (bit-ref x 62)))
        (set! status 2)
        unit)
      (if (!= (bit63-set x 0) (bit-ref x 63))
        (set! status 3)
        unit)
      status)))

(define (wide-masks) : i64
  (let
    [status : i64 42]
    (begin
      (if (!= (wide-mask-probe 0) 42)
        (set! status 1)
        unit)
      (if (!= (wide-mask-probe (shl 1 31)) 42)
        (set! status 2)
        unit)
      (if (!= (wide-mask-probe (shl 1 62)) 42)
        (set! status 3)
        unit)
      (if (!= (wide-mask-probe (shl 1 63)) 42)
        (set! status 4)
        unit)
      (if (!= (wide-mask-probe (bit-or (shl 1 31) (shl 1 62))) 42)
        (set! status 5)
        unit)
      (if (!= (wide-mask-probe (- 0 1)) 42)
        (set! status 6)
        unit)
      (if (!= (wide-mask-probe 12345) 42)
        (set! status 7)
        unit)
      status)))

;; Both arms of both admitted mappings, asserted by outcome rather than by
;; count: an inverted jump sense turns each of these four into its opposite.
(define (jump-sense) : i64
  (cond
    [(!= (parity-set 1 0) 1) 1]
    [(!= (parity-set 2 0) 0) 2]
    [(!= (bit3-clear 8 0) 0) 3]
    [(!= (bit3-clear 7 0) 1) 4]
    [(!= (bit31-set 2147483648 0) 1) 5]
    [(!= (bit31-set 2147483647 0) 0) 6]
    [(!= (bit62-clear 4611686018427387904 0) 0) 7]
    [(!= (bit62-clear 4611686018427387903 0) 1) 8]
    [else 42]))

(define (main) : i64
  (cond
    [(!= (exhaustive-low-bits) 42) 1]
    [(!= (wide-masks) 42) 2]
    [(!= (jump-sense) 42) 3]
    [else 42]))