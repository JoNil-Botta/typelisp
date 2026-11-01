;; Value-operation adapter. Expected permissions, failures and final memory
;; come only from loan_model's concrete execution, never production decisions.
;; Copy/Copy-Move = Read(source), Write(destination); MoveOnly-Move =
;; Consume(source), Write(destination); Copy-Consume = Read(source).
;; Keep events follow the entire core operation, so splitting its concrete
;; meaning cannot accidentally expire a retained loan between its operands.
;; Rejected operations have no asserted successor initialization state.
;; Scope: disjoint scalar cells, up to three direct loans, Boolean Copy or
;; scalar MoveOnly types. Parent/aggregate/cleanup behavior is tested elsewhere.
;; Terminator cases use one Boolean branch/return operand; both branch edges
;; are modeled, and a selected successor can retain the condition's loan.
(import loan_model as model)
(import compiler_ownership_core as core)
(import stdlib.io)

(define (id) : core.OwnershipBodyId
  (core.OwnershipBodyId (cast 8449 : u64) (cast 6 : u64) (cast 1 : u64)))

(define (type-id [index : i64]) : core.OwnershipTypeId
  (core.OwnershipTypeId (id) index))

(define (place [index : i64]) : core.OwnershipPlaceId
  (core.OwnershipPlaceId (id) index))

(define (loan [index : i64]) : core.OwnershipLoanId
  (core.OwnershipLoanId (id) index))

(define (block [index : i64]) : core.OwnershipBlockId
  (core.OwnershipBlockId (id) index))

(define (source [line : i64]) : core.OwnershipSource
  (core.OwnershipSource "loan-value-case.tl" line 1 "concrete value operation"))

(define (flag? [bits : i64] [index : i64]) : bool
  (!= (bit-and bits (shl 1 index)) 0))

(define (cell [index : i64]) : model.Cell
  (match index
    [0 model.Cell.Whole]
    [1 model.Cell.Left]
    [2 model.Cell.Right]
    [_ (io.panic "loan value adapter: unsupported place")]))

(define (cell-index [value : model.Cell]) : i64
  (match value
    [(model.Cell.Whole) 0]
    [(model.Cell.Left) 1]
    [(model.Cell.Right) 2]))

(define (copy-type? [operation : i64]) : bool
  (or (= operation 0) (= operation 1) (= operation 3)))

(define (width [operation : i64]) : i64
  (if (< operation 3)
    2
    1))

(define (instruction [operation : core.OwnershipOperation] [index : i64]) : core.OwnershipInstruction
  (core.OwnershipInstruction operation (source (+ 10 index))))

(define (return-empty) : core.OwnershipTerminator
  (core.OwnershipTerminator.Return
    (core.OwnershipPlaceIds (__tl_make-array core.OwnershipPlaceId 0))))

(define (body
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [copy? : bool]
  [blocks : (__tl_dyn-array core.OwnershipBlock)]) : core.OwnershipBody
  (let
    [records : (__tl_dyn-array core.OwnershipLoan)
      (__tl_make-array core.OwnershipLoan count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref records index)
            (core.OwnershipLoan
              (place (cell-index (array-ref loans index).cell))
              (if (array-ref loans index).exclusive
                core.OwnershipLoanKind.Exclusive
                core.OwnershipLoanKind.Shared)
              core.OwnershipLoanOrigin.Direct
              (source (+ 2 index))))
          (set! index (+ index 1))))
      (core.OwnershipBody
        (id)
        (__tl_make-array
          (core.OwnershipType
            (if copy?
              core.OwnershipTypeKind.Boolean
              core.OwnershipTypeKind.Scalar)
            copy?)
          (core.OwnershipType
            (core.OwnershipTypeKind.Product
              (core.OwnershipTypeIds (__tl_make-array (type-id 0) (type-id 0))))
            copy?))
        (__tl_make-array (core.OwnershipLocal (type-id 1) false (source 1)))
        (__tl_make-array
          (core.OwnershipPlace
            (core.OwnershipLocalId (id) 0)
            (type-id 1)
            core.OwnershipProjection.Root
            (source 1))
          (core.OwnershipPlace
            (core.OwnershipLocalId (id) 0)
            (type-id 0)
            (core.OwnershipProjection.Field (place 0) 0)
            (source 1))
          (core.OwnershipPlace
            (core.OwnershipLocalId (id) 0)
            (type-id 0)
            (core.OwnershipProjection.Field (place 0) 1)
            (source 1)))
        records
        (__tl_make-array core.OwnershipCleanup 0)
        (__tl_make-array core.OwnershipObligation 0)
        blocks
        (block 0)))))

