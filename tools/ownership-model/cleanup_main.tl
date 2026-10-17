;; Independent truth tables and concrete execution witnesses for cleanup.
(import cleanup_model as model)
(import cleanup_cases as cases)
(import stdlib.io)

(define (rejected-at? [outcome : model.Outcome] [index : i64]) : bool
  (match outcome
    [(model.Outcome.Rejected actual) (= actual index)]
    [_ false]))

(define (log-equal?
  [report : (& report model.Report)]
  [expected : (__tl_dyn-array i64)]) : bool
  (if (!= report.count (array-length expected))
    false
    (let
      [index : i64 0]
      (begin
        (while (< index report.count)
          (begin
            (unless
              (= (array-ref report.log index) (array-ref expected index))
              (return false))
            (set! index (+ index 1))))
        true))))

(define (accepted-log?
  [outcome : model.Outcome]
  [expected : (__tl_dyn-array i64)]
  [issued : i64]
  [exported : i64]) : bool
  (match outcome
    [(model.Outcome.Accepted report)
      (and
        (= report.issued issued)
        (= report.exported exported)
        (= report.issued (+ report.count report.exported))
        (log-equal? (& report) expected))]
    [_ false]))

(define (aborted-log?
  [outcome : model.Outcome]
  [expected : (__tl_dyn-array i64)]
  [issued : i64]) : bool
  (match outcome
    [(model.Outcome.Aborted report)
      (and
        (= report.issued issued)
        (= report.exported 0)
        (log-equal? (& report) expected))]
    [_ false]))

(define (direct-case? [manual : i64] [initial : i64] [code : i64]) : bool
  (let
    [outer : bool (!= (bit-and initial 1) 0)]
    [inner : bool (!= (bit-and initial 2) 0)]
    [setup : i64
      (+
        (if outer
          1
          0)
        (if inner
          1
          0))]
    [input : cases.Input (cases.direct-input manual initial code)]
    ;; A closed two-bit whole-owner truth table, separate from resource tokens,
    ;; field operations, registration arrays, and cleanup execution in the model.
    [valid : bool
      (match code
        [0 outer]
        [1 inner]
        [2 (and outer (not inner))]
        [3 (and inner (not outer))]
        [4 outer]
        [5 inner]
        [6 (not outer)]
        [7 (not inner)]
        [8 (and outer (!= (bit-and manual 1) 0))]
        [9 (and inner (!= (bit-and manual 2) 0))]
        [_ true])]
    [remaining : i64
      (match code
        [2 2]
        [3 1]
        [4 (bit-and initial 2)]
        [5 (bit-and initial 1)]
        [6 (bit-or initial 1)]
        [7 (bit-or initial 2)]
        [8 (bit-and initial 2)]
        [9 (bit-and initial 1)]
        [_ initial])]
    [registered : i64
      (match code
        [2 (bit-or initial 2)]
        [3 (bit-or initial 1)]
        [6 (bit-or initial 1)]
        [7 (bit-or initial 2)]
        [_ initial])]
    [issued : i64
      (*
        2
        (+
          setup
          (if (or (= code 6) (= code 7))
            1
            0)))]
    [exported : i64
      (if (or (= code 8) (= code 9))
        2
        0)]
    [outcome : model.Outcome (model.execute (& input.modes) (& input.trace))]
    (cond
      [(not valid) (rejected-at? outcome setup)]
      [(= code 10) (aborted-log? outcome (__tl_make-array i64 0) issued)]
      [(or
          (!= (bit-and manual remaining) 0)
          (!=
            (bit-and
              (bit-and registered (bit-xor manual 3))
              (bit-xor remaining 3))
            0))
        (rejected-at?
          outcome
          (if (or (= code 8) (= code 9) (= code 11))
            setup
            (+ setup 1)))]
      [else
        (match outcome
          [(model.Outcome.Accepted report)
            (and
              (= report.issued issued)
              (= report.exported exported)
              (= report.count (- issued exported)))]
          [_ false])])))

