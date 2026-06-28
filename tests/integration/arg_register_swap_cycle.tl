(import "stdlib/io.tl")

;; Forces arg-register SWAP/cycle marshalling. A caller passes its own params to
;; the callee in swapped (2-cycle) and rotated (3-cycle) order, so the call must
;; produce %rdi<-arg_j, %rsi<-arg_i etc. where each source is another arg's
;; destination register. A naive sequential marshalling clobbers a source before
;; it is read and miscompiles the callee's inputs; a sound parallel move (cycle
;; break via a scratch) preserves them.
;;
;; Values come from (arg-count) so the optimizer cannot constant-fold the calls
;; away and must emit the real call + marshalling. This passes both before the
;; register-eligibility change (args marshalled from memory) and after (args
;; marshalled from registers through the parallel-move solver) -- a regression
;; guard on argument-value correctness.

(define (swap2-callee [x : i64] [y : i64]) : i64
  (- x y))

(define (swap2-caller [a : i64] [b : i64]) : i64
  (swap2-callee b a))

(define (swap3-callee [x : i64] [y : i64] [z : i64]) : i64
  (+ (* x 100) (+ (* y 10) z)))

(define (swap3-caller [a : i64] [b : i64] [c : i64]) : i64
  (swap3-callee c a b))

(define (main) : i64
  (let
    [n : i64 (arg-count)]
    [r2 : i64 (swap2-caller (* n 50) (* n 8))]
    [r3 : i64 (swap3-caller (* n 1) (* n 2) (* n 3))]
    (if (and (= r2 (- 0 42)) (= r3 312))
      42
      1)))
