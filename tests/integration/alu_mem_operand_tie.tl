;; FORCING TEST for GAP8-C: the two-address destination of a COMMUTATIVE BinOp
;; whose LHS is a single-use fused `gep; load` must tie to the OTHER operand.
;;
;; `(bit-and (array-ref a i) acc)` is that shape exactly: the element load is
;; single-use and sits on the LHS, `acc` is the loop-carried accumulator on the
;; RHS. The backend folds the commuted order (`dst = MEM op x` is `dst = x op
;; MEM`), but the fold only pays when the destination's home IS the accumulator's
;; home, because it stages the non-loaded operand there first. Tie to the LHS
;; instead and every iteration pays a staging copy, with the accumulator
;; ping-ponging between two registers:
;;
;;     movq %rACC, %rT
;;     andq (%rA,%rI,8), %rT
;;     movq %rT, %rACC2
;;     orq  (%rB,%rI,8), %rACC2
;;
;; With the RHS preference the staging `mov` self-elides and the load is gone:
;;
;;     andq (%rA,%rI,8), %rACC
;;     orq  (%rB,%rI,8), %rACC
;;
;; Four different arrays, one op each: four reads of ONE element would be CSE'd
;; into a multi-use load, which retires the fold (and so must retire the tie).
;;
;; A wrong tie is still CORRECT code, only slower, so the exit code cannot catch
;; it; scripts/verify-asm-shape-gates.sh asserts the shape over the bounds-check-
;; eliminated fast body. The two call sites keep `fold-words` out of line.
(define (fold-words
  [a : (Array i64)]
  [b : (Array i64)]
  [c : (Array i64)]
  [d : (Array i64)]
  [seed : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 seed]
    (begin
      (while (< i (array-length a))
        (begin
          (set! acc (bit-and (array-ref a i) acc))
          (set! acc (bit-or (array-ref b i) acc))
          (set! acc (bit-xor (array-ref c i) acc))
          (set! acc (+ (array-ref d i) acc))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 8)]
    [b : (Array i64) (make-array i64 8)]
    [c : (Array i64) (make-array i64 8)]
    [d : (Array i64) (make-array i64 8)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref a i) -1)
          (set! i (+ i 1))))
      (if (= (fold-words a b c d -1) -1)
        (if (= (fold-words a b c d 0) 0)
          42
          1)
        1))))