;; Representation adapter only. Every expected decision comes from the
;; independent dynamic-token trace interpreter in loan_model.tl.
(import loan_model as model)
(import loan_main as controls)
(import loan_cases as cases)
(import compiler_ownership_core as core)
(import stdlib.io)
(import stdlib.string)

(define (loan-cross-id) : core.OwnershipBodyId
  (core.OwnershipBodyId (cast 8449 : u64) (cast 2 : u64) (cast 1 : u64)))

(define (loan-cross-type [id : i64]) : core.OwnershipTypeId
  (core.OwnershipTypeId (loan-cross-id) id))

(define (loan-cross-place [id : i64]) : core.OwnershipPlaceId
  (core.OwnershipPlaceId (loan-cross-id) id))

(define (loan-cross-block [id : i64]) : core.OwnershipBlockId
  (core.OwnershipBlockId (loan-cross-id) id))

(define (loan-cross-loan [id : i64]) : core.OwnershipLoanId
  (core.OwnershipLoanId (loan-cross-id) id))

(define (loan-cross-source [line : i64]) : core.OwnershipSource
  (core.OwnershipSource "loan-model-case.tl" line 1 "concrete loan trace"))

(define (loan-cross-cell [cell : model.Cell]) : i64
  (match cell
    [(model.Cell.Whole) 0]
    [(model.Cell.Left) 1]
    [(model.Cell.Right) 2]))

(define (loan-cross-event
  [body-id : core.OwnershipBodyId]
  [event : model.Event]) : core.OwnershipOperation
  (match event
    [(model.Event.Read cell)
      (core.OwnershipOperation.Read
        (core.OwnershipPlaceId body-id (loan-cross-cell cell)))]
    [(model.Event.Write cell)
      (core.OwnershipOperation.Assign
        (core.OwnershipPlaceId body-id (loan-cross-cell cell)))]
    [(model.Event.Consume cell)
      (core.OwnershipOperation.Consume
        (core.OwnershipPlaceId body-id (loan-cross-cell cell)))]
    [(model.Event.Invalidate cell)
      (core.OwnershipOperation.Invalidate
        (core.OwnershipPlaceId body-id (loan-cross-cell cell)))]
    [(model.Event.Borrow id)
      (core.OwnershipOperation.Borrow (core.OwnershipLoanId body-id id))]
    [(model.Event.Reborrow id)
      (core.OwnershipOperation.Reborrow (core.OwnershipLoanId body-id id))]
    [(model.Event.Keep id)
      (core.OwnershipOperation.UseLoan (core.OwnershipLoanId body-id id))]
    [(model.Event.MayKeep id)
      ;; The traces have no Copy or Move, so no holder is ever overwritten
      ;; and the demand behaves as a plain one.
      (core.OwnershipOperation.MayUseLoan
        (core.OwnershipLoanId body-id id)
        (core.OwnershipPlaceId body-id 0))]
    [(model.Event.ReadThrough id cell)
      (core.OwnershipOperation.AccessThrough
        (core.OwnershipLoanId body-id id)
        (core.OwnershipPlaceId body-id (loan-cross-cell cell))
        core.OwnershipAccess.Read)]
    [(model.Event.WriteThrough id cell)
      (core.OwnershipOperation.AccessThrough
        (core.OwnershipLoanId body-id id)
        (core.OwnershipPlaceId body-id (loan-cross-cell cell))
        core.OwnershipAccess.Write)]
    [(model.Event.End id)
      (core.OwnershipOperation.EndLoan (core.OwnershipLoanId body-id id))]))

