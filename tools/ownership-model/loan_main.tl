;; Standalone controls for concrete loan executions. No compiler imports.
(import loan_model as model)
(import loan_cases as cases)
(import stdlib.io)

(define (accepted? [result : model.Outcome]) : bool
  (match result
    [(model.Outcome.Accepted _ _) true]
    [_ false]))

(define (rejected-at? [result : model.Outcome] [index : i64]) : bool
  (match result
    [(model.Outcome.Rejected actual) (= actual index)]
    [_ false]))

(define (cell [index : i64]) : model.Cell
  (match index
    [0 model.Cell.Whole]
    [1 model.Cell.Left]
    [_ model.Cell.Right]))

(define (operation [index : i64] [place : model.Cell]) : model.Event
  (match index
    [0 (model.Event.Read place)]
    [1 (model.Event.Write place)]
    [2 (model.Event.Consume place)]
    [_ (model.Event.Invalidate place)]))

(define (initialized? [initial : i64] [place : i64]) : bool
  (match place
    [0 (= initial 3)]
    [1 (!= (bit-and initial 1) 0)]
    [_ (!= (bit-and initial 2) 0)]))

;; An explicit truth table for one borrow followed by a direct access. If the
;; capability has no later use it ends before that access. Shared capabilities
;; coexist with reads; exclusive capabilities and writes require disjoint cells.
(define (single-expected?
  [initial : i64]
  [exclusive : bool]
  [borrowed : i64]
  [accessed : i64]
  [action : i64]
  [retained : bool]) : bool
  (and
    (initialized? initial borrowed)
    (or (= action 1) (= action 3) (initialized? initial accessed))
    (or
      (not retained)
      (and (not exclusive) (= action 0))
      (and (> borrowed 0) (> accessed 0) (!= borrowed accessed)))))

(define (single-case?
  [initial : i64]
  [exclusive : bool]
  [borrowed : i64]
  [accessed : i64]
  [action : i64]
  [retained : bool]) : bool
  (let
    [loans : (Array model.Loan 3)
      (array
        (model.Loan (cell borrowed) exclusive (- 0 1))
        (model.Loan model.Cell.Left false (- 0 1))
        (model.Loan model.Cell.Right false (- 0 1)))]
    [trace : (__tl_dyn-array model.Event)
      (if retained
        (__tl_make-array
          (model.Event.Borrow 0)
          (operation action (cell accessed))
          (model.Event.Keep 0))
        (__tl_make-array
          (model.Event.Borrow 0)
          (operation action (cell accessed))))]
    [actual : bool
      (accepted?
        (model.execute
          (& loans)
          1
          (& trace)
          (initialized? initial 1)
          (initialized? initial 2)))]
    [expected : bool
      (single-expected? initial exclusive borrowed accessed action retained)]
    (begin
      (unless
        (= actual expected)
        (io.println
          "loan model mismatch: initial={} exclusive={} borrowed={} accessed={} action={} retained={}"
          initial
          exclusive
          borrowed
          accessed
          action
          retained))
      (= actual expected))))

(define (single-cases?) : bool
  (let
    [code : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< code 576))
        (let
          [n : i64 code]
          [initial : i64 (% n 4)]
          [exclusive : bool (= (% (/ n 4) 2) 1)]
          [borrowed : i64 (% (/ n 8) 3)]
          [accessed : i64 (% (/ n 24) 3)]
          [action : i64 (% (/ n 72) 4)]
          [retained : bool (= (/ n 288) 1)]
          (set!
            ok
            (with-arena
              scratch
              (single-case? initial exclusive borrowed accessed action retained))))
        (set! code (+ code 1)))
      (and ok (= code 576)))))

