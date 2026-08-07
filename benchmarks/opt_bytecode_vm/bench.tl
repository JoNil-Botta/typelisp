;# benchmarks/opt_bytecode_vm/bench.tl - stack bytecode interpreter workload.
;#
;# Equivalent to benchmarks/opt_bytecode_vm/baseline.c. Builds a small fixed
;# stack-machine program once, then runs it many rounds with a round-dependent
;# input and folds each run's result into a wrapping accumulator. Exercises enum
;# `match` with a payload-carrying variant, a fetch/dispatch loop over an
;# fixed `(Array Inst 9)`, and stack pushes/pops over a fixed
;# `(Array i64 2)` scratch buffer (the program's maximum stack depth). All values are
;# reduced modulo a prime so they stay non-negative and the printed decimal
;# matches the C baseline. The round count is a runtime argument.
(import stdlib.io)
(import stdlib.string)

(define vm-prime : i64
  1000000007)

(defenum Inst
  (PushInput)
  (PushConst i64)
  (Dup)
  (AddOp)
  (MulOp)
  (XorOp))

(define (vm-build-program) : (Array Inst 9)
  (array
    (PushInput)
    (PushConst 1000003)
    (MulOp)
    (PushConst 98765)
    (AddOp)
    (Dup)
    (MulOp)
    (PushConst 54321)
    (XorOp)))

(define (vm-bench [rounds : i64]) : i64
  (let
    [program : (Array Inst 9) (vm-build-program)]
    [stack : (Array i64 2) (array 0 0)]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (while (< round rounds)
        (begin
          (let
            [input : i64 (% (+ (* round 2654435761) 12345) vm-prime)]
            [pc : i64 0]
            [sp : i64 0]
            (begin
              (while (< pc 9)
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
              (set! acc (% (+ acc (array-ref stack 0)) vm-prime))))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [rounds : i64 (string.>int (io.arg 1))]
    (begin
      (io.print (vm-bench rounds))
      0)))