(define (loan-cross-instructions
  [trace : (& trace (__tl_dyn-array model.Event))]
  [initial : i64]
  [prefix? : bool]) : (__tl_dyn-array core.OwnershipInstruction)
  (let
    [prefix : i64
      (if prefix?
        2
        0)]
    [out : (__tl_dyn-array core.OwnershipInstruction)
      (__tl_make-array
        core.OwnershipInstruction
        (+ prefix (array-length trace)))]
    [i : i64 0]
    (begin
      (while (< i prefix)
        (begin
          (set!
            (array-ref out i)
            (core.OwnershipInstruction
              (if (!= (bit-and initial (shl 1 i)) 0)
                (core.OwnershipOperation.Assign (loan-cross-place (+ i 1)))
                (core.OwnershipOperation.Invalidate (loan-cross-place (+ i 1))))
              (loan-cross-source (+ i 1))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i (array-length trace))
        (begin
          (set!
            (array-ref out (+ prefix i))
            (core.OwnershipInstruction
              (loan-cross-event (loan-cross-id) (array-ref trace i))
              (loan-cross-source (+ i 10))))
          (set! i (+ i 1))))
      out)))

(define (loan-cross-body
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [blocks : (__tl_dyn-array core.OwnershipBlock)]) : core.OwnershipBody
  (let
    [locals : (__tl_dyn-array core.OwnershipLocal)
      (__tl_make-array core.OwnershipLocal 2)]
    [records : (__tl_dyn-array core.OwnershipLoan)
      (__tl_make-array core.OwnershipLoan count)]
    [i : i64 0]
    (begin
      (set!
        (array-ref locals 0)
        (core.OwnershipLocal (loan-cross-type 2) false (loan-cross-source 1)))
      (set!
        (array-ref locals 1)
        (core.OwnershipLocal (loan-cross-type 1) true (loan-cross-source 1)))
      (while (< i count)
        (begin
          (set!
            (array-ref records i)
            (core.OwnershipLoan
              (loan-cross-place (loan-cross-cell (array-ref loans i).cell))
              (if (array-ref loans i).exclusive
                core.OwnershipLoanKind.Exclusive
                core.OwnershipLoanKind.Shared)
              (if (< (array-ref loans i).parent 0)
                core.OwnershipLoanOrigin.Direct
                (core.OwnershipLoanOrigin.Parent
                  (loan-cross-loan (array-ref loans i).parent)))
              (loan-cross-source (+ i 3))))
          (set! i (+ i 1))))
      (core.OwnershipBody
        (loan-cross-id)
        (__tl_make-array
          (core.OwnershipType core.OwnershipTypeKind.Scalar false)
          (core.OwnershipType core.OwnershipTypeKind.Boolean true)
          (core.OwnershipType
            (core.OwnershipTypeKind.Product
              (core.OwnershipTypeIds
                (__tl_make-array (loan-cross-type 0) (loan-cross-type 0))))
            false))
        locals
        (__tl_make-array
          (core.OwnershipPlace
            (core.OwnershipLocalId (loan-cross-id) 0)
            (loan-cross-type 2)
            core.OwnershipProjection.Root
            (loan-cross-source 1))
          (core.OwnershipPlace
            (core.OwnershipLocalId (loan-cross-id) 0)
            (loan-cross-type 0)
            (core.OwnershipProjection.Field (loan-cross-place 0) 0)
            (loan-cross-source 1))
          (core.OwnershipPlace
            (core.OwnershipLocalId (loan-cross-id) 0)
            (loan-cross-type 0)
            (core.OwnershipProjection.Field (loan-cross-place 0) 1)
            (loan-cross-source 1))
          (core.OwnershipPlace
            (core.OwnershipLocalId (loan-cross-id) 1)
            (loan-cross-type 1)
            core.OwnershipProjection.Root
            (loan-cross-source 1)))
        records
        (__tl_make-array core.OwnershipCleanup 0)
        (__tl_make-array core.OwnershipObligation 0)
        blocks
        (loan-cross-block 0)))))

(define (loan-cross-return) : core.OwnershipTerminator
  (core.OwnershipTerminator.Return
    (core.OwnershipPlaceIds (__tl_make-array core.OwnershipPlaceId 0))))

(define (loan-cross-invalid-operation
  [loans : (& loans (Array model.Loan 3))]
  [trace : (& trace (__tl_dyn-array model.Event))]) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index (array-length trace))
        (begin
          (when
            (match (array-ref trace index)
              [(model.Event.ReadThrough id place)
                (not (model.contains? (array-ref loans id).cell place))]
              [(model.Event.WriteThrough id place)
                (or
                  (not (array-ref loans id).exclusive)
                  (not (model.contains? (array-ref loans id).cell place)))]
              [_ false])
            (return index))
          (set! index (+ index 1))))
      -1)))

;; A single-block execution has exactly the same future uses as its concrete
;; trace, so its active masks can be compared exactly on every valid prefix.
;; CFG comparisons below only require inclusion: a different reachable branch
;; can retain a loan which expires on one particular concrete path.
(define (loan-cross-linear-observation?
  [body : (& body core.OwnershipBody)]
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [trace : (& trace (__tl_dyn-array model.Event))]
  [initial : i64]) : bool
  (let
    [inspection : core.OwnershipInspection
      (core.ownership-inspect body (core.ownership-default-limits))]
    [issued : (Array bool 3) (array false false false)]
    [execution : model.Observation
      (model.observe
        loans
        count
        trace
        (!= (bit-and initial 1) 0)
        (!= (bit-and initial 2) 0))]
    [before-count : i64
      (+
        execution.completed
        (if (>= execution.failure 0)
          1
          0))]
    [index : i64 0]
    (begin
      (unless
        (and inspection.observation.complete? (>= execution.failure -1))
        (return false))
      (while (< index before-count)
        (let
          [loan : i64 0]
          (begin
            (while (< loan count)
              (let
                [concrete : i64
                  (array-ref execution.before (+ (* index 3) loan))]
                [abstract : i64
                  (array-ref
                    inspection.observation.before
                    (+ (* (+ index 2) count) loan))]
                (begin
                  (unless
                    (=
                      abstract
                      (if (> concrete 0)
                        2
                        (if (array-ref issued loan)
                          4
                          1)))
                    (return false))
                  (when
                    (< index execution.completed)
                    (begin
                      (match (array-ref trace index)
                        [(model.Event.Borrow id)
                          (when (= id loan) (set! (array-ref issued loan) true))]
                        [(model.Event.Reborrow id)
                          (when (= id loan) (set! (array-ref issued loan) true))]
                        [_ unit])
                      (unless
                        (=
                          (array-ref
                            inspection.observation.after
                            (+ (* (+ index 2) count) loan))
                          (if (>
                            (array-ref execution.after (+ (* index 3) loan))
                            0)
                            2
                            (if (array-ref issued loan)
                              4
                              1)))
                        (return false))))
                  (set! loan (+ loan 1)))))
            (set! index (+ index 1)))))
      true)))