(define (reborrow-controls?) : bool
  (let
    [loans : (Array model.Loan 3)
      (array
        (model.Loan model.Cell.Whole true (- 0 1))
        (model.Loan model.Cell.Left false 0)
        (model.Loan model.Cell.Right true 0))]
    [read-shared : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.ReadThrough 0 model.Cell.Left)
        (model.Event.Keep 1))]
    [write-shared : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.WriteThrough 0 model.Cell.Left)
        (model.Event.Keep 1))]
    [disjoint : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 2)
        (model.Event.WriteThrough 0 model.Cell.Left)
        (model.Event.Keep 2))]
    [premature-end : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.End 0)
        (model.Event.Keep 1))]
    [ended-child : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.End 1)
        (model.Event.WriteThrough 0 model.Cell.Left))]
    [new-iteration : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Keep 0)
        (model.Event.Borrow 0)
        (model.Event.Keep 0))]
    [retained-old-child : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Borrow 0)
        (model.Event.Keep 1))]
    ;; With a shared parent, the second issue joins the token the old child
    ;; still retains; a write under both then conflicts.
    [shared-loans : (Array model.Loan 3)
      (array
        (model.Loan model.Cell.Whole false (- 0 1))
        (model.Loan model.Cell.Left false 0)
        (model.Loan model.Cell.Right true 0))]
    [shared-old-child : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Borrow 0)
        (model.Event.Keep 1)
        (model.Event.Keep 0))]
    [shared-old-child-write : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Borrow 0)
        (model.Event.Write model.Cell.Right)
        (model.Event.Keep 1))]
    [outside : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.ReadThrough 1 model.Cell.Right))]
    [before : (__tl_dyn-array model.Event)
      (__tl_make-array (model.Event.Keep 0))]
    [after : (__tl_dyn-array model.Event)
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.End 0)
        (model.Event.Keep 0))]
    [invalid : (__tl_dyn-array model.Event)
      (__tl_make-array (model.Event.Borrow (- 0 1)))]
    (and
      (accepted? (model.execute (& loans) 3 (& read-shared) true true))
      (rejected-at? (model.execute (& loans) 3 (& write-shared) true true) 2)
      (accepted? (model.execute (& loans) 3 (& disjoint) true true))
      (rejected-at? (model.execute (& loans) 3 (& premature-end) true true) 2)
      (accepted? (model.execute (& loans) 3 (& ended-child) true true))
      (accepted? (model.execute (& loans) 3 (& new-iteration) true true))
      (rejected-at?
        (model.execute (& loans) 3 (& retained-old-child) true true)
        2)
      (accepted?
        (model.execute (& shared-loans) 3 (& shared-old-child) true true))
      (rejected-at?
        (model.execute (& shared-loans) 3 (& shared-old-child-write) true true)
        3)
      (rejected-at? (model.execute (& loans) 3 (& outside) true true) 2)
      (rejected-at? (model.execute (& loans) 3 (& before) true true) 0)
      (rejected-at? (model.execute (& loans) 3 (& after) true true) 1)
      (match (model.execute (& loans) 3 (& invalid) true true)
        [(model.Outcome.InvalidInput) true]
        [_ false]))))

(define (three-controls?) : bool
  (let
    [mode : i64 0]
    (begin
      (while (< mode 8)
        (let
          [loans : (Array model.Loan 3) (cases.witness-loans mode)]
          [trace : (__tl_dyn-array model.Event) (cases.witness-trace mode)]
          [result : model.Outcome
            (model.execute (& loans) 3 (& trace) true true)]
          [ok? : bool
            (match mode
              [0 (rejected-at? result 2)]
              [2 (rejected-at? result 1)]
              [4 (rejected-at? result 3)]
              [_ (accepted? result)])]
          (begin
            (unless
              ok?
              (begin
                (io.println
                  "ownership-loan-model three-loan mismatch: mode={}"
                  mode)
                (return false)))
            (set! mode (+ mode 1)))))
      true)))

(define (main) : i64
  (if (and (single-cases?) (reborrow-controls?) (three-controls?))
    (begin
      (io.println
        "ownership-loan-model-v1: direct=576 reborrow=13 three=8 passed")
      0)
    1))