;; Runtime twin for the multiblock inliner's DIRECT tail-call admission (the
;; `TailCall` arm of opt-inline-multiblock-instr-ok?).
;;
;; `tc-absorbed` is referenced from exactly one place -- `tc-value` -- so the
;; multiblock gate absorbs its whole body there. One of its arms ends in
;; `(tc-step n k)`, which the lowerer emits as a `TailCall`, and a tail call
;; inside an INLINED body is no longer a tail call of the caller: it has to come
;; back to the call site's continuation. The clone converts it into an ordinary
;; call plus the continuation wiring every `Return` in the same body already
;; gets.
;;
;; `tc-open-coded` is the identical computation written out at the call site, so
;; it never crosses an inline boundary. The two have to agree on every input:
;; the inputs that take the converted arm, the inputs that take the ordinary
;; `return` arms beside it, and the inputs that take neither.
;;
;; `tc-unit-absorbed` covers the same conversion where the tail call returns
;; unit and its only effect is a global write: the merged caller must still
;; perform the call, exactly once per visit, in the same order.
(define tc-log : i64
  0)

(define (tc-bump! [d : i64]) : unit
  (set! tc-log (+ tc-log d)))

(define (tc-step [n : i64] [k : i64]) : i64
  (+ (* n 3) k))

;; Three distinct exits: a tail call, a plain return, and a second plain
;; return. Mis-wiring the converted arm into the wrong continuation input
;; shows up as one of the other two answers.
(define (tc-absorbed [n : i64] [k : i64]) : i64
  (if (> n 0)
    (if (< n 10)
      (tc-step n k)
      (+ (* n 100) k))
    (- 0 7)))

(define (tc-open-coded [n : i64] [k : i64]) : i64
  (if (> n 0)
    (if (< n 10)
      (+ (* n 3) k)
      (+ (* n 100) k))
    (- 0 7)))

;; The one and only reference to `tc-absorbed`, so the absorption is not a
;; matter of how many times `main` happens to ask. The result is bound before
;; being returned so this site stays an ordinary call: the multiblock rewrite
;; fires on `Call`, and a tail call site is not one.
(define (tc-value [n : i64] [k : i64]) : i64
  (let
    [result : i64 (tc-absorbed n k)]
    result))

(define (tc-unit-absorbed [n : i64]) : unit
  (if (> n 0)
    (tc-bump! n)
    (tc-bump! 1000)))

(define (tc-unit-value [n : i64]) : unit
  (let
    [done : unit (tc-unit-absorbed n)]
    done))

(define (main) : i64
  (let
    [i : i64 (- 0 3)]
    [bad : i64 0]
    [expected-log : i64 0]
    (begin
      (while (<= i 20)
        (begin
          (unless (= (tc-value i 5) (tc-open-coded i 5)) (set! bad (+ bad 1)))
          (unless
            (= (tc-value i (- 0 4)) (tc-open-coded i (- 0 4)))
            (set! bad (+ bad 1)))
          (tc-unit-value i)
          (set!
            expected-log
            (+
              expected-log
              (if (> i 0)
                i
                1000)))
          (set! i (+ i 1))))
      (cond
        [(not (= bad 0)) 1]
        [(not (= tc-log expected-log)) 2]
        ;; The converted arm really is the one under test: 4 -> 3*4+5 = 17.
        [(not (= (tc-value 4 5) 17)) 3]
        [(not (= (tc-value 40 5) 4005)) 4]
        [(not (= (tc-value 0 5) (- 0 7))) 5]
        [else 42]))))