(define (loan-cross-linear?
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [trace : (& trace (__tl_dyn-array model.Event))]
  [initial : i64]) : bool
  (let
    [body : core.OwnershipBody
      (loan-cross-body
        loans
        count
        (__tl_make-array
          (core.OwnershipBlock
            (loan-cross-instructions trace initial true)
            (loan-cross-return)
            (loan-cross-source 1))))]
    [expected : model.Outcome
      (model.execute
        loans
        count
        trace
        (!= (bit-and initial 1) 0)
        (!= (bit-and initial 2) 0))]
    [actual : core.OwnershipResult
      (core.ownership-check (& body) (core.ownership-default-limits))]
    ;; An impossible shared-parent/exclusive-child contract is rejected before
    ;; graph execution, including when its definition is dead. Keep all such
    ;; matrix cases and require the exact metadata diagnostic; they are not
    ;; runtime first-event comparisons and must not pass on any generic error.
    [bad-parent : i64 -1]
    [bad-operation : i64 (loan-cross-invalid-operation loans trace)]
    [loan-index : i64 0]
    (begin
      (while (and (< loan-index count) (< bad-parent 0))
        (let
          [parent : i64 (array-ref loans loan-index).parent]
          (begin
            (when
              (and
                (>= parent 0)
                (array-ref loans loan-index).exclusive
                (not (array-ref loans parent).exclusive))
              (set! bad-parent loan-index))
            (set! loan-index (+ loan-index 1)))))
      (when
        (>= bad-parent 0)
        (return
          (and
            (match expected
              [(model.Outcome.Rejected _) true]
              [_ false])
            (match actual
              [(core.OwnershipResult.Err failure)
                (and
                  (match failure.kind
                    [(core.OwnershipFailureKind.Structural) true]
                    [_ false])
                  (= failure.block -1)
                  (= failure.instruction -1)
                  (= failure.source.line (+ bad-parent 3))
                  (string.eq
                    failure.message
                    "shared loan cannot grant exclusive authority"))]
              [_ false]))))
      (when
        (>= bad-operation 0)
        (return
          (and
            (match expected
              [(model.Outcome.Rejected _) true]
              [_ false])
            (match actual
              [(core.OwnershipResult.Err failure)
                (and
                  (match failure.kind
                    [(core.OwnershipFailureKind.Structural) true]
                    [_ false])
                  (= failure.block 0)
                  (= failure.instruction (+ bad-operation 2))
                  (= failure.source.line (+ bad-operation 10))
                  (string.eq failure.message "invalid operation operands"))]
              [_ false]))))
      (unless
        (loan-cross-linear-observation? (& body) loans count trace initial)
        (return false))
      (match expected
        [(model.Outcome.InvalidInput) false]
        [(model.Outcome.Accepted _ _)
          (match actual
            [(core.OwnershipResult.Ok) true]
            [_ false])]
        [(model.Outcome.Rejected at)
          (match actual
            [(core.OwnershipResult.Ok) false]
            [(core.OwnershipResult.Err failure)
              (and
                (= failure.block 0)
                (= failure.instruction (+ 2 at))
                (= failure.source.line (+ 10 at))
                (match failure.kind
                  [(core.OwnershipFailureKind.Loan) true]
                  [(core.OwnershipFailureKind.Uninitialized) true]
                  [_ false]))])]))))

(define (loan-cross-direct?) : bool
  (let
    [code : i64 0]
    (begin
      (while (< code 576)
        (let
          [initial : i64 (% code 4)]
          [exclusive : bool (= (% (/ code 4) 2) 1)]
          [borrowed : i64 (% (/ code 8) 3)]
          [accessed : i64 (% (/ code 24) 3)]
          [action : i64 (% (/ code 72) 4)]
          [retained : bool (= (/ code 288) 1)]
          [loans : (Array model.Loan 3)
            (array
              (model.Loan (controls.cell borrowed) exclusive -1)
              (model.Loan model.Cell.Left false -1)
              (model.Loan model.Cell.Right false -1))]
          [trace : (__tl_dyn-array model.Event)
            (if retained
              (__tl_make-array
                (model.Event.Borrow 0)
                (controls.operation action (controls.cell accessed))
                (model.Event.Keep 0))
              (__tl_make-array
                (model.Event.Borrow 0)
                (controls.operation action (controls.cell accessed))))]
          (unless
            (loan-cross-linear? (& loans) 1 (& trace) initial)
            (begin
              (io.println
                "ownership-loan-crosscheck direct mismatch: initial={} exclusive={} borrowed={} accessed={} action={} retained={}"
                initial
                exclusive
                borrowed
                accessed
                action
                retained)
              (return false))))
        (set! code (+ code 1)))
      true)))