(define (direct-cases?) : bool
  (let
    [manual : i64 0]
    (begin
      (while (< manual 4)
        (let
          [initial : i64 0]
          (begin
            (while (< initial 4)
              (let
                [code : i64 0]
                (begin
                  (while (< code 12)
                    (begin
                      (unless
                        (direct-case? manual initial code)
                        (begin
                          (io.println
                            "ownership-cleanup-model direct mismatch: modes={} initial={} operation={}"
                            manual
                            initial
                            code)
                          (return false)))
                      (set! code (+ code 1))))
                  (set! initial (+ initial 1)))))
            (set! manual (+ manual 1)))))
      true)))

(define (controls?) : bool
  (let
    [automatic : (Array model.Mode 2)
      (array model.Mode.Automatic model.Mode.Automatic)]
    [manual : (Array model.Mode 2)
      (array model.Mode.Discharge model.Mode.Discharge)]
    [handoff : (Array model.Mode 2)
      (array model.Mode.Discharge model.Mode.Automatic)]
    [empty : (__tl_dyn-array model.Event) (__tl_make-array model.Event 0)]
    [partial : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.BeginConstruction model.Owner.Inner)
        (model.Event.MoveField
          model.Owner.Outer
          model.Field.Left
          model.Owner.Inner
          model.Field.Left)
        (model.Event.InitializeField model.Owner.Inner model.Field.Right)
        (model.Event.BindComplete model.Owner.Inner)
        (model.Event.InitializeField model.Owner.Outer model.Field.Left)
        model.Event.Exit)]
    [ordered : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Initialize model.Owner.Inner)
        model.Event.Exit)]
    [transfer : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Move model.Owner.Outer model.Owner.Inner)
        model.Event.Exit)]
    [missing-field : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.BeginConstruction model.Owner.Inner)
        (model.Event.MoveField
          model.Owner.Outer
          model.Field.Left
          model.Owner.Inner
          model.Field.Left)
        (model.Event.InitializeField model.Owner.Inner model.Field.Right)
        (model.Event.BindComplete model.Owner.Inner)
        model.Event.Exit)]
    [all-fields : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.BeginConstruction model.Owner.Inner)
        (model.Event.MoveField
          model.Owner.Outer
          model.Field.Left
          model.Owner.Inner
          model.Field.Left)
        (model.Event.MoveField
          model.Owner.Outer
          model.Field.Right
          model.Owner.Inner
          model.Field.Right)
        (model.Event.BindComplete model.Owner.Inner)
        model.Event.Exit)]
    [overwrite : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.InitializeField model.Owner.Outer model.Field.Left)
        model.Event.Exit)]
    [double : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Cleanup model.Owner.Outer)
        (model.Event.Cleanup model.Owner.Outer)
        model.Event.Exit)]
    [abort : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Initialize model.Owner.Inner)
        model.Event.Abort)]
    [cleanup-abort : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Initialize model.Owner.Inner)
        (model.Event.AbortCleanup model.Owner.Inner))]
    [late-failure : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        model.Event.Exit
        model.Event.Exit)]
    [discharged : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Cleanup model.Owner.Outer)
        model.Event.Exit)]
    [return : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Initialize model.Owner.Outer)
        (model.Event.Return model.Owner.Outer)
        model.Event.Exit)]
    (and
      (accepted-log?
        (model.execute (& automatic) (& ordered))
        (__tl_make-array 4 3 2 1)
        4
        0)
      (accepted-log?
        (model.execute (& automatic) (& partial))
        (__tl_make-array 3 1 2 4)
        4
        0)
      (accepted-log?
        (model.execute (& handoff) (& transfer))
        (__tl_make-array 2 1)
        2
        0)
      (rejected-at? (model.execute (& automatic) (& transfer)) 2)
      (rejected-at? (model.execute (& automatic) (& missing-field)) 5)
      (rejected-at? (model.execute (& automatic) (& all-fields)) 5)
      (rejected-at? (model.execute (& manual) (& partial)) 6)
      (rejected-at? (model.execute (& automatic) (& overwrite)) 1)
      (rejected-at? (model.execute (& manual) (& double)) 2)
      (aborted-log?
        (model.execute (& automatic) (& abort))
        (__tl_make-array i64 0)
        4)
      (aborted-log?
        (model.execute (& manual) (& abort))
        (__tl_make-array i64 0)
        4)
      (aborted-log?
        (model.execute (& automatic) (& cleanup-abort))
        (__tl_make-array 4)
        4)
      (accepted-log?
        (model.execute (& automatic) (& late-failure))
        (__tl_make-array 2 1)
        2
        0)
      (rejected-at? (model.execute (& automatic) (& discharged)) 2)
      (accepted-log?
        (model.execute (& manual) (& discharged))
        (__tl_make-array 2 1)
        2
        0)
      (accepted-log?
        (model.execute (& manual) (& return))
        (__tl_make-array i64 0)
        2
        2)
      (rejected-at? (model.execute (& automatic) (& return)) 1)
      (match (model.execute (& automatic) (& empty))
        [(model.Outcome.InvalidInput) true]
        [_ false]))))

