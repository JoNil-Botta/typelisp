;; Early-return guard flip (C40 SHRINKWRAP-FLIP).
;;
;; `weight` opens with two parameter guards that return without a frame. At
;; -O2 on Linux each guard falls through to the next guard and then into the
;; saving block, and both bare returns are placed after the function's last
;; block, so the framed path takes no branch. -Os, -O1 and Win64 keep the bare
;; returns inline ahead of the saving block.
;;
;; tests/codegen/asm-shape.d/c40-shrinkwrap-flip.cases pins that layout. The
;; result is 42 only if every guard still returns the right value.
(define (weight [a : i64] [b : i64] [c : i64] [d : i64]) : i64
  (if (>= a b)
    1
    (if (< c d)
      (+ (weight (+ a 1) b c d) (weight (+ a 2) b c d))
      0)))

(define (main) : i64
  (+ (weight 0 7 0 1) (weight 0 4 0 1) (weight 0 3 5 1)))