(define (prefix [count : i64] [initial : i64]) : (__tl_dyn-array
    core.OwnershipInstruction)
  (let
    [out : (__tl_dyn-array core.OwnershipInstruction)
      (__tl_make-array core.OwnershipInstruction 0)]
    [index : i64 0]
    (begin
      (while (< index 2)
        (begin
          (__tl_array-push!
            out
            (instruction
              (if (flag? initial index)
                (core.OwnershipOperation.Assign (place (+ index 1)))
                (core.OwnershipOperation.Invalidate (place (+ index 1))))
              index))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index count)
        (begin
          (__tl_array-push!
            out
            (instruction
              (core.OwnershipOperation.Borrow (loan index))
              (+ index 2)))
          (set! index (+ index 1))))
      out)))

(define (value-operation [operation : i64] [from : i64]) : core.OwnershipOperation
  (let
    [to : i64 (- 3 from)]
    (match operation
      [0 (core.OwnershipOperation.Copy (place from) (place to))]
      [1 (core.OwnershipOperation.Move (place from) (place to))]
      [2 (core.OwnershipOperation.Move (place from) (place to))]
      [3 (core.OwnershipOperation.Consume (place from))]
      [4 (core.OwnershipOperation.Consume (place from))]
      [_ (io.panic "loan value adapter: unsupported value operation")])))

(define (value-trace
  [count : i64]
  [retained : i64]
  [operation : i64]
  [from : i64]) : (__tl_dyn-array model.Event)
  (let
    [out : (__tl_dyn-array model.Event) (__tl_make-array model.Event 0)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (__tl_array-push! out (model.Event.Borrow index))
          (set! index (+ index 1))))
      (__tl_array-push!
        out
        (if (copy-type? operation)
          (model.Event.Read (cell from))
          (model.Event.Consume (cell from))))
      (when
        (< operation 3)
        (__tl_array-push! out (model.Event.Write (cell (- 3 from)))))
      (set! index 0)
      (while (< index count)
        (begin
          (when
            (flag? retained index)
            (__tl_array-push! out (model.Event.Keep index)))
          (set! index (+ index 1))))
      out)))

(define (value-body
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [initial : i64]
  [retained : i64]
  [operation : i64]
  [from : i64]) : core.OwnershipBody
  (let
    [instructions : (__tl_dyn-array core.OwnershipInstruction)
      (prefix count initial)]
    [index : i64 0]
    (begin
      (__tl_array-push!
        instructions
        (instruction (value-operation operation from) (+ count 2)))
      (while (< index count)
        (begin
          (when
            (flag? retained index)
            (__tl_array-push!
              instructions
              (instruction
                (core.OwnershipOperation.UseLoan (loan index))
                (array-length instructions))))
          (set! index (+ index 1))))
      (body
        loans
        count
        (copy-type? operation)
        (__tl_make-array
          (core.OwnershipBlock instructions (return-empty) (source 1)))))))

(define (event-instruction [event : i64] [count : i64] [operation : i64]) : i64
  (cond
    [(< event count) (+ 2 event)]
    [(< event (+ count (width operation))) (+ 2 count)]
    [else (+ 3 event (- 0 (width operation)))]))

(define (semantic-at? [actual : (& actual core.OwnershipResult)] [at : i64]) : bool
  (match actual
    [(core.OwnershipResult.Ok) false]
    [(core.OwnershipResult.Err error)
      (and
        (= error.block 0)
        (= error.instruction at)
        (= error.source.line (+ 10 at))
        (match error.kind
          [(core.OwnershipFailureKind.Loan) true]
          [(core.OwnershipFailureKind.Uninitialized) true]
          [_ false]))]))