(define (loan-cross-reborrow-trace [mode : i64]) : (__tl_dyn-array model.Event)
  (match mode
    [0
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.ReadThrough 0 model.Cell.Left)
        (model.Event.Keep 1))]
    [1
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.WriteThrough 0 model.Cell.Left)
        (model.Event.Keep 1))]
    [2
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.WriteThrough 0 model.Cell.Right)
        (model.Event.Keep 1))]
    [3
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.End 0)
        (model.Event.Keep 1))]
    [4
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.End 1)
        (model.Event.WriteThrough 0 model.Cell.Left))]
    [5
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.Write model.Cell.Right)
        (model.Event.Keep 1))]
    [6
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.WriteThrough 1 model.Cell.Left))]
    [7
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.ReadThrough 1 model.Cell.Right))]
    [_
      (__tl_make-array
        (model.Event.Borrow 0)
        (model.Event.Reborrow 1)
        (model.Event.End 1)
        (model.Event.End 0)
        (model.Event.Write model.Cell.Whole))]))

(define (loan-cross-reborrow?) : bool
  (let
    [mode : i64 0]
    (begin
      (while (< mode 9)
        (let
          ;; Pin parent retention independently of EndLoan validation.
          [scenario : i64
            (match mode
              [3 5]
              [5 3]
              [_ mode])]
          [loans : (Array model.Loan 3)
            (array
              (model.Loan model.Cell.Whole true -1)
              (model.Loan model.Cell.Left false 0)
              (model.Loan model.Cell.Right false 0))]
          [trace : (__tl_dyn-array model.Event)
            (loan-cross-reborrow-trace scenario)]
          (unless
            (loan-cross-linear? (& loans) 2 (& trace) 3)
            (begin
              (io.println
                "ownership-loan-crosscheck reborrow mismatch: mode={}"
                scenario)
              (return false))))
        (set! mode (+ mode 1)))
      true)))

(define (loan-cross-reborrow-matrix?) : bool
  (let
    [code : i64 0]
    (begin
      (while (< code 128)
        (let
          [parent-exclusive : bool (= (% code 2) 1)]
          [child-exclusive : bool (= (% (/ code 2) 2) 1)]
          [child-cell : model.Cell (controls.cell (+ 1 (% (/ code 4) 2)))]
          [access : i64 (% (/ code 8) 4)]
          [write? : bool (= (% (/ code 32) 2) 1)]
          [retained : bool (= (/ code 64) 1)]
          [grant : i64
            (if (= access 3)
              1
              0)]
          [target : model.Cell
            (if (= access 3)
              child-cell
              (controls.cell access))]
          [operation : model.Event
            (if write?
              (model.Event.WriteThrough grant target)
              (model.Event.ReadThrough grant target))]
          [loans : (Array model.Loan 3)
            (array
              (model.Loan model.Cell.Whole parent-exclusive -1)
              (model.Loan child-cell child-exclusive 0)
              (model.Loan model.Cell.Right false -1))]
          [trace : (__tl_dyn-array model.Event)
            (if retained
              (__tl_make-array
                (model.Event.Borrow 0)
                (model.Event.Reborrow 1)
                operation
                (model.Event.Keep 1))
              (__tl_make-array
                (model.Event.Borrow 0)
                (model.Event.Reborrow 1)
                operation))]
          (unless
            (loan-cross-linear? (& loans) 2 (& trace) 3)
            (begin
              (io.println
                "ownership-loan-crosscheck reborrow matrix mismatch: case={}"
                code)
              (return false))))
        (set! code (+ code 1)))
      true)))

;; Read a selected path of the canonical graph back into concrete events.
;; This only converts identities and operations, never production decisions.
(define (loan-cross-model-cell [index : i64]) : model.Cell
  (match index
    [0 model.Cell.Whole]
    [1 model.Cell.Left]
    [2 model.Cell.Right]
    [_ (io.panic "loan adapter cannot model this place")]))

