;; Independently specified outcomes for actual concrete-model source mutations.
;; No compiler imports and no abstract/production answer participates.
(import loan_model as model)
(import loan_cases as cases)
(import stdlib.io)
(import stdlib.iterator)

(define (rejects-at? [outcome : model.Outcome] [index : i64]) : bool
  (match outcome
    [(model.Outcome.Rejected actual) (= actual index)]
    [_ false]))

(define (accepts? [outcome : model.Outcome]) : bool
  (match outcome
    [(model.Outcome.Accepted true true) true]
    [_ false]))

(define (main) : i64
  (let
    [loans : (Array model.Loan 3)
      (array
        (model.Loan model.Cell.Whole true -1)
        (model.Loan model.Cell.Left false 0)
        (model.Loan model.Cell.Right false -1))]
    [shared-write : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 2)
        (model.Event.WriteThrough 2 model.Cell.Right))]
    [parent-retention : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Write model.Cell.Right)
        (model.Event.Keep 1))]
    [end-demand : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.End 0)
        (model.Event.Keep 1))]
    [expiry : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Keep 0)
        (model.Event.Write model.Cell.Whole))]
    [siblings : (Array model.Loan 3) (cases.witness-loans 0)]
    [sibling-trace : (__tl_dyn-array model.Event) (cases.witness-trace 0)]
    [chain : (Array model.Loan 3) (cases.witness-loans 4)]
    [chain-trace : (__tl_dyn-array model.Event) (cases.witness-trace 4)]
    (begin
      (unless
        (rejects-at? (model.execute (& loans) 3 (& shared-write) true true) 1)
        (begin
          (io.println "ownership-loan-model mutation mismatch: shared-write")
          (return 1)))
      (unless
        (rejects-at?
          (model.execute (& loans) 3 (& parent-retention) true true)
          2)
        (begin
          (io.println
            "ownership-loan-model mutation mismatch: parent-retention")
          (return 1)))
      (unless
        (rejects-at? (model.execute (& loans) 3 (& end-demand) true true) 2)
        (begin
          (io.println "ownership-loan-model mutation mismatch: end-demand")
          (return 1)))
      (unless
        (accepts? (model.execute (& loans) 3 (& expiry) true true))
        (begin
          (io.println "ownership-loan-model mutation mismatch: expiry")
          (return 1)))
      (unless
        (rejects-at?
          (model.execute (& siblings) 3 (& sibling-trace) true true)
          2)
        (begin
          (io.println "ownership-loan-model mutation mismatch: issue-conflict")
          (return 1)))
      (unless
        (rejects-at? (model.execute (& chain) 3 (& chain-trace) true true) 3)
        (begin
          (io.println
            "ownership-loan-model mutation mismatch: ancestor-retention")
          (return 1)))
      (for [index (iterator.range 0 2)]
        (let
          [mode : i64
            (if (= index 0)
              3
              7)]
          [program : model.ReferenceProgram (cases.reference-program mode)]
          [references : (Array model.Loan 3)
            (cases.reference-loans program.copy?)]
          (unless
            (rejects-at?
              (model.execute-references (& references) 1 (& program) true true)
              (if (= mode 3)
                4
                3))
            (io.println
              "ownership-loan-model mutation mismatch: reference-{}"
              (if (= mode 3)
                "copy"
                "move"))
            (return 1))))
      (let
        [program : model.ReferenceProgram (cases.reference-cfg-program 0 2)]
        [references : (Array model.Loan 3) (cases.reference-loans false)]
        (unless
          (rejects-at?
            (model.execute-references (& references) 2 (& program) true true)
            6)
          (io.println
            "ownership-loan-model mutation mismatch: reference-generation")
          (return 1)))
      (io.println "ownership-loan-model mutation controls passed")
      0)))