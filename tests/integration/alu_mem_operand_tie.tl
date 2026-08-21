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
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [c : (__tl_dyn-array i64)]
  [d : (__tl_dyn-array i64)]
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

;; The UNFORCED spelling of the same four folds, and the forcing test for the
;; `load_sink` scheduling pass. Written as ONE nested expression, source
;; evaluation order lowers all four element reads FIRST and the four ALU ops
;; after, so only the innermost op's load is adjacent to its consumer and only
;; that one fold fires -- the backend's memory-operand probes all read the
;; instruction at `load index + 1`. `load_sink` moves each single-use `gep;
;; load` pair down to the slot before ITS consumer, and all four fold again.
;;
;; This is benchmarks/liveness_scan's flagship loop shape (a `bit-or` over a
;; `bit-and` over a `bit-xor`, each with a fresh element read on one side and
;; the running value on the other), one op wider.
(define (fold-nested
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [c : (__tl_dyn-array i64)]
  [d : (__tl_dyn-array i64)]
  [seed : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 seed]
    (begin
      (while (< i (array-length a))
        (begin
          (set!
            acc
            (bit-or
              (array-ref d i)
              (bit-and
                (array-ref c i)
                (bit-xor (array-ref b i) (bit-and (array-ref a i) acc)))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [c : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [d : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref a i) -1)
          (set! i (+ i 1))))
      (unless (= (fold-words a b c d -1) -1) (return 1))
      (unless (= (fold-words a b c d 0) 0) (return 1))
      (unless (= (fold-nested a b c d -1) 0) (return 1))
      (unless (= (fold-nested a b c d 0) 0) (return 1))
      42)))