(define (main) : i64
  (if (and (direct-cases?) (controls?) (construction-cases?) (bounds?))
    (begin
      (io.println
        "ownership-cleanup-model-v2: direct=192 controls=18 construction=30 bounds=2 passed")
      0)
    (begin
      (io.println "ownership-cleanup-model controls failed")
      1)))

;; An action's position is event*4 + owner*2 + field. Token identities are checked
;; against the separate exact resource log, not reconstructed by an adapter.
(define (accepted-actions?
  [outcome : model.Outcome]
  [tokens : (__tl_dyn-array i64)]
  [positions : (__tl_dyn-array i64)]
  [issued : i64]
  [exported : i64]) : bool
  (match outcome
    [(model.Outcome.Accepted report)
      (let
        [index : i64 0]
        (begin
          (unless
            (and
              (= report.issued issued)
              (= report.exported exported)
              (= report.issued (+ report.count report.exported))
              (= report.count (array-length positions))
              (= report.count (array-length report.actions))
              (log-equal? (& report) tokens))
            (return false))
          (while (< index report.count)
            (let
              [action : model.CleanupAction (array-ref report.actions index)]
              (begin
                (unless
                  (and
                    (= action.token (array-ref report.log index))
                    (=
                      (+
                        (* action.event 4)
                        (model.slot-index action.owner action.field))
                      (array-ref positions index)))
                  (return false))
                (set! index (+ index 1)))))
          true))]
    [_ false]))