;; The combined checker has already validated this immutable body and accepted
;; all permissions. Replay its canonical initialization transfer to inspect the
;; successful memory result; no permission decision comes from this replay.
(define (successful-state?
  [body : (& body core.OwnershipBody)]
  [left : bool]
  [right : bool]) : bool
  (let
    [state : (__tl_dyn-array i64) (__tl_make-array 1 1 1)]
    [index : i64 0]
    (begin
      (while (< index (array-length (array-ref body.blocks 0).instructions))
        (begin
          (match (core.ownership-transfer!
            body
            (&mut state)
            (& (array-ref (array-ref body.blocks 0).instructions index))
            0
            index)
            [(core.OwnershipResult.Err _) (return false)]
            [_ unit])
          (set! index (+ index 1))))
      (and
        (=
          (array-ref state 1)
          (if left
            2
            1))
        (=
          (array-ref state 2)
          (if right
            2
            1))
        (=
          (array-ref state 0)
          (if (= left right)
            (if left
              2
              1)
            3))))))

(define (value-observation?
  [body : (& body core.OwnershipBody)]
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [initial : i64]
  [operation : i64]
  [trace : (& trace (__tl_dyn-array model.Event))]) : bool
  (let
    [actual : core.OwnershipInspection
      (core.ownership-inspect body (core.ownership-default-limits))]
    [expected : model.Observation
      (model.observe loans count trace (flag? initial 0) (flag? initial 1))]
    [index : i64 0]
    [row : i64 (* (+ count 2) count)]
    (begin
      (unless
        (and actual.observation.complete? (>= expected.failure -1))
        (return false))
      (when
        (>= expected.completed count)
        (while (< index count)
          (let
            [before : i64 (array-ref actual.observation.before (+ row index))]
            [token : i64 (array-ref expected.before (+ (* count 3) index))]
            (begin
              (unless
                (if (> token 0)
                  (= before 2)
                  (= (bit-and before 2) 0))
                (return false))
              (when
                (>= expected.completed (+ count (width operation)))
                (let
                  [after : i64
                    (array-ref actual.observation.after (+ row index))]
                  [final-token : i64
                    (array-ref
                      expected.after
                      (+ (* (- (+ count (width operation)) 1) 3) index))]
                  (unless
                    (if (> final-token 0)
                      (= after 2)
                      (= (bit-and after 2) 0))
                    (return false))))
              (set! index (+ index 1))))))
      true)))

(define (value-case?
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [initial : i64]
  [retained : i64]
  [operation : i64]
  [from : i64]) : bool
  (let
    [trace : (__tl_dyn-array model.Event)
      (value-trace count retained operation from)]
    [fixture : core.OwnershipBody
      (value-body loans count initial retained operation from)]
    [expected : model.Outcome
      (model.execute loans count (& trace) (flag? initial 0) (flag? initial 1))]
    [actual : core.OwnershipResult
      (core.ownership-check (& fixture) (core.ownership-default-limits))]
    (and
      (value-observation? (& fixture) loans count initial operation (& trace))
      (match expected
        [(model.Outcome.InvalidInput) false]
        [(model.Outcome.Rejected at)
          (semantic-at? (& actual) (event-instruction at count operation))]
        [(model.Outcome.Accepted left right)
          (and
            (match (& actual)
              [(core.OwnershipResult.Ok) true]
              [_ false])
            (successful-state? (& fixture) left right))]))))

(define (value-campaign?) : bool
  (let
    [family : i64 0]
    [checked : i64 0]
    (begin
      (while (< family 3)
        (let
          [code : i64 0]
          [limit : i64
            (match family
              [0 40]
              [1 480]
              [_ 640])]
          (begin
            (while (< code limit)
              (let
                [operation : i64 (% code 5)]
                [from : i64 (+ 1 (% (/ code 5) 2))]
                [initial : i64
                  (if (= family 2)
                    3
                    (% (/ code 10) 4))]
                [retained : i64
                  (match family
                    [0 0]
                    [1 (% (/ code 40) 2)]
                    [_ (% (/ code 10) 8)])]
                [permissions : i64
                  (if (= family 2)
                    (/ code 80)
                    (% (/ code 80) 2))]
                [count : i64
                  (match family
                    [0 0]
                    [1 1]
                    [_ 3])]
                [loans : (Array model.Loan 3)
                  (array
                    (model.Loan
                      (if (= family 1)
                        (cell (/ code 160))
                        model.Cell.Left)
                      (flag? permissions 0)
                      -1)
                    (model.Loan model.Cell.Right (flag? permissions 1) -1)
                    (model.Loan model.Cell.Left (flag? permissions 2) -1))]
                (begin
                  (unless
                    (with-arena
                      case-arena
                      (value-case?
                        (& loans)
                        count
                        initial
                        retained
                        operation
                        from))
                    (begin
                      (io.println
                        "ownership-loan-value mismatch: family={} case={}"
                        family
                        code)
                      (return false)))
                  (set! checked (+ checked 1))
                  (set! code (+ code 1)))))
            (set! family (+ family 1)))))
      (= checked 1160))))

