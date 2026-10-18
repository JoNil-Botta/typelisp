;; refs #8750: a borrow of a global outlives every local scope but keeps the
;; global's own lifetime. It does not widen to `program`, which would stop it
;; counting as a loan of the global.
(defstruct GlobalLetProgramRec
  (value i64))

(define widened : GlobalLetProgramRec
  (GlobalLetProgramRec 42))

(define (global-let-program) : i64
  (let
    [r : (& program GlobalLetProgramRec) (& widened)]
    r.value))

(define (main) : i64
  (global-let-program))