(define (loan-cross-model-event
  [operation : (& operation core.OwnershipOperation)]) : model.Event
  (match operation
    [(core.OwnershipOperation.Read place)
      (model.Event.Read (loan-cross-model-cell place.index))]
    [(core.OwnershipOperation.Assign place)
      (model.Event.Write (loan-cross-model-cell place.index))]
    [(core.OwnershipOperation.Consume place)
      (model.Event.Consume (loan-cross-model-cell place.index))]
    [(core.OwnershipOperation.Invalidate place)
      (model.Event.Invalidate (loan-cross-model-cell place.index))]
    [(core.OwnershipOperation.Borrow loan) (model.Event.Borrow loan.index)]
    [(core.OwnershipOperation.Reborrow loan) (model.Event.Reborrow loan.index)]
    [(core.OwnershipOperation.UseLoan loan) (model.Event.Keep loan.index)]
    [(core.OwnershipOperation.MayUseLoan loan _)
      (model.Event.MayKeep loan.index)]
    [(core.OwnershipOperation.EndLoan loan) (model.Event.End loan.index)]
    [(core.OwnershipOperation.AccessThrough loan place access)
      (match access
        [(core.OwnershipAccess.Read)
          (model.Event.ReadThrough
            loan.index
            (loan-cross-model-cell place.index))]
        [(core.OwnershipAccess.Write)
          (model.Event.WriteThrough
            loan.index
            (loan-cross-model-cell place.index))])]
    [_ (io.panic "loan adapter fixture contains an unsupported event")]))

(defstruct LoanPathOutcome
  (accepted bool)
  (valid bool)
  (observed bool)
  (block i64)
  (instruction i64))

(define (loan-cross-path-observation?
  [observation : (& observation core.OwnershipObservation)]
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [trace : (& trace (__tl_dyn-array model.Event))]
  [blocks : (& blocks (__tl_dyn-array i64))]
  [instructions : (& instructions (__tl_dyn-array i64))]) : bool
  (let
    [execution : model.Observation (model.observe loans count trace true true)]
    [before-count : i64
      (+
        execution.completed
        (if (>= execution.failure 0)
          1
          0))]
    [index : i64 0]
    (begin
      (unless
        (and observation.complete? (>= execution.failure -1))
        (return false))
      (when
        (>= execution.failure 0)
        (let
          [failed : i64 execution.failure]
          [point : i64
            (+
              (array-ref observation.offsets (array-ref blocks failed))
              (array-ref instructions failed))]
          (when
            ;; These CFGs never consume/invalidate: failures must be Loan.
            (= (bit-and (array-ref observation.failure-kinds point) 2) 0)
            (return false))))
      (while (< index before-count)
        (let
          [row : i64
            (*
              count
              (+
                (array-ref observation.offsets (array-ref blocks index))
                (array-ref instructions index)))]
          [demanded : i64
            (match (array-ref trace index)
              [(model.Event.Keep id) id]
              [(model.Event.End id) id]
              [(model.Event.ReadThrough id _) id]
              [(model.Event.WriteThrough id _) id]
              [(model.Event.Reborrow id) (array-ref loans id).parent]
              [_ -1])]
          [loan : i64 0]
          (begin
            (while (< loan count)
              (let
                [token : i64 (array-ref execution.before (+ (* index 3) loan))]
                [abstract : i64 (array-ref observation.before (+ row loan))]
                (begin
                  ;; A concrete retained generation must never disappear from
                  ;; the abstract possible-active set, even on a rejecting CFG.
                  (when
                    (and (> token 0) (= (bit-and abstract 2) 0))
                    (return false))
                  ;; Definite authority at an actual use must hold on EVERY
                  ;; concrete path reaching that point, including failing ones.
                  (when
                    (and (= loan demanded) (= abstract 2) (= token 0))
                    (return false))
                  (when
                    (< index execution.completed)
                    (when
                      (and
                        (> (array-ref execution.after (+ (* index 3) loan)) 0)
                        (=
                          (bit-and (array-ref observation.after (+ row loan)) 2)
                          0))
                      (return false)))
                  (set! loan (+ loan 1)))))
            (set! index (+ index 1)))))
      true)))