(define (terminator-trace [count : i64] [retained? : bool]) : (__tl_dyn-array
    model.Event)
  (let
    [out : (__tl_dyn-array model.Event) (__tl_make-array model.Event 0)]
    (begin
      (when (= count 1) (__tl_array-push! out (model.Event.Borrow 0)))
      (__tl_array-push! out (model.Event.Read model.Cell.Left))
      (when retained? (__tl_array-push! out (model.Event.Keep 0)))
      out)))

(define (terminator-body
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]
  [initial : i64]
  [branch? : bool]
  [retained? : bool]) : core.OwnershipBody
  (let
    [blocks : (__tl_dyn-array core.OwnershipBlock)
      (__tl_make-array core.OwnershipBlock 0)]
    (begin
      (__tl_array-push!
        blocks
        (core.OwnershipBlock
          (prefix count initial)
          (if branch?
            (core.OwnershipTerminator.Branch (place 1) (block 1) (block 2))
            (core.OwnershipTerminator.Return
              (core.OwnershipPlaceIds (__tl_make-array (place 1)))))
          (source (+ 12 count))))
      (when
        branch?
        (begin
          (__tl_array-push!
            blocks
            (core.OwnershipBlock
              (if retained?
                (__tl_make-array
                  (instruction (core.OwnershipOperation.UseLoan (loan 0)) 0))
                (__tl_make-array core.OwnershipInstruction 0))
              (return-empty)
              (source 20)))
          (__tl_array-push!
            blocks
            (core.OwnershipBlock
              (__tl_make-array core.OwnershipInstruction 0)
              (return-empty)
              (source 21)))))
      (body loans count true blocks))))

(define (terminator-case? [branch? : bool] [code : i64]) : bool
  (let
    [count : i64
      (if (< code 4)
        0
        1)]
    [within : i64
      (if (= count 0)
        code
        (- code 4))]
    [initial : i64 (% within 4)]
    [retained? : bool (and branch? (= count 1) (= (% (/ within 4) 2) 1))]
    [exclusive? : bool
      (=
        (if branch?
          (/ within 8)
          (/ within 4))
        1)]
    [loans : (Array model.Loan 3)
      (array
        (model.Loan model.Cell.Left exclusive? -1)
        (model.Loan model.Cell.Right false -1)
        (model.Loan model.Cell.Left false -1))]
    [fixture : core.OwnershipBody
      (terminator-body (& loans) count initial branch? retained?)]
    [actual : core.OwnershipResult
      (core.ownership-check (& fixture) (core.ownership-default-limits))]
    [inspection : core.OwnershipInspection
      (core.ownership-inspect (& fixture) (core.ownership-default-limits))]
    [path : i64 0]
    [all-accepted? : bool true]
    [matched? : bool false]
    (begin
      (unless inspection.observation.complete? (return false))
      (while (<
        path
        (if branch?
          2
          1))
        (let
          [trace : (__tl_dyn-array model.Event)
            (terminator-trace count (and (= path 0) retained?))]
          (begin
            (match (model.execute
              (& loans)
              count
              (& trace)
              (flag? initial 0)
              (flag? initial 1))
              [(model.Outcome.InvalidInput) (return false)]
              [(model.Outcome.Accepted _ _) unit]
              [(model.Outcome.Rejected at)
                (begin
                  (set! all-accepted? false)
                  ;; A failure after the Read would be in a successor block;
                  ;; these fixtures cannot manufacture one and must not hide it.
                  (when (> at count) (return false))
                  (when (semantic-at? (& actual) (+ 2 at)) (set! matched? true)))])
            (set! path (+ path 1)))))
      (when
        (and (not branch?) all-accepted? (= count 1))
        (unless
          (=
            (bit-and (array-ref inspection.observation.before (+ count 2)) 2)
            0)
          (return false)))
      (if all-accepted?
        (match (& actual)
          [(core.OwnershipResult.Ok) true]
          [_ false])
        matched?))))

