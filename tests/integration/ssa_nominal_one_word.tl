;; A fieldless enum is a nominal one-word value. Keep both a diamond mutation
;; and a loop-carried mutation executable so representation-aware SSA cannot
;; regress to accepting the IR shape while mis-typing its inserted phis/copies.
(defenum SsaNominalState
  (Zero)
  (One)
  (Answer))

(define (ssa-nominal-score [state : SsaNominalState]) : i64
  (match state
    [(SsaNominalState.Zero) 0]
    [(SsaNominalState.One) 1]
    [(SsaNominalState.Answer) 42]))

(define (ssa-nominal-diamond [cond : bool]) : SsaNominalState
  (let
    [state : SsaNominalState SsaNominalState.Zero]
    (begin
      (if cond
        (set! state SsaNominalState.Answer)
        (set! state SsaNominalState.One))
      state)))

(define (ssa-nominal-loop [count : i64]) : SsaNominalState
  (let
    [state : SsaNominalState SsaNominalState.Zero]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (if (= index 4)
            (set! state SsaNominalState.Answer)
            (set! state SsaNominalState.One))
          (set! index (+ index 1))))
      state)))

(define (main) : i64
  (if (and
    (= (ssa-nominal-score (ssa-nominal-diamond true)) 42)
    (= (ssa-nominal-score (ssa-nominal-diamond false)) 1)
    (= (ssa-nominal-score (ssa-nominal-loop 5)) 42)
    (= (ssa-nominal-score (ssa-nominal-loop 4)) 1))
    42
    1))