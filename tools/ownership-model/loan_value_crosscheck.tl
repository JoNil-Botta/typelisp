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
(import loan_cases as cases)
(import loan_crosscheck as trace)
(import compiler_ownership_core as core)
(import stdlib.io)
(import stdlib.iterator)

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
  [path : (& path (__tl_dyn-array i64))]
  [left : bool]
  [right : bool]) : bool
  (let
    [state : (__tl_dyn-array i64)
      (__tl_make-array i64 (array-length body.places))]
    (begin
      (for [slot (iterator.range 0 (array-length state))]
        (set!
          (array-ref state slot)
          (if (and
            (match (array-ref body.places slot).projection
              [(core.OwnershipProjection.Root) true]
              [_ false])
            (array-ref body.locals (array-ref body.places slot).local.index).parameter?)
            2
            1)))
      (for [step (iterator.range 0 (array-length path))]
        (let
          [at : i64 (array-ref path step)]
          [instructions : (& body (__tl_dyn-array core.OwnershipInstruction))
            (& (array-ref body.blocks at).instructions)]
          (for [index (iterator.range 0 (array-length instructions))]
            (match (core.ownership-transfer!
              body
              (&mut state)
              (& (array-ref instructions index))
              at
              index)
              [(core.OwnershipResult.Err _) (return false)]
              [_ unit]))))
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
            (successful-state? (& fixture) (& (__tl_make-array 0)) left right))]))))

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

;; Three holder identities form a finite origin graph. This is serialization
;; metadata for production, not the concrete oracle's value/expiry decisions.
(define (reference-origins [program : (& program model.ReferenceProgram)]) : (Array
    i64
    3)
  (let
    [seeds : (Array i64 3) (array 0 0 0)]
    [reach : (Array i64 3) (array 1 2 4)]
    [origins : (Array i64 3) (array 0 0 0)]
    (for [index (iterator.range 0 (array-length program.events))]
      (match (array-ref program.events index)
        [(model.ReferenceEvent.Bind holder site)
          (when
            (and (model.reference-slot? holder) (model.reference-slot? site))
            (set!
              (array-ref seeds holder)
              (bit-or (array-ref seeds holder) (shl 1 site))))]
        [(or (model.ReferenceEvent.Copy source destination)
             (model.ReferenceEvent.Move source destination))
          (when
            (and
              (model.reference-slot? source)
              (model.reference-slot? destination))
            (set!
              (array-ref reach destination)
              (bit-or (array-ref reach destination) (shl 1 source))))]
        [_ unit]))
    (for [via (iterator.range 0 3)]
      (for [holder (iterator.range 0 3)]
        (when
          (flag? (array-ref reach holder) via)
          (set!
            (array-ref reach holder)
            (bit-or (array-ref reach holder) (array-ref reach via))))))
    (for [holder (iterator.range 0 3)]
      (for [from (iterator.range 0 3)]
        (when
          (flag? (array-ref reach holder) from)
          (set!
            (array-ref origins holder)
            (bit-or (array-ref origins holder) (array-ref seeds from))))))
    origins))

(define (reference-loan-count [program : (& program model.ReferenceProgram)]) : i64
  (let
    [count : i64 0]
    (for [index (iterator.range 0 (array-length program.events))]
      (match (array-ref program.events index)
        [(model.ReferenceEvent.Intrinsic (model.Event.Borrow site))
          (when
            (and (model.reference-slot? site) (>= site count))
            (set! count (+ site 1)))]
        [_ unit]))
    count))

(define (reference-uses!
  [instructions
    : (&mut instructions (__tl_dyn-array core.OwnershipInstruction))]
  [origins : (& origins (Array i64 3))]
  [count : i64]
  [holder : i64]) : unit
  (when
    (model.reference-slot? holder)
    (for [site (iterator.range 0 count)]
      (when
        (flag? (array-ref origins holder) site)
        (__tl_array-push!
          instructions
          (instruction
            (core.OwnershipOperation.MayUseLoan
              (loan site)
              (place (+ holder 3)))
            (array-length instructions)))))))