(define (construction-case? [code : i64]) : bool
  (let
    [input : cases.Input (cases.control-input code)]
    [outcome : model.Outcome (model.execute (& input.modes) (& input.trace))]
    (match code
      [0
        (accepted-actions?
          outcome
          (__tl_make-array 4 3 2 1)
          (__tl_make-array 9 8 11 10)
          4
          0)]
      [1
        (accepted-actions?
          outcome
          (__tl_make-array 2 1 4 3 6 5)
          (__tl_make-array 9 8 19 18 17 16)
          6
          0)]
      [2 (rejected-at? outcome 3)]
      [3
        (accepted-actions?
          outcome
          (__tl_make-array 2 1)
          (__tl_make-array 13 12)
          2
          0)]
      [4 (rejected-at? outcome 2)]
      [5 (rejected-at? outcome 0)]
      [6 (rejected-at? outcome 2)]
      [7 (rejected-at? outcome 2)]
      [8
        (accepted-actions?
          outcome
          (__tl_make-array 2 4 3 1)
          (__tl_make-array 25 24 31 30)
          4
          0)]
      [9 (rejected-at? outcome 6)]
      [10 (aborted-log? outcome (__tl_make-array i64 0) 2)]
      [11
        (accepted-actions?
          outcome
          (__tl_make-array 2 1)
          (__tl_make-array 13 12)
          2
          0)]
      [12
        (accepted-actions? outcome (__tl_make-array 1) (__tl_make-array 8) 1 0)]
      [13 (aborted-log? outcome (__tl_make-array i64 0) 1)]
      [14 (rejected-at? outcome 3)]
      [15
        (accepted-actions?
          outcome
          (__tl_make-array 1 2 3)
          (__tl_make-array 4 13 12)
          3
          0)]
      [16 (rejected-at? outcome 3)]
      [17 (rejected-at? outcome 2)]
      [18
        (accepted-actions?
          outcome
          (__tl_make-array 2 1 4 3)
          (__tl_make-array 5 4 13 12)
          4
          0)]
      [19
        (accepted-actions?
          outcome
          (__tl_make-array 2 1)
          (__tl_make-array 19 18)
          2
          0)]
      [20
        (accepted-actions?
          outcome
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          2
          2)]
      [21 (rejected-at? outcome 2)]
      [22
        (accepted-actions?
          outcome
          (__tl_make-array 3 1 2 4)
          (__tl_make-array 27 26 25 24)
          4
          0)]
      [23 (rejected-at? outcome 5)]
      [24 (rejected-at? outcome 5)]
      [25
        (match outcome
          [(model.Outcome.Aborted report)
            (and
              (= report.issued 4)
              (= report.exported 0)
              (= report.count 1)
              (= (array-length report.actions) 1)
              (= (array-ref report.log 0) 4)
              (let
                [action : model.CleanupAction (array-ref report.actions 0)]
                (and
                  (= action.event 2)
                  (= action.token 4)
                  (= (model.slot-index action.owner action.field) 3))))]
          [_ false])]
      [26 (rejected-at? outcome 1)]
      [27 (rejected-at? outcome 1)]
      [28 (rejected-at? outcome 2)]
      [_
        (accepted-actions?
          outcome
          (__tl_make-array 4 3 6 5 2 1)
          (__tl_make-array 11 10 19 18 17 16)
          6
          0)])))

(define (construction-cases?) : bool
  (let
    [code : i64 0]
    (begin
      (while (< code (cases.control-count))
        (begin
          (unless
            (construction-case? code)
            (begin
              (io.println
                "ownership-cleanup-model construction mismatch: case={}"
                code)
              (return false)))
          (set! code (+ code 1))))
      true)))

(define (bounds?) : bool
  (let
    [modes : (Array model.Mode 2)
      (array model.Mode.Automatic model.Mode.Automatic)]
    [trace : (__tl_dyn-array model.Event) (__tl_make-array model.Event 128)]
    [oversized : (__tl_dyn-array model.Event) (__tl_make-array model.Event 129)]
    [tokens : (__tl_dyn-array i64) (__tl_make-array i64 63)]
    [positions : (__tl_dyn-array i64) (__tl_make-array i64 63)]
    [index : i64 0]
    (begin
      (set!
        (array-ref trace 0)
        (model.Event.BeginConstruction model.Owner.Outer))
      (while (< index 63)
        (begin
          (set!
            (array-ref trace (+ 1 (* index 2)))
            (model.Event.InitializeField model.Owner.Outer model.Field.Left))
          (set!
            (array-ref trace (+ 2 (* index 2)))
            (model.Event.CleanupField model.Owner.Outer model.Field.Left))
          (set! (array-ref tokens index) (+ index 1))
          (set! (array-ref positions index) (* 4 (+ 2 (* index 2))))
          (set! index (+ index 1))))
      (set! (array-ref trace 127) model.Event.Exit)
      (and
        (accepted-actions?
          (model.execute (& modes) (& trace))
          tokens
          positions
          63
          0)
        (match (model.execute (& modes) (& oversized))
          [(model.Outcome.InvalidInput) true]
          [_ false])))))