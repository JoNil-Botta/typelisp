;; Fixed semantic witnesses for actual independent cleanup-model mutations.
(import cleanup_model as model)
(import cleanup_cases as cases)
(import stdlib.io)

(define (rejects-at? [outcome : model.Outcome] [index : i64]) : bool
  (match outcome
    [(model.Outcome.Rejected actual) (= actual index)]
    [_ false]))

(define (ordered? [outcome : model.Outcome]) : bool
  (match outcome
    [(model.Outcome.Accepted report)
      (and
        (= report.count 4)
        (= report.issued 4)
        (= report.exported 0)
        (= (array-ref report.log 0) 4)
        (= (array-ref report.log 1) 3)
        (= (array-ref report.log 2) 2)
        (= (array-ref report.log 3) 1))]
    [_ false]))

(define (main) : i64
  (let
    [automatic : (Array model.Mode 2)
      (array model.Mode.Automatic model.Mode.Automatic)]
    [manual : (Array model.Mode 2)
      (array model.Mode.Discharge model.Mode.Discharge)]
    [required : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Cleanup model.Owner.Outer)
        model.Event.Exit)]
    [ordered : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Initialize model.Owner.Inner)
        model.Event.Exit)]
    [overwrite : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.InitializeField model.Owner.Outer model.Field.Left)
        (model.Event.Cleanup model.Owner.Outer)
        model.Event.Exit)]
    [partial : cases.Input (cases.control-input 9)]
    [reverse-order : cases.Input (cases.control-input 0)]
    [building-leak : cases.Input (cases.control-input 2)]
    [unbound-complete : cases.Input (cases.control-input 14)]
    (begin
      (unless
        (rejects-at? (model.execute (& automatic) (& required)) 2)
        (begin
          (io.println
            "ownership-cleanup-model mutation mismatch: required-exit")
          (return 1)))
      (unless
        (ordered? (model.execute (& automatic) (& ordered)))
        (begin
          (io.println
            "ownership-cleanup-model mutation mismatch: cleanup-order")
          (return 1)))
      (unless
        (rejects-at? (model.execute (& manual) (& overwrite)) 1)
        (begin
          (io.println
            "ownership-cleanup-model mutation mismatch: live-overwrite")
          (return 1)))
      (unless
        (ordered?
          (model.execute (& reverse-order.modes) (& reverse-order.trace)))
        (begin
          (io.println
            "ownership-cleanup-model mutation mismatch: activation-order")
          (return 1)))
      (unless
        (rejects-at?
          (model.execute (& building-leak.modes) (& building-leak.trace))
          3)
        (begin
          (io.println
            "ownership-cleanup-model mutation mismatch: construction-leak")
          (return 1)))
      (unless
        (rejects-at?
          (model.execute (& unbound-complete.modes) (& unbound-complete.trace))
          3)
        (begin
          (io.println
            "ownership-cleanup-model mutation mismatch: premature-activation")
          (return 1)))
      (unless
        (rejects-at? (model.execute (& partial.modes) (& partial.trace)) 6)
        (begin
          (io.println
            "ownership-cleanup-model mutation mismatch: partial-discharge")
          (return 1)))
      (io.println "ownership-cleanup-model mutation controls passed")
      0)))