(defstruct ReferenceFixture
  (body core.OwnershipBody)
  (starts (__tl_dyn-array i64))
  (ends (__tl_dyn-array i64)))

(define (reference-body
  [program : (& program model.ReferenceProgram)]
  [loans : (& loans (Array model.Loan 3))]
  [count : i64]) : ReferenceFixture
  (let
    [instructions : (__tl_dyn-array core.OwnershipInstruction) (prefix 0 3)]
    [origins : (Array i64 3) (reference-origins program)]
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [ends : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (for [index (iterator.range 0 (array-length program.events))]
      (__tl_array-push! starts (array-length instructions))
      (match (array-ref program.events index)
        [(model.ReferenceEvent.Intrinsic event)
          (__tl_array-push!
            instructions
            (instruction
              (trace.loan-cross-event (id) (clone event))
              (array-length instructions)))]
        [(model.ReferenceEvent.Bind holder site)
          (__tl_array-push!
            instructions
            (instruction
              (core.OwnershipOperation.UseLoan (loan site))
              (array-length instructions)))
          (__tl_array-push!
            instructions
            (instruction
              (core.OwnershipOperation.Assign (place (+ holder 3)))
              (array-length instructions)))]
        [(or (model.ReferenceEvent.Copy source destination)
             (model.ReferenceEvent.Move source destination))
          (reference-uses! (&mut instructions) (& origins) count source)
          (__tl_array-push!
            instructions
            (instruction
              (if (= source destination)
                ;; Source self-assignment reads its captured value. Core Move
                ;; deliberately requires disjoint source/destination storage.
                (core.OwnershipOperation.Read (place (+ source 3)))
                (match (array-ref program.events index)
                  [(model.ReferenceEvent.Copy _ _)
                    (core.OwnershipOperation.Copy
                      (place (+ source 3))
                      (place (+ destination 3)))]
                  [_
                    (core.OwnershipOperation.Move
                      (place (+ source 3))
                      (place (+ destination 3)))]))
              (array-length instructions)))]
        [(model.ReferenceEvent.Clear holder)
          (__tl_array-push!
            instructions
            (instruction
              (core.OwnershipOperation.Invalidate (place (+ holder 3)))
              (array-length instructions)))]
        [(model.ReferenceEvent.Use holder)
          (reference-uses! (&mut instructions) (& origins) count holder)
          (__tl_array-push!
            instructions
            (instruction
              (core.OwnershipOperation.Read (place (+ holder 3)))
              (array-length instructions)))])
      (__tl_array-push! ends (array-length instructions)))
    (let
      [fixture : core.OwnershipBody
        (body
          loans
          count
          false
          (__tl_make-array
            (core.OwnershipBlock instructions (return-empty) (source 1))))]
      (__tl_array-push!
        fixture.types
        (core.OwnershipType core.OwnershipTypeKind.Scalar program.copy?))
      (for [holder (iterator.range 0 3)]
        (__tl_array-push!
          fixture.locals
          (core.OwnershipLocal (type-id 2) false (source 1)))
        (__tl_array-push!
          fixture.places
          (core.OwnershipPlace
            (core.OwnershipLocalId (id) (+ holder 1))
            (type-id 2)
            core.OwnershipProjection.Root
            (source 1))))
      (ReferenceFixture fixture starts ends))))

(define (reference-failure-at?
  [actual : (& actual core.OwnershipResult)]
  [fixture : (& fixture ReferenceFixture)]
  [at : i64]
  [kind : i64]) : bool
  (match actual
    [(core.OwnershipResult.Ok) false]
    [(core.OwnershipResult.Err error)
      (and
        (= error.block 0)
        (>= error.instruction (array-ref fixture.starts at))
        (< error.instruction (array-ref fixture.ends at))
        (= error.source.line (+ 10 error.instruction))
        (match error.kind
          [(core.OwnershipFailureKind.Loan) (= kind 0)]
          [(core.OwnershipFailureKind.Uninitialized) (= kind 1)]
          [(core.OwnershipFailureKind.Structural) (= kind 2)]
          [_ false]))]))

(define (reference-linear-case? [mode : i64]) : bool
  (let
    [program : model.ReferenceProgram (cases.reference-program mode)]
    [loans : (Array model.Loan 3) (cases.reference-loans program.copy?)]
    [count : i64 (reference-loan-count (& program))]
    [fixture : ReferenceFixture (reference-body (& program) (& loans) count)]
    [expected : model.Outcome
      (model.execute-references (& loans) count (& program) true true)]
    [actual : core.OwnershipResult
      (core.ownership-check (& fixture.body) (core.ownership-default-limits))]
    [ok? : bool
      (match expected
        [(model.Outcome.Accepted left right)
          (and
            (match (& actual)
              [(core.OwnershipResult.Ok) true]
              [_ false])
            (successful-state?
              (& fixture.body)
              (& (__tl_make-array 0))
              left
              right))]
        [(model.Outcome.Rejected at)
          (reference-failure-at?
            (& actual)
            (& fixture)
            at
            (if (or (= mode 7) (= mode 15))
              1
              0))]
        [(model.Outcome.InvalidInput)
          (and
            (or (= mode 11) (= mode 14))
            (reference-failure-at?
              (& actual)
              (& fixture)
              (if (= mode 11)
                0
                2)
              2))])]
    (unless
      ok?
      (io.println "ownership-loan-reference mismatch: linear={}" mode))
    ok?))

(define (reference-linear-campaign?) : bool
  ;; These cases contain each static borrow once. Reissued borrow sites need
  ;; CFG cycles, not duplicate definitions in a linear ownership body.
  (let
    [modes : (Array i64 12) (array 3 4 5 6 7 8 10 11 12 13 14 15)]
    (for [index (iterator.range 0 12)]
      (unless (reference-linear-case? (array-ref modes index)) (return false)))
    true))

(defstruct ReferenceCFG
  (fixture ReferenceFixture)
  (loop-start i64)
  (body-events i64))

(define (reference-instruction-range
  [instructions : (& instructions (__tl_dyn-array core.OwnershipInstruction))]
  [start : i64]
  [end : i64]) : (__tl_dyn-array core.OwnershipInstruction)
  (let
    [out : (__tl_dyn-array core.OwnershipInstruction)
      (__tl_make-array core.OwnershipInstruction 0)]
    (for [index (iterator.range start end)]
      (__tl_array-push! out (clone (array-ref instructions index))))
    out))

(define (reference-cfg-body [kind : i64]) : ReferenceCFG
  (let
    [program : model.ReferenceProgram (cases.reference-cfg-program kind 1)]
    [loans : (Array model.Loan 3) (cases.reference-loans program.copy?)]
    [fixture : ReferenceFixture (reference-body (& program) (& loans) 2)]
    [all : (__tl_dyn-array core.OwnershipInstruction)
      (replace!
        (array-ref fixture.body.blocks 0).instructions
        (__tl_make-array core.OwnershipInstruction 0))]
    [body-events : i64 (- (array-length program.events) 3)]
    [loop-start : i64 (array-ref fixture.starts 2)]
    [loop-end : i64 (array-ref fixture.starts (+ 2 body-events))]
    [entry : (__tl_dyn-array core.OwnershipInstruction)
      (reference-instruction-range (& all) 0 loop-start)]
    [trip : (__tl_dyn-array core.OwnershipInstruction)
      (reference-instruction-range (& all) loop-start loop-end)]
    [exit : (__tl_dyn-array core.OwnershipInstruction)
      (reference-instruction-range (& all) loop-end (array-length all))]
    ;; Assign provides a fresh unknown Boolean at each header visit. No
    ;; reference or modeled memory cell supplies the nondeterministic choice.
    (__tl_array-push!
      fixture.body.types
      (core.OwnershipType core.OwnershipTypeKind.Boolean true))
    (__tl_array-push!
      fixture.body.locals
      (core.OwnershipLocal (type-id 3) false (source 1)))
    (__tl_array-push!
      fixture.body.places
      (core.OwnershipPlace
        (core.OwnershipLocalId (id) 4)
        (type-id 3)
        core.OwnershipProjection.Root
        (source 1)))
    (set!
      fixture.body.blocks
      (__tl_make-array
        (core.OwnershipBlock
          entry
          (core.OwnershipTerminator.Goto (block 1))
          (source 1))
        (core.OwnershipBlock
          (__tl_make-array
            (instruction (core.OwnershipOperation.Assign (place 6)) 100))
          (core.OwnershipTerminator.Branch (place 6) (block 2) (block 3))
          (source 2))
        (core.OwnershipBlock
          trip
          (core.OwnershipTerminator.Goto (block 1))
          (source 3))
        (core.OwnershipBlock exit (return-empty) (source 4))))
    (ReferenceCFG fixture loop-start body-events)))

(define (reference-cfg-failure?
  [actual : (& actual core.OwnershipResult)]
  [cfg : (& cfg ReferenceCFG)]
  [event : i64]) : bool
  (and
    (>= event 2)
    (let
      [site : i64 (+ 2 (% (- event 2) cfg.body-events))]
      (match actual
        [(core.OwnershipResult.Ok) false]
        [(core.OwnershipResult.Err error)
          (and
            (= error.block 2)
            (>=
              error.instruction
              (- (array-ref cfg.fixture.starts site) cfg.loop-start))
            (<
              error.instruction
              (- (array-ref cfg.fixture.ends site) cfg.loop-start))
            (= error.source.line (+ 10 cfg.loop-start error.instruction))
            (match error.kind
              [(core.OwnershipFailureKind.Loan) true]
              [_ false]))]))))

(define (reference-cfg-case? [kind : i64]) : bool
  (let
    [cfg : ReferenceCFG (reference-cfg-body kind)]
    [actual : core.OwnershipResult
      (core.ownership-check
        (& cfg.fixture.body)
        (core.ownership-default-limits))]
    [all-accepted? : bool true]
    (for [trips (iterator.range 0 4)]
      (let
        [program : model.ReferenceProgram
          (cases.reference-cfg-program kind trips)]
        [loans : (Array model.Loan 3) (cases.reference-loans program.copy?)]
        [expected : model.Outcome
          (model.execute-references (& loans) 2 (& program) true true)]
        (match expected
          [(model.Outcome.InvalidInput)
            (io.println
              "ownership-loan-reference invalid CFG input: kind={} trips={}"
              kind
              trips)
            (return false)]
          [(model.Outcome.Rejected event)
            (set! all-accepted? false)
            (unless
              (reference-cfg-failure? (& actual) (& cfg) event)
              (io.println
                "ownership-loan-reference CFG mismatch: kind={} trips={} event={}"
                kind
                trips
                event)
              (return false))]
          [(model.Outcome.Accepted left right)
            ;; A graph rejection may be justified by another concrete path.
            ;; Only an accepted graph authorizes replay of its successful state.
            (when
              (match (& actual)
                [(core.OwnershipResult.Ok) true]
                [_ false])
              (let
                [path : (__tl_dyn-array i64) (__tl_make-array 0 1)]
                (for [_trip (iterator.range 0 trips)]
                  (__tl_array-push! path 2)
                  (__tl_array-push! path 1))
                (__tl_array-push! path 3)
                (unless
                  (successful-state? (& cfg.fixture.body) (& path) left right)
                  (io.println
                    "ownership-loan-reference CFG state mismatch: kind={} trips={}"
                    kind
                    trips)
                  (return false))))])))
    (=
      all-accepted?
      (match (& actual)
        [(core.OwnershipResult.Ok) true]
        [_ false]))))

(define (reference-cfg-campaign?) : bool
  (for [kind (iterator.range 0 4)]
    (unless (reference-cfg-case? kind) (return false)))
  true)

;; Return still requires initialization.
(define (main) : i64
  (if (and
    (value-campaign?)
    (terminator-campaign?)
    (authored-controls?)
    (reference-linear-campaign?)
    (reference-cfg-campaign?))
    (begin
      (io.println
        "ownership-loan-value-crosscheck-v2: values=1160 branch=20 return=12 controls=10 reference-linear=12 reference-graphs=4 reference-paths=16 passed")
      0)
    1))