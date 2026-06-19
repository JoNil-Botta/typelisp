;# benchmarks/opt_bytecode_vm/bench.tl - stack bytecode interpreter workload.
;#
;# Equivalent to benchmarks/opt_bytecode_vm/baseline.c. Builds a small fixed
;# stack-machine program once, then runs it many rounds with a round-dependent
;# input and folds each run's result into a wrapping accumulator. Exercises enum
;# `match` with a payload-carrying variant, a fetch/dispatch loop over an
;# `(Array Inst)`, and stack pushes/pops over an `(Array i64)`. All values are
;# reduced modulo a prime so they stay non-negative and the printed decimal
;# matches the C baseline. The round count is a runtime argument.
(import "stdlib/io.tl")

(define vm-prime : i64
  1000000007)

(defenum Inst
  (PushInput)
  (PushConst i64)
  (Dup)
  (AddOp)
  (MulOp)
  (XorOp))

(define (vm-build-program) : (Array Inst)
  (let
    [program : (Array Inst) (make-array Inst 9)]
    (begin
      (array-set! program 0 (PushInput))
      (array-set! program 1 (PushConst 1000003))
      (array-set! program 2 (MulOp))
      (array-set! program 3 (PushConst 98765))
      (array-set! program 4 (AddOp))
      (array-set! program 5 (Dup))
      (array-set! program 6 (MulOp))
      (array-set! program 7 (PushConst 54321))
      (array-set! program 8 (XorOp))
      program)))

(define (vm-run
  [program : (Array Inst)]
  [plen : i64]
  [stack : (Array i64)]
  [input : i64]) : i64
  (let
    [pc : i64 0]
    [sp : i64 0]
    (begin
      (while (< pc plen)
        (begin
          (match (array-ref program pc)
            [(PushInput)
              (begin
                (array-set! stack sp input)
                (set! sp (+ sp 1)))]
            [(PushConst value)
              (begin
                (array-set! stack sp value)
                (set! sp (+ sp 1)))]
            [(Dup)
              (begin
                (array-set! stack sp (array-ref stack (- sp 1)))
                (set! sp (+ sp 1)))]
            [(AddOp)
              (let
                [b : i64 (array-ref stack (- sp 1))]
                [a : i64 (array-ref stack (- sp 2))]
                (begin
                  (array-set! stack (- sp 2) (% (+ a b) vm-prime))
                  (set! sp (- sp 1))))]
            [(MulOp)
              (let
                [b : i64 (array-ref stack (- sp 1))]
                [a : i64 (array-ref stack (- sp 2))]
                (begin
                  (array-set! stack (- sp 2) (% (* a b) vm-prime))
                  (set! sp (- sp 1))))]
            [(XorOp)
              (let
                [b : i64 (array-ref stack (- sp 1))]
                [a : i64 (array-ref stack (- sp 2))]
                (begin
                  (array-set! stack (- sp 2) (% (bit-xor a b) vm-prime))
                  (set! sp (- sp 1))))])
          (set! pc (+ pc 1))))
      (array-ref stack 0))))

(define (vm-bench [rounds : i64]) : i64
  (let
    [program : (Array Inst) (vm-build-program)]
    [plen : i64 (array-length program)]
    [stack : (Array i64) (make-array i64 64)]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (while (< round rounds)
        (begin
          (let
            [input : i64 (% (+ (* round 2654435761) 12345) vm-prime)]
            (set! acc (% (+ acc (vm-run program plen stack input)) vm-prime)))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [rounds : i64 (string->int (arg 1))]
    (begin
      (print (vm-bench rounds))
      0)))