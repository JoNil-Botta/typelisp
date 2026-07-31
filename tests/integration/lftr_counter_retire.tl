;; FORCING TEST for LFTR: linear-function test replacement.
;;
;; `walk` is the bytecode-dispatch shape. Induction strength-reduces
;; `(array-ref prog i)` into a pointer phi that steps one 16-byte `Step` per
;; iteration, after which the counter `i` has exactly two readers left: its own
;; `i + 1` latch increment and the `i < n` exit test. LFTR must retire it, so
;; the latch keeps one pointer bump and one compare against an end address
;; materialised in the preheader instead of also carrying the counter.
;;
;; The runtime check guards reconstruction: an off-by-one in the rewritten end
;; address either drops the last element (wrong product) or walks past the
;; array (OOB abort or garbage opcode) -- either way not 42.
;; scripts/verify-asm-shape-gates.sh additionally pins the asm shape: the
;; retired counter is the only `add $1` the loop would emit, because `acc`
;; folds by register add/multiply.
(defenum Step
  (Add i64)
  (Mul i64))

;; Built behind a call so the element payloads stay opaque to the walk loop and
;; the length remains a runtime descriptor load.
(define (build-program) : (__tl_dyn-array Step)
  (make-array (Add 2) (Mul 3) (Add 4) (Mul 5)))

(define (walk [prog : (__tl_dyn-array Step)]) : i64
  (let
    [n : i64 (array-length prog)]
    [i : i64 0]
    [acc : i64 1]
    (begin
      (while (< i n)
        (begin
          (match (array-ref prog i)
            [(Add value) (set! acc (+ acc value))]
            [(Mul value) (set! acc (* acc value))])
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [prog : (__tl_dyn-array Step) (build-program)]
    [r : i64 (walk prog)]
    ;; ((1 + 2) * 3 + 4) * 5 = 65
    (if (= r 65)
      42
      1)))