(define (loan-cross-path
  [body : (& body core.OwnershipBody)]
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [observation : (& observation core.OwnershipObservation)]
  [path : (& path (__tl_dyn-array i64))]) : LoanPathOutcome
  (let
    [events : i64 0]
    [at : i64 0]
    (begin
      (unless
        (and (> (array-length path) 0) (= (array-ref path 0) body.entry.index))
        (return (LoanPathOutcome false false false -1 -1)))
      (while (< at (array-length path))
        (let
          [id : i64
            (let
              [found : i64 (array-ref path at)]
              (if (and (>= found 0) (< found (array-length body.blocks)))
                found
                (return (LoanPathOutcome false false false -1 -1))))]
          [block : (& body core.OwnershipBlock) (& (array-ref body.blocks id))]
          (begin
            (when
              (= at 0)
              (unless
                (and
                  (>= (array-length block.instructions) 2)
                  (match (array-ref block.instructions 0).operation
                    [(core.OwnershipOperation.Assign place) (= place.index 1)]
                    [_ false])
                  (match (array-ref block.instructions 1).operation
                    [(core.OwnershipOperation.Assign place) (= place.index 2)]
                    [_ false]))
                (return (LoanPathOutcome false false false -1 -1))))
            (unless
              (match (& block.terminator)
                [(core.OwnershipTerminator.Branch condition _ _)
                  (and (= condition.index 3) (< (+ at 1) (array-length path)))]
                [(core.OwnershipTerminator.Goto _)
                  (< (+ at 1) (array-length path))]
                [(core.OwnershipTerminator.Return operands)
                  (and
                    (= (array-length operands.items) 0)
                    (= (+ at 1) (array-length path)))]
                [(core.OwnershipTerminator.Abort)
                  (= (+ at 1) (array-length path))]
                [_ false])
              (return (LoanPathOutcome false false false -1 -1)))
            (set!
              events
              (+
                events
                (array-length block.instructions)
                (if (= at 0)
                  -2
                  0)))
            (when
              (< (+ at 1) (array-length path))
              (let
                [next : i64 (array-ref path (+ at 1))]
                (unless
                  (match (& block.terminator)
                    [(core.OwnershipTerminator.Goto target)
                      (= target.index next)]
                    [(core.OwnershipTerminator.Branch _ yes no)
                      (or (= yes.index next) (= no.index next))]
                    [_ false])
                  (return (LoanPathOutcome false false false -1 -1)))))
            (set! at (+ at 1)))))
      (unless
        (and (>= events 0) (<= events 128))
        (return (LoanPathOutcome false false false -1 -1)))
      (let
        [trace : (__tl_dyn-array model.Event)
          (__tl_make-array model.Event events)]
        [blocks : (__tl_dyn-array i64) (__tl_make-array i64 events)]
        [instructions : (__tl_dyn-array i64) (__tl_make-array i64 events)]
        [cursor : i64 0]
        (begin
          (set! at 0)
          (while (< at (array-length path))
            (let
              [id : i64 (array-ref path at)]
              [block : (& body core.OwnershipBlock)
                (& (array-ref body.blocks id))]
              [index : i64
                (if (= at 0)
                  2
                  0)]
              (begin
                (while (< index (array-length block.instructions))
                  (begin
                    (set!
                      (array-ref trace cursor)
                      (loan-cross-model-event
                        (& (array-ref block.instructions index).operation)))
                    (set! (array-ref blocks cursor) id)
                    (set! (array-ref instructions cursor) index)
                    (set! cursor (+ cursor 1))
                    (set! index (+ index 1))))
                (set! at (+ at 1)))))
          (let
            [observed : bool
              (loan-cross-path-observation?
                observation
                loans
                count
                (& trace)
                (& blocks)
                (& instructions))]
            (match (model.execute loans count (& trace) true true)
              [(model.Outcome.Accepted _ _)
                (LoanPathOutcome true true observed -1 -1)]
              [(model.Outcome.InvalidInput)
                (LoanPathOutcome false false false -1 -1)]
              [(model.Outcome.Rejected index)
                (LoanPathOutcome
                  false
                  true
                  observed
                  (array-ref blocks index)
                  (array-ref instructions index))])))))))

(define (loan-cross-events-block
  [events : (__tl_dyn-array model.Event)]
  [entry? : bool]
  [terminator : core.OwnershipTerminator]) : core.OwnershipBlock
  (core.OwnershipBlock
    (loan-cross-instructions (& events) 3 entry?)
    terminator
    (loan-cross-source 1)))

(define (loan-cross-branch [yes : i64] [no : i64]) : core.OwnershipTerminator
  (core.OwnershipTerminator.Branch
    (loan-cross-place 3)
    (loan-cross-block yes)
    (loan-cross-block no)))

(define (loan-cross-goto [target : i64]) : core.OwnershipTerminator
  (core.OwnershipTerminator.Goto (loan-cross-block target)))

(define (loan-cross-loop-mode? [mode : i64]) : bool
  (or (= mode 5) (= mode 6) (= mode 7) (= mode 9) (= mode 10) (>= mode 12)))