(define (terminator-campaign?) : bool
  (let
    [kind : i64 0]
    [checked : i64 0]
    (begin
      (while (< kind 2)
        (let
          [code : i64 0]
          [limit : i64
            (if (= kind 0)
              20
              12)]
          (begin
            (while (< code limit)
              (begin
                (unless
                  (with-arena case-arena (terminator-case? (= kind 0) code))
                  (begin
                    (io.println
                      "ownership-loan-value terminator mismatch: kind={} case={}"
                      kind
                      code)
                    (return false)))
                (set! checked (+ checked 1))
                (set! code (+ code 1))))
            (set! kind (+ kind 1)))))
      (= checked 32))))

(define (expected-outcome? [result : model.Outcome] [accepted? : bool]) : bool
  (match result
    [(model.Outcome.Accepted _ _) accepted?]
    [(model.Outcome.Rejected _) (not accepted?)]
    [(model.Outcome.InvalidInput) false]))

(define (authored-value?
  [operation : i64]
  [borrowed : i64]
  [retained : i64]
  [accepted? : bool]) : bool
  (let
    [loans : (Array model.Loan 3)
      (array
        (model.Loan (cell borrowed) false -1)
        (model.Loan model.Cell.Left false -1)
        (model.Loan model.Cell.Right false -1))]
    [trace : (__tl_dyn-array model.Event) (value-trace 1 retained operation 1)]
    (and
      (expected-outcome?
        (model.execute (& loans) 1 (& trace) true true)
        accepted?)
      (value-case? (& loans) 1 3 retained operation 1))))

(define (authored-terminator?
  [branch? : bool]
  [retained? : bool]
  [count : i64]
  [initial : i64]
  [accepted? : bool]) : bool
  (let
    [loans : (Array model.Loan 3)
      (array
        (model.Loan model.Cell.Left true -1)
        (model.Loan model.Cell.Right false -1)
        (model.Loan model.Cell.Left false -1))]
    [trace : (__tl_dyn-array model.Event) (terminator-trace count retained?)]
    [fixture : core.OwnershipBody
      (terminator-body (& loans) count initial branch? retained?)]
    (and
      (expected-outcome?
        (model.execute
          (& loans)
          count
          (& trace)
          (flag? initial 0)
          (flag? initial 1))
        accepted?)
      (match (core.ownership-check (& fixture) (core.ownership-default-limits))
        [(core.OwnershipResult.Ok) accepted?]
        [(core.OwnershipResult.Err error)
          (and
            (not accepted?)
            (match error.kind
              [(core.OwnershipFailureKind.Loan) true]
              [(core.OwnershipFailureKind.Uninitialized) true]
              [_ false]))]))))

(define (authored-controls?) : bool
  ;; Five named valid/invalid pairs. These expected decisions are asserted
  ;; independently of the generated campaign and of production classification.
  (and
    (authored-value? 0 2 0 true)
    ;; Copy destination loan expired.
    (authored-value? 0 2 1 false)
    ;; Copy writes the retained shared destination.
    (authored-value? 1 1 1 true)
    ;; Move of a Copy source only reads it.
    (authored-value? 2 1 1 false)
    ;; MoveOnly source consumption conflicts.
    (authored-value? 3 1 1 true)
    ;; Copy Consume leaves the shared source intact.
    (authored-value? 4 1 1 false)
    ;; MoveOnly Consume requires write authority.
    (authored-terminator? true false 1 3 true)
    (authored-terminator? true true 1 3 false)
    (authored-terminator? false false 1 3 true)
    ;; Exclusive loan expires at return.
    (authored-terminator? false false 0 0 false)))

;; Return still requires initialization.
(define (main) : i64
  (if (and (value-campaign?) (terminator-campaign?) (authored-controls?))
    (begin
      (io.println
        "ownership-loan-value-crosscheck-v1: values=1160 branch=20 return=12 controls=10 passed")
      0)
    1))