(define (loan-cross-graph
  [mode : i64]
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]) : core.OwnershipBody
  (let
    [blocks : (__tl_dyn-array core.OwnershipBlock)
      (__tl_make-array core.OwnershipBlock 4)]
    (begin
      (set!
        (array-ref blocks 0)
        (loan-cross-events-block
          (if (or (= mode 0) (= mode 5) (= mode 6) (= mode 7) (>= mode 12))
            (__tl_make-array model.Event 0)
            (__tl_make-array (model.Event.Borrow 0)))
          true
          (if (loan-cross-loop-mode? mode)
            (loan-cross-goto 1)
            (loan-cross-branch 1 2))))
      (set!
        (array-ref blocks 1)
        (loan-cross-events-block
          (match mode
            [0 (__tl_make-array (model.Event.Borrow 0))]
            [1 (__tl_make-array (model.Event.Keep 0))]
            [2 (__tl_make-array (model.Event.Reborrow 1))]
            [3 (__tl_make-array (model.Event.Reborrow 1) (model.Event.End 0))]
            [4 (__tl_make-array (model.Event.Reborrow 1) (model.Event.Keep 1))]
            [7 (__tl_make-array (model.Event.Borrow 0))]
            [11 (__tl_make-array (model.Event.Keep 0))]
            [12 (__tl_make-array (model.Event.Borrow 0))]
            [13 (__tl_make-array (model.Event.Borrow 0))]
            [14 (__tl_make-array (model.Event.Borrow 0))]
            [15 (__tl_make-array (model.Event.Borrow 0))]
            [16 (__tl_make-array (model.Event.Borrow 0))]
            [8 (__tl_make-array (model.Event.Write model.Cell.Left))]
            [_ (__tl_make-array model.Event 0)])
          false
          (cond
            [(loan-cross-loop-mode? mode) (loan-cross-branch 2 3)]
            [(= mode 11) (loan-cross-return)]
            [else (loan-cross-goto 3)])))
      (set!
        (array-ref blocks 2)
        (loan-cross-events-block
          (match mode
            [1 (__tl_make-array (model.Event.Write model.Cell.Left))]
            [5
              (__tl_make-array
                (model.Event.Borrow 0)
                (model.Event.Reborrow 1)
                (model.Event.ReadThrough 1 model.Cell.Left)
                (model.Event.End 1)
                (model.Event.End 0))]
            [6
              (__tl_make-array
                (model.Event.Borrow 0)
                (model.Event.Reborrow 1)
                (model.Event.WriteThrough 0 model.Cell.Left)
                (model.Event.Keep 1))]
            [7 (__tl_make-array (model.Event.Reborrow 1))]
            [8 (__tl_make-array (model.Event.Keep 0))]
            [9 (__tl_make-array (model.Event.Keep 0))]
            [10 (__tl_make-array (model.Event.Keep 0) (model.Event.End 0))]
            [11 (__tl_make-array (model.Event.Write model.Cell.Whole))]
            [12 (__tl_make-array (model.Event.Reborrow 1) (model.Event.End 0))]
            [13 (__tl_make-array (model.Event.Reborrow 1))]
            [14 (__tl_make-array (model.Event.Borrow 1))]
            [15 (__tl_make-array (model.Event.Borrow 1))]
            [16 (__tl_make-array (model.Event.Borrow 1))]
            [_ (__tl_make-array model.Event 0)])
          false
          (if (loan-cross-loop-mode? mode)
            (loan-cross-goto 1)
            (loan-cross-goto 3))))
      (set!
        (array-ref blocks 3)
        (loan-cross-events-block
          (match mode
            [0 (__tl_make-array (model.Event.Keep 0))]
            [2
              (__tl_make-array
                (model.Event.WriteThrough 0 model.Cell.Left)
                (model.Event.Keep 1))]
            [3 (__tl_make-array (model.Event.Keep 1))]
            [4 (__tl_make-array (model.Event.WriteThrough 0 model.Cell.Left))]
            [7 (__tl_make-array (model.Event.Keep 1))]
            [11 (__tl_make-array (model.Event.Read model.Cell.Whole))]
            [12 (__tl_make-array (model.Event.Keep 1))]
            [13 (__tl_make-array (model.Event.Keep 1))]
            ;; A reference that may hold either branch's loan: both are kept
            ;; where possibly issued, and a shared read of the whole is fine.
            [14
              (__tl_make-array
                (model.Event.MayKeep 0)
                (model.Event.MayKeep 1)
                (model.Event.Read model.Cell.Whole))]
            ;; Writing Left while loan 0 may be issued and is still kept later
            ;; conflicts on the path that borrowed it.
            [15
              (__tl_make-array
                (model.Event.Write model.Cell.Left)
                (model.Event.MayKeep 0)
                (model.Event.MayKeep 1))]
            ;; After the last possible use the write is fine on both paths.
            [16
              (__tl_make-array
                (model.Event.MayKeep 0)
                (model.Event.MayKeep 1)
                (model.Event.Write model.Cell.Left))]
            [_ (__tl_make-array (model.Event.Write model.Cell.Whole))])
          false
          (loan-cross-return)))
      (loan-cross-body loans count blocks))))

(define (loan-cross-loop-path [iterations : i64]) : (__tl_dyn-array i64)
  (let
    [path : (__tl_dyn-array i64) (__tl_make-array i64 (+ 3 (* iterations 2)))]
    [i : i64 0]
    (begin
      (set! (array-ref path 0) 0)
      (while (<= i iterations)
        (begin
          (set! (array-ref path (+ 1 (* i 2))) 1)
          (when (< i iterations) (set! (array-ref path (+ 2 (* i 2))) 2))
          (set! i (+ i 1))))
      (set! (array-ref path (+ 2 (* iterations 2))) 3)
      path)))

(define (loan-cross-graphs?) : bool
  (let
    [mode : i64 0]
    ;; Concrete paths enumerated over all graphs: four per loop graph, two per
    ;; other graph.
    [paths : i64 0]
    (begin
      (while (< mode 17)
        (let
          [loans : (Array model.Loan 3)
            (if (>= mode 14)
              (array
                (model.Loan model.Cell.Left false -1)
                (model.Loan model.Cell.Right false -1)
                (model.Loan model.Cell.Right false -1))
              (array
                (model.Loan model.Cell.Whole (< mode 12) -1)
                (model.Loan model.Cell.Left false 0)
                (model.Loan model.Cell.Right false 0)))]
          [count : i64
            (if (or (< mode 2) (and (>= mode 8) (< mode 12)))
              1
              2)]
          [body : core.OwnershipBody (loan-cross-graph mode (& loans) count)]
          [actual : core.OwnershipResult
            (core.ownership-check (& body) (core.ownership-default-limits))]
          [inspection : core.OwnershipInspection
            (core.ownership-inspect (& body) (core.ownership-default-limits))]
          [all-accepted : bool true]
          [matched-failure : bool false]
          [path-count : i64
            (if (loan-cross-loop-mode? mode)
              4
              2)]
          [path-index : i64 0]
          (begin
            (while (< path-index path-count)
              (let
                [path : (__tl_dyn-array i64)
                  (cond
                    [(loan-cross-loop-mode? mode)
                      (loan-cross-loop-path path-index)]
                    [(and (= mode 11) (= path-index 0)) (__tl_make-array 0 1)]
                    [else (__tl_make-array 0 (+ path-index 1) 3)])]
                [expected : LoanPathOutcome
                  (loan-cross-path
                    (& body)
                    (& loans)
                    count
                    (& inspection.observation)
                    (& path))]
                (begin
                  (unless
                    expected.valid
                    (begin
                      (io.println
                        "ownership-loan-crosscheck invalid path: mode={} path={}"
                        mode
                        path-index)
                      (return false)))
                  (unless
                    expected.observed
                    (begin
                      (io.println
                        "ownership-loan-crosscheck graph facts mismatch: mode={} path={}"
                        mode
                        path-index)
                      (return false)))
                  (unless
                    expected.accepted
                    (begin
                      (set! all-accepted false)
                      (match (& actual)
                        [(core.OwnershipResult.Err failure)
                          (when
                            (and
                              (= failure.block expected.block)
                              (= failure.instruction expected.instruction)
                              (match (& failure.kind)
                                [(core.OwnershipFailureKind.Loan) true]
                                [(core.OwnershipFailureKind.Uninitialized) true]
                                [_ false]))
                            (set! matched-failure true))]
                        [_ unit])))
                  (set! paths (+ paths 1))
                  (set! path-index (+ path-index 1)))))
            (unless
              (if all-accepted
                (match (& actual)
                  [(core.OwnershipResult.Ok) true]
                  [_ false])
                matched-failure)
              (begin
                (io.println
                  "ownership-loan-crosscheck graph mismatch: mode={} expected={}"
                  mode
                  all-accepted)
                (return false)))
            (set! mode (+ mode 1)))))
      (unless
        (= paths 54)
        (begin
          (io.println "ownership-loan-crosscheck path count mismatch: {}" paths)
          (return false)))
      true)))

(define (loan-cross-three?) : bool
  (let
    [mode : i64 0]
    (begin
      (while (< mode 8)
        (let
          [loans : (Array model.Loan 3) (cases.witness-loans mode)]
          [trace : (__tl_dyn-array model.Event) (cases.witness-trace mode)]
          (begin
            (unless
              (loan-cross-linear? (& loans) 3 (& trace) 3)
              (begin
                (io.println
                  "ownership-loan-crosscheck three-loan mismatch: mode={}"
                  mode)
                (return false)))
            (set! mode (+ mode 1)))))
      (set! mode 0)
      (while (< mode 3840)
        (let
          [configuration : i64 (/ mode 64)]
          [retained : i64 (% (/ mode 8) 8)]
          [action : i64 (% mode 8)]
          [loans : (Array model.Loan 3) (cases.configuration configuration)]
          [trace : (__tl_dyn-array model.Event)
            (cases.trace (& loans) retained action)]
          (begin
            (unless
              (with-arena scratch (loan-cross-linear? (& loans) 3 (& trace) 3))
              (begin
                (io.println
                  "ownership-loan-crosscheck three-loan matrix mismatch: mode={}"
                  mode)
                (return false)))
            (set! mode (+ mode 1)))))
      true)))

(define (main) : i64
  (if (and
    (loan-cross-direct?)
    (loan-cross-reborrow?)
    (loan-cross-reborrow-matrix?)
    (loan-cross-three?)
    (loan-cross-graphs?))
    (begin
      (io.println
        "ownership-loan-crosscheck-v1: direct=576 reborrow=137 three=3848 graphs=17 paths=54 passed")
      0)
    1))